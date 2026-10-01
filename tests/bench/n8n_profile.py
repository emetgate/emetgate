import argparse
import json
import math
import os
import statistics
import subprocess
import sys
import time

BENCH = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(BENCH))
PROJECT_ROOT = os.path.dirname(ROOT)
_exe = "emetgate.exe" if os.name == "nt" else "emetgate"
DEFAULT_EXE = os.environ.get("EMETGATE_BIN") or os.path.join(ROOT, "zig-out", "bin", _exe)
DEFAULT_REPO = os.environ.get("EMETGATE_N8N") or os.path.join(PROJECT_ROOT, "eval", "n8n-bench")

ENGINE = "packages/core/src/execution-engine"
WORKFLOW = ENGINE + "/workflow-execute.ts"

CALLS = [
    ("emetgate_search", {"pattern": "continueOnFail", "dir": ENGINE, "kinds": ["code"]}),
    ("emetgate_search", {"pattern": "continuesOnError|onError", "regex": True, "dir": WORKFLOW, "kinds": ["code"]}),
    ("emetgate_read_symbol", {"file": WORKFLOW, "symbols": ["WorkflowExecute.continuesOnError"]}),
    ("emetgate_search", {"pattern": "continuesOnError\\(|onError ===|handleNodeErrorOutput|continueErrorOutput", "regex": True, "dir": ENGINE, "kinds": ["code", "string"]}),
    ("emetgate_search", {"pattern": "continuesOnError", "dir": ENGINE}),
    ("emetgate_read_symbol", {"file": WORKFLOW, "symbols": ["WorkflowExecute.handleNodeExecutionError"]}),
    ("emetgate_read_symbol", {"file": WORKFLOW, "line_start": 1355, "line_end": 1380, "nodes": True}),
    ("emetgate_search", {"pattern": "handleNodeExecutionError(|continueExecution", "regex": False, "dir": ENGINE, "kinds": ["code"]}),
    ("emetgate_search", {"pattern": "handleNodeExecutionError", "dir": ENGINE, "kinds": ["code"]}),
    ("emetgate_read_symbol", {"file": WORKFLOW, "line_start": 2410, "line_end": 2450, "nodes": True}),
    ("emetgate_search", {"pattern": "continueOnFail", "dir": WORKFLOW, "kinds": ["code"]}),
    ("emetgate_search", {"pattern": "continueErrorOutput", "dir": "packages/core/src", "kinds": ["code", "string"]}),
    ("emetgate_read_symbol", {"file": WORKFLOW, "symbols": ["WorkflowExecute.continuesOnError", "WorkflowExecute.processNodeOutput"]}),
    ("emetgate_search", {"pattern": "continuesOnError(", "dir": WORKFLOW}),
    ("emetgate_search", {"pattern": "continuesOnError(", "dir": ENGINE, "kinds": ["code"]}),
    ("emetgate_search", {"pattern": "handleNodeErrorOutput|executionData.node.continueOnFail|onError", "regex": True, "dir": ENGINE, "kinds": ["code"]}),
    ("emetgate_read_symbol", {"file": WORKFLOW, "symbols": ["WorkflowExecute.handleNodeExecutionError", "WorkflowExecute.handleNodeErrorOutput"]}),
    ("emetgate_search", {"pattern": "onError", "dir": ENGINE, "kinds": ["code"]}),
    ("emetgate_read_symbol", {"file": WORKFLOW, "symbols": ["WorkflowExecute.handleNodeExecutionError", "WorkflowExecute.continuesOnError", "WorkflowExecute.rethrowNodeError"]}),
    ("emetgate_read_symbol", {"file": WORKFLOW, "line_start": 2400, "line_end": 2445, "nodes": True}),
    ("emetgate_search", {"pattern": "continuesOnError|handleNodeErrorOutput|onError", "regex": True, "dir": WORKFLOW, "kinds": ["code"]}),
    ("emetgate_read_symbol", {"file": WORKFLOW, "symbol": "WorkflowExecute.continuesOnError"}),
    ("emetgate_search", {"pattern": "continuesOnError\\(|handleNodeErrorOutput\\(|continueErrorOutput|stopExecution|executionError =", "regex": True, "dir": ENGINE, "kinds": ["code"]}),
    ("emetgate_search", {"pattern": "handleNodeErrorOutput", "dir": ENGINE, "kinds": ["code"]}),
    ("emetgate_read_file", {"file": WORKFLOW, "raw": True, "line_start": 1355, "line_end": 1385}),
    ("emetgate_search", {"pattern": "'continueErrorOutput'", "dir": ENGINE, "kinds": ["string"]}),
    ("emetgate_search", {"pattern": "continueOnFail|onError", "regex": True, "dir": ENGINE, "kinds": ["code"]}),
    ("emetgate_search", {"pattern": "continueRegularOutput|continueErrorOutput|stopWorkflow|continuesOnError\\(|handleNodeErrorOutput", "regex": True, "dir": WORKFLOW}),
    ("emetgate_search", {"pattern": "continueRegularOutput|continueErrorOutput|continuesOnError\\(|handleNodeErrorOutput|executionData\\.node\\.onError", "regex": True, "dir": ENGINE, "kinds": ["code"]}),
    ("emetgate_search", {"pattern": "continueErrorOutput", "dir": ENGINE, "kinds": ["code"]}),
    ("emetgate_search", {"pattern": "continueErrorOutput", "dir": ENGINE}),
    ("emetgate_read_symbol", {"file": WORKFLOW, "symbols": ["WorkflowExecute.continuesOnError", "WorkflowExecute.rethrowNodeError"]}),
    ("emetgate_read_symbol", {"file": WORKFLOW, "symbol": "WorkflowExecute.processNodeOutput"}),
    ("emetgate_read_symbol", {"file": WORKFLOW, "symbol": "WorkflowExecute.handleNodeExecutionError"}),
    ("emetgate_read_symbol", {"file": WORKFLOW, "line_start": 1355, "line_end": 1390, "nodes": True}),
    ("emetgate_search", {"pattern": "handleNodeExecutionError|handleNodeErrorOutput(", "regex": False, "dir": WORKFLOW}),
    ("emetgate_read_file", {"file": WORKFLOW, "raw": True, "line_start": 2405, "line_end": 2450}),
    ("emetgate_search", {"pattern": "continuesOnError|handleNodeErrorOutput|onError ===|onError !==", "regex": True, "dir": WORKFLOW, "kinds": ["code"]}),
    ("emetgate_search", {"pattern": "continuesOnError\\(|handleNodeErrorOutput\\(|continueErrorOutput", "regex": True, "dir": ENGINE, "kinds": ["code", "string"]}),
    ("emetgate_search", {"pattern": "continuesOnError", "dir": "packages/core/src"}),
    ("emetgate_read_file", {"file": WORKFLOW, "raw": True, "line_start": 1350, "line_end": 1380}),
    ("emetgate_search", {"pattern": "handleNodeExecutionError|continueExecution", "regex": True, "dir": ENGINE, "kinds": ["code"]}),
]

FIRST_CALLS = [
    ("emetgate_search", {"pattern": "continueOnFail", "dir": ENGINE, "kinds": ["code"]}),
    ("emetgate_search", {"pattern": "continueOnFail", "dir": WORKFLOW, "kinds": ["code"]}),
    ("emetgate_search", {"pattern": "continueOnFail|onError", "regex": True, "dir": ENGINE, "kinds": ["code"]}),
]

SEARCH_STAGES = [
    "total_ms", "jail_ms", "sync_ms", "list_ms", "index_load_ms", "index_refresh_ms", "refresh_stamp_ms",
    "refresh_work_ms", "index_save_ms", "filter_ms", "read_ms", "probe_ms", "parse_ms", "classify_ms", "json_ms",
]
SEARCH_COUNTS = ["files_candidates", "files_read", "files_parsed", "files_fast_classified", "index_reused", "index_recomputed"]


class McpSession:
    def __init__(self, exe, cwd):
        self.started = time.perf_counter()
        self.proc = subprocess.Popen(
            [exe, "mcp"],
            cwd=cwd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            encoding="utf-8",
            bufsize=1,
        )
        self._id = 0
        self.send("initialize", {"protocolVersion": "2025-06-18"})
        self.initialize_ms = (time.perf_counter() - self.started) * 1000

    def send(self, method, params):
        self._id += 1
        self.proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self._id, "method": method, "params": params}) + "\n")
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        if not line:
            raise RuntimeError(f"emetgate mcp exited with {self.proc.poll()} during {method}")
        return json.loads(line)

    def call(self, tool, arguments):
        started = time.perf_counter()
        reply = self.send("tools/call", {"name": tool, "arguments": arguments})
        elapsed = (time.perf_counter() - started) * 1000
        result = reply.get("result")
        if result is None:
            raise RuntimeError(f"{tool} failed: {reply}")
        text = result["content"][0]["text"]
        return text, result["isError"], elapsed

    def ping_ms(self):
        started = time.perf_counter()
        self.send("ping", {})
        return (time.perf_counter() - started) * 1000

    def close(self):
        self.proc.stdin.close()
        try:
            self.proc.wait(timeout=60)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def first_json(text):
    line = text.split("\n", 1)[0]
    try:
        return json.loads(line)
    except ValueError:
        return None


def percentile(values, q):
    ordered = sorted(values)
    rank = max(1, math.ceil(q * len(ordered)))
    return ordered[rank - 1]


def with_stats(tool, args):
    out = dict(args)
    out["stats"] = True
    return out


def describe(tool, args):
    short = tool.replace("emetgate_", "")
    keys = []
    for k in ("pattern", "symbol", "symbols", "line_start", "line_end", "dir", "regex", "kinds", "nodes", "raw"):
        if k in args:
            v = args[k]
            if k == "dir" or k == "file":
                v = v.replace(ENGINE, "<engine>").replace("packages/core/src", "<core/src>")
            keys.append(f"{k}={json.dumps(v, ensure_ascii=False)}")
    if "file" in args and tool != "emetgate_search":
        keys.insert(0, "file=" + args["file"].replace(WORKFLOW, "<workflow-execute.ts>"))
    return short + " " + " ".join(keys)


def outcome(tool, text, is_error):
    if is_error:
        body = first_json(text) or {}
        return "error:" + str(body.get("error", "?"))
    if tool != "emetgate_search":
        return "ok"
    body = first_json(text) or {}
    hits = sum(len(g.get("hits", [])) for g in body.get("groups", []))
    files = body.get("scope", {}).get("files", body.get("files_total", "?"))
    return f"{body.get('status', '-')} {hits} hits/{files} files"


def new_sessions(exe, repo, count, delay_s):
    rows = []
    for i in range(count):
        tool, args = FIRST_CALLS[i % len(FIRST_CALLS)]
        session = McpSession(exe, repo)
        try:
            if delay_s:
                time.sleep(delay_s)
            text, is_error, ms = session.call(tool, with_stats(tool, args))
            body = first_json(text) or {}
            rows.append({"call": describe(tool, args), "initialize_ms": session.initialize_ms, "first_ms": ms, "stats": body.get("stats", {}), "outcome": outcome(tool, text, is_error)})
        finally:
            session.close()
    return rows


def warm(exe, repo, runs):
    session = McpSession(exe, repo)
    samples = {i: [] for i in range(len(CALLS))}
    pings = []
    pids = set()
    try:
        tool, args = FIRST_CALLS[0]
        session.call(tool, args)
        for _ in range(runs):
            for i, (tool, args) in enumerate(CALLS):
                text, is_error, ms = session.call(tool, with_stats(tool, args))
                body = first_json(text) or {}
                stats = body.get("stats", {}) if isinstance(body, dict) else {}
                if "pid" in stats:
                    pids.add(stats["pid"])
                samples[i].append({"ms": ms, "stats": stats, "outcome": outcome(tool, text, is_error)})
            pings.append(session.ping_ms())
    finally:
        session.close()
    return samples, pings, pids


def git_spawn_ms(repo, rel_dir, runs):
    values = []
    for _ in range(runs):
        started = time.perf_counter()
        subprocess.run(["git", "rev-parse", "--show-toplevel"], cwd=os.path.join(repo, rel_dir), stdin=subprocess.DEVNULL, capture_output=True)
        values.append((time.perf_counter() - started) * 1000)
    return values


def fmt(v):
    if isinstance(v, float):
        return f"{v:.2f}"
    return str(v)


def git_grep_lines(repo, args, pattern_args, path):
    result = subprocess.run(["git", "grep", "-c", "-I", *args, *pattern_args, "--", path], cwd=repo, stdin=subprocess.DEVNULL, capture_output=True, text=True, encoding="utf-8", errors="replace")
    total = 0
    for line in result.stdout.splitlines():
        if line.strip():
            total += int(line.rsplit(":", 1)[-1])
    return total


def differential(exe, repo):
    session = McpSession(exe, repo)
    rows = []
    seen = set()
    try:
        for tool, args in CALLS:
            if tool != "emetgate_search":
                continue
            plain = {k: v for k, v in args.items() if k != "kinds"}
            key = json.dumps(plain, sort_keys=True)
            if key in seen:
                continue
            seen.add(key)
            text, is_error, _ = session.call(tool, plain)
            body = first_json(text) or {}
            hits = sum(len(g.get("hits", [])) for g in body.get("groups", []))
            pattern = plain["pattern"]
            path = plain.get("dir", ".")
            if body.get("read_as") == "literal alternatives":
                expected = git_grep_lines(repo, ["-F"], [x for alt in body["alternatives"] for x in ("-e", alt)], path)
            elif plain.get("regex"):
                expected = git_grep_lines(repo, ["-E"], ["-e", pattern], path)
            else:
                expected = git_grep_lines(repo, ["-F"], ["-e", pattern], path)
            capped = bool(body.get("truncated"))
            same = hits == expected or (capped and hits <= expected)
            rows.append({"call": describe(tool, plain), "status": body.get("status", "error" if is_error else "?"), "emetgate": hits, "git_grep": expected, "capped": capped, "same": same})
    finally:
        session.close()
    return rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--exe", default=DEFAULT_EXE)
    parser.add_argument("--repo", default=DEFAULT_REPO)
    parser.add_argument("--runs", type=int, default=10)
    parser.add_argument("--new", type=int, default=3)
    parser.add_argument("--delay", type=float, default=0.0)
    parser.add_argument("--json")
    parser.add_argument("--skip-new", action="store_true")
    parser.add_argument("--diff", action="store_true")
    options = parser.parse_args()
    if not os.path.exists(options.exe):
        raise SystemExit(f"emetgate binary not found at {options.exe}")
    if not os.path.isdir(options.repo):
        raise SystemExit(f"n8n checkout not found at {options.repo}")

    print(f"exe {options.exe}")
    print(f"repo {options.repo}")
    result = {"exe": options.exe, "repo": options.repo}

    if options.diff:
        rows = differential(options.exe, options.repo)
        print("\n## Matching lines: emetgate_search (kinds dropped) against git grep on the same tracked files\n")
        print("| call | status | emetgate | git grep | capped | same |")
        print("|---|---|---:|---:|---|---|")
        for r in rows:
            print(f"| {r['call']} | {r['status']} | {r['emetgate']} | {r['git_grep']} | {r['capped']} | {r['same']} |")
        different = [r for r in rows if not r["same"]]
        print(f"\n{len(rows) - len(different)} of {len(rows)} calls give the same number of matching lines")
        if options.json:
            with open(options.json, "w", encoding="utf-8", newline="\n") as f:
                json.dump({"diff": rows}, f, indent=1)
                f.write("\n")
        sys.exit(1 if different else 0)

    if not options.skip_new:
        rows = new_sessions(options.exe, options.repo, options.new, options.delay)
        result["new_sessions"] = rows
        print(f"\n## New session, first search {options.delay:.0f} s after initialize ({options.new} sessions)\n")
        print("| first call | initialize ms | first call ms | kernel ms | refresh | reason | stamp ms | work ms | save ms | outcome |")
        print("|---|---:|---:|---:|---|---|---:|---:|---:|---|")
        for r in rows:
            s = r["stats"]
            print(f"| {r['call']} | {r['initialize_ms']:.1f} | {r['first_ms']:.1f} | {fmt(s.get('total_ms', '-'))} | {s.get('refresh_mode', '-')} | {s.get('refresh_reason', '-')} | {fmt(s.get('refresh_stamp_ms', '-'))} | {fmt(s.get('refresh_work_ms', '-'))} | {fmt(s.get('index_save_ms', '-'))} | {r['outcome']} |")

    samples, pings, pids = warm(options.exe, options.repo, options.runs)
    spawn = git_spawn_ms(options.repo, os.path.dirname(WORKFLOW), options.runs)
    result["warm"] = [{"call": describe(t, a), "tool": t, "args": a, "samples": samples[i]} for i, (t, a) in enumerate(CALLS)]
    result["ping_ms"] = pings
    result["git_spawn_ms"] = spawn
    print(f"\n## Warm calls, one session, {options.runs} rounds over {len(CALLS)} real calls (pids seen: {sorted(pids)})\n")
    print(f"MCP ping round trip p50 {statistics.median(pings):.3f} ms, p99 {percentile(pings, 0.99):.3f} ms")
    print(f"git rev-parse --show-toplevel spawn in {os.path.dirname(WORKFLOW)}: p50 {statistics.median(spawn):.1f} ms, p99 {percentile(spawn, 0.99):.1f} ms\n")
    print("| # | call | outcome | round trip p50 | p99 | kernel p50 | p99 | " + " | ".join(SEARCH_STAGES[1:]) + " | " + " | ".join(SEARCH_COUNTS) + " | mode/reason |")
    print("|---:|---|---|---:|---:|---:|---:|" + "---:|" * (len(SEARCH_STAGES) - 1 + len(SEARCH_COUNTS)) + "---|")
    for i, (tool, args) in enumerate(CALLS):
        rows = samples[i]
        ms = [r["ms"] for r in rows]
        kernel = [r["stats"]["total_ms"] for r in rows if "total_ms" in r["stats"]]
        stage_cells = []
        for stage in SEARCH_STAGES[1:] + SEARCH_COUNTS:
            values = [r["stats"][stage] for r in rows if stage in r["stats"]]
            stage_cells.append(fmt(statistics.median(values)) if values else "-")
        modes = sorted({f"{r['stats'].get('refresh_mode', '-')}/{r['stats'].get('refresh_reason', '') or '-'}" for r in rows if r["stats"]})
        k50 = f"{statistics.median(kernel):.2f}" if kernel else "-"
        k99 = f"{percentile(kernel, 0.99):.2f}" if kernel else "-"
        print(f"| {i + 1} | {describe(tool, args)} | {rows[-1]['outcome']} | {statistics.median(ms):.2f} | {percentile(ms, 0.99):.2f} | {k50} | {k99} | " + " | ".join(stage_cells) + f" | {','.join(modes) or '-'} |")

    if options.json:
        with open(options.json, "w", encoding="utf-8", newline="\n") as f:
            json.dump(result, f, indent=1)
            f.write("\n")


if __name__ == "__main__":
    main()
