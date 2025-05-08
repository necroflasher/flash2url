module flash2url.swfparser;

import core.stdc.stdio;
import etc.c.zlib;
import std.array;
import std.string;
import flash2url.lzma;

/*
 * basic swf reader for flash2url, just complete enough to make the thing work
 * 
 * specifically it needs to
 * - parse tags
 * - tell when there's an error in the file (caller should give up reading tags)
 */

final class SwfReader
{
	enum State
	{
		readSwfHeader,
		readMovieHeader,
		readSwfData,
		finished,
	}

	State state;
	bool error;
	bool endOfInput;

	ubyte[] fileData;
	Appender!(ubyte[]) swfData;
	size_t swfDataPos;

	SwfHeader swfHeader;
	MovieHeader movieHeader;

	z_stream zs;
	lzma_stream lz;

	void delegate(scope const(ubyte)[]) putDecompressed;

	~this() nothrow @nogc
	{
		// this is harmless if never inited
		inflateEnd(&zs);
		lzma_end(&lz);
	}

	/**
	 * feed more data into the reader
	 */
	void put(scope const(ubyte)[] data)
	{
		if (state == State.readSwfHeader)
		{
			putHeaderData(data);
			return;
		}

		if (
			state == State.readMovieHeader ||
			state == State.readSwfData)
		{
			putSwfData(data);
			return;
		}
	}

	void putEndOfInput()
	{
		endOfInput = true;

		if (state != State.readSwfData)
		{
			error = true;
			fprintf(stderr, "flash2url: swfparser: parsing incomplete\n");
		}
	}

	void putHeaderData(scope const(ubyte)[] data)
	{
		fileData ~= data;

		if (fileData.length < SwfHeader.sizeof)
			return;

		swfHeader = *cast(SwfHeader*)&fileData[0];

		enum lzmaExtraSize = 4+1+4;
		if (
			swfHeader.isLzmaCompressed &&
			fileData.length < SwfHeader.sizeof+lzmaExtraSize)
		{
			return;
		}

		if (!swfHeader.isValid)
		{
			error = true;
			fprintf(stderr, "flash2url: swfparser: invalid header\n");
		}

		if (putDecompressed)
		{
			SwfHeader tmp = swfHeader;
			tmp.signature[0] = 'F';
			putDecompressed(tmp.asBytes);
		}

		fileData = fileData[SwfHeader.sizeof..$];

		if (swfHeader.isZlibCompressed)
		{
			if (int zerr = inflateInit(&zs))
			{
				fprintf(stderr, "inflateInit: %s (%d)\n", zError(zerr), zerr);
				assert(0);
			}
		}
		else if (swfHeader.isLzmaCompressed)
		{
			lzma_ret ret = lzma_alone_decoder(&lz, /* memoryLimit */ ulong.max);
			if (ret != lzma_ret.OK)
			{
				fprintf(stderr, "lzma_alone_decoder: %s (%d)\n", lzerror(ret).toStringz, ret);
				assert(0);
			}

			fileData = fileData[4..$]; // uint lzmaBodySize

			struct LzmaHeader
			{
			align(1):
				union
				{
					struct
					{
						ubyte properties;
						uint  dictionarySize;
					}
					ubyte[5] five;
				}
				ulong uncompressedSize;
			}
			LzmaHeader lzmaHeader;
			lzmaHeader.five = fileData[0..5];
			lzmaHeader.uncompressedSize = swfHeader.fileSize-8;
			fileData = fileData[5..$];

			ubyte[] headerBytes = lzmaHeader.asBytes;
			ret = unlz(lz, headerBytes, (scope _) { return lzma_ret.OK; });
			if (ret != lzma_ret.OK)
			{
				error = true;
				fprintf(stderr, "lzma header error: %s (%d)\n", lzerror(ret).toStringz, ret);
			}
		}

		state = State.readMovieHeader;
		if (fileData.length)
		{
			putSwfData(fileData);
			fileData = null;
		}
	}

	void putSwfData(scope const(ubyte)[] data)
	{
		scope xput = (scope const(ubyte)[] buf)
		{
			swfData ~= buf;
			if (putDecompressed)
				putDecompressed(buf);
		};

		if (!swfHeader.isCompressed)
		{
			xput(data);
		}
		else if (swfHeader.isZlibCompressed)
		{
			int zerr = unzlib(zs, data, (scope buf)
			{
				xput(buf);
				return 0;
			});
			if (zerr != Z_OK)
			{
				error = true;
				fprintf(stderr, "zlib decompression error: %s (%d)\n", zError(zerr), zerr);
			}
		}
		else if (swfHeader.isLzmaCompressed)
		{
			lzma_ret ret = unlz(lz, data, (scope buf)
			{
				xput(buf);
				return lzma_ret.OK;
			});
			if (ret != lzma_ret.OK)
			{
				error = true;
				fprintf(stderr, "lzma decompression error: %s (%d)\n", lzerror(ret).toStringz, ret);
			}
		}
		else
		{
			assert(0);
		}

		if (state == State.readMovieHeader)
		{
			scope br = new SwfBitReader(swfData[]);

			movieHeader.display = br.readRect();
			movieHeader.frameRate = br.readFixed(8, 8);
			movieHeader.frameCount = br.readUI(16);

			if (!br.overflow)
			{
				swfDataPos = br.curByte;
				state = State.readSwfData;
			}
		}
	}

	/**
	 * try to advance to the next tag
	 */
	bool nextTag(out SwfTagInfo tagOut)
	{
		if (state != State.readSwfData)
		{
			return false;
		}

		scope br = new SwfBitReader( (swfData[])[swfDataPos..$] );

		if (!br.totalBits && endOfInput)
		{
			// some files end without an end tag
			state = State.finished;
			return false;
		}

		uint x = br.readUI(16);
		uint tag = x >> 6;
		size_t length = x & 0b111111;

		if (length == 0x3f)
		{
			length = br.readUI(32);
		}

		const(ubyte)[] tagData = br.readBytesNoCopy(length);

		if (br.overflow)
		{
			if (endOfInput)
			{
				error = true;
				state = State.finished;
			}
			return false;
		}

		tagOut.code = tag;
		tagOut.data = tagData;

		swfDataPos += br.curByte;

		return true;
	}
}

ref inout(ubyte)[T.sizeof] asBytes(T)(return ref inout(T) val)
{
	return *cast(ubyte[T.sizeof]*)&val;
}

int unzlib(ref z_stream zs, ref inout(ubyte)[] inbuf, scope int delegate(scope ubyte[]) cb)
{
	ubyte[4*16*1024] outbuf = void;

	assert(inbuf.length);

	for (;;)
	{
		zs.next_out = outbuf.ptr;
		zs.avail_out = outbuf.length;

		zs.next_in = inbuf.ptr;
		zs.avail_in = cast(uint)inbuf.length;

		if (inbuf.length > uint.max)
			zs.avail_in = uint.max;

		int zerr = inflate(&zs, /* flush */ false);

		size_t inlen = (zs.next_in - inbuf.ptr);
		size_t outlen = (zs.next_out - outbuf.ptr);

		inbuf = inbuf[inlen..$];

		// cancelled
		if (int uerr = cb(outbuf[0..outlen]))
			return uerr;

		// error
		if (zerr != Z_OK && zerr != Z_STREAM_END)
			return zerr;

		// end of output
		if (zerr == Z_STREAM_END)
			return Z_OK;

		// end of input (need more data)
		if (!inbuf.length)
		{
			inbuf = null;
			return Z_OK;
		}
	}
}

lzma_ret unlz(ref lzma_stream zs, ref inout(ubyte)[] inbuf, scope lzma_ret delegate(scope ubyte[]) cb)
{
	ubyte[4*16*1024] outbuf = void;

	assert(inbuf.length);

	for (;;)
	{
		zs.next_out = outbuf.ptr;
		zs.avail_out = outbuf.length;

		zs.next_in = inbuf.ptr;
		zs.avail_in = inbuf.length;

		lzma_ret ret = lzma_code(&zs, lzma_action.RUN);

		size_t inlen = (zs.next_in - inbuf.ptr);
		size_t outlen = (zs.next_out - outbuf.ptr);

		inbuf = inbuf[inlen..$];

		// cancelled
		if (lzma_ret uret = cb(outbuf[0..outlen]))
			return uret;

		// error
		if (ret != lzma_ret.OK && ret != lzma_ret.STREAM_END)
			return ret;

		// end of output
		if (ret == lzma_ret.STREAM_END)
			return lzma_ret.OK;

		// end of input (need more data)
		if (!inbuf.length)
		{
			inbuf = null;
			return lzma_ret.OK;
		}
	}
}

string lzerror(lzma_ret ret)
{
	// descriptions from <lzma/base.h>
	switch (ret)
	{
		case lzma_ret.OK:
			return "Operation completed successfully";
		case lzma_ret.STREAM_END:
			return "End of stream was reached";
		case lzma_ret.NO_CHECK:
			return "Input stream has no integrity check";
		case lzma_ret.UNSUPPORTED_CHECK:
			return "Cannot calculate the integrity check";
		case lzma_ret.GET_CHECK:
			return "Integrity check type is now available";
		case lzma_ret.MEM_ERROR:
			return "Cannot allocate memory";
		case lzma_ret.MEMLIMIT_ERROR:
			return "Memory usage limit was reached";
		case lzma_ret.FORMAT_ERROR:
			return "File format not recognized";
		case lzma_ret.OPTIONS_ERROR:
			return "Invalid or unsupported options";
		case lzma_ret.DATA_ERROR:
			return "Data is corrupt";
		case lzma_ret.BUF_ERROR:
			return "No progress is possible";
		case lzma_ret.PROG_ERROR:
			return "Programming error";
		default:
			char[64] buf = void;
			snprintf(buf.ptr, buf.length, "%d", ret);
			return buf.fromStringz.idup;
	}
}

final class SwfBitReader
{
	const(ubyte)[] data;
	ulong curBit;
	bool overflow;

	this(ubyte[] data_)
	{
		data = data_;
	}

	pragma(inline, true)
	ulong totalBits() const
	{
		return cast(ulong)data.length*8;
	}

	pragma(inline, true)
	ulong curByte() const
	{
		return curBit/8;
	}

	bool checkOverflow(ulong add)
	{
		ulong rem = (totalBits - curBit);
		if (add > rem)
		{
			curBit = totalBits;
			overflow = true;
			return true;
		}
		return false;
	}

	/**
	 * align reading to the next byte (call after finishing reading bit values)
	 */
	void byteAlign()
	{
		if (size_t rem = curBit % 8)
		{
			size_t add = (8 - rem);
			if (!checkOverflow(add))
				curBit += add;
		}
	}

	/**
	 * read an unsigned bit value
	 */
	uint readUB(uint numbits)
	{
		if (checkOverflow(numbits))
			return 0;

		uint rv;
		foreach (i; 0..numbits)
		{
			size_t offsetIntoByte = curBit % 8;

			size_t shift = 7-offsetIntoByte;

			rv <<= 1;
			rv |= (data[curByte] >> shift) & 1;

			curBit++;
		}
		return rv;
	}

	/**
	 * read a signed bit value
	 */
	int readSB(uint numbits)
	{
		uint r = readUB(numbits);

		static auto toSigned(U)(U value, uint numbits)
		if (__traits(isUnsigned, U))
		{
			static if (is(U == ubyte)) alias S = byte;
			else static if (is(U == ushort)) alias S = short;
			else static if (is(U == uint)) alias S = int;
			else static if (is(U == ulong)) alias S = long;
			else static assert(0, "no corresponding signed type for '"~U.stringof);

			const U topbit = cast(U)( U(1) << (numbits-1) );
			if (value & topbit)
			{
				value ^= topbit; // remove sign bit
				value = cast(U)(topbit - value); // reverse value
				value = cast(U)-value; // negate
			}

			return cast(S)value;
		}

		return toSigned(r, numbits);
	}

	Rect readRect()
	{
		Rect rv;
		if (uint numbits = readUB(5))
		{
			rv.xmin = readSB(numbits);
			rv.xmax = readSB(numbits);
			rv.ymin = readSB(numbits);
			rv.ymax = readSB(numbits);
		}
		return rv;
	}

	double readFixed(uint bits1, uint bits2)
	{
		// same as "ReadUI(bits1+bits2) >> bits2" but as a float
		return readUI(bits1+bits2) / cast(double)(1<<bits2);
	}

	/**
	 * read an unsigned integer value (byte-aligned)
	 */
	uint readUI(uint numbits)
	{
		byteAlign();
		if (checkOverflow(numbits))
			return 0;

		uint rv;
		final switch (numbits)
		{
			case 8:
				rv = *cast(ubyte*)&data[curByte];
				break;
			case 16:
				rv = *cast(ushort*)&data[curByte];
				break;
			case 32:
				rv = *cast(uint*)&data[curByte];
				break;
		}
		curBit += numbits;
		return rv;
	}

	const(ubyte)[] readBytesNoCopy(size_t count)
	{
		byteAlign();
		if (checkOverflow(cast(ulong)count*8))
			return null;

		auto rv = data[curByte..curByte+count];
		curBit += cast(ulong)count*8;
		return rv;
	}
}

struct SwfTagInfo
{
	uint code;
	const(ubyte)[] data;
}

struct SwfHeader
{
	char[3] signature;
	ubyte swfVersion;
	uint fileSize; /// total size of the uncompressed .swf, includes this header

	bool isValid()
	{
		switch (signature)
		{
			case "FWS":
			case "CWS":
			case "ZWS":
				return true;
			default:
				return false;
		}
	}

	bool isCompressed()
	{
		return signature[0] != 'F';
	}

	bool isZlibCompressed()
	{
		return signature[0] == 'C';
	}

	bool isLzmaCompressed()
	{
		return signature[0] == 'Z';
	}
}

struct MovieHeader
{
	Rect   display;
	double frameRate;
	uint   frameCount;
}

struct Rect
{
	int xmin;
	int xmax;
	int ymin;
	int ymax;

	double pixelWidth()
	{
		return (xmax - xmin) / 20.0;
	}

	double pixelHeight()
	{
		return (ymax - ymin) / 20.0;
	}
}
