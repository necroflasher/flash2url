module flash2url.main;

import core.stdc.errno;
import core.stdc.stdio;
import core.sys.posix.sys.wait;
import core.sys.posix.unistd;
import std.array;
import std.path;
import std.process;
import std.string;
import flash2url.config;
import flash2url.server;
import flash2url.socket;
static import std.stdio;

__gshared
{
	Pid g_subProcess;
}

extern(C) void sigChild(int) nothrow @nogc
{
	if (g_subProcess is null)
		return;

	pid_t pid = g_subProcess.osHandle;

	int status;
	int waitrv;
	while ((waitrv = waitpid(pid, &status, WNOHANG)) == -1 && errno == EINTR)
		continue;

	if (waitrv == pid && WIFEXITED(status))
	{
		_exit(WEXITSTATUS(status));
	}
}

int main(string[] args)
{
	CmdLine cmd;

	if (int rv = cmd.parse(args))
		return rv;

	ushort port;
	int server = makeServer(listenAddress, port);

	char[512] urlbuf = void;
	snprintf(urlbuf.ptr, urlbuf.length, "http://%s:%hu/%s",
		listenAddress.ptr,
		port, urlencodeFilenameForFlashPlayer(cmd.filename).toStringz);

	g_subProcess = spawnProcess(
		cmd.subcommand ~ [urlbuf.fromStringz.idup],
		std.stdio.File("/dev/null", "rw"),
		std.stdio.stdout,
		std.stdio.stderr,
		);

	signal(SIGCHLD, &sigChild);
	signal(SIGPIPE, SIG_IGN);

	runServer(server, cmd);

	// if we got here, it means the server stopped because of an error

	if (g_subProcess)
	{
		kill(SIGTERM, g_subProcess.osHandle);
		g_subProcess.wait();
	}

	return 1;
}

struct CmdLine
{
	ulong    contentLengthKnown;
	string   filename;
	string   baseDir;
	string   baseUrl;
	string[] subcommand;

	int parse(string[] args)
	{
		foreach (i, arg; args[1..$])
		{
			if (string base = arg.stripPrefix("-basedir="))
			{
				baseDir = base;
			}
			else if (string base = arg.stripPrefix("-baseurl="))
			{
				baseUrl = base;
			}
			else if (string cl = arg.stripPrefix("-contentlength="))
			{
				int n;
				if (
					sscanf(cl.toStringz, "%llu%n", &contentLengthKnown, &n) != 1 ||
					cast(long)n != cast(long)cl.length)
				{
					fprintf(stderr, "failed to parse content-length value '%s'\n", cl.toStringz);
					return 1;
				}
			}
			else if (string fn = arg.stripPrefix("-filename="))
			{
				filename = fn;
			}
			else if (arg.length && arg[0] == '-')
			{
				fprintf(stderr, "unknown option '%s'\n", arg.toStringz);
				return 1;
			}
			else
			{
				subcommand = args[1+i..$];
				break;
			}
		}

		if (!subcommand.length)
		{
			fprintf(stderr,
				"usage: flash2url [options] <command> < infile.swf\n"~
				"options:\n"~
				"    -basedir=<path>   load files relative to the .swf from <path> + subpath\n"~
				"    -baseurl=<url>    redirect requests relative to the .swf to <url> + path\n"~
				"    -filename=<name>  set the name to serve the flash as (default: file.swf)\n"~
				"");

			return 1;
		}

		if (baseDir.length && baseUrl.length)
		{
			fprintf(stderr, "flash2url: can only use one of -basedir= and -baseurl=\n");
			return 1;
		}

		if (!filename.length)
			filename = fdname(0);

		if (!filename.length)
			filename = "file.swf";

		if (!(filename.length >= 4 && filename[$-4..$] == ".swf"))
			filename ~= ".swf";

		return 0;
	}
}

string stripPrefix(string self, string other)
{
	if (self.length >= other.length && self[0..other.length] == other)
		return self[other.length..$];
	else
		return null;
}

string fdname(int fd)
{
	import std.file : readLink;

	char[128] linkbuf = void;
	snprintf(linkbuf.ptr, linkbuf.length, "/proc/self/fd/%d", fd);

	try
	{
		string path = linkbuf.fromStringz.readLink;
		if (path.length && path[0] == '/')
			return path.baseName;
	}
	catch (Exception e)
	{
	}

	return null;
}

/**
 * url-encode the filename for passing it in the url, just enough that flash
 *  doesn't reject it
 * 
 * it cares about:
 * - characters below ' ' including tab
 * - 7f
 * 
 * but not
 * - stray percent signs
 * - invalid utf-8 (literal or url-encoded)
 * - slashes, query string (these don't matter, they become part of the url)
 */
string urlencodeFilenameForFlashPlayer(string str)
{
	auto ap = appender!string();
	foreach (c; str)
	{
		if (c < ' ' || c == 0x7f)
		{
			static immutable hexchars = "0123456789abcdef";
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
