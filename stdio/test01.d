
void main()
{
    writefln("%s = %s", 'λ', "α∧β∧…∧γ");
}


//----------------------------------------------------------------------------//
// Free Functions
//----------------------------------------------------------------------------//
// void write   (        args...);
// void writeln (        args...);
// void writef  (format, args...);
// void writefln(format, args...);
//----------------------------------------------------------------------------//

/**
 * Writes objects $(D args) to the standard output in the default formatting.
 */
void write(Args...)(Args args)
{
    .stdout.write(args);
}

/// ditto
void writeln(Args...)(Args args)
{
    .stdout.writeln(args);
}


/**
 * Writes objects $(D args) to the standard output in the specified formatting.
 */
void writef(Format, Args...)(Format format, Args args)
{
    .stdout.writef(format, args);
}

/// ditto
void writefln(Format, Args...)(Format format, Args args)
{
    .stdout.writefln(format, args);
}


//----------------------------------------------------------------------------//
// StandardOutput
//----------------------------------------------------------------------------//
// shared StandardOutput stdout;
//
// struct StandardOutput
// {
// shared:
//     // Text writing capabilities
//     @property LockingTextWriter lockingTextWriter();
//
//     void write   (        args...);
//     void writeln (        args...);
//     void writef  (format, args...);
//     void writefln(format, args...);
//
//     // Binary writing capability
//     void rawWrite(T)(in T[] data);
//
//     // FILE interfaces
//     @property FILE* handle();
//     void flush();
//     bool error();
//     void clearerr();
// }
//----------------------------------------------------------------------------//

import std.array;
import std.exception;
import std.format;

import std.internal.stdio.nativechar;

import core.stdc.errno;
import core.stdc.stdio;
import core.stdc.wchar_;


/**
 * Standard output handle synchronized with C stdio functions.
 */
shared StandardOutput stdout;

shared static this()
{
    assumeUnshared(.stdout) = StandardOutput(core.stdc.stdio.stdout);
}


/**
 * Object for writing Unicode text to the standard output in console-safe
 * system encoding.
 */
@system struct StandardOutput
{
private:
    FILE*                handle_;
    NativeCodesetEncoder encoder_;

    this(FILE* handle)
    {
        handle_  = handle;
        encoder_ = NativeCodesetEncoder(ConversionMode.console);
    }
    // MSDN says that standard streams should use a console code page anyway:
    //   http://msdn.microsoft.com/en-us/goglobal/bb688114.aspx

public:
    //----------------------------------------------------------------//
    // Transcoded Text Writing Capabilities
    //----------------------------------------------------------------//

    /**
     * Returns an output range for writing text to a locked standard stream
     * in the console-safe character encoding.
     */
    @property LockingTextWriter lockingTextWriter() shared
    {
        return LockingTextWriter(handle_, encoder_);
    }

    /// ditto
    static struct LockingTextWriter
    {
    private:
        FILELockingByteWriter writer_;
        NativeCodesetEncoder  encoder_;

        this(FILE* handle, ref NativeCodesetEncoder encoder)
        {
            writer_  = FILELockingByteWriter(handle);
            encoder_ = assumeUnshared(encoder);
        }

    public:
        void put(in  char[] str) { encoder_.convertChunk(str, writer_); }
        void put(in wchar[] str) { encoder_.convertChunk(str, writer_); }
        void put(in dchar[] str) { encoder_.convertChunk(str, writer_); }
        void put(dchar c) { put((&c)[0 .. 1]); }
    }


    /**
     * Formatted writing to the stream.
     */
    void write(Args...)(Args args) shared
    {
        auto w = this.lockingTextWriter;
        foreach (i, Arg; Args)
            formattedWrite(w, "%s", args[i]);
    }

    /// ditto
    void writeln(Args...)(Args args) shared
    {
        write(args, '\n');
    }

    /// ditto
    void writef(Format, Args...)(Format format, Args args) shared
    {
        auto w = this.lockingTextWriter;
        formattedWrite(w, format, args);
    }

    /// ditto
    void writefln(Format, Args...)(Format format, Args args) shared
    {
        auto w = this.lockingTextWriter;
        formattedWrite(w, format, args);
        w.put('\n');
    }


    //----------------------------------------------------------------//
    // Raw Binary Writing Capability
    //----------------------------------------------------------------//

    /**
     * Writes $(D buffer) to the file.
     */
    void rawWrite(T)(in T[] buffer) shared
    {
        auto locker   = FILELocker(handle_);
        auto binscope = FILEBinmodeScope(handle_);

        for (const(E)[] rest = buffer; !rest.empty; )
        {
            immutable size_t consumed =
                fwrite(rest.ptr, T.sizeof, rest.length, locker.handle) / T.sizeof;

            if (consumed < rest.length)
                rest = rest[consumed .. $];
            else
                break;

            if (.ferror(locker.handle))
            {
                switch (errno)
                {
                  case EINTR:
                    .clearerr(locker.handle);
                    continue;

                  default:
                    throw new ErrnoException("");
                }
                assert(0);
            }
        }
    }


    //----------------------------------------------------------------//
    // FILE Interface
    //----------------------------------------------------------------//

    /**
     * Returns a $(D FILE*) for C stdio.
     */
    @property FILE* handle() shared nothrow
    {
        return handle_;
    }

    void flush() shared
    {
        .fflush(handle_);
    }

    bool error() shared
    {
        return .ferror(handle_) != 0;
    }

    void clearerr() shared
    {
        .clearerr(handle_);
    }
}


//----------------------------------------------------------------------------//
// FILE Locking Utilities
//----------------------------------------------------------------------------//
// struct FILELocker;               Abstracts flockfile() etc.
// struct FILELockingByteReader;    Input range for reading ubyte's.
// struct FILELockingByteWriter;    Output range for writing ubyte's.
// struct FILELockingWideReader;    Input range for reading wchar_t's.
// struct FILELockingWideWriter;    Output range for writing wchar_t's.
//----------------------------------------------------------------------------//

version (unittest) static import std.file;

private extern(C) @system
{
    version (Windows)
    {
        version (DigitalMars)
        {
            int    __fp_lock(FILE*);
            void   __fp_unlock(FILE*);
            int    _fgetc_nlock(FILE*);
            int    _fputc_nlock(int, FILE*);
            wint_t _fgetwc_nlock(FILE*);
            wint_t _fputwc_nlock(wint_t, FILE*);

            alias __fp_lock     flockfile;
            alias __fp_unlock   funlockfile;
            alias _fgetc_nlock  getc_unlocked;
            alias _fputc_nlock  putc_unlocked;
            alias _fgetwc_nlock getwc_unlocked;
            alias _fputwc_nlock putwc_unlocked;
        }
    }
    else version (Posix)
    {
        void   flockfile(FILE*);
        void   funlockfile(FILE*);
        int    getc_unlocked(FILE*);
        int    putc_unlocked(int, FILE*);
    }

    static if (!__traits(compiles, &flockfile))
    {
        void flockfile(FILE*) {}
        void funlockfile(FILE*) {}
        int getc_unlocked(       FILE* fp) { return fgetc(   fp); }
        int putc_unlocked(int c, FILE* fp) { return fputc(c, fp); }
    }

    static if (!__traits(compiles, &getwc_unlocked))
    {
        wint_t getwc_unlocked(           FILE* fp) { return fgetwc(    fp); }
        wint_t putwc_unlocked(wint_t ch, FILE* fp) { return fputwc(ch, fp); }
    }
}


/*
 * Manages a thread lock associated with a $(D FILE*) handle with reference
 * counting.
 */
private @system struct FILELocker
{
private:
    FILE* handle_;

public:
    /**
     * Locks $(D handle).  The constructor would block if another thread is
     * locking the same $(D handle).
     */
    this(FILE* handle)
    in
    {
        assert(handle);
    }
    body
    {
        flockfile(handle);
        handle_ = handle;
    }

    this(this)
    {
        if (handle_)
            flockfile(handle_);
    }

    ~this()
    {
        if (handle_)
            funlockfile(handle_);
    }


    //----------------------------------------------------------------//

    /**
     * Returns the locked $(D FILE*) _handle.
     */
    @property FILE* handle() nothrow
    {
        return handle_;
    }
}

unittest
{
    enum string deleteme = "deleteme";

    FILE* fp = fopen(deleteme, "w");
    assert(fp, "Cannot open file for writing");
    scope(exit) fclose(fp), std.file.remove(deleteme);

    // copy construction
    auto locker = FILELocker(fp);
    assert(locker.handle is fp);
    {
        auto copy1 = locker;
        auto copy2 = locker;
        assert(copy1.handle is fp);
        assert(copy2.handle is fp);
        {
            auto copyCopy1 = copy1;
            auto copyCopy2 = copy2;
            assert(copyCopy1.handle is fp);
            assert(copyCopy2.handle is fp);
        }
    }
}


//----------------------------------------------------------------------------//

/*
 * Input range for reading raw bytes from a locked $(D FILE*).
 */
@system struct FILELockingByteReader
{
private:
    struct State
    {
        ubyte front;
        bool  empty;
        bool  wantNext = true;
    }
    State*     state_;
    FILELocker locker_;

public:
    /**
     * Constructs a $(D FILELockingByteReader) on a valid file _handle.
     *
     * The file must not be wide oriented because using byte I/O functions
     * on a wide oriented stream leads to an undefined behavior.
     *
     * Throws:
     *  $(D Enforcement) fails if $(D handle) is wide oriented.
     */
    this(FILE* handle)
    {
        enforce(fwide(handle, 0) <= 0, "File must be byte oriented");
        state_  = new State;
        locker_ = FILELocker(handle);
    }


    //----------------------------------------------------------------//
    // Input range primitives.
    //----------------------------------------------------------------//

    @property bool empty()
    {
        if (state_.wantNext)
            popFrontLazy();
        return state_.empty;
    }

    @property ubyte front()
    {
        if (state_.wantNext)
            popFrontLazy();
        return state_.front;
    }

    void popFront()
    {
        if (state_.wantNext)
            popFrontLazy();
        state_.wantNext = true;
    }


    /*
     * popFront 'lazily' so that underlying stream position is not
     * messed by unnecessarily prefetching one byte.
     */
    private void popFrontLazy()
    {
        scope(success) state_.wantNext = false;
        int c;

        while ( (c = getc_unlocked(locker_.handle)) == EOF &&
                ferror(locker_.handle) )
        {
            switch (errno)
            {
              case EINTR:
                .clearerr(locker_.handle);
                continue;

              default:
                throw new ErrnoException("");
            }
            assert(0);
        }

        if (feof(locker_.handle))
        {
            state_.empty = true;
        }
        else
        {
            // We assume that C's char is 7 or 8 bits long.
            assert(ubyte.min <= c && c <= ubyte.max);
            state_.front = cast(ubyte) c;
        }
    }
}

unittest
{
    enum string deleteme = "deleteme";

    immutable ubyte[] data = [ 1,2,3,4,5,6 ];
    std.file.write(deleteme, data);
    scope(exit) std.file.remove(deleteme);

    FILE* fp = fopen(deleteme, "rb");
    assert(fp, "Cannot open file for reading");
    scope(exit) fclose(fp);

    // Here the stream is at '1'.
    {
        auto reader = FILELockingByteReader(fp);

        assert(!reader.empty);
        {
            auto r2 = reader;
            auto r3 = reader;

            assert(!r2.empty);
            assert( r2.front == 1);
            assert(!r3.empty);
            assert( r3.front == 1);

            r2.popFront();  // drops 1
            assert(!r3.empty);
            assert( r3.front == 2);

            r3.popFront();  // drops 2
            r3.popFront();  // drops 3
            assert(!r2.empty);
            assert( r2.front == 4);
        }

        assert(!reader.empty);
        assert( reader.front == 4);
        reader.popFront();  // drops 4
    }

    // Here the stream shall be at '5'.
    {
        auto reader = FILELockingByteReader(fp);

        assert(!reader.empty);
        assert( reader.front == 5);
        reader.popFront(); // drops 5

        assert(!reader.empty);
        assert( reader.front == 6);
        reader.popFront(); // drops 6

        assert(reader.empty);
    }

    // Empty is empty.
    {
        auto reader = FILELockingByteReader(fp);
        assert(reader.empty);
    }
}


/*
 * Output range for writing raw bytes to a locked $(D FILE*).
 */
@system struct FILELockingByteWriter
{
private:
    FILELocker locker_;

public:
    /**
     * Constructs a $(D FILELockingWideWriter) on a valid file _handle.
     *
     * The file must not be wide oriented because using byte I/O functions
     * on a wide oriented stream leads to an undefined behavior.
     *
     * Throws:
     *  $(D Enforcement) fails if $(D handle) is wide oriented.
     */
    this(FILE* handle)
    {
        enforce(fwide(handle, 0) <= 0, "File must be byte oriented");
        locker_ = FILELocker(handle);
    }


    //----------------------------------------------------------------//
    // Output range primitives
    //----------------------------------------------------------------//

    /**
     * Writes one byte $(D datum) to the stream.
     */
    void put(ubyte datum)
    {
        while ( putc_unlocked(datum, locker_.handle) == EOF &&
                ferror(locker_.handle) )
        {
            switch (errno)
            {
              case EINTR:
                clearerr(locker_.handle);
                continue;

              default:
                throw new ErrnoException("");
            }
            assert(0);
        }
    }


    /**
     * Writes byte string $(D chunk) to the stream.
     */
    void put(in ubyte[] chunk)
    {
        for (const(ubyte)[] rest = chunk; !rest.empty; )
        {
            immutable size_t consumed =
                fwrite(rest.ptr, 1, rest.length, locker_.handle);

            if (consumed < rest.length)
                rest = rest[consumed .. $];
            else
                break;

            if (ferror(locker_.handle))
            {
                switch (errno)
                {
                  case EINTR:
                    clearerr(locker_.handle);
                    continue;

                  default:
                    throw new ErrnoException("");
                }
                assert(0);
            }
        }
    }
}

unittest
{
    enum string deleteme = "deleteme";

    if (std.file.exists(deleteme)) std.file.remove(deleteme);
    FILE* fp = fopen(deleteme, "w");
    assert(fp, "Cannot open file for writing");
    scope(exit) std.file.remove(deleteme);

    {
        scope(exit) fclose(fp);

        // copy construction
        auto writer = FILELockingByteWriter(fp);
        {
            auto copy1 = writer;
            auto copy2 = writer;
            {
                auto copyCopy1 = copy1;
                auto copyCopy2 = copy2;
            }
        }

        // Write a sequence: (1 2 3 ... 20) excluding 10 and 13.
        writer.put([ 1,2,3,4 ]);
        writer.put([ 5,6,7,8,9,11,12,14,15 ]);
        writer.put(16);
        {
            auto copyWriter1 = writer;
            auto copyWriter2 = writer;

            copyWriter1.put(17);
            copyWriter2.put(18);
        }
        writer.put([ 19,20 ]);
    }

    // Check the written content.
    immutable ubyte[] witness =
        [ 1,2,3,4,5,6,7,8,9,11,12,14,15,16,17,18,19,20 ];
    assert(std.file.read(deleteme) == witness);
}


//----------------------------------------------------------------------------//

/*
 * Input range for reading wide character objects from a locked $(D FILE*).
 *
 * NOTE:
 *  Wide character $(D wchar_t) is _not_ a Unicode code point; it's an opaque
 *  object whose content depends on the current C locale (LC_CTYPE).
 *
 *  For reading wide character as a Unicode code point, you have to convert
 *  the wide character to a narrow character sequence by calling $(D wcrtomb),
 *  and then convert it to a Unicode code point.
 *
 *  That said, some libc implementations (e.g. glibc) define $(D wchar_t) as
 *  UCS-4, and you can exploit it under such platforms.
 */
@system struct FILELockingWideReader
{
private:
    struct State
    {
        wchar_t front;
        bool    empty;
        bool    wantNext = true;
    }
    State*     state_;
    FILELocker locker_;

public:
    /**
     * Constructs a $(D FILELockingWideReader) on a valid file _handle.
     *
     * The file must not be byte oriented because using wide I/O functions
     * on a byte oriented stream leads to an undefined behavior.
     *
     * Throws:
     *  $(D Enforcement) fails if $(D handle) is byte oriented.
     */
    this(FILE* handle)
    {
        enforce(fwide(handle, 0) >= 0, "File must be wide oriented");
        state_  = new State;
        locker_ = FILELocker(handle);
    }


    //----------------------------------------------------------------//
    // Input range primitives
    //----------------------------------------------------------------//

    @property bool empty()
    {
        if (state_.wantNext)
            popFrontLazy();
        return state_.empty;
    }

    @property wchar_t front()
    {
        if (state_.wantNext)
            popFrontLazy();
        return state_.front;
    }

    void popFront()
    {
        if (state_.wantNext)
            popFrontLazy();
        state_.wantNext = true;
    }


    /*
     * popFront 'lazily' so that underlying stream position is not
     * messed by unnecessarily prefetching one character.
     */
    private void popFrontLazy()
    {
        scope(success) state_.wantNext = false;
        wint_t wc;

        while ( (wc = getwc_unlocked(locker_.handle)) == WEOF &&
                ferror(locker_.handle) )
        {
            switch (errno)
            {
              case EINTR:
                clearerr(locker_.handle);
                continue;

              case EILSEQ:
                goto default;

              default:
                throw new ErrnoException("");
            }
            assert(0);
        }

        if (feof(locker_.handle))
            state_.empty = true;
        else
            state_.front = cast(wchar_t) wc;
    }
}

unittest
{
    enum string deleteme = "deleteme";

    immutable ubyte[] data = [ ];
    std.file.write(deleteme, data);
    scope(exit) std.file.remove(deleteme);

    FILE* fp = fopen(deleteme, "r");
    assert(fp, "Cannot open file for reading");
    scope(exit) fclose(fp);

    fwide(fp, 1) > 0 || assert(0, "Cannot set to wide");

    // copy construction
    auto reader = FILELockingWideReader(fp);
    {
        auto copy1 = reader;
        auto copy2 = reader;
        {
            auto copyCopy1 = copy1;
            auto copyCopy2 = copy2;
        }
    }

    // Can't test actual reading because codeset is unknown.
    wchar_t wc;

    assert(reader.empty);
    assert(__traits(compiles, wc = reader.front));
    assert(__traits(compiles, reader.popFront()));
}


/*
 * Output range for writing wide character objects to a locked $(D FILE*).
 *
 * NOTE:
 *  Wide character $(D wchar_t) is _not_ a Unicode code point; it's an opaque
 *  object whose content depends on the current C locale (LC_CTYPE).
 *
 *  For writing Unicode code point as a wide character, you have to convert
 *  the Unicode code point to a narrow character sequence in CTYPE-specified
 *  codeset, and then convert it to a wide character by calling $(D mbrtowc).
 *
 *  That said, some libc implementations (e.g. glibc) define $(D wchar_t) as
 *  UCS-4, and you can exploit it under such platforms.
 */
@system struct FILELockingWideWriter
{
private:
    FILELocker locker_;

public:
    /**
     * Constructs a $(D FILELockingWideWriter) on a valid file _handle.
     *
     * The file must not be byte oriented because using wide I/O functions
     * on a byte oriented stream leads to an undefined behavior.
     *
     * Throws:
     *  $(D Enforcement) fails if $(D handle) is byte oriented.
     */
    this(FILE* handle)
    {
        enforce(fwide(handle, 0) >= 0, "File must be wide oriented");
        locker_ = FILELocker(handle);
    }


    //----------------------------------------------------------------//
    // Output range primitives
    //----------------------------------------------------------------//

    /**
     * Writes wide character $(D ch) to the stream.
     */
    void put(wchar_t ch)
    {
        while ( putwc_unlocked(ch, locker_.handle) == WEOF &&
                ferror(locker_.handle) )
        {
            switch (errno)
            {
              case EINTR:
                clearerr(locker_.handle);
                continue;

              case EILSEQ:
                goto default;

              default:
                throw new ErrnoException("");
            }
            assert(0);
        }
    }


    /**
     * Writes wide string $(D str) to the stream.
     */
    void put(in wchar_t[] str)
    {
        foreach (wchar_t ch; str)
            put(ch);
    }
}

unittest
{
    enum string deleteme = "deleteme";

    FILE* fp = fopen(deleteme, "w");
    assert(fp, "Cannot open file for writing");
    scope(exit) fclose(fp), std.file.remove(deleteme);

    fwide(fp, 1) > 0 || assert(0, "Cannot set to wide");

    // copy construction
    auto writer = FILELockingWideWriter(fp);
    {
        auto copy1 = writer;
        auto copy2 = writer;
        {
            auto copyCopy1 = copy1;
            auto copyCopy2 = copy2;
        }
    }

    // Can't test actual writing because codeset is unknown.
    wchar_t   wch =    wchar_t.init;
    wchar_t[] wstr = [ wchar_t.init ];

    assert(__traits(compiles, writer.put(wch )));
    assert(__traits(compiles, writer.put(wstr)));
}


//----------------------------------------------------------------------------//
// Windows' Binary Mode
//----------------------------------------------------------------------------//
// struct FILEBinmodeScope      Keeps FILE in binary mode during lifetime.
//----------------------------------------------------------------------------//

version (Windows) private @system
{
    version (DigitalMars)
    {
        extern(C)
        {
            int setmode(int, int);
            extern __gshared ubyte[_NFILE] __fhnd_info;
        }
        alias setmode _setmode;
        int _fileno(FILE* fp) { return fp._file; }

        enum
        {
            _O_BINARY   = 0x8000,
            FHND_TEXT   = 0x10,
            FHND_BYTE   = 0x20,
        }
    }
    else
    {
        int _setmode(int, int) { return 0; }
        int _fileno(FILE* fp) { return 0; }
        enum _O_BINARY = 0;
    }
}

/**
 * Keeps a $(D FILE*) handle in binary mode during its lifetime.
 *
 * This object is not copiable.
 */
version (Windows)
@system struct FILEBinmodeScope
{
private:
    FILE* handle_;
    int   mode_;

  version (DigitalMars)
    ubyte info_;    // @@@BUG4243@@@ workaround

public:
    /**
     * Start binary mode I/O on a valid $(D FILE*) handle.
     *
     * The constructor flushes the buffer of the file stream because changing
     * translation mode would mess the buffered data.  The destructor will
     * flush the buffer for the same reason.
     */
    this(FILE* handle)
    in
    {
        assert(handle);
    }
    body
    {
        // Need to flush the buffer before changing translation mode.
        fflush(handle);

        mode_   = _setmode(_fileno(handle), _O_BINARY);
        handle_ = handle;

        version (DigitalMars)
        {
            // @@@BUG4243@@@ workaround
            auto fno = _fileno(handle);
            info_ = __fhnd_info[fno];
            __fhnd_info[fno] &= ~FHND_TEXT;
            __fhnd_info[fno] |=  FHND_BYTE;
        }
    }

    ~this()
    {
        if (handle_ is null)
            return;

        // Need to flush the buffer before restoring translation mode.
        fflush(handle_);
        _setmode(_fileno(handle_), mode_);

        version (DigitalMars)
        {
            // @@@BUG4243@@@ workaround
            __fhnd_info[_fileno(handle_)] = info_;
        }
    }

    @disable this(this);
}

version (Windows)
unittest
{
    enum string deleteme = "deleteme";

    FILE* fp = fopen(deleteme, "w");
    assert(fp, "Cannot open file for writing");
    scope(exit) std.file.remove(deleteme);

    fputs("\n\r\n", fp);
    {
        auto binmode = FILEBinmodeScope(fp);
        fputs("\n\r\n", fp);
    }
    fputs("\n\r\n", fp);
    fclose(fp);

    // Check the written data.
    auto data = cast(string) std.file.read(deleteme);
    assert(data == "\r\n\r\r\n" ~ "\n\r\n" ~ "\r\n\r\r\n");
    // Translation:  ^     ^                   ^     ^
}

version (Windows) {} else
@system struct FILEBinmodeScope
{
    this(FILE*) {}
}


//----------------------------------------------------------------------------//
// Shared & Unshared
//----------------------------------------------------------------------------//

/*
 * Returns an unshared reference to a shared object $(D obj).  You can use
 * unshared reference to the object in a safe context -- a critical section,
 * for example.
 */
@system ref T assumeUnshared(T)(ref shared(T) obj) nothrow
{
    return *cast(T*) &obj;
}

unittest
{
    static shared int n;

    int k = assumeUnshared(n);
    assumeUnshared(n) = k;
}


/*
 * Reinterprets an unshared object $(D obj) as a shared one.
 */
@trusted ref shared(T) assumeShared(T)(ref T obj) nothrow
{
    return *cast(shared T*) &obj;
}

unittest
{
    int n;
    shared int k = assumeShared(n);
}


