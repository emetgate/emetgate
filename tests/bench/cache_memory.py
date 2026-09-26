import ctypes
import json
import os
import subprocess
import sys
import time

BENCH = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(BENCH))
_exe = "emetgate.exe" if os.name == "nt" else "emetgate"
SYN = os.environ.get("EMETGATE_BIN") or os.path.join(ROOT, "zig-out", "bin", _exe)
if not os.path.exists(SYN):
    raise SystemExit(f"emetgate binary not found at {SYN}; run `zig build` or set EMETGATE_BIN")

ESLINT_TEST = os.environ.get(
    "ESLINT_TEST", r"C:\Users\ugur\Desktop\projects\emetgate\eval\eslint-test"
)


class GT(ctypes.Structure):
    _fields_ = [
        ("cb", ctypes.c_uint32),
        ("PageFaultCount", ctypes.c_uint32),
        ("PeakWorkingSetSize", ctypes.c_size_t),
        ("WorkingSetSize", ctypes.c_size_t),
        ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
        ("QuotaPagedPoolUsage", ctypes.c_size_t),
        ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
        ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
        ("PagefileUsage", ctypes.c_size_t),
        ("PeakPagefileUsage", ctypes.c_size_t),
    ]


def peak_working_set(pid):
    info = GT()
    info.cb = ctypes.sizeof(GT)
    handle = ctypes.windll.kernel32.OpenProcess(0x1000 | 0x0400, False, pid)
    if not handle:
        raise OSError("OpenProcess failed")
    try:
        ok = ctypes.windll.psapi.GetProcessMemoryInfo(handle, ctypes.byref(info), info.cb)
        if not ok:
            raise OSError("GetProcessMemoryInfo failed")
        return info.PeakWorkingSetSize, info.PeakPagefileUsage
    finally:
        ctypes.windll.kernel32.CloseHandle(handle)


def tracked_source_bytes(root):
    out = subprocess.run(["git", "ls-files"], cwd=root, capture_output=True, text=True, check=True)
    total = 0
    for rel in out.stdout.splitlines():
        path = os.path.join(root, rel)
        if os.path.isfile(path):
            total += os.path.getsize(path)
    return total


def run_scan(mirror):
    args = [SYN, "mcp"]
    if mirror:
        args.append("--mirror")
    proc = subprocess.Popen(
        args,
        cwd=ESLINT_TEST,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    msg_id = 0

    def send(method, params):
        nonlocal msg_id
        msg_id += 1
        proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": msg_id, "method": method, "params": params}) + "\n")
        proc.stdin.flush()
        line = proc.stdout.readline()
        if not line:
            raise RuntimeError(f"no response; stderr: {proc.stderr.read()}")
        return json.loads(line)

    send("initialize", {"protocolVersion": "2025-06-18"})
    before, before_page = peak_working_set(proc.pid)
    send("tools/call", {"name": "emetgate_scan", "arguments": {"check": "forbid:networkidle"}})
    after, after_page = peak_working_set(proc.pid)
    proc.stdin.close()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
    return before, after, after_page


def main():
    if not os.path.exists(ESLINT_TEST):
        raise SystemExit(f"eslint-test clone not found at {ESLINT_TEST}")
    source_bytes = tracked_source_bytes(ESLINT_TEST)
    before, after, peak_page = run_scan(mirror=False)
    print(f"tracked source bytes (git ls-files):     {source_bytes:>12}")
    print(f"process working set before scan:         {before:>12}")
    print(f"process working set after one full scan: {after:>12}")
    print(f"process peak pagefile usage:              {peak_page:>12}")
    grown = max(after - before, 0)
    print(f"working set growth attributable to scan: {grown:>12}")
    if source_bytes:
        print(f"growth / tracked source bytes ratio:     {grown / source_bytes:>12.2f}x")


if __name__ == "__main__":
    main()
