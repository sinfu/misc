/*
 * ダックタイプされた構造体を実行時に切り替える
 */

import std.algorithm;
import std.contracts;
import std.conv;
import std.stdio;
import std.traits;


void main()
{
    Homogeneous!(FileOutputStream, MemoryOutputStream) sink;
    ubyte[] buffer;
    ubyte[] dummy;

    assert(sink.Homogeneous.empty);

    // MemoryOutputStream をセット
    sink = MemoryOutputStream(&buffer);
    sink.write(dummy = [ 61,62,63,64 ]);

    assert(sink.Homogeneous.contains!MemoryOutputStream);
    assert(sink.Homogeneous.instance!MemoryOutputStream.buffer_ is &buffer);

    // 実行時，FileOutputStream に切り替える
    sink = FileOutputStream(stdout);
    sink.write(dummy = [ 65,66,67,68 ]); // "ABCD"
    sink.write(dummy = [ 10 ]);

    assert(sink.Homogeneous.contains!FileOutputStream);
    assert(sink.Homogeneous.instance!FileOutputStream.file_ is stdout);

    // 正しくコピー & 破壊
    {
        auto dup = sink;
        dup.write(dummy = [ 97,98,99,100 ]);
        dup.write(dummy = [ 10 ]);
    }

    // MemoryOutputStream の結果… ちゃんと切り替わっている
    assert(buffer == [ 61,62,63,64 ]);
}

struct FileOutputStream
{
    File file_;
    int* rc_;

    size_t write(in ubyte[] data)
    {
        file_.rawWrite(data);
        return data.length;
    }
    void flush() { file_.flush(); }
    void close() { file_.close(); }

    this(File file)
    {
        file_ = file;
        rc_   = new int;
        writeln(++*rc_, " # FileOutputStream   this");
    }
    this(this)
    {
        writeln(++*rc_, " > FileOutputStream   this(this)");
    }
    ~this()
    {
        if (rc_)
        writeln(--*rc_, " < FileOutputStream   ~this");
    }
}

struct MemoryOutputStream
{
    ubyte[]* buffer_;
    int*     rc_;

    size_t write(in ubyte[] data)
    {
        *buffer_ ~= data;
        return data.length;
    }
    void flush() {}
    void close() {}

    this(ubyte[]* buffer)
    {
        buffer_ = buffer;
        rc_     = new int;
        writeln(++*rc_, " # MemoryOutputStream this");
    }
    this(this)
    {
        writeln(++*rc_, " > MemoryOutputStream this(this)");
    }
    ~this()
    {
        if (rc_)
        writeln(--*rc_, " < MemoryOutputStream ~this");
    }
}


//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://

private @system void initStorage(T)(ref T obj)
{
    auto init = typeid(T).init;
    if (init.ptr)
        (cast( void*) &obj)[0 .. T.sizeof] = init[];
    else
        (cast(ubyte*) &obj)[0 .. T.sizeof] = 0;
}


@system struct Homogeneous(Ducks...)
{
    auto ref opDispatch(string op, Args...)(auto ref Args args)
    {
        enforce(which_ != size_t.max, op ~ Args.stringof);

        enum string dispatch = "storageAs!Duck()."
                ~ (args.length == 0 ? op : op ~ "(args)");

        final switch (which_)
        {
            foreach (Duck; Ducks)
            {
            case duckID!Duck:
                static if (__traits(compiles, typeof(mixin(dispatch))))
                    return mixin(dispatch);
                else
                    enforce(0, Duck.stringof ~ "." ~ op ~ Args.stringof);
                assert(0);
            }
        }
        assert(0);
    }


    this(this)
    {
        if (which_ != size_t.max)
            postblit();
    }

    ~this()
    {
        if (which_ != size_t.max)
            dispose();
    }


    // @@@BUG@@@
    // Error: function opAssign conflicts with template opAssign(T)
    private template _workaround_()
        { @disable void opAssign(...) { assert(0); } }
    mixin _workaround_ _dummy_opAssign;

    void opAssign(T : typeof(this))(T rhs)
    {
        swap(this, rhs);
    }

    void opAssign(T)(T rhs)
    {
        if (which_ == size_t.max)
            grab(rhs);
        else
            replace(rhs);
    }

    //
    mixin _MetaInterface Homogeneous;


    //----------------------------------------------------------------//
private:

    template _MetaInterface()
    {
        @safe @property bool empty() const nothrow
        {
            return which_ == size_t.max;
        }

        template allowed(T)
        {
            enum allowed = (duckID!T != size_t.max);
        }

        @safe bool contains(T)() const nothrow
        {
            return which_ != size_t.max && which_ == duckID!T;
        }

        @property ref T instance(T)()
        {
            static if (duckID!T != size_t.max)
            {
                enforce(which_ != size_t.max, "unset");
                enforce(which_ == duckID!T);
                return storageAs!T;
            }
            else static assert(0, ".");
        }

        T get(T)()
        {
            enforce(which_ != size_t.max, "unset");

            final switch (which_)
            {
                foreach (Duck; Ducks)
                {
                case duckID!Duck:
                    static if (isImplicitlyConvertible!(Duck, T))
                        return storageAs!T;
                    else
                        enforce(0, "inconvertible "
                                ~ Duck.stringof ~ " -> "
                                ~ T.stringof);
                    assert(0);
                }
            }
        }

        void clear()
        {
            if (which_ != size_t.max)
                dispose();
        }
    }


    template duckID(T, size_t id = 0)
    {
        static if (id < Ducks.length)
        {
            static if (is(T == Ducks[id]))
                enum duckID = id;
            else
                enum duckID = duckID!(T, id + 1);
        }
        else
        {
            enum duckID = size_t.max;
        }
    }


    void grab(T)(ref T rhs)
    in
    {
        assert(which_ == size_t.max);
    }
    body
    {
        static if (duckID!T != size_t.max)
        {
            swap(storageAs!T, rhs);
            which_ = duckID!T;
        }
        else
        {
            foreach (Duck; Ducks)
            {
                static if (__traits(compiles, storageAs!Duck() = rhs))
                {
                    which_ = duckID!Duck;
                    initStorage(storageAs!Duck());
                    storageAs!Duck() = rhs;
                    break;
                }
            }
        }
    }

    void replace(T)(ref T rhs)
    in
    {
        assert(which_ != size_t.max);
    }
    body
    {
        final switch (which_)
        {
            foreach (Duck; Ducks)
            {
            case duckID!Duck:
                static if (__traits(compiles, storageAs!Duck() = rhs))
                    return storageAs!Duck() = rhs;
                else
                    break;
            }
        }

        foreach (Duck; Ducks)
        {
            static if (__traits(compiles, storageAs!Duck() = rhs))
            {
                dispose();
                which_ = duckID!Duck;
                initStorage(storageAs!Duck());
                swap(storageAs!Duck(), rhs);
                break;
            }
        }
    }


    ref T storageAs(T)()
        if (duckID!T != size_t.max)
    {
        foreach (Duck; Ducks)
        {
            static if (duckID!T == duckID!Duck)
                return *cast(Duck*) storage_.ptr;
        }
        assert(0);
    }

    void postblit()
    in
    {
        assert(which_ != size_t.max);
    }
    body
    {
        final switch (which_)
        {
            foreach (Duck; Ducks)
            {
            case duckID!Duck:
                static if (__traits(compiles, storageAs!Duck().__postblit()))
                    storageAs!Duck().__postblit();
                return;
            }
        }
    }

    void dispose()
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
        final switch (which_)
        {
            foreach (Duck; Ducks)
            {
            case duckID!Duck:
                static if (is(Duck == struct) || is(Duck == union))
                    .clear(storageAs!Duck());
                which_ = size_t.max;
                return;
            }
        }
    }

    //----------------------------------------------------------------//
private:
    size_t which_ = size_t.max;
    union
    {
        ubyte[_maxSize!(0, Ducks)]                  storage_;
        void*[_maxSize!(0, Ducks) / (void*).sizeof] mark_;
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

