/*
 * Propagate member-function calls over multiple objects with the same
 * arguments.
 */

import std.array;

void main()
{
    int[] a = [ 1, 2, 3, 4 ];
    int[] b = [ 5, 6, 7, 8 ];

    auto ra = a;
    auto rb = b;

    propagate.popFront.over(ra, rb);
    assert(ra.front == 2);
    assert(rb.front == 6);

    propagate.put(100).over(ra, rb);
    assert(ra.front == 3);
    assert(rb.front == 7);

    assert(a == [ 1, 100, 3, 4 ]);
    assert(b == [ 5, 100, 7, 8 ]);
}


//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://

struct propagate
{
    static auto opDispatch(string op, Args...)(Args args)
    {
        return Dispatcher!(op, Args)(args);
    }
}

private struct Dispatcher(string op, Args...)
{
    void over(Targets...)(auto ref Targets targets)
    {
        foreach (i, T; Targets)
            mixin("targets[i]." ~ op ~ "(args_);");
    }

private:
    Args args_;
}

