/**
 * Macros:
 *   D = $(I $1)
 */
module lntw;

import std.format;
import std.stdio;

import core.stdc.locale;

void main()
{
    {
//      fwide(std.stdio.stdout.getFP(), 1);     // wide mode

        auto r = cast(immutable ubyte[]) "?";
        auto w = LockingNativeTextWriter(std.stdio.stdout, r);
        w.put("מגדל בבל"c);
        w.put('\n');
        w.put("Tower of Babel"w);
        w.put('\n');
        w.put("バベルの塔"d);
        w.put('\n');
    }
}


// use libiconv for debugging
version (FreeBSD) debug = USE_LIBICONV;


//-/////////////////////////////////////////////////////////////////////////////
// LockingNativeTextWriter
//-/////////////////////////////////////////////////////////////////////////////

import core.stdc.wchar_ : fwide, WEOF;
import core.stdc.stdio;
import core.sys.posix.unistd;

import std.algorithm;
import std.contracts;
import std.stdio;
import std.traits;


version (Windows) private
{
    import core.sys.windows.windows;
    import std.windows.syserror;

    version (DigitalMars)
    {
        extern(C) extern __gshared HANDLE[_NFILE] _osfhnd;
        @system HANDLE peekHANDLE(FILE* f) { return _osfhnd[f._file]; }

        version = WITH_WINDOWS_CONSOLE;
    }

    immutable typeof(&WriteConsoleW) indirectWriteConsoleW;
    shared static this()
    {
        indirectWriteConsoleW = cast(typeof(indirectWriteConsoleW))
            GetProcAddress(GetModuleHandleA("kernel32.dll"),
                    "WriteConsoleW");
    }
}


/**
 * An $(D output range) that locks the file and provides writing to the
 * file in the native multibyte encoding.
 */
@system struct LockingNativeTextWriter
{
    /**
     * Constructs a $(D LockingNativeTextWriter) object.
     *
     * Params:
     *   file =
     *     An open $(D File) to write in.
     *
     *   replacement =
     *     A valid multibyte character to use when a Unicode character
     *     cannot be represented in the native encoding.  If this
     *     argument is empty, an $(D EncodingException) will be thrown
     *     on any non-representable character.
     *
     * Throws:
     * $(UL
     *   $(LI $(D enforcement) fails if $(D file) is not open.)
     *   $(LI $(D enforcement) fails if there is no safe mean to
     *        convert UTF text to the native multibyte encoding.)
     * )
     *
     * NOTES:
     * If writing to a wide-oriented $(D File), make sure that the
     * LC_CTYPE locale used by the $(D fputwc) function is set to the
     * environment native one: $(D "").  Or, you may get an $(D
     * StdioException) with the error code $(D EILSEQ).
     *
     * Such a restriction does not exist in byte-oriented, or usual,
     * files.
     */
    this(File file, immutable(ubyte)[] replacement = null)
    {
        enforce(file.isOpen, "Attempted to write to a closed file");
        swap(file_, file);

        auto fp = file_.getFP();
        FLOCK(fp);
        auto handle = cast(_iobuf*) fp;

        useWide_ = (fwide(fp, 0) > 0);

        //
        version (WITH_WINDOWS_CONSOLE)
        {{
            HANDLE console = peekHANDLE(fp);
            DWORD  dummy;

            if (GetConsoleMode(console, &dummy) &&
                indirectWriteConsoleW &&
                indirectWriteConsoleW(console, "\0"w.ptr, 0, null, null))
            {
                console_ = console;
                fflush(fp); // need to sync
                return;
            }
        }}

        // This should be in File.open() for tracking convertion state.
        if (useWide_)
            wideTextPutter_ = _WideTextEncoder!(_UnsharedWidePutter)(
                    _UnsharedWidePutter(handle), replacement);
        else
            nativeTextPutter_ = NativeTextEncoder!(_UnsharedNarrowPutter)(
                    _UnsharedNarrowPutter(handle), replacement);
    }

    this(this)
    {
        FLOCK(file_.p.handle);
    }

    ~this()
    {
        FUNLOCK(file_.p.handle);
    }


    //----------------------------------------------------------------//
    // range primitive implementations
    //----------------------------------------------------------------//

    /// Range primitive implementations.
    void put(S)(S str)
        if (isSomeString!(S))
    {
        version (WITH_WINDOWS_CONSOLE)
        {
            if (console_ != INVALID_HANDLE_VALUE)
                return putWinConsole(str);
        }

        if (useWide_)
            wideTextPutter_.put(str);
        else
            nativeTextPutter_.put(str);
    }

    /// ditto
    void put(C : dchar)(C ch)
    {
        version (WITH_WINDOWS_CONSOLE)
        {
            if (console_ != INVALID_HANDLE_VALUE)
                return putWinConsole(ch);
        }

        if (useWide_)
            wideTextPutter_.put(ch);
        else
            nativeTextPutter_.put(ch);
    }


    //----------------------------------------------------------------//
    // WriteConsoleW
    //----------------------------------------------------------------//
private:
    version (Windows)
    {
        enum size_t BUFFER_SIZE = 80;

        void putWinConsole(in char[] str)
        {
            // Forward to the wstring overload.
            for (const(char)[] inbuf = str; inbuf.length > 0; )
            {
                wchar[BUFFER_SIZE] wbuf = void;
                const wsLen = inbuf.convert(wbuf);
                putWinConsole(wbuf[0 .. wsLen]);
            }
        }

        void putWinConsole(in wchar[] str)
        {
            for (const(wchar)[] outbuf = str; outbuf.length > 0; )
            {
                DWORD nwritten;

                if (!indirectWriteConsoleW(console_,
                        outbuf.ptr, outbuf.length, &nwritten, null))
                    throw new /+StdioException+/Exception(
                        sysErrorString(GetLastError()));
                outbuf = outbuf[nwritten .. $];
            }
        }

        void putWinConsole(in dchar[] str)
        {
            // Forward to the wstring overload.
            for (const(dchar)[] inbuf = str; inbuf.length > 0; )
            {
                wchar[BUFFER_SIZE] wbuf = void;
                const wsLen = inbuf.convert(wbuf);
                putWinConsole(wbuf[0 .. wsLen]);
            }
        }

        void putWinConsole(dchar ch)
        {
            // Forward to the wstring overload.
            wchar[2] wbuf = void;
            const wcLen = encode(wbuf, ch);
            putWinConsole(wbuf[0 .. wcLen]);
        }
    }


    //----------------------------------------------------------------//
private:
    File file_;     // the underlying File object
    int  useWide_;  // whether to use wide-oriented functions

    version (WITH_WINDOWS_CONSOLE)
        HANDLE console_ = INVALID_HANDLE_VALUE;

    // XXX This should be in File.Impl for tracking the convertion state.
    NativeTextEncoder!(_UnsharedNarrowPutter) nativeTextPutter_;
     _WideTextEncoder!(_UnsharedWidePutter  )   wideTextPutter_;
}


// internally used to write multibyte character to FILE*
private @system struct _UnsharedNarrowPutter
{
    _iobuf* handle_;

    void put(const ubyte[] mbs)
    {
        size_t nwritten = fwrite(
                mbs.ptr, 1, mbs.length, cast(shared) handle_);
        errnoEnforce(nwritten == mbs.length);
    }
}

// internally used to write wide character to FILE*
private @system struct _UnsharedWidePutter
{
    _iobuf* handle_;

    void put(wchar_t wc)
    {
        auto stat = FPUTWC(wc, handle_);
        if (stat == WEOF)
            throw new StdioException(null);
    }

    void put(const wchar_t[] wcs)
    {
        foreach (wchar_t wc; wcs)
            FPUTWC(wc, handle_);
        if (ferror(cast(shared) handle_))
            throw new StdioException(null);
    }
}


//-/////////////////////////////////////////////////////////////////////////////
// NativeTextEncoder
//-/////////////////////////////////////////////////////////////////////////////

import std.algorithm;
import std.contracts;
import std.encoding : EncodingException;
import std.range;
import std.string;
import std.utf;

import core.stdc.errno;
//import core.stdc.locale;
import core.stdc.string;
//import core.stdc.wchar_;

version (Windows)
{
    import core.sys.windows.windows;
    import std.windows.syserror;

    enum DWORD CP_UTF8 = 65001;
}
else version (Posix)
{
    //import core.sys.posix.iconv;
    //import core.sys.posix.locale;
    //import core.sys.posix.langinfo;
}


version (unittest) import std.array : appender;

private enum BUFFER_SIZE : size_t
{
    mchars = 160,
    chars  = 160,
    wchars =  80,
    dchars =  80,
}
static assert(BUFFER_SIZE.mchars >= 2*MB_LEN_MAX);


//----------------------------------------------------------------------------//
// Versions for platform-dependent features
//----------------------------------------------------------------------------//

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
    version = WCHART_UNICODE_ON_UTF;
    version = HAVE_MBSTATE;
}
else version (Solaris)
{
    version = WCHART_UNICODE_ON_UTF;
    version = HAVE_MBSTATE;
    version = HAVE_ICONV;
}
else static assert(0);

version (WCHART_WCHAR) version = WCHART_UNICODE;
version (WCHART_DCHAR) version = WCHART_UNICODE;

version (WCHART_UNICODE) version = WCHART_UNICODE_ON_UTF;

debug (USE_LIBICONV)
{
    version = HAVE_ICONV;
    pragma(lib, "iconv");
}

version (LittleEndian)
{
    private enum ICONV_DSTRING = "UTF-32LE";
}
else version (BigEndian)
{
    private enum ICONV_DSTRING = "UTF-32BE";
}


//----------------------------------------------------------------------------//

version (Windows)
{
    // WideCharToMultiByte
    version = USE_WINNLS;
    version = PREFER_WSTRING;
}
else
{
    // XXX prefer which?

    version (HAVE_ICONV)
    {
        // iconv UTF-32 --> native
        version = USE_ICONV;
        version = PREFER_DSTRING;
    }
    else
    version (WCHART_DCHAR) version (HAVE_MBSTATE) version (HAVE_MULTILOCALE)
    {
        // uselocale + mbstate_t + wcrtomb
        version = USE_MULTILOCALE;
        version = PREFER_DSTRING;
    }
}


//----------------------------------------------------------------------------//
// Locale information at program startup
//----------------------------------------------------------------------------//

private
{
    version (Windows)
    {
        // ACP at program startup.
        immutable DWORD nativeACP;
    }

    version (Posix)
    {
        // Null-terminated native encoding name guessed from the
        // CODESET langinfo.
        immutable string nativeEncodingz;
    }

    version (HAVE_MULTILOCALE)
    {
        // Hard copy of a locale_t object at program startup.
        __gshared locale_t nativeLocaleCTYPE;
    }

    // Set to true if the native encoding is UTF-8.
    immutable bool isNativeUTF8;

    // Set to true if wchar_t is Unicode on UTF codeset.
    version (WCHART_UNICODE_ON_UTF)
        enum bool isUTFWchartUnicode = true;
    else
        enum bool isUTFWchartUnicode = false;
}

shared static this()
{
    const ctype = setlocale(LC_CTYPE, "");
    scope(exit) setlocale(LC_CTYPE, "C");

    version (Windows)
    {
        nativeACP    = GetACP();
        isNativeUTF8 = (nativeACP == CP_UTF8);
    }

    version (Posix)
    {
        if (auto codeset = nl_langinfo(CODESET))
            nativeEncodingz = codeset[0 .. strlen(codeset) + 1].idup;
        else
            nativeEncodingz = "US-ASCII\0";
        switch (nativeEncodingz)
        {
            case "646\0": nativeEncodingz = "US-ASCII\0"; break;
            case "PCK\0": nativeEncodingz =    "CP932\0"; break;
            default: break;
        }
        assert(nativeEncodingz[$ - 1] == '\0');
        isNativeUTF8 = (nativeEncodingz == "UTF-8\0");
    }

    version (HAVE_MULTILOCALE)
    {
        if (auto newLoc = newlocale(LC_CTYPE_MASK, ctype, null))
            nativeLocaleCTYPE = newLoc;
        else
            nativeLocaleCTYPE = LC_GLOBAL_LOCALE;
    }
}


//----------------------------------------------------------------------------//
// NativeTextEncoder
//----------------------------------------------------------------------------//

/**
 * An output range that converts UTF string or Unicode code point to the
 * corresponding multibyte character sequence in the $(I native multibyte
 * encoding).  The multibyte string is written to another output range
 * $(D Sink).
 *
 * The $(I native multibyte encoding) is determined by:
 * $(UL
 *   $(LI Windows: the ANSI codepage (ACP) at program startup.)
 *   $(LI POSIX systems: The CODESET langinfo of the native environment
 *        LC_CTYPE locale at program startup.)
 * )
 * And $(D NativeTextEncoder) is not affected by dynamic change of the
 * locale.
 */
@system struct NativeTextEncoder(Sink)
    if (isOutputRange!(Sink, const(ubyte)[]))
{
    /**
     * Constructs a $(D NativeTextEncoder) object.
     *
     * Params:
     *   sink =
     *      An output range of type $(D Sink) to put multibyte character
     *      sequence.  $(D Sink) must accept $(D const(ubyte)[]).
     *
     *   replacement =
     *      A valid multibyte character to use when a Unicode character
     *      cannot be represented in the native multibyte character set.
     *      $(D NativeTextEncoder) will throw an $(D EncodingException) on
     *      any non-representable character if $(D replacement) is empty.
     *
     * Throws:
     * $(UL
     *   $(LI $(D enforcement) fails if $(D NativeTextEncoder) could not
     *        figure out a safe mean to convert UTF to native multibyte
     *        encoding.)
     * )
     */
    this(Sink sink, immutable(ubyte)[] replacement = null)
    {
        swap(sink_, sink);
        replacement_ = (replacement.length ? replacement : null);

        if (.isNativeUTF8)
            // Then, the initialization below is unneeded.
            return;

        version (USE_WINNLS)
        {
        }
        else version (USE_ICONV)
        {
            context_          = new Context;
            context_.mbencode = iconv_open(
                    nativeEncodingz.ptr, ICONV_DSTRING);
            errnoEnforce(context_.mbencode != cast(iconv_t) -1,
                    "opening an iconv descriptor");
        }
        else version (USE_MULTILOCALE)
        {
            context_          = new Context;
            context_.narrowen = mbstate_t.init;
            context_.ctype    = errnoEnforce(duplocale(.nativeLocaleCTYPE));
                                // XXX is duplocale necessary?
        }
        else
        {
            enforce(false, "Cannot use NativeTextEncoder under this "
                    ~"environment.");
        }
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
            version (USE_MULTILOCALE)
                freelocale(context_.locale);
            version (USE_ICONV)
                errnoEnforce(iconv_close(context_.mbencode) == 0);
        }
    }


    //----------------------------------------------------------------//
    // output range primitives
    //----------------------------------------------------------------//

    /**
     * Converts a UTF string $(D str) or Unicode code point $(D ch)
     * to the corresponding multibyte string in the native multibyte
     * encoding and puts the multibyte string to the $(D sink).
     *
     * Throws:
     * $(UL
     *   $(LI $(D UtfException) if the argument is invalid.)
     *   $(LI $(D EncodingException) on convertion error.)
     * )
     */
    void put(const char[] str)
    {
        if (.isNativeUTF8)
        {
            if (str.length > 0)
                sink_.put(cast(const(ubyte)[]) str);
            return;
        }

        version (PREFER_WSTRING)
        {
            // Forward to the wstring overload.
            for (const(char)[] inbuf = str; inbuf.length > 0; )
            {
                wchar[BUFFER_SIZE.wchars] tmpbuf = void;
                size_t tmpLen = inbuf.convert(tmpbuf);
                this.put(tmpbuf[0 .. tmpLen]);
            }
        }
        else version (PREFER_DSTRING)
        {
            // Forward to the dstring overload.
            for (const(char)[] inbuf = str; inbuf.length > 0; )
            {
                dchar[BUFFER_SIZE.dchars] tmpbuf = void;
                size_t tmpLen = inbuf.convert(tmpbuf);
                this.put(tmpbuf[0 .. tmpLen]);
            }
        }
        else
        {
            assert(0);
        }
    }


    /**
     * Ditto
     */
    void put(const wchar[] str)
    {
        if (.isNativeUTF8)
        {
            // Trivial UTF transcode.
            for (const(wchar)[] inbuf = str; inbuf.length > 0; )
            {
                char[BUFFER_SIZE.chars] tmpbuf = void;
                size_t tmpLen = inbuf.convert(tmpbuf);
                sink_.put(cast(ubyte[]) tmpbuf[0 .. tmpLen]);
            }
            return;
        }

        version (PREFER_DSTRING)
        {
            // Forward to the dstring overload.
            for (const(wchar)[] inbuf = str; inbuf.length > 0; )
            {
                dchar[BUFFER_SIZE.dchars] tmpbuf = void;
                size_t tmpLen = inbuf.convert(tmpbuf);
                this.put(tmpbuf[0 .. tmpLen]);
            }
        }
        else version (USE_WINNLS)
        {
            convertNext(str);
        }
        else
        {
            assert(0);
        }
    }


    /**
     * Ditto
     */
    void put(const dchar[] str)
    {
        if (.isNativeUTF8)
        {
            // Trivial UTF transcode.
            for (const(dchar)[] inbuf = str; inbuf.length > 0; )
            {
                char[BUFFER_SIZE.chars] tmpbuf = void;
                size_t tmpLen = inbuf.convert(tmpbuf);
                sink_.put(cast(ubyte[]) tmpbuf[0 .. tmpLen]);
            }
            return;
        }

        version (PREFER_WSTRING)
        {
            // Forward to the wstring overload.
            for (const(dchar)[] inbuf = str; inbuf.length > 0; )
            {
                wchar[BUFFER_SIZE.wchars] tmpbuf = void;
                size_t tmpLen = inbuf.convert(tmpbuf);
                this.put(tmpbuf[0 .. tmpLen]);
            }
        }
        else version (USE_ICONV)
        {
            convertNext(str);
        }
        else version (USE_MULTILOCALE)
        {
            convertNext(str);
        }
        else
        {
            assert(0);
        }
    }


    /**
     * Ditto
     */
    void put(dchar ch)
    {
        if (.isNativeUTF8)
        {
            char[4] tmp = void;
            size_t width = encode(tmp, ch);
            sink_.put(cast(ubyte[]) tmp[0 .. width]);
        }
        else
        {
            this.put((&ch)[0 .. 1]);
        }
    }


    //----------------------------------------------------------------//
    // internal put(string) implementation
    //----------------------------------------------------------------//
private:

    /*
     * Converts a UTF-16 string to the corresponding native multibyte
     * string using WideCharToMultiByte().
     */
    version (USE_WINNLS)
    void convertNext(const wchar[] str)
    {
        if (str.length == 0)
            return;

        ubyte[BUFFER_SIZE.mchars] stock = void;
        ubyte[]                   mbbuf;
        size_t                    mbLen;
        BOOL                      cannotMap;

        mbLen = WideCharToMultiByte(
                nativeACP, 0, str.ptr, str.length, null, 0,
                cast(char*) replacement_.ptr, &cannotMap);
        enforce(mbLen != 0, sysErrorString(GetLastError()));
        if (replacement_.length == 0 && cannotMap)
            throw new EncodingException("Cannot represent a Unicode "
                    ~"character in the native multibyte encoding");

        if (mbLen <= stock.length)
            mbbuf = stock[0 .. mbLen];
        else
            mbbuf = new ubyte[mbLen];

        mbLen = WideCharToMultiByte(
                nativeACP, 0, str.ptr, str.length,
                cast(char*) mbbuf.ptr, mbbuf.length,
                cast(char*) replacement_.ptr, null);
        enforce(mbLen != 0, sysErrorString(GetLastError()));

        sink_.put(mbbuf[0 .. mbLen]);
    }


    /*
     * Converts a UTF-32 string to the corresponding native multibyte
     * string using iconv().
     */
    version (USE_ICONV)
    void convertNext(const dchar[] str)
    {
        auto psrc    = cast(const(ubyte)*) str.ptr;
        auto srcLeft = dchar.sizeof * str.length;

        // The stack-allocated stock suffices most cases.  GC-alloc
        // will be used only when iconv() raised an E2BIG.
        ubyte[BUFFER_SIZE.mchars] stock = void;
        ubyte[]                   mbuf  = stock;

        // Last convertion ended with an incomplete code point.
        // (Maybe a variation selector?)
        if (srcLeft > 0 && context_.memorandum != dchar.init)
        {
            dchar[2] combo = void;
            combo[0] = context_.memorandum;
            combo[1] = *psrc;

            auto pcombo    = cast(const(ubyte)*) combo.ptr;
            auto comboLeft = combo.length;
            auto pbuf      = mbuf.ptr;
            auto bufLeft   = mbuf.length;

            const stat = iconv(context_.mbencode,
                    &pcombo, &comboLeft, &pbuf, &bufLeft);
            if (stat == cast(size_t) -1)
            {
                errnoEnforce(errno == EILSEQ, "on iconv()");
                if (replacement_.length == 0)
                    throw new EncodingException(
                        "Cannot represent a Unicode character in the "
                        ~"native multibyte encoding");
                sink_.put(replacement_);
            }
            else
            {
                sink_.put(mbuf[0 .. $ - bufLeft]);
            }

            // OK, consumed the combinated dchars.
            context_.memorandum = dchar.init;
            ++psrc;
            --srcLeft;
        }

        // Consume the entire source.
        while (srcLeft > 0)
        {
            auto pbuf    = mbuf.ptr;
            auto bufLeft = mbuf.length;

            const stat = iconv(context_.mbencode,
                    &psrc, &srcLeft, &pbuf, &bufLeft);
            auto iconvErrno = errno;

            // Output converted characters (available even on error).
            if (bufLeft < mbuf.length)
                sink_.put(mbuf[0 .. $ - bufLeft]);

            if (stat == cast(size_t) -1) switch (errno = iconvErrno)
            {
                // Could not represent *psrc in the native encoding.
                // Recover with a replacement string if any.
                case EILSEQ:
                    if (replacement_.length == 0)
                        throw new EncodingException(
                            "Cannot represent a Unicode character in the "
                            ~"native multibyte encoding");
                    sink_.put(replacement_);
                    psrc    += dchar.sizeof;
                    srcLeft -= dchar.sizeof;
                    break;

                // The input string ends with some incomplete code point.
                // Queue it in the context and finish.
                case EINVAL:
                    assert(srcLeft == 1);
                    context_.memorandum = *cast(const dchar*) psrc;
                    srcLeft = 0;
                    break;

                // Insufficient output buffer.  Extend the buffer and
                // continue.
                case E2BIG:
                    mbuf = new ubyte[mbuf.length * 2];
                    break;

                default:
                    errnoEnforce(0, "on iconv()");
                    assert(0);
            }
        }
    }


    /*
     * Converts a UTF-32 string to the corresponding native multibyte
     * string using wcrtomb().
     */
    version (USE_MULTILOCALE)
    void convertNext(const dchar[] str)
    {
        auto origLoc = errnoEnforce(uselocale(context_.ctype));
        scope(exit) errnoEnforce(uselocale(origLoc));

        // Convert UTF-32 to multibyte char-by-char with buffering.
        ubyte[BUFFER_SIZE.mchars] mbuf     = void;
        size_t                    mbufUsed = 0;

        for (const(dchar)[] inbuf = str; inbuf.length > 0; )
        {
            if (mbufUsed >= mbuf.length - MB_CUR_MAX)
            {
                sink_.put(mbuf[0 .. mbufUsed]);
                mbufUsed = 0;
            }

            const mbLen = wcrtomb(cast(char*) &mbuf[mbufUsed],
                    inbuf[0], &context_.narrowen);
            inbuf = inbuf[1 .. $];

            if (mbLen == cast(size_t) -1)
            {
                errnoEnforce(errno == EILSEQ, "on wcrtomb()");

                // Could not represent inbuf[0] in the native encoding.
                // We can recover from this error with a replacement.
                if (replacement_.length == 0)
                    throw new EncodingException(
                        "Cannot represent  a Unicode character in the "
                        ~"native multibyte character sequence");

                // Write the successfully converted substring and the
                // replacement string.
                if (mbufUsed > 0)
                    sink_.put(mbuf[0 .. mbufUsed]);
                sink_.put(replacement_);
                mbufUsed = 0;

                // The shift state is undefined; XXX reset.
                context_.narrowen = mbstate_t.init;
            }
            else
            {
                mbufUsed += mbLen;
            }
        }

        // Flush any remaining chars.
        if (mbufUsed > 0)
            sink_.put(mbuf[0 .. mbufUsed]);
    }


    //----------------------------------------------------------------//
private:
    Sink               sink_;
    immutable(ubyte)[] replacement_;
    Context*           context_;

    struct Context
    {
        version (USE_ICONV)
        {
            iconv_t     mbencode;   // UTF-32 -> multibyte descriptor
            dchar       memorandum; // unfinished code point
        }
        version (USE_MULTILOCALE)
        {
            locale_t    ctype;      // CTYPE-masked locale object to use
            mbstate_t   narrowen;   // wide -> multibyte shift state
        }
        uint refCount = 1;
    }
}

unittest
{
    version (Posix) if (.nativeEncodingz == "eucJP\0" ||
                        .nativeEncodingz == "EUC-JP\0")
    {
        ubyte[] mbs;
        auto r = appender(&mbs);
        auto w = NativeTextEncoder!(typeof(r))(r);
        w.put("1 \u6d88\u3048\u305f 2"c);
        w.put("3 \u624b\u888b\u306e 4"w);
        w.put("5 \u3086\u304f\u3048 6"d);
        w.put(""c);
        w.put('\u2026');
        w.put('/');
        assert(cast(string) mbs ==
                "\x31\x20\xbe\xc3\xa4\xa8\xa4\xbf\x20\x32"
                ~"\x33\x20\xbc\xea\xc2\xde\xa4\xce\x20\x34"
                ~"\x35\x20\xa4\xe6\xa4\xaf\xa4\xa8\x20\x36"
                ~"\xa1\xc4\x2f");
        // replacement
        r.clear();
        w = NativeTextEncoder!(typeof(r))(r, cast(immutable ubyte[]) "#");
        w.put("123 \u05de\u05d2\u05d3\u05dc\U00026951 abc"c);
        assert(cast(string) mbs == "123 ##### abc");
        //
        w = NativeTextEncoder!(typeof(r))(r);
        try
        {
            w.put("\U00026951"c);
            assert(0);
        }
        catch (EncodingException ee) {}
    }
    version (Windows) if (.nativeACP == 932)
    {
        ubyte[] mbs;
        auto r = appender(&mbs);
        auto w = NativeTextEncoder!(typeof(r))(r);
        w.put("1 \u6d88\u3048\u305f 2"c);
        w.put("3 \u624b\u888b\u306e 4"w);
        w.put("5 \u3086\u304f\u3048 6"d);
        w.put(""c);
        w.put('\u2026');
        w.put('/');
        assert(cast(string) mbs ==
                "\x31\x20\x8f\xc1\x82\xa6\x82\xbd\x20\x32"
                ~"\x33\x20\x8e\xe8\x91\xdc\x82\xcc\x20\x34"
                ~"\x35\x20\x82\xe4\x82\xad\x82\xa6\x20\x36"
                ~"\x81\x63\x2f");
    }
}


//----------------------------------------------------------------------------//
// WideTextEncoder
//----------------------------------------------------------------------------//

private// Is this worth making public?
/*
 * An output range that converts UTF string or Unicode code point to the
 * corresponding wide character sequence in the $(I native character
 * codeset).  The multibyte string is written to another output range
 * $(D Sink).
 */
@system struct _WideTextEncoder(Sink)
    if (isOutputRange!(Sink, wchar_t) &&
        isOutputRange!(Sink, const(wchar_t)[]))
{
    /**
     * Constructs a $(D WideTextEncoder) object.
     *
     * Params:
     *   sink =
     *      An output range of type $(D Sink) to put wide character
     *      sequence.  $(D Sink) must accept $(D wchar_t) and
     *      $(D const(wchar_t)[]).
     *
     *   replacement =
     *      A valid multibyte character to use when a Unicode character
     *      cannot be represented in the native character set.
     *      $(D WideTextEncoder) will throw an $(D EncodingException) on
     *      any non-representable character if $(D replacement) is empty.
     *
     * Throws:
     * $(UL
     *   $(LI $(D enforcement) fails if $(D WideTextEncoder) could not
     *        figure out a safe mean to convert UTF to native wide
     *        character encoding.)
     * )
     *
     * Note:
     * The $(D replacement) being multibyte is intentional because on
     * CSI (codeset independent) platforms it is generally difficalt
     * for human to write wide character sequence.
     */
    this(Sink sink, immutable(ubyte)[] replacement = null)
    {
        version (WCHART_UNICODE)
        {
            // Pass-thru mode.
            swap(sink_, sink);
            cast(void) replacement;
        }
        else
        {
            if (.isNativeUTF8 && .isUTFWchartUnicode)
            {
                // Pass-thru mode.
                swap(sink_, sink);
                return;
            }
            // First represent UTF text in the native multibyte encoding.
            // Then widen it with _NativeTextWidener.
            proxy_ = NativeTextEncoder!(_NativeTextWidener!(Sink))(
                    _NativeTextWidener!(Sink)(sink), replacement);
        }
    }


    //----------------------------------------------------------------//
    // output range primitives
    //----------------------------------------------------------------//

    /**
     * Converts a UTF string $(D str) or Unicode code point $(D ch)
     * to the corresponding wide string in the native codeset and
     * puts the wide string to the $(D sink).
     *
     * Throws:
     * $(UL
     *   $(LI $(D UtfException) if the argument is invalid.)
     *   $(LI $(D EncodingException) on convertion error.)
     * )
     */
    void put(const char[] str)
    {
        version (WCHART_WCHAR)
        {
            passThruWstring(str);
        }
        else version (WCHART_DCHAR)
        {
            passThruDstring(str);
        }
        else
        {
            if (.isNativeUTF8 && .isUTFWchartUnicode)
            {
                passThruDstring(str);
            }
            else
            {
                proxy_.put(str);
            }
        }
    }


    /**
     * Ditto
     */
    void put(const wchar[] str)
    {
        version (WCHART_WCHAR)
        {
            sink_.put(str);
        }
        else version (WCHART_DCHAR)
        {
            passThruDstring(str);
        }
        else
        {
            if (.isNativeUTF8 && .isUTFWchartUnicode)
            {
                passThruDstring(str);
            }
            else
            {
                proxy_.put(str);
            }
        }
    }


    /**
     * Ditto
     */
    void put(const dchar[] str)
    {
        version (WCHART_WCHAR)
        {
            passThruWstring(str);
        }
        else version (WCHART_DCHAR)
        {
            sink_.put(str);
        }
        else
        {
            if (.isNativeUTF8 && .isUTFWchartUnicode)
            {
                sink_.put(cast(const(wchar_t)[]) str);
            }
            else
            {
                proxy_.put(str);
            }
        }
    }


    /**
     * Ditto
     */
    void put(dchar ch)
    {
        version (WCHART_WCHAR)
        {
            wchar[2] wch = void;
            if (encode(wch, ch) == 1)
                sink_.put(wch[0]);
            else
                sink_.put(wch[]);
        }
        else version (WCHART_DCHAR)
        {
            sink_.put(ch);
        }
        else
        {
            if (.isNativeUTF8 && .isUTFWchartUnicode)
            {
                sink_.put(cast(wchar_t) ch);
            }
            else
            {
                proxy_.put(ch);
            }
        }
    }


    //----------------------------------------------------------------//
private:

    void passThruWstring(Char)(const(Char)[] str)
        if (is(Char == char) || is(Char == dchar))
    {
        for (const(Char)[] inbuf = str; inbuf.length > 0; )
        {
            wchar[BUFFER_SIZE.wchars] wsbuf = void;
            size_t                    wsLen;
            wsLen = inbuf.convert(wsbuf);
            sink_.put(cast(const(wchar_t)[]) wsbuf[0 .. wsLen]);
        }
    }

    void passThruDstring(Char)(const(Char)[] str)
        if (is(Char == char) || is(Char == wchar))
    {
        for (const(Char)[] inbuf = str; inbuf.length > 0; )
        {
            dchar[BUFFER_SIZE.dchars] dsbuf = void;
            size_t                    dsLen;
            dsLen = inbuf.convert(dsbuf);
            sink_.put(cast(const(wchar_t)[]) dsbuf[0 .. dsLen]);
        }
    }


    //----------------------------------------------------------------//
private:
    Sink sink_;

    version (WCHART_UNICODE)
    {
    }
    else
    {
        NativeTextEncoder!(_NativeTextWidener!(Sink)) proxy_;
    }
}

unittest
{
    version (Posix) if (.nativeEncodingz ==     "eucJP\0" ||
                        .nativeEncodingz ==    "EUC-JP\0" ||
                        .nativeEncodingz ==      "SJIS\0" ||
                        .nativeEncodingz == "Shift_JIS\0" ||
                        .nativeEncodingz ==     "UTF-8\0")
    {
        wchar_t[] wcs;
        auto r = appender(&wcs);
        try
        {
            auto w = _WideTextEncoder!(typeof(r))(r);
            w.put("\u3054\u306f\u3093\u304b"c);
            w.put("\u3051\u305f"w);
            w.put("\u307e"d);
            w.put('\u3054');
            assert(wcs.length == 8);
        }
        catch (Exception e)
        {
            assert(0, e.toString());
        }
    }
    version (Windows) if (.nativeACP == 932)
    {
        wchar_t[] wcs;
        auto r = appender(&wcs);
        auto w = _WideTextEncoder!(typeof(r))(r);
        w.put("\u3054\u306f\u3093\u304b"c);
        w.put("\u3051\u305f"w);
        w.put("\u307e"d);
        w.put('\u3054');
        assert(wcs == "\u3054\u306f\u3093\u304b\u3051\u305f\u307e\u3054"w);
    }
}


//----------------------------------------------------------------------------//

/*
 * [internal]
 * An output range that converts native multibyte string to the corresponding
 * wide character sequence in the native character codeset.  The wide string
 * is written to another output range $(D Sink).
 */
private @system struct _NativeTextWidener(Sink)
    if (isOutputRange!(Sink, const(wchar_t)[]))
{
    /**
     * Constructs a $(D _NativeTextWidener) object.
     *
     * Params:
     *   sink =
     *      An output range of type $(D Sink) to put wide character
     *      sequence.  $(D Sink) must accept $(D const(wchar_t)[]).
     *
     * Throws:
     * $(UL
     *   $(LI $(D enforcement) fails if $(D _NativeTextWidener) could not
     *        figure out a safe mean to convert multibyte string to wide
     *        string under the platform.)
     * )
     */
    this(Sink sink)
    {
        swap(sink_, sink);

        if (.isNativeUTF8 && .isUTFWchartUnicode)
            // Then, the initialization below is unneeded.
            return;

        version (USE_MULTILOCALE)
        {
            context_       = new Context;
            context_.widen = mbstate_t.init;
            context_.ctype = errnoEnforce(duplocale(.nativeLocaleCTYPE));
                           // XXX is duplocale necessary?
        }
        else
        {
            enforce(false, "Cannot figure out a safe mean to convert "
                    ~"multibyte string to wide string");
        }
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
            version (USE_MULTILOCALE)
                freelocale(context_.ctype);
        }
    }


    //----------------------------------------------------------------//
    // output range primitive implementation
    //----------------------------------------------------------------//

    /**
     * Widens the given multibyte string.
     */
    void put(const ubyte[] mbs)
    {
        if (.isNativeUTF8 && .isUTFWchartUnicode)
        {
            // Trivial UTF convertion.
            version (WCHART_WCHAR)
                alias wchar WcharT;
            else
                alias dchar WcharT;

            for (auto inbuf = cast(const(char)[]) mbs; inbuf.length > 0; )
            {
                WcharT[BUFFER_SIZE.wchars] wsbuf = void;
                size_t                     wsLen;
                wsLen = inbuf.convert(wsbuf);
                sink_.put(cast(const(wchar_t)[]) wsbuf[0 .. wsLen]);
            }
            return;
        }

        version (USE_MULTILOCALE)
        {
            // Use wcrtomb.
            auto origLoc = errnoEnforce(uselocale(context_.ctype));
            scope(exit) errnoEnforce(uselocale(origLoc));

            // Convert multibyte to wide with buffering.
            wchar_t[BUFFER_SIZE.wchars] wbuf     = void;
            size_t                      wbufUsed = 0;

            for (const(char)[] inbuf = mbs; inbuf.length > 0; )
            {
                if (wbufUsed == wbuf.length)
                {
                    sink_.put(wbuf[]);
                    wbufUsed = 0;
                }

                size_t mbcLen = mbrtowc(&wbuf[wbufUsed],
                        inbuf.ptr, inbuf.length, &context_.widen);
                if (mbcLen == cast(size_t) -1)
                {
                    // No EILSEQ recovery here -- multibyte string should
                    // be convertible to wide string.
                    if (errno == EILSEQ)
                        throw new EncodingException("Encountered an "
                                ~"illegal multibyte character");
                    errnoEnforce(0);
                }

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
        else
        {
            assert(0);
        }
    }


    //----------------------------------------------------------------//
private:
    Sink     sink_;
    Context* context_;

    struct Context
    {
        version (HAVE_MULTILOCALE)
        {
            locale_t  ctype;    // native CTYPE locale object
            mbstate_t widen;    // multibyte --> wide
        }
        uint refCount = 1;
    }
}


//-/////////////////////////////////////////////////////////////////////////////
// std.utf extension
//-/////////////////////////////////////////////////////////////////////////////

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
                throw new UtfException("illegal code point", c);
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
                throw new UtfException("illegal code point", c);
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


//-/////////////////////////////////////////////////////////////////////////////
// druntime fix
//-/////////////////////////////////////////////////////////////////////////////
private:

// fix  core.stdc.locale
// fix  core.stdc.wchar
// add  core.sys.posix.iconv
// add  core.sys.posix.locale
// add  core.sys.posix.langinfo

alias int c_int;


//----------------------------------------------------------------------------//
// fix - core.stdc.locale
//----------------------------------------------------------------------------//

import core.stdc.locale : lconv, localeconv, setlocale;

version (Windows)
{
    enum
    {
        LC_ALL,
        LC_COLLATE,
        LC_CTYPE,
        LC_MONETARY,
        LC_NUMERIC,
        LC_TIME,
    }
}
else version (linux)
{
    enum
    {
        LC_CTYPE,
        LC_NUMERIC,
        LC_TIME,
        LC_COLLATE,
        LC_MONETARY,
        LC_MESSAGES,
        LC_ALL,
        LC_PAPER,
        LC_NAME,
        LC_ADDRESS,
        LC_TELEPHONE,
        LC_MEASUREMENT,
        LC_IDENTIFICATION,
    }
}
else version (OSX)
{
    enum
    {
        LC_ALL,
        LC_COLLATE,
        LC_CTYPE,
        LC_MONETARY,
        LC_NUMERIC,
        LC_TIME,
        LC_MESSAGES,
    }
}
else version (FreeBSD)
{
    enum
    {
        LC_ALL,
        LC_COLLATE,
        LC_CTYPE,
        LC_MONETARY,
        LC_NUMERIC,
        LC_TIME,
        LC_MESSAGES,
    }
}
else version (Solaris)
{
    enum
    {
        LC_CTYPE,
        LC_NUMERIC,
        LC_TIME,
        LC_COLLATE,
        LC_MONETARY,
        LC_MESSAGES,
        LC_ALL,
    }
}
else static assert(0);


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
        c_int   count;
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
        size_t  iconv(iconv_t, in ubyte**, size_t*, ubyte**, size_t*);
        c_int   iconv_close(iconv_t);
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

        enum
        {
             LC_CTYPE_MASK           = 1 << LC_CTYPE,
             LC_NUMERIC_MASK         = 1 << LC_NUMERIC,
             LC_TIME_MASK            = 1 << LC_TIME,
             LC_COLLATE_MASK         = 1 << LC_COLLATE,
             LC_MONETARY_MASK        = 1 << LC_MONETARY,
             LC_MESSAGES_MASK        = 1 << LC_MESSAGES,
             LC_PAPER_MASK           = 1 << LC_PAPER,
             LC_NAME_MASK            = 1 << LC_NAME,
             LC_ADDRESS_MASK         = 1 << LC_ADDRESS,
             LC_TELEPHONE_MASK       = 1 << LC_TELEPHONE,
             LC_MEASUREMENT_MASK     = 1 << LC_MEASUREMENT,
             LC_IDENTIFICATION_MASK  = 1 << LC_IDENTIFICATION,
             LC_ALL_MASK             = LC_CTYPE_MASK | LC_NUMERIC_MASK |
                 LC_TIME_MASK | LC_COLLATE_MASK | LC_MONETARY_MASK |
                 LC_MESSAGES_MASK | LC_PAPER_MASK | LC_NAME_MASK |
                 LC_ADDRESS_MASK | LC_TELEPHONE_MASK | LC_MEASUREMENT_MASK |
                 LC_IDENTIFICATION_MASK,
        }
    }
    else version (OSX)
    {
        enum LC_GLOBAL_LOCALE = cast(locale_t) -1;

        enum
        {
            LC_COLLATE_MASK  = 1 << 0,
            LC_CTYPE_MASK    = 1 << 1,
            LC_MESSAGES_MASK = 1 << 2,
            LC_MONETARY_MASK = 1 << 3,
            LC_NUMERIC_MASK  = 1 << 4,
            LC_TIME_MASK     = 1 << 5,
            LC_ALL_MASK      = LC_COLLATE_MASK | LC_CTYPE_MASK |
                LC_MESSAGES_MASK | LC_MONETARY_MASK | LC_NUMERIC_MASK |
                LC_TIME_MASK,
        }
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
    version (linux)
    {
        alias c_int nl_item;

        private @safe pure nothrow
            nl_item _NL_ITEM(int category, int index)
        {
            return (category << 16) | index;
        }

        enum
        {
            ABDAY_1 = _NL_ITEM(LC_TIME, 0),
            ABDAY_2,
            ABDAY_3,
            ABDAY_4,
            ABDAY_5,
            ABDAY_6,
            ABDAY_7,
            DAY_1,
            DAY_2,
            DAY_3,
            DAY_4,
            DAY_5,
            DAY_6,
            DAY_7,
            ABMON_1,
            ABMON_2,
            ABMON_3,
            ABMON_4,
            ABMON_5,
            ABMON_6,
            ABMON_7,
            ABMON_8,
            ABMON_9,
            ABMON_10,
            ABMON_11,
            ABMON_12,
            MON_1,
            MON_2,
            MON_3,
            MON_4,
            MON_5,
            MON_6,
            MON_7,
            MON_8,
            MON_9,
            MON_10,
            MON_11,
            MON_12,
            AM_STR,
            PM_STR,
            D_T_FMT,
            D_FMT,
            T_FMT,
            T_FMT_AMPM,
            ERA,
            ERA_YEAR,
            ERA_D_FMT,
            ALT_DIGITS,
            ERA_D_T_FMT,
            ERA_T_FMT,
            _NL_TIME_NUM_ALT_DIGITS,
            _NL_TIME_ERA_NUM_ENTRIES,
            _NL_TIME_ERA_ENTRIES_EB,
            _NL_TIME_ERA_ENTRIES_EL,
            _NL_NUM_LC_TIME,

            _NL_COLLATE_NRULES = _NL_ITEM(LC_COLLATE, 0),
            _NL_COLLATE_RULES,
            _NL_COLLATE_HASH_SIZE,
            _NL_COLLATE_HASH_LAYERS,
            _NL_COLLATE_TABLE_EB,
            _NL_COLLATE_TABLE_EL,
            _NL_COLLATE_UNDEFINED,
            _NL_COLLATE_EXTRA_EB,
            _NL_COLLATE_EXTRA_EL,
            _NL_COLLATE_ELEM_HASH_SIZE,
            _NL_COLLATE_ELEM_HASH_EB,
            _NL_COLLATE_ELEM_HASH_EL,
            _NL_COLLATE_ELEM_STR_POOL,
            _NL_COLLATE_ELEM_VAL_EB,
            _NL_COLLATE_ELEM_VAL_EL,
            _NL_COLLATE_SYMB_HASH_SIZE,
            _NL_COLLATE_SYMB_HASH_EB,
            _NL_COLLATE_SYMB_HASH_EL,
            _NL_COLLATE_SYMB_STR_POOL,
            _NL_COLLATE_SYMB_CLASS_EB,
            _NL_COLLATE_SYMB_CLASS_EL,
            _NL_NUM_LC_COLLATE,

            _NL_CTYPE_CLASS = _NL_ITEM(LC_CTYPE, 0),
            _NL_CTYPE_TOUPPER_EB,
            _NL_CTYPE_TOLOWER_EB,
            _NL_CTYPE_TOUPPER_EL,
            _NL_CTYPE_TOLOWER_EL,
            _NL_CTYPE_CLASS32,
            _NL_CTYPE_NAMES_EB,
            _NL_CTYPE_NAMES_EL,
            _NL_CTYPE_HASH_SIZE,
            _NL_CTYPE_HASH_LAYERS,
            _NL_CTYPE_CLASS_NAMES,
            _NL_CTYPE_MAP_NAMES,
            _NL_CTYPE_WIDTH,
            _NL_CTYPE_MB_CUR_MAX,
            _NL_CTYPE_CODESET_NAME,
            CODESET = _NL_CTYPE_CODESET_NAME,
            _NL_NUM_LC_CTYPE,

            INT_CURR_SYMBOL = _NL_ITEM(LC_MONETARY, 0),
            CURRENCY_SYMBOL,
            CRNCYSTR = CURRENCY_SYMBOL,
            MON_DECIMAL_POINT,
            MON_THOUSANDS_SEP,
            MON_GROUPING,
            POSITIVE_SIGN,
            NEGATIVE_SIGN,
            INT_FRAC_DIGITS,
            FRAC_DIGITS,
            P_CS_PRECEDES,
            P_SEP_BY_SPACE,
            N_CS_PRECEDES,
            N_SEP_BY_SPACE,
            P_SIGN_POSN,
            N_SIGN_POSN,
            _NL_NUM_LC_MONETARY,

            DECIMAL_POINT = _NL_ITEM(LC_NUMERIC, 0),
            RADIXCHAR = DECIMAL_POINT,
            THOUSANDS_SEP,
            THOUSEP = THOUSANDS_SEP,
            GROUPING,
            _NL_NUM_LC_NUMERIC,

            YESEXPR = _NL_ITEM(LC_MESSAGES, 0),
            NOEXPR,
            YESSTR,
            NOSTR,
            _NL_NUM_LC_MESSAGES,

            _NL_NUM
        }
    }
    else version (OSX)
    {
        alias c_int nl_item;

        enum
        {
            CODESET = 0,
            D_T_FMT,
            D_FMT,
            T_FMT,
            T_FMT_AMPM,
            AM_STR,
            PM_STR,
            DAY_1,
            DAY_2,
            DAY_3,
            DAY_4,
            DAY_5,
            DAY_6,
            DAY_7,
            ABDAY_1,
            ABDAY_2,
            ABDAY_3,
            ABDAY_4,
            ABDAY_5,
            ABDAY_6,
            ABDAY_7,
            MON_1,
            MON_2,
            MON_3,
            MON_4,
            MON_5,
            MON_6,
            MON_7,
            MON_8,
            MON_9,
            MON_10,
            MON_11,
            MON_12,
            ABMON_1,
            ABMON_2,
            ABMON_3,
            ABMON_4,
            ABMON_5,
            ABMON_6,
            ABMON_7,
            ABMON_8,
            ABMON_9,
            ABMON_10,
            ABMON_11,
            ABMON_12,
            ERA,
            ERA_D_FMT,
            ERA_D_T_FMT,
            ERA_T_FMT,
            ALT_DIGITS,
            RADIXCHAR,
            THOUSEP,
            YESEXPR,
            NOEXPR,
            YESSTR,
            NOSTR,
            CRNCYSTR,
            D_MD_ORDER,
        }
    }
    else version (FreeBSD)
    {
        alias c_int nl_item;

        enum
        {
            CODESET = 0,
            D_T_FMT,
            D_FMT,
            T_FMT,
            T_FMT_AMPM,
            AM_STR,
            PM_STR,
            DAY_1,
            DAY_2,
            DAY_3,
            DAY_4,
            DAY_5,
            DAY_6,
            DAY_7,
            ABDAY_1,
            ABDAY_2,
            ABDAY_3,
            ABDAY_4,
            ABDAY_5,
            ABDAY_6,
            ABDAY_7,
            MON_1,
            MON_2,
            MON_3,
            MON_4,
            MON_5,
            MON_6,
            MON_7,
            MON_8,
            MON_9,
            MON_10,
            MON_11,
            MON_12,
            ABMON_1,
            ABMON_2,
            ABMON_3,
            ABMON_4,
            ABMON_5,
            ABMON_6,
            ABMON_7,
            ABMON_8,
            ABMON_9,
            ABMON_10,
            ABMON_11,
            ABMON_12,
            ERA,
            ERA_D_FMT,
            ERA_D_T_FMT,
            ERA_T_FMT,
            ALT_DIGITS,
            RADIXCHAR,
            THOUSEP,
            YESEXPR,
            NOEXPR,
            YESSTR,
            NOSTR,
            CRNCYSTR,
            D_MD_ORDER,
            ALTMON_1,
            ALTMON_2,
            ALTMON_3,
            ALTMON_4,
            ALTMON_5,
            ALTMON_6,
            ALTMON_7,
            ALTMON_8,
            ALTMON_9,
            ALTMON_10,
            ALTMON_11,
            ALTMON_12,
        }
    }
    else version (Solaris)
    {
        alias c_int nl_item;

        enum
        {
            DAY_1 = 1,
            DAY_2,
            DAY_3,
            DAY_4,
            DAY_5,
            DAY_6,
            DAY_7,
            ABDAY_1,
            ABDAY_2,
            ABDAY_3,
            ABDAY_4,
            ABDAY_5,
            ABDAY_6,
            ABDAY_7,
            MON_1,
            MON_2,
            MON_3,
            MON_4,
            MON_5,
            MON_6,
            MON_7,
            MON_8,
            MON_9,
            MON_10,
            MON_11,
            MON_12,
            ABMON_1,
            ABMON_2,
            ABMON_3,
            ABMON_4,
            ABMON_5,
            ABMON_6,
            ABMON_7,
            ABMON_8,
            ABMON_9,
            ABMON_10,
            ABMON_11,
            ABMON_12,
            RADIXCHAR,
            THOUSEP,
            YESSTR,
            NOSTR,
            CRNCYSTR,
            D_T_FMT,
            D_FMT,
            T_FMT,
            AM_STR,
            PM_STR,
            CODESET,
            T_FMT_AMPM,
            ERA,
            ERA_D_FMT,
            ERA_D_T_FMT,
            ERA_T_FMT,
            ALT_DIGITS,
            YESEXPR,
            NOEXPR,
            _DATE_FMT,
            MAXSTRMSG,
        }
    }
    else static assert(0);

    extern(C) @system
    {
        char* nl_langinfo(nl_item);
        char* nl_langinfo_l(nl_item, locale_t);
    }
}

