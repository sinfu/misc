
import std.format;
import std.stdio;

import core.stdc.locale;

void main()
{
//  setlocale(LC_CTYPE, "ja_JP.eucJP");
//  setlocale(LC_CTYPE, "ja_JP.SJIS");
//  setlocale(LC_CTYPE, "ja_JP.UTF-8");
//  setlocale(LC_CTYPE, "Japanese_Japan.932");
    setlocale(LC_CTYPE, "");
    setlocale(LC_CTYPE, "ja_JP.UTF-8");

    auto sink = File("a.txt", "w");
//  auto sink = stderr;
//  auto sink = stdout;

    fwide(sink.getFP(), -1);
//  fwide(sink.getFP(),  1);

    {
        //auto w = LockingNativeTextWriter(sink, "<?>");
        auto w = File.LockingTextWriter(sink);
        formattedWrite(w, "<< %s = %s%s%s >>\n", "λ", "α"w, '∧', "β"d);

        foreach (i; 0 .. 1_000_000)
        //foreach (i; 0 .. 10)
            w.put("安倍川もち 生八つ橋 なごやん 雪の宿\n");
    }
    sink.writeln("...");
}

//------------------------------------------------------------
// バッファリングを加えたときのテスト結果
//------------------------------------------------------------

// テスト用ライン "安倍川もち 生八つ橋 なごやん 雪の宿\n"

// To xterm/tmux, UTF-8 52u/L, 100 000
//
// LockingNativeTextWriter
// (narrow)  1.21s user 0.28s system 29% cpu 5.063 total
// ( wide )  1.80s user 0.34s system 39% cpu 5.415 total
//
// LockingTextWriter
// (narrow)  0.87s user 0.35s system 24% cpu 4.947 total
// ( wide )  1.22s user 0.36s system 30% cpu 5.207 total

// To file, UTF-8 52 u/L, 1 000 000
//
// LockingNativeTextWriter
// (narrow)  2.30s user 0.21s system 97% cpu 2.582 total
// ( wide )  5.63s user 0.19s system 99% cpu 5.838 total
//
// LockingTextWriter
// (narrow)  0.96s user 0.20s system 65% cpu 1.764 total
// ( wide )  2.65s user 0.19s system 99% cpu 2.858 total

// UTF-8 ロケールでは LNTW/narrow == LTW/wide であることを考えると，
// かなり優秀じゃないか? (LNTW/wide は多重変換だから仕方ない)

//------------------------------------------------------------

// use libiconv for debugging
version (FreeBSD) debug = WITH_LIBICONV;


//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://
// LockingNativeTextWriter
//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://

import core.stdc.wchar_ : fwide;

import std.algorithm;
import std.contracts;
import std.range;


version (Windows) private
{
    import core.sys.windows.windows;

    /*
     * fileno(), isatty(), osfhnd()
     */
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
 * An $(D output range) that locks the file and provides writing to it
 * in the multibyte encoding of the current locale.
 *
 * $(D LockingNativeTextWriter) accepts $(D dchar) and any $(D input
 * range) with elements of type $(D dchar).
 */
struct LockingNativeTextWriter
{
    /**
     * Constructs a $(D LockingNativeTextWriter) object.
     *
     * Params:
     *   file =
     *     An opened $(D File) object to write in.
     *
     *   replacement =
     *     A valid multibyte string to use when a Unicode character
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

    /// Range primitive implementations.
    void put(R)(R writeme)
        if (is(ElementType!R : const(dchar)))
    {
        version (Windows)
        {
            if (useWinConsole_)
            {
                auto hconsole = osfhnd(file_.p.handle);
                static if (is(R : const(wchar)[]))
                {
                    indirectWriteConsoleW(hconsole,
                            writeme.ptr, writeme.length, null, null);
                }
                else
                {
                    // TODO
                    foreach (dchar c; writeme)
                    {
                        wchar[2] wc = void;
                        size_t wcLen = std.utf.encode(wc, c);
                        indirectWriteConsoleW(hconsole,
                                wc.ptr, wcLen, null, null);
                    }
                }
                return; // done
            }
        }

        if (useWide_)
            wideWriter_.put(writeme);
        else
            narrowWriter_.put(writeme);
    }

    /// ditto
    void put(C = dchar)(dchar c)
    {
        version (Windows)
        {
            if (useWinConsole_)
            {
                wchar[2] wc = void;
                size_t wcLen = std.utf.encode(wc, c);
                indirectWriteConsoleW(osfhnd(file_.p.handle),
                        wc.ptr, wcLen, null, null);
                return;
            }
        }

        if (useWide_)
            wideWriter_.put(c);
        else
            narrowWriter_.put(c);
    }


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
//      foreach (char unit; mbs)
//          FPUTC(unit, handle_);
//      errnoEnforce(ferror(cast(FILE*) handle_) == 0);
        size_t nwritten = fwrite(mbs.ptr, 1, mbs.length, cast(shared) handle_);
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
    version = UNICODE_WCHART;
//  version = HAVE_MBSTATE;     // DMD/Windows has no mbstate
}
else version (linux)
{
    version = UNICODE_WCHART;
    version = HAVE_MBSTATE;
    version = HAVE_ICONV;
}
else version (OSX)
{
    version = UNICODE_WCHART;
    version = HAVE_MBSTATE;
    version = HAVE_ICONV;
}
else version (FreeBSD)
{
    version = HAVE_MBSTATE;
//  version = HAVE_ICONV;       // Citrus

    debug (WITH_LIBICONV)
    {
        version = HAVE_ICONV;
        pragma(lib, "iconv");
    }
}
/+
else version (NetBSD)
{
    version = HAVE_MBSTATE;
    version = HAVE_ICONV;
}
else version (Solaris)
{
    version = HAVE_MBSTATE;
    version = HAVE_ICONV;
}
+/
else static assert(0);


//----------------------------------------------------------------------------//
// iconv
//----------------------------------------------------------------------------//

version (UNICODE_WCHART)
{
    version = USE_LIBC_WCHAR;
}
else version (HAVE_ICONV)
{
    version = USE_ICONV;

    // druntime: core.sys.posix.iconv
    private extern(C) @system
    {
        alias void* iconv_t;
        iconv_t iconv_open(in char* tocode, in char* fromcode);
        size_t iconv(iconv_t cd, in ubyte** inbuf, size_t* inbytesleft, ubyte** outbuf, size_t* outbytesleft);
        int iconv_close(iconv_t cd);
    }
}
else static assert(0);

private
{
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
//      size_t mbsnrtowcs(wchar_t* dst, in char** src, size_t nms, size_t len, mbstate_t* ps);
//      size_t wcsnrtombs(char* dst, in wchar_t** src, size_t nwc, size_t len, mbstate_t* ps);

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
// Unicode --> multibyte
//----------------------------------------------------------------------------//

/**
 * An output range which converts UTF string or Unicode code point to the
 * corresponding multibyte character sequence in the current locale encoding
 * and puts the multibyte characters to another output range $(D Sink).
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
        if (replacement)
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
        version (USE_LIBC_WCHAR)
        {
            version (HAVE_MBSTATE)
                context_.narrowen = mbstate_t.init;
            else
                wctomb(null, 0);
        }
        else version (USE_ICONV)
        {
            const(char)* codeset = nl_langinfo(CODESET);
            if (codeset == null || strcmp(codeset, "646") == 0)
                codeset = "US-ASCII";
            if (strcmp(codeset, "PCK") == 0)
                codeset = "CP932";
            context_.mbencode = iconv_open(codeset, ICONV_DSTRING);
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
            version (USE_ICONV)
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
        // TODO
        /+
        foreach (dchar ch; str)
            put(ch);
        +/

        const(char)[] inbuf = str;

        while (inbuf.length > 0)
        {
            dchar[80] dchbuf = void;
            size_t dchLen;

            dchLen = inbuf.transcode(dchbuf);
            put(dchbuf[0 .. dchLen]);
        }
    }

    /// ditto
    void put(in wchar[] str)
    {
        // TODO
        foreach (dchar ch; str)
            put(ch);
    }

    /// ditto
    void put(in dchar[] str)
    {
        // TODO

        version (USE_ICONV)
        {
            char[128] mbuf = void;
            auto psrc = cast(const(ubyte)*) str.ptr;
            auto nsrc = dchar.sizeof * str.length;

            while (nsrc > 0)
            {
                auto pdst = cast(ubyte*) mbuf.ptr;
                auto ndst = mbuf.length;

                auto stat = iconv(context_.mbencode,
                        &psrc, &nsrc, &pdst, &ndst);
                auto iconverr = errno;

                if (ndst < mbuf.length)
                    sink_.put(mbuf[0 .. $ - ndst]);

                if (stat == -1 && errno == EILSEQ && replacement_)
                {
                    sink_.put(replacement_);
                    psrc += dchar.sizeof;
                    nsrc -= dchar.sizeof;
                    continue;
                }
                errno = iconverr;
                errnoEnforce(stat != -1,
                    "Cannot convert a Unicode character to multibyte "
                    ~"character sequence");
            }
        }
        else
        {
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
        version (USE_LIBC_WCHAR)
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
                    if (replacement_.length > 0)
                        sink_.put(replacement_);
                    // Here, the shift state is undefined; reset it to
                    // the initial state.
                    version (HAVE_MBSTATE)
                        context_.narrowen = mbstate_t.init;
                    else
                        wctomb(null, 0);
                }
                else
                {
                    assert(0 < mbLen && mbLen <= mbuf.length);
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
                    if (replacement_.length > 0)
                        sink_.put(replacement_);
                    // Here, the shift state is undefined; reset it to
                    // the initial state.
                    version (HAVE_MBSTATE)
                        context_.narrowen = mbstate_t.init;
                    else
                        wctomb(null, 0);
                }
                else
                {
                    assert(0 < mbLen && mbLen <= mbuf.length);
                    sink_.put(mbuf[0 .. mbLen]);
                }
            }
            else static assert(0);
        }
        else version (USE_ICONV)
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
                if (replacement_.length > 0)
                    sink_.put(replacement_);
            }
            else
            {
                assert(bufLeft < mbuf.length);
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
        version (USE_LIBC_WCHAR)
        {
            version (HAVE_MBSTATE)
                mbstate_t narrowen; // wide(Unicode) -> multibyte
        }
        else version (USE_ICONV)
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

/**
 * An output range which converts UTF string or Unicode code point to the
 * corresponding wide character sequence in the current locale code set
 * and puts the wide characters to another output range $(D Sink).
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
     * wide character sequence on some CSI (codeset independent) platforms.
     */
    this(Sink sink, immutable(char)[] replacement = null)
    {
        version (USE_LIBC_WCHAR)
        {
            swap(sink_, sink);
            // Unicode-to-Unicode; replacement is unnecessary.
            cast(void) replacement;
        }
        else
        {
            // Convertion will be done as follows under code set
            // independent systems:
            //            iconv              mbrtowc
            //   Unicode -------> multibyte ---------> wide
            alias .Widener!(Sink) Widener;
            proxy_ = NarrowWriter!(Widener)(Widener(sink), replacement);
        }
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
        // TODO
        foreach (dchar ch; str)
            put(ch);
    }

    /// ditto
    void put(in wchar[] str)
    {
        version (USE_LIBC_WCHAR)
        {
            static if (is(wchar_t == wchar))
            {
                sink_.put(str);
            }
            else
            {
                // TODO
                foreach (dchar ch; str)
                    put(ch);
            }
        }
        else version (USE_ICONV)
        {
            proxy_.put(str);
        }
        else static assert(0);
    }

    /// ditto
    void put(in dchar[] str)
    {
        version (USE_LIBC_WCHAR)
        {
            static if (is(wchar_t == dchar))
            {
                sink_.put(str);
            }
            else
            {
                // TODO
                foreach (dchar ch; str)
                    put(ch);
            }
        }
        else version (USE_ICONV)
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
        version (USE_LIBC_WCHAR)
        {
            static if (is(wchar_t == wchar))
            {
                wchar[2] wbuf = void;
                sink_.put(wbuf[0 .. encode(wbuf, ch)]);
            }
            else static if (is(wchar_t == dchar))
            {
                sink_.put(ch);
            }
            else static assert(0);
        }
        else version (USE_ICONV)
        {
            proxy_.put(ch);
        }
        else static assert(0);
    }


    //----------------------------------------------------------------//
private:
    version (USE_LIBC_WCHAR)
    {
        Sink sink_;
    }
    else version (USE_ICONV)
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
        const(char)[] rest = mbs;

        while (rest.length > 0)
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

private:
    Sink sink_;
    version (HAVE_MBSTATE)
        mbstate_t widen_;
}


//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://

size_t transcode(ref const(char)[] inbuf, dchar[] outbuf)
{
    auto curin = inbuf;
    auto curout = outbuf;

    while (curin.length > 0 && curout.length > 0)
    {
        curout[0] = curin.decode();
        curout = curout[1 .. $];
    }
    inbuf = curin;
    return outbuf.length - curout.length;
}


private dchar decode(ref const(char)[] inbuf)
{
    size_t inLen;
    dchar c;
    const u1 = inbuf[0];

    if ((u1 & 0x80) == 0)
    {
        inLen = 1;
        c = u1;
    }
    else if ((u1 & 0xE0) == 0xC0)
    {
        const u2 = inbuf[1];
        if ((u1 & 0xEF) == 0xC0)
            throw new Exception("overlong", __FILE__, __LINE__);
        if ((u2 & 0xC0) != 0x80)
            throw new Exception("incomplete UTF-8 sequence", __FILE__, __LINE__);

        inLen = 2;
        c = u1 & 0x1F;
        c = (c << 6) | (u2 & 0x3F);
    }
    else if ((u1 & 0xF0) == 0xE0)
    {
        const u2 = inbuf[1];
        const u3 = inbuf[2];
        if (u1 == 0xE0 && (u2 & 0x1F))
            throw new Exception("overlong", __FILE__, __LINE__);
        if ((u2 & u3 & 0xC0) != 0x80)
            throw new Exception("incomplete UTF-8 sequence", __FILE__, __LINE__);

        inLen = 3;
        c = u1 & 0x0F;
        c = (c << 6) | (u2 & 0x3F);
        c = (c << 6) | (u3 & 0x3F);
    }
    else if ((u1 & 0xF8) == 0xF0)
    {
        const u2 = inbuf[1];
        const u3 = inbuf[2];
        const u4 = inbuf[3];
        if (u1 == 0xF0 && (u2 & 0x0F))
            throw new Exception("overlong", __FILE__, __LINE__);
        if ((u2 & u3 & u4 & 0xC0) != 0x80)
            throw new Exception("incomplete UTF-8 sequence", __FILE__, __LINE__);

        inLen = 4;
        c = u1 & 0x07;
        c = (c << 6) | (u2 & 0x3F);
        c = (c << 6) | (u3 & 0x3F);
        c = (c << 6) | (u4 & 0x3F);
    }
    else
    {
        throw new Exception("illegal UTF-8 sequence", __FILE__, __LINE__);
    }

    inbuf = inbuf[inLen .. $];
    return c;
}


