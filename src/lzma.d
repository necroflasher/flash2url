/**
 * based on:
 * https://github.com/rtbo/squiz-box/blob/main/src/squiz_box/c/lzma.d
 */
module flash2url.lzma;

enum lzma_reserved_enum
{
	LZMA_RESERVED_ENUM = 0,
}

enum lzma_ret
{
	OK                = 0,
	STREAM_END        = 1,
	NO_CHECK          = 2,
	UNSUPPORTED_CHECK = 3,
	GET_CHECK         = 4,
	MEM_ERROR         = 5,
	MEMLIMIT_ERROR    = 6,
	FORMAT_ERROR      = 7,
	OPTIONS_ERROR     = 8,
	DATA_ERROR        = 9,
	BUF_ERROR         = 10,
	PROG_ERROR        = 11,
}

enum lzma_action
{
	RUN          = 0,
	SYNC_FLUSH   = 1,
	FULL_FLUSH   = 2,
	FINISH       = 3,
	FULL_BARRIER = 4,
}

struct lzma_allocator;
struct lzma_internal;

struct lzma_stream
{
	const(ubyte)*          next_in;
	size_t                 avail_in;
	ulong                  total_in;

	ubyte*                 next_out;
	size_t                 avail_out;
	ulong                  total_out;

	const(lzma_allocator)* allocator;

	lzma_internal*         internal;

	void*                  reserved_ptr1;
	void*                  reserved_ptr2;
	void*                  reserved_ptr3;
	void*                  reserved_ptr4;
	ulong                  reserved_int1;
	ulong                  reserved_int2;
	size_t                 reserved_int3;
	size_t                 reserved_int4;
	lzma_reserved_enum     reserved_enum1;
	lzma_reserved_enum     reserved_enum2;
}

extern(C) lzma_ret lzma_alone_decoder(lzma_stream* strm, ulong memlimit) nothrow @nogc;
extern(C) lzma_ret lzma_code(lzma_stream* strm, lzma_action action) nothrow @nogc;
extern(C) void lzma_end(lzma_stream* strm) nothrow @nogc;
