/**
 * Adding missing D header file for POSIX.
 *
 * Standards: The Open Group Base Specifications Issue 6, IEEE Std 1003.1, 2004 Edition
 */
module core.sys.posix.iconv;

extern(C) @system:

//
// Required
//
/*
iconv_t

iconv_t iconv_open(in char*, in char*);
size_t  iconv(iconv_t, ubyte**, size_t*, ubyte**, size_t*);
int     iconv_close(iconv_t);
*/

version( linux )
{
    alias void* iconv_t;

    iconv_t iconv_open(in char*, in char*);
    size_t  iconv(iconv_t, ubyte**, size_t*, ubyte**, size_t*);
    int     iconv_close(iconv_t);
}
else version( OSX )
{
    // OSX libc does not have iconv
}
else version( FreeBSD )
{
    // FreeBSD libc does not have iconv
}
else version( Solaris )
{
    struct _iconv_info
    {
        // Managed by OS
    }
    alias _iconv_info* iconv_t;

    iconv_t iconv_open(in char*, in char*);
    size_t  iconv(iconv_t, const(ubyte)**, size_t*, ubyte**, size_t*);
    int     iconv_close(iconv_t);
}
