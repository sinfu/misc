module utf;

////////////////////////////////////////////////////////////////////////////////
// std.utf extension
////////////////////////////////////////////////////////////////////////////////

import std.utf;

version (unittest) private bool expectError_(lazy void expr)
{
    try { expr; } catch (UtfException e) { return true; }
    return false;
}


//----------------------------------------------------------------------------//
// UTF-8 to others
//----------------------------------------------------------------------------//

/**
 * Converts the UTF-8 string in $(D inbuf) to the corresponding UTF-16
 * string in $(D outbuf), upto $(D outbuf.length) UTF-16 code units.
 * Upon successful return, $(D inbuf) will be advanced to immediately
 * after the last converted UTF-8 sequence.
 *
 * Returns:
 *   The number of UTF-16 code units written to $(D outbuf).
 *
 * Throws:
 *   $(D UtfException) on encountering a malformed UTF-8 sequence in
 *   $(D inbuf).
 */
size_t convert(ref const(char)[] inbuf, wchar[] outbuf) @safe
{
    const(char)[] curin = inbuf;
    wchar[] curout = outbuf;

    while (curin.length != 0 && curout.length != 0)
    {
        const u1 = curin[0];

        if ((u1 & 0b10000000) == 0)
        {
            // 0xxxxxxx (U+0 - U+7F)
            curout[0] = u1;
            curout = curout[1 .. $];
            curin  = curin [1 .. $];
        }
        else if ((u1 & 0b11100000) == 0b11000000)
        {
            // 110xxxxx 10xxxxxx (U+80 - U+7FF)
            if (curin.length < 2)
                throw new UtfException("missing trailing UTF-8 sequence", u1);

            const u2 = curin[1];
            if ((u2 & 0b11000000) ^ 0b10000000)
                throw new UtfException("decoding UTF-8", u1, u2);

            // the corresponding UTF-16 code unit
            uint w;
            w =             u1 & 0b00011111;
            w = (w << 6) | (u2 & 0b00111111);
            if (w < 0x80)
                throw new UtfException("overlong UTF-8 sequence", u1, u2);
            assert(0x80 <= w && w <= 0x7FF);

            curout[0] = cast(wchar) w;
            curout = curout[1 .. $];
            curin  = curin [2 .. $];
        }
        else if ((u1 & 0b11110000) == 0b11100000)
        {
            // 1110xxxx 10xxxxxx 10xxxxxx (U+800 - U+FFFF)
            if (curin.length < 3)
                throw new UtfException("missing trailing UTF-8 sequence", u1);

            const u2 = curin[1];
            const u3 = curin[2];
            if ( ((u2 & 0b11000000) ^ 0b10000000) |
                 ((u3 & 0b11000000) ^ 0b10000000) )
                throw new UtfException("decoding UTF-8", u1, u2, u3);

            // the corresponding UTF-16 code unit
            uint w;
            w =             u1 & 0b00001111;
            w = (w << 6) | (u2 & 0b00111111);
            w = (w << 6) | (u3 & 0b00111111);
            if (w < 0x800)
                throw new UtfException("overlong UTF-8 sequence", u1, u2, u3);
            if ((w & 0xF800) == 0xD800)
                throw new UtfException("surrogate code point in UTF-8", w);
            assert(0x800 <= w && w <= 0xFFFF);
            assert(w < 0xD800 || 0xDFFF < w);

            curout[0] = cast(wchar) w;
            curout = curout[1 .. $];
            curin  = curin [3 .. $];
        }
        else if ((u1 & 0b11111000) == 0b11110000)
        {
            // 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx (U+10000 - U+10FFFF)
            if (curin.length < 4)
                throw new UtfException("missing trailing UTF-8 sequence", u1);

            // The code point needs surrogate-pair encoding.
            if (curout.length < 2)
                break; // No room; stop converting.

            const u2 = curin[1];
            const u3 = curin[2];
            const u4 = curin[3];
            if ( ((u2 & 0b11000000) ^ 0b10000000) |
                 ((u3 & 0b11000000) ^ 0b10000000) |
                 ((u4 & 0b11000000) ^ 0b10000000) )
                throw new UtfException("decoding UTF-8", u1, u2, u3, u4);

            // First calculate the corresponding Unicode code point, and then
            // compose a surrogate pair.
            uint c;
            c =             u1 & 0b00000111;
            c = (c << 6) | (u2 & 0b00111111);
            c = (c << 6) | (u3 & 0b00111111);
            c = (c << 6) | (u4 & 0b00111111);
            if (c < 0x10000)
                throw new UtfException("overlong UTF-8 sequence", u1, u2, u3, u4);
            if (c > 0x10FFFF)
                throw new UtfException("illegal code point", c);
            assert(0x10000 <= c && c <= 0x10FFFF);

            curout[0] = cast(wchar) ((((c - 0x10000) >> 10) & 0x3FF) + 0xD800);
            curout[1] = cast(wchar) (( (c - 0x10000)        & 0x3FF) + 0xDC00);
            curout = curout[2 .. $];
            curin  = curin [4 .. $];
        }
        else
        {
            // invalid 5/6-byte UTF-8 or trailing byte 10xxxxxx
            throw new UtfException("illegal UTF-8 leading byte", u1);
        }
    }

    inbuf = curin;
    return outbuf.length - curout.length;
}

/// ditto
size_t convert(ref immutable(char)[] inbuf, wchar[] outbuf) @safe
{
    const(char)[] inbuf_ = inbuf;
    const result = convert(inbuf_, outbuf);
    assert(inbuf.ptr <= inbuf_.ptr && inbuf_.ptr <= inbuf.ptr + inbuf.length);
    inbuf = cast(immutable) inbuf_;
    return result;
}

unittest
{
    string s = "\u0000\u007F\u0080\u07FF\u0800\uD7FF\uE000\uFFFD"
        ~"\U00010000\U0010FFFF";
    wchar[6] dstbuf;

    assert(s.convert(dstbuf) == 6);
    assert(s.length == 14);
    assert(dstbuf[0 .. 6] == "\u0000\u007F\u0080\u07FF\u0800\uD7FF");

    assert(s.convert(dstbuf) == 6);
    assert(s.length == 0);
    assert(dstbuf[0 .. 6] == "\uE000\uFFFD\U00010000\U0010FFFF");
}


/**
 * Converts the UTF-8 string in $(D inbuf) to the corresponding UTF-32
 * string in $(D outbuf), upto $(D outbuf.length) UTF-32 code units.
 * Upon successful return, $(D inbuf) will be advanced to immediately
 * after the last converted UTF-8 sequence.
 *
 * Returns:
 *   The number of UTF-32 code units, or Unicode code points, written
 *   to $(D outbuf).
 *
 * Throws:
 *   $(D UtfException) on encountering a malformed UTF-8 sequence
 *   in $(D inbuf).
 */
size_t convert(ref const(char)[] inbuf, dchar[] outbuf) @safe
{
    const(char)[] curin = inbuf;
    dchar[] curout = outbuf;

    while (curin.length != 0 && curout.length != 0)
    {
        const u1 = curin[0];

        if ((u1 & 0b10000000) == 0)
        {
            // 0xxxxxxx (U+0 - U+7F)
            curout[0] = u1;
            curout = curout[1 .. $];
            curin  = curin [1 .. $];
        }
        else if ((u1 & 0b11100000) == 0b11000000)
        {
            // 110xxxxx 10xxxxxx (U+80 - U+7FF)
            if (curin.length < 2)
                throw new UtfException("missing trailing UTF-8 sequence", u1);

            const u2 = curin[1];
            if ((u2 & 0b11000000) ^ 0b10000000)
                throw new UtfException("decoding UTF-8", u1, u2);

            // the corresponding code point
            uint c;
            c =             u1 & 0b00011111;
            c = (c << 6) | (u2 & 0b00111111);
            if (c < 0x80)
                throw new UtfException("overlong UTF-8 sequence", u1, u2);
            assert(0x80 <= c && c <= 0x7FF);

            curout[0] = cast(dchar) c;
            curout = curout[1 .. $];
            curin  = curin [2 .. $];
        }
        else if ((u1 & 0b11110000) == 0b11100000)
        {
            // 1110xxxx 10xxxxxx 10xxxxxx (U+800 - U+FFFF)
            if (curin.length < 3)
                throw new UtfException("missing trailing UTF-8 sequence", u1);

            const u2 = curin[1];
            const u3 = curin[2];
            if ( ((u2 & 0b11000000) ^ 0b10000000) |
                 ((u3 & 0b11000000) ^ 0b10000000) )
                throw new UtfException("decoding UTF-8", u1, u2, u3);

            // the corresponding code point
            uint c;
            c =             u1 & 0b00001111;
            c = (c << 6) | (u2 & 0b00111111);
            c = (c << 6) | (u3 & 0b00111111);
            if (c < 0x800)
                throw new UtfException("overlong UTF-8 sequence", u1, u2, u3);
            if ((c & 0xF800) == 0xD800)
                throw new UtfException("surrogate code point in UTF-8", c);
            assert(0x800 <= c && c <= 0xFFFF);
            assert(c < 0xD800 || 0xDFFF < c);

            curout[0] = cast(dchar) c;
            curout = curout[1 .. $];
            curin  = curin [3 .. $];
        }
        else if ((u1 & 0b11111000) == 0b11110000)
        {
            // 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx (U+10000 - U+10FFFF)
            if (curin.length < 4)
                throw new UtfException("missing trailing UTF-8 sequence", u1);

            const u2 = curin[1];
            const u3 = curin[2];
            const u4 = curin[3];
            if ( ((u2 & 0b11000000) ^ 0b10000000) |
                 ((u3 & 0b11000000) ^ 0b10000000) |
                 ((u4 & 0b11000000) ^ 0b10000000) )
                throw new UtfException("decoding UTF-8", u1, u2, u3, u4);

            // the corresponding code point
            uint c;
            c =             u1 & 0b00000111;
            c = (c << 6) | (u2 & 0b00111111);
            c = (c << 6) | (u3 & 0b00111111);
            c = (c << 6) | (u4 & 0b00111111);
            if (c < 0x10000)
                throw new UtfException("overlong UTF-8 sequence", u1, u2, u3, u4);
            if (c > 0x10FFFF)
                throw new UtfException("illegal code point", c);
            assert(0x10000 <= c && c <= 0x10FFFF);

            curout[0] = cast(dchar) c;
            curout = curout[1 .. $];
            curin  = curin [4 .. $];
        }
        else
        {
            // invalid 5/6-byte UTF-8 or trailing byte 10xxxxxx
            throw new UtfException("illegal UTF-8 leading byte", u1);
        }
    }

    inbuf = curin;
    return outbuf.length - curout.length;
}

/// ditto
size_t convert(ref immutable(char)[] inbuf, dchar[] outbuf) @safe
{
    const(char)[] inbuf_ = inbuf;
    const result = convert(inbuf_, outbuf);
    assert(inbuf.ptr <= inbuf_.ptr && inbuf_.ptr <= inbuf.ptr + inbuf.length);
    inbuf = cast(immutable) inbuf_;
    return result;
}

unittest
{
    string s = "\u0000\u007F\u0080\u07FF\u0800\uD7FF\uE000\uFFFD"
        ~"\U00010000\U0010FFFF";
    dchar[6] dstbuf;

    assert(s.convert(dstbuf) == 6);
    assert(s.length == 14);
    assert(dstbuf[0 .. 6] == "\u0000\u007F\u0080\u07FF\u0800\uD7FF");

    assert(s.convert(dstbuf) == 4);
    assert(s.length == 0);
    assert(dstbuf[0 .. 4] == "\uE000\uFFFD\U00010000\U0010FFFF");
}


//----------------------------------------------------------------------------//
// UTF-16 to others
//----------------------------------------------------------------------------//

/**
 * Converts the UTF-16 string in $(D inbuf) to the corresponding UTF-8
 * string in $(D outbuf), upto $(D outbuf.length) UTF-8 code units.
 * Upon successful return, $(D inbuf) will be advanced to immediately
 * after the last converted UTF-16 sequence.
 *
 * Returns:
 *   The number of UTF-8 code units written to $(D outbuf).
 *
 * Throws:
 *   $(D UtfException) on encountering a malformed UTF-16 sequence in
 *   $(D inbuf).
 */
size_t convert(ref const(wchar)[] inbuf, char[] outbuf) @safe
{
    const(wchar)[] curin = inbuf;
    char[] curout = outbuf;

    while (curin.length != 0)
    {
        wchar w = curin[0];

        if (w <= 0x7F)
        {
            // UTF-8: 0xxxxxxx
            if (curout.length < 1)
                break; // No room; stop converting.

            curout[0] = cast(char) w;
            curout = curout[1 .. $];
            curin  = curin [1 .. $];
        }
        else if (w <= 0x7FF)
        {
            // UTF-8: 110xxxxx 10xxxxxx
            if (curout.length < 2)
                break; // No room; stop converting.

            curout[0] = cast(char) (0b11000000 | (w >> 6        ));
            curout[1] = cast(char) (0b10000000 | (w & 0b00111111));
            curout = curout[2 .. $];
            curin  = curin [1 .. $];
        }
        else if ((w & 0xF800) != 0xD800)
        {
            // UTF-8: 1110xxxx 10xxxxxx 10xxxxxx
            if (curout.length < 3)
                break; // No room; stop converting.

            curout[0] = cast(char) (0b11100000 |  (w >> 12)              );
            curout[1] = cast(char) (0b10000000 | ((w >> 6 ) & 0b00111111));
            curout[2] = cast(char) (0b10000000 | ( w        & 0b00111111));
            curout = curout[3 .. $];
            curin  = curin [1 .. $];
        }
        else // Found a surrogate code unit.
        {
            if ((w & 0xFC00) == 0xDC00)
                throw new UtfException("isolated low surrogate", w);
            assert((w & 0xFC00) == 0xD800);

            wchar w1 = w;
            wchar w2 = curin[1];
            if ((w2 & 0xFC00) != 0xDC00)
                throw new UtfException("isolated high surrogate", w1, w2);

            // UTF-8: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
            if (curout.length < 4)
                break; // No room; stop converting.

            // First calculate the corresponding Unicode code point, and then
            // compose the UTF-8 sequence.
            uint c;
            c =              w1 - 0xD7C0;
            c = (c << 10) | (w2 - 0xDC00);
            assert(0x10000 <= c && c <= 0x10FFFF);

            curout[0] = cast(char) (0b11110000 | ( c >> 18)              );
            curout[1] = cast(char) (0b10000000 | ((c >> 12) & 0b00111111));
            curout[2] = cast(char) (0b10000000 | ((c >>  6) & 0b00111111));
            curout[3] = cast(char) (0b10000000 | ( c        & 0b00111111));
            curout = curout[4 .. $];
            curin  = curin [2 .. $];
        }
    }

    inbuf = curin;
    return outbuf.length - curout.length;
}

/// ditto
size_t convert(ref immutable(wchar)[] inbuf, char[] outbuf) @safe
{
    const(wchar)[] inbuf_ = inbuf;
    const result = convert(inbuf_, outbuf);
    assert(inbuf.ptr <= inbuf_.ptr && inbuf_.ptr <= inbuf.ptr + inbuf.length);
    inbuf = cast(immutable) inbuf_;
    return result;
}

unittest
{
    wstring s = "\u0000\u007F\u0080\u07FF\u0800\uD7FF\uE000\uFFFD"
        ~"\U00010000\U0010FFFF";
    char[6] dstbuf;

    assert(s.convert(dstbuf) == 6);
    assert(s.length == 8);
    assert(dstbuf[0 .. 6] == "\u0000\u007F\u0080\u07FF");

    assert(s.convert(dstbuf) == 6);
    assert(s.length == 6);
    assert(dstbuf[0 .. 6] == "\u0800\uD7FF");

    assert(s.convert(dstbuf) == 6);
    assert(s.length == 4);
    assert(dstbuf[0 .. 6] == "\uE000\uFFFD");

    assert(s.convert(dstbuf) == 4);
    assert(s.length == 2);
    assert(dstbuf[0 .. 4] == "\U00010000");

    assert(s.convert(dstbuf) == 4);
    assert(s.length == 0);
    assert(dstbuf[0 .. 4] == "\U0010FFFF");
}


/**
 * Converts the UTF-16 string in $(D inbuf) to the corresponding UTF-32
 * string in $(D outbuf), upto $(D outbuf.length) UTF-32 code units.
 * Upon successful return, $(D inbuf) will be advanced to immediately
 * after the last converted UTF-16 sequence.
 *
 * Returns:
 *   The number of UTF-32 code units written to $(D outbuf).
 *
 * Throws:
 *   $(D UtfException) on encountering a malformed UTF-16 sequence in
 *   $(D inbuf).
 */
size_t convert(ref const(wchar)[] inbuf, dchar[] outbuf) @safe
{
    const(wchar)[] curin = inbuf;
    dchar[] curout = outbuf;

    while (curin.length != 0 && curout.length != 0)
    {
        wchar w = curin[0];

        if ((w & 0xF800) != 0xD800)
        {
            curout[0] = w;
            curout = curout[1 .. $];
            curin  = curin [1 .. $];
        }
        else // surrogate code unit
        {
            if ((w & 0xFC00) == 0xDC00)
                throw new UtfException("isolated low surrogate", w);
            assert((w & 0xFC00) == 0xD800);

            wchar w1 = w;
            wchar w2 = curin[1];
            if ((w2 & 0xFC00) != 0xDC00)
                throw new UtfException("isolated high surrogate", w1, w2);

            // Calculate the corresponding Unicode code point.
            uint c;
            c =              w1 - 0xD7C0;
            c = (c << 10) | (w2 - 0xDC00);
            assert(0x10000 <= c && c <= 0x10FFFF);

            curout[0] = cast(dchar) c;
            curout = curout[1 .. $];
            curin  = curin [2 .. $];
        }
    }

    inbuf = curin;
    return outbuf.length - curout.length;
}

/// ditto
size_t convert(ref immutable(wchar)[] inbuf, dchar[] outbuf) @safe
{
    const(wchar)[] inbuf_ = inbuf;
    const result = convert(inbuf_, outbuf);
    assert(inbuf.ptr <= inbuf_.ptr && inbuf_.ptr <= inbuf.ptr + inbuf.length);
    inbuf = cast(immutable) inbuf_;
    return result;
}

unittest
{
    wstring s = "\u0000\u007F\u0080\u07FF\u0800\uD7FF\uE000\uFFFD"
        ~"\U00010000\U0010FFFF";
    dchar[6] dstbuf;

    assert(s.convert(dstbuf) == 6);
    assert(s.length == 6);
    assert(dstbuf[0 .. 6] == "\u0000\u007F\u0080\u07FF\u0800\uD7FF");

    assert(s.convert(dstbuf) == 4);
    assert(s.length == 0);
    assert(dstbuf[0 .. 4] == "\uE000\uFFFD\U00010000\U0010FFFF");
}


//----------------------------------------------------------------------------//
// UTF-32 to others
//----------------------------------------------------------------------------//

/**
 * Converts the UTF-32 string in $(D inbuf) to the corresponding UTF-8
 * string in $(D outbuf), upto $(D outbuf.length) UTF-8 code units.
 * Upon successful return, $(D inbuf) will be advanced to immediately
 * after the last converted UTF-32 code unit.
 *
 * Returns:
 *   The number of UTF-8 code units written to $(D outbuf).
 *
 * Throws:
 *   $(D UtfException) on encountering a malformed UTF-32 sequence in
 *   $(D inbuf).
 */
size_t convert(ref const(dchar)[] inbuf, char[] outbuf) @safe
{
    const(dchar)[] curin = inbuf;
    char[] curout = outbuf;

    while (curin.length != 0)
    {
        dchar c = curin[0];

        if (c <= 0x7F)
        {
            // UTF-8: 0xxxxxxx
            if (curout.length < 1)
                break; // No room; stop converting.

            curout[0] = cast(char) c;
            curout = curout[1 .. $];
            curin  = curin [1 .. $];
        }
        else if (c <= 0x7FF)
        {
            // UTF-8: 110xxxxx 10xxxxxx
            if (curout.length < 2)
                break; // No room; stop converting.

            curout[0] = cast(char) (0b11000000 | (c >> 6        ));
            curout[1] = cast(char) (0b10000000 | (c & 0b00111111));
            curout = curout[2 .. $];
            curin  = curin [1 .. $];
        }
        else if (c <= 0xFFFF)
        {
            // UTF-8: 1110xxxx 10xxxxxx 10xxxxxx
            if (curout.length < 3)
                break; // No room; stop converting.

            curout[0] = cast(char) (0b11100000 |  (c >> 12)              );
            curout[1] = cast(char) (0b10000000 | ((c >> 6 ) & 0b00111111));
            curout[2] = cast(char) (0b10000000 | ( c        & 0b00111111));
            curout = curout[3 .. $];
            curin  = curin [1 .. $];
        }
        else if (c <= 0x10FFFF)
        {
            // UTF-8: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
            if (curout.length < 4)
                break; // No room; stop converting.

            assert(0x10000 <= c && c <= 0x10FFFF);
            curout[0] = cast(char) (0b11110000 | ( c >> 18)              );
            curout[1] = cast(char) (0b10000000 | ((c >> 12) & 0b00111111));
            curout[2] = cast(char) (0b10000000 | ((c >>  6) & 0b00111111));
            curout[3] = cast(char) (0b10000000 | ( c        & 0b00111111));
            curout = curout[4 .. $];
            curin  = curin [1 .. $];
        }
        else
        {
            // Any code point larger than U+10FFFF is invalid.
            throw new UtfException("decoding UTF-32", c);
        }
    }

    inbuf = curin;
    return outbuf.length - curout.length;
}

/// ditto
size_t convert(ref immutable(dchar)[] inbuf, char[] outbuf) @safe
{
    const(dchar)[] inbuf_ = inbuf;
    const result = convert(inbuf_, outbuf);
    assert(inbuf.ptr <= inbuf_.ptr && inbuf_.ptr <= inbuf.ptr + inbuf.length);
    inbuf = cast(immutable) inbuf_;
    return result;
}

unittest
{
    dstring s = "\u0000\u007F\u0080\u07FF\u0800\uD7FF\uE000\uFFFD"
        ~"\U00010000\U0010FFFF";
    char[6] dstbuf;

    assert(s.convert(dstbuf) == 6);
    assert(s.length == 6);
    assert(dstbuf[0 .. 6] == "\u0000\u007F\u0080\u07FF");

    assert(s.convert(dstbuf) == 6);
    assert(s.length == 4);
    assert(dstbuf[0 .. 6] == "\u0800\uD7FF");

    assert(s.convert(dstbuf) == 6);
    assert(s.length == 2);
    assert(dstbuf[0 .. 6] == "\uE000\uFFFD");

    assert(s.convert(dstbuf) == 4);
    assert(s.length == 1);
    assert(dstbuf[0 .. 4] == "\U00010000");

    assert(s.convert(dstbuf) == 4);
    assert(s.length == 0);
    assert(dstbuf[0 .. 4] == "\U0010FFFF");
}


/**
 * Converts the UTF-16 string in $(D inbuf) to the corresponding UTF-32
 * string in $(D outbuf), upto $(D outbuf.length) UTF-32 code units.
 * Upon successful return, $(D inbuf) will be advanced to immediately
 * after the last converted UTF-16 sequence.
 *
 * Returns:
 *   The number of UTF-32 code units written to $(D outbuf).
 *
 * Throws:
 *   $(D UtfException) on encountering a malformed UTF-16 sequence in
 *   $(D inbuf).
 */
size_t convert(ref const(dchar)[] inbuf, wchar[] outbuf) @safe
{
    const(dchar)[] curin = inbuf;
    wchar[] curout = outbuf;

    while (curin.length != 0 && curout.length != 0)
    {
        dchar c = curin[0];

        if (c <= 0xFFFF)
        {
            if ((c & 0xF800) == 0xD800)
                throw new UtfException(
                    "surrogate code point in UTF-32", c);

            curout[0] = cast(wchar) c;
            curout = curout[1 .. $];
            curin  = curin [1 .. $];
        }
        else if (c <= 0x10FFFF)
        {
            // Needs surrogate pair.
            if (curout.length < 2)
                break; // No room; stop converting.

            assert(0x10000 <= c && c <= 0x10FFFF);
            curout[0] = cast(wchar) ((((c - 0x10000) >> 10) & 0x3FF) + 0xD800);
            curout[1] = cast(wchar) (( (c - 0x10000)        & 0x3FF) + 0xDC00);
            curout = curout[2 .. $];
            curin  = curin [1 .. $];
        }
        else
        {
            // Any code point larger than U+10FFFF is invalid.
            throw new UtfException("decoding UTF-32", c);
        }
    }

    inbuf = curin;
    return outbuf.length - curout.length;
}

/// ditto
size_t convert(ref immutable(dchar)[] inbuf, wchar[] outbuf) @safe
{
    const(dchar)[] inbuf_ = inbuf;
    const result = convert(inbuf_, outbuf);
    assert(inbuf.ptr <= inbuf_.ptr && inbuf_.ptr <= inbuf.ptr + inbuf.length);
    inbuf = cast(immutable) inbuf_;
    return result;
}

unittest
{
    dstring s = "\u0000\u007F\u0080\u07FF\u0800\uD7FF\uE000\uFFFD"
        ~"\U00010000\U0010FFFF";
    wchar[3] dstbuf;

    assert(s.convert(dstbuf) == 3);
    assert(s.length == 7);
    assert(dstbuf[0 .. 3] == "\u0000\u007F\u0080");

    assert(s.convert(dstbuf) == 3);
    assert(s.length == 4);
    assert(dstbuf[0 .. 3] == "\u07FF\u0800\uD7FF");

    assert(s.convert(dstbuf) == 2);
    assert(s.length == 2);
    assert(dstbuf[0 .. 2] == "\uE000\uFFFD");

    assert(s.convert(dstbuf) == 2);
    assert(s.length == 1);
    assert(dstbuf[0 .. 2] == "\U00010000");

    assert(s.convert(dstbuf) == 2);
    assert(s.length == 0);
    assert(dstbuf[0 .. 2] == "\U0010FFFF");
}

