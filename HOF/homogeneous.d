/**
 * Run-time polymorphic access to duck-typed objects
 *
 * Macros:
 *   D = $(I $1)
 */
module homogeneous;

void main()
{
    demo();
}


//----------------------------------------------------------------------------//
// Demo
//----------------------------------------------------------------------------//

import std.stdio;

void demo()
{
    Homogeneous!(FileStream, MemoryStream) sink;

    assert(sink.Homogeneous.empty);

    // Set a MemoryStream.
    auto memst = MemoryStream(512);
    sink = memst;
    sink.write("This is written to the memory.\n");

    assert(sink.Homogeneous.isActive!MemoryStream);
    assert(sink.Homogeneous.instance!MemoryStream.data ==
            "This is written to the memory.\n");

    // Switch to a FileStream at run time.
    sink = FileStream(stdout);
    sink.write("This is written to the stdout.\n");

    assert(sink.Homogeneous.isActive!FileStream);

    // Copy constructor and destructor.
    {
        auto cpsink = sink;
        cpsink.write("Hello from the copy of the sink.\n");
        sink = cpsink;
    }

    // The sink is still alive.
    sink.write("Good bye.\n");
}

// Demo
struct MemoryStream
{
    char[] buffer;
    size_t pos;
    int*   rc;

    this(size_t size)
    {
        buffer = new char[size];
        rc     = new int;
        writeln("\t", ++*rc, " # MemoryStream this()");
    }

    this(this)
    {
        writeln("\t", ++*rc, " > MemoryStream this(this)");
    }

    ~this()
    {
        if (rc)
            writeln("\t", --*rc, " < MemoryStream ~this()");
    }

    void write(in char[] data)
    {
        buffer[pos .. pos + data.length] = data[];
        pos += data.length;
    }

    char[] data()
    {
        return buffer[0 .. pos];
    }
}

// Demo
struct FileStream
{
    File file;
    int* rc;

    this(File f)
    {
        file = f;
        rc   = new int;
        writeln("\t", ++*rc, " # FileStream this()");
    }

    this(this)
    {
        writeln("\t", ++*rc, " > FileStream this(this)");
    }

    ~this()
    {
        if (rc)
            writeln("\t", --*rc, " < FileStream ~this()");
    }

    void write(in char[] data)
    {
        file.rawWrite(data);
    }
}


////////////////////////////////////////////////////////////////////////////////
// Homogeneous
////////////////////////////////////////////////////////////////////////////////

import std.algorithm;   // swap
import std.array;       // empty, front, popFront
import std.conv;

version (unittest) import std.typetuple : TypeTuple;


/**
 * Provides run-time polymorphic access to a specific group of duck-typed
 * objects.
 *
 * Example:
--------------------
Homogeneous!(FileWriter, MemoryWriter) writer;

// Set a writer object
writer = FileWriter("output.dat");
writer.write("This is written to the file.");

// Switch to another writer
writer = MemoryWriter();
writer.write("This is written to the memory.");

// Access to a MemoryWriter-specific member
assert(writer.Homogeneous.instance!MemoryWriter.data
        == "This is written to the memory.");
--------------------
 */
struct Homogeneous(Ducks...)
{
    /**
     * Invokes the method $(D op) on the active object.
     *
     * The allowed operation $(D op) is the intersection of the allowed
     * operations on all $(D Ducks).
     *
     * Throws:
     * $(UL
     *   $(LI $(D Error) if this $(D Homogeneous) object is empty)
     * )
     */
    @system auto ref opDispatch(string op, Args...)(auto ref Args args)
        if (_canDispatch!(op, Args))
    {
        if (which_ == size_t.max)
            throw new Error("dispatching " ~ op ~ Args.stringof
                    ~ " on an empty " ~ typeof(this).stringof);

        mixin (_onActiveDuck!(
            q{
                return mixin("storageAs!Duck()."
                        ~ (args.length == 0 ? op : op ~ "(args)"));
            }));
        assert(0);
    }


    /**
     * If $(D T) is one of the $(D Ducks), alters the contained object
     * with $(D rhs); otherwise assigns $(D rhs) on the active object.
     */
    @system void opAssign(T)(T rhs)
        if (_canAssign!(T))
    {
        if (which_ == size_t.max)
            grab(rhs);
        else
            assign(rhs);
    }

    // @@@BUG4424@@@ workaround
    @trusted void opAssign(T)(T rhs) if (is(T == typeof(this)))
        { swap(this, rhs); }
    private template _workaround4424()
        { @disable void opAssign(...) { assert(0); } }
    mixin _workaround4424 _workaround4424_;


    //----------------------------------------------------------------//
    // operator overloads
    //----------------------------------------------------------------//

    @system auto ref opUnary(string op)()
    {
        if (which_ == size_t.max)
            throw new Error("unary " ~ op ~ " on an empty "
                    ~ typeof(this).stringof);

        mixin (_onActiveDuck!(
            q{
                return mixin(op ~ "storageAs!Duck");
            }));
        assert(0);
    }

    @system auto ref opIndexUnary(string op, Indices...)(Indices indices)
    {
        if (which_ == size_t.max)
            throw new Error("unary " ~ to!string(Indices.length)
                    ~ "-indexing " ~ op ~ " on an empty "
                    ~ typeof(this).stringof);

        mixin (_onActiveDuck!(
            q{
                return mixin(op ~ "storageAs!Duck[" ~
                        _commaExpand!("indices", Indices.length) ~ "]");
            }));
        assert(0);
    }

    @system auto ref opSliceUnary(string op, I, J)(I i, J j)
    {
        if (which_ == size_t.max)
            throw new Error("unary slicing " ~ op ~ " on an empty "
                    ~ typeof(this).stringof);

        mixin (_onActiveDuck!(
            q{
                return mixin(op ~ "storageAs!Duck[i .. j]");
            }));
        assert(0);
    }

    @system auto ref opSliceUnary(string op)()
    {
        if (which_ == size_t.max)
            throw new Error("unary slicing " ~ op ~ " on an empty "
                    ~ typeof(this).stringof);

        mixin (_onActiveDuck!(
            q{
                return mixin(op ~ "storageAs!Duck[]");
            }));
        assert(0);
    }

    @system auto ref opCast(T)()
    {
        if (which_ == size_t.max)
            throw new Error("casting an empty " ~ typeof(this).stringof
                    ~ " to " ~ T.stringof);

        mixin (_onActiveDuck!(
            q{
                static if (is(T == Duck))
                    return         storageAs!Duck;
                else
                    return cast(T) storageAs!Duck;
            }));
        assert(0);
    }

    @system auto ref opBinary(string op, RHS)(RHS rhs)
    {
        if (which_ == size_t.max)
            throw new Error("binary " ~ op ~ " on an empty LHS "
                    ~ typeof(this).stringof ~ " and RHS " ~ RHS.stringof);

        mixin (_onActiveDuck!(
            q{
                return mixin("storageAs!Duck() " ~ op ~ " rhs");
            }));
        assert(0);
    }

    @system auto ref opBinaryRight(string op, LHS)(LHS lhs)
    {
        if (which_ == size_t.max)
            throw new Error("binary " ~ op ~ " on LHS " ~ LHS.stringof
                    ~ "and an empty RHS " ~ typeof(this).stringof);

        mixin (_onActiveDuck!(
            q{
                return mixin("lhs " ~ op ~ "storageAs!Duck");
            }));
        assert(0);
    }

    @system bool opEquals(RHS)(auto ref RHS rhs) const
    {
        if (which_ == size_t.max)
            throw new Error("comparing an empty " ~ typeof(this).stringof
                    ~ " with " ~ RHS.stringof);

        mixin (_onActiveDuck!(
            q{
                return storageAs_const!Duck() == rhs;
            }));
        assert(0);
    }

    @system bool opEquals(RHS : typeof(this))(ref const RHS rhs) const
    {
        if (which_ != size_t.max && which_ == rhs.which_)
        {
            mixin (_onActiveDuck!(
                q{
                    return storageAs_const!Duck() == rhs.storageAs_const!Duck;
                }));
            assert(0);
        }
        else
        {
            return false;
        }
    }

    @system int opCmp(RHS)(auto ref RHS rhs) const
    {
        if (which_ == size_t.max)
            throw new Error("comparing an empty " ~ typeof(this).stringof
                    ~ " with " ~ RHS.stringof);

        mixin (_onActiveDuck!(
            q{
                return (storageAs_const!Duck < rhs) ? -1 :
                       (storageAs_const!Duck > rhs) ?  1 : 0;
            }));
        assert(0);
    }

    @system int opCmp(RHS : typeof(this))(ref const RHS rhs) const
    {
        if (which_ == size_t.max || rhs.which_ == size_t.max)
            throw new Error("comparing empty " ~ typeof(this).stringof
                    ~ " objects");

        mixin (_onActiveDuck!(
            q{
                return -rhs.opCmp(storageAs_const!Duck);
            }));
        assert(0);
    }

    @system auto ref opCall(Args...)(auto ref Args args)
    {
        if (which_ == size_t.max)
            throw new Error("calling an empty " ~ typeof(this).stringof
                    ~ " object");

        mixin (_onActiveDuck!(
            q{
                return storageAs!Duck()(args);
            }));
        assert(0);
    }

    @system auto ref opOpAssign(string op, RHS)(RHS rhs)
    {
        mixin (_onActiveDuck!(
            q{
                return mixin("storageAs!Duck() " ~ op ~ "= rhs");
            }));
        assert(0);
    }

    @system auto ref opIndexOpAssign(string op, RHS, Indices...)
        (RHS rhs, Indices indices)
    {
        mixin (_onActiveDuck!(
            q{
                return mixin("storageAs!Duck[" ~
                        _commaExpand!("indices", Indices.length) ~
                    "] " ~ op ~ "= rhs");
            }));
        assert(0);
    }

    @system auto ref opSliceOpAssign(string op, RHS, I, J)(RHS rhs, I i, J j)
    {
        mixin (_onActiveDuck!(
            q{
                return mixin("storageAs!Duck[i .. j] " ~ op ~ "= rhs");
            }));
        assert(0);
    }

    @system auto ref opSliceOpAssign(string op)(RHS rhs)
    {
        mixin (_onActiveDuck!(
            q{
                return mixin("storageAs!Duck[] " ~ op ~ "= rhs");
            }));
        assert(0);
    }

    @system auto ref opIndex(Indices...)(Indices indices)
    {
        mixin (_onActiveDuck!(
            q{
                return mixin("storageAs!Duck[" ~
                    _commaExpand!("indices", Indices.length) ~ "]");
            }));
        assert(0);
    }

    @system auto ref opSlice(I, J)(I i, J j)
    {
        mixin (_onActiveDuck!(
            q{
                return storageAs!Duck[i .. j];
            }));
        assert(0);
    }

    @system auto ref opSlice(_Dummy = void)()
    {
        mixin (_onActiveDuck!(
            q{
                return storageAs!Duck[];
            }));
        assert(0);
    }


    //----------------------------------------------------------------//
    // managing stored object
    //----------------------------------------------------------------//

    /**
     * Invokes the copy constructor on the active object if any.
     */
    @system this(this)
    {
        if (which_ != size_t.max)
            postblit();
    }


    /**
     * Invokes the destructor on the active object if any.
     */
    @system ~this()
    {
        if (which_ != size_t.max)
            dispose();
    }


    /**
     * The $(D Homogeneous) namespace provides various 'meta' methods
     * for operating on this $(D Homogeneous) object itself, not a
     * contained object.
     *
     * Example:
--------------------
Homogeneous!(A, B) ab;

assert(ab.Homogeneous.empty);
assert(ab.Homogeneous.allows!A);

ab = A();
assert(ab.Homogeneous.isActive!A);

A a = ab.Homogeneous.instance!A;
--------------------
     */
    template _Homogeneous()
    {
        /**
         * A tuple of types that are considered homogeneous in this
         * object, i.e. the $(D Ducks).
         */
        alias Ducks Types;


        /**
         * Returns $(D true) if type $(D T) is listed in the homogeneous
         * type list $(D Types).
         */
        template allows(T) // FIXME the name
        {
            enum bool allows = _homogenizes!T;
        }


        /**
         * Returns $(D true) if this $(D Homogeneous) object contains
         * nothing.
         */
        @safe @property bool empty() const nothrow
        {
            return which_ == size_t.max;
        }


        /**
         * Returns $(D true) if the type of the active object is $(D T).
         */
        @safe bool isActive(T)() const nothrow
        {
            return which_ != size_t.max && which_ == duckID!T;
        }


        /**
         * Touch the active object directly (by ref).  The type $(D T)
         * must be the active one, i.e. $(D isActive!T == true).
         *
         * Throws:
         * $(UL
         *   $(LI $(D assertion) fails if the $(D Homogeneous) object is
         *        empty or $(D T) is not active)
         * )
         */
        @trusted @property ref T instance(T)() nothrow
            if (allows!(T))
        in
        {
            assert(which_ == duckID!T);
        }
        body
        {
            return storageAs!T;
        }
        /+ // @@@BUG3748@@@
        @trusted @property ref inout(T) instance(T)() inout nothrow
        +/
    }

    /// Ditto
    alias _Homogeneous!() Homogeneous;


    //----------------------------------------------------------------//
    // internals
    //----------------------------------------------------------------//
private:

    /*
     * Determines if the operation $(D op) is supported on all the ducks
     * and the return types are compatible.
     */
    template _canDispatch(string op, Args...)
    {
        enum bool _canDispatch = __traits(compiles,
                function(Args args)
                {
                    // The operation must be supported by all ducks, and
                    // the return types must be compatible.
                    foreach (Duck; Ducks)
                    {
                        Duck duck;
                        static if (Args.length == 0)
                            return mixin("duck." ~ op);
                        else
                            return mixin("duck." ~ op ~ "(args)");
                    }
                    assert(0);
                });
    }


    /*
     * Determines if a value of $(D T) can be assigned to at least one
     * of the ducks.
     */
    template _canAssign(T, size_t i = 0)
    {
        static if (i < Ducks.length)
            enum bool _canAssign = __traits(compiles,
                    function(ref Ducks[i] duck, T rhs)
                    {
                        duck = rhs;
                    })
                || _canAssign!(T, i + 1);
        else
            enum bool _canAssign = false;
    }

    unittest
    {
        foreach (Duck; Ducks)
            assert(_canAssign!(Duck));
        struct Unknown {}
        assert(!_canAssign!(Unknown));
    }


    /*
     * Returns $(D true) if the type $(D T) is in the set of homogeneous
     * types $(D Ducks).
     */
    template _homogenizes(T)
    {
        enum bool _homogenizes = (duckID!T != size_t.max);
    }

    unittest
    {
        foreach (Duck; Ducks)
            assert(_homogenizes!(Duck));
        struct Unknown {}
        assert(!_homogenizes!(Unknown));
    }


    /*
     * Returns the ID of the duck of type $(D T), or $(D size_t.max) if
     * $(D T) is not in the set of homogeneous types.
     */
    template duckID(T, size_t id = 0)
    {
        static if (id < Ducks.length)
        {
            static if (is(T == Ducks[id]))
                enum size_t duckID = id;
            else
                enum size_t duckID = duckID!(T, id + 1);
        }
        else
        {
            enum size_t duckID = size_t.max;
        }
    }


    /*
     * Generates code for operating on the active duck.
     */
    template _onActiveDuck(string stmt)
    {
        enum string _onActiveDuck =
                "assert(which_ != size_t.max);" ~
            "L_chooseActive:" ~
                "final switch (which_) {" ~
                    "foreach (Duck; Ducks) {" ~
                        "case duckID!Duck:" ~
                            stmt ~
                            "break L_chooseActive;" ~
                    "}" ~
                "}";
    }


    /*
     * Set $(D rhs) in the storage.
     */
    @trusted void grab(T)(ref T rhs)
    in
    {
        assert(which_ == size_t.max);
    }
    body
    {
        static if (_homogenizes!(T))
        {
            // Simple blit.
            _init(storageAs!T);
            swap(storageAs!T, rhs);
            which_ = duckID!T;
        }
        else
        {
            // Use the first-matching opAssign.
            foreach (Duck; Ducks)
            {
                static if (__traits(compiles, storageAs!Duck() = rhs))
                {
                    _init(storageAs!Duck);
                    storageAs!Duck() = rhs;
                    which_ = duckID!Duck;
                    break;
                }
            }
        }
    }


    /*
     * Assigns $(D rhs) to the existing active object.
     */
    @trusted void assign(T)(ref T rhs)
    in
    {
        assert(which_ != size_t.max);
    }
    body
    {
        mixin (_onActiveDuck!(
            q{
                static if (__traits(compiles, storageAs!Duck() = rhs))
                    return storageAs!Duck() = rhs;
            }));

        // Or, alter the content with rhs.
        dispose();
        grab(rhs);
    }


    /*
     * Returns a reference to the holded object as an instance of
     * type $(D T).  This does not validate the type.
     */
    @system ref T storageAs(T)() nothrow
        if (_homogenizes!(T))
    {
        foreach (Duck; Ducks)
        {
            static if (duckID!T == duckID!Duck)
                return *cast(Duck*) storage_.ptr;
        }
        assert(0);
    }
    /+ // @@@BUG3748@@@
    @system ref inout(T) storageAs(T)() inout nothrow
    +/
    @system ref const(T) storageAs_const(T)() const nothrow
        if (_homogenizes!(T))
    {
        foreach (Duck; Ducks)
        {
            static if (duckID!T == duckID!Duck)
                return *cast(const Duck*) storage_.ptr;
        }
        assert(0);
    }



    /*
     * Runs the copy constructor on the active object.
     */
    @trusted void postblit()
    in
    {
        assert(which_ != size_t.max);
    }
    body
    {
        mixin (_onActiveDuck!(
            q{
                static if (__traits(compiles, storageAs!Duck().__postblit()))
                    storageAs!Duck().__postblit();
                return;
            }));
        assert(0);
    }


    /*
     * Destroys the active object (if it's a struct) and markes this
     * $(D Homogeneous) object empty.
     */
    @trusted void dispose()
    in
    {
        assert(which_ != size_t.max);
    }
    out
    {
        assert(which_ == size_t.max);
    }
    body
    {
        mixin (_onActiveDuck!(
            q{
                static if (__traits(compiles, storageAs!Duck.__dtor()))
                    storageAs!Duck.__dtor();
                which_ = size_t.max;
                return;
            }));
        assert(0);
    }


    //----------------------------------------------------------------//

    // @@@BUG@@@ workaround
    static if (_canDispatch!("front") && _canDispatch!("empty") &&
            _canDispatch!("popFront"))
    public @system
    {
        @property bool empty()
        {
            return opDispatch!("empty")();
        }
        @property auto ref front()
        {
            return opDispatch!("front")();
        }
        void popFront()
        {
            opDispatch!("popFront")();
        }
    }


    //----------------------------------------------------------------//
private:
    size_t which_ = size_t.max;     // ID of the 'active' Duck
    union
    {
        ubyte[_maxSize!(0, Ducks)]                  storage_;
        void*[_maxSize!(0, Ducks) / (void*).sizeof] mark_;
        // XXX too conservative?
    }
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
    Homogeneous!(Counter) a;
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
    Homogeneous!(A, B) ab;
    ab = A();
    assert(ab.inc() == 1 && afoo == 1);
    assert(ab.dec() == 0 && afoo == 0);
    ab = B();
    assert(ab.inc() == -1 && bfoo == -1);
    assert(ab.dec() ==  0 && bfoo ==  0);
}

unittest
{
    // ref argument & ref return
    struct K {
        ref int foo(ref int a, ref int b) { ++b; return a; }
    }
    Homogeneous!(K) k;
    int v, w;
    k = K();
    assert(&(k.foo(v, w)) == &v);
    assert(w == 1);
}

unittest
{
    // meta interface
    Homogeneous!(int, real) a;

    assert(is(a.Homogeneous.Types == TypeTuple!(int, real)));
    assert(a.Homogeneous.allows!int);
    assert(a.Homogeneous.allows!real);
    assert(!a.Homogeneous.allows!string);

    assert(a.Homogeneous.empty);

    a = 42;
    assert(!a.Homogeneous.empty);
    assert( a.Homogeneous.isActive!int);
    assert(!a.Homogeneous.isActive!real);
    assert(!a.Homogeneous.isActive!string);
    int* i = &(a.Homogeneous.instance!int());
    assert(*i == 42);

    a = -21.0L;
    assert(!a.Homogeneous.empty);
    assert(!a.Homogeneous.isActive!int);
    assert( a.Homogeneous.isActive!real);
    assert(!a.Homogeneous.isActive!string);
    real* r = &(a.Homogeneous.instance!real());
    assert(*r == -21.0L);

    a = a.init;
    assert(a.Homogeneous.empty);
}

unittest
{
    // implicit convertion
    Homogeneous!(real, const(char)[]) a;
    a = 42;
    assert(a.Homogeneous.isActive!real);
    a = "abc";
    assert(a.Homogeneous.isActive!(const(char)[]));
}

unittest
{
    // foreach over input range
    Homogeneous!(string, wstring) str;

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
}

//--------------------------------------------------------------------//
// operator overloads

version (unittest) private bool eq(S)(S a, S b)
{
    foreach (i, _; a.tupleof)
    {
        if (a.tupleof[i] != b.tupleof[i])
            return false;
    }
    return true;
}

version (unittest) private bool fails(lazy void expr)
{
    try { expr; } catch (Error e) { return true; }
    return false;
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
    Homogeneous!(OpEcho) obj;

    obj = OpEcho();
    foreach (op; TypeTuple!("+", "-", "~", "*", "++", "--"))
    {
        auto r = mixin(op ~ "obj");
        assert(eq( r, Tag(op) ));
    }
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
    Homogeneous!(OpEcho) obj;

    obj = OpEcho();
    foreach (op; TypeTuple!("+", "-", "~", "*", "++", "--"))
    {
        auto r = mixin(op ~ "obj[4, 2.5]");
        assert(eq( r, Tag(op, 4, 2.5) ));
    }
}

unittest
{
    // opSliceUnary
    struct Tag { string op; int x; real y; }
    struct OpEcho {
        Tag opSliceUnary(string op)(int x, real y) {
            return Tag(op, x, y);
        }
    }
    Homogeneous!(OpEcho) obj;

    obj = OpEcho();
    foreach (op; TypeTuple!("+", "-", "~", "*", "++", "--"))
    {
        auto r = mixin(op ~ "obj[4 .. 5.5]");
        assert(eq( r, Tag(op, 4, 5.5) ));
    }
}

unittest
{
    // opCast
    struct OpEcho {
        T opCast(T)() { return T.init; }
    }
    Homogeneous!(OpEcho) obj;

    obj = OpEcho();
    foreach (T; TypeTuple!(int, string, OpEcho))
    {
        auto r = cast(T) obj;
        assert(is(typeof(r) == T));
    }
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
    Homogeneous!(OpEcho) obj;

    obj = OpEcho();
    foreach (op; TypeTuple!("+", "-", "*", "/", "%", "^^", "&",
                "|", "^", "<<", ">>", ">>>", "~"/+, "in" @@@BUG@@@+/))
    {
        auto r = mixin("obj " ~ op ~ " 42");
        assert(eq( r, LTag(op, 42) ));
        auto s = mixin("76 " ~ op ~ " obj");
        assert(eq( s, RTag(op, 76) ));
    }
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
    Homogeneous!(Dummy) obj;

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
    Homogeneous!(Dummy!0, Dummy!1) a, b;

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
    Homogeneous!(Dummy) a;

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
    Homogeneous!(Dummy!0, Dummy!1) a, b;

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
    // opCall
    struct Tag { int x; real y; }
    struct OpEcho {
        Tag opCall(int x, real y) {
            return Tag(x, y);
        }
    }
    Homogeneous!(OpEcho) obj;

//  obj = OpEcho(); // @@@BUG@@@
    obj = OpEcho.init;
    auto r = obj(4, 8.5);
    assert(r == Tag(4, 8.5));
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
    Homogeneous!(OpEcho) obj;

    obj = OpEcho();
    foreach (op; TypeTuple!("+", "-", "*", "/", "%", "^^", "&",
                "|", "^", "<<", ">>", ">>>", "~"))
    {
        auto r = mixin("obj " ~ op ~ "= 97");
        assert(eq( r, Tag(op, 97) ));
    }
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
    Homogeneous!(OpEcho) obj;

    obj = OpEcho();
    foreach (op; TypeTuple!("+", "-", "*", "/", "%", "^^", "&",
                "|", "^", "<<", ">>", ">>>", "~"))
    {
        auto r = mixin("obj[4, 7.5] " ~ op ~ "= 42");
        assert(eq( r, Tag(op, 42, 4, 7.5) ));
    }
}

unittest
{
    // opSliceOpAssign
    struct Tag { string op; int v; int i; real j; }
    struct OpEcho {
        Tag opSliceOpAssign(string op)(int v, int i, real j) {
            return Tag(op, v, i, j);
        }
    }
    Homogeneous!(OpEcho) obj;

    obj = OpEcho();
    foreach (op; TypeTuple!("+", "-", "*", "/", "%", "^^", "&",
                "|", "^", "<<", ">>", ">>>", "~"))
    {
        auto r = mixin("obj[4 .. 7.5] " ~ op ~ "= 42");
        assert(eq( r, Tag(op, 42, 4, 7.5) ));
    }
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
    Homogeneous!(OpEcho) obj;

    obj = OpEcho();
    auto r = obj[4, 9.5];
    assert(eq( r, Tag(4, 9.5) ));
}

unittest
{
    // opSlice
    struct Tag { int i; real j; }
    struct OpEcho {
        Tag opSlice(int i, real j) {
            return Tag(i, j);
        }
    }
    Homogeneous!(OpEcho) obj;

    obj = OpEcho();
    auto r = obj[4 .. 9.5];
    assert(eq( r, Tag(4, 9.5) ));
}


//----------------------------------------------------------------------------//

private @trusted void _init(T)(ref T obj)
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

private template _maxSize(size_t max, TT...)
{
    static if (TT.length > 0)
    {
        static if (max < TT[0].sizeof)
            enum _maxSize = _maxSize!(TT[0].sizeof, TT[1 .. $]);
        else
            enum _maxSize = _maxSize!(         max, TT[1 .. $]);
    }
    else
    {
        enum _maxSize = max;
    }
}

private template _commaExpand(string array, size_t N)
    if (N >= 1)
{
    static if (N == 1)
        enum string _commaExpand = array ~ "[0]";
    else
        enum string _commaExpand = _commaExpand!(array, N - 1)
            ~ ", " ~ array ~ "[" ~ N.stringof ~ " - 1]";
}

