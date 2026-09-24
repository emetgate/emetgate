import json
import os
import subprocess
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))))
EXE = os.environ.get("EMETGATE_BIN") or os.path.join(ROOT, "zig-out", "bin", "emetgate.exe")


def run(argv, cwd=None, timeout=None):
    return subprocess.run(argv, cwd=cwd, capture_output=True, text=True, timeout=timeout)


def make_repo(name, files):
    base = os.path.join(tempfile.gettempdir(), "emetgate-repro-" + name)
    if os.path.isdir(base):
        run(["cmd", "/c", "rmdir", "/s", "/q", base])
    os.makedirs(base)
    for rel, content in files.items():
        path = os.path.join(base, rel)
        os.makedirs(os.path.dirname(path) or base, exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(content)
    run(["git", "init", "-q"], cwd=base)
    run(["git", "config", "user.email", "repro@example.com"], cwd=base)
    run(["git", "config", "user.name", "repro"], cwd=base)
    run(["git", "add", "-A"], cwd=base)
    run(["git", "commit", "-q", "-m", "init"], cwd=base)
    return base


def target_hash(repo, rel, ref):
    out = run([EXE, "symbols", os.path.join(repo, rel), "--json"], timeout=20)
    data = json.loads(out.stdout)
    target = next(s for s in data["symbols"] if s["ref"] == ref)
    return target["hash"]


def run_outside_sandbox(cwd, command, timeout_s=30):
    t0 = time.perf_counter()
    try:
        out = subprocess.run(["cmd", "/d", "/c", command], cwd=cwd, capture_output=True, text=True, timeout=timeout_s)
        elapsed = (time.perf_counter() - t0) * 1000
        return {"returncode": out.returncode, "elapsed_ms": elapsed, "stdout_tail": out.stdout[-1000:], "stderr_tail": out.stderr[-1000:]}
    except subprocess.TimeoutExpired:
        return {"returncode": None, "elapsed_ms": timeout_s * 1000, "stdout_tail": "", "stderr_tail": "timeout"}


def run_inside_sandbox(repo, rel, ref, command, timeout_s=90):
    before_hash = target_hash(repo, rel, ref)
    argv = [
        EXE, "try", os.path.join(repo, rel),
        "--symbol", ref, "--hash", before_hash,
        "--body", "{ return 2; }",
        "--test", command,
        "--json",
    ]
    t0 = time.perf_counter()
    out = run(argv, timeout=timeout_s)
    elapsed = (time.perf_counter() - t0) * 1000
    try:
        parsed = json.loads(out.stdout) if out.stdout.strip() else None
    except json.JSONDecodeError:
        parsed = None
    return {"returncode": out.returncode, "elapsed_ms": elapsed, "parsed": parsed, "stdout_tail": out.stdout[-1500:]}


def report(name, outside, inside):
    print(f"=== {name} ===")
    print("outside sandbox:", outside["returncode"], round(outside["elapsed_ms"], 1), "ms")
    if outside["returncode"] not in (0, None):
        print("  stderr:", outside["stderr_tail"][:300])
    print("inside sandbox: ", inside["returncode"], round(inside["elapsed_ms"], 1), "ms")
    print("  parsed:", inside["parsed"])
