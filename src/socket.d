module flash2url.socket;

import core.sys.posix.unistd;
import std.exception;

public import core.sys.posix.netdb;
public import core.sys.posix.netinet.tcp;

version(linux)
	enum SOCK_CLOEXEC = 0x80000;

version(FreeBSD)
	enum SOCK_CLOEXEC = 0x10000000;

enum SOL_TCP = IPPROTO_TCP;

extern(C) int accept4(int, sockaddr*, socklen_t*, int) nothrow @nogc;

/**
 * make a tcp server on 127.0.0.1 + random port
 */
int makeServer(const(char)* addrStr, out ushort portOut)
{
	sockaddr_in sin = {
		sin_family: AF_INET,
		sin_port: 0,
		sin_addr: {
			s_addr: inet_addr(addrStr),
		},
	};
	addrinfo addr = {
		ai_family: sin.sin_family,
		ai_socktype: SOCK_STREAM,
		ai_protocol: IPPROTO_TCP,
		ai_addrlen: sin.sizeof,
		ai_addr: cast(sockaddr*)&sin,
	};

	version(CRuntime_Glibc)
		int fd = socket(addr.ai_family, addr.ai_socktype|SOCK_CLOEXEC, addr.ai_protocol);
	else
	{
		import core.sys.posix.fcntl;
		int fd = socket(addr.ai_family, addr.ai_socktype, addr.ai_protocol);
		if (fd >= 0)
			fcntl(fd, F_SETFD, fcntl(fd, F_GETFD, 0)|FD_CLOEXEC);
	}

	if (fd == -1)
	{
		throw new ErrnoException("socket");
	}

	scope(failure)
	{
		close(fd);
	}

	const int yes = 1;
	if (setsockopt(fd, SOL_TCP, TCP_NODELAY, &yes, yes.sizeof) == -1)
	{
		throw new ErrnoException("setsockopt TCP_NODELAY");
	}

	if (bind(fd, addr.ai_addr, addr.ai_addrlen) == -1)
	{
		throw new ErrnoException("bind");
	}

	// find out what port we were assigned
	socklen_t len = sin.sizeof;
	if (getsockname(fd, cast(sockaddr*)&sin, &len) == -1)
	{
		throw new ErrnoException("getsockname");
	}

	enum backlog = 16;

	if (listen(fd, backlog) == -1)
	{
		throw new ErrnoException("listen");
	}

	portOut = ntohs(sin.sin_port);

	return fd;
}
