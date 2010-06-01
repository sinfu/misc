/*
Forwarding D-style variadic arguments

--------------------
% dmd -run test01_fwd_varargs
arguments = 31 42 : 1 2 3
result = 9 8 7 6
% _
--------------------
 */

import std.stdio;

void main()
{
    test(1, 2, 3);
}

void test(...)
{
    auto s = forward!sub(31, 42, _arguments, _argptr);
    writeln("result = ", s);
}

int[4] sub(int a, lazy int b, ...)
{
    const args = cast(int*) _argptr;
    writeln("arguments = ", a, " ", b, " : ", args[0 .. _arguments.length]);
    return [9,8,7,6];
}


//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://

import std.traits;


/**
 * Forwards variadic arguments to func.
 */
template forward(alias func)
{
    alias MachineForward!(func, false).invoke forward;
}


//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://
// Utilities
//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://

/*
 * Returns true if the (type of a) callable object F is a ref function.
 */
template isRefFunction(F...)
    if (isCallable!(F))
{
    enum bool isRefFunction =
        (functionAttributes!(F) & FunctionAttribute.REF) != 0;
}

/*
 * Allocates smaller array on the stack rather than heap.  The allocated
 * memory must not be escaped out of the scope where a Stock object is.
 *
 * Example:
--------------------
Stock!(ubyte, 128) stock = void;

scope ubyte[] buf = stock.takeOut();
...
--------------------
 */
private struct Stock(T, size_t stockSize)
{
    T[stockSize] stock;

    T[] takeOut(size_t n) // potentially unsafe
    {
        return (n <= stock.length) ? stock[0 .. n] : new T[n];
    }
}


//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://
// Forwarding variadic arguments (X86)
//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://

version (X86) private
{
    static assert((void*).sizeof == uint.sizeof);

    /*
     * Determines whether a return value of the type R should be returned in
     * a (pair of) register or in a hidden argument.
     *
     * Returns:
     *   true if a hidden argument should be used, or false otherwise.
     */
    template useHiddenReturn(R)
    {
        static if (is(R == struct) || is(R == union))
        {
            version (Windows)
                enum bool useHiddenReturn =
                    (R.sizeof > 8 || (R.sizeof & (R.sizeof - 1)));
            else
                enum bool useHiddenReturn = true;
        }
        else static if (isStaticArray!(R))
            enum bool useHiddenReturn =
                (R.sizeof > 8 || (R.sizeof & (R.sizeof - 1)));
        else
            enum bool useHiddenReturn = false;
    }

    /*
     * Constructs stack on-the-fly.
     */
    private struct ArchStackWriter
    {
        enum size_t ALIGN = 4;

        ubyte*       sp;    // virtual stack pointer
        const ubyte* guard; // for the overflow-check purpose

        this(ubyte[] stack) nothrow @trusted
        {
            this.sp    = stack.ptr + (stack.length & ~(ALIGN - 1));
            this.guard = stack.ptr;
        }

        /*
         * Pushes bulk data onto the stack.  The data must not be empty.
         *--------------------
         *     mov ecx, data.length
         *     sub esp, ecx
         *     mov esi, data.ptr
         *     mov edi, esp
         *     rep movsb
         *--------------------
         */
        void push(in ubyte[] data) nothrow @trusted
        in
        {
            assert(data.length > 0);
            assert(sp >= guard);
            assert(alignSize(data.length) <= (sp - guard));
        }
        body
        {
            sp -= alignSize(data.length);
            sp[0 .. data.length] = data[];
        }

        /*
         * Pushes a dword onto the stack.
         *--------------------
         *     push dw
         *--------------------
         */
        void push(uint dw) nothrow @trusted
        {
            push((cast(ubyte*) &dw)[0 .. uint.sizeof]);
        }

        static size_t alignSize(size_t size) pure nothrow @safe
        {
            return (size + (ALIGN - 1)) & ~(ALIGN - 1);
        }
    }

    alias ArchStackWriter.alignSize alignStackSize;

    /*
     * X86-specific forward!func implementation.
     */
    template MachineForward(alias func, bool useContext)
    {
        alias ParameterStorageClass PSTC;

        alias                 ReturnType!(func) FormalRT;
        alias         ParameterTypeTuple!(func) FixedArgs;
        alias ParameterStorageClassTuple!(func) fixedArgsSTC;

        enum byRef     = isRefFunction!(func);
        enum useHidden = !byRef && useHiddenReturn!(FormalRT);

        static if (byRef || useHidden)
            alias FormalRT* RealRT;
        else
            alias FormalRT  RealRT;

        enum string declareFixedParams = FixedArgs.stringof[1 .. $ - 1];
            // hack
        static assert(__traits(compiles,
                {
                    mixin("void foo(" ~ declareFixedParams ~ ") {}");
                }));

        //:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://

        /+
        (auto ref) FormalRT invoke(
                (auto ref/out/lazy) FixedArgs fixedArgs,
                TypeInfo[] arguments, void* argptr, void* ctxptr = null )
        +/
        extern(C) mixin(
        (byRef ? "ref " : "") ~ "FormalRT invoke(" ~
            declareFixedParams ~ ", " ~
            "TypeInfo[] arguments, void* argptr, void* ctxptr = null )" ~ q{
        {
            Stock!(ubyte, 128) stockStack = void;

            static if (useHidden) FormalRT hidden = void;

            /* calculate the call stack size */
            size_t fixedSize, variadicSize, extraSize;
            {
                foreach (i, T; FixedArgs)
                {
                    if (fixedArgsSTC[i] & (PSTC.OUT | PSTC.REF))
                        fixedSize += (void*).sizeof;
                    else if (fixedArgsSTC[i] & PSTC.LAZY)
                        fixedSize += (void delegate()).sizeof;
                    else
                        fixedSize += alignStackSize(T.sizeof);
                }
                foreach (arg; arguments)
                    variadicSize += alignStackSize(arg.tsize);

                extraSize = TypeInfo_Tuple.sizeof;
                static if (useHidden ) extraSize += (void*).sizeof;
                static if (useContext) extraSize += (void*).sizeof;
            }
            immutable stackSize = fixedSize + variadicSize + extraSize;

            /* set up the call stack */
            scope stack = stockStack.takeOut(stackSize);
            scope types = new TypeInfo_Tuple();
            {
                auto writer = ArchStackWriter(stack);

                // an, ..., a1, a0
                writer.push((cast(ubyte*) argptr)[0 .. variadicSize]);

                // copy fixed arguments from the call stack of this
                // function (i.e. invoke).  invoke() is declared with
                // extern(C), so the fixed arguments are pushed after the
                // 'arguments' parameter.
                auto pfixed = cast(ubyte*) &arguments - fixedSize;
                writer.push(pfixed[0 .. fixedSize]);

                // _arguments
                types.elements = arguments;
                writer.push(cast(uint) cast(void*) types);

                static if (useHidden ) writer.push(cast(uint) &hidden);
                static if (useContext) writer.push(cast(uint)  ctxptr);
            }

            static if (useHidden)
                return  invokeFunction!(RealRT, func)(stack, stack.length, 0), hidden;
            else static if (byRef)
                return *invokeFunction!(RealRT, func)(stack, stack.length, 0);
            else
                return  invokeFunction!(RealRT, func)(stack, stack.length, 0);
        }
        }); // mixin
    }
}

version (D_InlineAsm_X86) private
{
extern(D):

    /*
     * Invokes func() with pre-constructed call stack and EAX.
     *
     * This function itself is unaware of any calling conventions.  The
     * caller manages the calling convention by setting up relevant
     * parameters.
     *
     * Params:
     *   func   = (pointer to) the invoked function
     *   cstack = call stack for the invoked function, top to bottom.
     *   nclean = number of bytes to be popped from the stack after
     *            returned from the invoked function.
     *   eax    = argument passed to the invoked function via EAX.
     *
     * Returns:
     *   The invoked function's (raw) return value.
     *
     * Assumption:
     *   This function assumes that EBX is preserved across function calls.
     */
    RawRT invokeFunction(RawRT, alias func)(
            ubyte[] cstack, size_t nclean, uint eax )
    {
        asm
        {
            naked;
            push    EBP;
            mov     EBP, ESP;
            push    ESI;
            push    EDI;
            push    EBX;

            mov     ESI, 16[EBP];   // = cstack.ptr
            mov     ECX, 12[EBP];   // = cstack.length
            mov     EBX,  8[EBP];   // = nclean

            sub     ESP, ECX;       // set up the call stack
            mov     EDI, ESP;
            rep;
            movsb;
            call    func;           // invoke func()
            add     ESP, EBX;       // clean up the stack

            pop     EBX;
            pop     EDI;
            pop     ESI;
            pop     EBP;
            ret     12;             // ubyte[] + size_t
        }
    }

    // ditto
    RawRT invokeFunction(RawRT)( void* func,
            ubyte[] cstack, size_t nclean, uint eax ) @trusted
    {
        asm
        {
            naked;
            push    EBP;
            mov     EBP, ESP;
            push    ESI;
            push    EDI;
            push    EBX;

            mov     EDX, 20[EBP];   // = func
            mov     ESI, 16[EBP];   // = cstack.ptr
            mov     ECX, 12[EBP];   // = cstack.length
            mov     EBX,  8[EBP];   // = nclean

            sub     ESP, ECX;       // set up the call stack
            mov     EDI, ESP;
            rep;
            movsb;
            call    EDX;            // invoke funcptr()
            add     ESP, EBX;       // clean up the stack

            pop     EBX;
            pop     EDI;
            pop     ESI;
            pop     EBP;
            ret     16;             // void* + ubyte[] + size_t
        }
    }

    unittest
    {
        extern(D) static int test(int a, int b)
        {
            return a * b;
        }
        immutable a = 31;
        immutable b = 97;

        auto stack = new ubyte[4];
        *(cast(int*) stack.ptr) = a;
        immutable r = invokeFunction!(int, test)(stack, 0, b);
        assert(r == test(a, b));
    }
}


