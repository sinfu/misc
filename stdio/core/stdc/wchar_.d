// Add missing MB_CUR_MAX

/**
 * D header file for C99.
 *
 * Copyright: Copyright Sean Kelly 2005 - 2009.
 * License:   <a href="http://www.boost.org/LICENSE_1_0.txt">Boost License 1.0</a>.
 * Authors:   Sean Kelly
 * Standards: ISO/IEC 9899:1999 (E)
 *
 *          Copyright Sean Kelly 2005 - 2009.
 * Distributed under the Boost Software License, Version 1.0.
 *    (See accompanying file LICENSE_1_0.txt or copy at
 *          http://www.boost.org/LICENSE_1_0.txt)
 */
module core.stdc.wchar_;

private import core.stdc.config;
private import core.stdc.stdarg; // for va_list
private import core.stdc.stdio;  // for FILE, not exposed per spec
public import core.stdc.stddef;  // for size_t, wchar_t
public import core.stdc.time;    // for tm
public import core.stdc.stdint;  // for WCHAR_MIN, WCHAR_MAX

extern (C):

nothrow:

version( Windows )
{
    version (DigitalMars)
    {
        struct mbstate_t { /+dummy+/ }
        extern __gshared size_t __locale_mbsize;
        alias __locale_mbsize MB_CUR_MAX;
    }
}
else version( linux )
{
    struct mbstate_t
    {
        int    count;
        wint_t value = 0;
    }

    @system size_t __ctype_get_mb_cur_max() shared;
    alias __ctype_get_mb_cur_max MB_CUR_MAX;
}
else version( OSX )
{
    union mbstate_t
    {
        ubyte[128] __mbstate8;
        long       _mbstateL;
    }

    @system size_t __mb_cur_max() shared;
    alias __mb_cur_max MB_CUR_MAX;
}
else version( FreeBSD )
{
    union mbstate_t
    {
        ubyte[128] __mbstate8;
        long       _mbstateL;
    }

    extern __gshared size_t __mb_cur_max;
    alias __mb_cur_max MB_CUR_MAX;
}
else version( Solaris )
{
    alias int wchar_t;

    struct mbstate_t
    {
        version (LP64)
            long[4] __filler;
        else
            int [6] __filler;
    }

    extern __gshared ubyte* __ctype;
    @system size_t MB_CUR_MAX() { return __ctpye[520]; }
}


alias wchar_t wint_t;

enum wint_t WEOF = -1;

int fwprintf(FILE* stream, in wchar_t* format, ...);
int fwscanf(FILE* stream, in wchar_t* format, ...);
int swprintf(wchar_t* s, size_t n, in wchar_t* format, ...);
int swscanf(in wchar_t* s, in wchar_t* format, ...);
int vfwprintf(FILE* stream, in wchar_t* format, va_list arg);
int vfwscanf(FILE* stream, in wchar_t* format, va_list arg);
int vswprintf(wchar_t* s, size_t n, in wchar_t* format, va_list arg);
int vswscanf(in wchar_t* s, in wchar_t* format, va_list arg);
int vwprintf(in wchar_t* format, va_list arg);
int vwscanf(in wchar_t* format, va_list arg);
int wprintf(in wchar_t* format, ...);
int wscanf(in wchar_t* format, ...);

wint_t fgetwc(FILE* stream);
wint_t fputwc(wchar_t c, FILE* stream);

wchar_t* fgetws(wchar_t* s, int n, FILE* stream);
int      fputws(in wchar_t* s, FILE* stream);

extern (D)
{
    wint_t getwchar()                     { return fgetwc(stdin);     }
    wint_t putwchar(wchar_t c)            { return fputwc(c,stdout);  }
    wint_t getwc(FILE* stream)            { return fgetwc(stream);    }
    wint_t putwc(wchar_t c, FILE* stream) { return fputwc(c, stream); }
}

wint_t ungetwc(wint_t c, FILE* stream);
int    fwide(FILE* stream, int mode);

double  wcstod(in wchar_t* nptr, wchar_t** endptr);
float   wcstof(in wchar_t* nptr, wchar_t** endptr);
real    wcstold(in wchar_t* nptr, wchar_t** endptr);
c_long  wcstol(in wchar_t* nptr, wchar_t** endptr, int base);
long    wcstoll(in wchar_t* nptr, wchar_t** endptr, int base);
c_ulong wcstoul(in wchar_t* nptr, wchar_t** endptr, int base);
ulong   wcstoull(in wchar_t* nptr, wchar_t** endptr, int base);

wchar_t* wcscpy(wchar_t* s1, in wchar_t* s2);
wchar_t* wcsncpy(wchar_t* s1, in wchar_t* s2, size_t n);
wchar_t* wcscat(wchar_t* s1, in wchar_t* s2);
wchar_t* wcsncat(wchar_t* s1, in wchar_t* s2, size_t n);
int      wcscmp(in wchar_t* s1, in wchar_t* s2);
int      wcscoll(in wchar_t* s1, in wchar_t* s2);
int      wcsncmp(in wchar_t* s1, in wchar_t* s2, size_t n);
size_t   wcsxfrm(wchar_t* s1, in wchar_t* s2, size_t n);
wchar_t* wcschr(in wchar_t* s, wchar_t c);
size_t   wcscspn(in wchar_t* s1, in wchar_t* s2);
wchar_t* wcspbrk(in wchar_t* s1, in wchar_t* s2);
wchar_t* wcsrchr(in wchar_t* s, wchar_t c);
size_t   wcsspn(in wchar_t* s1, in wchar_t* s2);
wchar_t* wcsstr(in wchar_t* s1, in wchar_t* s2);
wchar_t* wcstok(wchar_t* s1, in wchar_t* s2, wchar_t** ptr);
size_t   wcslen(in wchar_t* s);

wchar_t* wmemchr(in wchar_t* s, wchar_t c, size_t n);
int      wmemcmp(in wchar_t* s1, in wchar_t* s2, size_t n);
wchar_t* wmemcpy(wchar_t* s1, in wchar_t* s2, size_t n);
wchar_t* wmemmove(wchar_t*s1, in wchar_t* s2, size_t n);
wchar_t* wmemset(wchar_t* s, wchar_t c, size_t n);

size_t wcsftime(wchar_t* s, size_t maxsize, in wchar_t* format, in tm* timeptr);

version( Windows )
{
    wchar_t* _wasctime(tm*);      // non-standard
    wchar_t* _wctime(time_t*);	  // non-standard
    wchar_t* _wstrdate(wchar_t*); // non-standard
    wchar_t* _wstrtime(wchar_t*); // non-standard
}

wint_t btowc(int c);
int    wctob(wint_t c);
int    mbsinit(in mbstate_t* ps);
size_t mbrlen(in char* s, size_t n, mbstate_t* ps);
size_t mbrtowc(wchar_t* pwc, in char* s, size_t n, mbstate_t* ps);
size_t wcrtomb(char* s, wchar_t wc, mbstate_t* ps);
size_t mbsrtowcs(wchar_t* dst, in char** src, size_t len, mbstate_t* ps);
size_t wcsrtombs(char* dst, in wchar_t** src, size_t len, mbstate_t* ps);

size_t mbsnrtowcs(wchar_t* dst, in char** src, size_t nms, size_t len, mbstate_t* ps);
size_t wcsnrtombs(char* dst, in wchar_t** src, size_t nwc, size_t len, mbstate_t* ps);

