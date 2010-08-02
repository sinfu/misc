/*
 * - http://www.sampou.org/haskell/article/whyfp.html
 */

import std.algorithm;
import std.array;
import std.conv;
import std.exception;
import std.functional;
import std.math;
import std.range;
import std.stdio;

void main()
{
    auto r  = differentiator!sin(0, 0.01);
    auto rr = geometricErrorReducer(r, .5);
    auto z  = cos(0);

    writeln("--------------------");
    popFrontN(r, 8);
    writeln(r.front, "\t", feqrel(r.front, z));

    writeln("--------------------");
    popFrontN(rr, 4);
    writeln(rr.front, "\t", feqrel(rr.front, z));
}


//----------------------------------------------------------------------------//
// Sequential differentiation
//----------------------------------------------------------------------------//

auto differentiator(alias fun)(real x, real h0 = 0.1)
{
    auto hseq = geometricSequence!real(h0, 0.5);
    alias binaryRevertArgs!(naivediff!fun) diffAt;
    return parametricMap!diffAt(hseq, x);
}

template naivediff(alias fun)
{
    auto naivediff(T)(T x, T h)
    {
        return (fun(x + h) - fun(x)) / h;
    }
}

unittest
{
    assert(naivediff!sin(0, 1) < naivediff!sin(0.0, 0.5));
}


//----------------------------------------------------------------------------//
// Error reducer
//----------------------------------------------------------------------------//

/**
 *
 */
auto geometricErrorReducer(Range)(Range seq, real ratio)
        if (isForwardRange!Range && isInfinite!Range)
{
    return GeometricErrorReducer!Range(seq, ratio);
}

@safe struct GeometricErrorReducer(Range)
{
    static assert(isForwardRange!Range);
    static assert(isInfinite!Range);

    //----------------------------------------------------------------//
  private:
    ElementType!Range head_;
    real              eratio_;
    Range             sequence_;

    this(Range sequence, real ratio)
    {
        alias estimateGeometricErrorOrder errorOrder;

        sequence_ = sequence;
        eratio_   = ratio ^^ errorOrder(sequence, ratio);
        popFront();
    }

    //----------------------------------------------------------------//
  public:
    enum bool empty = false;

    @property ref ElementType!Range front() nothrow
    {
        return head_;
    }

    void popFront()
    {
        /*
         * Proof.  By assumption, the first two elements of sequence_ are
         *
         *                a = X + W   h ^^n ,
         *                b = X + W (rh)^^n .
         *
         * Solving the equation in terms of X gives
         *
         *                      a r^^n - b
         *                 X = ------------ .
         *                       r^^n - 1
         */
        auto a = sequence_.front; sequence_.popFront();
        auto b = sequence_.front; sequence_.popFront();

        head_ = (a*eratio_ - b) / (eratio_ - 1);
    }

    @property typeof(this) save()
    {
        auto copy = this;
        copy.sequence_ = sequence_.save;
        return copy;
    }
}


/**
 * Params:
 *  seq = Forward range that converges to a certain value alongside with a
 *        geometric error term.  $(D seq) must have at least three elements.
 *  r   = Common ratio of the error factor.
 */
real estimateGeometricErrorOrder(Range)(Range seq, real r)
{
    static assert(isForwardRange!Range);
    static assert(is(ElementType!Range : real));
    enforce(abs(r) < 1, "Sequence would not converge due to |r| >= 1.");

    /*
     * Proof.  By assumption, the first three elements of seq are
     *
     *                  a = X + W (k^2 h)^n ,
     *                  b = X + W (k   h)^n ,
     *                  c = X + W      h ^n ;
     *
     * where X is a convergence value; W and h are error constants; k is the
     * inverse common ratio of the error term (i.e. k = 1/r).
     *
     * Subtracting c from a and b, respectively, we obtain
     *
     *               a - c = W (k^(2n) - 1) h^n ,
     *               b - c = W (k^  n  - 1) h^n .
     *
     * Dividing the former by the latter gives
     *
     *             a - c     k^(2n) - 1
     *            ------- = ------------ = k^n + 1 .
     *             b - c       k^n - 1
     *
     * Now we can see that the order of the error term n is given by
     *
     *                        |  a - c      |
     *               n = log  | ------- - 1 | . //
     *                      k |  b - c      |
     */
    immutable a = seq.front; seq.popFront();
    immutable b = seq.front; seq.popFront();
    immutable c = seq.front;
    immutable g = (a - c) / (b - c) - 1;
    immutable n = log(g) / -log(r);

    return n;
}

unittest
{
    immutable real x = 3.1416,
                   w = 0.9,
                   h = 1.0,
                   r = 0.95,
                   n = 5.5;
    //
    real[] seq = [ x + w *        h ^^n,
                   x + w * (    r*h)^^n,
                   x + w * (  r*r*h)^^n,
                   x + w * (r*r*r*h)^^n ];
    immutable en1 = estimateGeometricErrorOrder(seq[0 .. 3], r);
    immutable en2 = estimateGeometricErrorOrder(seq[1 .. 4], r);
    assert(approxEqual(en1, n));
    assert(approxEqual(en2, n));
}


//----------------------------------------------------------------------------//
// Basic recursive sequence generators
//----------------------------------------------------------------------------//
// arithmeticSequence
// geometricSequence
//----------------------------------------------------------------------------//

/**
 * Returns an infinite arithmetic sequence with the first term $(D a) and the
 * common difference $(D d).
 */
auto arithmeticSequence(T)(T a, T d)
{
    return parametric1stRecurrence!"x + a"(a, d);
}

unittest
{
    auto seq = arithmeticSequence!real(0, 2);

    static assert(!seq.empty);
    assert(seq.front == 0); seq.popFront();
    assert(seq.front == 2); seq.popFront();
    assert(seq.front == 4); seq.popFront();
    assert(seq.front == 6); seq.popFront();
}

unittest
{
    auto seq = arithmeticSequence!real(8, -3);

    static assert(!seq.empty);
    assert(seq.front ==  8); seq.popFront();
    assert(seq.front ==  5); seq.popFront();
    assert(seq.front ==  2); seq.popFront();
    assert(seq.front == -1); seq.popFront();
}


/**
 * Returns an infinite geometric sequence with the first term $(D a) and the
 * common ratio $(D r).
 */
auto geometricSequence(T)(T a, T r)
{
    return parametric1stRecurrence!"x * a"(a, r);
}

unittest
{
    auto seq = geometricSequence!real(1, 0.5);

    static assert(!seq.empty);
    assert(seq.front == 1.0  ); seq.popFront();
    assert(seq.front == 0.5  ); seq.popFront();
    assert(seq.front == 0.25 ); seq.popFront();
    assert(seq.front == 0.125); seq.popFront();
}

unittest
{
    auto seq = geometricSequence!real(1, 2);

    static assert(!seq.empty);
    assert(seq.front == 1); seq.popFront();
    assert(seq.front == 2); seq.popFront();
    assert(seq.front == 4); seq.popFront();
    assert(seq.front == 8); seq.popFront();
}


//----------------------------------------------------------------------------//
// Generic recursive sequence generator
//----------------------------------------------------------------------------//

// [workaround] std.range recurrence can't take local expression.

/**
 * Returns an infinite recursive sequence of the 1st order with the first term
 * $(D start) and the recurrence equation $(D update).
 *
 * Params:
 *  update     = The recurrence equation.  The expression shall use the symbol
 *               name $(D x) as the last value.
 *  start      = The first term.
 *  parameters = Optional _parameters passed to the recurrence $(D update).
 *               The _parameters are passed to the recurrence with the symbol
 *               names $(D a), $(D b), ... etc.
 *
 * Example:
--------------------
// Linear recursive sequence with the first term 1 and
// the recurrence equation 2*x + 5.
auto seq = parametric1stRecurrence!"a*x + b"(1, 2, 5);

writeln(take(seq, 4));  // displays "1 7 19 43"
--------------------
 */
template parametric1stRecurrence(alias update)
{
    @safe auto parametric1stRecurrence(T, PP...)(T start, PP parameters) nothrow
    {
        alias parametricUnaryFun!update updateFun;
        return Parametric1stRecurrence!(updateFun, T, PP)(start, parameters);
    }
}

@safe struct Parametric1stRecurrence(alias update, T, PP...)
{
  private:
    T  head_;
    PP parameters_;

  public:
    enum bool empty = false;

    @property ref T front() nothrow
    {
        return head_;
    }

    void popFront()
    {
        head_ = update(head_, parameters_);
    }

    @property typeof(this) save() nothrow
    {
        return this;
    }
}

unittest
{
    auto seq = parametric1stRecurrence!"a*x + b"(1, 2, 5);
    auto sv1 = seq.save;

    static assert(!seq.empty);
    static assert(!sv1.empty);

    // normal iteration
    assert(seq.front ==  1); seq.popFront();
    assert(seq.front ==  7); seq.popFront();
    assert(seq.front == 19); seq.popFront();
    assert(seq.front == 43); seq.popFront();
    assert(seq.front == 91);

    // check the first copy for forward-ness
    assert(sv1.front ==  1); sv1.popFront();
    assert(sv1.front ==  7); sv1.popFront();
    assert(sv1.front == 19);

    // check the second copy for forward-ness
    auto sv2 = sv1.save;

    assert(sv2.front == 19); sv2.popFront();
    assert(sv2.front == 43);

    // check all the copies for forward-ness
    assert(seq.front == 91);
    assert(sv1.front == 19);
    assert(sv2.front == 43);
}


//----------------------------------------------------------------------------//
// Map
//----------------------------------------------------------------------------//

// [workaround] std.algorithm map() can't take local expression.

template parametricMap(alias mapper)
{
    auto parametricMap(Range, PP...)(Range r, PP parameters)
    {
        alias parametricUnaryFun!mapper mapperFun;
        return ParametricMap!(mapperFun, Range, PP)(r, parameters);
    }
}

struct ParametricMap(alias mapper, Range, PP...)
{
  private:
    Range range_;
    PP    parameters_;

  public:

    static if (isInfinite!Range)
    {
        enum bool empty = false;
    }
    else
    {
        @property bool empty()
        {
            return range_.empty;
        }
    }

    @property auto ref front()
    {
        return mapper(range_.front, parameters_);
    }

    void popFront()
    {
        range_.popFront();
    }

    @property typeof(this) save()
    {
        auto copy = this;
        copy.range_ = range_.save;
        return copy;
    }
}


//----------------------------------------------------------------------------//
// Functional
//----------------------------------------------------------------------------//

/**
 * Generates a unary function with several parameters.
 *
 * The expression $(D expr) must use the symbol name $(D x) for the function
 * parameter and the symbol names $(D a), $(D b), ... for the parameters.
 */
template parametricUnaryFun(string expr)
{
    T parametricUnaryFun(T, PP...)(T x, PP p)
    {
        static immutable char[8] nth = "abcdefgh";
      /+
        @@@BUG@@@ static foreach creates scope
        foreach (i, P; PP)
            mixin ("alias p[i] "~ nth[i] ~";");
      +/
        mixin (function
               {
                   string stmt = "";
                   foreach (i, P; PP)
                       stmt ~= "alias p["~ i.stringof ~"] "~ nth[i] ~";";
                   return stmt;
               }());
        return mixin(expr);
    }
}

/// ditto
template parametricUnaryFun(alias fun)
{
    alias fun parametricUnaryFun;
}

unittest
{
    alias parametricUnaryFun!"x * p[0] - p[1]" fun;

    assert(fun(1, 2, 3) == 1 * 2 - 3);
    assert(fun(2, 3, 4) == 2 * 3 - 4);
    assert(fun(5, 4, 3) == 5 * 4 - 3);
    assert(fun(6, 4, 2) == 6 * 4 - 2);
}

unittest
{
    alias parametricUnaryFun!"x + (a * b - c)" fun;

    assert(fun(1, 2, 3, 4) == 1 + (2 * 3 - 4));
    assert(fun(2, 3, 4, 5) == 2 + (3 * 4 - 5));
    assert(fun(6, 5, 4, 3) == 6 + (5 * 4 - 3));
    assert(fun(7, 5, 3, 1) == 7 + (5 * 3 - 1));
}

unittest
{
    alias parametricUnaryFun!( (x, a, b) { return (x - a) * b; } ) fun;

    assert(fun(1., 2, 3) == (1. - 2) * 3);
    assert(fun(3., 4, 5) == (3. - 4) * 5);
}

