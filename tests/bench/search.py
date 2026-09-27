import json
import os
import shutil
import statistics
import subprocess
import sys
import time

import tiktoken

BENCH = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(BENCH))
PROJECT_ROOT = os.path.dirname(ROOT)
_exe = "emetgate.exe" if os.name == "nt" else "emetgate"
SYN = os.environ.get("EMETGATE_BIN") or os.path.join(ROOT, "zig-out", "bin", _exe)
if not os.path.exists(SYN):
    raise SystemExit(f"emetgate binary not found at {SYN}; run `zig build` or set EMETGATE_BIN")

EVAL_ROOT = os.environ.get("EMETGATE_EVAL_ROOT", os.path.join(PROJECT_ROOT, "eval"))
EXPRESS = os.path.join(EVAL_ROOT, "express-test")
ESLINT = os.path.join(EVAL_ROOT, "eslint-test")
INDEX_ROOT = os.path.join(os.environ.get("LOCALAPPDATA", ""), "emetgate", "index")

ENC = tiktoken.get_encoding("o200k_base")
MS_SAMPLES = 10


def toks(s):
    return len(ENC.encode(s))


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def clear_index():
    shutil.rmtree(INDEX_ROOT, ignore_errors=True)


class McpSession:
    def __init__(self, cwd, extra=None):
        self.proc = subprocess.Popen(
            [SYN, "mcp", *(extra or [])],
            cwd=cwd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            bufsize=1,
        )
        self._id = 0
        self.started = time.perf_counter()
        self._send("initialize", {"protocolVersion": "2025-06-18"})
        self.startup_ms = (time.perf_counter() - self.started) * 1000

    def _send(self, method, params):
        self._id += 1
        msg = {"jsonrpc": "2.0", "id": self._id, "method": method, "params": params}
        self.last_request = msg
        self.proc.stdin.write(json.dumps(msg) + "\n")
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        if not line:
            err = self.proc.stderr.read()
            code = self.proc.poll()
            if code is None:
                self.proc.wait(timeout=5)
                code = self.proc.returncode
            raise RuntimeError(
                "emetgate mcp produced no response; "
                f"exit_code={code} (0x{code & 0xFFFFFFFF:08X}) "
                f"last_request={json.dumps(msg)} stderr={err!r}"
            )
        return json.loads(line)

    def call(self, name, arguments):
        started = time.perf_counter()
        reply = self._send("tools/call", {"name": name, "arguments": arguments})
        elapsed_ms = (time.perf_counter() - started) * 1000
        result = reply.get("result")
        if result is None:
            raise RuntimeError(f"tool call failed: {reply}")
        text = result["content"][0]["text"]
        return text, result["isError"], elapsed_ms

    def close(self):
        self.proc.stdin.close()
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def rg(repo, pattern, extra=None):
    args = ["rg", "-n", "--no-heading"]
    if extra:
        args.extend(extra)
    args.append(pattern)
    started = time.perf_counter()
    result = subprocess.run(args, cwd=repo, stdin=subprocess.DEVNULL, capture_output=True, text=True, encoding="utf-8", errors="replace")
    elapsed_ms = (time.perf_counter() - started) * 1000
    return result.stdout, elapsed_ms


def rg_ms_median(repo, pattern, extra=None, samples=MS_SAMPLES):
    values = [rg(repo, pattern, extra)[1] for _ in range(samples)]
    return statistics.median(values)


def git_grep_ms_median(repo, pattern, regex, samples=MS_SAMPLES):
    args = ["git", "grep", "-n", "-E" if regex else "-F", "-e", pattern]
    values = []
    for _ in range(samples):
        started = time.perf_counter()
        subprocess.run(args, cwd=repo, stdin=subprocess.DEVNULL, capture_output=True)
        values.append((time.perf_counter() - started) * 1000)
    return statistics.median(values)


def scan_bandwidth_bytes_per_ms():
    data = (b"export function example(value) { return value + 1; }\n" * (64 * 1024 * 1024 // 55))
    needle = b"zz_not_present_zz"
    best = None
    for _ in range(5):
        started = time.perf_counter()
        data.find(needle)
        elapsed = (time.perf_counter() - started) * 1000
        best = elapsed if best is None else min(best, elapsed)
    return len(data) / best


def floor_parts(repo, pattern, regex, samples=MS_SAMPLES):
    session = McpSession(repo)
    try:
        session.call("emetgate_search", {"pattern": pattern, "regex": regex})
        pings = []
        for _ in range(samples):
            started = time.perf_counter()
            session._send("ping", {})
            pings.append((time.perf_counter() - started) * 1000)
        text, is_error, _ = session.call("emetgate_search", {"pattern": pattern, "regex": regex, "stats": True})
        if is_error:
            raise RuntimeError(f"emetgate_search failed: {text}")
        stats = json.loads(text.splitlines()[0])["stats"]
    finally:
        session.close()
    return {
        "transport_ms": statistics.median(pings),
        "sync_ms": stats.get("sync_ms", 0.0),
        "filter_ms": stats.get("filter_ms", 0.0),
        "candidate_bytes": stats.get("candidate_bytes", 0),
    }


def floor_ms(parts, bandwidth):
    return parts["transport_ms"] + parts["sync_ms"] + parts["filter_ms"] + parts["candidate_bytes"] / bandwidth


def emetgate_cold_warm_ms(repo, pattern, regex, samples=MS_SAMPLES):
    build = []
    startup = []
    cold = []
    warm = []
    text = None
    args = {"pattern": pattern, "regex": regex}
    for _ in range(samples):
        clear_index()
        session = McpSession(repo)
        try:
            t, is_error, build_ms = session.call("emetgate_search", args)
            if is_error:
                raise RuntimeError(f"emetgate_search failed: {t}")
            build.append(build_ms)
        finally:
            session.close()
        session = McpSession(repo)
        try:
            startup.append(session.startup_ms)
            t, is_error, cold_ms = session.call("emetgate_search", args)
            if is_error:
                raise RuntimeError(f"emetgate_search failed: {t}")
            text = t
            cold.append(cold_ms)
            _, _, warm_ms = session.call("emetgate_search", args)
            warm.append(warm_ms)
        finally:
            session.close()
    return text, {
        "build_ms": statistics.median(build),
        "startup_ms": statistics.median(startup),
        "cold_ms": statistics.median(cold),
        "warm_ms": statistics.median(warm),
    }


def extract_function_range(source, symbol_name):
    needle = f"function {symbol_name}("
    start_idx = source.index(needle)
    start_line = source.count("\n", 0, start_idx) + 1
    open_brace = source.index("{", start_idx)
    depth = 0
    j = open_brace
    while True:
        if source[j] == "{":
            depth += 1
        elif source[j] == "}":
            depth -= 1
            if depth == 0:
                break
        j += 1
    end_line = source.count("\n", 0, j) + 1
    return "\n".join(source.splitlines()[start_line - 1 : end_line])


HEADER = """\
Emetgate search benchmark: ripgrep (the built-in Grep tool's engine) vs emetgate_search
Methodology (read before quoting a number):
- Tokenizer: o200k_base (approximate; the RATIO is the signal, not the absolute count).
- "rg" = tokens of `rg -n` output for the same pattern in the same directory, no result cap.
- "emetgate" = tokens of the single emetgate_search NDJSON reply, grouped and kind-tagged.
- "+edit" scenarios: finding a match is not the end goal, the model still needs to edit the
  symbol. The built-in path in Claude Code is Grep then Read before Edit (Read is required
  before Edit); ripgrep's own side of the comparison is charged for that Read, in TWO
  columns matching tests/bench/reader.py's real-file scenario: reading the whole file, and
  reading only the exact changed function's line range (the best case a model could reach,
  which it cannot know without already having read the file). emetgate_search returns the
  symbol's hash in the same reply, so it stays at 1 turn against rg's 2 (search, then read).
- ms is the median of {samples} runs of wall time. rg and git grep are timed as the process a
  tool call starts (spawn included, as Claude Code's Grep starts rg per call); git grep runs
  with -F for literal patterns and -E for the regex. emetgate is timed as the MCP round trip
  of one tools/call in a running server. "index build" is the first search of a new server
  with the on-disk index deleted: it reads, grams and parses every tracked file once, on the
  session's thread pool, and saves the index. "cold" is the first search of the next new
  server, with that index on disk: the server loads it at startup after its change watcher
  starts, and the first search restats every tracked file and re-reads only those whose stamp
  changed. "startup" is that server's spawn and initialize round trip, which includes the
  load. "warm" is the second search of the same server; it first syncs with the watch barrier,
  so a write that finished before the call is seen.
- "search right after a committed write": a writable copy of express in one server started
  with a test command. Each round commits an emetgate_try to lib/utils.js, runs git add -A
  and git commit (which rewrites the git index), then searches for the text just written;
  cold is that first search after the write, warm the search after it. rg, git grep and
  the floor are measured on the same copy.
- floor: the parts a warm search cannot avoid, measured in the same session: an MCP ping
  round trip, the watch barrier, the trigram candidate filter, and reading the candidate
  bytes once at the scan bandwidth bytes.find reaches over 64 MB already in memory.
- A scenario ripgrep wins is reported anyway, not hidden.
- Reproduce: `python tests/bench/search.py [--save]` (needs a ReleaseFast emetgate binary, `rg` on PATH,
  and read-only checkouts at {express} and {eslint}).
""".format(express=EXPRESS, eslint=ESLINT, samples=MS_SAMPLES)


def scenario(name, repo, pattern, group, extra_rg=None, regex=False):
    if not os.path.isdir(repo):
        return None
    clear_index()
    session = McpSession(repo)
    try:
        emetgate_text, is_error, _ = session.call("emetgate_search", {"pattern": pattern, "regex": regex})
        if is_error:
            raise RuntimeError(f"emetgate_search failed: {emetgate_text}")
    finally:
        session.close()

    rg_text, _ = rg(repo, pattern, extra_rg)
    rg_ms = rg_ms_median(repo, pattern, extra_rg)
    git_ms = git_grep_ms_median(repo, pattern, regex)
    _, timings = emetgate_cold_warm_ms(repo, pattern, regex)
    parts = floor_parts(repo, pattern, regex)

    rg_tokens = toks(rg_text)
    emetgate_tokens = toks(emetgate_text)
    ratio = emetgate_tokens / rg_tokens if rg_tokens else float("nan")
    return {
        "name": name,
        "group": group,
        "rg_tokens": rg_tokens,
        "emetgate_tokens": emetgate_tokens,
        "ratio": ratio,
        "rg_turns": 1,
        "emetgate_turns": 1,
        "rg_ms": rg_ms,
        "git_ms": git_ms,
        **timings,
        "floor": parts,
    }


def scenario_edit(name, repo, pattern, group, symbol_name, file_rel, extra_rg=None, regex=False):
    if not os.path.isdir(repo):
        return None
    clear_index()
    session = McpSession(repo)
    try:
        emetgate_text, is_error, _ = session.call("emetgate_search", {"pattern": pattern, "regex": regex})
        if is_error:
            raise RuntimeError(f"emetgate_search failed: {emetgate_text}")
    finally:
        session.close()

    rg_text, _ = rg(repo, pattern, extra_rg)
    rg_ms = rg_ms_median(repo, pattern, extra_rg)
    git_ms = git_grep_ms_median(repo, pattern, regex)
    _, timings = emetgate_cold_warm_ms(repo, pattern, regex)
    parts = floor_parts(repo, pattern, regex)

    source = read(os.path.join(repo, file_rel))
    full_file_tokens = toks(source)
    best_case_tokens = toks(extract_function_range(source, symbol_name))

    rg_tokens_only = toks(rg_text)
    emetgate_tokens = toks(emetgate_text)
    rows = []
    for label, read_tokens in (("full file", full_file_tokens), ("best-case range", best_case_tokens)):
        rg_tokens = rg_tokens_only + read_tokens
        ratio = emetgate_tokens / rg_tokens if rg_tokens else float("nan")
        rows.append({
            "name": f"{name} (rg+Read {label})",
            "group": group,
            "rg_tokens": rg_tokens,
            "emetgate_tokens": emetgate_tokens,
            "ratio": ratio,
            "rg_turns": 2,
            "emetgate_turns": 1,
            "rg_ms": rg_ms,
            "git_ms": git_ms,
            **timings,
            "floor": parts,
        })
    return rows


def writable_copy(source):
    import tempfile
    work = tempfile.mkdtemp(prefix="emetgate-search-write-")
    listed = subprocess.run(["git", "ls-files", "-z"], cwd=source, check=True, capture_output=True).stdout
    for rel in [f for f in listed.decode("utf-8").split("\0") if f]:
        dest = os.path.join(work, rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        shutil.copyfile(os.path.join(source, rel), dest)
    git_commit(work, "base", add_all=True, init=True)
    return work


def git_commit(work, message, add_all=True, init=False):
    who = ["-c", "user.name=bench", "-c", "user.email=bench@example.invalid"]
    if init:
        subprocess.run(["git", "init", "-q"], cwd=work, check=True)
    if add_all:
        subprocess.run(["git", *who, "add", "-A"], cwd=work, check=True)
    subprocess.run(["git", *who, "commit", "-q", "-m", message], cwd=work, check=True)


WRITE_FILE = "lib/utils.js"
WRITE_SYMBOL = "parseExtendedQueryString"


def scenario_after_write(name, repo, samples=MS_SAMPLES):
    if not os.path.isdir(repo):
        return None
    work = writable_copy(repo)
    try:
        session = McpSession(work, ["--test", "cmd /c exit 0"])
        try:
            startup_ms = session.startup_ms
            _, _, build_ms = session.call("emetgate_search", {"pattern": "not found"})
            first = []
            second = []
            text = None
            for i in range(samples):
                token = f"parameterLimit: {1000 + i}"
                read, is_error, _ = session.call("emetgate_read_symbol", {"file": WRITE_FILE, "symbol": WRITE_SYMBOL})
                if is_error:
                    raise RuntimeError(read)
                current = json.loads(read.splitlines()[0])["hash"]
                body = "{\n  return qs.parse(str, {\n    allowPrototypes: true,\n    " + token + "\n  });\n}"
                reply, is_error, _ = session.call("emetgate_try", {"file": WRITE_FILE, "symbol": WRITE_SYMBOL, "hash": current, "body": body})
                if is_error or "committed" not in reply:
                    raise RuntimeError(f"emetgate_try did not commit: {reply}")
                git_commit(work, f"write {i}")
                text, is_error, ms1 = session.call("emetgate_search", {"pattern": token})
                if is_error or WRITE_FILE not in text:
                    raise RuntimeError(f"search after the write missed {token}: {text}")
                first.append(ms1)
                _, _, ms2 = session.call("emetgate_search", {"pattern": token})
                second.append(ms2)
        finally:
            session.close()
        pattern = f"parameterLimit: {1000 + samples - 1}"
        rg_text, _ = rg(work, pattern)
        rg_ms = rg_ms_median(work, pattern)
        git_ms = git_grep_ms_median(work, pattern, False)
        parts = floor_parts(work, pattern, False)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    rg_tokens = toks(rg_text)
    emetgate_tokens = toks(text)
    return {
        "name": name,
        "group": "code",
        "rg_tokens": rg_tokens,
        "emetgate_tokens": emetgate_tokens,
        "ratio": emetgate_tokens / rg_tokens if rg_tokens else float("nan"),
        "rg_turns": 1,
        "emetgate_turns": 1,
        "rg_ms": rg_ms,
        "git_ms": git_ms,
        "build_ms": build_ms,
        "startup_ms": startup_ms,
        "cold_ms": statistics.median(first),
        "warm_ms": statistics.median(second),
        "floor": parts,
    }


def main():
    print(HEADER)
    rows = []
    for s in [
        scenario("an error message string", EXPRESS, "not found", "string"),
        scenario("a term only in comments", ESLINT, "eslint-disable", "comment"),
        scenario("a JSON key value", EXPRESS, "express", "json"),
        scenario("a common short word", EXPRESS, "function", "code"),
        scenario("a regex pattern", EXPRESS, "req\\.(params|query)", "code", regex=True, extra_rg=["-e"]),
    ]:
        if s is not None:
            rows.append(s)
    for edit in [
        scenario_edit("tryRender usages", EXPRESS, "tryRender", "code", "tryRender", "lib/application.js"),
        scenario_edit("logerror usages", EXPRESS, "logerror", "code", "logerror", "lib/application.js"),
    ]:
        if edit is not None:
            rows.extend(edit)
    after = scenario_after_write("search right after a committed write and a git commit", EXPRESS)
    if after is not None:
        rows.append(after)

    bandwidth = scan_bandwidth_bytes_per_ms()
    print(f"\nmeasured scan bandwidth (bytes.find over 64 MB in memory): {bandwidth / 1e6:.2f} GB/s")
    print("\n| scenario | group | rg tokens | emetgate tokens | ratio | turns rg/eg | rg ms | git grep ms | index build ms | startup ms | cold ms | warm ms | floor ms | warm - floor | candidate KB |")
    print("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    worse = []
    ms_regressions = []
    for s in rows:
        floor = floor_ms(s["floor"], bandwidth)
        print("| {} | {} | {} | {} | {:.2f}x | {}/{} | {:.1f} | {:.1f} | {:.1f} | {:.1f} | {:.1f} | {:.1f} | {:.2f} | {:.2f} | {:.0f} |".format(
            s["name"], s["group"], s["rg_tokens"], s["emetgate_tokens"], s["ratio"],
            s["rg_turns"], s["emetgate_turns"], s["rg_ms"], s["git_ms"], s["build_ms"], s["startup_ms"], s["cold_ms"], s["warm_ms"],
            floor, s["warm_ms"] - floor, s["floor"]["candidate_bytes"] / 1024,
        ))
        if s["ratio"] > 1 / 3:
            worse.append(s["name"])
        if max(s["warm_ms"], s["cold_ms"]) >= min(s["rg_ms"], s["git_ms"]):
            ms_regressions.append((s["name"], s["rg_ms"], s["git_ms"], s["cold_ms"], s["warm_ms"]))

    print("\nfloor = MCP ping round trip + watch barrier (sync) + trigram candidate filter + candidate bytes at the measured scan bandwidth.")
    if worse:
        print("\nScenarios under the 3x-better token rule (not hidden):")
        for name in worse:
            print(f"  - {name}")

    if ms_regressions:
        print("\nScenarios where cold or warm emetgate ms did not beat both rg and git grep (not hidden):")
        for name, rg_ms, git_ms, cold_ms, warm_ms in ms_regressions:
            print(f"  - {name}: rg {rg_ms:.1f} ms, git grep {git_ms:.1f} ms, emetgate cold {cold_ms:.1f} ms, warm {warm_ms:.1f} ms")
    else:
        print("\nCold and warm emetgate ms beat both rg and git grep in every scenario.")

    if "--save" in sys.argv:
        out = {
            "date": time.strftime("%Y-%m-%d"),
            "scan_gb_per_s": round(bandwidth / 1e6, 2),
            "rows": [
                {
                    "name": s["name"],
                    "group": s["group"],
                    "rg_tokens": s["rg_tokens"],
                    "emetgate_tokens": s["emetgate_tokens"],
                    "rg_turns": s["rg_turns"],
                    "emetgate_turns": s["emetgate_turns"],
                    "rg_ms": round(s["rg_ms"], 1),
                    "git_ms": round(s["git_ms"], 1),
                    "build_ms": round(s["build_ms"], 1),
                    "startup_ms": round(s["startup_ms"], 1),
                    "cold_ms": round(s["cold_ms"], 1),
                    "warm_ms": round(s["warm_ms"], 1),
                    "floor_ms": round(floor_ms(s["floor"], bandwidth), 2),
                }
                for s in rows
            ],
        }
        with open(os.path.join(BENCH, "search_results.json"), "w", encoding="utf-8", newline="\n") as f:
            json.dump(out, f, indent=2)
            f.write("\n")
        print("saved tests/bench/search_results.json; run python tools/readme_facts.py")


PROFILE_SCENARIOS = [
    ("an error message string", EXPRESS, "not found", False),
    ("a term only in comments", ESLINT, "eslint-disable", False),
    ("a regex pattern", EXPRESS, "req\\.(params|query)", True),
]

PROFILE_STAGES = [
    "total_ms",
    "jail_ms",
    "list_ms",
    "sync_ms",
    "refresh_mode",
    "refresh_reason",
    "dirty_paths",
    "index_load_ms",
    "index_refresh_ms",
    "refresh_stamp_ms",
    "refresh_work_ms",
    "index_reused",
    "index_recomputed",
    "index_save_ms",
    "files_candidates",
    "files_read",
    "read_ms",
    "probe_ms",
    "files_parsed",
    "files_fast_classified",
    "parse_ms",
    "classify_ms",
    "json_ms",
]


def profile_one(repo, pattern, regex):
    clear_index()
    builder = McpSession(repo)
    try:
        builder.call("emetgate_search", {"pattern": pattern, "regex": regex})
    finally:
        builder.close()
    session = McpSession(repo)
    try:
        cold_text, is_error, cold_ms = session.call("emetgate_search", {"pattern": pattern, "regex": regex, "stats": True})
        if is_error:
            raise RuntimeError(f"emetgate_search failed: {cold_text}")
        cold_stats = json.loads(cold_text.splitlines()[0])["stats"]
        cold_pid = cold_stats["pid"]

        warm_text, is_error, warm_ms = session.call("emetgate_search", {"pattern": pattern, "regex": regex, "stats": True})
        if is_error:
            raise RuntimeError(f"emetgate_search failed: {warm_text}")
        warm_stats = json.loads(warm_text.splitlines()[0])["stats"]
        warm_pid = warm_stats["pid"]
    finally:
        session.close()
    return {
        "cold_ms": cold_ms,
        "warm_ms": warm_ms,
        "cold": cold_stats,
        "warm": warm_stats,
        "same_process": cold_pid == warm_pid and cold_pid != 0,
        "pid": cold_pid,
    }


def profile_main():
    print("Stage profile for the 3 worst scenarios (single run each, not a median; see search.py bench above for the ms medians).")
    print("Proves the MCP child process stays open across cold/warm calls in one session (same pid) rather than respawning per call.\n")
    for name, repo, pattern, regex in PROFILE_SCENARIOS:
        if not os.path.isdir(repo):
            continue
        p = profile_one(repo, pattern, regex)
        print(f"=== {name} ({repo}) ===")
        print(f"same process across cold+warm calls: {p['same_process']} (pid={p['pid']})")
        print(f"tool-call wall time: cold {p['cold_ms']:.1f} ms, warm {p['warm_ms']:.1f} ms")
        print("{:<20} {:>12} {:>12}".format("stage", "cold", "warm"))
        for stage in PROFILE_STAGES:
            cold_v = p["cold"].get(stage, "-")
            warm_v = p["warm"].get(stage, "-")
            if isinstance(cold_v, float):
                cold_v = f"{cold_v:.2f}"
            if isinstance(warm_v, float):
                warm_v = f"{warm_v:.2f}"
            print("{:<20} {:>12} {:>12}".format(stage, cold_v, warm_v))
        print("tracked_files={} files_total_is_not_reported_here".format(p["cold"].get("tracked_files")))
        print()


if __name__ == "__main__":
    if "--profile" in sys.argv:
        profile_main()
    else:
        main()
