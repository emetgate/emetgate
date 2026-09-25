import ctypes
import ctypes.wintypes as wt
import subprocess

advapi32 = ctypes.windll.advapi32
kernel32 = ctypes.windll.kernel32

kernel32.GetCurrentProcess.restype = wt.HANDLE
kernel32.GetCurrentProcess.argtypes = []
kernel32.CreateFileW.restype = wt.HANDLE
kernel32.CreateFileW.argtypes = [wt.LPCWSTR, wt.DWORD, wt.DWORD, ctypes.c_void_p, wt.DWORD, wt.DWORD, wt.HANDLE]
kernel32.WaitForSingleObject.restype = wt.DWORD
kernel32.WaitForSingleObject.argtypes = [wt.HANDLE, wt.DWORD]
kernel32.GetExitCodeProcess.argtypes = [wt.HANDLE, ctypes.POINTER(wt.DWORD)]
kernel32.TerminateProcess.argtypes = [wt.HANDLE, wt.UINT]
kernel32.CloseHandle.argtypes = [wt.HANDLE]
advapi32.OpenProcessToken.argtypes = [wt.HANDLE, wt.DWORD, ctypes.POINTER(wt.HANDLE)]
advapi32.CreateRestrictedToken.argtypes = [
    wt.HANDLE, wt.DWORD, wt.DWORD, ctypes.c_void_p, wt.DWORD, ctypes.c_void_p, wt.DWORD, ctypes.c_void_p, ctypes.POINTER(wt.HANDLE)
]
advapi32.SetTokenInformation.argtypes = [wt.HANDLE, ctypes.c_int, ctypes.c_void_p, wt.DWORD]
advapi32.ConvertStringSidToSidW.argtypes = [wt.LPCWSTR, ctypes.POINTER(ctypes.c_void_p)]
advapi32.CreateProcessAsUserW.argtypes = [
    wt.HANDLE, wt.LPCWSTR, wt.LPWSTR, ctypes.c_void_p, ctypes.c_void_p, wt.BOOL, wt.DWORD,
    ctypes.c_void_p, wt.LPCWSTR, ctypes.c_void_p, ctypes.c_void_p,
]


TOKEN_ALL_ACCESS = 0xF01FF
DISABLE_MAX_PRIVILEGE = 0x1
TokenIntegrityLevel = 25
SE_GROUP_INTEGRITY = 0x00000020
CREATE_UNICODE_ENVIRONMENT = 0x00000400
CREATE_NO_WINDOW = 0x08000000
INFINITE = 0xFFFFFFFF
LOW_INTEGRITY_SID = "S-1-16-4096"


class SID_AND_ATTRIBUTES(ctypes.Structure):
    _fields_ = [("Sid", ctypes.c_void_p), ("Attributes", wt.DWORD)]


class TOKEN_MANDATORY_LABEL(ctypes.Structure):
    _fields_ = [("Label", SID_AND_ATTRIBUTES)]


class STARTUPINFOW(ctypes.Structure):
    _fields_ = [
        ("cb", wt.DWORD), ("lpReserved", wt.LPWSTR), ("lpDesktop", wt.LPWSTR), ("lpTitle", wt.LPWSTR),
        ("dwX", wt.DWORD), ("dwY", wt.DWORD), ("dwXSize", wt.DWORD), ("dwYSize", wt.DWORD),
        ("dwXCountChars", wt.DWORD), ("dwYCountChars", wt.DWORD), ("dwFillAttribute", wt.DWORD),
        ("dwFlags", wt.DWORD), ("wShowWindow", wt.WORD), ("cbReserved2", wt.WORD),
        ("lpReserved2", ctypes.c_void_p), ("hStdInput", wt.HANDLE), ("hStdOutput", wt.HANDLE), ("hStdError", wt.HANDLE),
    ]


class SECURITY_ATTRIBUTES(ctypes.Structure):
    _fields_ = [("nLength", wt.DWORD), ("lpSecurityDescriptor", ctypes.c_void_p), ("bInheritHandle", wt.BOOL)]


class PROCESS_INFORMATION(ctypes.Structure):
    _fields_ = [("hProcess", wt.HANDLE), ("hThread", wt.HANDLE), ("dwProcessId", wt.DWORD), ("dwThreadId", wt.DWORD)]


def _check(ok):
    if not ok:
        raise ctypes.WinError(ctypes.get_last_error())


def run_low_integrity(command, cwd, stdout_path, timeout_ms=60000):
    ctypes.set_last_error(0)
    process_token = wt.HANDLE()
    _check(advapi32.OpenProcessToken(kernel32.GetCurrentProcess(), TOKEN_ALL_ACCESS, ctypes.byref(process_token)))

    restricted_token = wt.HANDLE()
    _check(advapi32.CreateRestrictedToken(
        process_token, DISABLE_MAX_PRIVILEGE, 0, None, 0, None, 0, None, ctypes.byref(restricted_token)
    ))
    kernel32.CloseHandle(process_token)

    sid_ptr = ctypes.c_void_p()
    _check(advapi32.ConvertStringSidToSidW(LOW_INTEGRITY_SID, ctypes.byref(sid_ptr)))
    label = TOKEN_MANDATORY_LABEL()
    label.Label.Sid = sid_ptr
    label.Label.Attributes = SE_GROUP_INTEGRITY
    _check(advapi32.SetTokenInformation(restricted_token, TokenIntegrityLevel, ctypes.byref(label), ctypes.sizeof(label)))
    kernel32.LocalFree(sid_ptr)

    inheritable = SECURITY_ATTRIBUTES()
    inheritable.nLength = ctypes.sizeof(SECURITY_ATTRIBUTES)
    inheritable.lpSecurityDescriptor = None
    inheritable.bInheritHandle = True

    out_handle = kernel32.CreateFileW(
        stdout_path, 0x40000000, 0, ctypes.byref(inheritable), 2, 0x80, None
    )
    if not out_handle or out_handle == -1:
        raise ctypes.WinError(ctypes.get_last_error())
    nul_handle = kernel32.CreateFileW("NUL", 0x80000000, 3, ctypes.byref(inheritable), 3, 0, None)
    if not nul_handle or nul_handle == -1:
        raise ctypes.WinError(ctypes.get_last_error())

    startup = STARTUPINFOW()
    startup.cb = ctypes.sizeof(STARTUPINFOW)
    startup.dwFlags = 0x00000100
    startup.hStdOutput = out_handle
    startup.hStdError = out_handle
    startup.hStdInput = nul_handle

    info = PROCESS_INFORMATION()
    cmdline = ctypes.create_unicode_buffer("cmd.exe /d /c " + command)
    ok = advapi32.CreateProcessAsUserW(
        restricted_token, None, cmdline, None, None, True,
        CREATE_UNICODE_ENVIRONMENT | CREATE_NO_WINDOW, None, cwd, ctypes.byref(startup), ctypes.byref(info)
    )
    kernel32.CloseHandle(out_handle)
    kernel32.CloseHandle(nul_handle)
    if not ok:
        err = ctypes.get_last_error()
        kernel32.CloseHandle(restricted_token)
        raise ctypes.WinError(err)

    wait = kernel32.WaitForSingleObject(info.hProcess, timeout_ms)
    timed_out = wait == 0x102
    exit_code = wt.DWORD()
    if not timed_out:
        kernel32.GetExitCodeProcess(info.hProcess, ctypes.byref(exit_code))
    else:
        kernel32.TerminateProcess(info.hProcess, 1)
    kernel32.CloseHandle(info.hProcess)
    kernel32.CloseHandle(info.hThread)
    kernel32.CloseHandle(restricted_token)
    return {"timed_out": timed_out, "exit_code": None if timed_out else exit_code.value}


def run_normal(command, cwd, timeout_s):
    out = subprocess.run(["cmd", "/d", "/c", command], cwd=cwd, capture_output=True, text=True, timeout=timeout_s)
    return out
