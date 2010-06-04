/*
 * Spying global variables in other modules by 'hand-mangling' symbol names.
 */

import std.stdio;

extern(C) extern // use the C name mangling
{
    /*
     * object._moduleinfo_tlsdtors{,_ik} (See druntime/src/object_.d)
     */
    ModuleInfo*[] _D6object20_moduleinfo_tlsdtorsAPS6object10ModuleInfo;
    uint          _D6object22_moduleinfo_tlsdtors_ik;

    alias _D6object20_moduleinfo_tlsdtorsAPS6object10ModuleInfo _moduleinfo_tlsdtors;
    alias _D6object22_moduleinfo_tlsdtors_ik                    _moduleinfo_tlsdtors_i;
}

void main()
{
    writeln("tlsdtors = [ ", _moduleinfo_tlsdtors[0 .. _moduleinfo_tlsdtors_i], " ]");
}


