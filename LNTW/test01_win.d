/+

コンソールへの書き込み
  FILE* がバイト指向のとき
      1. WriteConsoleW
     or. WideCharToMultiByte(GetConsoleOutputCP) + fwrite
  FILE* がワイド指向のとき
      1. WriteConsoleW
     or. fputwc

WriteConsoleW を使って可能な限り Unicode を表示しきる．WriteConsoleW が使えない場合は，
コンソールのコードページに変換して出力する．ここでACPやCRTのロケールを使うと，chcp
されていた場合に文字化けしてしまう．

NOTE: ConsoleOutputCP はプログラムの動作中に変わる可能性がある…

■ファイルやパイプへの書き込み
  FILE* がバイト指向のとき
     1. WideCharToMultiByte(GetACP) + fwrite
  FILE* がワイド指向のとき
     1. fputwc

他のプログラムやファイル出力で期待されるコードページはACPなので，WCTMB で変換して出力．
ワイドモードではCRTに任せるしかない (この場合，ACPではなくCRTのロケールが使われるが)．

 +/
version (Windows) {} else { static assert(0); }

import std.stdio;

import core.stdc.stdlib;
import core.stdc.wchar_;

import utfex;


private T* assumeLocked(T)(shared(T)* x)
{
    return cast(T*) x;
}

void main()
{
    FILE* fp = stdout.getFP();

    bool isWide_;
    bool isConsole_;
    bool useWriteConsoleW_;

    isWide_ = (fwide(fp, 0) > 0);

    {
        HANDLE console = osfhnd(fp);
        DWORD  dummy;

        if (GetConsoleMode(console, &dummy))
        {
            isConsole_ = true;

            if (indirectWriteConsoleW && indirectWriteConsoleW(console, "\0"w.ptr, 0, null, null))
                useWriteConsoleW_ = true;
        }
    }

    FLOCK(fp);
    scope(exit) FUNLOCK(fp);

    auto unlockedFP = assumeLocked(fp);

    //
    string s;
    s = "Chazuke (茶漬け, ちゃづけ) or ochazuke (お茶漬け, from o + cha tea + tsuke submerge) is "
        ~"a simple Japanese dish made by pouring green tea, dashi, or hot water over cooked rice "
        ~"roughly in the same proportion as milk over cereal, usually with savoury toppings.";
    s = "このドキュメントは間違えだらけで、全然役に立たない。\n"
        ~"この埃だれけのテレビをちゃんと拭いてくれない？\n"
        ~"たった１キロを走っただけで、汗まみれになるのは情けない。\n"
        ~"女の子と共通の話題ができて、自分の体も健康になる。いいことずくめですよ。\n";

    if (useWriteConsoleW_)
    {
        //------------------ console and WriteConsoleW ------------------//
        HANDLE console = osfhnd(fp);

    // >> LNTW
        for (const(char)[] inbuf = s; inbuf.length > 0; )
        {
            wchar[80] wsbuf = void;
            size_t    wsLen = inbuf.convert(wsbuf);

            while (wsLen > 0)
            {
                DWORD nwritten;
                if (!indirectWriteConsoleW(console, wsbuf.ptr, wsLen, &nwritten, null))
                    throw new Exception( toWindowsErrorString(GetLastError()) );
                else
                    wsLen -= nwritten;
            }
        }
    // << LNTW
    }
    else
    {
        //------------------ file or no WriteConsoleW ------------------//
        const codepage = (isConsole_ ? GetConsoleOutputCP() : GetACP());

        if (isWide_)
        {
            //------------------ wide mode ------------------//

        // >> WideWriter
            for (const(char)[] inbuf = s; inbuf.length > 0; )
            {
                wchar[80] wsbuf = void;
                size_t    wsLen = inbuf.convert(wsbuf);

            // >> UnsharedWidePutter
                foreach (wchar wc; wsbuf)
                    FPUTWC(wc, unlockedFP);
            // << UnsharedWidePutter
            }
        // << WideWriter
        }
        else
        {
            //------------------ narrow mode ------------------//
            char[160] mstackStock = void;
            char[]    mstock = mstackStock;

        // >> NarrowWriter
            for (const(char)[] inbuf = s; inbuf.length > 0; )
            {
                wchar[80] wsbuf = void;
                size_t    wsLen = inbuf.convert(wsbuf);

        //--------
                char[]    mbuf;
                size_t    mbLen;

                mbLen = cast(size_t) WideCharToMultiByte(
                        codepage, 0, wsbuf.ptr, wsLen, null, 0, null, null);
                if (mbLen == 0)
                    throw new Exception( toWindowsErrorString(GetLastError()) );

                if (mbLen <= mstock.length)
                    mbuf = mstock[0 .. mbLen];
                else
                    mbuf = mstock = new char[mbLen];

                mbLen = cast(size_t) WideCharToMultiByte(
                        codepage, 0, wsbuf.ptr, wsLen, mbuf.ptr, mbuf.length, null, null);
                if (mbLen == 0)
                    throw new Exception( toWindowsErrorString(GetLastError()) );

            // >> UnsharedNarrowPutter
                const nwritten = fwrite(mbuf.ptr, 1, mbLen, fp);
                if (nwritten != mbLen)
                    throw new Exception("");
            // << UnsharedNarrowPutter
            }
        // << NarrowWriter
        }
    }
}


private
{
    import core.sys.windows.windows;
    import std.windows.syserror : toWindowsErrorString = sysErrorString;

    enum
    {
        DWORD CP_ACP = 0,
              CP_OEMCP,
              CP_MACCP,
              CP_THREAD_ACP,
    }

    version (DigitalMars)
    {
        extern(C) extern __gshared HANDLE[_NFILE] _osfhnd;
        HANDLE osfhnd(FILE* f) { return _osfhnd[fileno(f._file)]; }
    }
    else
    {
        // osfhnd()
        static assert(0);
    }

    immutable typeof(&WriteConsoleW) indirectWriteConsoleW;
    static this()
    {
        indirectWriteConsoleW = cast(typeof(indirectWriteConsoleW))
            GetProcAddress(GetModuleHandleA("kernel32.dll"), "WriteConsoleW");
    }
}



