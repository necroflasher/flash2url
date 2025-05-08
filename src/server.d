module flash2url.server;

import core.stdc.errno;
import core.stdc.stdio;
import core.sys.posix.fcntl;
import core.sys.posix.unistd;
import core.time;
import std.array;
import std.path;
import std.string;
import std.uri : urldecode = decode, urlencode = encode;
import flash2url.main : CmdLine;
import flash2url.socket;
import flash2url.swfparser;

__gshared
{
	/// the flash file that was read from stdin
	Appender!(ubyte[]) g_flashData;

	/// url string that the flash was first requested from (urlencoded path+query)
	string g_flashUrl;
}

void runServer(int server, ref const(CmdLine) cmd)
{
	serverloop:
	for (;;)
	{
		int client = accept4(server, null, null, SOCK_CLOEXEC);

		if (client == -1)
		{
			if (errno == EINTR)
				continue;

			perror("accept");
			break;
		}

		scope(exit)
		{
			if (client != -1)
			{
				close(client);
				client = -1;
			}
		}

		HttpRequestHead head;
		for (ubyte[] request; /* empty */; /* empty */)
		{
			ubyte[16*1024] buf = void;
			ssize_t readrv = read(client, buf.ptr, buf.length);
			if (readrv == -1)
			{
				perror("read");
				continue serverloop;
			}
			if (readrv == 0)
			{
				continue serverloop;
			}
			request ~= buf[0..readrv];
			if (head.parse(request))
			{
				break;
			}
		}

		//fprintf(stderr, ">>>\n%.*s<<<\n", cast(int)request.length-2, request.ptr);

		if (head.method == "GET" && !g_flashUrl.length)
		{
			// first request, assume this is the flash

			g_flashUrl = head.url;
			if (!serveFlash(client, cmd.filename, cmd.contentLengthKnown))
			{
				break;
			}
		}
		else if (head.method == "GET" && head.url == g_flashUrl)
		{
			// loading the flash a second time (probably reloaded by clicking
			//  the url and pressing enter)

			char[64] contentLengthBuf = void;
			snprintf(contentLengthBuf.ptr, contentLengthBuf.length, "Content-Length: %zu\r\n", g_flashData[].length);

			write_full(client,
				"HTTP/1.1 200 OK\r\n"~
				"Content-Type: application/x-shockwave-flash\r\n"~
				contentLengthBuf.fromStringz~
				"Connection: close\r\n"~
				"\r\n"
				);

			if (!write_full(client, g_flashData[]))
			{
				break;
			}
		}
		else
		{
			serveOtherResource(client, head, cmd);
		}

		//fprintf(stderr, "flash2url: closing connection\n");
		shutdown(client, SHUT_WR);
		for (;;)
		{
			ubyte[16*1024] tmp = void;
			ssize_t readrv = read(client, tmp.ptr, tmp.length);
			if (readrv == 0 || (readrv == -1 && errno != EINTR))
				break;
		}
		//fprintf(stderr, "flash2url: request finished\n");
	}
}

/**
 * serve a resource relative to the .swf file
 */
void serveOtherResource(int client, ref const(HttpRequestHead) head, ref const(CmdLine) cmd)
{
	if (cmd.baseUrl.length)
	{
		serveOtherFromBaseUrl(client, head, cmd);
		return;
	}

	if (cmd.baseDir.length)
	{
		serveOtherFromBaseDir(client, head, cmd);
		return;
	}

	// no -basedir= or -baseurl=

	write_full(client,
		"HTTP/1.1 404 Not Found\r\n"~
		"Content-Length: 0\r\n"~
		"Connection: close\r\n"~
		"\r\n"
		);
}

void serveOtherFromBaseUrl(int client, ref const(HttpRequestHead) head, ref const(CmdLine) cmd)
{
	string target = cmd.baseUrl;

	// if the base url already ends with a slash, don't add another one from the path
	if (target[$-1] == '/')
		target ~= head.url[1..$];
	else
		target ~= head.url;

	fprintf(stderr, "flash2url: -> %s\n", target.toStringz);

	write_full(client,
		"HTTP/1.1 307 Temporary Redirect\r\n"~
		"Location: "~target~"\r\n"~
		"Content-Length: 0\r\n"~
		"Connection: close\r\n"~
		"\r\n"
		);
}

void serveOtherFromBaseDir(int client, ref const(HttpRequestHead) head, ref const(CmdLine) cmd)
{
	/*
	 * not sure why i implemented this. i can't think of a situation
	 *  where you'd want to stream the main .swf but already have
	 *  the other files it needs on disk
	 */

	if (head.method != "GET")
	{
		write_full(client,
			"HTTP/1.1 405 Method Not Allowed\r\n"~
			"Content-Length: 0\r\n"~
			"Connection: close\r\n"~
			"\r\n"
			);
		return;
	}

	int dataFd = -1;
	int dataErr;

	string dataFilePath = safeJoinPath(cmd.baseDir, urldecode(head.url));

	dataFd = open(dataFilePath.toStringz, O_RDONLY|O_CLOEXEC);
	if (dataFd == -1)
		dataErr = errno;

	stat_t sb;
	if (dataFd != -1)
	{
		if (fstat(dataFd, &sb) == -1)
		{
			dataErr = errno;
			close(dataFd);
			dataFd = -1;
		}
	}

	if (dataFd != -1 && S_ISDIR(sb.st_mode))
	{
		dataErr = EISDIR;
		close(dataFd);
		dataFd = -1;
	}

	//printf("%s %s -> fd %d errno %d\n", head.method.toStringz, dataFilePath.toStringz, dataFd, dataErr);

	if (dataFd != -1)
	{
		fprintf(stderr, "flash2url: -> %s\n", dataFilePath.toStringz);

		char[64] contentLengthBuf = void;
		snprintf(contentLengthBuf.ptr, contentLengthBuf.length, "Content-Length: %llu\r\n", cast(ulong)sb.st_size);

		write_full(client,
			"HTTP/1.1 200 OK\r\n"~
			contentLengthBuf.fromStringz~
			"Connection: close\r\n"~
			"\r\n"
			);

		for (;;)
		{
			ubyte[16*1024] buf = void;
			ssize_t readrv = read(dataFd, buf.ptr, buf.length);
			if (readrv == -1)
			{
				perror("read");
				break;
			}
			if (readrv == 0)
			{
				break;
			}
			if (!write_full(client, buf[0..readrv]))
			{
				break;
			}
		}

		close(dataFd);
	}
	else
	{
		fprintf(stderr, "flash2url: !! %s\n", dataFilePath.toStringz);

		string status = "500";

		if (dataErr == EISDIR)
			status = "400";
		if (dataErr == EPERM || dataErr == EACCES)
			status = "403";
		if (dataErr == ENOENT)
			status = "404";

		write_full(client,
			"HTTP/1.1 "~status~"\r\n"~
			"Content-Length: 0\r\n"~
			"Connection: close\r\n"~
			"\r\n"
			);
	}
}

/**
 * serve the flash from stdin (first time only)
 * 
 * contentLength: set if known, 0 otherwise
 */
bool serveFlash(int client, string filename, ulong contentLength)
{
	auto startTime = MonoTime.currTime;

	scope sr = new SwfReader;

	ulong sizeRead;

	bool writeError;
	ulong bodySizeWritten;

	bool headerSent;
	auto bufferedData = appender!(ubyte[]);

	/*
	 * if the content-length of the incoming swf data is known, use it and
	 *  write the file as-is in the http response
	 * 
	 * otherwise, decompress the swf and serve it that way, using the
	 *  uncompressed filesize from the swf header as the content-length
	 * 
	 * why: some flashes have a preloader that depends on content-length being
	 *  correct (they check loaderInfo.bytesLoaded against loaderInfo.bytesTotal)
	 * 
	 * the two modes work about the same, but serving the compressed original
	 *  may be better in case something depends on the exact value of bytesTotal
	 */
	const bool serveCompressedOriginal = (contentLength != 0);

	void trySendHeader()
	{
		if (headerSent)
			return;

		bool sawFirstFrame;
		for (SwfTagInfo tag; sr.nextTag(tag); /* empty */)
		{
			enum ShowFrame = 1;

			if (tag.code == ShowFrame)
			{
				sawFirstFrame = true;
				break;
			}
		}
		if (!sawFirstFrame)
			return;

		char[64] contentLengthBuf = void;
		snprintf(contentLengthBuf.ptr, contentLengthBuf.length, "Content-Length: %llu\r\n", contentLength);

		auto headerData =
			"HTTP/1.1 200 OK\r\n"~
			"Content-Type: application/x-shockwave-flash\r\n"~
			contentLengthBuf.fromStringz~
			"Connection: close\r\n"~
			"\r\n";

		if (
			!write_full(client, headerData) ||
			!write_full(client, bufferedData[]))
		{
			writeError = true;
		}

		headerSent = true;

		bodySizeWritten += bufferedData[].length;
		bufferedData.clear();

		auto timeToFirstFrame = (MonoTime.currTime - startTime);
		if (timeToFirstFrame >= 10.seconds)
		{
			fprintf(stderr, "\a"~"flash2url: to play the flash, click the url and press enter\n");
			// idea: kill and restart flash player?
			// this should be uncommon though, maybe not worth the complexity
		}
	}

	// decompress mode: set a callback to receive a decompressed version of the flash
	if (!serveCompressedOriginal)
	{
		sr.putDecompressed = (scope buf)
		{
			if (headerSent)
			{
				if (write_full(client, buf))
					bodySizeWritten += buf.length;
				else
					writeError = true;
			}
			else
			{
				bufferedData ~= buf;
			}
		};
	}

	for (;;)
	{
		ubyte[16*1024] buf = void;

		ssize_t readrv = read(STDIN_FILENO, buf.ptr, buf.length);
		if (readrv == -1)
		{
			perror("read");
			break;
		}
		if (readrv == 0)
		{
			sr.putEndOfInput();
			break;
		}

		sizeRead += buf[0..readrv].length;
		sr.put(buf[0..readrv]);

		g_flashData ~= buf[0..readrv];

		if (!headerSent)
		{
			// decompress mode: get content-length from the swf header
			if (!serveCompressedOriginal)
			{
				contentLength = sr.swfHeader.fileSize;
			}

			trySendHeader();
		}

		// compressed mode writes or buffers the data here
		// decompress mode does it in the swfreader callback
		if (serveCompressedOriginal)
		{
			if (headerSent)
			{
				if (write_full(client, buf[0..readrv]))
					bodySizeWritten += buf[0..readrv].length;
				else
					writeError = true;
			}
			else
			{
				bufferedData ~= buf[0..readrv];
			}
		}

		// write error -> probably flash has exited, we'll soon exit too
		// end the loop so we don't spam error messages
		if (writeError)
		{
			break;
		}
	}

	trySendHeader();

	// i guess we couldn't parse the first frame?
	// should just dump the entire file in this case? (no valid flash needs this though)
	if (!headerSent)
	{
		fprintf(stderr, "flash2url: header never sent?\n");
		write_full(client,
			"HTTP/1.1 500 Internal Server Error\r\n"~
			"Content-Length: 0\r\n"~
			"Connection: close\r\n"~
			"\r\n"
			);
	}

	// check that content-length matches what we wrote
	if (headerSent && !writeError && bodySizeWritten != contentLength)
	{
		char[64] type = void;
		if (bodySizeWritten > contentLength)
			snprintf(type.ptr, type.length, " (%llu extra)", bodySizeWritten-contentLength);
		else
			snprintf(type.ptr, type.length, " (%llu short)", contentLength-bodySizeWritten);

		fprintf(stderr, "flash2url: warning: sent content-length %llu but wrote %llu bytes%s\n",
			contentLength, bodySizeWritten, type.ptr);
	}

	//if (headerSent && !writeError)
	//{
	//	auto dltime = (MonoTime.currTime - startTime);
	//	if (dltime >= 10.msecs)
	//	{
	//		fprintf(stderr, "flash2url: download finished in %s\n",
	//			msecs(dltime.total!"msecs").toString().toStringz);
	//	}
	//}

	if (!headerSent || writeError)
		return false;

	return true;
}

/// append "path" to "root" without letting it escape that directory
string safeJoinPath(string root, string path)
{
	assert(root.length);
	return root~buildNormalizedPath("/", path);
}

//static assert(safeJoinPath("hi", "/../bye") == "hi/bye");
//static assert(safeJoinPath("hi", "bye") == "hi/bye");

struct HttpRequestHead
{
	string method;
	string url;
	string protocol;

	string[2][] headers;

	void reset()
	{
		this = this.init;
	}

	bool parse(ubyte[] buf)
	{
		reset();

		size_t i;
		bool emptyLine;
		foreach (line; buf.assumeUTF.lineSplitter)
		{
			if (i == 0)
			{
				size_t sp1 = line.indexOf(' ');
				size_t sp2 = line.lastIndexOf(' ');
				method   = line[0..sp1].idup;
				url      = line[sp1+1..sp2].idup;
				protocol = line[sp2+1..$].idup;
			}
			else if (line.length)
			{
				size_t colon = line.indexOf(':');
				string name  = line[0..colon].strip.idup;
				string value = line[colon+1..$].strip.idup;
				headers ~= [name, value];
			}
			else
			{
				emptyLine = true;
				break;
			}
			i++;
		}

		if (!emptyLine)
			return false;

		return true;
	}
}

bool write_full(int fd, scope const(void)[] data) nothrow @nogc
{
	const void[] origdata = data;

	while (data.length)
	{
		ssize_t rv = write(fd, data.ptr, (data.length <= ssize_t.max) ? data.length : ssize_t.max);

		if (rv == -1)
		{
			if (errno == EINTR)
				continue;

			//debug(server)
			{
				int err = errno;
				fprintf(stderr, "write_full: got errno %d on fd %d with %zu/%zu bytes written\n",
					err,
					fd,
					(origdata.length - data.length),
					origdata.length);
				errno = err;
			}

			return false;
		}

		// write doesn't fail with rv 0, only read does
		assert(rv != 0);

		data = data[rv..$];
	}

	return true;
}

bool read_full(int fd, scope void[] data) nothrow @nogc
{
	const void[] origdata = data;

	while (data.length)
	{
		ssize_t rv = read(fd, data.ptr, (data.length <= ssize_t.max) ? data.length : ssize_t.max);

		if (rv == -1)
		{
			if (errno == EINTR)
				continue;

			//debug(server)
			{
				int err = errno;
				fprintf(stderr, "read_full: got errno %d on fd %d with %zu/%zu bytes read\n",
					err,
					fd,
					(origdata.length - data.length),
					origdata.length);
				errno = err;
			}

			return false;
		}

		// end of file?
		if (rv == 0)
		{
			// partial read?
			if (data.ptr != origdata.ptr)
				errno = EIO;
			else
				errno = 0;

			//debug(server)
			{
				int err = errno;
				fprintf(stderr, "read_full: got EOF on fd %d with %zu/%zu bytes read\n",
					fd,
					(origdata.length - data.length),
					origdata.length);
				errno = err;
			}

			return false;
		}

		data = data[rv..$];
	}

	return true;
}
