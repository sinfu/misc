/*
Detect integer overflow on X86.

--------------------
% dmd -run test04_int_overflow
test04_int_overflow.OverflowException@test04_int_overflow.d(20): Integer overflow
--------------------
 */

import core.exception;


void main()
{
    uint n = 0xFFFFFFF0;
    uint i = 0x00000004;
    uint j = 0x00000010;

    n += i; mixin(checkIntegerOverflow);    // okay
    n += j; mixin(checkIntegerOverflow);    // throws OverflowException
}


//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://

enum string checkIntegerOverflow =
    "{ enum uint __overflowed_at = __LINE__;"
      "asm { jnc  $ + 10;"
            "mov  EAX, __overflowed_at;"
            "call __mod_onIntegerOverflow; } }";

void __mod_onIntegerOverflow(uint line)
{
    onIntegerOverflow(__FILE__, line);
}


//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://

extern(C) void onIntegerOverflow(string file, uint line)
{
    throw new OverflowException("Integer overflow", file, line);
}

class OverflowException : Exception
{
    this(string msg, string file, uint line)
    {
        super(msg, file, line);
    }
}

