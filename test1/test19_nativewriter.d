
import std.format;
import std.stdio;


void main()
{
//  setlocale(LC_CTYPE, "ja_JP.eucJP");
//  setlocale(LC_CTYPE, "ja_JP.SJIS");
//  setlocale(LC_CTYPE, "ja_JP.UTF-8");
//  setlocale(LC_CTYPE, "Japan_Japanese.932");
    setlocale(LC_CTYPE, "");

//  auto sink = File("a.txt", "w");
//  auto sink = stderr;
    auto sink = stdout;

//  fwide(sink.getFP(), -1);
//  fwide(sink.getFP(),  1);

    {
        auto w = LockingNativeTextWriter(sink);
        formattedWrite(w, "<< %s = %s%s%s >>\n", "λ", "α"w, '∧', "β"d);
    }
    sink.writeln("...");
}


/*

LockingNativeTextWriter:
  Unicode文字列を現在のロケールに従って変換出力する．

 • 変換できない文字があったら?


Windows
------------------------------
 • wchar_t == UTF-16
 ‼ wcrtomb() はコンソールのコードページを知らない (CHCPで変わる)

 ‣ ファイルの場合は wcrtomb() など
   コンソールに書くときは WriteConsoleW()


Linux, OSX
------------------------------
 • wchar_t == UTF-32
 • libc 組み込みの iconv も使える

 ‣ wcrtomb() など


FreeBSD, NetBSD, Solaris
------------------------------
 • wchar_t == int (character set independent)
 • NetBSD, Solaris の libc には組み込み iconv あり
 • FreeBSD にも，そのうち Citrus iconv がマージされる

 ‣ iconv_open(tocode, "UTF-32LE") とか
   tocode は現在のロケールのエンコーディング

http://citrus.bsdclub.org/doc/iconv-article-rev2.pdf

# tocode = char, wchar_t が使えるのは GNU libiconv の機能
# Citrus, Solaris ではサポートされてない


========================================================================

ワイド指向ストリーム
--------------------

バイト指向ストリームには生のデータが書き込める．ワイド指向ストリームには
wchar_t しか書き込めない．ワイド指向の関数 fputwc() などで書き込むと，
libc 内部で wcrtomb() など使って変換してから出力される．

 • バイト指向のとき
     Unicode -> マルチ変換して fwrite

 • ワイド指向のとき
     wchar_t == Unicode なシステムではそのまま fputwc()
     CSIシステムでは Unicode -> マルチ -> ワイド変換して fputwc()

FILE* の指向 (fwide() で設定・取得できる) にそむくような関数を使うと
未定義動作．一度でもワイド関数を使うとワイド指向に固定されるので注意．
バイト関数でも同様．

http://www.opengroup.org/onlinepubs/9699919799/functions/V2_chap02.html#tag_15_05_02

 */

import core.stdc.errno;
import core.stdc.locale;
import core.stdc.wchar_ : fwide;

import std.algorithm : swap;
import std.contracts : enforce, errnoEnforce;
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

    // Unicode直接書く用
    immutable typeof(WriteConsoleW)* indirectWriteConsoleW;

    static this()
    {
        indirectWriteConsoleW = cast(typeof(indirectWriteConsoleW))
            GetProcAddress(GetModuleHandleA("kernel32.dll"), "WriteConsoleW");
    }
}


/*
 * LockingTextWriter + native encoding support
 */
struct LockingNativeTextWriter
{
    this(File f)
    {
        enforce(f.isOpen);
        swap(file_, f);
        FLOCK(file_.p.handle);

        orientation_ = fwide(file_.p.handle, 0);
        context_ = new Context;
        context_.conv.init();

        version (Windows)
        {
            // can we use WriteConsoleW()?
            useWinConsole_ = (indirectWriteConsoleW !is null &&
                    isatty(fileno(file_.p.handle)));
            if (useWinConsole_)
                file_.flush(); // need to sync
        }
    }

    this(this)
    {
        if (context_ is null)
            return;
        ++context_.refCount;
        FLOCK(file_.p.handle);
    }

    ~this()
    {
        if (context_ is null)
            return;
        if (--context_.refCount == 0)
            context_.conv.term();
        FUNLOCK(file_.p.handle);
    }

    void opAssign(LockingNativeTextWriter rhs)
    {
        swap(this, rhs);
    }


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

        if (orientation_ <= 0)
            foreach (dchar c; writeme)
                putNarrow(c);
        else
            foreach (dchar c; writeme)
                putWide(c);
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

        if (orientation_ <= 0)
            putNarrow(c);
        else
            putWide(c);
    }


    //----------------------------------------------------------------//
private:

    /*
     * Writes a Unicode code point c to the stream using byte-oriented
     * output functions.
     */
    void putNarrow(dchar c)
    in
    {
        assert(fwide(file_.p.handle, 0) <= 0);
    }
    body
    {
        char[32] mbuf = void;
        size_t mLen = context_.conv.toMultibyteChar(c, mbuf);

        size_t nwritten = fwrite(mbuf.ptr, 1, mLen, file_.p.handle);
        errnoEnforce(nwritten == mLen);
    }


    /*
     * Writes a Unicode code point c to the stream using wide-oriented
     * output functions.
     */
    void putWide(dchar c)
    in
    {
        assert(fwide(file_.p.handle, 0) >= 0);
    }
    body
    {
        auto handle = cast(_iobuf*) file_.p.handle;

        static if (is(wchar_t == wchar))
        {
            wchar[2] wc = void;
            if (std.utf.encode(wc, c) == 1)
            {
                FPUTWC(wc[0], handle);
            }
            else
            {
                FPUTWC(wc[0], handle);
                FPUTWC(wc[1], handle);
            }
        }
        else static if (is(wchar_t == dchar))
        {
            FPUTWC(c, handle);
        }
        else
        {
            wchar_t[1] wcbuf = void;
            size_t wcLen = context_.conv.toWideChar(c, wcbuf);
            assert(wcLen == 1);
            FPUTWC(wcbuf[0], handle);
        }
        errnoEnforce(ferror(file_.p.handle) == 0);
    }


    //----------------------------------------------------------------//
private:
    struct Context // XXX 本当は File に入れた方が良い
    {
        NativeConv conv;
        uint       refCount = 1;
    }
    Context* context_;
    File     file_;
    int      orientation_;

    version (Windows) /+immutable+/ bool useWinConsole_;
                // @@@BUG@@@ "Error: this is not mutable"
}


//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://
// Unicode --> multibyte char, wchar_t
//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://

version (Windows)
{
    version = UNICODE_WCHART;
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
    version = HAVE_ICONV;
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

    // druntime core.sys.posix.iconv 無い!
    private extern(C)
    {
        typedef int iconv_t = -1; // XXX
        iconv_t iconv_open(in char* tocode, in char* fromcode);
        size_t iconv(iconv_t cd, in ubyte** inbuf, size_t* inbytesleft, ubyte** outbuf, size_t* outbytesleft);
        int iconv_close(iconv_t cd);
    }
    version (FreeBSD) pragma(lib, "iconv"); // Citrusまだ
}
else
{
    static assert(0);
}

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
    else
    {
        static assert(0);
    }
}


//----------------------------------------------------------------------------//
// druntimeのwchar関連fix
//----------------------------------------------------------------------------//

private
{
    version (Windows)
    {
        alias wchar wchar_t;
        typedef int mbstate_t;  // XXX ?
    }
    version (linux)
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

    enum size_t MB_LEN_MAX = 6; // XXX
}


//----------------------------------------------------------------------------//

// TODO: stateful encoding

import std.contracts;
import std.utf;

import core.stdc.errno;
import core.stdc.locale;
import core.stdc.string : memset, strchr, strcmp;


struct NativeConv
{
    @disable this(this) { assert(0); }

    void init(char replacement = '?')
    {
        version (HAVE_MBSTATE)
        {
            memset(&mbstate_, 0, mbstate_.sizeof);
            assert(mbsinit(&mbstate_));
        }
        version (USE_ICONV)
        {
            // TODO もっと良い方法
            const(char)* native = strchr(setlocale(LC_CTYPE, null), '.');
            if (native !is null)
            {
                assert(*native == '.');
                ++native;
                if (strcmp(native, "PCK") == 0)
                    native = "Shift_JIS"; // Solaris
            }
            else
            {
                native = "ASCII"; // or UTF-8?
            }
            utf32cd_ = iconv_open(native, ICONV_DSTRING);
            errnoEnforce(utf32cd_ != iconv_t.init, "iconv does not "
                    ~"support convertion between Unicode and the "
                    ~"current locale encoding");
        }
        replacement_ = replacement;
    }

    void term()
    {
        version (USE_ICONV)
        {
            if (utf32cd_ != iconv_t.init)
            {
                errnoEnforce(iconv_close(utf32cd_) != -1);
                utf32cd_ = iconv_t.init;
            }
        }
    }


    //----------------------------------------------------------------//
    // Unicode -> Native
    //----------------------------------------------------------------//

    /*
     * Represents a Unicode code point c in the multibyte encoding of
     * the current locale and stores the multibyte character (possibly
     * with some shift sequences) to mbuf.
     *
     * Returns:
     *   The number of bytes written to mbuf.
     */
    size_t toMultibyteChar(dchar c, char[] mbuf)
    {
        static if (is(wchar_t == wchar))
        {
            wchar[2] wc = void;
            wchar[3] wcz = 0;
            size_t wcLen = std.utf.encode(wc, c);
            wcz[0 .. wcLen] = wc[0 .. wcLen];

            size_t mbLen;
            version (HAVE_MBSTATE)
                mbLen = wcsrtombs(mbuf.ptr, wcz.ptr, mbuf.length, &mbstate_);
            else
                mbLen = wcstombs(mbuf.ptr, wcz.ptr, mbuf.length);
            errnoEnforce(0 <= mbLen && mbLen <= mbuf.length, "Cannot "
                    ~"represent a Unicode character in the current "
                    ~"locale encoding");
            return mbLen;
        }
        else static if (is(wchar_t == dchar))
        {
            size_t mbLen;
            version (HAVE_MBSTATE)
                mbLen = wcrtomb(mbuf.ptr, c, &mbstate_);
            else
                mbLen = wctomb(mbuf.ptr, c);
            errnoEnforce(0 <= mbLen && mbLen <= mbuf.length, "Cannot "
                    ~"represent a Unicode character in the current "
                    ~"lcoale encoding");
            return mbLen;
        }
        else version (USE_ICONV)
        {
            ubyte* pchar = cast(ubyte*) &c;
            size_t charLeft = c.sizeof;
            ubyte* pbuf = cast(ubyte*) mbuf.ptr;
            size_t bufLeft = mbuf.length;

            assert(utf32cd_ != iconv_t.init);
            auto stat = iconv(utf32cd_,
                    &pchar, &charLeft, &pbuf, &bufLeft);
            errnoEnforce(stat != -1, "Cannot represent a Unicode "
                    ~"character in the current locale encoding");
            return mbuf.length - bufLeft;
        }
        else
        {
            static assert(0);
        }
    }


    /*
     * Represents a Unicode code point c in the wide character set of the
     * current locale and stores the wide character sequence to mbuf.
     *
     * Returns:
     *   The number of wide characters written to wbuf.
     */
    size_t toWideChar(dchar c, wchar_t[] wbuf)
    {
        enforce(wbuf.length >= 1);

        static if (is(wchar_t == wchar))
        {
            wchar[2] wc = void;
            size_t wcLen = std.utf.encode(wc, c);
            enforce(wbuf.length >= wcLen);
            wbuf[0 .. wcLen] = wc[0 .. wcLen];
            return wcLen;
        }
        else static if (is(wchar_t == dchar))
        {
            wbuf[0] = c;
            return 1;
        }
        else version (USE_ICONV)
        {
            // Unicode -> multibyte -> wide
            char[64] mbuf = void;
            size_t mbcLen = toMultibyteChar(c, mbuf);

            size_t mbUsed;
            version (HAVE_MBSTATE)
                mbUsed = mbrtowc(wbuf.ptr, mbuf.ptr, mbcLen, &mbstate_);
            else
                mbUsed = mbtowc(wbuf.ptr, mbuf.ptr, mbcLen);
            errnoEnforce(mbUsed == 0 || mbUsed == mbcLen);

            if (mbUsed == 0)
                wbuf[0] = 0;
            return 1;
        }
        else
        {
            static assert(0);
        }
    }


    //----------------------------------------------------------------//
    // Native -> Unicode
    //----------------------------------------------------------------//

    // TODO

    //----------------------------------------------------------------//
private:
    version (HAVE_MBSTATE)
        mbstate_t mbstate_;
    version (USE_ICONV)
        iconv_t utf32cd_;
    char replacement_;      // TODO
}

