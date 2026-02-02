module flash2url.server;

import core.stdc.errno;
import core.stdc.stdio;
import core.sys.posix.fcntl;
import core.sys.posix.unistd;
import core.time : MonoTime, seconds;
import std.array : Appender, appender;
import std.path : buildNormalizedPath;
import std.string : assumeUTF, fromStringz, indexOf, lastIndexOf,
    lineSplitter, strip, toStringz;
import std.uri : urldecode = decode;
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
	while (runServerIter(server, cmd))
		continue;
}

bool runServerIter(int server, ref const(CmdLine) cmd)
{
	int client;

	if (cmd.traceServer)
		fprintf(stderr, "flash2url: > accept\n");

	client = accept4(server, null, null, SOCK_CLOEXEC);

	if (cmd.traceServer)
		fprintf(stderr, "flash2url: < accept fd=%d\n", client);

	if (client < 0)
	{
		if (errno == EINTR)
			return true;

		perror("accept");
		return false;
	}

	try
		return handleClient(client, cmd);
	finally
		close(client);
}

bool handleClient(int client, ref const(CmdLine) cmd)
{
	HttpRequestHead head;

	/*
	 * [1/2] read the request headers
	 */

	if (cmd.traceServer)
		fprintf(stderr,
		    "flash2url: reading request headers...\n");

	for (ubyte[] request; /* empty */; /* empty */)
	{
		ubyte[16*1024] buf = void;
		ssize_t readrv;

		readrv = read(client, buf.ptr, buf.length);

		if (readrv < 0)
		{
			perror("read");
			return true;
		}
		if (!readrv)
		{
			fprintf(stderr,
			    "flash2url: EOS reading request\n");
			return true;
		}

		request ~= buf[0..readrv];

		if (head.parse(request))
		{
			if (0)
				fprintf(stderr, "[%.*s]\n",
				    cast(int)request.length,
				    request.ptr);
			break;
		}

		if (request.length > 128*1024)
		{
			fprintf(stderr,
			    "flash2url: unable to parse request\n");
			return true;
		}
	}

	if (cmd.traceServer)
		fprintf(stderr,
		    "flash2url: reading request headers... done\n");

	/*
	 * [2/2] decide what to do for the url + method
	 */

	if (head.method == "GET" && !g_flashUrl.length)
	{
		/* first request, assume this is the flash */

		g_flashUrl = head.url;

		if (cmd.traceServer)
			fprintf(stderr,
			    "flash2url: GET flash at %s -> read\n",
			    head.url.toStringz);

		if (!serveFlash(client,
		     cmd.filename, cmd.contentLengthKnown, cmd))
			return false;
	}
	else if (head.method == "GET" && head.url == g_flashUrl)
	{
		char[64] contentLengthBuf = void;

		/* loading the flash a second time (probably reloaded by
		   clicking the url and pressing enter) */

		if (cmd.traceServer)
			fprintf(stderr,
			    "flash2url: GET flash at %s -> cache\n",
			    head.url.toStringz);

		snprintf(
		    contentLengthBuf.ptr,
		    contentLengthBuf.length,
		    "%zu",
		    g_flashData[].length);

		write_full(client,
		    "HTTP/1.1 200 OK\r\n"~
		    "Content-Type: application/x-shockwave-flash\r\n"~
		    "Content-Length: "~
		     contentLengthBuf.fromStringz~"\r\n"~
		    "Connection: close\r\n"~
		    "\r\n"~
		    "");

		if (!write_full(client, g_flashData[]))
			return false;
	}
	else
	{
		if (cmd.traceServer)
			fprintf(stderr,
			    "flash2url: serve resource at %s\n",
			    head.url.toStringz);

		serveResource(client, head, cmd);
	}

	return true;
}

/**
 * serve a resource relative to the .swf file
 */
void serveResource(
	int                        client,
	ref const(HttpRequestHead) head,
	ref const(CmdLine)         cmd)
{
	if (cmd.baseUrl.length)
	{
		serveResourceWithBaseUrl(client, head, cmd);
		return;
	}

	if (cmd.baseDir.length)
	{
		serveResourceWithBaseDir(client, head, cmd);
		return;
	}

	// no -basedir= or -baseurl=

	write_full(client,
	    "HTTP/1.1 404 Not Found\r\n"~
	    "Content-Length: 0\r\n"~
	    "Connection: close\r\n"~
	    "\r\n"~
	    "");
}

void serveResourceWithBaseUrl(
	int                        client,
	ref const(HttpRequestHead) head,
	ref const(CmdLine)         cmd)
{
	string target = cmd.baseUrl;

	/* if the base url already ends with a slash, don't add another
	   one from the path */
	if (target[$-1] == '/')
		target ~= head.url[1..$];
	else
		target ~= head.url;

	fprintf(stderr, "flash2url: -> %s\n", target.toStringz);

	/* 307 will supposedly preserve the method */
	write_full(client,
	    "HTTP/1.1 307 Temporary Redirect\r\n"~
	    "Location: "~target~"\r\n"~
	    "Content-Length: 0\r\n"~
	    "Connection: close\r\n"~
	    "\r\n"~
	    "");
}

void serveResourceWithBaseDir(
	int                        client,
	ref const(HttpRequestHead) head,
	ref const(CmdLine)         cmd)
{
	if (head.method != "GET")
	{
		/* disk files only support GET */
		write_full(client,
		    "HTTP/1.1 405 Method Not Allowed\r\n"~
		    "Content-Length: 0\r\n"~
		    "Connection: close\r\n"~
		    "\r\n"~
		    "");
		return;
	}

	/*
	 * open and stat the file
	 */

	int dataFd = -1;
	int dataErr;
	stat_t sb;

	string dataFilePath =
	    safeJoinPath(cmd.baseDir, urldecode(head.url));

	dataFd = open(dataFilePath.toStringz, O_RDONLY|O_CLOEXEC);
	if (dataFd < 0)
		dataErr = errno;

	if (dataFd >= 0)
	{
		if (fstat(dataFd, &sb) < 0)
		{
			dataErr = errno;
			close(dataFd);
			dataFd = -1;
		}
	}

	/* can't open dirs! */
	if (dataFd >= 0 && S_ISDIR(sb.st_mode))
	{
		dataErr = EISDIR;
		close(dataFd);
		dataFd = -1;
	}

	/*
	 * was there an error opening it?
	 */

	if (dataFd < 0)
	{
		fprintf(stderr,
		    "flash2url: !! %s\n", dataFilePath.toStringz);

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
		    "\r\n"~
		    "");

		return;
	}

	/*
	 * write the file to the client and get out
	 */

	fprintf(stderr, "flash2url: -> %s\n", dataFilePath.toStringz);

	char[64] contentLengthBuf = void;
	snprintf(
	    contentLengthBuf.ptr,
	    contentLengthBuf.length,
	    "%llu",
	    cast(ulong)sb.st_size);

	write_full(client,
	    "HTTP/1.1 200 OK\r\n"~
	    "Content-Length: "~contentLengthBuf.fromStringz~"\r\n"~
	    "Connection: close\r\n"~
	    "\r\n"~
	    "");

	for (;;)
	{
		ubyte[16*1024] buf = void;
		ssize_t readrv;

		readrv = read(dataFd, buf.ptr, buf.length);

		if (readrv < 0)
		{
			perror("read");
			break;
		}
		if (!readrv)
			break;

		if (!write_full(client, buf[0..readrv]))
			break;
	}

	close(dataFd);
}

/**
 * serve the flash from stdin (first time only)
 * 
 * contentLength: set if known, 0 otherwise
 */
bool serveFlash(
	int                client,
	string             filename,
	ulong              contentLength,
	ref const(CmdLine) cmd)
{
	auto sr = SwfReader();

	auto startTime = MonoTime.currTime;

	scope time = ()
	{
		auto sec = (MonoTime.currTime - startTime)
		    .total!"hnsecs"/10_000_000.0;
		return sec;
	};

	/*
	 * if the content-length of the incoming swf data is known, use
	 *  it and write the file as-is in the http response
	 * 
	 * otherwise, decompress the swf and serve it that way, using
	 *  the uncompressed filesize from the swf header as the
	 *  content-length
	 * 
	 * why: some flashes have a preloader that depends on
	 *  content-length being correct (they check
	 *  loaderInfo.bytesLoaded against loaderInfo.bytesTotal)
	 * 
	 * the two modes work about the same, but serving the compressed
	 *  original may be better in case something depends on the
	 *  exact value of bytesTotal
	 */
	enum Mode
	{
		/*
		 * send the file unmodified as we get it from stdin.
		 */
		passthrough,
		/*
		 * unpack the file, if compressed. uncompressed files
		 * are sent as-is.
		 */
		unpack,
	}
	Mode mode = (contentLength != 0)
	/++/      ? Mode.passthrough
	/++/      : Mode.unpack;

	if (cmd.traceServer)
		if (contentLength)
			fprintf(stderr,
			    "flash2url: [%.4f] got content-length"~
			    " %llu, sending file as-is\n",
			    time(),
			    contentLength);
		else
			fprintf(stderr,
			    "flash2url: [%.4f] content-length unknown,"~
			    " sending decompressed file\n", time());

	/* if true, one of the write calls to the client failed and the
	   stream should be considered corrupt. */
	bool writeError;

	/* true if we've sent the first frame to the player. */
	bool firstFrameSent;

	/* holds data to be sent until we parse the first frame.
	   used while !firstFrameSent */
	auto bufferedData = appender!(ubyte[]);

	/* (checked against content-length) */
	ulong bytesWritten;

	scope trySendFirstFrame = ()
	{
		if (firstFrameSent)
			return;

		bool gotFirstFrame;
		for (SwfTagInfo tag; sr.nextTag(tag); /* empty */)
		{
			enum ShowFrame = 1;

			if (tag.code == ShowFrame)
			{
				gotFirstFrame = true;
				break;
			}
		}
		if (!gotFirstFrame)
			return;

		/* (somewhat inaccurate because of buffering) */
		if (cmd.traceServer)
			fprintf(stderr,
			    "flash2url: [%.4f] got first frame"~
			    " at %llu bytes\n",
			    time(),
			    g_flashData[].length);

		char[64] contentLengthBuf = void;
		snprintf(
		    contentLengthBuf.ptr,
		    contentLengthBuf.length,
		    "Content-Length: %llu\r\n",
		    contentLength);

		auto headerData =
		    "HTTP/1.1 200 OK\r\n"~
		    "Content-Type: application/x-shockwave-flash\r\n"~
		    contentLengthBuf.fromStringz~
		    "Connection: close\r\n"~
		    "\r\n";

		if (!write_full(client, headerData) ||
		    !write_full(client, bufferedData[]))
		{
			writeError = true;
			return;
		}

		firstFrameSent = true;

		bytesWritten += bufferedData[].length;
		bufferedData.clear();

		auto timeToFirstFrame = (MonoTime.currTime - startTime);
		if (timeToFirstFrame >= 10.seconds)
			fprintf(stderr,
			    "\a"~
			    "flash2url: to play the flash,"~
			    " click the url and press enter\n");
	};

	/* buffers or writes some bytes of the swf file according to
	   whether we already sent the first frame. */
	scope bufferOrWriteData = (scope const(ubyte)[] buf)
	{
		if (firstFrameSent)
			if (!writeError && write_full(client, buf))
				bytesWritten += buf.length;
			else
				writeError = true;
		else
			bufferedData ~= buf;
	};

	/* this callback gets an unpacked version of the flash */
	if (mode == Mode.unpack)
		sr.putDecompressed = bufferOrWriteData;

	bool tracePrinted10secTimeout;
	bool tracePrintedCompressionType;

	for (;;)
	{
		ubyte[16*1024] buf = void;
		ssize_t readrv;

		readrv = read(STDIN_FILENO, buf.ptr, buf.length);
		if (readrv < 0)
		{
			if (errno == EINTR)
				continue;
			perror("read");
			sr.putEndOfInput();
			break;
		}
		if (!readrv)
		{
			sr.putEndOfInput();
			break;
		}

		g_flashData ~= buf[0..readrv];

		if (0)
		if (cmd.traceServer)
			fprintf(stderr,
			    "flash2url: [%.4f] ... at %llu bytes\n",
			    time(),
			    g_flashData[].length);

		if (cmd.traceServer &&
		    !firstFrameSent &&
		    !tracePrinted10secTimeout &&
		    time() >= 10.0)
		{
			tracePrinted10secTimeout = true;
			fprintf(stderr,
			    "flash2url: [%.4f] still waiting for"~
			    " first frame at %llu bytes\n",
			    time(),
			    g_flashData[].length);
		}

		sr.put(buf[0..readrv]);

		/* Mode.unpack does this in .put() above */
		if (mode == Mode.passthrough)
			bufferOrWriteData(buf[0..readrv]);

		if (cmd.traceServer &&
		    !tracePrintedCompressionType &&
		    g_flashData[].length >= SwfHeader.sizeof)
		{
			tracePrintedCompressionType = true;
			fprintf(stderr,
			    "flash2url: [%.4f] compression type: ",
			    time());
			if (!sr.swfHeader.isValid)
				fprintf(stderr, "<invalid header>\n");
			else if (!sr.swfHeader.isCompressed)
				fprintf(stderr, "none\n");
			else if (sr.swfHeader.isZlibCompressed)
				fprintf(stderr, "zlib\n");
			else if (sr.swfHeader.isLzmaCompressed)
				fprintf(stderr, "lzma\n");
			else
				fprintf(stderr, "?\n");
		}

		if (!firstFrameSent)
		{
			/* use unpacked filesize as content-length */
			if (mode == Mode.unpack &&
			    !contentLength &&
			    sr.swfHeader.isValid)
			{
				contentLength = sr.swfHeader.fileSize;

				if (cmd.traceServer)
					fprintf(stderr,
					    "flash2url: [%.4f] got"~
					    " uncompressed"~
					    " content-length %llu"~
					    " from swf header\n",
					    time(),
					    contentLength);
			}

			trySendFirstFrame();
		}
	}

	if (cmd.traceServer)
		fprintf(stderr,
		    "flash2url: [%.4f] load finished at %llu bytes\n",
		    time(),
		    g_flashData[].length);

	trySendFirstFrame();

	if (!firstFrameSent)
	{
		if (cmd.traceServer)
			fprintf(stderr,
			    "flash2url: [%.4f] wasn't able to send"~
			    " anything!\n",
			    time());

		write_full(client,
		    "HTTP/1.1 500 Internal Server Error\r\n"~
		    "Content-Length: 0\r\n"~
		    "Connection: close\r\n"~
		    "\r\n"~
		    "");
	}

	/* check that content-length matches what we wrote */
	if (firstFrameSent &&
	    !writeError &&
	    bytesWritten != contentLength)
	{
		char[64] type = void;

		if (bytesWritten > contentLength)
			snprintf(
			    type.ptr,
			    type.length,
			    " (%llu extra)",
			    bytesWritten-contentLength);
		else
			snprintf(
			    type.ptr,
			    type.length,
			    " (%llu short)",
			    contentLength-bytesWritten);

		fprintf(stderr,
		    "flash2url: warning: sent content-length %llu"~
		    " but wrote %llu bytes%s\n",
		    contentLength,
		    bytesWritten,
		    type.ptr);
	}

	return true;
}

/* append "path" to "root" without letting it escape that directory */
string safeJoinPath(string root, string path)
{
	assert(root.length);
	return root~buildNormalizedPath("/", path);
}

unittest
{
	assert(safeJoinPath("hi", "/../bye") == "hi/bye");
	assert(safeJoinPath("hi", "bye") == "hi/bye");
	assert(safeJoinPath("hi", "/a//b") == "hi/a/b");
}

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

unittest
{
	HttpRequestHead h;
	bool ok;

	/* thought: it's missing a way to return unparsed extra bytes.
	   not like we'd need that for anything. */

	ok = h.parse(cast(ubyte[])"");
	assert(!ok);

	/* basic, no headers */
	ok = h.parse(cast(ubyte[])"GET / HTTP/1.0");
	assert(!ok);
	ok = h.parse(cast(ubyte[])"GET / HTTP/1.0\r\n");
	assert(!ok);
	ok = h.parse(cast(ubyte[])"GET / HTTP/1.0\r\n\r\n");
	assert(ok);
	assert(h.method == "GET");
	assert(h.url == "/");
	assert(h.protocol == "HTTP/1.0");
	assert(h.headers == []);

	/* basic, one header */
	ok = h.parse(
	    cast(ubyte[])"GET / HTTP/1.0\r\nUser-Agent: hello");
	assert(!ok);
	ok = h.parse(
	    cast(ubyte[])"GET / HTTP/1.0\r\nUser-Agent: hello\r\n");
	assert(!ok);
	ok = h.parse(
	    cast(ubyte[])"GET / HTTP/1.0\r\nUser-Agent: hello\r\n\r\n");
	assert(ok);
	assert(h.method == "GET");
	assert(h.url == "/");
	assert(h.protocol == "HTTP/1.0");
	assert(h.headers == [["User-Agent", "hello"]]);

	/* real request */
	/* note: the value of User-Agent has a trailing space.
	   at present we trim that */
	ok = h.parse(cast(ubyte[])(
	    "GET /file.swf HTTP/1.1\r\n"~
	    "Host: 127.0.0.1:57821\r\n"~
	    "Accept-Encoding: deflate, gzip, br, zstd\r\n"~
	    "Accept: text/xml, application/xml, application/xhtml+xml,"~
	    " text/html;q=0.9, text/plain;q=0.8, text/css, image/png,"~
	    " image/jpeg, image/gif;q=0.8,"~
	    " application/x-shockwave-flash, video/mp4;q=0.9,"~
	    " flv-application/octet-stream;q=0.8, video/x-flv;q=0.7,"~
	    " audio/mp4, application/futuresplash, */*;q=0.5\r\n"~
	    "User-Agent: Adobe Flash Player \r\n"~
	    "x-flash-version: 32,0,0,465\r\n"~
	    "Connection: Keep-Alive\r\n"~
	    "\r\n"~
	    ""));
	assert(ok);
	assert(h.method == "GET");
	assert(h.url == "/file.swf");
	assert(h.protocol == "HTTP/1.1");
	assert(h.headers.length);
	assert(h.headers[0][0] == "Host");
	assert(h.headers[0][1] == "127.0.0.1:57821");
	assert(h.headers.length == 6);
	assert(h.headers[1] == ["Accept-Encoding", "deflate, gzip,"~
	    " br, zstd"]);
	assert(h.headers[2] == ["Accept", "text/xml, application/xml,"~
	    " application/xhtml+xml, text/html;q=0.9,"~
	    " text/plain;q=0.8, text/css, image/png, image/jpeg,"~
	    " image/gif;q=0.8, application/x-shockwave-flash,"~
	    " video/mp4;q=0.9, flv-application/octet-stream;q=0.8,"~
	    " video/x-flv;q=0.7, audio/mp4, application/futuresplash,"~
	    " */*;q=0.5"]);
	assert(h.headers[3] == ["User-Agent", "Adobe Flash Player"]);
	assert(h.headers[4] == ["x-flash-version", "32,0,0,465"]);
	assert(h.headers[5] == ["Connection", "Keep-Alive"]);

	/* bad utf-8 does not break it, text is passed as-is */
	ok = h.parse(cast(ubyte[])(
	    "GET /%ff\xff HTTP/1.0\r\n"~
	    "User-Agent: x%ff\xffy\r\n"~
	    "\r\n"));
	assert(ok);
	assert(h.url == "/%ff\xff");
	assert(h.headers == [["User-Agent", "x%ff\xffy"]]);

	/* \r is optional btw */
	ok = h.parse(
	    cast(ubyte[])"GET /%ff\xff HTTP/1.0\nUser-Agent: hi\n\n");
	assert(ok);
	assert(h.url == "/%ff\xff");
	assert(h.headers == [["User-Agent", "hi"]]);
}

bool write_full(int fd, scope const(void)[] data) nothrow @nogc
{
	const void[] origdata = data;

	while (data.length)
	{
		ssize_t rv = write(
		    fd,
		    data.ptr,
		    (data.length <= ssize_t.max)
		     ? data.length
		     : ssize_t.max);

		if (rv < 0)
		{
			if (errno == EINTR)
				continue;

			//debug(server)
			{
				int err = errno;
				fprintf(stderr,
				    "write_full: got errno %d on fd %d"~
				    " with %zu/%zu bytes written\n",
				    err,
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

bool read_full(int fd, scope void[] data) nothrow @nogc
{
	const void[] origdata = data;

	while (data.length)
	{
		ssize_t rv = read(
		    fd,
		    data.ptr,
		    (data.length <= ssize_t.max)
		     ? data.length
		     : ssize_t.max);

		if (rv < 0)
		{
			if (errno == EINTR)
				continue;

			//debug(server)
			{
				int err = errno;
				fprintf(stderr,
				    "read_full: got errno %d on fd %d"~
				    " with %zu/%zu bytes read\n",
				    err,
				    fd,
				    (origdata.length - data.length),
				    origdata.length);
				errno = err;
			}

			return false;
		}

		// end of file?
		if (!rv)
		{
			// partial read?
			if (data.ptr != origdata.ptr)
				errno = EIO;
			else
				errno = 0;

			//debug(server)
			{
				int err = errno;
				fprintf(stderr,
				    "read_full: got EOF on fd %d with"~
				    " %zu/%zu bytes read\n",
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
