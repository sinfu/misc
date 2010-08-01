//
// Add missing POSIX header file
//
module core.sys.posix.locale;

import core.stdc.locale;

alias void* locale_t;

version( linux )
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
else version( OSX )
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

extern(C) @system nothrow
{
    locale_t newlocale(int category_mask, in char *locale, locale_t base);
    locale_t duplocale(locale_t locobj);
    void     freelocale(locale_t locobj);
    locale_t uselocale(locale_t newloc);
}

