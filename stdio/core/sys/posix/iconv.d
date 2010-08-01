//
// Add missing POSIX header file
//
module core.sys.posix.iconv;

extern(C) @system:

version( linux )
{
    // GNU
    alias void* iconv_t;

    iconv_t iconv_open(in char*, in char*);
    size_t  iconv(iconv_t, in ubyte**, size_t*, ubyte**, size_t*);
    int     iconv_close(iconv_t);
}
else version( OSX )
{
    alias void* iconv_t;

    iconv_t iconv_open(in char*, in char*);
    size_t  iconv(iconv_t, in ubyte**, size_t*, ubyte**, size_t*);
    int     iconv_close(iconv_t);
}
else version( Solaris )
{
    alias void* iconv_t;    // struct _iconv_info*

    iconv_t iconv_open(in char*, in char*);
    size_t  iconv(iconv_t, in ubyte**, size_t*, ubyte**, size_t*);
    int     iconv_close(iconv_t);
}

