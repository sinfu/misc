/*
Convert delegates to Windows function pointers.

--------------------
> dmd -run test06_delegate_to_winfunc
read	delta
1024	1024
2048	1024
3072	1024
4096	1024
5120	1024
5475	355
Finished!
--------------------
 */

import std.stdio;

import core.sys.windows.windows;
import core.memory;

extern(Windows) // Missing declarations
{
    enum DWORD ERROR_HANDLE_EOF = 38;

    // Asynchronous IO
    alias void function(DWORD dwErrorCode, DWORD dwNumberOfBytesTransfered,
            OVERLAPPED* lpOverlapped) FileIOCompletionRoutine;
    BOOL ReadFileEx(HANDLE hFile, void* lpBuffer, DWORD nNumberOfBytesToRead,
        OVERLAPPED* lpOverlapped, FileIOCompletionRoutine lpCompletionRoutine);

    // Event objects
    HANDLE CreateEventW(SECURITY_ATTRIBUTES* lpEventAttributes, BOOL bManualReset,
            BOOL bInitialState, LPCWSTR lpName);
    BOOL SetEvent(HANDLE hEvent);

    // Alertable wait API
    DWORD WaitForMultipleObjectsEx(DWORD nCount, const(HANDLE)* lpHandles,
            BOOL fWaitAll, DWORD dwMilliseconds, BOOL bAlertable);
}

void main()
{
    /*
     * Open this source file in the 'overlapped' mode.
     */
    HANDLE file;

    file = CreateFileW(__FILE__, GENERIC_READ, FILE_SHARE_READ, null,
            OPEN_EXISTING, FILE_FLAG_OVERLAPPED, null);
    if (file == INVALID_HANDLE_VALUE)
        throw new Exception("CreateFile");
    scope(exit) CloseHandle(file);

    /*
     * Read in the entire file asynchronously.
     */
    OVERLAPPED  overlapped;
    HANDLE      readEvent;  // signaled when a read operation is completed
    ubyte[]     buffer;     // read-in buffer
    size_t      nread;      // the number of bytes read

    // Create readEvent.  This will be signaled by a completeion routine.
    readEvent = CreateEventW(null, FALSE, FALSE, null);
    if (readEvent == INVALID_HANDLE_VALUE)
        throw new Exception("CreateEvent");
    scope(exit) CloseHandle(readEvent);

    // Allocate the buffer.
    buffer.length = 1024;

            /+:::::::::::::::::::::::::::::::::::::::://
                     XXX translateToWindows()
            //::::::::::::::::::::::::::::::::::::::::+/
    // IO completion routine; invoked when ReadFileEx operation is completed.
    auto onReadCompleted = translateToWindows(
        (DWORD dwErrorCode, DWORD dwNumberOfBytesTransfered, OVERLAPPED*)
        {
            // print the number of bytes read and the delta
            nread += dwNumberOfBytesTransfered;
            writeln(nread, "\t", dwNumberOfBytesTransfered);

            if (dwErrorCode == ERROR_HANDLE_EOF)
                writeln("----"); // EOF

            // Signal the readEvent object.  Read next data!
            SetEvent(readEvent);
        });

    writeln("read\tdelta");
    scope(success) writeln("Finished!");

    // Start reading file.
L_read:
    while (true)
    {
        // Move the file pointer to the appropriate position.
        overlapped.Offset = nread;

        // Asynchronous read
        cast(void) ReadFileEx(file, buffer.ptr, buffer.length, &overlapped,
                onReadCompleted);

        switch (GetLastError())
        {
            case ERROR_SUCCESS, ERROR_MORE_DATA:
                break;
            case ERROR_HANDLE_EOF:
                break L_read;
            default:
                throw new Exception("ReadFileEx");
        }

        // Must use alertable wait.  DONT: WaitForSingleObject()
        switch (WaitForMultipleObjectsEx(1, &readEvent, TRUE, INFINITE, TRUE))
        {
            case WAIT_OBJECT_0:
                break;
            default:
                throw new Exception("WaitForSingleObject");
        }
    }
}


//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://
// Convert delegates to Windows function pointers dynamically
//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://

template WindowsFuncPtr(R, P...)
{
    extern(Windows) alias R function(P) WindowsFuncPtr;
}

version (X86)
{
    /*
     * Returns a pinter to a stdcall function which invokes the passed
     * delegate dg.
     *
     * BUGS:
     *   memory leak
     */
    auto translateToWindows(R, P...)(R delegate(P) dg)
    {
        enum CODE_SIZE = TEMPLATE_CODE_WINDOWS.length;
        ubyte[] code;

        // allocate memory in an executable page
        void* xpage = VirtualAlloc(null, CODE_SIZE, MEM_COMMIT,
                PAGE_EXECUTE_READWRITE);
        if (xpage == null)
            throw new Exception("VirtualAlloc");

        code = (cast(ubyte*) xpage)[0 .. CODE_SIZE];
        code[] = TEMPLATE_CODE_WINDOWS[];

        *cast(uint*) &code[ 4] = cast(uint) dg.ptr;
        *cast(uint*) &code[12] = cast(uint) dg.funcptr;

        return cast(WindowsFuncPtr!(R, P)) code.ptr;
    }

    template stackSize(PP...)
    {
        static if (PP.length > 0)
            enum size_t stackSize =
                alignSize(PP[0].sizeof) + stackSize!(PP[1 .. $]);
        else
            enum size_t stackSize = 0;
    }

    size_t alignSize(size_t n) pure nothrow @safe
    {
        return (n + 3) & ~3;
    }

    private static immutable ubyte[] TEMPLATE_CODE_WINDOWS =
    [
        // Fix#1 @4  = dg.ptr
        // Fix#2 @12 = dg.funcptr

        0x90, 0x90, 0x90,           // nop
        0xB8, 0,0,0,0,              // mov EAX, Fix#1
        0x90, 0x90, 0x90,           // nop
        0xB9, 0,0,0,0,              // mov ECX, Fix#2
        0xFF, 0xE1,                 // jmp ECX
    ];
}


