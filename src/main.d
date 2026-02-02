module flash2url.main;

import core.stdc.errno;
import core.stdc.stdio;
import core.sys.posix.sys.wait;
import core.sys.posix.unistd;
import std.array : appender;
import std.path : baseName;
import std.process : Pid, spawnProcess, wait;
import std.string : fromStringz, toStringz;
import flash2url.config;
import flash2url.server;
import flash2url.socket;
static import std.file;
static import std.stdio;

__gshared
{
	Pid g_subProcess;
}

extern(C) void sigChild(int) nothrow @nogc
{
	pid_t pid;
	int status;
	int waitrv;
	int err;

	err = errno;
	pid = g_subProcess.osHandle;

	while (
	    (waitrv = waitpid(pid, &status, WNOHANG)) < 0 &&
	    errno == EINTR)
		continue;

	if (pid != waitrv)
		goto end;

	if (WIFEXITED(status))
		_exit(WEXITSTATUS(status));
	if (WIFSIGNALED(status))
		_exit(128 + WTERMSIG(status));
end:
	errno = err;
}

int main(string[] args)
{
	CmdLine cmd;

	if (int rv = cmd.parse(args))
		return rv;

	if (isatty(STDIN_FILENO))
	{
		fprintf(stderr,
		    "flash2url: stdin is a terminal, exiting\n");
		return 1;
	}

	ushort port;
	int server;
	if (!makeServer(listenAddress, port, server))
	{
		fprintf(stderr, "flash2url: failed to create server\n");
		return 1;
	}

	char[6] portbuf = void;
	snprintf(portbuf.ptr, portbuf.length, "%hu", port);
	char[] url =
	    "http://"~
	    listenAddress~
	    ":"~
	    portbuf.fromStringz~
	    "/"~
	    urlencodeFilenameForFlashPlayer(cmd.filename);

	g_subProcess = spawnProcess(
	    cmd.subcommand ~ [url.idup],
	    std.stdio.File("/dev/null", "rw"),
	    std.stdio.stdout,
	    std.stdio.stderr);
	/* the SIGCHLD handler is somewhat unsafe. set it only
	   after the global is set. trigger it manually once
	   in case we missed anything. */
	signal(SIGCHLD, &sigChild);
	sigChild(SIGCHLD);
	/* let us read EOF on stdin instead of killing the process */
	signal(SIGPIPE, SIG_IGN);

	runServer(server, cmd);

	/* if we got here, it means the server stopped because of an
	   error. normally we would exit through the signal handler. */

	fprintf(stderr,
	    "flash2url: server stopped, killing child process\n");

	if (kill(g_subProcess.osHandle, SIGTERM) < 0)
		perror("kill");

	g_subProcess.wait();

	return 1;
}

struct CmdLine
{
	ulong    contentLengthKnown;
	string   filename;
	string   baseDir;
	string   baseUrl;
	string[] subcommand;
	bool     traceServer;
}

int parse(ref CmdLine cl, string[] args)
{
	foreach (i, arg; args[1..$])
	{
		if (string base = arg.stripPrefix("-basedir="))
		{
			cl.baseDir = base;
		}
		else if (string base = arg.stripPrefix("-baseurl="))
		{
			cl.baseUrl = base;
		}
		else if (
		    string cls = arg.stripPrefix("-contentlength="))
		{
			int n;
			if (sscanf(cls.toStringz, "%llu%n",
			     &cl.contentLengthKnown, &n) != 1 ||
			    cast(long)n != cast(long)cls.length)
			{
				fprintf(stderr,
				    "failed to parse content-length"~
				    " value '%s'\n",
				    cls.toStringz);
				return 1;
			}
		}
		else if (string fn = arg.stripPrefix("-filename="))
		{
			cl.filename = fn;
		}
		else if (arg == "-trace=server")
		{
			cl.traceServer = true;
		}
		else if (arg.length && arg[0] == '-')
		{
			fprintf(stderr,
			    "unknown option '%s'\n", arg.toStringz);
			return 1;
		}
		else
		{
			cl.subcommand = args[1+i..$];
			break;
		}
	}

	if (!cl.subcommand.length)
	{
		fprintf(stderr,
"usage: flash2url [options] <command> < infile.swf\n"~
"options:\n"~
"    -contentlength=<n>  file at stdin is <n> bytes long\n"~
"    -basedir=<path>     load files relative to the .swf from <path> + subpath\n"~
"    -baseurl=<url>      redirect requests relative to the .swf to <url> + path\n"~
"    -filename=<name>    set the name to serve the flash as (default: file.swf)\n"~
"    -trace=server\n"~
"");
		return 1;
	}

	if (cl.baseDir.length && cl.baseUrl.length)
	{
		fprintf(stderr,
		    "flash2url: can only use one of"~
		    " -basedir= and -baseurl=\n");
		return 1;
	}

	if (!cl.filename.length)
		cl.filename = fdname(0);

	if (!cl.filename.length)
		cl.filename = "file.swf";

	if (!(cl.filename.length >= 4 && cl.filename[$-4..$] == ".swf"))
		cl.filename ~= ".swf";

	return 0;
}

string stripPrefix(string self, string other)
{
	if (self.length >= other.length &&
	    self[0..other.length] == other)
		return self[other.length..$];
	else
		return null;
}

string fdname(int fd)
{
	char[128] linkbuf = void;
	snprintf(linkbuf.ptr, linkbuf.length, "/proc/self/fd/%d", fd);

	try
	{
		string path = std.file.readLink(linkbuf.fromStringz);
		if (path.length && path[0] == '/')
			return path.baseName;
	}
	catch (Exception)
	{
	}

	return null;
}

unittest
{
	int[2] tube;
	if (pipe(tube) < 0)
		assert(0);
	assert(fdname(tube[0]) is null);
	close(tube[0]);
	close(tube[1]);

	/* note: this resolves symlinks. would use /bin/sh but that's a
	   symlink to a different shell. let's hope the user has this
	   other nonstandard thing instead. */
	FILE* f;
	f = fopen("/etc/resolv.conf", "r");
	assert(f);
	//fprintf(stderr, "[%s]\n", fdname(fileno(f)).toStringz);
	assert(fdname(fileno(f)) == "resolv.conf");
	fclose(f);
}

/**
 * url-encode the filename for passing it in the url, just enough that
 *  flash doesn't reject it
 * 
 * it cares about:
 * - characters below ' ' including tab
 * - 7f
 * 
 * but not
 * - stray percent signs
 * - invalid utf-8 (literal or url-encoded)
 * - slashes, query string (these don't matter,
 *                          they become part of the url)
 */
string urlencodeFilenameForFlashPlayer(string str)
{
	static immutable hexchars = "0123456789abcdef";
	auto ap = appender!string();
	foreach (c; str)
	{
		if (c < ' ' || c == 0x7f)
		{
			ap ~= '%';
			ap ~= hexchars[c >> 4];
			ap ~= hexchars[c & 0b1111];
		}
		else
		{
			ap ~= c;
		}
	}
	return ap[];
}

unittest
{
	alias fn = urlencodeFilenameForFlashPlayer;
	assert(fn("hi.swf") == "hi.swf");
	assert(fn("hi/?") == "hi/?");
	assert(fn("ha%h") == "ha%h");
	assert(fn("\x01") == "%01");
	assert(fn("\x20") == "\x20");
	assert(fn("\x7f") == "%7f");
	assert(fn("\x80") == "\x80");
}
