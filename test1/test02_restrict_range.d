/*
Restrict ranges to specific concepts.  Useful for testing.

--------------------
int[] a = [ 1, 2, 3 ];
auto r = hideLength(asInputRange(a));

// the random access feature is hidden
static assert(!isRandomAccessRange!(typeof(r)));

// the length property is hidden
static assert(!hasLength!(typeof(r)));

some_algorithm(r);
--------------------
 */

import std.array;
import std.range;


/**
 * Restrict the range r to an input range.
 */
auto asInputRange(R)(R r)
    if (isInputRange!(R))
{
    return restrict!(InputBehavior)(r);
}

unittest
{
    auto r = asInputRange([ 1, 2, 3 ]);

    alias typeof(r) R;
    static assert(isInputRange!(R));
    //static assert(! isForwardRange!(R));
    static assert(! isBidirectionalRange!(R));
    static assert(! isRandomAccessRange!(R));
    static assert(! isOutputRange!(R, int));
    static assert(hasLength!(R));
    static assert(! isInfinite!(R));

    assert(r.length == 3);
    assert(r.front == 1); r.popFront;
    assert(r.front == 2); r.popFront;
    assert(r.front == 3); r.popFront;
    assert(r.empty);
}


/**
 * Restrict the range r to a forward range.
 */
auto asForwardRange(R)(R r)
    if (isForwardRange!(R))
{
    return restrict!(InputBehavior, ForwardBehavior)(r);
}

unittest
{
    auto r = asForwardRange([ 1, 2, 3 ]);

    alias typeof(r) R;
    static assert(isInputRange!(R));
    static assert(isForwardRange!(R));
    static assert(! isBidirectionalRange!(R));
    static assert(! isRandomAccessRange!(R));
    static assert(! isOutputRange!(R, int));
    static assert(hasLength!(R));
    static assert(! isInfinite!(R));

    assert(r.length == 3);
    assert(r.front == 1); r.popFront;
    assert(r.front == 2); r.popFront;
    assert(r.front == 3); r.popFront;
    assert(r.empty);
}


/**
 * Restrict the range r to a bidirectional range.
 */
auto asBidirectionalRange(R)(R r)
    if (isBidirectionalRange!(R))
{
    return restrict!(InputBehavior, BidirectionalBehavior)(r);
}

unittest
{
    auto r = asBidirectionalRange([ 1, 2, 3 ]);

    alias typeof(r) R;
    static assert(isInputRange!(R));
    //static assert(! isForwardRange!(R));
    static assert(isBidirectionalRange!(R));
    static assert(! isRandomAccessRange!(R));
    static assert(! isOutputRange!(R, int));
    static assert(hasLength!(R));
    static assert(! isInfinite!(R));

    assert(r.back == 3); r.popBack;
    assert(r.back == 2); r.popBack;
    assert(r.back == 1); r.popBack;
    assert(r.empty);
}


/**
 * Restrict the range r to a random access range.
 */
auto asRandomAccessRange(R)(R r)
    if (isRandomAccessRange!(R))
{
    static if (isInfinite!(R))
        return restrict!(InputBehavior, RandomAccessBehavior)(r);
    else
        return restrict!(InputBehavior, BidirectionalBehavior, RandomAccessBehavior)(r);
}

unittest
{
    auto r = asRandomAccessRange([ 1, 2, 3 ]);

    alias typeof(r) R;
    static assert(isInputRange!(R));
    //static assert(! isForwardRange!(R));
    static assert(isBidirectionalRange!(R));
    static assert(isRandomAccessRange!(R));
    static assert(! isOutputRange!(R, int));
    static assert(hasLength!(R));
    static assert(! isInfinite!(R));

    r.popFront;
    assert(r[0] == 2);
    assert(r[1] == 3);
}


/**
 * Restrict the range r to an output range whose element type is E.
 */
auto asOutputRange(E, R)(R r)
    if (isOutputRange!(R, E))
{
    return restrict!(OutputBehavior!(E).behavior)(r);
}

unittest
{
    auto a = new int[3];
    auto r = asOutputRange!int(a);

    alias typeof(r) R;
    static assert(! isInputRange!(R));
    static assert(! isForwardRange!(R));
    static assert(! isBidirectionalRange!(R));
    static assert(! isRandomAccessRange!(R));
    static assert(isOutputRange!(R, int));

    r.put(1);
    r.put(2);
    r.put(3);
    assert(a == [ 1, 2, 3]);
}


/**
 * Hide .length property of the range r.
 */
auto hideLength(R)(R r)
{
    static if (hasLength!(R))
        return WithoutLength!(R)(r);
    else
        return r;
}

unittest
{
    auto r = hideLength([ 1, 2, 3 ]);
    auto rr = hideLength(r);

    alias typeof(r) R;
    static assert(!hasLength!(R));
    static assert(isInputRange!(R));
    static assert(isBidirectionalRange!(R));
    static assert(isRandomAccessRange!(R));

    assert(r.front == 1);
    assert(r[1] == 2);
    assert(r.back == 3);
}

struct WithoutLength(R)
{
    alias forward_ this;
    R forward_;

private:
    size_t length() @property { return 0; }
}


//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://

/*
 * Eliminate specific behaviors from the range R.
 */
struct Restrict(R, behaviors...)
{
    mixin mixinBehaviors!(R, behaviors);

    this(T : R)(T r)
    {
        forward_ = r;
    }

    static if (!__traits(compiles, isForward__))
    {
        // digitalmars.D [110612]
        this(S : typeof(this))(ref S src)
        {
            static assert(0);
        }
        void opAssign(T : typeof(this))(T rhs)
        {
            static assert(0);
        }
    }

private:
    R forward_;

    template mixinBehaviors(R, behaviors...)
    {
        static if (behaviors.length > 0)
        {
            mixin mixinBehaviors!(R, behaviors[1 .. $]);
            alias behaviors[0] behavior;
            mixin behavior!(R);
        }
    }
}

template restrict(behaviors...)
{
    auto restrict(R)(R r)
    {
        return Restrict!(R, behaviors)(r);
    }
}


// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - //
// Behaviors
// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - //

/*
 * InputRange:
 *   - R.empty
 *   - R.popFront
 *   - R.front
 *   - R.length (optional)
 */
template InputBehavior(R)
{
    static if (isInfinite!(R))
    {
        enum bool empty = false;
    }
    else
    {
        bool empty() @property
        {
            return forward_.empty;
        }
    }

    static if (hasLength!(R))
    {
        size_t length() @property
        {
            return forward_.length;
        }
    }

    void popFront()
    {
        forward_.popFront;
    }

    auto ref ElementType!(R) front() @property
    {
        return forward_.front;
    }
}

/*
 * ForwardRange:
 *   - R.this(ref R)
 *   - R.opAssign(R)
 */
template ForwardBehavior(R)
{
    enum bool isForward__ = true;
}

/*
 * BidirectionalRange:
 *   - R.popBack
 *   - R.back
 */
template BidirectionalBehavior(R)
{
    void popBack()
    {
        forward_.popBack;
    }

    auto ref ElementType!(R) back() @property
    {
        return forward_.back;
    }
}

/*
 * RandomAccessRange:
 *   - R.opIndex(size_t)
 */
template RandomAccessBehavior(R)
{
    auto ref ElementType!(R) opIndex(size_t i)
    {
        return forward_[i];
    }
}

/*
 * OutputRange:
 *   - R.put(E e)
 */
template OutputBehavior(E)
{
    alias E ElementType;

    template behavior(R, ElementType = E)
    {
        void put(ElementType e)
        {
            forward_.put(e);
        }
    }
}


