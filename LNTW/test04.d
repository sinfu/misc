/**
 * Macros:
 *   D = $(I $1)
 */
module test04;

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
import std.range;
import std.string;
import std.utf;
import utf;

import core.stdc.errno;
import core.stdc.locale;
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
     *        figure out any safe mean to convert UTF to native multibyte
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
        else version (USE_MULTILOCALE)
        {
            context_          = new Context;
            context_.narrowen = mbstate_t.init;
            context_.ctype    = errnoEnforce(duplocale(nativeLocaleCTYPE));
                                // XXX is duplocale necessary?
        }
        else version (USE_ICONV)
        {
            context_          = new Context;
            context_.mbencode = iconv_open(
                    nativeEncodingz.ptr, ICONV_DSTRING);
            errnoEnforce(context_.mbencode != cast(iconv_t) -1,
                    "opening an iconv descriptor");
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
                iconv_close(context_.mbencode);
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


