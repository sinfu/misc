/**
 * Macros:
 *   D = $(I $1)
 */
module nativeenc;

import std.array;
import std.stdio;

void main()
{
    ubyte[] a;
    auto r = appender(&a);

    auto e = NativeTextEncoder!(typeof(r))(r, cast(immutable ubyte[]) "<?>");
    e.put("女の子と共通の話題ができて、自分の体も健康になる。"
         ~"いいことずくめですよ。"c);
    printf("%zu: %.*s\n", a.length, a);
}


version (FreeBSD) debug = USE_LIBICONV;

//-/////////////////////////////////////////////////////////////////////////////
// NativeTextEncoder
//-/////////////////////////////////////////////////////////////////////////////

import std.algorithm;
import std.contracts;
import std.encoding : EncodingException;
import std.range;
import std.string;
import std.utf;
import utf;

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

    // Is the native encoding UTF-8?
    immutable bool isNativeUTF8;
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
 *   $(LI POSIX systems: The CODESET langinfo of the LC_CTYPE locale at
 *        program startup.)
 * )
 * $(D NativeTextEncoder) is not affected by any dynamic change of locale.
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
     *      $(D NativeWriter) will throw an $(D EncodingException) on any
     *      non-representable character if $(D replacement) is empty.
     *
     * Throws:
     * $(UL
     *   $(LI $(D enforcement) fails if $(D NativeWriter) could not
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
            context_.ctype    = errnoEnforce(duplocale(nativeLocaleCTYPE));
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

