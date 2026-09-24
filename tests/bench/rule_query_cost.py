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
RUNS = int(os.environ.get("RUNS", "30"))

SOURCE = "export function add(a: number, b: number): number {\n  return a + b;\n}\n"
BODIES = ["{\n  return a + b;\n}", "{\n  return b + a;\n}"]
TEST_CMD = "exit 0"
RULE_Q = 'q:((call_expression function: (identifier) @violation) (#match? @violation "^(eval|scrape.*Api)$"))'
BUDGET_Q = 'q:((string_fragment) @violation (#match? @violation "' + "a?" * 1500 + 'b"))'


def run(argv, cwd):
    return subprocess.run(argv, cwd=cwd, capture_output=True, text=True)


def make_repo(base, files):
    root = os.path.join(base, "repo")
    os.makedirs(os.path.join(root, "src"))
    for rel, text in files.items():
        with open(os.path.join(root, rel), "w", encoding="utf-8", newline="") as f:
            f.write(text)
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


def one_proposal(root, body, expect="committed"):
    started = time.perf_counter()
    result = run(
        [EXE, "try", "src/math.ts", "--symbol", "add", "--hash", current_hash(root),
         "--body", body, "--test", TEST_CMD, "--json"],
        root,
    )
    elapsed = time.perf_counter() - started
    payload = json.loads(result.stdout.strip().splitlines()[-1])
    got = payload.get("status") if expect == "committed" else payload.get("reason")
    if got != expect:
        raise SystemExit(f"expected {expect}: {result.stdout} {result.stderr}")
    return elapsed, payload


def prepare(tmp, name, rule):
    root = make_repo(os.path.join(tmp, name), {"src/math.ts": SOURCE})
    if rule:
        added = run([EXE, "rule", "add", "cost probe", "--check", rule, "--enforce"], root)
        assert added.returncode == 0, added.stderr
    one_proposal(root, BODIES[0])
    return root


def paired(tmp):
    plain = prepare(tmp, "plain", None)
    ruled = prepare(tmp, "ruled", RULE_Q)
    without, with_rule = [], []
    for i in range(RUNS):
        body = BODIES[i % 2]
        without.append(one_proposal(plain, body)[0])
        with_rule.append(one_proposal(ruled, body)[0])
    return without, with_rule


def budget_ceiling(tmp):
    root = prepare(tmp, "budget", BUDGET_Q)
    body = "{\n  const s = \"" + "a" * 20000 + "\";\n  return a + b + s.length;\n}"
    samples = []
    for _ in range(5):
        elapsed, payload = one_proposal(root, body, expect="rule_check_crashed")
        assert payload["detail"] == "query_budget_exceeded", payload
        samples.append(elapsed)
    return samples


def report(label, samples):
    ordered = sorted(samples)
    print(
        f"{label:<26} n={len(samples)} median={statistics.median(ordered) * 1000:8.1f} ms  "
        f"worst={ordered[-1] * 1000:8.1f} ms  best={ordered[0] * 1000:8.1f} ms"
    )
    return statistics.median(ordered)


if __name__ == "__main__":
    if not os.path.exists(EXE):
        raise SystemExit(f"emetgate binary not found at {EXE}; run `zig build`")
    tmp = tempfile.mkdtemp()
    try:
        without, with_rule = paired(tmp)
        report("no q: rule", without)
        report("one q: rule", with_rule)
        report("added per proposal", [b - a for a, b in zip(without, with_rule)])
        report("budget exhausted", budget_ceiling(tmp))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    sys.exit(0)
