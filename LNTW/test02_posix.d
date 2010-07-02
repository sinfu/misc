/+
POSIX

FILE* がバイト指向のとき
   1. デフォルトロケールのコードセットが UTF-8 ならば fwrite
   2. defined(__STDC_ISO_10646__)，mbstate_t かつ POSIX multi-locale がサポート
      されるならば uselocale + wcrtomb + fwrite
   3. iconv が存在して，デフォルトロケールの CODESET が有効な iconv tocode
      ならば iconv + fwrite
   4. enforcement failure (マルチバイトに変換できない)

FILE* がワイド指向のとき
   1. defined(__STDC_ISO_10646__) ならば fputwc
   2. デフォルトロケールの wchar_t が Unicode ならば fputwc
   3. mbstate_t と POSIX multi-locale がサポートされるならば，いったんマルチ
      バイトに変換 (結局 iconv) してから，uselocale + mbrtowc + fputwc
   4. enforcement failure (ワイドに変換できない)

他のプログラムやファイル出力で期待されるエンコーディングは起動時のロケールのはず．

 +/
version (Posix) {} else { static assert(0); }

import std.stdio;

import core.stdc.stdlib;
import core.stdc.wchar_;

import utfex;


private T* assumeLocked(T)(shared(T)* x)
{
    return cast(T*) x;
}

void main()
{
    if (initialCodesetz == "UTF-8\0")
    {}
}

void main_()
{
    FILE* fp = stdout.getFP();

    FLOCK(fp);
    scope(exit) FUNLOCK(fp);

    auto unlockedFP = assumeLocked(fp);

    //
    string s;
    s = "Chazuke (茶漬け, ちゃづけ) or ochazuke (お茶漬け, from o + cha tea + tsuke submerge) is "
        ~"a simple Japanese dish made by pouring green tea, dashi, or hot water over cooked rice "
        ~"roughly in the same proportion as milk over cereal, usually with savoury toppings.";
    s = "このドキュメントは間違えだらけで、全然役に立たない。\n"
        ~"この埃だれけのテレビをちゃんと拭いてくれない？\n"
        ~"たった１キロを走っただけで、汗まみれになるのは情けない。\n"
        ~"女の子と共通の話題ができて、自分の体も健康になる。いいことずくめですよ。\n";
}


//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://

version (linux)
{
    version = WCHART_DCHAR;
    version = HAVE_MBSTATE;
    version = HAVE_BOUNDED_MBWC;
    version = HAVE_ICONV;
    version = HAVE_MULTILOCALE;
}
else version (OSX)
{
    version = WCHART_DCHAR;
    version = HAVE_MBSTATE;
    version = HAVE_BOUNDED_MBWC;
    version = HAVE_ICONV;
    version = HAVE_MULTILOCALE;
}
else version (FreeBSD)
{
    version = HAVE_MBSTATE;
    version = HAVE_BOUNDED_MBWC;
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

version (HAVE_ICONV) private
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


//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://

/*
 * Keep the locale information at program startup.
 */

import core.stdc.locale;
import core.stdc.string;


// The value of the LC_CTYPE locale in zero-terminated ASCII string.
immutable string initialCTYPEz;

// The value of the CODESET langinfo in zero-terminated ASCII string.
immutable string initialCodesetz;

version (HAVE_MULTILOCALE)
{
    // A hard copy of a locale_t object corresponding to initialCTYPEz.
    // This object MUST NOT be freed nor modified.
    locale_t initialLocaleCTYPE()
    {
        return initialLocaleCTYPE_;
    }
    private __gshared locale_t initialLocaleCTYPE_;
}

static this()
{
    if (auto ctype = setlocale(LC_CTYPE, ""))
        initialCTYPEz = ctype[0 .. strlen(ctype) + 1].idup;
    else
        initialCTYPEz = "C\0";

    if (auto codeset = nl_langinfo(CODESET))
        initialCodesetz = codeset[0 .. strlen(codeset) + 1].idup;
    else
        initialCodesetz = "US-ASCII\0";

    version (HAVE_MULTILOCALE)
    {
        if (auto newLoc = newlocale(LC_CTYPE_MASK, defaultCTYPE, null))
            initialLocaleCTYPE_ = newLoc;
        else
            initialLocaleCTYPE_ = LC_GLOBAL_LOCALE;
    }

    // revert to the default
    setlocale(LC_CTYPE, "C");
}


////////////////////////////////////////////////////////////////////////////////
// druntime
////////////////////////////////////////////////////////////////////////////////

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


