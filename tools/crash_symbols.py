import ctypes
import ctypes.wintypes as wt
import os
import re
import struct
import sys

DYNAMIC_BASE = 0x0040
HIGH_ENTROPY_VA = 0x0020
USAGE = """usage: python -I tools/crash_symbols.py fix-base EXE
       python -I tools/crash_symbols.py name EXE FOLDER...
fix-base clears the dynamic-base flag of EXE so it loads at its preferred address.
name prints each stack address of every stderr-*.txt under FOLDER with the function and line the PDB beside EXE gives."""


def _optional_header(data):
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe:pe + 4] != b"PE\0\0":
        raise SystemExit("not a PE file")
    opt = pe + 24
    if struct.unpack_from("<H", data, opt)[0] != 0x20B:
        raise SystemExit("not a 64-bit PE file")
    return opt


def image_base(exe):
    data = open(exe, "rb").read()
    return struct.unpack_from("<Q", data, _optional_header(data) + 24)[0]


def fix_base(exe):
    data = bytearray(open(exe, "rb").read())
    at = _optional_header(data) + 70
    flags = struct.unpack_from("<H", data, at)[0]
    struct.pack_into("<H", data, at, flags & ~DYNAMIC_BASE & ~HIGH_ENTROPY_VA)
    open(exe, "wb").write(bytes(data))
    print("%s loads at 0x%x" % (exe, image_base(exe)))


class _Symbol(ctypes.Structure):
    _fields_ = [("SizeOfStruct", wt.ULONG), ("TypeIndex", wt.ULONG), ("Reserved", ctypes.c_ulonglong * 2),
                ("Index", wt.ULONG), ("Size", wt.ULONG), ("ModBase", ctypes.c_ulonglong), ("Flags", wt.ULONG),
                ("Value", ctypes.c_ulonglong), ("Address", ctypes.c_ulonglong), ("Register", wt.ULONG),
                ("Scope", wt.ULONG), ("Tag", wt.ULONG), ("NameLen", wt.ULONG), ("MaxNameLen", wt.ULONG),
                ("Name", ctypes.c_char * 1024)]


class _Line(ctypes.Structure):
    _fields_ = [("SizeOfStruct", wt.DWORD), ("Key", ctypes.c_void_p), ("LineNumber", wt.DWORD),
                ("FileName", ctypes.c_char_p), ("Address", ctypes.c_ulonglong)]


def _symbolizer(exe):
    dbg = ctypes.WinDLL("dbghelp.dll")
    process = wt.HANDLE(0x5E7)
    dbg.SymSetOptions(0x2 | 0x10)
    dbg.SymInitialize.argtypes = [wt.HANDLE, ctypes.c_char_p, wt.BOOL]
    if not dbg.SymInitialize(process, os.path.dirname(os.path.abspath(exe)).encode(), False):
        raise SystemExit("dbghelp could not start")
    dbg.SymLoadModuleEx.argtypes = [wt.HANDLE, wt.HANDLE, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_ulonglong, wt.DWORD, ctypes.c_void_p, wt.DWORD]
    dbg.SymLoadModuleEx.restype = ctypes.c_ulonglong
    if not dbg.SymLoadModuleEx(process, None, os.path.abspath(exe).encode(), None, image_base(exe), 0, None, 0):
        raise SystemExit("dbghelp could not load %s" % exe)
    dbg.SymFromAddr.argtypes = [wt.HANDLE, ctypes.c_ulonglong, ctypes.POINTER(ctypes.c_ulonglong), ctypes.POINTER(_Symbol)]
    dbg.SymGetLineFromAddr64.argtypes = [wt.HANDLE, ctypes.c_ulonglong, ctypes.POINTER(wt.DWORD), ctypes.POINTER(_Line)]

    def name(address):
        symbol = _Symbol()
        symbol.SizeOfStruct = ctypes.sizeof(_Symbol) - 1024
        symbol.MaxNameLen = 1024
        offset = ctypes.c_ulonglong(0)
        function = symbol.Name.decode(errors="replace") if dbg.SymFromAddr(process, address, ctypes.byref(offset), ctypes.byref(symbol)) else "?"
        line = _Line()
        line.SizeOfStruct = ctypes.sizeof(_Line)
        column = wt.DWORD(0)
        where = "%s:%d" % (line.FileName.decode(errors="replace"), line.LineNumber) if dbg.SymGetLineFromAddr64(process, address, ctypes.byref(column), ctypes.byref(line)) else ""
        return function, where

    return name


def name_dumps(exe, folders):
    dumps = []
    for folder in folders:
        for top, _, files in os.walk(folder):
            dumps.extend(os.path.join(top, f) for f in files if re.match(r"stderr-.*\.txt$", f))
    if not dumps:
        print("no stderr dump under %s" % ", ".join(folders))
        return
    name = _symbolizer(exe)
    for dump in sorted(dumps):
        text = open(dump, encoding="utf-8", errors="replace").read()
        print("== %s" % dump)
        first = text.strip().splitlines()[:1]
        if first:
            print(first[0])
        seen = []
        for hex_address in re.findall(r"0x([0-9a-fA-F]{8,16}) in", text):
            address = int(hex_address, 16)
            if address in seen:
                continue
            seen.append(address)
            function, where = name(address)
            print("  0x%x  %s  %s" % (address, function, where))


def main(argv):
    if len(argv) >= 2 and argv[0] == "fix-base":
        fix_base(argv[1])
    elif len(argv) >= 3 and argv[0] == "name":
        name_dumps(argv[1], argv[2:])
    else:
        print(USAGE)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
