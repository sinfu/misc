
import std.array;
import std.exception;
import std.format;
import std.range;
import std.traits;

import std.internal.stdio.nativechar;

import core.atomic;

import core.stdc.errno;
import core.stdc.stdio;
import core.stdc.wchar_;

version (unittest) static import std.file;


void main()
{
    writeln("α-β");

    write("Enter a line: ");
    writeln(" --> ", stdinText.readln());
}


//----------------------------------------------------------------------------//
// Free Functions
//----------------------------------------------------------------------------//
// void write   (        args...);
// void writeln (        args...);
// void writef  (format, args...);
// void writefln(format, args...);
//----------------------------------------------------------------------------//

shared File stdin, stdout, stderr;
shared NativeTextIOPort stdinText, stdoutText, stderrText;
shared   UTF8TextIOPort stdinUTF8, stdoutUTF8, stderrUTF8;

shared static this()
{
    // SAFE: shared static this runs only once at program startup.
    assumeUnshared(stdin ) = File(core.stdc.stdio.stdin );
    assumeUnshared(stdout) = File(core.stdc.stdio.stdout);
    assumeUnshared(stderr) = File(core.stdc.stdio.stderr);

    assumeUnshared( stdinText) = NativeTextIOPort(assumeUnshared(stdin ));
    assumeUnshared(stdoutText) = NativeTextIOPort(assumeUnshared(stdout));
    assumeUnshared(stderrText) = NativeTextIOPort(assumeUnshared(stderr));

    assumeUnshared( stdinUTF8) = UTF8TextIOPort(assumeUnshared(stdin ));
    assumeUnshared(stdoutUTF8) = UTF8TextIOPort(assumeUnshared(stdout));
    assumeUnshared(stderrUTF8) = UTF8TextIOPort(assumeUnshared(stderr));
}


/**
 *
 */
void write(Args...)(Args args)
{
    stdoutText.write(args);
}

/// ditto
void writeln(Args...)(Args args)
{
    stdoutText.writeln(args);
}

/// ditto
void writef(Format, Args...)(Format format, Args args)
{
    stdoutText.writef(format, args);
}

/// ditto
void writefln(Format, Args...)(Format format, Args args)
{
    stdoutText.writefln(format, args);
}


//----------------------------------------------------------------------------//
// NativeTextIOPort
//----------------------------------------------------------------------------//
// struct NativeTextIOPort
// {
//     this(File file);
//
// shared:
//     @property LockingTextWriter lockingTextWriter();
//     void write   (        args...);
//     void writeln (        args...);
//     void writef  (format, args...);
//     void writefln(format, args...);
//
//     @property LockingTextReader lockingTextReader();
//     String readln(dchar terminator);
//     size_t readln(ref Char[], dchar terminator);
// }
//----------------------------------------------------------------------------//


/**
 * Object for writing Unicode text to the standard output in console-safe
 * system encoding.
 */
@system struct NativeTextIOPort
{
private:
    File                 file_;
    NativeCodesetEncoder encoder_;
    NativeCodesetDecoder decoder_;

public:
    //----------------------------------------------------------------//
    // Constructor
    //----------------------------------------------------------------//

    /**
     * Constructs a $(D NativeTextIOPort) on an open $(D File).
     *
     * Params:
     *  file = An open $(D File) to perform native text I/O on.
     *
     * Throws:
     *  $(D Exception) if conversion is not supported on the platform.
     */
    this(File file)
    {
        // Construct transcoders.
        immutable convMode = determineConversionMode(file.handle);
        encoder_ = NativeCodesetEncoder(convMode);
        decoder_ = NativeCodesetDecoder(convMode);

        file_ = file;
    }


    /*
     * Returns the relevant $(D ConversionMode) for a given $(D file).
     */
    private static ConversionMode determineConversionMode(FILE* handle)
    {
        if (handle is core.stdc.stdio.stdin  ||
            handle is core.stdc.stdio.stdout ||
            handle is core.stdc.stdio.stderr )
            // File is a standard stream.  Text should be encoded in system's
            // console encoding regardless of whether the stream is redirected.
            return ConversionMode.console;
        else
            // It's a file; use user's native codeset.
            return ConversionMode.native;
    }


    //----------------------------------------------------------------//
    // Transcoded text writing capabilities
    //----------------------------------------------------------------//

    /**
     * Returns an output range for writing text to a locked file stream in
     * the native character encoding.
     */
    @property LockingTextWriter lockingTextWriter()
    {
        return assumeShared(this).lockingTextWriter;
    }

    /// ditto
    @property LockingTextWriter lockingTextWriter() shared
    {
        return LockingTextWriter(file_, encoder_);
    }

    /// ditto
    static struct LockingTextWriter
    {
    private:
        FILELockingByteWriter writer_;
        NativeCodesetEncoder  encoder_;
        File                  reference_;

        /*
         * Params:
         *  file    = This object is holded by the $(D LockingTextWriter)
         *            object for maintaining the reference counter associated
         *            with $(D file).
         *  encoder = The string _encoder to use.
         */
        this(ref shared File file, ref shared NativeCodesetEncoder encoder)
        {
            // Enter a critical section.
            writer_ = FILELockingByteWriter(file.handle);

            // SAFE: We are in the critical section.
            encoder_   = assumeUnshared(encoder);
            reference_ = assumeUnshared(file);
        }


    public:
        //----------------------------------------------------------------//
        // Output range primitives
        //----------------------------------------------------------------//

        /**
         * Writes a UTF string $(D str) to the file stream in the native
         * character encoding.
         */
        void put(S)(S str)
            if (isSomeString!(S))
        {
            encoder_.convertChunk(str, writer_);
        }


        /**
         * Writes a Unicode code point $(D c) to the file stream in the native
         * character encoding.
         */
        void put(C = dchar)(dchar c)
            if (is(C == dchar))
        {
            put((&c)[0 .. 1]);
        }
    }


    /**
     * Writes formatted arguments $(D args) to the thread-locked stream.
     */
    void write(Args...)(Args args) shared
    {
        auto writer = this.lockingTextWriter;

        foreach (i, Arg; Args)
        {
            static if (__traits(compiles, writer.put(args[i]) ))
                writer.put(args[i]);
            else
                std.format.formattedWrite(writer, "%s", args[i]);
        }
    }

    /// ditto
    void writeln(Args...)(Args args) shared
    {
        write(args, '\n');
    }

    /// ditto
    void writef(Format, Args...)(Format format, Args args) shared
    {
        auto writer = this.lockingTextWriter;

        std.format.formattedWrite(writer, format, args);
    }

    /// ditto
    void writefln(Format, Args...)(Format format, Args args) shared
    {
        auto writer = this.lockingTextWriter;

        std.format.formattedWrite(writer, format, args);
        writer.put('\n');
    }


    //----------------------------------------------------------------//
    // Transcoded text reading capabilities
    //----------------------------------------------------------------//

    /**
     * Returns an output range for reading text from a locked file stream in
     * the native character encoding.
     */
    @property LockingTextReader lockingTextReader()
    {
        return assumeShared(this).lockingTextReader;
    }

    /// ditto
    @property LockingTextReader lockingTextReader() shared
    {
        return LockingTextReader(file_, decoder_);
    }

    /// ditto
    static struct LockingTextReader
    {
    private:
        FILELockingByteReader reader_;
        NativeCodesetDecoder  decoder_;
        File                  reference_;
        State*                state_;

        static struct State
        {
            dchar front;
            bool  empty;
            bool  wantNext = true;
        }


        /*
         * Constructs a $(D LockingTextReader) object.
         *
         * Params:
         *  file    = This object is holded by the $(D LockingTextReader)
         *            object for maintaining the reference counter associated
         *            with $(D file).
         *  decoder = A character _decoder to use.
         */
        this(ref shared File file, ref shared NativeCodesetDecoder decoder)
        {
            state_ = new State;

            // Enter a critical section.
            reader_ = FILELockingByteReader(file.handle);

            // SAFE: We are in the critical section.
            decoder_   = assumeUnshared(decoder);
            reference_ = assumeUnshared(file);
        }


    public:
        //----------------------------------------------------------------//
        // Input range primitives
        //----------------------------------------------------------------//

        /*
         * Returns $(D true) iff the underlying stream offeres no more
         * characters.
         */
        @property bool empty()
        in
        {
            assert(state_ != null);
        }
        body
        {
            if (state_.wantNext)
                popFrontLazy();
            return state_.empty;
        }


        /*
         * Returns the character at the current position of the stream.
         */
        @property dchar front()
        in
        {
            assert(state_ != null);
        }
        body
        {
            if (state_.wantNext)
                popFrontLazy();
            return state_.front;
        }


        /*
         * Drops the cached $(D front) character.  Next access to the
         * $(D empty) or $(D front) will fetch the next character.
         */
        void popFront()
        in
        {
            assert(state_ != null);
        }
        body
        {
            if (state_.wantNext)
                popFrontLazy();
            state_.wantNext = true;
        }


        /*
         * Fetch the next character into $(D state_.front).  $(D state_.empty)
         * is set to $(D true) if the stream offers no more character.
         */
        private void popFrontLazy()
        in
        {
            assert(state_ != null);
            assert(state_.wantNext);
        }
        body
        {
            scope(success) state_.wantNext = false;

            // Reader shall use a dchar (if any) in IOPort's pushback buffer.
            if (false)
            {
                assert(0, "not implemented");
                state_.front = dchar.init;
                return;
            }
            assert(1, "pushback buffer must be empty");

            // Receiver receives converted dchars from the decoder.
            //
            // Note that a character may be represented in multiple dchars,
            // and thus put() may be called multiple times.  In such case
            // Receiver pushes 'extra' code points to IOPort's pushback
            // buffer. [TODO]
            static struct Receiver
            {
                State* state_;

                void put(dchar c)
                in
                {
                    assert(state_ != null);
                }
                body
                {
                    state_.front = c;
                }
            }
            auto receiver = Receiver(state_);

            final switch (decoder_.convertCharacter(reader_, receiver))
            {
              case ConversionStatus.ok:
                break;

              case ConversionStatus.empty:
                state_.empty = true;
                break;
            }
        }
    }


    /**
     * Reads one line from the stream.
     */
    String readln(String = string)(dchar terminator = '\n') shared
        if (isSomeString!(String))
    {
        char[] buffer;

        buffer = buffer[0 .. readln(buffer, terminator)];
        return assumeUnique(buffer);
    }

    /// ditto
    size_t readln(Char)(ref Char[] buffer, dchar terminator = '\n') shared
        if (isSomeChar!(Char))
    {
        auto writer = appender(&buffer);

        foreach (dchar c; this.lockingTextReader)
        {
            putUTF!Char(writer, c);
            if (c == terminator)
                break;
        }
        return writer.data.length;
    }
}


//----------------------------------------------------------------------------//
// UTF8TextIOPort
//----------------------------------------------------------------------------//
// struct UTF8TextIOPort
// {
//     this(File file);
//
// shared:
//     @property LockingTextWriter lockingTextWriter();
//     void write   (        args...);
//     void writeln (        args...);
//     void writef  (format, args...);
//     void writefln(format, args...);
//
//     @property LockingTextReader lockingTextReader();
//     String readln(dchar terminator);
//     size_t readln(ref Char[], dchar terminator);
// }
//----------------------------------------------------------------------------//

/**
 * Object for writing Unicode text to a $(D File) in UTF-8 encoding.
 */
@system struct UTF8TextIOPort
{
private:
    File file_;

public:
    //----------------------------------------------------------------//
    // Constructor
    //----------------------------------------------------------------//

    /**
     * Constructs a $(D UTF8TextIOPort) on an open $(D File).
     *
     * Params:
     *  file = An open $(D File) to perform UTF-8 text I/O on.
     */
    this(File file)
    {
        file_ = file;
    }


    //----------------------------------------------------------------//
    // Transcoded text writing capabilities
    //----------------------------------------------------------------//

    /**
     * Returns an output range for writing text to a locked file stream in
     * the UTF-8 encoding.
     */
    @property LockingTextWriter lockingTextWriter()
    {
        return assumeShared(this).lockingTextWriter;
    }

    /// ditto
    @property LockingTextWriter lockingTextWriter() shared
    {
        return LockingTextWriter(file_);
    }

    /// ditto
    static struct LockingTextWriter
    {
    private:
        FILELockingByteWriter byteWriter_;
        FILELockingWideWriter wideWriter_;
        int                   orientation_;
        File                  reference_;

        /**
         * Constructs a $(D LockingTextWriter) object on an open $(D file).
         */
        this(ref shared File file)
        {
            auto handle = file.handle;

            // We have to deal with the stream orientation.
            orientation_ = core.stdc.wchar_.fwide(handle, 0);

            if (orientation_ <= 0)
                byteWriter_ = FILELockingByteWriter(handle);
            else
                wideWriter_ = FILELockingWideWriter(handle);

            // SAFE: We are in the critical section.
            reference_ = assumeUnshared(file);
        }


    public:
        //----------------------------------------------------------------//
        // Range primitive implementations.
        //----------------------------------------------------------------//

        /**
         * Writes a UTF string $(D str) to the file stream in UTF-8 encoding.
         */
        void put(String)(String str)
            if (isSomeString!(String))
        {
            if (is(String : const(char)[]) && orientation_ <= 0)
            {
                // Write UTF-8 string directly to the stream.
                byteWriter_.put(cast(const ubyte[]) str);
            }
            else
            {
                // Put each character in turn.
                foreach (dchar c; str)
                    this.put(c);
            }
        }


        /**
         * Writes a Unicode code point $(D c) to the stream in UTF-8 encoding.
         */
        void put(Char = dchar)(dchar c)
            if (is(Char == dchar))
        {
            if (orientation <= 0)
            {
                assert(byteWriter_ != byteWriter_.init);

                if (c <= 0x7F)
                {
                    // Simplest case: single ASCII character.
                    byteWriter_.put(cast(ubyte) c);
                }
                else
                {
                    // Encode to UTF-8 and write each code unit.
                    char[4] buffer = void;
                    size_t  stride = std.utf.encode(buf, c);

                    foreach (u; buffer[0 .. stride])
                        byteWriter_.put(cast(ubyte) u);
                }
            }
            else
            {
                // The stream orientation is wide.  Write the code point
                // directly as a wide character if wchar_t is UCS-2/4.
                assert(wideWriter_ != wideWriter_.init);

                static if (is(wchar_t == wchar))
                {
                    if (c <= 0xFFFF)
                    {
                        // Simple UCS-2 character.
                        wideWriter_.put(cast(wchar_t) c);
                    }
                    else
                    {
                        // Deal with UTF-16 surrogate pair.
                        immutable wchar_t
                            a = (((c - 0x10000) >> 10) & 0x3FF) + 0xD800,
                            b = ( (c - 0x10000)        & 0x3FF) + 0xDC00;
                        wideWriter_.put(a);
                        wideWriter_.put(b);
                    }
                }
                else static if (is(wchar_t == dchar))
                {
                    wideWriter_.put(c);
                }
                else
                {
                    assert(0, "not supported");
                }
            }
        }
    }


    /**
     * Writes formatted arguments $(D args) to the thread-locked stream.
     */
    void write(Args...)(Args args) shared
    {
        auto writer = this.lockingTextWriter;

        foreach (i, Arg; Args)
        {
            static if (__traits(compiles, writer.put(args[i]) ))
                writer.put(args[i]);
            else
                std.format.formattedWrite(writer, "%s", args[i]);
        }
    }

    /// ditto
    void writeln(Args...)(Args args) shared
    {
        write(args, '\n');
    }

    /// ditto
    void writef(Format, Args...)(Format format, Args args) shared
    {
        auto writer = this.lockingTextWriter;

        std.format.formattedWrite(writer, format, args);
    }

    /// ditto
    void writefln(Format, Args...)(Format format, Args args) shared
    {
        auto writer = this.lockingTextWriter;

        std.format.formattedWrite(writer, format, args);
        writer.put('\n');
    }


    //----------------------------------------------------------------//
    // Transcoded text reading capabilities
    //----------------------------------------------------------------//

    /**
     * Returns an output range for reading text from a locked file stream in
     * the native character encoding.
     */
    @property LockingTextReader lockingTextReader()
    {
        return assumeShared(this).lockingTextReader;
    }

    /// ditto
    @property LockingTextReader lockingTextReader() shared
    {
        return LockingTextReader(file_);
    }

    /// ditto
    static struct LockingTextReader
    {
    private:
        FILELockingByteReader byteReader_;
        FILELockingWideReader wideReader_;
        int                   orientation_;
        State*                state_;
        File                  reference_;

        static struct State
        {
            dchar front;
            bool  empty;
            bool  wantNext = true;
        }


        /*
         * Constructs a $(D LockingTextReader) object.
         */
        this(ref shared File file)
        {
            state_ = new State;

            // We shall deal with the stream orientation.
            auto  handle = file.handle;
            orientation_ = core.stdc.wchar_.fwide(handle, 0);

            if (orientation_ <= 0)
                byteReader_ = FILELockingByteReader(handle);
            else
                wideReader_ = FILELockingWideReader(handle);

            // SAFE: We are in the critical section.
            reference_ = assumeUnshared(file);
        }


    public:
        //----------------------------------------------------------------//
        // Input range primitives
        //----------------------------------------------------------------//

        /*
         * Returns $(D true) iff the underlying stream offeres no more
         * characters.
         */
        @property bool empty()
        in
        {
            assert(state_ != null);
        }
        body
        {
            if (state_.wantNext)
                popFrontLazy();
            return state_.empty;
        }


        /*
         * Returns the character at the current position of the stream.
         */
        @property dchar front()
        in
        {
            assert(state_ != null);
        }
        body
        {
            if (state_.wantNext)
                popFrontLazy();
            return state_.front;
        }


        /*
         * Drops the cached $(D front) character.  Next access to the
         * $(D empty) or $(D front) will fetch the next character.
         */
        void popFront()
        in
        {
            assert(state_ != null);
        }
        body
        {
            if (state_.wantNext)
                popFrontLazy();
            state_.wantNext = true;
        }


        /*
         * Fetch the next character into $(D state_.front).  $(D state_.empty)
         * is set to $(D true) if the stream offers no more character.
         */
        private void popFrontLazy()
        in
        {
            assert(state_ != null);
            assert(state_.wantNext);
        }
        body
        {
            scope(success) state_.wantNext = false;

            if (orientation_ <= 0)
            {
                // Stream is byte oriented.
                assert(byteReader_ != byteReader_.init);

                // Decode UTF-8 sequence.
                if (byteReader_.empty)
                    state_.empty = true;
                else
                    state_.front = decodeFront(byteReader_);
            }
            else
            {
                // Stream is wide oriented.
                assert(wideReader_ != wideReader_.init);

                static if (is(wchar_t == wchar) || is(wchar_t == dchar))
                {
                    if (wideReader_.empty)
                        state_.empty = true;
                    else
                        state_.front = decodeFront(wideReader_);
                }
                else
                {
                    assert(0, "not supported");
                }
            }
        }
    }


    // NOTE: efficient std.stdio readlnImpl() could be used.

    /**
     * Reads one line from the stream.
     */
    String readln(String = string)(dchar terminator = '\n') shared
        if (isSomeString!(String))
    {
        char[] buffer;

        buffer = buffer[0 .. readln(buffer, terminator)];
        return assumeUnique(buffer);
    }

    /// ditto
    size_t readln(Char)(ref Char[] buffer, dchar terminator = '\n') shared
        if (isSomeChar!(Char))
    {
        auto writer = appender(&buffer);

        foreach (dchar c; this.lockingTextReader)
        {
            putUTF!Char(writer, c);
            if (c == terminator)
                break;
        }
        return writer.data.length;
    }
}


//----------------------------------------------------------------------------//
// File
//----------------------------------------------------------------------------//
// shared File stdin, stdout, stderr;
//
// struct File
// {
//     this(FILE* handle);
//     this(string name, in char[] openMode);
//
//     @property FILE* handle();
//     @property int   fileno();
//
//     @property bool  isOpen();
//     void            open(string name, in char[] openMode);
//     void            close();
//
//     @property bool  error();
//     void            clearerr();
//
//     void            flush();
//     void            setvbuf(size_t   size, int mode);
//     void            setvbuf(void[] buffer, int mode);
// }
//----------------------------------------------------------------------------//


private @trusted T atomicLoad(T)(const ref shared T val)
{
    return atomicOp!("|=", T, T)(val, 0);
}


/**
 *
 */
@system struct File
{
private:
    /*
     * Pack all fields in $(D Impl) for sharing them among all copies of the
     * semantically same $(D File) objects.
     */
    static struct Impl
    {
        FILE*  handle;
        string name;
        int    refCount = -1;   // -1: No reference counting
    }
    Impl* impl;


public:
    //----------------------------------------------------------------//
    // Constructors
    //----------------------------------------------------------------//

    /**
     *
     */
    this(FILE* handle, bool own = false)
    {
        impl          = new Impl;
        impl.handle   = handle;
        impl.refCount = (own ? 1 : -1);
    }


    /**
     *
     */
    this(string name, in char[] openMode)
    {
        open(name, openMode);
    }


    //----------------------------------------------------------------//
    // FILE resource management
    //----------------------------------------------------------------//

    /*
     * Copy constructor atomically increments the internal reference counter
     * iff the $(D File) object is owning the underlying $(D FILE*) handle.
     */
    this(this) //shared
    {
        if (auto p = cast(shared) impl)
        {
            if (atomicLoad(p.refCount) > 0)
                atomicOp!"+="(p.refCount, 1);
        }
    }


    /*
     * Destructor atomically decrements the internal reference counter iff
     * the $(D File) object is owning the underlying $(D FILE*) handle; and
     * closes the $(D FILE*) handle if the reference count becomes zero.
     */
    ~this() //shared
    {
        if (auto p = cast(shared) impl)
        {
            if (atomicLoad(p.refCount) > 0)
            {
                if (atomicOp!"-="(p.refCount, 1) == 0)
                    close();
            }
        }
    }


    //----------------------------------------------------------------//
    // FILE interface: handle and fd
    //----------------------------------------------------------------//

    /**
     * Returns the underlying $(D FILE*) object.
     */
    @property FILE* handle()
    {
        return impl.handle;
    }

    /// ditto
    @property FILE* handle() shared
    {
        return impl.handle;
    }


    /**
     * .
     */
    @property int fileno()
    {
        auto handle = impl.handle;

        return core.stdc.stdio.fileno(handle);
    }


    //----------------------------------------------------------------//
    // FILE interface: open/close
    //----------------------------------------------------------------//

    /**
     * Returns $(D true) iff the underlying file is open.
     */
    @property bool isOpen()
    {
        return impl && impl.handle;
    }

    /// ditto
    @property bool isOpen() shared
    {
        return impl && impl.handle;
    }


    /**
     *
     */
    void open(string path, in char[] openMode)
    {
        assert(0, "not implemented");
    }


    /**
     * Closes the underlying file object.
     */
    void close()
    {
        if (core.stdc.stdio.fclose(impl.handle) == -1)
        {
            switch (errno)
            {
              default:
                throw new Exception("");
            }
            assert(0);
        }

        *impl = (*impl).init;
         impl =   impl .init;
    }


    //----------------------------------------------------------------//
    // FILE interface: error
    //----------------------------------------------------------------//

    /**
     *
     */
    @property bool error()
    {
        auto handle = impl.handle;

        return core.stdc.stdio.ferror(handle) != 0;
    }


    /**
     *
     */
    void clearerr()
    {
        auto handle = impl.handle;

        core.stdc.stdio.clearerr(handle);
    }


    //----------------------------------------------------------------//
    // FILE interface: buffering
    //----------------------------------------------------------------//

    /**
     * .
     */
    void flush()
    {
        auto handle = impl.handle;

        while (core.stdc.stdio.fflush(handle) == EOF)
        {
            switch (errno)
            {
              case EINTR:
                continue;

              default:
                throw new Exception("");
            }
            assert(0);
        }
    }


    /**
     * .
     */
    void setvbuf(size_t size, int mode = 0)
    {
        auto handle = impl.handle;

        core.stdc.stdio.setvbuf(handle, null, mode, size);
    }


    /**
     * .
     */
    void setvbuf(void[] buffer, int mode = 0)
    {
        auto handle = impl.handle;

        core.stdc.stdio.setvbuf(
                handle, cast(char*) buffer.ptr, mode, buffer.length);
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


