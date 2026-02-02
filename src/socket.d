module flash2url.socket;

import core.stdc.stdio;
import core.sys.posix.fcntl;
import core.sys.posix.netdb;
import core.sys.posix.netinet.tcp : TCP_NODELAY;
import core.sys.posix.unistd;

version(CRuntime_Glibc)
{
	/* /usr/include/x86_64-linux-gnu/bits/socket_type.h */
	enum SOCK_CLOEXEC = 0x80000;
}

version(FreeBSD)
	enum SOCK_CLOEXEC = 0x10000000;

/* glibc: /usr/include/arpa/inet.h */
private extern(C) int inet_aton(const(char)* cp, in_addr* inp);

/* glibc: /usr/include/netinet/tcp.h */
private enum SOL_TCP = IPPROTO_TCP;

/* glibc: /usr/include/x86_64-linux-gnu/sys/socket.h */
extern(C) int accept4(
    int sockfd, sockaddr* addr, socklen_t* addrlen, int flags);

/**
 * make a tcp server on the given address + a random port
 */
bool makeServer(const(char)* addrStr, out ushort portOut, out int fdOut)
{
	sockaddr_in addr;
	socklen_t len;
	int fd;
	int optval;

	if (!inet_aton(addrStr, &addr.sin_addr))
	{
		fprintf(stderr, "inet_aton: invalid ip address\n");
		return false;
	}

	fd = socket(AF_INET, SOCK_STREAM|SOCK_CLOEXEC, IPPROTO_TCP);

	if (fd < 0)
	{
		perror("socket");
		return false;
	}

	optval = 1;
	if (setsockopt(
	    fd, SOL_TCP, TCP_NODELAY, &optval, optval.sizeof) < 0)
	{
		perror("setsockopt TCP_NODELAY");
		close(fd);
		return false;
	}

	addr.sin_family = AF_INET;
	if (bind(fd, cast(sockaddr*)&addr, addr.sizeof) < 0)
	{
		perror("bind");
		close(fd);
		return false;
	}

	/* find out what port we were assigned */
	len = addr.sizeof;
	if (getsockname(fd, cast(sockaddr*)&addr, &len) < 0)
	{
		perror("getsockname");
		close(fd);
		return false;
	}

	enum backlog = 16;
	if (listen(fd, backlog) < 0)
	{
		perror("listen");
		close(fd);
		return false;
	}

	portOut = ntohs(addr.sin_port);
	fdOut = fd;

	return true;
}
