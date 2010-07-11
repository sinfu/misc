/**
 * Macros:
 *   D = $(I $1)
 *   BUGZILLA = $(RED $1)
 */
module variant_algebraic;

void main()
{
}


import std.algorithm;
import std.array;
import std.conv;
import std.traits;
import std.typetuple;
import std.variant : maxSize, Variant, VariantException;

version (unittest) import std.range;


/*
$(D phony!T) is a dummy lvalue of type $(D T).
 */
private template phony(T)
{
    static extern T phony;
}

unittest
{
    real foo(ref string s) { return 0; }
    assert(is(typeof(++phony!int) == int));
    assert(is(typeof(foo(phony!string)) == real));
}


/*
$(D phonyList!(TT...)) is a tuple of dummy lvalues of types $(D TT).
 */
private template phonyList(TT...)
{
    static if (TT.length > 0)
        alias TypeTuple!(phony!(TT[0]), phonyList!(TT[1 .. $]))
                            phonyList;
    else
        alias TypeTuple!()  phonyList;
}

unittest
{
    int foo(Args...)(ref Args args) { return 0; }
    assert(is(typeof(foo(phonyList!(int, dchar))) == int));
}


/*
Returns:
 - $(D x) by value if $(D R == T).
 - An $(D R) constructed with $(D x).
 - Nothing if $(D R == void).
 */
private
{
    @safe nothrow R byValue(R, T)(auto ref T x)
            if (is(R == T))
    {
        return x;
    }

    @system R byValue(R, T)(auto ref T x)
            if (!is(R == T))
    {
        R r = x;
        return r;
    }

    @safe nothrow void byValue(R, T)(auto ref T x)
            if (is(R == void))
    {
    }

    @safe R byValue(R, T = void)()
    {
        static if (!is(R == void))
            return R.init;
    }
}


/*
Compile fails if $(D var) is an rvalue.
 */
private @safe void expectLvalue(T)(ref T var) shared nothrow;

unittest
{
    int x;
    assert(__traits(compiles, expectLvalue(x)));
    assert(!__traits(compiles, expectLvalue(42)));
}


/*
Initializes a variable $(D obj) with its default initializer without
invoking copy constructor nor destructor.
 */
private @trusted void init(T)(ref T obj) nothrow
{
    static if (is(T == struct))
    {
        auto buf  = (cast(void*) &obj   )[0 .. T.sizeof];
        auto init = (cast(void*) &T.init)[0 .. T.sizeof];
        buf[] = init[];
    }
    else
    {
        obj = T.init;
    }
}

unittest
{
    struct S
    {
        int n;
        this(this) { assert(0); }
    }
    S s;
    s.n = 42;
    assert(s != s.init);
    init(s);
    assert(s == s.init);
}


/*
Workaround for the issue 4444.
 */
private @trusted string expandArray(string array, size_t n)
{
    string expr = "";

    foreach (i; 0 .. n)
    {
        if (i > 0)
            expr ~= ", ";
        expr ~= array ~ "[" ~ to!string(i) ~ "]";
    }
    return expr;
}

unittest
{
    enum s = expandArray("arr", 3);
    assert(s == "arr[0], arr[1], arr[2]");
}


//----------------------------------------------------------------------------//

// Hook for non-canonicalized instantiation arguments.
template Algebraic(Types...)
        if (!isAlgebraicCanonicalized!Types)
{
    alias Algebraic!(AlgebraicCanonicalize!Types) Algebraic;
}

private template AlgebraicCanonicalize(Types...)
{
    alias NoDuplicates!Types AlgebraicCanonicalize;
}

private template isAlgebraicCanonicalized(Types...)
{
    enum bool isAlgebraicCanonicalized =
        is(Types == AlgebraicCanonicalize!Types);
}


/**
Algebraic data type restricted to a closed set of possible types.
$(D Algebraic) is useful when it is desirable to restrict what a
discriminated type could hold to the end of defining simpler and
more efficient manipulation.

$(D Algebraic) allows compile-time checking that all possible
types are handled by user code, eliminating a large class of
errors.
--------------------
Algebraic!(int, double) x;

// these lines won't compile since long and string are not allowed
auto n = x.Algebraic.instance!long;
x = "abc";
--------------------

Bugs:

$(UL
 $(LI Currently, $(D Algebraic) does not allow recursive data types.
     They will be allowed in a future iteration of the implementation.)
 $(LI $(D opCall) overloads are hidden due to $(BUGZILLA 4243).
 $(LI $(D opApply) overloads are hidden because it conflicts with
     the $(D range) primitives.)
)

Examples:
--------------------
Algebraic!(int, double, string) v = 5;
assert(v.Algebraic.isActive!int);

v = 3.14;
assert(v.Algebraic.isActive!double);

v *= 2;
assert(v > 6);
--------------------

You can call any method $(D Types) have against $(D Algebraic).
--------------------
Algebraic!(string, wstring, dstring) s;

s = "The quick brown fox jumps over the lazy dog.";
assert(s.front == 'T');
assert(s.back == '.');
assert(s.length == 44);
s.popBack;
assert(equal(take(retro(s), 3), "god"));
--------------------

Dispatch a holded object to several handlers with $(D Algebraic.dispatch):
--------------------
Algebraic!(int, double, string) x = 42;

x.Algebraic.dispatch(
        (ref int n)
        {
            writeln("saw an int: ", n);
            ++n;
        },
        (string s)
        {
            writeln("saw a string: ", s);
        }
    );
assert(x == 43);    // incremented
--------------------
 */

struct Algebraic(_Types...)
        if (isAlgebraicCanonicalized!_Types)
{
    static assert(_Types.length > 0,
            "Attempted to instantiate Algebraic with empty argument");
    static assert(is(_Types == Erase!(void, _Types)),
            "void is not allowed for Algebraic");

    /**
     * Constructs an $(D Algebraic) object with an initial value
     * $(D init).
     *
     * See_Also:
     *  $(D opAssign)
     */
    this(T)(T init)
    {
        static assert(_canAssign!(T), "Attempted to construct an "
                ~ typeof(this).stringof ~ " with a disallowed initial "
                "object of type " ~ T.stringof);
        _grab(init);
    }


    /**
     * Assigns $(D rhs) to the $(D Algebraic) object.
     *
     * If $(D T) is one of the $(D Types...), the active object (if any)
     * is destroyed and $(D rhs) takes place of it;  otherwise assignment
     * of $(D rhs) occurs on the active object.
     */
    @system void opAssign(T)(T rhs)
            if (_canAssign!(T) && !_isCompatibleAlgebraic!(T))
    {
        static if (_allowed!T)
        {
            if (!_empty)
                _dispose();
            _grab(rhs);
        }
        else
        {
            if (_empty)
                _grab(rhs);
            else
                _assign(rhs);
        }
    }

    @trusted void opAssign(T)(T rhs)
            if (is(T == typeof(this)))
    {
        swap(this, rhs);
    }

    @system void opAssign(T)(T rhs)
            if (_isCompatibleAlgebraic!(T) && !is(T == typeof(this)))
    {
        foreach (U; T.Algebraic.Types)
        {
            static if (_canAssign!U)
            {
                if (rhs.Algebraic.isActive!U)
                    return opAssign(rhs.Algebraic.instance!U);
            }
        }
        throw new VariantException("Attempted to assign incompatible "
                ~ "Algebraic of type " ~ T.stringof ~ " to "
                ~ typeof(this).stringof);
    }

    private template _isCompatibleAlgebraic(T)
    {
//      static if (is(T : .Algebraic!UU, UU...)) // @@@ bug?
        static if (is(T.Algebraic.Types UU) && is(T == .Algebraic!UU))
            enum bool _isCompatibleAlgebraic =
                _Types.length + UU.length > NoDuplicates!(_Types, UU).length;
        else
            enum bool _isCompatibleAlgebraic = false;
    }

    // @@@BUG4424@@@ workaround
    private template _workaround4424()
        { @disable void opAssign(...) { assert(0); } }
    mixin _workaround4424 _workaround4424_;


    /**
     * Invokes the copy constructor on the active object if any.
     */
    this(this)
    {
        if (!_empty)
        {
            mixin (_onActiveObject!(
                q{
                    static if (__traits(compiles,
                            _storageAs!Active().__postblit() ))
                        _storageAs!Active().__postblit();
                }));
        }
    }


    /**
     * Invokes the destructor on the active object if any.
     */
    ~this()
    {
        if (!_empty)
            _dispose();
    }


    //------------------------------------------------------------------------//

    /**
     * $(D Algebraic) namespace for operating on the $(D Algebraic) object
     * itself, not a holded object.
     *
     * Example:
--------------------
Algebraic!(A, B) ab;
assert(ab.Algebraic.empty);

ab = A();
assert(ab.Algebraic.isActive!A);
--------------------
     */
    private template _Algebraic()
    {
        /**
         * The type tuple used to instantiate the $(D Algebraic) with no
         * duplicates.
         *
         * Example:
--------------------
Algebraic!(int, int, real, int) x;
assert(is( x.Algebraic.Types == TypeTuple!(int, real) ));
--------------------
         */
        alias _Types Types;


        /**
         * Returns $(D true) if type $(D T) is contained in $(D Types...).
         */
        template allowed(T)
        {
            enum bool allowed = _allowed!T;
        }


        /**
         * Returns $(D true) if an object of type $(D T) can be assigned to
         * the $(D Algebraic) object.
         */
        template canAssign(T)
        {
            enum bool canAssign = _canAssign!T;
        }


        /**
         * Returns $(D true) if the $(D Algebraic) object holds nothing.
         */
        @safe @property nothrow bool empty() const
        {
            return _empty;
        }


        /**
         * Returns $(D true) if the type of the active object is $(D T).
         */
        @safe nothrow bool isActive(T)() const
        {
            return !_empty && _which == _typeCode!T;
        }

        unittest
        {
            .Algebraic!Types x;
            foreach (Type; Types)
            {
                assert(!x.Algebraic.isActive!Type);
                x = Type.init;
                assert(x.Algebraic.isActive!Type);
            }
        }


        /**
         * Returns the active object of type $(D T) by reference.  $(D T)
         * must be the type of the active object, i.e.,
         * $(D isActive!T == true).
         *
         * Throws:
         * $(UL
         *   $(LI $(D VariantException) if the $(D Algebraic) object is
         *        empty or $(D T) is not active.)
         * )
         *
         * Example:
--------------------
// take a pointer to the active object
Algebraic!(A, B) ab = A();

assert(ab.Algebraic.isActive!A);
A* p = &(ab.Algebraic.instance!A());
B* q = &(ab.Algebraic.instance!B());    // throws VariantException
--------------------
         */
        @trusted @property ref T instance(T)()
                if (allowed!(T))
        {
            if (!isActive!T)
                throw new VariantException("Attempting to peek a reference "
                        ~ "to " ~ T.stringof ~ " in " ~ typeof(this).stringof);
            return _storageAs!T;
        }
        /+ // @@@BUG3748@@@
        @trusted @property nothrow ref inout(T) instance(T)() inout
        +/


        /**
         * Returns the active object as a value of type $(D T) allowing
         * implicit convertion.
         *
         * Throws:
         *  $(UL
         *   $(LI Compile fails if none of $(D Types...) supports implicit
         *      convertion to $(D T).)
         *   $(LI $(D VariantException) if the $(D Algebraic) object is
         *      empty or the active object is not implicitly convertible
         *      to $(D T).)
         *  )
         */
        @trusted T get(T)()
            if (_canGet!(T))
        {
            if (_empty)
                throw new VariantException("Attempted to get a value of "
                        "type " ~ T.stringof ~ " out of an empty "
                        ~ typeof(this).stringof);

            mixin (_onActiveObject!(
                q{
                    static if (isImplicitlyConvertible!(Active, T))
                        return _storageAs!Active;
                    else
                        throw new VariantException(Active.stringof
                            ~ "is not implicitly convertible to "
                            ~ T.stringof);
                }));
            assert(0);
        }

        private template _canGet(T, size_t i = 0)
        {
            static if (i < Types.length && is(Types[i] Active))
                enum bool _canGet = isImplicitlyConvertible!(Active, T)
                        || _canGet!(T, i + 1);
            else
                enum bool _canGet = false;
        }


        /**
         * Returns the active object explicitly converted to $(D T) using
         * $(D std.conv.to!T).
         *
         * Throws:
         *  $(UL
         *   $(LI Compile fails if none of $(D Types...) supports explicit
         *      convertion to $(D T).)
         *   $(LI $(D VariantException) if the $(D Algebraic) object is
         *      empty.)
         *   $(LI $(D ConvError) on any convertion error.)
         *  )
         */
        @trusted T coerce(T)()
            if (_canCoerce!(T))
        {
            if (_empty)
                throw new VariantException("Attempted to coerce an empty "
                        ~ typeof(this).stringof ~ " into " ~ T.stringof);

            mixin (_onActiveObject!(
                q{
                    static if (__traits(compiles, to!T(phony!Active)))
                        return to!T(_storageAs!Active);
                    else
                        throw new ConvError("Can't convert a value of type "
                            ~ Active.stringof ~ " to type " ~ T.stringof)
                }));
            assert(0);
        }

        private template _canCoerce(T, size_t i = 0)
        {
            static if (i < Types.length && is(Types[i] Active))
                enum bool _canCoerce = __traits(compiles, to!T(phony!Active))
                        || _canCoerce!(T, i + 1);
            else
                enum bool _canCoerce = false;
        }


        /**
         * Passes a reference to the active object by reference to
         * appropriate $(D handlers) in turn.
         *
         * Returns:
         *  $(D true) if at least one handler is called.
         *
         * Example:
--------------------
Algebraic!(A, B, C) x = A.init;

// will print "saw an A" and "it's an A"
auto matched = x.Algebraic.dispatch(
        (A obj) { writeln("saw an A"); },
        (B obj) { writeln("saw a B"); },
        (ref A obj) { writeln("it's an A"); }
    );
assert(matched == true);
--------------------
         */
        bool dispatch(Handlers...)(Handlers handlers)
        {
            if (_empty)
                return false;

            uint match = 0;
            mixin (_onActiveObject!(
                q{
                    foreach (handler; handlers)
                    {
                        static if (__traits(compiles,
                                handler(_storageAs!Active)))
                        {
                            handler(_storageAs!Active);
                            ++match;
                        }
                    }
                }));
            return match != 0;
        }
    }

    /// Ditto
    alias _Algebraic!() Algebraic;


    //----------------------------------------------------------------//

    /**
     * Evaluates a method or a property $(D op) on the active object.
     *
     * The operation $(D op) must be defined by at least one type in the
     * allowed $(D Types...).
     *
     * Params:
     *  args = The arguments to be passed to the method.
     *
     * Returns:
     *  The value returned by the active object's method $(D op).
     *
     *  The type of the result is the $(D CommonType) of all $(D op)s on
     *  possible $(D Types...).  It's returned by reference if all the
     *  return types are identical and returned by reference.
--------------------
Algebraic!(int, real) n = 0;
assert(is(typeof(n.max) == real));

Algebraic!(int[], Retro!(int[])) r = [ 1, 2, 3 ];
auto p = &(r.front());
assert(*p == 1);
--------------------
     *
     * Throws:
     *  $(UL
     *   $(LI $(D VariantException) if the $(D Algebraic) object is
     *        empty.)
     *   $(LI $(D VariantException) if the method $(D op) is not
     *        defined by the active object.)
     *  )
     *
     * BUGS:
     *  $(UL
     *   $(LI Forward reference errors may occur due to $(BUGZILLA 3294).
     *       For example, $(D hasLength) reports $(D false) even if the
     *       $(D length) property is really available.)
     *  )
     */
    auto ref opDispatch(string op, Args...)(auto ref Args args)
            if (_canDispatch!(op, Args))
    {
        alias CommonType!(_MapDispatchRTs!(0, op, Args)) RT;
        enum byRef    = _canDispatchByRef!(op, Args);

        enum attempt  = (Args.length ? op ~ Args.stringof : op);
        enum dispatch = "_storageAs!Active()."
                ~ (args.length ? op ~ "(args)" : op);

        if (_empty)
            throw new VariantException(_emptyMsg(attempt));
        //
        mixin (_onActiveObject!(
            q{
                static if (is(typeof(mixin(dispatch)) Ri))
                {
                    static if (byRef)
                    {
                        // Return the result by reference.
                        return mixin(dispatch);
                    }
                    else static if (!is(RT == void) && !is(Ri == void))
                    {
                        // Return the result by value of type RT.
                        return byValue!RT(mixin(dispatch));
                    }
                    else
                    {
                        // Just dispatch the method and return nothing.
                        return mixin(dispatch), byValue!RT;
                    }
                }
            }));
        throw new VariantException(_undefinedOpMsg(attempt));
    }

    /*
     * Returns a type tuple consisting of the return types of dispatched
     * methods $(D op(Args)).  Non-dispatchable ones are eliminated; so
     * an empty tuple is returned if $(D op(Args)) is not supported.
     */
    template _MapDispatchRTs(size_t i, string op, Args...)
    {
        static if (i < _Types.length)
        {
            static if (is(typeof(function(Args args)
                    // Check if the method is supported by Types[i].
                    // And if so, alias the return type to R.
                        {
                            _Types[i] obj;
                            enum dispatch = "obj."
                                ~ (args.length ? op ~ "(args)" : op);
                            return mixin(dispatch);
                        }
                    ) R == return))
                alias TypeTuple!(R, _MapDispatchRTs!(i + 1, op, Args))
                            _MapDispatchRTs;
            else
                alias _MapDispatchRTs!(i + 1, op, Args)
                            _MapDispatchRTs;
        }
        else
        {
            alias TypeTuple!() _MapDispatchRTs;
        }
    }

    /*
     * Returns true if $(D op(Args)) is supported by at least one type.
     */
    private template _canDispatch(string op, Args...)
    {
        enum bool _canDispatch =
            _MapDispatchRTs!(0, op, Args).length > 0;
    }

    /*
     * Determines if all return types of $(D op(Args)) are identical
     * and by-ref.
     */
    private template _canDispatchByRef(string op, Args...)
    {
        enum bool _canDispatchByRef =
            NoDuplicates!(_MapDispatchRTs!(0, op, Args)).length == 1
            &&
            __traits(compiles, function(Args args)
                {
                    enum dispatch = "obj."
                        ~ (args.length ? op ~ "(args)" : op);
                    foreach (Type; _Types)
                    {
                        Type obj;
                        expectLvalue(mixin(dispatch));
                    }
                });
    }


    //--------------------------------------------------------------------//
    // standard operator overloads

    /*
     * Generic implementation for opXxx.  See opUnary() for usage.
     *
     * Params:
     *  FwdRTs   = Type tuple of the possible return types.
     *  attempt  = What's being done.
     *  dispatch = Valid D expression to dispatch, in which Active is given
     *             as the type of the active object.
     */
    private enum string _opGenericImpl =
        q{
            static assert(FwdRTs.length > 0, _invalidOpMsg(attempt));

            static if (is(Erase!(void, staticMap!(Unqual, FwdRTs)) NVRTs) &&
                    NVRTs.length > 0)
                alias .Algebraic!NVRTs RT;
            else
                alias void             RT;

            if (_empty)
                throw new VariantException(_emptyMsg(attempt));
            mixin (_onActiveObject!(
                q{
                    static if (is(typeof(mixin(dispatch)) Ri))
                    {
                        static if (is(Ri == void))
                            return mixin(dispatch), byValue!RT;
                        else
                            return byValue!RT(mixin(dispatch));
                    }
                }));
            throw new VariantException(_undefinedOpMsg(attempt));
        };

    // TODO
    private template _opGenericOnActiveObject(string expr)
    {
        enum string _opGenericOnActiveObject = _onActiveObject!(
                 "static if (is(typeof(" ~ expr ~ ") Ri))"
                ~"{"
                    ~"static if (is(Ri == void))"
                        ~"return (" ~ expr ~ "), byValue!RT;"
                    ~"else"
                        ~"return byValue!RT(" ~ expr ~ ");"
                ~"}");
    }


    /*
     * Returns a type tuple consisting of the types of expressions $(D expr)
     * successfully mixed in with $(D Args) and $(D Active) as a type in
     * $(D Types).
     *
     * Non-evaluateable expressions are eliminated; so an empty tuple is
     * returned if $(D expr) is not supported.
     */
    private template _MapOpGenericRTs(size_t i, string expr, Args...)
    {
        static if (i < _Types.length && is(_Types[i] Active))
        {
            static if (is(typeof(mixin(expr)) R))
                alias TypeTuple!(R, _MapOpGenericRTs!(i + 1, expr, Args))
                            _MapOpGenericRTs;
            else
                alias _MapOpGenericRTs!(i + 1, expr, Args)
                            _MapOpGenericRTs;
        }
        else
        {
            alias TypeTuple!() _MapOpGenericRTs;
        }
    }


    /*
     * <op>storageAs!Active
     */
    auto opUnary(string op)()
    {
        enum attempt  = "unary " ~ op;
        enum dispatch = op ~ "_storageAs!Active";

        alias _MapOpUnaryRTs!(op) FwdRTs;
        mixin (_opGenericImpl);
    }

    private template _MapOpUnaryRTs(string op)
    {
        alias _MapOpGenericRTs!(0, op ~ "phony!Active") _MapOpUnaryRTs;
    }


    /*
     * storageAs!Active <op> rhs
     */
    auto opBinary(string op, RHS)(RHS rhs)
    {
        enum attempt  = "binary " ~ op ~ " " ~ RHS.stringof;
        enum dispatch = "_storageAs!Active() " ~ op ~ " rhs";

        alias _MapOpBinaryRTs!(op, RHS) FwdRTs;
        mixin (_opGenericImpl);
    }

    private template _MapOpBinaryRTs(string op, RHS)
    {
        alias _MapOpGenericRTs!(0,
                "phony!Active " ~ op ~ " phony!(Args[0])",
                RHS
            ) _MapOpBinaryRTs;
    }


    /*
     * lhs <op> storageAs!Active
     */
    auto opBinaryRight(string op, LHS)(LHS lhs)
    {
        enum attempt  = "binary " ~ LHS.stringof ~ " " ~ op;
        enum dispatch = "lhs " ~ op ~ " _storageAs!Active";

        alias _MapOpBinaryRightRTs!(op, LHS) FwdRTs;
        mixin (_opGenericImpl);
    }

    private template _MapOpBinaryRightRTs(string op, LHS)
    {
        alias _MapOpGenericRTs!(0,
                "phony!(Args[0]) " ~ op ~ " phony!Active",
                LHS
            ) _MapOpBinaryRightRTs;
    }


    /*
     * storageAs!Active[ indices[0], ... ]
     */
    auto opIndex(Indices...)(Indices indices)
    {
        enum K        = Indices.length;
        enum attempt  = to!string(K) ~ "-indexing";
//      enum dispatch = "_storageAs!Active()[indices]"; // @@@BUG4444@@@
        enum dispatch = "_storageAs!Active()[" ~ expandArray("indices", K) ~ "]";

        alias _MapOpIndexRTs!(Indices) FwdRTs;
        mixin (_opGenericImpl);
    }

    private template _MapOpIndexRTs(Indices...)
    {
        alias _MapOpGenericRTs!(0,
//              "phony!Active[phonyList!Args]", // @@@BUG4444@@@
                "phony!Active[" ~ expandArray("phonyList!Args", Indices.length) ~ "]",
                Indices
            ) _MapOpIndexRTs;
    }


    /*
     * storageAs!Active[i .. j]
     */
    auto opSlice(I, J)(I i, J j)
    {
        enum attempt  = "slicing";
        enum dispatch = "_storageAs!Active()[i .. j]";

        alias _MapOpSliceRTs!(I, J) FwdRTs;
        mixin (_opGenericImpl);
    }

    private template _MapOpSliceRTs(I, J)
    {
        alias _MapOpGenericRTs!(0,
                "phony!Active[phony!(Args[0]) .. phony!(Args[1])]",
                I, J
            ) _MapOpSliceRTs;
    }


    /*
     * storageAs!Active[]
     */
    auto opSlice()()
    {
        enum attempt  = "whole-slicing";
        enum dispatch = "_storageAs!Active()[]";

        alias _MapOpSliceRTs!() FwdRTs;
        mixin (_opGenericImpl);
    }

    private template _MapOpSliceRTs()
    {
        alias _MapOpGenericRTs!(0, "phony!Active[]") _MapOpSliceRTs;
    }


    /*
     * <op>storageAs!Active[ indices[0], ... ]
     */
    auto opIndexUnary(string op, Indices...)(Indices indices)
    {
        enum K        = Indices.length;
        enum attempt  = to!string(K) ~ "-indexing unary " ~ op;
//      enum dispatch = op ~ "_storageAs!Active()[indices]";  // @@@BUG4444@@@
        enum dispatch = op ~ "_storageAs!Active()[" ~ expandArray("indices", K) ~ "]";

        alias _MapOpIndexUnaryRTs!(op, Indices) FwdRTs;
        mixin (_opGenericImpl);
    }

    private template _MapOpIndexUnaryRTs(string op, Indices...)
    {
        alias _MapOpGenericRTs!(0,
//              op ~ "phony!Active[phonyList!Args]",    // @@@BUG4444@@@
                op ~ "phony!Active["
                    ~ expandArray("phonyList!Args", Indices.length) ~ "]",
                Indices
            ) _MapOpIndexUnaryRTs;
    }


    /*
     * <op>storageAs!Active[i .. j]
     */
    auto opSliceUnary(string op, I, J)(I i, J j)
    {
        enum attempt  = "unary slicing " ~ op;
        enum dispatch = op ~ "_storageAs!Active()[i .. j]";

        alias _MapOpSliceUnaryRTs!(op, I, J) FwdRTs;
        mixin (_opGenericImpl);
    }

    private template _MapOpSliceUnaryRTs(string op, I, J)
    {
        alias _MapOpGenericRTs!(0,
                op ~ "phony!Active[phony!(Args[0]) .. phony!(Args[1])]",
                I, J
            ) _MapOpSliceUnaryRTs;
    }


    /*
     * <op>storageAs!Active[]
     */
    auto opSliceUnary(string op)()
    {
        enum attempt  = "unary whole-slicing " ~ op;
        enum dispatch = op ~ "_storageAs!Active()[]";

        alias _MapOpSliceUnaryRTs!(op) FwdRTs;
        mixin (_opGenericImpl);
    }

    private template _MapOpSliceUnaryRTs(string op)
    {
        alias _MapOpGenericRTs!(0, op ~ "phony!Active[]") _MapOpSliceUnaryRTs;
    }


    /*
     * storageAs!Active[ indices[0], ... ] = rhs
     */
    auto opIndexAssign(RHS, Indices...)(RHS rhs, Indices indices)
    {
        enum K        = Indices.length;
        enum attempt  = to!string(K) ~ "-indexing assignment of " ~ RHS.stringof;
//      enum dispatch = "_storageAs!Active()[indices] = rhs";  // @@@BUG4444@@@
        enum dispatch = "_storageAs!Active()[" ~ expandArray("indices", K) ~ "] = rhs";

        alias _MapOpIndexAssignRTs!(RHS, Indices) FwdRTs;
        mixin (_opGenericImpl);
    }

    private template _MapOpIndexAssignRTs(RHS, Indices...)
    {
        alias _MapOpGenericRTs!(0,
//              "phony!Active[ phonyList!(Args[1 .. $] ] = phony!(Args[0])", // @@@BUG4444@@@
                "phony!Active[" ~ expandArray(
                    "phonyList!(Args[1 .. $])", Indices.length)
                        ~ "] = phony!(Args[0])",
                RHS, Indices
            ) _MapOpIndexAssignRTs;
    }


    /*
     * storageAs!Active[i .. j] = rhs
     */
    auto opSliceAssign(RHS, I, J)(RHS rhs, I i, J j)
    {
        enum attempt  = "slicing assignment of " ~ RHS.stringof;
        enum dispatch = "_storageAs!Active()[i .. j] = rhs";

        alias _MapOpSliceAssignRTs!(RHS, I, J) FwdRTs;
        mixin (_opGenericImpl);
    }

    private template _MapOpSliceAssignRTs(RHS, I, J)
    {
        alias _MapOpGenericRTs!(0,
                "phony!Active[phony!(Args[1]) .. phony!(Args[2])]"
                    ~ " = phony!(Args[0])",
                RHS, I, J
            ) _MapOpSliceAssignRTs;
    }


    /*
     * storageAs!Active[] = rhs
     */
    auto opSliceAssign(RHS)(RHS rhs)
    {
        enum attempt  = "whole-slicing assignment of " ~ RHS.stringof;
        enum dispatch = "_storageAs!Active()[] = rhs";

        alias _MapOpSliceAssignRTs!(RHS) FwdRTs;
        mixin (_opGenericImpl);
    }

    private template _MapOpSliceAssignRTs(RHS)
    {
        alias _MapOpGenericRTs!(0,
                "phony!Active[] = phony!(Args[0])",
                RHS
            ) _MapOpSliceAssignRTs;
    }


    /*
     * storageAs!Active <op>= rhs
     */
    auto opOpAssign(string op, RHS)(RHS rhs)
    {
        enum attempt  = "binary assignment " ~ op ~ "= " ~ RHS.stringof;
        enum dispatch = "_storageAs!Active() " ~ op ~ "= rhs";

        alias _MapOpOpAssignRTs!(op, RHS) FwdRTs;
        mixin (_opGenericImpl);
    }

    private template _MapOpOpAssignRTs(string op, RHS)
    {
        alias _MapOpGenericRTs!(0,
                "phony!Active " ~ op ~ "= phony!(Args[0])",
                RHS
            ) _MapOpOpAssignRTs;
    }


    /*
     * storageAs!Active[ indices[0], ... ] <op>= rhs
     */
    auto opIndexOpAssign(string op, RHS, Indices...)(RHS rhs, Indices indices)
    {
        enum attempt  = "binary indexing assignment " ~ op ~ "= " ~ RHS.stringof;
        enum dispatch = "_storageAs!Active()["
                            ~ expandArray("indices", Indices.length)
                        ~ "] " ~ op ~ "= rhs";

        alias _MapOpIndexOpAssignRTs!(op, RHS, Indices) FwdRTs;
        mixin (_opGenericImpl);
    }

    private template _MapOpIndexOpAssignRTs(string op, RHS, Indices...)
    {
        alias _MapOpGenericRTs!(0,
//              "phony!Active[phonyList!(Args[1 .. $])] "
//                  ~ op ~ "= phony!(Args[0])",    // @@@BUG4444@@@
                "phony!Active[" ~ expandArray(
                    "phonyList!(Args[1 .. $])", Indices.length) ~ "] "
                    ~ op ~ "= phony!(Args[0])",
                RHS, Indices
            ) _MapOpIndexOpAssignRTs;
    }


    /*
     * storageAs!Active[i .. j] <op>= rhs
     */
    auto opSliceOpAssign(string op, RHS, I, J)(RHS rhs, I i, J j)
    {
        enum attempt  = "binary slicing assignment " ~ op ~ "= " ~ RHS.stringof;
        enum dispatch = "_storageAs!Active()[i .. j] " ~ op ~ "= rhs";

        alias _MapOpSliceOpAssignRTs!(op, RHS, I, J) FwdRTs;
        mixin (_opGenericImpl);
    }

    private template _MapOpSliceOpAssignRTs(string op, RHS, I, J)
    {
        alias _MapOpGenericRTs!(0,
                "phony!Active[phony!(Args[1]) .. phony!(Args[2])] "
                    ~ op ~ "= phony!(Args[0])",
                RHS, I, J
            ) _MapOpSliceOpAssignRTs;
    }


    /*
     * storageAs!Active[] <op>= rhs
     */
    auto opSliceOpAssign(string op, RHS)(RHS rhs)
    {
        enum attempt  = "binary whole-slicing assignment " ~ op ~ "= "
                        ~ "with " ~ RHS.stringof;
        enum dispatch = "_storageAs!Active()[] " ~ op ~ "= rhs";

        alias _MapOpSliceOpAssignRTs!(op, RHS) FwdRTs;
        mixin (_opGenericImpl);
    }

    private template _MapOpSliceOpAssignRTs(string op, RHS)
    {
        alias _MapOpGenericRTs!(0,
                "phony!Active[] " ~ op ~ "= phony!(Args[0])",
                RHS
            ) _MapOpSliceOpAssignRTs;
    }


    /*
     * cast(T) storageAs!Active
     */
    T opCast(T)()
    {
        enum attempt = "casting to " ~ T.stringof;

        if (_empty)
            throw new VariantException(_emptyMsg(attempt));
        mixin (_onActiveObject!(
            q{
                static if (is(Active : T))
                    return         _storageAs!Active;
//              else static if (__traits(compiles, cast(T) _storageAs!Active))  // @@@ e2ir
                else static if (is(typeof(Active.opCast!T) R == return) && is(R == T))
                    return cast(T) _storageAs!Active;
            }));
        throw new VariantException(_undefinedOpMsg(attempt));
    }


    /*
     * storageAs!Active == rhs
     */
    bool opEquals(RHS)(auto ref RHS rhs) const
            if (!_isCompatibleAlgebraic!(RHS))
    {
        enum attempt = "equality comparison with " ~ RHS.stringof;

        if (_empty)
            throw new VariantException(_emptyMsg(attempt));
        mixin (_onActiveObject!(
            q{
                static if (__traits(compiles,
                        _storageAs_const!Active() == rhs))
                    return _storageAs_const!Active() == rhs;
            }));
        throw new VariantException(_undefinedOpMsg(attempt));
    }

    // Algebraic vs. Algebraic
    bool opEquals(RHS)(ref const RHS rhs) const
            if (is(RHS == typeof(this)))
    {
        if (!_empty && _which == rhs._which)
        {
            mixin (_onActiveObject!(
                q{
                    return _storageAs_const!Active() ==
                            rhs._storageAs_const!Active;
                }));
            assert(0);
        }
        else
        {
            return false;
        }
    }


    /*
     * storageAs!Active <>= rhs
     */
    int opCmp(RHS)(auto ref RHS rhs) const
            if (!_isCompatibleAlgebraic!(RHS))
    {
        enum attempt = "ordering comparison with " ~ RHS.stringof;

        if (_empty)
            throw new VariantException(_emptyMsg(attempt));
        mixin (_onActiveObject!(
            q{
                static if (__traits(compiles, _storageAs_const!Active < rhs))
                {
                    return (_storageAs_const!Active < rhs) ? -1 :
                           (_storageAs_const!Active > rhs) ?  1 : 0;
                }
            }));
        throw new VariantException(_undefinedOpMsg(attempt));
    }

    // Algebraic vs. Algebraic
    int opCmp(RHS)(ref const RHS rhs) const
            if (is(RHS == typeof(this)))
    {
        enum attempt = "ordering comparison";

        if (_empty)
            throw new VariantException(_emptyMsg(attempt));
        mixin (_onActiveObject!(
            q{
                return -rhs.opCmp(_storageAs_const!Active);
            }));
        assert(0);
    }

    // TODO _isCompatibleAlgebraic

    /+
    // @@@BUG4253@@@
    auto opCall(Args...)(auto ref Args args)
    {
        enum attempt  = "calling operator";
        enum dispatch = "_storageAs!Active(args)";

        alias _MapOpCallRTs!(Args) FwdRTs;
        mixin (_opGenericImpl);
    }

    private template _MapOpCallRTs(Args...)
    {
        alias _MapOpGenericRTs!(0,
                "phony!Active(phonyList!Args)",
                Args
            ) _MapOpCallRTs;
    }
    +/

    /+
    // @@@ cannot coexist with input range primitives
    int opApply(Args...)(int delegate(ref Args) dg)
    {
        enum attempt = "foreach";

        if (_empty)
            throw new VariantException(_emptyMsg(attempt));
        mixin (_onActiveObject!(
            q{
                static if (__traits(compiles,
                        _storageAs!Active().opApply(dg)))
                    return _storageAs!Active().opApply(dg);
            }));
        throw new VariantException(_undefinedOpMsg(attempt));
    }
    +/


    //--------------------------------------------------------------------//
    // special functions

    @trusted string toString()
    {
        if (_empty)
            return typeof(this).stringof ~ "(empty)";

        mixin (_onActiveObject!(
            q{
                static if (__traits(compiles,
                        to!string(_storageAs!Active) ))
                    return to!string(_storageAs!Active);
                else
                    return Active.stringof;
            }));
        assert(0);
    }

    @trusted hash_t toHash() const
    {
        if (_empty)
            return 0;

        mixin (_onActiveObject!(
            q{
                return typeid(Active).getHash(_storage.ptr);
            }));
        assert(0);
    }


    // input range primitives
    static if (_canDispatch!"front" &&
               _canDispatch!"empty" &&
               _canDispatch!"popFront")
    {
        @property bool empty()
        {
            return opDispatch!"empty"();
        }
        @property auto ref front()
        {
            return opDispatch!"front"();
        }
        void popFront()
        {
            opDispatch!"popFront"();
        }
    }

    // forward range primitive
    static if (_canDispatch!"save")
    {
        @property auto save()
        {
            enum attempt  = "range primitive save()";
            enum dispatch = "_storageAs!Active.save";

            alias _MapPrimitiveSave!() FwdRTs;
            mixin (_opGenericImpl);
        }

        private template _MapPrimitiveSave()
        {
            alias _MapOpGenericRTs!(0, "phony!Active.save")
                    _MapPrimitiveSave;
        }
    }

    // bidirectional range primitives
    static if (_canDispatch!"back" &&
               _canDispatch!"popBack")
    {
        @property auto ref back()
        {
            return opDispatch!"back"();
        }
        void popBack()
        {
            opDispatch!"popBack"();
        }
    }


    //------------------------------------------------------------//
    // internals
private:

    /*
     * Returns the internal code number of the type $(D T), or
     * $(D size_t.max) if $(D T) is not in $(D Types...).
     */
    template _typeCode(T, size_t id = 0)
    {
        static if (id < _Types.length)
        {
            static if (is(T == _Types[id]))
                enum size_t _typeCode = id;
            else
                enum size_t _typeCode = _typeCode!(T, id + 1);
        }
        else
        {
            enum size_t _typeCode = size_t.max;
        }
    }


    /*
     * Returns $(D true) if $(D T) is in the type tuple $(D Types...).
     */
    template _allowed(T)
    {
        enum bool _allowed = (_typeCode!T != size_t.max);
    }


    /*
     * Returns $(D true) if the $(D Algebraic) object holds nothing currently.
     */
    @safe @property nothrow bool _empty() const
    {
//      return _which == size_t.max;    // @@@ corrupted?
        return _which >= _Types.length;
    }


    /*
     * Returns a reference to the storage as an object of type $(D T).
     */
    @trusted nothrow ref T _storageAs(T)()
    {
        static assert(_allowed!T);
        return *cast(T*) _storage.ptr;
    }
    @trusted nothrow ref const(T) _storageAs_const(T)() const
    {
        static assert(_allowed!T);
        return *cast(const T*) _storage.ptr;
    }
    /+ // @@@BUG3748@@@
    @trusted nothrow ref inout(T) storageAs(T)() inout
    +/


    /*
     * Generates code for doing $(D stmt) on the active object.
     */
    template _onActiveObject(string stmt)
    {
        enum string _onActiveObject =
                 "assert(!_empty);"
            ~"L_chooseActive:"
                ~"final switch (_which)"
                ~"{"
                    ~"foreach (Active; _Types)"
                    ~"{"
                    ~"case _typeCode!Active:"
                        ~stmt
                        ~"break L_chooseActive;"
                    ~"}"
                ~"}";
    }


    /*
     * Error message for an attempting against any operation on an
     * empty Algebraic object.
     */
    static @safe pure nothrow string _emptyMsg(string attempt)
    {
        return "Attempted to evaluate " ~ attempt ~ " on an empty "
            ~ typeof(this).stringof;
    }

    /*
     * Error message for an attempting to evaluate any operation that
     * is not defined by any of $(D Types...).
     */
    static @safe pure nothrow string _invalidOpMsg(string op)
    {
        return "No type in " ~ typeof(this).stringof ~ " defines " ~ op;
    }

    /*
     * Error message for an attempting to evaluate any operation that
     * is not defined by the active object.
     */
    @safe nothrow string _undefinedOpMsg(string op) const
    in
    {
        assert(!_empty);
    }
    body
    {
        string typeName;

        mixin (_onActiveObject!(
            q{
                typeName = Active.stringof;
            }));
        return "An active object of type " ~ typeName ~ " does not "
            ~ "define " ~ op;
    }


    /*
     * Determines if assignment of a $(D T) is allowed on at least one
     * of $(D Types...).
     */
    template _canAssign(T, size_t i = 0)
    {
        static if (i < _Types.length && is(_Types[i] Type))
            enum bool _canAssign =
                is(T : Type)
                ||
                __traits(compiles, function(ref Type duck, T rhs)
                    {
                        // implicit convertion or opAssign
                        duck = rhs;
                    })
                ||
                _canAssign!(T, i + 1);
        else
            enum bool _canAssign = false;
    }

    unittest
    {
        foreach (Type; _Types)
            assert(_canAssign!(Type));
        struct Unknown {}
        assert(!_canAssign!(Unknown));
    }


    /*
     * Set $(D rhs) in the empty storage.
     */
    @trusted void _grab(T)(ref T rhs)
    in
    {
        assert(_empty);
    }
    out
    {
        assert(!_empty);
    }
    body
    {
        static if (_allowed!T)
        {
            // Simple blit.
            init(_storageAs!T);
            swap(_storageAs!T, rhs);
            _which = _typeCode!T;
        }
        else
        {
            // Use opAssign matched first.
            foreach (Active; _Types)
            {
                static if (__traits(compiles, _storageAs!Active() = rhs))
                {
                    init(_storageAs!Active);
                    _storageAs!Active() = rhs;
                    _which = _typeCode!Active;
                    break;
                }
            }
        }
    }


    /*
     * Assigns $(D rhs) to the non-empty active storage.
     */
    @trusted void _assign(T)(ref T rhs)
    in
    {
        assert(!_empty);
    }
    body
    {
        mixin (_onActiveObject!(
            q{
                static if (__traits(compiles, _storageAs!Active() = rhs))
                    return _storageAs!Active() = rhs;
            }));

        // Or, replace the content with rhs.
        _dispose();
        _grab(rhs);
    }


    /*
     * Destroys the active object (if it's a struct) and marks this
     * $(D Algebraic) object empty.
     */
    @trusted void _dispose()
    in
    {
        assert(!_empty);
    }
    out
    {
        assert(_empty);
    }
    body
    {
        mixin (_onActiveObject!(
            q{
                static if (__traits(compiles, _storageAs!Active.__dtor()))
                    _storageAs!Active.__dtor();
                _which = size_t.max;
                return;
            }));
        assert(0);
    }


    //------------------------------------------------------------------------//
private:
    void*[(maxSize!_Types + (void*).sizeof - 1) / (void*).sizeof]
            _storage;
    size_t  _which = size_t.max;    // typeCode of the active object
}


version (unittest) private
{
    bool eq(S)(S a, S b)
    {
        foreach (i, _; a.tupleof)
        {
            if (a.tupleof[i] != b.tupleof[i])
                return false;
        }
        return true;
    }

    bool fails(lazy void expr)
    {
        try { expr; } catch (VariantException e) { return true; }
        return false;
    }
}

//-------------- doc examples

unittest
{
    // doc example 0
    Algebraic!(int, double) x;

    // these lines won't compile since long and string are not allowed
//  auto n = x.Algebraic.instance!long;
//  x = "abc";
    assert(!__traits(compiles, x.Algebraic.instance!long));
    assert(!__traits(compiles, x = "abc"));
}

unittest
{
    // doc example 1
    Algebraic!(int, double, string) v = 5;
    assert(v.Algebraic.isActive!int);

    v = 3.14;
    assert(v.Algebraic.isActive!double);

    v *= 2;
    assert(v > 6);
}

unittest
{
    // doc example 2
    Algebraic!(string, wstring, dstring) s;

    s = "The quick brown fox jumps over the lazy dog.";
    assert(s.front == 'T');
    assert(s.back == '.');
    assert(s.length == 44);
    s.popBack;
    assert(equal(take(retro(s), 3), "god"));
}

unittest
{
    // doc exmaple 3
    Algebraic!(int, double, string) x = 42;

    x.Algebraic.dispatch(
            (ref int n)
            {
                //writeln("saw an int: ", n);
                assert(n == 42);
                ++n;
            },
            (string s)
            {
                //writeln("saw a string: ", s);
                assert(0);
            }
        );
    assert(x == 43);    // incremented
}

unittest
{
    // doc example 4
    Algebraic!(int, int, real, int) x;
    assert(is( x.Algebraic.Types == TypeTuple!(int, real) ));
}

unittest
{
    // doc example 5 - take a pointer to the active object
    struct A {}
    struct B {}
    Algebraic!(A, B) ab = A();

    assert(ab.Algebraic.isActive!A);
    A* p = &(ab.Algebraic.instance!A());
//  B* q = &(ab.Algebraic.instance!B());    // throws VariantException
    B* q;
    assert(fails( q = &(ab.Algebraic.instance!B()) ));
}

//--------------

unittest
{
    // funny types
    assert(!__traits(compiles, Algebraic!()));
    assert(!__traits(compiles, Algebraic!(void)));
    assert(!__traits(compiles, Algebraic!(int, void, dchar)));
    assert(is( Algebraic!(int, real, int) == Algebraic!(int, real) ));
}

unittest
{
    // copy constructor & destructor
    struct Counter
    {
        int* copies;
        this(this) { copies && ++*copies; }
        ~this()    { copies && --*copies; }
    }
    Algebraic!(Counter) a;
    a = Counter(new int);
    assert(*a.copies == 0);
    {
        auto b = a;
        assert(*a.copies == 1);
        {
            auto c = a;
            assert(*a.copies == 2);
        }
        assert(*a.copies == 1);
    }
    assert(*a.copies == 0);
}

unittest
{
    // basic use
    int afoo, bfoo;
    struct A {
        int inc() { return ++afoo; }
        int dec() { return --afoo; }
    }
    struct B {
        int inc() { return --bfoo; }
        int dec() { return ++bfoo; }
    }
    Algebraic!(A, B) ab;
    ab = A();
    assert(ab.inc() == 1 && afoo == 1);
    assert(ab.dec() == 0 && afoo == 0);
    ab = B();
    assert(ab.inc() == -1 && bfoo == -1);
    assert(ab.dec() ==  0 && bfoo ==  0);
}

unittest
{
    // constructor
    auto x = Algebraic!(int, real)(4.5);
    assert(x == 4.5);
}

unittest
{
    // meta interface
    Algebraic!(int, real) a;

    assert(is(a.Algebraic.Types == TypeTuple!(int, real)));
    assert(a.Algebraic.allowed!int);
    assert(a.Algebraic.allowed!real);
    assert(!a.Algebraic.allowed!string);

    assert(a.Algebraic.canAssign!int);
    assert(a.Algebraic.canAssign!real);
    assert(a.Algebraic.canAssign!byte);
    assert(a.Algebraic.canAssign!short);
    assert(a.Algebraic.canAssign!ushort);
    assert(a.Algebraic.canAssign!double);
    assert(a.Algebraic.canAssign!(const int));
    assert(a.Algebraic.canAssign!(immutable int));
    assert(!a.Algebraic.canAssign!string);
    assert(!a.Algebraic.canAssign!void);
    assert(!a.Algebraic.canAssign!(int*));
    assert(!a.Algebraic.canAssign!(int[]));

    assert(a.Algebraic.empty);

    a = 42;
    assert(!a.Algebraic.empty);
    assert( a.Algebraic.isActive!int);
    assert(!a.Algebraic.isActive!real);
    assert(!a.Algebraic.isActive!string);
    assert(fails( a.Algebraic.instance!real ));
    int* i = &(a.Algebraic.instance!int());
    assert(*i == 42);

    a = -21.0L;
    assert(!a.Algebraic.empty);
    assert(!a.Algebraic.isActive!int);
    assert( a.Algebraic.isActive!real);
    assert(!a.Algebraic.isActive!string);
    assert(fails( a.Algebraic.instance!int ));
    real* r = &(a.Algebraic.instance!real());
    assert(*r == -21.0L);

    a = 100;
    assert(a.Algebraic.dispatch(
            (int a) { assert(a == 100); },
            (ref real b) { assert(0); },
            (ref int a) { assert(a == 100); ++a; }
        ));
    assert(a == 101);

    a = a.init;
    assert(a.Algebraic.empty);
    assert(fails( a.Algebraic.instance!int ));
    assert(fails( a.Algebraic.instance!real ));
}

unittest
{
    // implicit convertion
    Algebraic!(real, const(char)[]) a;

    a = 42;
    assert(a.Algebraic.isActive!real);
    a = "abc";
    assert(a.Algebraic.isActive!(const(char)[]));
}

unittest
{
    // foreach over input range
    Algebraic!(string, wstring) str;

    assert(isInputRange!(typeof(str)));
    assert(isForwardRange!(typeof(str)));
    assert(isBidirectionalRange!(typeof(str)));
//  assert(isRandomAccessRange!(typeof(str)));  // @@@ forward reference
//  assert(hasLength!(typeof(str)));            // @@@ forward reference

    str = cast(string) "a";
    assert(str.length == 1);
    assert(str.front == 'a');
    str.popFront;
    assert(str.empty);

    str = cast(wstring) "bc";
    assert(str.length == 2);
    str.popFront;
    assert(str.front == 'c');
    assert(!str.empty);

    size_t i;
    str = "\u3067\u3043\u30fc";
    foreach (e; str)
        assert(e == "\u3067\u3043\u30fc"d[i++]);
    foreach_reverse (e; str)
        assert(e == "\u3067\u3043\u30fc"d[--i]);
}

//-------------- operator overloads

unittest
{
    // opDispatch
    struct Tag { string op; int n; }
    struct OpEcho {
        Tag opDispatch(string op)(int n) {
            return Tag(op, n);
        }
    }
    Algebraic!(OpEcho) obj;

    obj = OpEcho();
    auto r = obj.foo(42);
    assert(eq( r, Tag("foo", 42) ));
}

unittest
{
    // opDispatch (common type)
    struct K {
        @property  int value() { return 441; }
    }
    struct L {
        @property real value() { return 4.5; }
    }
    Algebraic!(K, L) obj;

    obj = K(); assert(obj.value == 441);
    obj = L(); assert(obj.value == 4.5);

    assert(!__traits(compiles, &(obj.value()) ));
//  assert(is( typeof(obj.value()) == real ));  // @@@ forward reference
    auto r = obj.value;
    assert(is( typeof(r) == real ));
}

unittest
{
    // opDispatch (ref argument & ref return)
    struct K {
        ref int foo(ref int a, ref int b) { ++b; return a; }
    }
    struct L {
        ref int foo(   long a, ref int b) {      return b; }
    }
    Algebraic!(K, L) q;
    int v, w;

    q = K();
    assert(&(q.foo(v, w)) == &v);
    assert(w == 1);

    q = L();
    assert(&(q.foo(v, w)) == &w);
}

unittest
{
    // opDispatch (empty / undefined)
    Algebraic!(int, real) obj;

    assert(fails( obj.max ));
    obj = 42;
    assert(fails( obj.nan ));
}

unittest
{
    // opAssign
    struct Tag { string op; int n; }
    struct OpEcho {
        int n;
        void opAssign(int n) {
            this.n = n;
        }
    }
    Algebraic!(OpEcho) obj;

    obj = OpEcho();
    obj = 42;
    assert(obj.n == 42);
}

unittest
{
    // opAssign (intersection)
    Algebraic!(   int, real) a;
    Algebraic!(string, real) b;

    a = 4;
    assert(a.Algebraic.isActive!int);
    b = a;
    assert(b.Algebraic.isActive!real);
    a = b;
    assert(a.Algebraic.isActive!real);
    b = "0";
    assert(b.Algebraic.isActive!string);

    // incompatible: string
    assert(fails( a = b ));
}

unittest
{
    // opUnary
    struct Tag { string op; }
    struct OpEcho {
        Tag opUnary(string op)() {
            return Tag(op);
        }
    }
    Algebraic!(OpEcho) obj;

    obj = OpEcho();
    foreach (op; TypeTuple!("+", "-", "~", "*", "++", "--"))
    {
        auto r = mixin(op ~ "obj");
        assert(r.Algebraic.isActive!Tag);
        assert(eq( r.Algebraic.instance!Tag, Tag(op) ));
    }
}

unittest
{
    // opUnary (empty, undefined)
    Algebraic!(int, string) p;

    assert(fails( ~p ));
    p = "D";
    assert(fails( +p ));
}

unittest
{
    // opIndexUnary
    struct Tag { string op; int x; real y; }
    struct OpEcho {
        Tag opIndexUnary(string op)(int x, real y) {
            return Tag(op, x, y);
        }
    }
    Algebraic!(OpEcho) obj;

    obj = OpEcho();
    foreach (op; TypeTuple!("+", "-", "~", "*", "++", "--"))
    {
        auto r = mixin(op ~ "obj[4, 2.5]");
        assert(r.Algebraic.isActive!Tag);
        assert(eq( r.Algebraic.instance!Tag, Tag(op, 4, 2.5) ));
    }
}

unittest
{
    // opIndexUnary (empty, undefined)
    Algebraic!(int[], int) obj;

    assert(fails( ++obj[0] ));
    obj = 42;
    assert(fails( --obj[4] ));
}

unittest
{
    // opSliceUnary
    struct Tag { string op; int x; real y; }
    struct OpEcho {
        Tag opSliceUnary(string op, int k = 2)(int x, real y) {
            return Tag(op, x, y);
        }
        Tag opSliceUnary(string op, int k = 0)() {
            return Tag(op, -1, -1);
        }
    }
    Algebraic!(OpEcho) obj;

    obj = OpEcho();
    foreach (op; TypeTuple!("+", "-", "~", "*", "++", "--"))
    {
        auto r = mixin(op ~ "obj[4 .. 5.5]");
        assert(r.Algebraic.isActive!Tag);
        assert(eq( r.Algebraic.instance!Tag, Tag(op, 4, 5.5) ));

        auto s = mixin(op ~ "obj[]");
        assert(r.Algebraic.isActive!Tag);
        assert(eq( s.Algebraic.instance!Tag, Tag(op, -1, -1) ));
    }
}

unittest
{
    // opSliceUnary (empty, undefined)
    Algebraic!(int[], int) obj;

    assert(fails( ++obj[0 .. 1] ));
    assert(fails( --obj[] ));
    obj = 42;
    assert(fails( ++obj[0 .. 1] ));
    assert(fails( --obj[] ));
}

unittest
{
    // opCast
    struct OpEcho {
        T opCast(T)() { return T.init; }
    }
    Algebraic!(OpEcho) obj;

    obj = OpEcho();
    foreach (T; TypeTuple!(int, string, OpEcho, Object, real))
    {
        T r = cast(T) obj;
    }
}

unittest
{
    // opCast (empty, undefined)
    Algebraic!(int, string) obj;

    assert(fails( cast(int) obj ));
    assert(fails( cast(string) obj ));
    obj = 42;
    assert(fails( cast(string) obj ));
    obj = "abc";
    assert(fails( cast(int) obj ));
}

unittest
{
    // opBinary, opBinaryRight
    struct LTag { string op; int v; }
    struct RTag { string op; int v; }
    struct OpEcho {
        LTag opBinary(string op)(int v) {
            return LTag(op, v);
        }
        RTag opBinaryRight(string op)(int v) {
            return RTag(op, v);
        }
    }
    Algebraic!(OpEcho) obj;

    obj = OpEcho();
    foreach (op; TypeTuple!("+", "-", "*", "/", "%", "^^", "&",
                "|", "^", "<<", ">>", ">>>", "~", "in"))
    {
        auto r = mixin("obj " ~ op ~ " 42");
        assert(r.Algebraic.isActive!LTag);
        assert(eq( r.Algebraic.instance!LTag, LTag(op, 42) ));

        auto s = mixin("76 " ~ op ~ " obj");
        assert(s.Algebraic.isActive!RTag);
        assert(eq( s.Algebraic.instance!RTag, RTag(op, 76) ));
    }
}

unittest
{
    // opBinary, opBinaryRight (empty, undefined)
    Algebraic!(int, real) obj;

    assert(fails( obj + 4 ));
    assert(fails( 4 + obj ));
    obj = 4.5;
    assert(fails( obj >> 4 ));
    assert(fails( 4 >> obj ));
}

unittest
{
    // opEquals (forward)
    struct Dummy {
        bool opEquals(int v) const {
            return v > 0;
        }
        bool opEquals(ref const Dummy) const { assert(0); }
    }
    Algebraic!(Dummy) obj;

    obj = Dummy();
    assert(obj ==  1);
    assert(obj !=  0);
    assert(obj != -1);
}

unittest
{
    // opEquals (meta)
    struct Dummy(int k) {
        bool opEquals(int kk)(ref const Dummy!kk rhs) const {
            return k == kk;
        }
    }
    Algebraic!(Dummy!0, Dummy!1) a, b;

    a = Dummy!0();
    b = Dummy!1();
    assert(a == a);
    assert(a != b);
    assert(b == b);
}

unittest
{
    // opCmp (forward)
    struct Dummy {
        int opCmp(int v) const {
            return 0 - v;
        }
        int opCmp(ref const Dummy) const { assert(0); }
    }
    Algebraic!(Dummy) a;

    a = Dummy();
    assert(a >= 0);
    assert(a > -1);
    assert(a < 1);
}

unittest
{
    // opCmp (meta)
    struct Dummy(int k) {
        int opCmp(int kk)(ref const Dummy!kk r) const {
            return k - kk;
        }
    }
    Algebraic!(Dummy!0, Dummy!1) a, b;

    a = Dummy!0();
    b = Dummy!1();
    assert(a >= a);
    assert(a <= b);
    assert(a < b);
    assert(b >= a);
    assert(b <= b);
    assert(b > a);
}

unittest
{
    // opCmp (empty, undefined)
    Algebraic!(int, string) obj;

    assert(fails( /+obj < 0+/ obj.opCmp(0) ));
    obj = "abc";
    assert(fails( /+obj > 0+/ obj.opCmp(1) ));
}

/+
// @@@BUG4253@@@
unittest
{
    // opCall
    struct Tag { int x; real y; }
    struct OpEcho {
        Tag opCall(int x, real y) {
            return Tag(x, y);
        }
    }
    Algebraic!(OpEcho) obj;

//  obj = OpEcho(); // @@@BUG@@@
    obj = OpEcho.init;
    auto r = obj(4, 8.5);
    assert(r.Algebraic.isActive!Tag);
    assert(r.Algebraic.instance!Tag == Tag(4, 8.5));
}
+/

unittest
{
    // opIndexAssign
    struct Tag { string v; int i; real j; }
    struct OpEcho {
        Tag opIndexAssign(string v, int i, real j) {
            return Tag(v, i, j);
        }
    }
    Algebraic!(OpEcho) obj;

    obj = OpEcho();
    auto r = (obj[1, 2.5] = "abc");
    assert(r.Algebraic.isActive!Tag);
    assert(eq( r.Algebraic.instance!Tag, Tag("abc", 1, 2.5) ));
}

unittest
{
    // opIndexAssign (empty, undefined)
    Algebraic!(int, int[]) obj;

    assert(fails( obj[0] = 4 ));
    obj = 42;
    assert(fails( obj[4] = 0 ));
}

unittest
{
    // opSliceAssign
    struct Tag { string v; int i; real j; }
    struct OpEcho {
        Tag opSliceAssign(string v, int i, real j) {
            return Tag(v, i, j);
        }
    }
    Algebraic!(OpEcho) obj;

    obj = OpEcho();
    auto r = (obj[1 .. 2.5] = "abc");
    assert(r.Algebraic.isActive!Tag);
    assert(eq( r.Algebraic.instance!Tag, Tag("abc", 1, 2.5) ));
}

unittest
{
    // opSliceAssign (empty, undefined)
    Algebraic!(int, int[]) obj;

    assert(fails( obj[0 .. 1] = 2 ));
    obj = 42;
    assert(fails( obj[1 .. 2] = 3 ));
}

unittest
{
    // opOpAssign
    struct Tag { string op; int v; }
    struct OpEcho {
        Tag opOpAssign(string op)(int v) {
            return Tag(op, v);
        }
    }
    Algebraic!(OpEcho) obj;

    obj = OpEcho();
    foreach (op; TypeTuple!("+", "-", "*", "/", "%", "^^", "&",
                "|", "^", "<<", ">>", ">>>", "~"))
    {
        auto r = mixin("obj " ~ op ~ "= 97");
        assert(r.Algebraic.isActive!Tag);
        assert(eq( r.Algebraic.instance!Tag, Tag(op, 97) ));
    }
}

unittest
{
    // opOpAssign (empty, undefined)
    Algebraic!(int, string) obj;

//  assert(fails( obj *= 4 ));  // exception uncaught. why?
    obj = "abc";
    assert(fails( obj /= 4 ));
}

unittest
{
    // opIndexOpAssign
    struct Tag { string op; int v; int x; real y; }
    struct OpEcho {
        Tag opIndexOpAssign(string op)(int v, int x, real y) {
            return Tag(op, v, x, y);
        }
    }
    Algebraic!(OpEcho) obj;

    obj = OpEcho();
    foreach (op; TypeTuple!("+", "-", "*", "/", "%", "^^", "&",
                "|", "^", "<<", ">>", ">>>", "~"))
    {
        auto r = mixin("obj[4, 7.5] " ~ op ~ "= 42");
        assert(r.Algebraic.isActive!Tag);
        assert(eq( r.Algebraic.instance!Tag, Tag(op, 42, 4, 7.5) ));
    }
}

unittest
{
    // opIndexOpAssign (empty, undefined)
    Algebraic!(int, int[]) obj;

    assert(fails( obj[0] += 4 ));
    obj = 42;
    assert(fails( obj[1] *= 4 ));
}

unittest
{
    // opSliceOpAssign
    struct Tag { string op; int v; int i; real j; }
    struct OpEcho {
        Tag opSliceOpAssign(string op, int k = 2)(int v, int i, real j) {
            return Tag(op, v, i, j);
        }
        Tag opSliceOpAssign(string op, int k = 0)(int v) {
            return Tag(op, v, -1, -1);
        }
    }
    Algebraic!(OpEcho) obj;

    obj = OpEcho();
    foreach (op; TypeTuple!("+", "-", "*", "/", "%", "^^", "&",
                "|", "^", "<<", ">>", ">>>", "~"))
    {
        auto r = mixin("obj[4 .. 7.5] " ~ op ~ "= 42");
        assert(r.Algebraic.isActive!Tag);
        assert(eq( r.Algebraic.instance!Tag, Tag(op, 42, 4, 7.5) ));

        auto s = mixin("obj[] " ~ op ~ "= 42");
        assert(s.Algebraic.isActive!Tag);
        assert(eq( s.Algebraic.instance!Tag, Tag(op, 42, -1, -1) ));
    }
}

unittest
{
    // opSliceOpAssign (empty, undefined)
    Algebraic!(int, int[]) obj;

    assert(fails( obj[0 .. 1] += 1 ));
    assert(fails( obj[]       -= 2 ));
    obj = 42;
    assert(fails( obj[2 .. 3] *= 3 ));
    assert(fails( obj[]       /= 4 ));
}

unittest
{
    // opIndex
    struct Tag { int i; real j; }
    struct OpEcho {
        Tag opIndex(int i, real j) {
            return Tag(i, j);
        }
    }
    Algebraic!(OpEcho) obj;

    obj = OpEcho();
    auto r = obj[4, 9.5];
    assert(r.Algebraic.isActive!Tag);
    assert(eq( r.Algebraic.instance!Tag, Tag(4, 9.5) ));
}

unittest
{
    // opIndex (empty, undefined)
    Algebraic!(int, int[]) obj;

    assert(fails( obj[0] ));
    obj = 42;
    assert(fails( obj[2] ));
}

unittest
{
    // opSlice
    struct Tag { int i; real j; }
    struct OpEcho {
        Tag opSlice(int i, real j) {
            return Tag(i, j);
        }
        Tag opSlice() {
            return Tag(-1, -1);
        }
    }
    Algebraic!(OpEcho) obj;

    obj = OpEcho();
    auto r = obj[4 .. 9.5];
    assert(r.Algebraic.isActive!Tag);
    assert(eq( r.Algebraic.instance!Tag, Tag(4, 9.5) ));

    auto s = obj[];
    assert(s.Algebraic.isActive!Tag);
    assert(eq( s.Algebraic.instance!Tag, Tag(-1, -1) ));
}

unittest
{
    // opSlice (empty, undefined)
    Algebraic!(int, int[]) obj;

    assert(fails( obj[0 .. 1] ));
    assert(fails( obj[] ));
    obj = 42;
    assert(fails( obj[2 .. 3] ));
    assert(fails( obj[] ));
}

/+
unittest
{
    // opApply
    struct OpEcho {
        int opApply(int delegate(ref size_t, ref real) dg)
        {
            foreach (i, ref e; [ 1.L, 2.5L, 5.5L ])
                if (auto r = dg(i, e))
                    return r;
            return 0;
        }
    }
    Algebraic!(OpEcho) obj;

    obj = OpEcho();
    foreach (size_t i, ref real e; obj)
        assert(e == [ 1.L, 2.5L, 5.5L ][i]);
}
+/

//-------------- special functions

unittest
{
    // toString
    Algebraic!(int, string, Object) obj;
    obj.toString();

    obj = 42;
    assert(obj.toString() == "42");

    obj = "The quick brown...";
    assert(obj.toString() == "The quick brown...");

    obj = new class { string toString() { return "mew"; } };
    assert(obj.toString() == "mew");

    assert(to!string(obj) == "mew");
}

unittest
{
    // toHash
    Algebraic!(string, Object) obj;
    obj.toHash();

    obj = "I'm in a box.";
    obj.toHash();

    obj = new class { hash_t toHash() { return 42; } };
    assert(obj.toHash() == 42);
}

//-------------- misc

unittest
{
    // class object
    class A {
        int foo(int a, int b) { return a + b; }
    }
    struct B {
        int foo(int a, int b) { return a * b; }
    }
    Algebraic!(A, B) ab;

    ab = new A;
    {
        auto c = ab;
        assert(c.foo(2, 3) == 5);
    }
    assert(ab.foo(4, 5) == 9);

    ab = B();
    assert(ab.foo(6, 7) == 42);
}

unittest
{
    // associative array
    Algebraic!(int[string], real[string]) map;

    map = (int[string]).init;
    map["abc"] = 42;
    assert(("abc" in map) != null);
    assert(map["abc"] == 42);
    map.rehash;
    assert(map.length == 1);

    map = (real[string]).init;
    map["xyz"] = 3.5;
    assert(("xyz" in map) != null);
    assert(map["xyz"] == 3.5);
    map.rehash;
    assert(map.length == 1);
}


