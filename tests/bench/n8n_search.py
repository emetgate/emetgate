import argparse
import json
import os
import statistics
import subprocess
import sys
import time

BENCH = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BENCH)
from n8n_profile import DEFAULT_EXE, DEFAULT_REPO, McpSession, first_json, percentile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(BENCH)), "vendor", "pure_python_blake3"))
from pure_blake3 import Hasher

INDEX_ROOT = os.path.join(os.environ.get("LOCALAPPDATA", ""), "emetgate", "index")
ENGINE = "packages/core/src/execution-engine"
WORKFLOW = ENGINE + "/workflow-execute.ts"
WRITE_FILE = ENGINE + "/routing-node.ts"

QUERIES = [
    ("a rare name in one package", {"pattern": "continueOnFail", "dir": ENGINE, "kinds": ["code"]}, False),
    ("a common name in one package", {"pattern": "onError", "dir": ENGINE}, False),
    ("a regex with four alternatives", {"pattern": "continuesOnError\\(|onError ===|handleNodeErrorOutput|continueErrorOutput", "regex": True, "dir": ENGINE}, True),
    ("a name across the whole repository", {"pattern": "handleNodeExecutionError", "dir": "."}, False),
    ("a name in one file", {"pattern": "continueOnFail", "dir": WORKFLOW}, False),
]

READS = [
    ("read one symbol", "emetgate_read_symbol", {"file": WORKFLOW, "symbols": ["WorkflowExecute.continuesOnError"]}),
    ("read a line range", "emetgate_read_file", {"file": WORKFLOW, "raw": True, "line_start": 1355, "line_end": 1385}),
]


def timed(args, cwd):
    started = time.perf_counter()
    subprocess.run(args, cwd=cwd, stdin=subprocess.DEVNULL, capture_output=True)
    return (time.perf_counter() - started) * 1000


def rg_ms(repo, args, samples):
    cmd = ["rg", "-n", "--no-heading"]
    if not args.get("regex"):
        cmd.append("-F")
    cmd += ["-e", args["pattern"], args["dir"]]
    return statistics.median(timed(cmd, repo) for _ in range(samples))


def git_ms(repo, args, samples):
    cmd = ["git", "grep", "-n", "-E" if args.get("regex") else "-F", "-e", args["pattern"], "--", args["dir"]]
    return statistics.median(timed(cmd, repo) for _ in range(samples))


def with_stats(args):
    out = dict(args)
    out["stats"] = True
    return out


def new_session(exe, repo, args, delay, sessions):
    first = []
    warm_wait = []
    warmup = []
    for _ in range(sessions):
        session = McpSession(exe, repo)
        try:
            if delay:
                time.sleep(delay)
            text, _, ms = session.call("emetgate_search", with_stats(args))
            first.append(ms)
            stats = (first_json(text) or {}).get("stats", {})
            warm_wait.append(stats.get("warm_wait_ms", 0))
            warmup.append(stats.get("warmup_ms", 0))
        finally:
            session.close()
    return statistics.median(first), statistics.median(warm_wait), statistics.median(warmup), max(warmup)


def warm(session, args, runs):
    trips = []
    kernel = []
    barrier = []
    for _ in range(runs):
        text, _, ms = session.call("emetgate_search", with_stats(args))
        trips.append(ms)
        stats = (first_json(text) or {}).get("stats", {})
        kernel.append(stats.get("total_ms", 0))
        barrier.append(stats.get("sync_ms", 0))
    return trips, kernel, barrier


def after_write(session, repo, args, runs):
    path = os.path.join(repo, WRITE_FILE)
    original = open(path, "rb").read()
    trips = []
    try:
        for i in range(runs):
            with open(path, "wb") as out:
                out.write(original + f"\n// bench_write_{i}\n".encode())
            _, _, ms = session.call("emetgate_search", args)
            trips.append(ms)
    finally:
        with open(path, "wb") as out:
            out.write(original)
    return statistics.median(trips)


def repo_key(repo):
    path = os.path.abspath(repo).rstrip("\\/")
    hasher = Hasher()
    hasher.update(path.replace("/", "\\").lower().encode("utf-8"))
    return hasher.finalize(16).hex()


def index_size(repo):
    folder = os.path.join(INDEX_ROOT, repo_key(repo))
    pointer = os.path.join(folder, "index.v4")
    if not os.path.exists(pointer):
        return None
    tag = open(pointer, encoding="utf-8").read().strip()
    image = os.path.join(folder, "index.v4." + tag)
    return os.path.getsize(image) if os.path.exists(image) else None


def tracked_bytes(repo):
    out = subprocess.run(["git", "ls-files", "-z"], cwd=repo, capture_output=True, check=True).stdout.decode("utf-8")
    total = 0
    indexed = 0
    count = 0
    for name in out.split("\0"):
        if not name:
            continue
        try:
            size = os.path.getsize(os.path.join(repo, name))
        except OSError:
            continue
        count += 1
        total += size
        if size <= 1024 * 1024:
            indexed += size
    return total, indexed, count


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", default=DEFAULT_EXE)
    ap.add_argument("--repo", default=DEFAULT_REPO)
    ap.add_argument("--samples", type=int, default=10)
    ap.add_argument("--sessions", type=int, default=5)
    ap.add_argument("--runs", type=int, default=50)
    ap.add_argument("--json")
    args = ap.parse_args()
    repo = os.path.abspath(args.repo)
    McpSession(args.exe, repo).close()
    rows = []
    session = McpSession(args.exe, repo)
    try:
        for name, call, _ in QUERIES:
            session.call("emetgate_search", call)
            trips, kernel, barrier = warm(session, call, args.runs)
            write_ms = after_write(session, repo, call, max(10, args.runs // 5))
            rows.append({
                "name": name,
                "rg_ms": round(rg_ms(repo, call, args.samples), 1),
                "git_ms": round(git_ms(repo, call, args.samples), 1),
                "warm_p50_ms": round(percentile(trips, 0.5), 2),
                "warm_p99_ms": round(percentile(trips, 0.99), 2),
                "kernel_p50_ms": round(percentile(kernel, 0.5), 2),
                "kernel_p99_ms": round(percentile(kernel, 0.99), 2),
                "barrier_p50_ms": round(percentile(barrier, 0.5), 2),
                "after_write_ms": round(write_ms, 2),
            })
        reads = []
        for name, tool, call in READS:
            session.call(tool, call)
            trips = []
            for _ in range(args.runs):
                _, _, ms = session.call(tool, call)
                trips.append(ms)
            reads.append({"name": name, "p50_ms": round(percentile(trips, 0.5), 2), "p99_ms": round(percentile(trips, 0.99), 2)})
        ping = []
        for _ in range(args.runs):
            started = time.perf_counter()
            session.send("ping", {})
            ping.append((time.perf_counter() - started) * 1000)
    finally:
        session.close()
    for row, (name, call, _) in zip(rows, QUERIES):
        row["new_now_ms"], row["warm_wait_ms"], row["warmup_ms"], row["warmup_max_ms"] = [round(v, 1) for v in new_session(args.exe, repo, call, 0, args.sessions)]
        row["new_3s_ms"] = round(new_session(args.exe, repo, call, 3, args.sessions)[0], 2)
    size = index_size(repo)
    total, indexed, count = tracked_bytes(repo)
    out = {
        "date": time.strftime("%Y-%m-%d"),
        "repo": "n8n",
        "ping_p50_ms": round(percentile(ping, 0.5), 3),
        "index_bytes": size,
        "tracked_files": count,
        "tracked_bytes": total,
        "indexable_bytes": indexed,
        "rows": rows,
        "reads": reads,
    }
    print(json.dumps(out, indent=2))
    if args.json:
        with open(args.json, "w", encoding="utf-8", newline="\n") as f:
            json.dump(out, f, indent=2)
            f.write("\n")


if __name__ == "__main__":
    main()
