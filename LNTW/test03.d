import std.format;
import std.stdio;

void main()
{
}


// use libiconv for debugging
version (FreeBSD) debug = WITH_LIBICONV;


////////////////////////////////////////////////////////////////////////////////
// LockingNativeTextWriter
////////////////////////////////////////////////////////////////////////////////

import core.stdc.wchar_ : fwide;

import std.algorithm;
import std.contracts;
import std.traits;


version (Windows) private
{
    import core.sys.windows.windows;
    import std.windows.syserror;

    version (DigitalMars)
    {
        extern(C) extern __gshared HANDLE[_NFILE] _osfhnd;
        @safe HANDLE peekHandle(FILE* f) { return _osfhnd[f._file]; }

        version = LNTW_useWriteConsole;
    }

    immutable typeof(&WriteConsoleW) indirectWriteConsoleW;
    static this()
    {
        indirectWriteConsoleW = cast(typeof(indirectWriteConsoleW))
            GetProcAddress(GetModuleHandleA("kernel32.dll"),
                    "WriteConsoleW");
    }
}


/**
 * An $(D output range) that locks the file and provides writing to the
 * file in the multibyte encoding of the current locale.
 */
struct LockingNativeTextWriter
{
    /**
     * Constructs a $(D LockingNativeTextWriter) object.
     *
     * Params:
     *   file =
     *     An opened $(D File) to write in.
     *
     *   replacement =
     *     A valid multibyte string to use when a Unicode text
     *     cannot be represented in the current locale.  $(D
     *     LockingNativeTextWriter) will throw an exception on any
     *     non-representable character if this parameter is $(D null).
     */
    this(File file, immutable(char)[] replacement = null)
    {
        enforce(file.isOpen, "Attempted to write to a closed file");
        swap(file_, file);

        auto fp = file_.getFP();
        FLOCK(fp);
        auto handle = cast(_iobuf*) fp;

        useWide_ = (fwide(fp, 0) > 0);

        //
        bool isConsole;

        version (LNTW_useWriteConsole)
        {{
            HANDLE console = peekHandle(fp);
            DWORD  dummy;

            if (GetConsoleMode(console, &dummy))
            {
                isConsole = true;

                if (indirectWriteConsoleW !is null &&
                    indirectWriteConsoleW(console, "\0"w.ptr, 0, null, null))
                {
                    useWinConsole_ = true;
                    fflush(fp); // need to sync
                    return;
                }
            }
        }}

        // This should be in File.open() for tracking convertion state.
        if (useWide_)
            wideWriter_ =
                WideWriter(UnsharedWidePutter(handle), replacement);
        else
            narrowWriter_ =
                NativeWriter(UnsharedNarrowPutter(handle), replacement);
    }

    this(this)
    {
        FLOCK(file_.p.handle);
    }

    ~this()
    {
        FUNLOCK(file_.p.handle);
    }

    /+
    // @@@BUG@@@ swap() invokes copy constructor
    void opAssign(LockingNativeTextWriter rhs)
    {
        swap(this, rhs);
    }
    +/


    //----------------------------------------------------------------//
    // range primitive implementations
    //----------------------------------------------------------------//

    /// Range primitive implementations.
    void put(S)(S writeme)
        if (isSomeString!(S))
    {
        version (LNTW_useWriteConsole)
        {
            if (useWinConsole_)
                return putConsoleW(peekHandle(file_.getFP()), writeme);
        }

        if (useWide_)
            wideWriter_.put(writeme);
        else
            narrowWriter_.put(writeme);
    }

    /// ditto
    void put(C : dchar)(C c)
    {
        version (Windows)
        {
            if (useWinConsole_)
                return putConsoleW(osfhnd(file_.getFP()), c);
        }

        if (useWide_)
            wideWriter_.put(c);
        else
            narrowWriter_.put(c);
    }


    //----------------------------------------------------------------//
    // WriteConsoleW
    //----------------------------------------------------------------//
private:
    version (LNTW_useWriteConsole)
    {
        enum size_t BUFFER_SIZE = 80;

        void putConsoleW(HANDLE console, in wchar[] str)
        {
            for (const(wchar)[] outbuf = str; outbuf.length > 0; )
            {
                DWORD nwritten;

                if (!indirectWriteConsoleW(console,
                        str.ptr, str.length, &nwritten, null))
                    throw new Exception(
                        toWindowsErrorString(GetLastError()),
                        __FILE__, __LINE__);
                outbuf = outbuf[nwritten .. $];
            }
        }

        void putConsoleW(HANDLE console, dchar c)
        {
            wchar[2] wbuf = void;
            const wcLen = encode(wbuf, c);
            putConsoleW(console, wbuf[0 .. wcLen]);
        }

        void putConsoleW(HANDLE console, in char[] str)
        {
            for (const(char)[] inbuf = str; inbuf.length > 0; )
            {
                wchar[BUFFER_SIZE] wbuf = void;
                const wsLen = inbuf.convert(wbuf);
                putConsoleW(console, wbuf[0 .. wsLen]);
            }
        }

        void putConsoleW(HANDLE console, in dchar[] str)
        {
            for (const(dchar)[] inbuf = str; inbuf.length > 0; )
            {
                wchar[BUFFER_SIZE] wbuf = void;
                const wsLen = inbuf.convert(wbuf);
                putConsoleW(console, wbuf[0 .. wsLen]);
            }
        }
    } // Windows


    //----------------------------------------------------------------//
private:
    File file_;     // the underlying File object
    int  useWide_;  // whether to use wide functions

    version (Windows)
        bool useWinConsole_;

    // XXX These should be in File.Impl for tracking the convertion state.
    alias .NativeWriter!(UnsharedNarrowPutter) NativeWriter;
    alias .WideWriter!(UnsharedWidePutter) WideWriter;
    NativeWriter narrowWriter_;
    WideWriter   wideWriter_;
}


// internally used to write multibyte character to FILE*
private struct UnsharedNarrowPutter
{
    _iobuf* handle_;

    void put(in char[] mbs)
    {
        size_t nwritten = fwrite(
                mbs.ptr, 1, mbs.length, cast(shared) handle_);
        errnoEnforce(nwritten == mbs.length);
    }
}

// internally used to write wide character to FILE*
private struct UnsharedWidePutter
{
    _iobuf* handle_;

    void put(wchar_t wc)
    {
        auto stat = FPUTWC(wc, handle_);
        errnoEnforce(stat != -1);
    }

    void put(in wchar_t[] wcs)
    {
        foreach (wchar_t wc; wcs)
            FPUTWC(wc, handle_);
        errnoEnforce(ferror(cast(shared) handle_) == 0);
    }
}


////////////////////////////////////////////////////////////////////////////////
// Unicode to locale-native encoding converter
////////////////////////////////////////////////////////////////////////////////

import std.algorithm;
import std.contracts;
import std.range;
import std.utf;

import core.stdc.errno;
import core.stdc.locale;
import core.stdc.string;
//import core.stdc.wchar_;

version (Windows)
{
    import core.sys.windows.windows;

    enum DWORD CP_UTF8 = 65001;
}
else version (Posix)
{
    //import core.sys.posix.iconv;
    //import core.sys.posix.locale;
    //import core.sys.posix.langinfo;
}


version (unittest) import std.array : appender;


// Performance configuration
private enum BUFFER_SIZE : size_t
{
    mchars = 160,
    chars  = 160,
    wchars =  80,
    dchars =  80,
}
static assert(BUFFER_SIZE.mchars >= 2*MB_LEN_MAX);


//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://
// platform-dependent features
//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://

version (Windows)
{
    version = WCHART_WCHAR;
}
else version (linux)
{
    version = WCHART_DCHAR;
    version = HAVE_MBSTATE;
    version = HAVE_ICONV;
    version = HAVE_MULTILOCALE;
}
else version (OSX)
{
    version = WCHART_DCHAR;
    version = HAVE_MBSTATE;
    version = HAVE_ICONV;
    version = HAVE_MULTILOCALE;
}
else version (FreeBSD)
{
    version = HAVE_MBSTATE;
}
else version (Solaris)
{
    version = HAVE_MBSTATE;
    version = HAVE_ICONV;
}
else static assert(0);

version (WCHART_WCHAR) version = WCHART_UNICODE;
version (WCHART_DCHAR) version = WCHART_UNICODE;

debug (WITH_LIBICONV)
{
    version = HAVE_ICONV;
    pragma(lib, "iconv");
}


//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://
// locale information at program startup
//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://

private
{
    version (Windows)
    {
        // ACP at program startup.
        immutable DWORD initialACP;
    }

    version (Posix)
    {
        // The value of the CODESET langinfo in zero-terminated ASCII string.
        immutable string initialCodesetz;
    }

    version (HAVE_MULTILOCALE)
    {
        // A hard copy of a locale_t object corresponding to initialCTYPEz.
        // This object MUST NOT be freed nor modified.
        shared locale_t initialLocaleCTYPE;
    }
}

static this()
{
    string ctypez;

    if (auto ctype = setlocale(LC_CTYPE, ""))
        ctypez = ctype[0 .. strlen(ctype) + 1].idup;
    else
        ctypez = "C\0";
    assert(ctypez.length > 0 && ctypez[$ - 1] == '\0');

    version (Windows)
    {
        initialACP = GetACP();
    }

    version (Posix)
    {
        if (auto codeset = nl_langinfo(CODESET))
            initialCodesetz = codeset[0 .. strlen(codeset) + 1].idup;
        else
            initialCodesetz = "US-ASCII\0";
        assert(initialCodesetz.length > 0 && initialCodesetz[$ - 1] == '\0');
    }

    version (HAVE_MULTILOCALE)
    {
        if (auto newLoc = newlocale(LC_CTYPE_MASK, ctypez.ptr, null))
            initialLocaleCTYPE = newLoc;
        else
            initialLocaleCTYPE = LC_GLOBAL_LOCALE;
        assert(initialLocaleCTYPE != null);
    }

    // revert to the default
    setlocale(LC_CTYPE, "C");
}


//----------------------------------------------------------------------------//
// NativeWriter : converts UTF to environment-specific multibyte encoding
//----------------------------------------------------------------------------//

// Determine a thread-safe mean to convert UTF to multibyte encoding.
version (Windows)
{
    // WideCharToMultiByte
    version = NativeWriter_withWinNLS;
    version = NativeWriter_preferWstring;
}
else
{
    version (WCHART_DCHAR) version (HAVE_MBSTATE) version (HAVE_MULTILOCALE)
    {
        // uselocale + mbstate_t + wcrtomb
        version = NativeWriter_withMultiLocale;
        version = NativeWriter_preferDstring;
    }

    version (NativeWriter_withMultiLocale)
    {
    }
    else version (HAVE_ICONV)
    {
        // iconv
        version = NativeWriter_withIconv;
        version = NativeWriter_preferDstring;

        version (LittleEndian)
        {
            private enum ICONV_DSTRING = "UTF-32LE";
        }
        else version (BigEndian)
        {
            private enum ICONV_DSTRING = "UTF-32BE";
        }
    }
}


/**
 * An output range that converts UTF string or Unicode code point to the
 * corresponding multibyte character sequence in the native multibyte
 * encoding.  The multibyte string is written to another output range
 * $(D Sink).
 */
struct NativeWriter(Sink)
    if (isOutputRange!(Sink, char[]))
{
    /**
     * Constructs a $(D NativeWriter) object.
     *
     * Params:
     *   sink =
     *      An output range of type $(D Sink) where to put multibyte
     *      character sequence.
     *
     *   replacement =
     *      A valid multibyte string to use when a Unicode character cannot
     *      be represented in the current locale.  $(D NativeWriter) will
     *      throw an exception on any non-representable character if this
     *      parameter is not specified.
     *
     * Throws:
     *  - $(D enforcement) fails if $(D replacement) is not a valid
     *    multibyte string.
     *
     *  - $(D enforcement) fails if $(D NativeWriter) could not figure out
     *    how to safely convert UTF to native multibyte encoding.
     */
    this(Sink sink, immutable(char)[] replacement)
    {
        swap(sink_, sink);
        context_ = new Context;

        // Initialize the convertion state.
        version (NativeWriter_withWinNLS)
        {
            context_.codepage = initialACP;
            if (context_.codepage == CP_UTF8)
                passThruString_ = true;
        }
        else version (NativeWriter_withMultiLocale)
        {
            context_.locale   = duplocale(initialLocaleCTYPE);
            context_.narrowen = mbstate_t.init;

            if (strcmp(nl_langinfo_l(CODESET, context_.locale), "UTF-8"))
                passThruString_ = true;
        }
        else version (NativeWriter_withIconv)
        {
            {
                passThruString_ = true;
            }
            else
            {
                mbencode_ = iconv_open(enc.encoding, ICONV_DSTRING);
                errnoEnforce(mbencode_ != cast(iconv_t) -1,
                        "Cannot figure out how to convert Unicode to "
                        ~"multibyte character encoding");
            }
        }
        else version (Posix)
        {
            passThruString_ = (enc.codesetz == "UTF-8\0");
            enforce(passThruString_, "Cannot figure out how to convert "
                    ~"Unicode to multibyte character encoding");
        }
        else static assert(0);
    }

    this(this)
    {
        if (context_)
            ++context_.refCount;
    }

    ~this()
    {
        if (context_ && --context_.refCount == 0)
        {
            version (NativeWriter_withMultiLocale)
                freelocale(context_.locale);
            version (NativeWriter_withIconv)
                errnoEnforce(iconv_close(context_.mbencode) != -1);
        }
    }


    //----------------------------------------------------------------//
    // output range primitives
    //----------------------------------------------------------------//

    /**
     * Converts a UTF string to multibyte character sequence in the
     * current locale code encoding and puts the multibyte characters
     * to the sink.
     */
    void put(in char[] str)
    {
        if (passThruString_)
        {
            sink_.put(str);
            return;
        }

        version (NativeWriter_preferWstring)
        {
            for (const(char)[] inbuf = str; inbuf.length > 0; )
            {
                wchar[BUFFER_SIZE.wchars] wbuf = void;
                const wsLen = inbuf.convert(wbuf);
                put(wbuf[0 .. wsLen]);
            }
        }
        else version (NativeWriter_preferDstring)
        {
            for (const(char)[] inbuf = str; inbuf.length > 0; )
            {
                dchar[BUFFER_SIZE.dchars] dbuf = void;
                const dsLen = inbuf.convert(dbuf);
                put(dbuf[0 .. dsLen]);
            }
        }
        else
        {
            assert(0);
        }
    }

    /// ditto
    void put(in wchar[] str)
    {
        if (passThruString_)
        {
            for (const(wchar)[] inbuf = str; inbuf.length > 0; )
            {
                char[BUFFER_SIZE.chars] buf = void;
                const strLen = inbuf.convert(buf);
                sink_.put(buf[0 .. strLen]);
            }
            return; // done
        }

        version (NativeWriter_preferDstring)
        {
            for (const(wchar)[] inbuf = str; inbuf.length > 0; )
            {
                dchar[BUFFER_SIZE.dchars] dbuf = void;
                const dsLen = inbuf.convert(dbuf);
                put(dbuf[0 .. dsLen]);
            }
        }
        else version (NativeWriter_withWinNLS)
        {
            char[BUFFER_SIZE.mchars] mstock = void;
            char[] mbuf;
            size_t mbLen;

            mbLen = cast(size_t) WideCharToMultiByte(
                    codepage, 0, wsbuf.ptr, wsLen, null, 0, null, null);
            if (mbLen == 0)
                throw new Exception( toWindowsErrorString(GetLastError()) );

            if (mbLen <= mstock.length)
                mbuf = mstock[0 .. mbLen];
            else
                mbuf = mstock = new char[mbLen];

            mbLen = cast(size_t) WideCharToMultiByte(
                    codepage, 0, wsbuf.ptr, wsLen, mbuf.ptr, mbuf.length, null, null);
            if (mbLen == 0)
                throw new Exception( toWindowsErrorString(GetLastError()) );

        }
        else
        {
            assert(0);
        }
    }

    /// ditto
    void put(in dchar[] str)
    {
        if (passThruString_)
        {
            for (const(dchar)[] inbuf = str; inbuf.length > 0; )
            {
                char[BUFFER_SIZE.chars] buf = void;
                const strLen = inbuf.convert(buf);
                sink_.put(buf[0 .. strLen]);
            }
            return; // done
        }

        version (NativeWriter_preferWstring)
        {
            for (const(dchar)[] inbuf = str; inbuf.length > 0; )
            {
                wchar[BUFFER_SIZE.wchars] wbuf = void;
                const wsLen = inbuf.convert(wbuf);
                put(wbuf[0 .. wsLen]);
            }
        }
        else version (NativeWriter_bufferedWcrtombForDstring)
        {
            version (HAVE_MULTILOCALE)
            {
                auto savedLoc = uselocale(context_.locale);
                scope(exit) uselocale(savedLoc);
            }

            // Convert UTF-32 to multibyte with buffering.
            char[BUFFER_SIZE.mchars] mbuf = void;
            size_t mbufUsed = 0;

            for (const(dchar)[] inbuf = str; inbuf.length > 0; )
            {
                if (mbufUsed >= mbuf.length - MB_CUR_MAX)
                {
                    sink_.put(mbuf[0 .. mbufUsed]);
                    mbufUsed = 0;
                }

                size_t mbLen;
                version (HAVE_MBSTATE)
                    mbLen = wcrtomb(&mbuf[mbufUsed], inbuf[0],
                            &context_.narrowen);
                else
                    mbLen = wctomb(&mbuf[mbufUsed], inbuf[0]);
                inbuf = inbuf[1 .. $];

                if (mbLen == cast(size_t) -1)
                {
                    // Cannot convert inbuf[0] in the current locale.
                    errnoEnforce(errno == EILSEQ && replacement_,
                        "Cannot convert a Unicode character to multibyte "
                        ~"character sequence");

                    // Write the successfully converted substring and the
                    // replacement string.
                    if (mbufUsed > 0)
                        sink_.put(mbuf[0 .. mbufUsed]);
                    if (replacement_.length > 0)
                        sink_.put(replacement_);
                    mbufUsed = 0;

                    // The shift state is undefined; XXX reset.
                    version (HAVE_MBSTATE)
                        context_.narrowen = mbstate_t.init;
                    else
                        wctomb(null, 0);
                }
                else
                {
                    mbufUsed += mbLen;
                }
            }
            // Flush the buffer.
            if (mbufUsed > 0)
                sink_.put(mbuf[0 .. mbufUsed]);
        }
        else version (NativeWriter_withIconv)
        {
            // Convert UTF-32 to multibyte by chunk.
            auto psrc = cast(const(ubyte)*) str.ptr;
            auto srcLeft = dchar.sizeof * str.length;

            while (srcLeft > 0)
            {
                char[BUFFER_SIZE.mchars] mbuf = void;
                auto pbuf = cast(ubyte*) mbuf.ptr;
                auto bufLeft = mbuf.length;

                size_t stat = iconv(context_.mbencode,
                        &psrc, &srcLeft, &pbuf, &bufLeft);
                auto iconverr = errno;

                // Output converted characters (available even on error).
                if (bufLeft < mbuf.length)
                    sink_.put(mbuf[0 .. $ -bufLeft]);

                if (stat == cast(size_t) -1)
                {
                    // EILSEQ means that iconv couldn't convert the
                    // character at *psrc.  We can recover this error if
                    // we have a replacement string.
                    errno = iconverr;
                    errnoEnforce(errno == EILSEQ && replacement_,
                        "Cannot convert a Unicode character to multibyte "
                        ~"character sequence");
                    assert(srcLeft >= dchar.sizeof);

                    // Output the replacement string and skip *psrc.
                    if (replacement_.length > 0)
                        sink_.put(replacement_);
                    psrc    += dchar.sizeof;
                    srcLeft -= dchar.sizeof;
                }
            }
        }
        else
        {
            assert(0);
        }
    }


    /**
     * Converts a Unicode code point to a multibyte character in
     * the current locale encoding and puts it to the sink.
     */
    void put(dchar ch)
    {
        if (passThruString_)
        {
            char[4] buf = void;
            size_t cLen = encode(buf, ch);
            sink_.put(buf[0 .. cLen]);
            return; // done
        }

        version (NativeWriter_withMultiLocale)
        {
            static assert(is(wchar_t == dchar));

            auto savedLoc = uselocale(context_.locale);
            scope(exit) uselocale(savedLoc);

            char[MB_LEN_MAX] mbuf = void;
            size_t mbLen;

            version (HAVE_MBSTATE)
                mbLen = wcrtomb(mbuf.ptr, ch, &context_.narrowen);
            else
                mbLen = wctomb(mbuf.ptr, ch);

            if (mbLen == cast(size_t) -1)
            {
                errnoEnforce(errno == EILSEQ && replacement_,
                    "Cannot convert a Unicode character to multibyte "
                    ~"character sequence");

                // Unicode ch is not representable in the current
                // locale.  Output the replacement instead.
                if (replacement_.length > 0)
                    sink_.put(replacement_);

                // The shift state is undefined; XXX reset.
                version (HAVE_MBSTATE)
                    context_.narrowen = mbstate_t.init;
                else
                    wctomb(null, 0);
            }
            else
            {
                // succeeded
                sink_.put(mbuf[0 .. mbLen]);
            }
        }
        else version (NativeWriter_withIconv)
        {
            char[MB_LEN_MAX] mbuf = void;

            auto pchar    = cast(const(ubyte)*) &ch;
            auto charLeft = ch.sizeof;
            auto pbuf     = cast(ubyte*) mbuf.ptr;
            auto bufLeft  = mbuf.length;

            auto stat = iconv(context_.mbencode,
                    &pchar, &charLeft, &pbuf, &bufLeft);
            errnoEnforce(stat != -1 || (errno == EILSEQ && replacement_),
                "Cannot convert a Unicode character to multibyte "
                ~"character sequence");

            if (stat == -1)
            {
                // Unicode ch is not representable in the current locale.
                // Output the replacement instead.
                if (replacement_.length > 0)
                    sink_.put(replacement_);
            }
            else
            {
                // succeeded
                sink_.put(mbuf[0 .. $ - bufLeft]);
            }
        }
        else
        {
            assert(0);
        }
    }


    //----------------------------------------------------------------//
private:
    Sink              sink_;
    Context*          context_;
    immutable(char)[] replacement_;
    bool              passThruString_;

    struct Context
    {
        version (NativeWriter_withWinNLS)
        {
            DWORD       codepage;   // UTF-16 -> multibyte
        }
        version (NativeWriter_withMultiLocale)
        {
            locale_t    locale;
            mbstate_t   narrowen;   // UTF-32 -> multibyte
        }
        version (NativeWriter_withIconv)
        {
            iconv_t     mbencode;   // UTF-32 -> multibyte
        }
        uint refCount = 1;
    }
}

unittest
{
    if (setlocale(LC_CTYPE, "ja_JP.eucJP") != null)
    {
        scope(exit) setlocale(LC_CTYPE, "C");
        char[] mbs;
        auto r = appender(&mbs);
        auto w = NativeWriter!(typeof(r))(r);
        w.put("1 \u6d88\u3048\u305f 2"c);
        w.put("3 \u624b\u888b\u306e 4"w);
        w.put("5 \u3086\u304f\u3048 6"d);
        w.put(""c);
        w.put('\u2026');
        w.put('/');
        assert(mbs == "\x31\x20\xbe\xc3\xa4\xa8\xa4\xbf\x20\x32"
                ~"\x33\x20\xbc\xea\xc2\xde\xa4\xce\x20\x34"
                ~"\x35\x20\xa4\xe6\xa4\xaf\xa4\xa8\x20\x36"
                ~"\xa1\xc4\x2f");
    }
    version (Windows) if (setlocale(LC_CTYPE, "Japanese_Japan.932"))
    {
        scope(exit) setlocale(LC_CTYPE, "C");
        char[] mbs;
        auto r = appender(&mbs);
        auto w = NativeWriter!(typeof(r))(r);
        w.put("1 \u6d88\u3048\u305f 2"c);
        w.put("3 \u624b\u888b\u306e 4"w);
        w.put("5 \u3086\u304f\u3048 6"d);
        w.put(""c);
        w.put('\u2026');
        w.put('/');
        assert(mbs == "\x31\x20\x8f\xc1\x82\xa6\x82\xbd\x20\x32"
                ~"\x33\x20\x8e\xe8\x91\xdc\x82\xcc\x20\x34"
                ~"\x35\x20\x82\xe4\x82\xad\x82\xa6\x20\x36"
                ~"\x81\x63\x2f");
    }
}


/*
 * Encodes a Unicode code point in UTF-16 and writes it to buf with zero
 * terminator (U+0).  Returns the number of code units written to buf
 * including the terminating zero.
 */
private size_t encodez(ref wchar[3] buf, dchar ch)
{
    size_t n = std.utf.encode(*cast(wchar[2]*) &buf, ch);
    assert(n <= 2);
    buf[n++] = 0;
    return n;
}

unittest
{
    wchar[3] bufz;
    assert(encodez(bufz, '\u1000') == 2);
    assert(bufz[0 .. 2] == "\u1000\u0000");
    assert(encodez(bufz, '\U00020000') == 3);
    assert(bufz[0 .. 3] == "\U00020000\u0000");
}



//----------------------------------------------------------------------------//
// Unicode --> wchar_t
//----------------------------------------------------------------------------//

version (WCHART_UNICODE)
{
    // Trivial UTF convertion.
    version = WideWriter_passThru;
         version (WCHART_WCHAR) version = WideWriter_passThruWstring;
    else version (WCHART_DCHAR) version = WideWriter_passThruDstring;
    else static assert(0);
}
else
{
    // First convert a Unicode character into multibyte character sequence.
    // Then widen it to obtain a wide character.  Uses NativeWriter.
    version = WideWriter_widenNarrow;
}

version (WideWriter_passThruWstring) version = WideWriter_preferWstring;
version (WideWriter_passThruDstring) version = WideWriter_preferDstring;


/**
 * An output range which converts UTF string or Unicode code point to the
 * corresponding wide character sequence in the current locale code set.
 * The converted wide string is written to another output range $(D Sink).
 */
struct WideWriter(Sink)
{
    /**
     * Constructs a $(D WideWriter) object.
     *
     * Params:
     *   sink =
     *      An output range of type $(D Sink) where to put converted
     *      wide character sequence.
     *
     *   replacement =
     *      A valid multibyte string to use when a Unicode character cannot
     *      be represented in the current locale.  $(D WideWriter) will
     *      throw an exception on any non-representable character if this
     *      parameter is $(D null).
     *
     * Throws:
     *  - $(D Exception) if $(D replacement) is not $(D null) and it does
     *    not represent a valid multibyte string in the current locale.
     *
     *  - $(D Exception) if the constructor could not figure out what the
     *    current locale encoding is.
     *
     * Note:
     * $(D replacement) is a multibyte string because it's hard to write
     * wide character sequence by hand on some $(I codeset independent)
     * platforms.
     */
    this(Sink sink, immutable(char)[] replacement = null)
    {
        version (WideWriter_passThru)
        {
            // Unicode-to-Unicode; replacement is unnecessary.
            cast(void) replacement;
            swap(sink_, sink);
        }
        else version (WideWriter_widenNarrow)
        {
            // Convertion will be done as follows under code set
            // independent systems:
            //            iconv              mbrtowc
            //   Unicode -------> multibyte ---------> wide
            alias .Widener!(Sink) Widener;
            proxy_ = NativeWriter!(Widener)(Widener(sink), replacement);
        }
        else static assert(0);
    }


    //----------------------------------------------------------------//
    // output range primitive
    //----------------------------------------------------------------//

    /**
     * Converts a UTF string to wide character sequence in the current
     * locale code set and puts the wide characters to the sink.
     */
    void put(in char[] str)
    {
        version (WideWriter_preferWstring)
        {
            for (const(char)[] inbuf = str; inbuf.length > 0; )
            {
                wchar[BUFFER_SIZE.wchars] wbuf = void;
                const wsLen = inbuf.convert(wbuf);
                put(wbuf[0 .. wsLen]);
            }
        }
        else version (WideWriter_preferDstring)
        {
            for (const(char)[] inbuf = str; inbuf.length > 0; )
            {
                dchar[BUFFER_SIZE.dchars] dbuf = void;
                const dsLen = inbuf.convert(dbuf);
                put(dbuf[0 .. dsLen]);
            }
        }
        else version (WideWriter_widenNarrow)
        {
            proxy_.put(str);
        }
        else static assert(0);
    }

    /// ditto
    void put(in wchar[] str)
    {
        version (WideWriter_preferDstring)
        {
            for (const(wchar)[] inbuf = str; inbuf.length > 0; )
            {
                dchar[BUFFER_SIZE.dchars] dbuf = void;
                const dsLen = inbuf.convert(dbuf);
                put(dbuf[0 .. dsLen]);
            }
        }
        else version (WideWriter_passThruWstring)
        {
            sink_.put(str);
        }
        else version (WideWriter_widenNarrow)
        {
            proxy_.put(str);
        }
        else static assert(0);
    }

    /// ditto
    void put(in dchar[] str)
    {
        version (WideWriter_preferWstring)
        {
            for (const(dchar)[] inbuf = str; inbuf.length > 0; )
            {
                wchar[BUFFER_SIZE.wchars] wbuf = void;
                const wsLen = inbuf.convert(wbuf);
                put(wbuf[0 .. wsLen]);
            }
        }
        else version (WideWriter_passThruDstring)
        {
            sink_.put(str);
        }
        else version (WideWriter_widenNarrow)
        {
            proxy_.put(str);
        }
        else static assert(0);
    }


    /**
     * Converts a Unicode code point to a wide character in the
     * current locale code set and puts it to the sink.
     */
    void put(dchar ch)
    {
        version (WideWriter_passThru)
        {
            static if (is(wchar_t == wchar))
            {
                wchar[2] wbuf = void;

                if (encode(wbuf, ch) == 1)
                    sink_.put(wbuf[0]);
                else
                    sink_.put(wbuf[]);
            }
            else static if (is(wchar_t == dchar))
            {
                sink_.put(ch);
            }
            else static assert(0);
        }
        else version (WideWriter_widenNarrow)
        {
            proxy_.put(ch);
        }
        else static assert(0);
    }


    //----------------------------------------------------------------//
private:
    version (WideWriter_passThru)
    {
        Sink sink_;
    }
    else version (WideWriter_widenNarrow)
    {
        NativeWriter!(Widener!(Sink)) proxy_;
    }
}

unittest
{
    if (setlocale(LC_CTYPE, "ja_JP.eucJP") != null)
    {
        scope(exit) setlocale(LC_CTYPE, "C");
        wchar_t[] wcs;
        auto r = appender(&wcs);
        auto w = WideWriter!(typeof(r))(r);
        w.put("1 \u6d88\u3048\u305f 2"c);
        w.put("3 \u624b\u888b\u306e 4"w);
        w.put("5 \u3086\u304f\u3048 6"d);
        w.put(""c);
        w.put('\u2026');
        w.put('/');
        assert(wcs.length == 23);
    }
    version (Windows) if (setlocale(LC_CTYPE, "Japanese_Japan.932"))
    {
        scope(exit) setlocale(LC_CTYPE, "C");
        wchar_t[] wcs;
        auto r = appender(&wcs);
        auto w = WideWriter!(typeof(r))(r);
        w.put("1 \u6d88\u3048\u305f 2"c);
        w.put("3 \u624b\u888b\u306e 4"w);
        w.put("5 \u3086\u304f\u3048 6"d);
        w.put(""c);
        w.put('\u2026');
        w.put('/');
        assert(wcs == "1 \u6d88\u3048\u305f 2"
                ~"3 \u624b\u888b\u306e 4"
                ~"5 \u3086\u304f\u3048 6"
                ~"\u2026/");
    }
}


//----------------------------------------------------------------------------//

/*
 * [internal]  Convenience range to convert multibyte string to wide
 * string.  This is just a thin-wrapper against mbrtowc().
 */
private struct Widener(Sink)
{
    @disable this(this) { assert(0); } // mbstate must not be copied

    this(Sink sink)
    {
        swap(sink_, sink);

        version (HAVE_MBSTATE)
            widen_ = mbstate_t.init;
        else
            mbtowc(null, null, 0);

        version (HAVE_MULTILOCALE)
        {
            auto curLoc = uselocale(null);
            locale_ = (curLoc == LC_GLOBAL_LOCALE ?
                    LC_GLOBAL_LOCALE : duplocale(curLoc));
            errnoEnforce(locale_ != null, "creating a cache of "
                    ~"the current locale object");
        }
    }

    ~this()
    {
        version (HAVE_MULTILOCALE)
        {
            if (locale_ != LC_GLOBAL_LOCALE)
                freelocale(locale_);
        }
    }


    /*
     * Converts (possibly incomplete) multibyte character sequence mbs
     * to wide characters and puts them onto the sink.
     */
    void put(in char[] mbs)
    {
        version (HAVE_MULTILOCALE)
        {
            auto savedLoc = uselocale(locale_);
            scope(exit) uselocale(savedLoc);
        }

        version (HAVE_RANGED_MBWC)
        {
            for (const(char)[] inbuf = mbs; inbuf.length > 0; )
            {
                wchar_t[BUFFER_SIZE.wchars] wbuf = void;
                const(char)* psrc = inbuf.ptr;

                const wcLen = mbsnrtowcs(wbuf.ptr, &psrc, inbuf.length,
                        wbuf.length, &widen_);
                errnoEnforce(wcLen != -1);
                    // No EILSEQ recovery here -- multibyte string should
                    // be convertible to wide string.

                // wcLen == 0 can happen if the multibyte string ends
                // with an escape sequence.  In such case, the shift
                // state is changed and no wide character is produced.
                if (wcLen > 0)
                    sink_.put(wbuf[0 .. wcLen]);

                inbuf = inbuf[cast(size_t) (psrc - inbuf.ptr) .. $];
            }
        }
        else
        {
            // Convert multibyte to wide with buffering.
            wchar_t[BUFFER_SIZE.wchars] wbuf = void;
            size_t wbufUsed = 0;

            for (const(char)[] inbuf = mbs; inbuf.length > 0; )
            {
                if (wbufUsed == wbuf.length)
                {
                    sink_.put(wbuf[]);
                    wbufUsed = 0;
                }

                size_t mbcLen;
                version (HAVE_MBSTATE)
                    mbcLen = mbrtowc(&wbuf[wbufUsed], inbuf.ptr, inbuf.length,
                            &widen_);
                else
                    mbcLen = wctomb(&mbuf[wbufUsed], inbuf.ptr, inbuf.length);
                enforce(mbcLen != cast(size_t) -1);
                    // No EILSEQ recovery here -- multibyte string should
                    // be convertible to wide string.

                if (mbcLen == cast(size_t) -2)
                {
                    break; // consumed entire inbuf as a part of MB char
                           // sequence and the convertion state changed
                }
                else if (mbcLen == 0)
                {
                    break; // XXX assuming the null character is the end
                }
                else
                {
                    ++wbufUsed;
                    inbuf = inbuf[mbcLen .. $];
                }
            }
            // Flush the buffer.
            if (wbufUsed > 0)
                sink_.put(wbuf[0 .. wbufUsed]);
        }
    }

private:
    Sink sink_;
    version (HAVE_MBSTATE)
        mbstate_t widen_;
    version (HAVE_MULTILOCALE)
        locale_t  locale_;
}


////////////////////////////////////////////////////////////////////////////////
// std.utf extension
////////////////////////////////////////////////////////////////////////////////

// convert()    fast 'streaming' converter

import std.utf;

version (unittest) private bool expectError_(lazy void expr)
{
    try { expr; } catch (UtfException e) { return true; }
    return false;
}


//----------------------------------------------------------------------------//
// UTF-8 to others
//----------------------------------------------------------------------------//

/**
 * Converts the UTF-8 string in $(D inbuf) to the corresponding UTF-16
 * string in $(D outbuf), upto $(D outbuf.length) UTF-16 code units.
 * Upon successful return, $(D inbuf) will be advanced to immediately
 * after the last converted UTF-8 sequence.
 *
 * Returns:
 *   The number of UTF-16 code units written to $(D outbuf).
 *
 * Throws:
 *   $(D UtfException) on encountering a malformed UTF-8 sequence in
 *   $(D inbuf).
 */
size_t convert(ref const(char)[] inbuf, wchar[] outbuf) @safe
{
    const(char)[] curin = inbuf;
    wchar[] curout = outbuf;

    while (curin.length != 0 && curout.length != 0)
    {
        const u1 = curin[0];

        if ((u1 & 0b10000000) == 0)
        {
            // 0xxxxxxx (U+0 - U+7F)
            curout[0] = u1;
            curout = curout[1 .. $];
            curin  = curin [1 .. $];
        }
        else if ((u1 & 0b11100000) == 0b11000000)
        {
            // 110xxxxx 10xxxxxx (U+80 - U+7FF)
            if (curin.length < 2)
                throw new UtfException("missing trailing UTF-8 sequence", u1);

            const u2 = curin[1];
            if ((u2 & 0b11000000) ^ 0b10000000)
                throw new UtfException("decoding UTF-8", u1, u2);

            // the corresponding UTF-16 code unit
            uint w;
            w =             u1 & 0b00011111;
            w = (w << 6) | (u2 & 0b00111111);
            if (w < 0x80)
                throw new UtfException("overlong UTF-8 sequence", u1, u2);
            assert(0x80 <= w && w <= 0x7FF);

            curout[0] = cast(wchar) w;
            curout = curout[1 .. $];
            curin  = curin [2 .. $];
        }
        else if ((u1 & 0b11110000) == 0b11100000)
        {
            // 1110xxxx 10xxxxxx 10xxxxxx (U+800 - U+FFFF)
            if (curin.length < 3)
                throw new UtfException("missing trailing UTF-8 sequence", u1);

            const u2 = curin[1];
            const u3 = curin[2];
            if ( ((u2 & 0b11000000) ^ 0b10000000) |
                 ((u3 & 0b11000000) ^ 0b10000000) )
                throw new UtfException("decoding UTF-8", u1, u2, u3);

            // the corresponding UTF-16 code unit
            uint w;
            w =             u1 & 0b00001111;
            w = (w << 6) | (u2 & 0b00111111);
            w = (w << 6) | (u3 & 0b00111111);
            if (w < 0x800)
                throw new UtfException("overlong UTF-8 sequence", u1, u2, u3);
            if ((w & 0xF800) == 0xD800)
                throw new UtfException("surrogate code point in UTF-8", w);
            assert(0x800 <= w && w <= 0xFFFF);
            assert(w < 0xD800 || 0xDFFF < w);

            curout[0] = cast(wchar) w;
            curout = curout[1 .. $];
            curin  = curin [3 .. $];
        }
        else if ((u1 & 0b11111000) == 0b11110000)
        {
            // 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx (U+10000 - U+10FFFF)
            if (curin.length < 4)
                throw new UtfException("missing trailing UTF-8 sequence", u1);

            // The code point needs surrogate-pair encoding.
            if (curout.length < 2)
                break; // No room; stop converting.

            const u2 = curin[1];
            const u3 = curin[2];
            const u4 = curin[3];
            if ( ((u2 & 0b11000000) ^ 0b10000000) |
                 ((u3 & 0b11000000) ^ 0b10000000) |
                 ((u4 & 0b11000000) ^ 0b10000000) )
                throw new UtfException("decoding UTF-8", u1, u2, u3, u4);

            // First calculate the corresponding Unicode code point, and then
            // compose a surrogate pair.
            uint c;
            c =             u1 & 0b00000111;
            c = (c << 6) | (u2 & 0b00111111);
            c = (c << 6) | (u3 & 0b00111111);
            c = (c << 6) | (u4 & 0b00111111);
            if (c < 0x10000)
                throw new UtfException("overlong UTF-8 sequence", u1, u2, u3, u4);
            if (c > 0x10FFFF)
                throw new UtfException("invalid code point", c);
            assert(0x10000 <= c && c <= 0x10FFFF);

            curout[0] = cast(wchar) ((((c - 0x10000) >> 10) & 0x3FF) + 0xD800);
            curout[1] = cast(wchar) (( (c - 0x10000)        & 0x3FF) + 0xDC00);
            curout = curout[2 .. $];
            curin  = curin [4 .. $];
        }
        else
        {
            // invalid 5/6-byte UTF-8 or trailing byte 10xxxxxx
            throw new UtfException("illegal UTF-8 leading byte", u1);
        }
    }

    inbuf = curin;
    return outbuf.length - curout.length;
}

/// ditto
size_t convert(ref immutable(char)[] inbuf, wchar[] outbuf) @safe
{
    const(char)[] inbuf_ = inbuf;
    const result = convert(inbuf_, outbuf);
    assert(inbuf.ptr <= inbuf_.ptr && inbuf_.ptr <= inbuf.ptr + inbuf.length);
    inbuf = cast(immutable) inbuf_;
    return result;
}

unittest
{
    string s = "\u0000\u007F\u0080\u07FF\u0800\uD7FF\uE000\uFFFD"
        ~"\U00010000\U0010FFFF";
    wchar[6] dstbuf;

    assert(s.convert(dstbuf) == 6);
    assert(s.length == 14);
    assert(dstbuf[0 .. 6] == "\u0000\u007F\u0080\u07FF\u0800\uD7FF");

    assert(s.convert(dstbuf) == 6);
    assert(s.length == 0);
    assert(dstbuf[0 .. 6] == "\uE000\uFFFD\U00010000\U0010FFFF");
}


/**
 * Converts the UTF-8 string in $(D inbuf) to the corresponding UTF-32
 * string in $(D outbuf), upto $(D outbuf.length) UTF-32 code units.
 * Upon successful return, $(D inbuf) will be advanced to immediately
 * after the last converted UTF-8 sequence.
 *
 * Returns:
 *   The number of UTF-32 code units, or Unicode code points, written
 *   to $(D outbuf).
 *
 * Throws:
 *   $(D UtfException) on encountering a malformed UTF-8 sequence
 *   in $(D inbuf).
 */
size_t convert(ref const(char)[] inbuf, dchar[] outbuf) @safe
{
    const(char)[] curin = inbuf;
    dchar[] curout = outbuf;

    while (curin.length != 0 && curout.length != 0)
    {
        const u1 = curin[0];

        if ((u1 & 0b10000000) == 0)
        {
            // 0xxxxxxx (U+0 - U+7F)
            curout[0] = u1;
            curout = curout[1 .. $];
            curin  = curin [1 .. $];
        }
        else if ((u1 & 0b11100000) == 0b11000000)
        {
            // 110xxxxx 10xxxxxx (U+80 - U+7FF)
            if (curin.length < 2)
                throw new UtfException("missing trailing UTF-8 sequence", u1);

            const u2 = curin[1];
            if ((u2 & 0b11000000) ^ 0b10000000)
                throw new UtfException("decoding UTF-8", u1, u2);

            // the corresponding code point
            uint c;
            c =             u1 & 0b00011111;
            c = (c << 6) | (u2 & 0b00111111);
            if (c < 0x80)
                throw new UtfException("overlong UTF-8 sequence", u1, u2);
            assert(0x80 <= c && c <= 0x7FF);

            curout[0] = cast(dchar) c;
            curout = curout[1 .. $];
            curin  = curin [2 .. $];
        }
        else if ((u1 & 0b11110000) == 0b11100000)
        {
            // 1110xxxx 10xxxxxx 10xxxxxx (U+800 - U+FFFF)
            if (curin.length < 3)
                throw new UtfException("missing trailing UTF-8 sequence", u1);

            const u2 = curin[1];
            const u3 = curin[2];
            if ( ((u2 & 0b11000000) ^ 0b10000000) |
                 ((u3 & 0b11000000) ^ 0b10000000) )
                throw new UtfException("decoding UTF-8", u1, u2, u3);

            // the corresponding code point
            uint c;
            c =             u1 & 0b00001111;
            c = (c << 6) | (u2 & 0b00111111);
            c = (c << 6) | (u3 & 0b00111111);
            if (c < 0x800)
                throw new UtfException("overlong UTF-8 sequence", u1, u2, u3);
            if ((c & 0xF800) == 0xD800)
                throw new UtfException("surrogate code point in UTF-8", c);
            assert(0x800 <= c && c <= 0xFFFF);
            assert(c < 0xD800 || 0xDFFF < c);

            curout[0] = cast(dchar) c;
            curout = curout[1 .. $];
            curin  = curin [3 .. $];
        }
        else if ((u1 & 0b11111000) == 0b11110000)
        {
            // 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx (U+10000 - U+10FFFF)
            if (curin.length < 4)
                throw new UtfException("missing trailing UTF-8 sequence", u1);

            const u2 = curin[1];
            const u3 = curin[2];
            const u4 = curin[3];
            if ( ((u2 & 0b11000000) ^ 0b10000000) |
                 ((u3 & 0b11000000) ^ 0b10000000) |
                 ((u4 & 0b11000000) ^ 0b10000000) )
                throw new UtfException("decoding UTF-8", u1, u2, u3, u4);

            // the corresponding code point
            uint c;
            c =             u1 & 0b00000111;
            c = (c << 6) | (u2 & 0b00111111);
            c = (c << 6) | (u3 & 0b00111111);
            c = (c << 6) | (u4 & 0b00111111);
            if (c < 0x10000)
                throw new UtfException("overlong UTF-8 sequence", u1, u2, u3, u4);
            if (c > 0x10FFFF)
                throw new UtfException("invalid code point", c);
            assert(0x10000 <= c && c <= 0x10FFFF);

            curout[0] = cast(dchar) c;
            curout = curout[1 .. $];
            curin  = curin [4 .. $];
        }
        else
        {
            // invalid 5/6-byte UTF-8 or trailing byte 10xxxxxx
            throw new UtfException("illegal UTF-8 leading byte", u1);
        }
    }

    inbuf = curin;
    return outbuf.length - curout.length;
}

/// ditto
size_t convert(ref immutable(char)[] inbuf, dchar[] outbuf) @safe
{
    const(char)[] inbuf_ = inbuf;
    const result = convert(inbuf_, outbuf);
    assert(inbuf.ptr <= inbuf_.ptr && inbuf_.ptr <= inbuf.ptr + inbuf.length);
    inbuf = cast(immutable) inbuf_;
    return result;
}

unittest
{
    string s = "\u0000\u007F\u0080\u07FF\u0800\uD7FF\uE000\uFFFD"
        ~"\U00010000\U0010FFFF";
    dchar[6] dstbuf;

    assert(s.convert(dstbuf) == 6);
    assert(s.length == 14);
    assert(dstbuf[0 .. 6] == "\u0000\u007F\u0080\u07FF\u0800\uD7FF");

    assert(s.convert(dstbuf) == 4);
    assert(s.length == 0);
    assert(dstbuf[0 .. 4] == "\uE000\uFFFD\U00010000\U0010FFFF");
}


//----------------------------------------------------------------------------//
// UTF-16 to others
//----------------------------------------------------------------------------//

/**
 * Converts the UTF-16 string in $(D inbuf) to the corresponding UTF-8
 * string in $(D outbuf), upto $(D outbuf.length) UTF-8 code units.
 * Upon successful return, $(D inbuf) will be advanced to immediately
 * after the last converted UTF-16 sequence.
 *
 * Returns:
 *   The number of UTF-8 code units written to $(D outbuf).
 *
 * Throws:
 *   $(D UtfException) on encountering a malformed UTF-16 sequence in
 *   $(D inbuf).
 */
size_t convert(ref const(wchar)[] inbuf, char[] outbuf) @safe
{
    const(wchar)[] curin = inbuf;
    char[] curout = outbuf;

    while (curin.length != 0)
    {
        wchar w = curin[0];

        if (w <= 0x7F)
        {
            // UTF-8: 0xxxxxxx
            if (curout.length < 1)
                break; // No room; stop converting.

            curout[0] = cast(char) w;
            curout = curout[1 .. $];
            curin  = curin [1 .. $];
        }
        else if (w <= 0x7FF)
        {
            // UTF-8: 110xxxxx 10xxxxxx
            if (curout.length < 2)
                break; // No room; stop converting.

            curout[0] = cast(char) (0b11000000 | (w >> 6        ));
            curout[1] = cast(char) (0b10000000 | (w & 0b00111111));
            curout = curout[2 .. $];
            curin  = curin [1 .. $];
        }
        else if ((w & 0xF800) != 0xD800)
        {
            // UTF-8: 1110xxxx 10xxxxxx 10xxxxxx
            if (curout.length < 3)
                break; // No room; stop converting.

            curout[0] = cast(char) (0b11100000 |  (w >> 12)              );
            curout[1] = cast(char) (0b10000000 | ((w >> 6 ) & 0b00111111));
            curout[2] = cast(char) (0b10000000 | ( w        & 0b00111111));
            curout = curout[3 .. $];
            curin  = curin [1 .. $];
        }
        else // Found a surrogate code unit.
        {
            if ((w & 0xFC00) == 0xDC00)
                throw new UtfException("isolated low surrogate", w);
            assert((w & 0xFC00) == 0xD800);

            wchar w1 = w;
            wchar w2 = curin[1];
            if ((w2 & 0xFC00) != 0xDC00)
                throw new UtfException("isolated high surrogate", w1, w2);

            // UTF-8: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
            if (curout.length < 4)
                break; // No room; stop converting.

            // First calculate the corresponding Unicode code point, and then
            // compose the UTF-8 sequence.
            uint c;
            c =              w1 - 0xD7C0;
            c = (c << 10) | (w2 - 0xDC00);
            assert(0x10000 <= c && c <= 0x10FFFF);

            curout[0] = cast(char) (0b11110000 | ( c >> 18)              );
            curout[1] = cast(char) (0b10000000 | ((c >> 12) & 0b00111111));
            curout[2] = cast(char) (0b10000000 | ((c >>  6) & 0b00111111));
            curout[3] = cast(char) (0b10000000 | ( c        & 0b00111111));
            curout = curout[4 .. $];
            curin  = curin [2 .. $];
        }
    }

    inbuf = curin;
    return outbuf.length - curout.length;
}

/// ditto
size_t convert(ref immutable(wchar)[] inbuf, char[] outbuf) @safe
{
    const(wchar)[] inbuf_ = inbuf;
    const result = convert(inbuf_, outbuf);
    assert(inbuf.ptr <= inbuf_.ptr && inbuf_.ptr <= inbuf.ptr + inbuf.length);
    inbuf = cast(immutable) inbuf_;
    return result;
}

unittest
{
    wstring s = "\u0000\u007F\u0080\u07FF\u0800\uD7FF\uE000\uFFFD"
        ~"\U00010000\U0010FFFF";
    char[6] dstbuf;

    assert(s.convert(dstbuf) == 6);
    assert(s.length == 8);
    assert(dstbuf[0 .. 6] == "\u0000\u007F\u0080\u07FF");

    assert(s.convert(dstbuf) == 6);
    assert(s.length == 6);
    assert(dstbuf[0 .. 6] == "\u0800\uD7FF");

    assert(s.convert(dstbuf) == 6);
    assert(s.length == 4);
    assert(dstbuf[0 .. 6] == "\uE000\uFFFD");

    assert(s.convert(dstbuf) == 4);
    assert(s.length == 2);
    assert(dstbuf[0 .. 4] == "\U00010000");

    assert(s.convert(dstbuf) == 4);
    assert(s.length == 0);
    assert(dstbuf[0 .. 4] == "\U0010FFFF");
}


/**
 * Converts the UTF-16 string in $(D inbuf) to the corresponding UTF-32
 * string in $(D outbuf), upto $(D outbuf.length) UTF-32 code units.
 * Upon successful return, $(D inbuf) will be advanced to immediately
 * after the last converted UTF-16 sequence.
 *
 * Returns:
 *   The number of UTF-32 code units written to $(D outbuf).
 *
 * Throws:
 *   $(D UtfException) on encountering a malformed UTF-16 sequence in
 *   $(D inbuf).
 */
size_t convert(ref const(wchar)[] inbuf, dchar[] outbuf) @safe
{
    const(wchar)[] curin = inbuf;
    dchar[] curout = outbuf;

    while (curin.length != 0 && curout.length != 0)
    {
        wchar w = curin[0];

        if ((w & 0xF800) != 0xD800)
        {
            curout[0] = w;
            curout = curout[1 .. $];
            curin  = curin [1 .. $];
        }
        else // surrogate code unit
        {
            if ((w & 0xFC00) == 0xDC00)
                throw new UtfException("isolated low surrogate", w);
            assert((w & 0xFC00) == 0xD800);

            wchar w1 = w;
            wchar w2 = curin[1];
            if ((w2 & 0xFC00) != 0xDC00)
                throw new UtfException("isolated high surrogate", w1, w2);

            // Calculate the corresponding Unicode code point.
            uint c;
            c =              w1 - 0xD7C0;
            c = (c << 10) | (w2 - 0xDC00);
            assert(0x10000 <= c && c <= 0x10FFFF);

            curout[0] = cast(dchar) c;
            curout = curout[1 .. $];
            curin  = curin [2 .. $];
        }
    }

    inbuf = curin;
    return outbuf.length - curout.length;
}

/// ditto
size_t convert(ref immutable(wchar)[] inbuf, dchar[] outbuf) @safe
{
    const(wchar)[] inbuf_ = inbuf;
    const result = convert(inbuf_, outbuf);
    assert(inbuf.ptr <= inbuf_.ptr && inbuf_.ptr <= inbuf.ptr + inbuf.length);
    inbuf = cast(immutable) inbuf_;
    return result;
}

unittest
{
    wstring s = "\u0000\u007F\u0080\u07FF\u0800\uD7FF\uE000\uFFFD"
        ~"\U00010000\U0010FFFF";
    dchar[6] dstbuf;

    assert(s.convert(dstbuf) == 6);
    assert(s.length == 6);
    assert(dstbuf[0 .. 6] == "\u0000\u007F\u0080\u07FF\u0800\uD7FF");

    assert(s.convert(dstbuf) == 4);
    assert(s.length == 0);
    assert(dstbuf[0 .. 4] == "\uE000\uFFFD\U00010000\U0010FFFF");
}


//----------------------------------------------------------------------------//
// UTF-32 to others
//----------------------------------------------------------------------------//

/**
 * Converts the UTF-32 string in $(D inbuf) to the corresponding UTF-8
 * string in $(D outbuf), upto $(D outbuf.length) UTF-8 code units.
 * Upon successful return, $(D inbuf) will be advanced to immediately
 * after the last converted UTF-32 code unit.
 *
 * Returns:
 *   The number of UTF-8 code units written to $(D outbuf).
 *
 * Throws:
 *   $(D UtfException) on encountering a malformed UTF-32 sequence in
 *   $(D inbuf).
 */
size_t convert(ref const(dchar)[] inbuf, char[] outbuf) @safe
{
    const(dchar)[] curin = inbuf;
    char[] curout = outbuf;

    while (curin.length != 0)
    {
        dchar c = curin[0];

        if (c <= 0x7F)
        {
            // UTF-8: 0xxxxxxx
            if (curout.length < 1)
                break; // No room; stop converting.

            curout[0] = cast(char) c;
            curout = curout[1 .. $];
            curin  = curin [1 .. $];
        }
        else if (c <= 0x7FF)
        {
            // UTF-8: 110xxxxx 10xxxxxx
            if (curout.length < 2)
                break; // No room; stop converting.

            curout[0] = cast(char) (0b11000000 | (c >> 6        ));
            curout[1] = cast(char) (0b10000000 | (c & 0b00111111));
            curout = curout[2 .. $];
            curin  = curin [1 .. $];
        }
        else if (c <= 0xFFFF)
        {
            // UTF-8: 1110xxxx 10xxxxxx 10xxxxxx
            if (curout.length < 3)
                break; // No room; stop converting.

            curout[0] = cast(char) (0b11100000 |  (c >> 12)              );
            curout[1] = cast(char) (0b10000000 | ((c >> 6 ) & 0b00111111));
            curout[2] = cast(char) (0b10000000 | ( c        & 0b00111111));
            curout = curout[3 .. $];
            curin  = curin [1 .. $];
        }
        else if (c <= 0x10FFFF)
        {
            // UTF-8: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
            if (curout.length < 4)
                break; // No room; stop converting.

            assert(0x10000 <= c && c <= 0x10FFFF);
            curout[0] = cast(char) (0b11110000 | ( c >> 18)              );
            curout[1] = cast(char) (0b10000000 | ((c >> 12) & 0b00111111));
            curout[2] = cast(char) (0b10000000 | ((c >>  6) & 0b00111111));
            curout[3] = cast(char) (0b10000000 | ( c        & 0b00111111));
            curout = curout[4 .. $];
            curin  = curin [1 .. $];
        }
        else
        {
            // Any code point larger than U+10FFFF is invalid.
            throw new UtfException("decoding UTF-32", c);
        }
    }

    inbuf = curin;
    return outbuf.length - curout.length;
}

/// ditto
size_t convert(ref immutable(dchar)[] inbuf, char[] outbuf) @safe
{
    const(dchar)[] inbuf_ = inbuf;
    const result = convert(inbuf_, outbuf);
    assert(inbuf.ptr <= inbuf_.ptr && inbuf_.ptr <= inbuf.ptr + inbuf.length);
    inbuf = cast(immutable) inbuf_;
    return result;
}

unittest
{
    dstring s = "\u0000\u007F\u0080\u07FF\u0800\uD7FF\uE000\uFFFD"
        ~"\U00010000\U0010FFFF";
    char[6] dstbuf;

    assert(s.convert(dstbuf) == 6);
    assert(s.length == 6);
    assert(dstbuf[0 .. 6] == "\u0000\u007F\u0080\u07FF");

    assert(s.convert(dstbuf) == 6);
    assert(s.length == 4);
    assert(dstbuf[0 .. 6] == "\u0800\uD7FF");

    assert(s.convert(dstbuf) == 6);
    assert(s.length == 2);
    assert(dstbuf[0 .. 6] == "\uE000\uFFFD");

    assert(s.convert(dstbuf) == 4);
    assert(s.length == 1);
    assert(dstbuf[0 .. 4] == "\U00010000");

    assert(s.convert(dstbuf) == 4);
    assert(s.length == 0);
    assert(dstbuf[0 .. 4] == "\U0010FFFF");
}


/**
 * Converts the UTF-16 string in $(D inbuf) to the corresponding UTF-32
 * string in $(D outbuf), upto $(D outbuf.length) UTF-32 code units.
 * Upon successful return, $(D inbuf) will be advanced to immediately
 * after the last converted UTF-16 sequence.
 *
 * Returns:
 *   The number of UTF-32 code units written to $(D outbuf).
 *
 * Throws:
 *   $(D UtfException) on encountering a malformed UTF-16 sequence in
 *   $(D inbuf).
 */
size_t convert(ref const(dchar)[] inbuf, wchar[] outbuf) @safe
{
    const(dchar)[] curin = inbuf;
    wchar[] curout = outbuf;

    while (curin.length != 0 && curout.length != 0)
    {
        dchar c = curin[0];

        if (c <= 0xFFFF)
        {
            if ((c & 0xF800) == 0xD800)
                throw new UtfException(
                    "surrogate code point in UTF-32", c);

            curout[0] = cast(wchar) c;
            curout = curout[1 .. $];
            curin  = curin [1 .. $];
        }
        else if (c <= 0x10FFFF)
        {
            // Needs surrogate pair.
            if (curout.length < 2)
                break; // No room; stop converting.

            assert(0x10000 <= c && c <= 0x10FFFF);
            curout[0] = cast(wchar) ((((c - 0x10000) >> 10) & 0x3FF) + 0xD800);
            curout[1] = cast(wchar) (( (c - 0x10000)        & 0x3FF) + 0xDC00);
            curout = curout[2 .. $];
            curin  = curin [1 .. $];
        }
        else
        {
            // Any code point larger than U+10FFFF is invalid.
            throw new UtfException("decoding UTF-32", c);
        }
    }

    inbuf = curin;
    return outbuf.length - curout.length;
}

/// ditto
size_t convert(ref immutable(dchar)[] inbuf, wchar[] outbuf) @safe
{
    const(dchar)[] inbuf_ = inbuf;
    const result = convert(inbuf_, outbuf);
    assert(inbuf.ptr <= inbuf_.ptr && inbuf_.ptr <= inbuf.ptr + inbuf.length);
    inbuf = cast(immutable) inbuf_;
    return result;
}

unittest
{
    dstring s = "\u0000\u007F\u0080\u07FF\u0800\uD7FF\uE000\uFFFD"
        ~"\U00010000\U0010FFFF";
    wchar[3] dstbuf;

    assert(s.convert(dstbuf) == 3);
    assert(s.length == 7);
    assert(dstbuf[0 .. 3] == "\u0000\u007F\u0080");

    assert(s.convert(dstbuf) == 3);
    assert(s.length == 4);
    assert(dstbuf[0 .. 3] == "\u07FF\u0800\uD7FF");

    assert(s.convert(dstbuf) == 2);
    assert(s.length == 2);
    assert(dstbuf[0 .. 2] == "\uE000\uFFFD");

    assert(s.convert(dstbuf) == 2);
    assert(s.length == 1);
    assert(dstbuf[0 .. 2] == "\U00010000");

    assert(s.convert(dstbuf) == 2);
    assert(s.length == 0);
    assert(dstbuf[0 .. 2] == "\U0010FFFF");
}


////////////////////////////////////////////////////////////////////////////////
// druntime fix
////////////////////////////////////////////////////////////////////////////////

// fix  core.stdc.wchar
// add  core.sys.posix.iconv
// add  core.sys.posix.locale
// add  core.sys.posix.langinfo

//----------------------------------------------------------------------------//
// fix - core.stdc.wchar
//----------------------------------------------------------------------------//

enum size_t MB_LEN_MAX = 16;

version (Windows)
{
    alias wchar wchar_t;

    version (DigitalMars)
    {
        struct mbstate_t {} // XXX dummy

        extern(C) extern __gshared size_t __locale_mbsize;
        alias __locale_mbsize MB_CUR_MAX;
    }
    else static assert(0);
}
else version (linux)
{
    alias dchar wchar_t;

    struct mbstate_t
    {
        int     count;
        wchar_t value = 0;  // XXX wint_t
    }

    extern(C) @system size_t __ctype_get_mb_cur_max();
    alias __ctype_get_mb_cur_max MB_CUR_MAX;
}
else version (OSX)
{
    alias dchar wchar_t;

    union mbstate_t
    {
        ubyte[128] __mbstate8;
        long       _mbstateL;
    }

    extern(C) @system size_t __mb_cur_max();
    alias __mb_cur_max MB_CUR_MAX;
}
else version (FreeBSD)
{
    alias int wchar_t;

    union mbstate_t
    {
        ubyte[128] __mbstate8;
        long       _mbstateL;
    }

    extern(C) extern __gshared size_t __mb_cur_max;
    alias __mb_cur_max MB_CUR_MAX;
}
else version (Solaris)
{
    alias int wchar_t;

    struct mbstate_t
    {
        version (LP64)
            long[4] __filler;
        else
            int [6] __filler;
    }

    extern(C) extern __gshared ubyte* __ctype;
    @system size_t MB_CUR_MAX() { return __ctpye[520]; }
}
else static assert(0);

extern(C) @system
{
    int    mbsinit(in mbstate_t* ps);
    int    mbrlen(in char* s, size_t n, mbstate_t* ps);
    size_t mbrtowc(wchar_t* pwc, in char* s, size_t n, mbstate_t* ps);
    size_t wcrtomb(char* s, wchar_t wc, mbstate_t* ps);
    size_t mbsrtowcs(wchar_t* dst, in char** src, size_t len, mbstate_t* ps);
    size_t wcsrtombs(char* dst, in wchar_t** src, size_t len, mbstate_t* ps);

    size_t mbsnrtowcs(wchar_t* dst, in char** src, size_t nms, size_t len, mbstate_t* ps);
    size_t wcsnrtombs(char* dst, in wchar_t** src, size_t nwc, size_t len, mbstate_t* ps);

    int    mblen(in char* s, size_t n);
    int    mbtowc(wchar_t* pwc, in char* s, size_t n);
    int    wctomb(char*s, wchar_t wc);
    size_t mbstowcs(wchar_t* pwcs, in char* s, size_t n);
    size_t wcstombs(char* s, in wchar_t* pwcs, size_t n);
}


//----------------------------------------------------------------------------//
// missing - core.sys.posix.iconv
//----------------------------------------------------------------------------//

version (Posix)
{
    alias void* iconv_t;

    extern(C) @system
    {
        iconv_t iconv_open(in char*, in char*);
        size_t iconv(iconv_t, in ubyte**, size_t*, ubyte**, size_t*);
        int iconv_close(iconv_t);
    }
}


//----------------------------------------------------------------------------//
// missing - core.sys.posix.locale
//----------------------------------------------------------------------------//

version (Posix)
{
    alias void* locale_t;

    version (linux)
    {
        enum LC_GLOBAL_LOCALE = cast(locale_t) -1;
    }
    else version (OSX)
    {
        enum LC_GLOBAL_LOCALE = cast(locale_t) -1;
    }

    extern(C) @system
    {
        locale_t newlocale(int category_mask, in char *locale, locale_t base);
        locale_t duplocale(locale_t locobj);
        void     freelocale(locale_t locobj);
        locale_t uselocale(locale_t newloc);
    }
}


//----------------------------------------------------------------------------//
// missing - core.sys.posix.langinfo
//----------------------------------------------------------------------------//

version (Posix)
{
    alias int nl_item;

    version (linux)
    {
    }
    else version (OSX)
    {
    }
    else version (FreeBSD)
    {
        enum CODESET = 0;
    }
    else version (Solaris)
    {
        enum CODESET = 49;
    }
    else static assert(0);

    extern(C) @system
    {
        char* nl_langinfo(nl_item);
        char* nl_langinfo_l(nl_item, locale_t);
    }
}


