import json
import os
import shutil
import subprocess
import sys
import tempfile

import tiktoken

BENCH = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(BENCH))
_exe = "emetgate.exe" if os.name == "nt" else "emetgate"
SYN = os.environ.get("EMETGATE_BIN") or os.path.join(ROOT, "zig-out", "bin", _exe)
if not os.path.exists(SYN):
    raise SystemExit(f"emetgate binary not found at {SYN}; run `zig build` or set EMETGATE_BIN")

AFFILIATE_SCRAPER = os.environ.get(
    "AFFILIATE_SCRAPER", r"C:\Users\ugur\Desktop\Freelance\affiliate-scraper"
)

ENC = tiktoken.get_encoding("o200k_base")


def toks(s):
    return len(ENC.encode(s))


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


class McpSession:
    def __init__(self, cwd, mirror=False):
        args = [SYN, "mcp"]
        if mirror:
            args.append("--mirror")
        self.proc = subprocess.Popen(
            args,
            cwd=cwd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
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
        reply = self._send("tools/call", {"name": name, "arguments": arguments})
        result = reply.get("result")
        if result is None:
            raise RuntimeError(f"tool call failed: {reply}")
        text = result["content"][0]["text"]
        return text, result["isError"]

    def close(self):
        self.proc.stdin.close()
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()


HEADER = """\
Emetgate reader benchmark: built-in Read vs the emetgate MCP read tools
Methodology (read before quoting a number):
- Tokenizer: o200k_base (GPT-4o-family proxy; NOT Claude's tokenizer). Absolute counts
  are approximate; the RATIO between approaches is the signal.
- "Read baseline" = tokens of the exact bytes a plain cat/Read of the file (or, for the
  line-range case, sed -n of that range) would put in context. No tool-schema overhead
  counted on either side.
- "emetgate" = tokens of the actual NDJSON line(s) the MCP tool call(s) return, including
  the JSON wrapper, hash and any locate step (skeleton/key-tree/heading-tree), exactly as
  a model would receive them. Two-step scenarios (locate + fetch) sum both steps, matching
  how tests/bench/run4.py counts a symbol edit's ingest side.
- A scenario emetgate does NOT come out ahead on is reported anyway, not hidden.
- Reproduce: `python tests/bench/reader.py` (needs a built emetgate binary; the "real
  project" scenarios read {affiliate} read-only and are skipped if it is absent).
""".format(affiliate=AFFILIATE_SCRAPER)


def scenario_big_function():
    path = os.path.join(AFFILIATE_SCRAPER, "src", "index.js")
    if not os.path.exists(path):
        return None
    content = read(path)
    session = McpSession(AFFILIATE_SCRAPER)
    try:
        skeleton_text, _ = session.call("emetgate_skeleton", {"file": "src/index.js"})
        body_text, _ = session.call("emetgate_read_symbol", {"file": "src/index.js", "symbol": "loadPending"})
    finally:
        session.close()
    baseline = toks(content)
    emetgate = toks(skeleton_text) + toks(body_text)
    return "find + read a function in a 1.6k-line real file (affiliate-scraper/src/index.js)", baseline, emetgate, 1


def scenario_big_json():
    path = os.path.join(AFFILIATE_SCRAPER, "package-lock.json")
    if not os.path.exists(path):
        return None
    content = read(path)
    session = McpSession(AFFILIATE_SCRAPER)
    try:
        tree_text, _ = session.call("emetgate_read_file", {"file": "package-lock.json"})
        value_text, is_error = session.call(
            "emetgate_read_file",
            {"file": "package-lock.json", "pointer": "/packages/node_modules~1abort-controller/version"},
        )
    finally:
        session.close()
    if is_error:
        raise RuntimeError(f"pointer read failed: {value_text}")
    baseline = toks(content)
    emetgate = toks(tree_text) + toks(value_text)
    return "read one key in a 50 KB real package-lock.json", baseline, emetgate, 1


def scenario_readme_section():
    path = os.path.join(ROOT, "README.md")
    content = read(path)
    session = McpSession(ROOT)
    try:
        tree_text, _ = session.call("emetgate_read_file", {"file": "README.md"})
        section_text, _ = session.call("emetgate_read_file", {"file": "README.md", "heading": "Limits"})
    finally:
        session.close()
    baseline = toks(content)
    emetgate = toks(tree_text) + toks(section_text)
    return "read one section of this repo's own README.md", baseline, emetgate, 1


def scenario_repeat_read():
    path = os.path.join(AFFILIATE_SCRAPER, "src", "index.js")
    if not os.path.exists(path):
        return None
    content = read(path)
    session = McpSession(AFFILIATE_SCRAPER, mirror=True)
    try:
        session.call("emetgate_read_symbol", {"file": "src/index.js", "symbol": "loadPending"})
        second_text, _ = session.call("emetgate_read_symbol", {"file": "src/index.js", "symbol": "loadPending"})
    finally:
        session.close()
    baseline = toks(content)
    emetgate = toks(second_text)
    return "read the SAME symbol a second time in one session, --mirror on", baseline, emetgate, 2


def scenario_reread_after_edit(tmp_path):
    original = "export function add(a, b) {\n  return a + b;\n}\n"
    edited = "export function add(a, b) {\n  return a + b + 1;\n}\n"
    with open(tmp_path, "w", encoding="utf-8") as f:
        f.write(original)
    session = McpSession(os.path.dirname(tmp_path), mirror=True)
    try:
        name = os.path.basename(tmp_path)
        session.call("emetgate_read_symbol", {"file": name, "symbol": "add"})
        with open(tmp_path, "w", encoding="utf-8") as f:
            f.write(edited)
        after_text, is_error = session.call("emetgate_read_symbol", {"file": name, "symbol": "add"})
    finally:
        session.close()
    if is_error:
        raise RuntimeError(f"reread after edit failed: {after_text}")
    if "unchanged" in after_text:
        raise RuntimeError("mirror reported unchanged after a real edit; this would be the dangerous direction")
    baseline = toks(edited)
    emetgate = toks(after_text)
    return "reread the SAME symbol after it changed, --mirror on (must not say unchanged)", baseline, emetgate, 3


def scenario_reread_after_edit_real_file():
    src_path = os.path.join(AFFILIATE_SCRAPER, "src", "index.js")
    if not os.path.exists(src_path):
        return None
    content = read(src_path)
    tmp_dir = tempfile.mkdtemp(prefix="emetgate-reader-bench-")
    tmp_path = os.path.join(tmp_dir, "index.js")
    try:
        with open(tmp_path, "w", encoding="utf-8") as f:
            f.write(content)
        subprocess.run(["git", "init", "-q"], cwd=tmp_dir, check=True)
        subprocess.run(["git", "add", "."], cwd=tmp_dir, check=True)
        subprocess.run(
            ["git", "-c", "user.email=bench@example.com", "-c", "user.name=bench", "commit", "-q", "-m", "init"],
            cwd=tmp_dir,
            check=True,
        )
        session = McpSession(tmp_dir, mirror=True)
        try:
            session.call("emetgate_read_symbol", {"file": "index.js", "symbol": "loadPending"})
            edited = content.replace(
                "function loadPending() {",
                "function loadPending() {\n  // emetgate reader bench edit marker",
                1,
            )
            with open(tmp_path, "w", encoding="utf-8") as f:
                f.write(edited)
            after_text, is_error = session.call("emetgate_read_symbol", {"file": "index.js", "symbol": "loadPending"})
        finally:
            session.close()
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)
    if is_error:
        raise RuntimeError(f"reread after edit (real file) failed: {after_text}")
    if "unchanged" in after_text:
        raise RuntimeError("mirror reported unchanged after a real edit on a real file; this would be the dangerous direction")

    start_idx = edited.index("function loadPending()")
    start_line = edited.count("\n", 0, start_idx) + 1
    open_brace = edited.index("{", start_idx)
    depth = 0
    j = open_brace
    while True:
        if edited[j] == "{":
            depth += 1
        elif edited[j] == "}":
            depth -= 1
            if depth == 0:
                break
        j += 1
    end_line = edited.count("\n", 0, j) + 1
    exact_range = "\n".join(edited.splitlines()[start_line - 1 : end_line])

    return {
        "name": "reread a small changed symbol in the real 1.6K-line affiliate-scraper/src/index.js, --mirror on",
        "full_file": toks(edited),
        "best_case_range": toks(exact_range),
        "emetgate": toks(after_text),
    }


def scenario_line_range():
    path = os.path.join(ROOT, "build.zig")
    lines = read(path).splitlines(keepends=True)
    start, end = 10, 15
    exact = "".join(lines[start - 1:end])
    session = McpSession(ROOT)
    try:
        range_text, _ = session.call("emetgate_read_file", {"file": "build.zig", "line_start": start, "line_end": end})
    finally:
        session.close()
    baseline = toks(exact)
    emetgate = toks(range_text)
    return f"line range {start}-{end} of build.zig (sed -n vs a hashed range read)", baseline, emetgate, 4


def main():
    print(HEADER)
    print("{:<70} {:>10} {:>10} {:>8}".format("scenario", "Read", "emetgate", "ratio"))
    scenarios = [
        scenario_big_function(),
        scenario_big_json(),
        scenario_readme_section(),
        scenario_repeat_read(),
        scenario_reread_after_edit(os.path.join(BENCH, "_tmp_reread.js")),
        scenario_line_range(),
    ]
    worse = []
    for s in scenarios:
        if s is None:
            continue
        name, baseline, emetgate, _group = s
        ratio = emetgate / baseline if baseline else float("nan")
        print("{:<70} {:>10} {:>10} {:>7.2f}x".format(name[:70], baseline, emetgate, ratio))
        if emetgate > baseline:
            worse.append(name)
    tmp = os.path.join(BENCH, "_tmp_reread.js")
    if os.path.exists(tmp):
        os.remove(tmp)
    if worse:
        print("\nScenarios where emetgate used MORE tokens than a plain read (not hidden):")
        for name in worse:
            print(f"  - {name}")

    real = scenario_reread_after_edit_real_file()
    if real is not None:
        print()
        print("Real-file version of the mirror reread scenario above (synthetic vs a real 1.6K-line file):")
        print("{:<90} {:>14} {:>16} {:>10}".format("scenario", "Read (full file)", "Read (best case range)", "emetgate"))
        print("{:<90} {:>14} {:>16} {:>10}".format(
            real["name"][:90], real["full_file"], real["best_case_range"], real["emetgate"]
        ))
        print(
            "Even the best case (reading exactly the changed function's line range with sed -n, "
            "which a model cannot know in advance without already having read the file) is "
            f"{real['best_case_range']} tokens against emetgate's {real['emetgate']}; "
            f"ratio {real['emetgate'] / real['best_case_range']:.2f}x."
        )


if __name__ == "__main__":
    main()
