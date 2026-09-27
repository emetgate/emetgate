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
    def __init__(self, cwd):
        self.proc = subprocess.Popen(
            [SYN, "mcp"],
            cwd=cwd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            bufsize=1,
        )
        self._id = 0
        self._send("initialize", {"protocolVersion": "2025-06-18"})

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
    result = subprocess.run(args, cwd=repo, capture_output=True, text=True, encoding="utf-8", errors="replace")
    elapsed_ms = (time.perf_counter() - started) * 1000
    return result.stdout, elapsed_ms


def rg_ms_median(repo, pattern, extra=None, samples=MS_SAMPLES):
    values = [rg(repo, pattern, extra)[1] for _ in range(samples)]
    return statistics.median(values)


def emetgate_cold_warm_ms(repo, pattern, regex, samples=MS_SAMPLES):
    cold = []
    warm = []
    text = None
    for _ in range(samples):
        clear_index()
        session = McpSession(repo)
        try:
            t, is_error, cold_ms = session.call("emetgate_search", {"pattern": pattern, "regex": regex})
            if is_error:
                raise RuntimeError(f"emetgate_search failed: {t}")
            text = t
            cold.append(cold_ms)
            _, _, warm_ms = session.call("emetgate_search", {"pattern": pattern, "regex": regex})
            warm.append(warm_ms)
        finally:
            session.close()
    return text, statistics.median(cold), statistics.median(warm)


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
- ms is the median of {samples} runs, wall time for the tool call(s) only (subprocess spawn
  excluded). rg has one ms column (its own cache behavior is not under this project's
  control). emetgate has separate cold (index directory deleted first) and warm (second
  call in the same session) columns, per the user rule that ms must not regress either way.
- A scenario ripgrep wins is reported anyway, not hidden.
- Reproduce: `python tests/bench/search.py` (needs a built emetgate binary, `rg` on PATH,
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
    _, cold_ms, warm_ms = emetgate_cold_warm_ms(repo, pattern, regex)

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
        "cold_ms": cold_ms,
        "warm_ms": warm_ms,
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
    _, cold_ms, warm_ms = emetgate_cold_warm_ms(repo, pattern, regex)

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
            "cold_ms": cold_ms,
            "warm_ms": warm_ms,
        })
    return rows


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

    print("{:<38} {:>6} {:>10} {:>10} {:>7} {:>6} {:>6} {:>9} {:>9} {:>9}".format(
        "scenario", "group", "rg_tok", "eg_tok", "ratio", "rg_tn", "eg_tn", "rg_ms", "cold_ms", "warm_ms"
    ))
    worse = []
    ms_regressions = []
    for s in rows:
        print("{:<38} {:>6} {:>10} {:>10} {:>6.2f}x {:>6} {:>6} {:>9.1f} {:>9.1f} {:>9.1f}".format(
            s["name"][:38], s["group"], s["rg_tokens"], s["emetgate_tokens"], s["ratio"],
            s["rg_turns"], s["emetgate_turns"], s["rg_ms"], s["cold_ms"], s["warm_ms"],
        ))
        if s["ratio"] > 1 / 3:
            worse.append(s["name"])
        if s["cold_ms"] > s["rg_ms"] or s["warm_ms"] > s["rg_ms"]:
            ms_regressions.append((s["name"], s["rg_ms"], s["cold_ms"], s["warm_ms"]))

    if worse:
        print("\nScenarios under the 3x-better rule (not hidden):")
        for name in worse:
            print(f"  - {name}")

    if ms_regressions:
        print("\nScenarios where emetgate ms did not beat rg ms (not hidden):")
        for name, rg_ms, cold_ms, warm_ms in ms_regressions:
            print(f"  - {name}: rg {rg_ms:.1f} ms, emetgate cold {cold_ms:.1f} ms, warm {warm_ms:.1f} ms")


PROFILE_SCENARIOS = [
    ("an error message string", EXPRESS, "not found", False),
    ("a term only in comments", ESLINT, "eslint-disable", False),
    ("a regex pattern", EXPRESS, "req\\.(params|query)", True),
]

PROFILE_STAGES = [
    "index_load_ms",
    "index_refresh_ms",
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
