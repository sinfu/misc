/*
Convert delegates to C function pointers.

--------------------
% dmd -run test05_delegate_to_cfunc
^Cexiting...
--------------------
 */

import std.stdio;

import core.stdc.signal;
import core.thread;


void main()
{
    bool term;

    auto trap =
        (int sig)
        {
            assert(sig == SIGINT);
            term = true;
        };
    signal(SIGINT, translateToC(trap));

    while (!term)
        Thread.yield();
    writeln("exiting...");
}



//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://

template CFuncPtr(R, P...)
{
    extern(C) alias R function(P) CFuncPtr;
}

version (X86)
{
    auto translateToC(R, P...)(R delegate(P) dg)
    {
        ubyte[] code = TEMPLATE_CODE_C.dup;

        *cast(uint*) &code[ 3] = -stackSize!(P);
        *cast(uint*) &code[24] = cast(uint) dg.ptr;
        *cast(uint*) &code[32] = cast(uint) dg.funcptr;

        return cast(CFuncPtr!(R, P)) code.ptr;
    }

    template stackSize(PP...)
    {
        static if (PP.length > 0)
            enum size_t stackSize =
                alignSize(PP[0].sizeof) + stackSize!(PP[1 .. $]);
        else
            enum size_t stackSize = 0;
    }

    size_t alignSize(size_t n) pure nothrow @safe
    {
        return (n + 3) & ~3;
    }

    private static immutable ubyte[] TEMPLATE_CODE_C =
    [
        // Fix#1 @ 3 = -stackSize!(P)   <- NOTE the sign!
        // Fix#2 @24 = dg.ptr
        // Fix#3 @32 = dg.funcptr

        0x56,                       // push ESI
        0x57,                       // push EDI

        /* copy arguments */
        0xB9, 0,0,0,0,              // mov  ECX, Fix#1
        0x8D, 0x74, 0x24, 12,       // lea  ESI, [ESP +  12]
        0x8D, 0x3C, 0x0C,           // lea  EDI, [ESP + ECX]
        0x03, 0xE1,                 // add  ESP, ECX
        0xF7, 0xD9,                 // neg  ECX
        0xF3, 0xA4,                 // rep  movsb

        /* invoke delegate */
        0x90, 0x90, 0x90,           // nop
        0xB8, 0,0,0,0,              // mov  EAX, Fix#2
        0x90, 0x90, 0x90,           // nop
        0xB9, 0,0,0,0,              // mov  ECX, Fix#3
        0xFF, 0xD1,                 // call ECX

        0x5F,                       // pop  EDI
        0x5E,                       // pop  ESI
        0xC3                        // ret
    ];
}


