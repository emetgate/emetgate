import json
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EXE = os.environ.get("EMETGATE_BIN") or os.path.join(ROOT, "zig-out", "bin", "emetgate.exe")
RUNS = int(os.environ.get("RUNS", "20"))

SOURCE = "export function add(a: number, b: number): number {\n  return a + b;\n}\n"
BODIES = ["{\n  return a + b;\n}", "{\n  return b + a;\n}"]
TEST_CMD = "exit 0"
RULE_CMD = "cmd:exit 0"


def run(argv, cwd):
    return subprocess.run(argv, cwd=cwd, capture_output=True, text=True)


def make_repo(base):
    root = os.path.join(base, "repo")
    os.makedirs(os.path.join(root, "src"))
    with open(os.path.join(root, "src", "math.ts"), "w", encoding="utf-8", newline="") as f:
        f.write(SOURCE)
    for argv in (
        ["git", "init", "-q"],
        ["git", "config", "user.email", "t@t"],
        ["git", "config", "user.name", "t"],
        ["git", "add", "."],
        ["git", "commit", "-q", "-m", "init"],
    ):
        assert run(argv, root).returncode == 0, argv
    return root


def current_hash(root):
    out = run([EXE, "symbols", "src/math.ts", "--json"], root).stdout.strip().splitlines()[-1]
    for entry in json.loads(out)["symbols"]:
        if entry["ref"] == "add":
            return entry["hash"]
    raise KeyError("add")


def one_proposal(root, body):
    started = time.perf_counter()
    result = run(
        [EXE, "try", "src/math.ts", "--symbol", "add", "--hash", current_hash(root),
         "--body", body, "--test", TEST_CMD, "--json"],
        root,
    )
    elapsed = time.perf_counter() - started
    payload = json.loads(result.stdout.strip().splitlines()[-1])
    if payload.get("status") != "committed":
        raise SystemExit(f"proposal did not commit: {result.stdout} {result.stderr}")
    return elapsed


def prepare(tmp, name, with_rule):
    root = make_repo(os.path.join(tmp, name))
    if with_rule:
        added = run([EXE, "rule", "add", "cost probe", "--check", RULE_CMD, "--enforce"], root)
        assert added.returncode == 0, added.stderr
    one_proposal(root, BODIES[0])
    return root


def measure():
    tmp = tempfile.mkdtemp()
    try:
        plain = prepare(tmp, "plain", False)
        ruled = prepare(tmp, "ruled", True)
        without, with_rule = [], []
        for i in range(RUNS):
            body = BODIES[i % 2]
            without.append(one_proposal(plain, body))
            with_rule.append(one_proposal(ruled, body))
        return without, with_rule
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def report(label, samples):
    ordered = sorted(samples)
    print(
        f"{label:<22} n={len(samples)} median={statistics.median(ordered) * 1000:8.1f} ms  "
        f"worst={ordered[-1] * 1000:8.1f} ms  best={ordered[0] * 1000:8.1f} ms"
    )
    return statistics.median(ordered), ordered[-1]


if __name__ == "__main__":
    if not os.path.exists(EXE):
        raise SystemExit(f"emetgate binary not found at {EXE}; run `zig build`")
    without, with_rule = measure()
    base_median, _ = report("no command rule", without)
    rule_median, _ = report("one command rule", with_rule)
    paired = sorted(b - a for a, b in zip(without, with_rule))
    print(
        f"{'added per proposal':<22} n={len(paired)} median={statistics.median(paired) * 1000:8.1f} ms  "
        f"worst={paired[-1] * 1000:8.1f} ms  best={paired[0] * 1000:8.1f} ms"
    )
    print(f"{'medians differ by':<22} {(rule_median - base_median) * 1000:8.1f} ms")
    sys.exit(0)
