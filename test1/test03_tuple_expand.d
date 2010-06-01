/*
Expand nested tuples.

--------------------
% dmd -run test03_tuple_expand
=== scatter ===
x = -3
y = 2
z = -2
=== flatten ===
Tuple!(real,real,real,real)(3, -3, 2, -2)
% _
--------------------
 */
import std.math;
import std.stdio;

void main()
{
    real x, y, z;

    auto tup = tuple(sqrts(9), sqrts(4));

    writeln("=== scatter ===");
    scatter(tup, ignore, x, y, z);
    writeln("x = ", x);
    writeln("y = ", y);
    writeln("z = ", z);

    writeln("=== flatten ===");
    writeln(flatten(tup));
}

Tuple!(real, real) sqrts(real n)
{
    return tuple(sqrt(n), -sqrt(n));
}


//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://
// Expand nested tuples
//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://

import std.typecons;
import std.typetuple;

// taken from the tie code
private template isTuple(T)
{
    enum isTuple = __traits(compiles, { void f(X...)(Tuple!X x) {}; f(T.init); });
}

private immutable struct Ignore
{
    void opAssign(T)(T e) {}
}
immutable Ignore ignore;


/*
 * Assigns flattened contents in the tuple tup to vars.
 */
void scatter(Tup, Vars...)(auto ref Tup tup, ref Vars vars)
    if (isTuple!(Tup))
in
{
    enum expectedLength = Flat!Tup.Types.length;

    static assert(Vars.length >= expectedLength,
            "scatter: too less variables; " ~ expectedLength.stringof ~
            " variables are expected, not " ~ Vars.length.stringof);
    static assert(Vars.length <= expectedLength,
            "scatter: too much variables; " ~ expectedLength.stringof ~
            " variables are expected, not " ~ Vars.length.stringof);
}
body
{
    /*
     * Generator generates code like this:
     *--------------------
     *     vars[0] = tup.expand[0];
     *     vars[1] = tup.expand[1].expand[0].expand[0];
     *     vars[2] = tup.expand[1].expand[1];
     *             :
     *     vars[6] = tup.expand[3];
     *--------------------
     */
    static struct Generator
    {
        string flatidx = "0";   // flattened index

        string walkThru(Types...)(string tup)
        {
            string code = "";

            foreach (i, T; Types)
            {
                immutable field = tup ~ ".expand[" ~ i.stringof ~"]";

                static if (isTuple!(T))
                {
                    // it's a nested tuple
                    code ~= walkThru!(T.Types)(field);
                }
                else
                {
                    code ~= "vars[" ~ flatidx ~"] = " ~ field ~ ";";
                    flatidx ~= "+1";
                }
            }
            return code;
        }
    }

    // implement scatter()
    enum code = {
            Generator gen;
            return gen.walkThru!(Tup.Types)("tup");
        }();
    mixin(code);

    debug (showGeneratedCode)
    {
        pragma(msg, "=== scatter(", Tup, ") ===");
        pragma(msg, code);
    }
}

unittest
{
    // 0-nested
    {
        int x, y, z;
        auto t = tuple(1, 2, 3);
        scatter(t, x, y, z);
        assert(x == 1);
        assert(y == 2);
        assert(z == 3);
    }
    // 1-nested
    {
        int x, y, z;
        auto t = tuple(1, tuple(2), 3);
        scatter(t, x, y, z);
        assert(x == 1);
        assert(y == 2);
        assert(z == 3);
    }
    // 2-nested
    {
        int v, w, x, y, z;
        auto t = tuple(1, tuple(2, tuple(3), 4), 5);
        scatter(t, v, w, x, y, z);
        assert(v == 1);
        assert(w == 2);
        assert(x == 3);
        assert(y == 4);
        assert(z == 5);
    }
    // ignore
    {
        int x;
        auto t = tuple(1, 2);
        scatter(t, ignore, x);
        assert(x == 2);
    }
}


/*
 * Returns a flattened tuple.
 */
Flat!(Tup) flatten(Tup)(auto ref Tup tup)
    if (isTuple!(Tup))
{
    Flat!Tup flat = void;

    scatter(tup, flat.field);
    return flat;
}

unittest
{
    // 0-nested
    {
        auto t = tuple(1, 2, 3);
        auto f = flatten(t);
        assert(f == t);
    }
    // 1-nested
    {
        auto t = tuple(1, tuple(2), 3);
        auto f = flatten(t);
        assert(f == tuple(1, 2, 3));
    }
    // 2-nested
    {
        auto t = tuple(1, tuple(2, tuple(3), 4), 5);
        auto f = flatten(t);
        assert(f == tuple(1, 2, 3, 4, 5));
    }
}


/*
 * Returns the flattened type of the tuple Tup.  Field names are dropped so
 * that name conflicts don't occur.
 */
template Flat(Tup)
    if (isTuple!(Tup))
{
    alias Tuple!(FlatImpl!(Tup.Types)) Flat;
}

private template FlatImpl(Types...)
{
    static if (Types.length > 0)
    {
        static if (isTuple!(Types[0]))
            alias TypeTuple!(
                    FlatImpl!(Types[0].Types),
                    FlatImpl!(Types[1 .. $]) )
                FlatImpl;
        else
            alias TypeTuple!(
                    Types[0],
                    FlatImpl!(Types[1 .. $]))
                FlatImpl;
    }
    else
    {
        alias TypeTuple!() FlatImpl;
    }
}

unittest
{
    // 0-nested
    {
        alias Tuple!(int) Tup;
        alias Flat!Tup Fla;
        static assert(is(Fla == Tup));
    }
    // 1-nested
    {
        alias Tuple!(int, Tuple!(short), byte) Tup;
        alias Flat!Tup Fla;
        static assert(is(Fla.Types == TypeTuple!(int, short, byte)));
    }
    // 2-nested
    {
        alias Tuple!(int, Tuple!(char, Tuple!(byte, wchar), dchar), short) Tup;
        alias Flat!Tup Fla;
        static assert(is(Fla.Types == TypeTuple!(int, char, byte, wchar, dchar, short)));
    }
    // 2-nested twice
    {
        alias Tuple!(Tuple!(Tuple!(byte, char)), Tuple!(Tuple!(wchar, short))) Tup;
        alias Flat!Tup Fla;
        static assert(is(Fla.Types == TypeTuple!(byte, char, wchar, short)));
    }
}

