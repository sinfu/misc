/*
 * Range iteration with side-effect.
 */

import std.algorithm;
import std.array;
import std.range;

import std.stdio;


void main()
{
    dchar[] a = [ 'a', 'b', 'c', 'd' ];
    size_t i;

    foreach (e; comma(PaceMaker(0.5), hookFront({ write(i++, " = "); }), a))
        writeln(e);
}


//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://

/*
 * much like the comma expression.
 */
Comma!(RR) comma(RR...)(RR rr)
{
    return Comma!(RR)(rr);
}

struct Comma(RR...)
{
    bool empty() @property
    {
        foreach (r; sources_)
            if (r.empty)
                return true;
        return false;
    }

    void popFront()
    {
        propagate.popFront.over(sources_);
    }

    auto ref ElementType!(RLast) front()
    {
        foreach (r; sources_[0 .. $ - 1])
            r.front;
        return sources_[$ - 1].front;
    }

private:
    RR sources_;
    alias RR[RR.length - 1] RLast;
}


//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://

struct hookPop
{
    enum bool empty = false;

    void popFront()
    {
        effect_();
    }

    int front()
    {
        return 0;
    }

private:
    void delegate() effect_;
}

struct hookFront
{
    enum bool empty = false;

    void popFront()
    {
    }

    int front()
    {
        effect_();
        return 0;
    }

private:
    void delegate() effect_;
}


//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://

struct PaceMaker
{
    this(real interval)
    {
        version (Posix) interval_ = 1_000_000;
        version (Win32) interval_ = 1_000;
        interval_ *= interval;
    }

    enum bool empty = false;

    void popFront()
    {
        version (Posix)
            usleep(interval_);
        version (Win32)
            Sleep(interval_);
    }

    void front()
    {
    }

private:
    version (Posix)
    {
        import core.sys.posix.unistd : useconds_t, usleep;
        useconds_t interval_;
    }
    version (Win32)
    {
        import core.sys.windows.windows : Sleep;
        uint interval_;
    }
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

