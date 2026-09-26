import json
import os
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

ENC = tiktoken.get_encoding("o200k_base")


def toks(s):
    return len(ENC.encode(s))


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
        self.proc.stdin.write(json.dumps(msg) + "\n")
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        if not line:
            err = self.proc.stderr.read()
            raise RuntimeError(f"emetgate mcp produced no response; stderr: {err}")
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


HEADER = """\
Emetgate search benchmark: ripgrep (the built-in Grep tool's engine) vs emetgate_search
Methodology (read before quoting a number):
- Tokenizer: o200k_base (approximate; the RATIO is the signal, not the absolute count).
- "rg" = tokens of `rg -n` output for the same pattern in the same directory, no result cap
  (matching ripgrep's default, which is also what the built-in Grep tool exposes).
- "emetgate" = tokens of the single emetgate_search NDJSON reply, grouped and kind-tagged,
  exactly as a model would receive it.
- Two scenarios are marked "+edit": finding a match is not the end goal, the model still
  needs the target symbol's hash to call emetgate_try. For rg that means one more tool call
  (emetgate_read_symbol on the file/symbol rg pointed at); emetgate_search already returns
  the hash in the same reply, so 1 turn there against 2 for rg. Both sides' tokens for that
  second call are counted, matching how tests/bench/reader.py counts a two-step read.
- ms is wall time for the tool call(s) only (subprocess spawn, not counted), cold (first
  call, cache/index empty) and warm (index built, tree cache populated) shown separately.
- A scenario ripgrep wins is reported anyway, not hidden.
- Reproduce: `python tests/bench/search.py` (needs a built emetgate binary, `rg` on PATH,
  and read-only checkouts at {express} and {eslint}).
""".format(express=EXPRESS, eslint=ESLINT)


def scenario(name, repo, pattern, group, extra_rg=None, edit_symbol=None, edit_file=None, regex=False):
    if not os.path.isdir(repo):
        return None
    session_cold = McpSession(repo)
    try:
        emetgate_cold_text, is_error, cold_ms = session_cold.call("emetgate_search", {"pattern": pattern, "regex": regex})
        if is_error:
            raise RuntimeError(f"emetgate_search failed: {emetgate_cold_text}")
        emetgate_warm_text, _, warm_ms = session_cold.call("emetgate_search", {"pattern": pattern, "regex": regex})
        edit_tokens = 0
        edit_turns = 0
        if edit_symbol:
            body_text, is_err2, _ = session_cold.call("emetgate_read_symbol", {"file": edit_file, "symbol": edit_symbol})
            if not is_err2:
                edit_tokens = toks(body_text)
                edit_turns = 1
    finally:
        session_cold.close()

    rg_text, rg_ms = rg(repo, pattern, extra_rg)

    rg_tokens = toks(rg_text) + edit_tokens
    emetgate_tokens = toks(emetgate_cold_text)
    rg_turns = 1 + edit_turns
    emetgate_turns = 1
    ratio = emetgate_tokens / rg_tokens if rg_tokens else float("nan")
    return {
        "name": name,
        "group": group,
        "rg_tokens": rg_tokens,
        "emetgate_tokens": emetgate_tokens,
        "ratio": ratio,
        "rg_turns": rg_turns,
        "emetgate_turns": emetgate_turns,
        "rg_ms": rg_ms,
        "cold_ms": cold_ms,
        "warm_ms": warm_ms,
    }


def main():
    print(HEADER)
    scenarios = [
        scenario("function name usages (+edit)", EXPRESS, "tryRender", "code", edit_symbol="tryRender", edit_file="lib/application.js"),
        scenario("an error message string", EXPRESS, "not found", "string"),
        scenario("a term only in comments", ESLINT, "eslint-disable", "comment"),
        scenario("a JSON key value", EXPRESS, "express", "json"),
        scenario("a common short word", EXPRESS, "function", "code"),
        scenario("a regex pattern", EXPRESS, "req\\.(params|query)", "code", regex=True, extra_rg=["-e"]),
    ]
    print("{:<32} {:>6} {:>10} {:>10} {:>7} {:>6} {:>6} {:>9} {:>9} {:>9}".format(
        "scenario", "group", "rg_tok", "eg_tok", "ratio", "rg_tn", "eg_tn", "rg_ms", "cold_ms", "warm_ms"
    ))
    worse = []
    for s in scenarios:
        if s is None:
            continue
        print("{:<32} {:>6} {:>10} {:>10} {:>6.2f}x {:>6} {:>6} {:>9.1f} {:>9.1f} {:>9.1f}".format(
            s["name"][:32], s["group"], s["rg_tokens"], s["emetgate_tokens"], s["ratio"],
            s["rg_turns"], s["emetgate_turns"], s["rg_ms"], s["cold_ms"], s["warm_ms"],
        ))
        if s["ratio"] > 1 / 3:
            worse.append(s["name"])
    if worse:
        print("\nScenarios under the 3x-better rule (not hidden):")
        for name in worse:
            print(f"  - {name}")


if __name__ == "__main__":
    main()
