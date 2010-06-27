/*
- NarrowWriter(Sink)
        Unicode文字列を LC_CTYPE ロケールに従ってマルチバイト文字列に変換し，
        別の出力レンジ Sink に書き込む出力レンジ．

- WideWriter(Sink)
        Unicode文字列を LC_CTYPE ロケールに従ってワイド文字列に変換し，別の
        出力レンジ Sink に書き込む出力レンジ．

 */

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
    auto w = NarrowWriter!(typeof(r))(r);
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
    version = HAVE_ICONV;       // 近いうちに来る
    pragma(lib, "iconv");
}
else version (Solaris)
{
    version = HAVE_MBSTATE;
    version = HAVE_ICONV;
}
else
{
    static assert(0);
}


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
    private extern(C)
    {
        typedef int iconv_t = -1; // XXX 適当
        iconv_t iconv_open(in char* tocode, in char* fromcode);
        size_t iconv(iconv_t cd, in ubyte** inbuf, size_t* inbytesleft, ubyte** outbuf, size_t* outbytesleft);
        int iconv_close(iconv_t cd);
    }
}
else
{
    static assert(0);
}

private
{
    // マニ定数はリテラルと同じくカメレオン型なので char* に渡してよい
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
    else
    {
        static assert(0);
    }
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
            ubyte[128] _mbstate8;
            int        _mbstateL;
        }
    }
    else version (FreeBSD)
    {
        alias int wchar_t;
        union mbstate_t
        {
            ubyte[128] _mbstate8;
            int        _mbstateL;
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
    else
    {
        static assert(0);
    }

    extern(C)
    {
        int    mbsinit(in mbstate_t* ps);
        size_t mbrtowc(wchar_t* pwc, in char* s, size_t n, mbstate_t* ps);
        size_t wcrtomb(char* s, wchar_t wc, mbstate_t* ps);
        size_t mbsrtowcs(wchar_t* dst, in char** src, size_t len, mbstate_t* ps);
        size_t wcsrtombs(char* dst, in wchar_t** src, size_t len, mbstate_t* ps);

        int     mbtowc(wchar_t* pwc, in char* s, size_t n);
        int     wctomb(char*s, wchar_t wc);
        size_t  mbstowcs(wchar_t* pwcs, in char* s, size_t n);
        size_t  wcstombs(char* s, in wchar_t* pwcs, size_t n);
    }

    enum size_t MB_LEN_MAX = 8;
        // 悪意の無い ISO-2022-JP-2 なら最大 6，余裕 +2
}


//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://

import std.contracts;
import std.utf;

import core.stdc.errno;
import core.stdc.locale;
import core.stdc.string : memset, strchr, strcmp;

version (unittest) import std.array : appender;


/*
 * Encodes a Unicode code point in UTF-16 and writes it to buf with zero
 * terminator (U+0).  Returns the number of code units written to buf
 * including the terminating zero.
 */
private size_t encodez(ref wchar[3] buf, dchar ch)
{
    size_t n = std.utf.encode(*cast(wchar[2]*) &buf, ch);
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

/*
 * An output range which converts UTF string or Unicode code point to the
 * corresponding multibyte character sequence and puts the multibyte
 * characters to another output range Sink.
 */
struct NarrowWriter(Sink)
{
    this(Sink sink, immutable(char)[] replacement = null)
    {
        version (USE_LIBC_WCHAR)
        {
            version (HAVE_MBSTATE)
            {
                memset(&narrowen_, 0, narrowen_.sizeof);
                assert(mbsinit(&narrowen_));
            }
        }
        else version (USE_ICONV)
        {
            // TODO: もっとマシな実装 (確実な方法はなさげ)
            const(char)* native = strchr(setlocale(LC_CTYPE, null), '.');
            if (native != null)
            {
                assert(*native == '.');
                ++native;
                if (strcmp(native, "PCK") == 0)
                    native = "Shift_JIS";
            }
            else
            {
                native = "ASCII"; // or UTF-8?
            }
            mbencode_ = iconv_open(native, ICONV_DSTRING);
            errnoEnforce(mbencode_ != cast(iconv_t) -1,
                "iconv does not support convertion between Unicode "
                ~"and the current locale encoding");
        }
        else
        {
            static assert(0);
        }
        sink_ = sink;
    }

    ~this()
    {
        // TODO [CRITICAL]: 山椒カウント or コピー禁止
        version (USE_ICONV)
            errnoEnforce(iconv_close(mbencode_) != -1);
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

        // TODO: wcsnrtombs() があるシステムなら一気に変換できる
        // TODO: iconv でも同じく
    }


    /**
     * Converts a Unicode code point ch to a multibyte character in
     * the current locale encoding and puts it to the sink.
     */
    void put(dchar ch)
    {
        version (USE_LIBC_WCHAR)
        {
            static if (is(wchar_t == wchar))
            {
                char[MB_LEN_MAX] mbuf = void;
                size_t mbLen;
                wchar[3] wbuf = void;

                .encodez(wbuf, ch);

                version (HAVE_MBSTATE)
                    mbLen = wcsrtombs(mbuf.ptr, wbuf.ptr, mbuf.length,
                            &narrowen_);
                else
                    mbLen = wcstombs(mbuf.ptr, wbuf.ptr, mbuf.length);
                errnoEnforce(0 < mbLen && mbLen <= mbuf.length);

                sink_.put(mbuf[0 .. mbLen]);
            }
            else static if (is(wchar_t == dchar))
            {
                char[MB_LEN_MAX] mbuf = void;
                size_t mbLen;

                version (HAVE_MBSTATE)
                    mbLen = wcrtomb(mbuf.ptr, c, &narrowen_);
                else
                    mbLen = wctomb(mbuf.ptr, c);
                errnoEnforce(0 < mbLen && mbLen <= mbuf.length);

                sink_.put(mbuf[0 .. mbLen]);
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

            auto stat = iconv(mbencode_,
                    &pchar, &charLeft, &pbuf, &bufLeft);
            errnoEnforce(stat != -1);

            sink_.put(mbuf[0 .. $ - bufLeft]);
        }
        else static assert(0);
    }


    //----------------------------------------------------------------//
private:
    Sink sink_;

    version (USE_LIBC_WCHAR)
    {
        mbstate_t narrowen_;    // wide(Unicode) -> multibyte
    }
    else version (USE_ICONV)
    {
        iconv_t   mbencode_;    // Unicode -> multibyte
        mbstate_t widen_;       // multibyte -> wide
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

/*
 * An output range which converts UTF string or Unicode code point to the
 * corresponding wide character sequence and puts the wide characters to another
 * output range Sink.
 */
struct WideWriter(Sink)
{
    this(Sink sink, immutable(wchar_t)[] replacement = null)
    {
        version (USE_LIBC_WCHAR)
        {
            sink_ = sink;
        }
        else
        {
            // Convertion will be done as follows under codeset
            // independent systems:
            //            iconv              mbrtowc
            //   Unicode -------> multibyte ---------> wide
            alias .Widener!(Sink) Widener;
            proxy_ = NarrowWriter!(Widener)(Widener(sink));
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
     * Converts a Unicode code point ch to a wide character in the
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
 * Convenience range to convert multibyte string to wide string.  This
 * is just a thin-wrapper against the mbrtowc() function.
 */
private struct Widener(Sink)
{
    this(Sink sink)
    {
        version (HAVE_MBSTATE)
        {
            memset(&widen_, 0, widen_.sizeof);
            assert(mbsinit(&widen_));
        }
        sink_ = sink;
    }

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
                break; // consumed entire rest as a part of control sequence
                       // XXX ??
            }
            else if (stat == 0)
            {
                break; // XXX assuming the null character is the end
            }
            else
            {
                sink_.put(wc);
                rest = rest[stat .. $];
            }
        }
        // Note: POSIX.2008 拡張 mbsnrtowcs() 使えばもう少し効率よくなる
    }

private:
    version (HAVE_MBSTATE)
        mbstate_t widen_;
    Sink sink_;
}

