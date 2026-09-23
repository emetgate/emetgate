import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EXE = os.environ.get("EMETGATE_BIN") or os.path.join(ROOT, "zig-out", "bin", "emetgate.exe")
SIZES = [int(n) for n in os.environ.get("SIZES", "2000,4000,8000,16000").split(",")]
TIMEOUT_S = float(os.environ.get("TIMEOUT_S", "60"))
SUPERLINEAR = float(os.environ.get("SUPERLINEAR", "1.35"))

SHAPES = {
    "statements": lambda n: "a;\n" * n,
    "arguments": lambda n: "f(" + "a, " * n + "a);\n",
    "array": lambda n: "x = [" + "1, " * n + "1];\n",
    "binary_chain": lambda n: "x = a" + " + a" * n + ";\n",
    "nested_calls": lambda n: "x = " + "f(" * min(n, 4000) + "a" + ")" * min(n, 4000) + ";\n" + "a;\n" * max(0, n - 4000),
    "members": lambda n: "x = a" + ".b" * n + ";\n",
}

EIGHT_ANCHORED = "(program (_) @violation" + " . (_) @violation" * 7 + ")"
EIGHT_LOOSE = "(program (_) @violation" + " (_) @violation" * 7 + ")"

QUERIES = {
    "baseline identifier": "(identifier) @violation",
    "wildcard every node": "(_) @violation",
    "uncaptured + child": "((_ (_)+) @violation)",
    "uncaptured * child": "((_ (_)*) @violation)",
    "optional capture": "(_ . (_)? @violation)",
    "two anchored siblings": "(_ (_) @violation . (_) @violation)",
    "two loose siblings": "(_ (_) @violation (_) @violation)",
    "eight anchored siblings": EIGHT_ANCHORED,
    "eight loose siblings": EIGHT_LOOSE,
    "eight anchored + #eq? all": "(" + EIGHT_ANCHORED + " (#eq? @violation @violation))",
    "alternation 3 kinds": "[(identifier) (number) (property_identifier)] @violation",
    "alternation with captures": "(_ [(identifier) @violation (number) @violation (call_expression) @violation])",
    "nested 3 levels": "(_ (_ (_) @violation))",
    "nested 6 levels": "(_ (_ (_ (_ (_ (_) @violation)))))",
    "first child anchor": "(_ . (_) @violation)",
    "last child anchor": "(_ (_) @violation .)",
    "uncaptured * then last": "(_ (_)* . (_) @violation .)",
    "field + negated field": "(call_expression function: (_) @violation !type_arguments)",
    "#eq? two captures": "((_ (identifier) @violation . (identifier) @b) (#eq? @violation @b))",
    "#match? regex": "((identifier) @violation (#match? @violation \"^(a|b)+$\"))",
    "#any-of? 50 strings": "((identifier) @violation (#any-of? @violation " + " ".join(f'"w{i}"' for i in range(50)) + "))",
    "#not-eq? on wildcard": "((_) @violation (#not-eq? @violation \"zz\"))",
}


def run(argv, cwd, timeout=None):
    return subprocess.run(argv, cwd=cwd, capture_output=True, text=True, timeout=timeout)


def make_repo(base):
    root = os.path.join(base, "repo")
    os.makedirs(os.path.join(root, "src"))
    write_source(root, "a;\n")
    for argv in (["git", "init", "-q"], ["git", "add", "src/w.ts"]):
        assert run(argv, root).returncode == 0, argv
    return root


def write_source(root, text):
    with open(os.path.join(root, "src", "w.ts"), "w", encoding="utf-8", newline="") as f:
        f.write(text)


def scan(root, query):
    started = time.perf_counter()
    try:
        result = run([EXE, "scan", "--check", "q:" + query, "--in", "src/w.ts", "--json"], root, TIMEOUT_S)
    except subprocess.TimeoutExpired:
        return TIMEOUT_S, "timeout"
    elapsed = time.perf_counter() - started
    lines = result.stdout.strip().splitlines()
    if not lines:
        return elapsed, f"exit {result.returncode}"
    payload = json.loads(lines[-1])
    status = payload.get("status", "?")
    if status == "check_failed":
        details = {f.get("detail") for f in payload.get("check_failures", [])}
        status = "failed:" + ",".join(sorted(d for d in details if d))
    elif status == "error":
        status = "refused:" + str(payload.get("error"))
    return elapsed, status


def exponent(sizes, times):
    pairs = [(a, b, ta, tb) for (a, ta), (b, tb) in zip(zip(sizes, times), zip(sizes[1:], times[1:])) if ta > 0.02 and tb > 0]
    if not pairs:
        return 0.0
    a, b, ta, tb = pairs[-1]
    return math.log(tb / ta) / math.log(b / a)


def main():
    if not os.path.exists(EXE):
        raise SystemExit(f"emetgate binary not found at {EXE}; run `zig build -Doptimize=ReleaseSafe`")
    tmp = tempfile.mkdtemp()
    rows = []
    try:
        root = make_repo(tmp)
        for shape, build in SHAPES.items():
            baseline = []
            for n in SIZES:
                write_source(root, build(n))
                baseline.append(scan(root, "(comment) @violation")[0])
            for name, query in QUERIES.items():
                times, statuses = [], []
                for n, base in zip(SIZES, baseline):
                    write_source(root, build(n))
                    elapsed, status = scan(root, query)
                    times.append(max(0.0, elapsed - base))
                    statuses.append(status)
                    if status == "timeout":
                        break
                k = exponent(SIZES[: len(times)], times)
                flag = "SUPERLINEAR" if k > SUPERLINEAR or "timeout" in statuses else ""
                rows.append((shape, name, times, statuses, k, flag))
                cells = " ".join(f"{t * 1000:9.0f}" for t in times)
                print(f"{flag:<11} {shape:<13} {name:<28} k={k:5.2f}  ms[{cells}]  {statuses[-1]}", flush=True)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    flagged = [r for r in rows if r[5]]
    print(f"\nsizes {SIZES}; {len(rows)} combinations, {len(flagged)} grow faster than n^{SUPERLINEAR}")
    for shape, name, times, statuses, k, _ in flagged:
        print(f"  {shape} / {name}: k={k:.2f}, {times[-1] * 1000:.0f} ms at n={SIZES[len(times) - 1]}, {statuses[-1]}")
    return 1 if flagged else 0


if __name__ == "__main__":
    sys.exit(main())
