
import std.format;
import std.stdio;

import core.stdc.locale;

void main()
{
    setlocale(LC_CTYPE, "ja_JP.eucJP");
//  setlocale(LC_CTYPE, "ja_JP.UTF-8");
//  setlocale(LC_CTYPE, "Japanese_Japan.932");
//  setlocale(LC_CTYPE, "ja_JP.UTF-8");

//  auto sink = File("a.txt", "w");
//  auto sink = stderr;
//  auto sink = stdout;

    fwide(sink.getFP(), -1);
//  fwide(sink.getFP(),  1);

    {
        auto w = LockingNativeTextWriter(sink, "<?>");
        //auto w = File.LockingTextWriter(sink);
        //formattedWrite(w, "<< %s = %s%s%s >>\n", "λ", "α"w, '∧', "β"d);

        foreach (i; 0 .. 1_000_000)
        //foreach (i; 0 .. 100_000)
        //foreach (i; 0 .. 10)
            w.put("安倍川もち 生八つ橋 なごやん 雪の宿\n");
    }
    sink.writeln("...");
}

// LockingNativeTextWriter, narrow, UTF-8, 1_000_000, to file
//      2.08s user 0.19s system 94% cpu 2.398 total

// LockingNativeTextWriter, narrow, eucJP, 1_000_000, to file
//      2.59s user 0.14s system 96% cpu 2.814 total

// LockingTextWriter, wide, UTF-8, 1_000_000, to file
//      2.72s user 0.16s system 99% cpu 2.910 total

// LockingTextWriter, narrow, UTF-8, 1_000_000, to file
//      0.88s user 0.19s system 62% cpu 1.729 total

// use libiconv for debugging
version (FreeBSD) debug = WITH_LIBICONV;


////////////////////////////////////////////////////////////////////////////////
// LockingNativeTextWriter
////////////////////////////////////////////////////////////////////////////////

import core.stdc.wchar_ : fwide;

import std.algorithm;
import std.contracts;
import std.range;
import std.traits;


version (Windows) private
{
    import core.sys.windows.windows;

    version (DigitalMars)
    {
        extern(C)
        {
            int isatty(int);
            extern __gshared HANDLE[_NFILE] _osfhnd;
        }

        int fileno(FILE* f) { return f._file; }
        HANDLE osfhnd(FILE* f) { return _osfhnd[fileno(f)]; }
    }
    else
    {
        // fileno(), isatty(), osfhnd()
        static assert(0);
    }

    immutable typeof(WriteConsoleW)* indirectWriteConsoleW;
    static this()
    {
        indirectWriteConsoleW = cast(typeof(indirectWriteConsoleW))
            GetProcAddress(GetModuleHandleA("kernel32.dll"), "WriteConsoleW");
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
        useWide_ = (fwide(file_.p.handle, 0) > 0);

        FLOCK(file_.p.handle);
        auto handle = cast(_iobuf*) file_.p.handle;

        version (Windows)
        {
            // can we use WriteConsoleW()?
            useWinConsole_ = (indirectWriteConsoleW !is null &&
                    isatty(fileno(file_.p.handle)));
            if (useWinConsole_)
            {
                fflush(file_.p.handle); // need to sync
                return; // we won't use narrow/wideWriter
            }
        }

        // This should be in File.open() for tracking convertion state.
        if (useWide_)
            wideWriter_ =
                WideWriter(UnsharedWidePutter(handle), replacement);
        else
            narrowWriter_ =
                NarrowWriter(UnsharedNarrowPutter(handle), replacement);
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
        version (Windows)
        {
            if (useWinConsole_)
                return putConsoleW(osfhnd(file_.getFP()), writeme);
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
    version (Windows)
    {
        enum size_t BUFFER_SIZE = 80;

        void putConsoleW(HANDLE console, dchar c)
        {
            if (c <= 0xFFFF)
            {
                indirectWriteConsoleW(console,
                        cast(wchar*) &c, 1, null, null);
            }
            else
            {
                wchar[2] wbuf = void;
                encode(wbuf, c);
                indirectWriteConsoleW(console,
                        wbuf.ptr, 2, null, null);
            }
        }

        void putConsoleW(HANDLE console, in char[] str)
        {
            for (const(char)[] inbuf = str; inbuf.length > 0; )
            {
                wchar[BUFFER_SIZE] wbuf = void;
                const wsLen = inbuf.convert(wbuf);
                indirectWriteConsoleW(console,
                        wbuf.ptr, wsLen, null, null);
            }
        }

        void putConsoleW(HANDLE console, in wchar[] str)
        {
            indirectWriteConsoleW(console,
                    str.ptr, str.length, null, null);
        }

        void putConsoleW(HANDLE console, in dchar[] str)
        {
            for (const(dchar)[] inbuf = str; inbuf.length > 0; )
            {
                wchar[BUFFER_SIZE] wbuf = void;
                const wsLen = inbuf.convert(wbuf);
                indirectWriteConsoleW(console,
                        wbuf.ptr, wsLen, null, null);
            }
        }
    } // Windows


    //----------------------------------------------------------------//
private:
    File file_;     // the underlying File object
    int  useWide_;  // whether to use wide functions

    // XXX These should be in File.Impl for tracking the convertion state.
    alias .NarrowWriter!(UnsharedNarrowPutter) NarrowWriter;
    alias .WideWriter!(UnsharedWidePutter) WideWriter;
    NarrowWriter narrowWriter_;
    WideWriter   wideWriter_;

    version (Windows) bool useWinConsole_;
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
        errnoEnforce(ferror(cast(FILE*) handle_) == 0);
    }
}


////////////////////////////////////////////////////////////////////////////////
// Unicode --> multibyte char, wchar_t
////////////////////////////////////////////////////////////////////////////////

version (Windows)
{
    version = WCHART_WCHAR;
//  version = HAVE_MBSTATE;     // DMD/Windows has no mbstate
}
else version (linux)
{
    version = WCHART_DCHAR;
    version = HAVE_MBSTATE;
    version = HAVE_RANGED_MBWC;
    version = HAVE_ICONV;
}
else version (OSX)
{
    version = WCHART_DCHAR;
    version = HAVE_MBSTATE;
    version = HAVE_RANGED_MBWC;
    version = HAVE_ICONV;
}
else version (FreeBSD)
{
    version = HAVE_MBSTATE;
    version = HAVE_RANGED_MBWC;
//  version = HAVE_ICONV;       // Citrus
}
/+
else version (NetBSD)
{
    version = HAVE_MBSTATE;
//  version = HAVE_RANGED_MBWC; // not yet
    version = HAVE_ICONV;
}
else version (Solaris)
{
    version = HAVE_MBSTATE;
    version = HAVE_ICONV;
}
+/
else static assert(0);

version (WCHART_WCHAR) version = WCHART_UNICODE;
version (WCHART_DCHAR) version = WCHART_UNICODE;

debug (WITH_LIBICONV)
{
    version = HAVE_ICONV;
    pragma(lib, "iconv");
}


//----------------------------------------------------------------------------//
// iconv
//----------------------------------------------------------------------------//

version (HAVE_ICONV) private
{
    /+
    import core.sys.posix.iconv;
    +/
    extern(C) @system
    {
        typedef void* iconv_t;
        iconv_t iconv_open(in char*, in char*);
        size_t iconv(iconv_t, in ubyte**, size_t*, ubyte**, size_t*);
        int iconv_close(iconv_t);
    }

    version (LittleEndian)
    {
        enum ICONV_WSTRING = "UTF-16LE",
             ICONV_DSTRING = "UTF-32LE";
    }
    else version (BigEndian)
    {
        enum ICONV_WSTRING = "UTF-16BE",
             ICONV_DSTRING = "UTF-32BE";
    }
    else static assert(0);
}


//----------------------------------------------------------------------------//
// druntime: core.stdc.wchar is not correct
//----------------------------------------------------------------------------//

/+
import core.stdc.stdlib;
import core.stdc.wchar;
+/
private
{
    version (Windows)
    {
        alias wchar wchar_t;
        alias int mbstate_t;    // XXX dummy
    }
    else version (linux)
    {
        alias dchar wchar_t;
        struct mbstate_t
        {
            int     count;
            wchar_t value = 0;  // XXX wint_t
        }
    }
    else version (OSX)
    {
        alias dchar wchar_t;
        union mbstate_t
        {
            ubyte[128] __mbstate8;
            long       _mbstateL;
        }
    }
    else version (FreeBSD)
    {
        alias int wchar_t;
        union mbstate_t
        {
            ubyte[128] __mbstate8;
            long       _mbstateL;
        }
    }
    /+
    else version (NetBSD)
    {
        alias int wchar_t;
        union mbstate_t
        {
            long       __mbstateL;
            ubyte[128] __mbstate8;
        }
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
    }
    +/
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

    unittest
    {
        version (HAVE_MBSTATE)
        {
            // Verify if mbstate_t.init represents the initial state.
            mbstate_t mbst = mbstate_t.init;
            assert(mbsinit(&mbst));
        }
    }

    enum size_t MB_LEN_MAX = 16;
}


//----------------------------------------------------------------------------//
// druntime: core.sys.posix.langinfo
//----------------------------------------------------------------------------//

/+
import core.sys.posix.langinfo;
+/
version (Posix) private
{
    version (linux)
    {
        alias int nl_item;
    }
    else version (OSX)
    {
        alias int nl_item;
    }
    else version (FreeBSD)
    {
        alias int nl_item;
        enum CODESET = 0;
    }
    /+
    else version (NetBSD)
    {
        alias int nl_item;
        enum CODESET = 51;
    }
    else version (Solaris)
    {
        alias int nl_item;
        enum CODESET = 49;
    }
    +/
    else static assert(0);

    extern(C) @system
    {
        char* nl_langinfo(nl_item);
    }
}


//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://
// NarrowWriter and WideWriter
//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://

import std.algorithm;
import std.contracts;
import std.range;
import std.utf;

import core.stdc.errno;
import core.stdc.locale;
import core.stdc.string : memset, strcmp;

version (unittest) import std.array : appender;


private enum BUFFER_SIZE : size_t
{
    mchars = 160,
    wchars =  80,
    dchars =  80,
}
static assert(BUFFER_SIZE.mchars >= 2*MB_LEN_MAX);


//----------------------------------------------------------------------------//
// Unicode --> multibyte
//----------------------------------------------------------------------------//

     version (WCHART_UNICODE) version = NarrowWriter_convertWithC;
else version (HAVE_ICONV)     version = NarrowWriter_convertWithIconv;
else static assert(0);

version (NarrowWriter_convertWithC) version (HAVE_RANGED_MBWC)
{
    // whether to use wcsnrtombs()
    version (WCHART_WCHAR) version = NarrowWriter_wcsnrtombsForWstring;
    version (WCHART_DCHAR) version = NarrowWriter_wcsnrtombsForDstring;
}

version (NarrowWriter_wcsnrtombsForWstring)
    version = NarrowWriter_preferWstring;
version (NarrowWriter_wcsnrtombsForDstring)
    version = NarrowWriter_preferDstring;
version (NarrowWriter_convertWithIconv)
    version = NarrowWriter_preferDstring;


/**
 * An output range which converts UTF string or Unicode code point to the
 * corresponding multibyte character sequence in the current locale encoding.
 * The converted multibyte string is written to another output range $(D Sink).
 */
struct NarrowWriter(Sink)
    if (isOutputRange!(Sink, char[]))
{
    /**
     * Constructs a $(D NarrowWriter) object.
     *
     * Params:
     *   sink =
     *      An output range of type $(D Sink) where to put converted
     *      multibyte character sequence.
     *
     *   replacement =
     *      A valid multibyte string to use when a Unicode character cannot
     *      be represented in the current locale.  $(D NarrowWriter) will
     *      throw an exception on any non-representable character if this
     *      parameter is $(D null).
     *
     * Throws:
     *  - $(D Exception) if $(D replacement) is not $(D null) and it does
     *    not represent a valid multibyte string in the current locale.
     *
     *  - $(D Exception) if the constructor could not figure out what the
     *    current locale encoding is.
     */
    this(Sink sink, immutable(char)[] replacement = null)
    {
        swap(sink_, sink);
        context_ = new Context;

        // Validate the replacement string.
        if (replacement.length > 0)
        {
            version (HAVE_MBSTATE)
            {
                mbstate_t mbst = mbstate_t.init;
            }
            else
            {
                mbtowc(null, null, 0);
                scope(exit) mbtowc(null, null, 0);
            }
            for (size_t i = 0; i < replacement.length; )
            {
                version (HAVE_MBSTATE)
                    auto n = mbrlen(&replacement[i],
                            replacement.length - i, &mbst);
                else
                    auto n = mblen(&replacement[i],
                            replacement.length - i);
                enforce(n != -1, "The replacement string is not "
                    ~"a valid multibyte character sequence in the "
                    ~"current locale");
                if (n == 0)
                    replacement = replacement[0 .. i];
                i += n;
            }
        }
        replacement_ = replacement;

        // Initialize the convertion state.
        version (NarrowWriter_convertWithC)
        {
            version (HAVE_MBSTATE)
                context_.narrowen = mbstate_t.init;
            else
                wctomb(null, 0);
        }
        else version (NarrowWriter_convertWithIconv)
        {
            const(char)* codeset = nl_langinfo(CODESET);
            if (codeset == null || strcmp(codeset, "646") == 0)
                codeset = "US-ASCII";
            if (strcmp(codeset, "PCK") == 0)
                codeset = "CP932";

            const encoding = codeset;
            context_.mbencode = iconv_open(encoding, ICONV_DSTRING);
            errnoEnforce(context_.mbencode != cast(iconv_t) -1,
                "Cannot figure out how to convert Unicode to multibyte "
                ~"character encoding");
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
            version (NarrowWriter_convertWithIconv)
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
        version (NarrowWriter_preferWstring)
        {
            for (const(char)[] inbuf = str; inbuf.length > 0; )
            {
                wchar[BUFFER_SIZE.wchars] wbuf = void;
                const wsLen = inbuf.convert(wbuf);
                put(wbuf[0 .. wsLen]);
            }
        }
        else version (NarrowWriter_preferDstring)
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
            // [fallback] put each character in turn
            foreach (dchar ch; str)
                put(ch);
        }
    }

    /// ditto
    void put(in wchar[] str)
    {
        version (NarrowWriter_preferDstring)
        {
            for (const(wchar)[] inbuf = str; inbuf.length > 0; )
            {
                dchar[BUFFER_SIZE.dchars] dbuf = void;
                const dsLen = inbuf.convert(dbuf);
                put(dbuf[0 .. dsLen]);
            }
        }
        else version (NarrowWriter_wcsnrtombsForWstring)
        {
            // Convert UTF-16 to multibyte by chunk using wcsnrtombs().
            for (const(wchar)[] inbuf = str; inbuf.length > 0; )
            {
                char[BUFFER_SIZE.mchars] mbuf = void;
                const(wchar)* psrc = inbuf.ptr;

                const mbLen = wcsnrtombs(mbuf.ptr, &psrc,
                        inbuf.length, mbuf.length, &context_.narrowen);
                if (mbLen == -1)
                {
                    errnoEnforce(errno == EILSEQ && replacement_,
                        "Cannot convert a Unicode character to multibyte "
                        ~"character sequence");

                    // No way to get successfully-converted substring;
                    // discard it and just output the replacement.
                    sink_.put(replacement_);
                    ++psrc;

                    // The shift state is undefined; XXX reset.
                    context_.narrowen = mbstate_t.init;
                }
                else
                {
                    // Output the converted string.
                    sink_.put(mbuf[0 .. mbLen]);
                }
                inbuf = inbuf[cast(size_t) (psrc - inbuf.ptr) .. $];
            }
        }
        else
        {
            // [fallback] put each character in turn
            foreach (dchar ch; str)
                put(ch);
        }
    }

    /// ditto
    void put(in dchar[] str)
    {
        version (NarrowWriter_preferWstring)
        {
            for (const(dchar)[] inbuf = str; inbuf.length > 0; )
            {
                wchar[BUFFER_SIZE.wchars] wbuf = void;
                const wsLen = inbuf.convert(wbuf);
                put(wbuf[0 .. wsLen]);
            }
        }
        else version (NarrowWriter_wcsnrtombsForDstring)
        {
            // Convert UTF-32 to multibyte by chunk using wcsnrtombs().
            for (const(dchar)[] inbuf = str; inbuf.length > 0; )
            {
                char[BUFFER_SIZE.mchars] mbuf = void;
                const(dchar)* psrc = inbuf.ptr;

                const mbLen = wcsnrtombs(mbuf.ptr, &psrc,
                        inbuf.length, mbuf.length, &context_.narrowen);
                if (mbLen == -1)
                {
                    errnoEnforce(errno == EILSEQ && replacement_,
                        "Cannot convert a Unicode character to multibyte "
                        ~"character sequence");

                    // No way to get successfully-converted substring;
                    // discard it and just output the replacement.
                    sink_.put(replacement_);
                    ++psrc;

                    // The shift state is undefined; XXX reset.
                    context_.narrowen = mbstate_t.init;
                }
                else
                {
                    // Output the converted string.
                    sink_.put(mbuf[0 .. mbLen]);
                }
                inbuf = inbuf[cast(size_t) (psrc - inbuf.ptr) .. $];
            }
        }
        else version (NarrowWriter_convertWithIconv)
        {
            // Convert UTF-32 to multibyte by chunk.
            auto psrc = cast(const(ubyte)*) str.ptr;
            auto srcLeft = dchar.sizeof * str.length;

            while (srcLeft > 0)
            {
                char[BUFFER_SIZE.mchars] mbuf = void;
                auto pbuf = cast(ubyte*) mbuf.ptr;
                auto bufLeft = mbuf.length;

                auto stat = iconv(context_.mbencode,
                        &psrc, &srcLeft, &pbuf, &bufLeft);
                auto iconverr = errno;

                // Output converted characters (available even on error).
                if (bufLeft < mbuf.length)
                    sink_.put(mbuf[0 .. $ -bufLeft]);

                if (stat == -1)
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
            // [fallback] put each character in turn
            foreach (dchar ch; str)
                put(ch);
        }
    }


    /**
     * Converts a Unicode code point to a multibyte character in
     * the current locale encoding and puts it to the sink.
     */
    void put(dchar ch)
    {
        version (NarrowWriter_convertWithC)
        {
            static if (is(wchar_t == wchar))
            {
                // dchar --> wchar[2] --> multibyte
                char[MB_LEN_MAX] mbuf = void;
                size_t mbLen;
                wchar[3] wbuf = void;

                .encodez(wbuf, ch);

                version (HAVE_MBSTATE)
                    mbLen = wcsrtombs(mbuf.ptr, wbuf.ptr, mbuf.length,
                            &context_.narrowen);
                else
                    mbLen = wcstombs(mbuf.ptr, wbuf.ptr, mbuf.length);
                errnoEnforce(mbLen != -1 || (errno == EILSEQ && replacement_),
                    "Cannot convert a Unicode character to multibyte "
                    ~"character sequence");

                if (mbLen == -1)
                {
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
            else static if (is(wchar_t == dchar))
            {
                char[MB_LEN_MAX] mbuf = void;
                size_t mbLen;

                version (HAVE_MBSTATE)
                    mbLen = wcrtomb(mbuf.ptr, ch, &context_.narrowen);
                else
                    mbLen = wctomb(mbuf.ptr, ch);
                errnoEnforce(mbLen != -1 || (errno == EILSEQ && replacement_),
                    "Cannot convert a Unicode character to multibyte "
                    ~"character sequence");

                if (mbLen == -1)
                {
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
            else static assert(0);
        }
        else version (NarrowWriter_convertWithIconv)
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
        else static assert(0);
    }


    //----------------------------------------------------------------//
private:
    Sink sink_;
    Context* context_;
    immutable(char)[] replacement_;

    struct Context
    {
        version (NarrowWriter_convertWithC)
        {
            version (HAVE_MBSTATE)
                mbstate_t narrowen; // wide(Unicode) -> multibyte
        }
        else version (NarrowWriter_convertWithIconv)
        {
            iconv_t mbencode;       // Unicode -> multibyte
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
        auto w = NarrowWriter!(typeof(r))(r);
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
        auto w = NarrowWriter!(typeof(r))(r);
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
    // Then widen it to obtain a wide character.  Uses NarrowWriter.
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
            proxy_ = NarrowWriter!(Widener)(Widener(sink), replacement);
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
        NarrowWriter!(Widener!(Sink)) proxy_;
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
        version (HAVE_MBSTATE)
            widen_ = mbstate_t.init;
        else
            mbtowc(null, null, 0);
        swap(sink_, sink);
    }


    /*
     * Converts (possibly incomplete) multibyte character sequence mbs
     * to wide characters and puts them onto the sink.
     */
    void put(in char[] mbs)
    {
        version (HAVE_RANGED_MBWC)
        {
            for (const(char)[] inbuf = mbs; inbuf.length > 0; )
            {
                wchar_t[BUFFER_SIZE.wchars] wbuf = void;
                const(char)* psrc = inbuf.ptr;

                const wcLen = mbsnrtowcs(wbuf.ptr, &psrc, inbuf.length,
                        wbuf.length, &widen_);
                errnoEnforce(wcLen != -1);

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
            for (const(char)[] rest = mbs; rest.length > 0; )
            {
                wchar_t wc;
                size_t stat;

                version (HAVE_MBSTATE)
                    stat = mbrtowc(&wc, rest.ptr, rest.length, &widen_);
                else
                    stat = mbtowc(&wc, rest.ptr, rest.length);
                errnoEnforce(stat != cast(size_t) -1);

                if (stat == cast(size_t) -2)
                {
                    break; // consumed entire rest as a part of MB char
                           // sequence and the convertion state changed
                }
                else if (stat == 0)
                {
                    break; // XXX assuming the null character is the end
                }
                else
                {
                    assert(stat <= rest.length);
                    rest = rest[stat .. $];
                    sink_.put(wc);
                }
            }
        }
    }

private:
    Sink sink_;
    version (HAVE_MBSTATE)
        mbstate_t widen_;
}


////////////////////////////////////////////////////////////////////////////////
// std.utf extension
////////////////////////////////////////////////////////////////////////////////

import std.utf;

version (unittest) private void expectError_()
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


