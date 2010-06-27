/*
- NarrowWriter(Sink)
        Unicode文字列を LC_CTYPE ロケールに従ってマルチバイト文字列に変換し，
        別の出力レンジ Sink に書き込む出力レンジ．

- WideWriter(Sink)
        Unicode文字列を LC_CTYPE ロケールに従ってワイド文字列に変換し，別の
        出力レンジ Sink に書き込む出力レンジ．

 */

debug = WITH_LIBICONV;

import core.stdc.locale;

import std.array;
import std.format;
import std.stdio;

void main()
{
//  setlocale(LC_CTYPE, "Japanese_Japan.932");
//  setlocale(LC_CTYPE, "ja_JP.eucJP");
    setlocale(LC_CTYPE, "");

    char[] mbs;
    auto r = appender(&mbs);
    auto w = NarrowWriter!(typeof(r))(r, "?");
    formattedWrite(w, "<< %s = %s%s%s >>\n", "λ", "α"w, '∧', "β"d);

    stdout.rawWrite(mbs);
}


////////////////////////////////////////////////////////////////////////////////
// Unicode --> multibyte char, wchar_t
////////////////////////////////////////////////////////////////////////////////

version (Windows)
{
    version = UNICODE_WCHART;
//  version = HAVE_MBSTATE;     // DMD/Windows: なし
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

    // druntime core.sys.posix.iconv: なし
    private extern(C) @system
    {
        typedef int iconv_t = -1; // XXX 適当
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
// druntime wchar: 間違い修正
//----------------------------------------------------------------------------//

private
{
    version (Windows)
    {
        alias wchar wchar_t;
        typedef int mbstate_t;  // XXX ?
    }
    else version (linux)
    {
        alias dchar wchar_t;
        struct mbstate_t
        {
            int     count;
            wchar_t value;      // XXX wint_t
        }
    }
    else version (OSX)
    {
        alias dchar wchar_t;
        union mbstate_t         // XXX ?
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
            mbstate_t mbst = mbstate_t.init;
            assert(mbsinit(&mbst));
        }
    }

    enum size_t MB_LEN_MAX = 16;
}


//----------------------------------------------------------------------------//
// langinfo
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

import std.algorithm : swap;
import std.contracts;
import std.conv;
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
        foreach (dchar ch; str)
            put(ch);
    }

    /// ditto
    void put(in wchar[] str)
    {
        foreach (dchar ch; str)
            put(ch);
    }

    /// ditto
    void put(in dchar[] str)
    {
        foreach (dchar ch; str)
            put(ch);
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

