import difflib
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
EXPRESS = os.environ.get("EMETGATE_EXPRESS") or os.path.join(ROOT, "..", "eval", "express-test")
DISPLAY_ROOT = "C:\\Users\\dev\\project\\"
ENC = tiktoken.get_encoding("o200k_base")
TEST_COMMAND = "exit 0"


def toks(text):
    return len(ENC.encode(text))


def call_cost(name, arguments):
    return toks(name) + toks(json.dumps(arguments, ensure_ascii=False))


class Flow:
    def __init__(self):
        self.sent = 0
        self.received = 0
        self.turns = 0
        self.failed = 0

    def call(self, name, arguments, result, failed=False):
        self.sent += call_cost(name, arguments)
        self.received += toks(result)
        self.turns += 1
        if failed:
            self.failed += 1

    @property
    def total(self):
        return self.sent + self.received


class McpSession:
    def __init__(self, cwd):
        self.proc = subprocess.Popen(
            [SYN, "mcp", "--test", TEST_COMMAND],
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
        self.proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self._id, "method": method, "params": params}) + "\n")
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        if not line:
            raise RuntimeError("emetgate mcp produced no response: " + self.proc.stderr.read())
        return json.loads(line)

    def call(self, name, arguments):
        reply = self._send("tools/call", {"name": name, "arguments": arguments})
        result = reply.get("result")
        if result is None:
            raise RuntimeError(f"tool call failed: {reply}")
        return result["content"][0]["text"], result["isError"]

    def close(self):
        self.proc.stdin.close()
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def read(path):
    with open(path, encoding="utf-8", newline="") as f:
        return f.read()


def cat_n(content):
    lines = content.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return "\n".join(f"{i + 1:>6}\t{line}" for i, line in enumerate(lines))


def changed_lines(old, new):
    prefix = 0
    while prefix < min(len(old), len(new)) and old[prefix] == new[prefix]:
        prefix += 1
    suffix = 0
    while suffix < min(len(old), len(new)) - prefix and old[len(old) - 1 - suffix] == new[len(new) - 1 - suffix]:
        suffix += 1
    start = old.rfind("\n", 0, prefix) + 1
    old_end = old.find("\n", len(old) - suffix)
    old_end = len(old) if old_end == -1 else old_end
    new_end = new.find("\n", len(new) - suffix)
    new_end = len(new) if new_end == -1 else new_end
    return start, old_end, new_end


def builtin_edit(flow, path, old, new):
    display = DISPLAY_ROOT + path.replace("/", "\\")
    start, old_end, new_end = changed_lines(old, new)
    tail = len(old) - old_end
    while True:
        old_string = old[start:old_end]
        new_string = new[start:len(new) - tail]
        arguments = {"file_path": display, "old_string": old_string, "new_string": new_string}
        matches = old.count(old_string)
        if matches == 1:
            flow.call("Edit", arguments, f"The file {display} has been updated successfully.")
            return
        flow.call("Edit", arguments, f"Found {matches} matches of the string to replace, but replace_all is false. To replace all occurrences, set replace_all to true. To replace only one occurrence, please provide more context to uniquely identify the instance.\nString: {old_string}", failed=True)
        grown_start = old.rfind("\n", 0, max(start - 1, 0)) + 1 if start > 0 else 0
        grown_end = old.find("\n", old_end + 1)
        grown_end = len(old) if grown_end == -1 else grown_end
        tail = len(old) - grown_end
        start, old_end = grown_start, grown_end


def builtin_flow(path, old, steps, already_read):
    flow = Flow()
    display = DISPLAY_ROOT + path.replace("/", "\\")
    if not already_read:
        flow.call("Read", {"file_path": display}, cat_n(old))
    current = old
    for after in steps:
        builtin_edit(flow, path, current, after)
        current = after
    return flow


def other_formats(old, new):
    diff = difflib.unified_diff(old.splitlines(keepends=True), new.splitlines(keepends=True), n=3)
    udiff = "".join(line if not line.startswith("@@") else "@@ @@\n" for line in diff)
    start, old_end, new_end = changed_lines(old, new)
    search_replace = "<<<<<<< SEARCH\n" + old[start:old_end] + "\n=======\n" + new[start:new_end] + "\n>>>>>>> REPLACE\n"
    return {"whole-file": toks(new), "udiff": toks(udiff), "search/replace": toks(search_replace)}


def address_of(annotated, line_text):
    for line in annotated.split("\n"):
        head, bar, rest = line.partition("|")
        if bar and len(head) >= 12 and all(c in "0123456789abcdef" for c in head) and rest.strip() == line_text.strip():
            return head
    raise KeyError(f"no node hash on the line: {line_text!r}")


class Scenario:
    def __init__(self, name, path, symbol, edits, already_read=False, note=""):
        self.name = name
        self.path = path
        self.symbol = symbol
        self.edits = edits
        self.already_read = already_read
        self.note = note


def copy_project(source_root, files):
    work = tempfile.mkdtemp(prefix="emetgate-write-")
    for rel in files:
        target = os.path.join(work, rel)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        shutil.copyfile(os.path.join(source_root, rel), target)
    subprocess.run(["git", "init", "-q"], cwd=work, check=True)
    subprocess.run(["git", "add", "-A"], cwd=work, check=True)
    subprocess.run(["git", "-c", "user.name=bench", "-c", "user.email=bench@example.invalid", "commit", "-q", "-m", "base"], cwd=work, check=True)
    return work


def emetgate_flow(source_root, scenario):
    work = copy_project(source_root, [scenario.path])
    flow = Flow()
    session = McpSession(work)
    try:
        read_args = {"file": scenario.path, "symbol": scenario.symbol, "nodes": True}
        text, is_error = session.call("emetgate_read_symbol", read_args)
        if is_error:
            raise RuntimeError(text)
        annotated = json.loads(text)["nodes"]
        if not scenario.already_read:
            flow.call("emetgate_read_symbol", read_args, text)
        items = [{"node": address_of(annotated, line), "text": new} for line, _old, new in scenario.edits]
        arguments = {"file": scenario.path, **(items[0] if len(items) == 1 else {"nodes": items})}
        result, is_error = session.call("emetgate_try", arguments)
        flow.call("emetgate_try", arguments, result, failed=is_error)
        if is_error:
            raise RuntimeError(f"{scenario.name}: {result}")
        after = read(os.path.join(work, scenario.path))
    finally:
        session.close()
        shutil.rmtree(work, ignore_errors=True)
    return flow, after


def expected_steps(original, edits):
    steps = []
    current = original
    for _line, old, new in edits:
        if current.count(old) != 1:
            raise RuntimeError(f"scenario text is not unique in the file: {old!r}")
        current = current.replace(old, new, 1)
        steps.append(current)
    return steps


EXPRESS_SCENARIOS = [
    Scenario(
        "one line in a large function",
        "lib/response.js", "sendfile",
        [("if (err && err.code === 'ECONNRESET') return onaborted();",
          "if (err && err.code === 'ECONNRESET') return onaborted();",
          "if (err && (err.code === 'ECONNRESET' || err.code === 'EPIPE')) return onaborted();")],
    ),
    Scenario(
        "one line whose text occurs three times",
        "lib/response.js", "sendfile",
        [("function onerror(err) {",
          "function onerror(err) {\n    if (done) return;\n    done = true;\n    callback(err);\n  }",
          "function onerror(err) {\n    if (done) return;\n    done = true;\n    callback(err || new Error('unknown error'));\n  }")],
        note="callback(err); occurs three times: Edit needs a retry, the node is not unique so emetgate sends the enclosing function",
    ),
    Scenario(
        "replace an if block",
        "lib/utils.js", "acceptParams",
        [("if (key === 'q') {",
          "if (key === 'q') {\n      ret.quality = parseFloat(value);\n    } else {\n      ret.params[key] = value;\n    }",
          "if (key === 'q') {\n      var quality = parseFloat(value);\n      ret.quality = isNaN(quality) ? 1 : quality;\n    } else {\n      ret.params[key.toLowerCase()] = value;\n    }")],
    ),
    Scenario(
        "replace a small function whole",
        "lib/utils.js", "parseExtendedQueryString",
        [("function parseExtendedQueryString(str) {",
          "function parseExtendedQueryString(str) {\n  return qs.parse(str, {\n    allowPrototypes: true\n  });\n}",
          "function parseExtendedQueryString(str) {\n  return qs.parse(str, {\n    allowPrototypes: true,\n    depth: 10,\n    arrayLimit: 100\n  });\n}")],
    ),
    Scenario(
        "delete a function",
        "lib/application.js", "logerror",
        [("function logerror(err) {",
          "function logerror(err) {\n  /* istanbul ignore next */\n  if (this.get('env') !== 'test') console.error(err);\n}",
          "")],
    ),
    Scenario(
        "two edits in one file",
        "lib/response.js", "sendfile",
        [("var err = new Error('Request aborted');",
          "var err = new Error('Request aborted');",
          "var err = new Error('Request aborted by the client');"),
         ("var err = new Error('EISDIR, read');",
          "var err = new Error('EISDIR, read');",
          "var err = new Error('EISDIR, illegal operation on a directory');")],
    ),
    Scenario(
        "one line, file already read (Read costs 0)",
        "lib/response.js", "sendfile",
        [("if (err && err.code === 'ECONNRESET') return onaborted();",
          "if (err && err.code === 'ECONNRESET') return onaborted();",
          "if (err && (err.code === 'ECONNRESET' || err.code === 'EPIPE')) return onaborted();")],
        already_read=True,
    ),
]


HEADER = """\
Emetgate write benchmark: the built-in Read + Edit flow vs emetgate node edits
Methodology (read before quoting a number):
- Tokenizer: o200k_base (GPT-4o-family proxy; NOT Claude's tokenizer). Absolute counts
  are approximate; the RATIO between the flows is the signal.
- A flow is every tool call a model makes for the edit: the call (tool name + JSON
  arguments) and the text the tool returns, summed. Tool schemas are left out on both sides.
- Built-in flow, Claude Code's rules: Edit needs a prior Read of the file (cat -n
  output, whole file, the default); old_string is the changed lines, and when they occur
  more than once the call fails and is retried with one more line of context on each side
  (the failed call and its error message count). Edit returns one success line. The
  built-in flow runs no test; emetgate's does (the test command here is a no-op).
- emetgate flow: emetgate_read_symbol with nodes:true, then one emetgate_try with the node
  hash of the line that starts the edited node and that node's new text; both are real
  MCP calls against a git copy of the file, and the file on disk is checked afterwards.
- "file already read": the Read (and the emetgate read) cost 0; only the edit call counts.
- Other formats: the model's emitted edit alone in Aider's formats (whole file, udiff with
  3 context lines, SEARCH/REPLACE), without the Read that each still needs.
- Fixtures: express (eval/express-test, MIT), copied into a temporary git repo per scenario.
- Reproduce: `python tests/bench/write_flow.py` (needs a built emetgate binary)."""


def run(source_root, scenarios, label):
    rows = []
    for scenario in scenarios:
        original = read(os.path.join(source_root, scenario.path))
        steps = expected_steps(original, scenario.edits)
        builtin = builtin_flow(scenario.path, original, steps, scenario.already_read)
        emetgate, after = emetgate_flow(source_root, scenario)
        if after != steps[-1]:
            raise RuntimeError(f"{scenario.name}: emetgate wrote something other than the intended edit")
        formats = other_formats(original, steps[-1])
        rows.append((label, scenario, builtin, emetgate, formats))
    return rows


def main():
    if not os.path.exists(SYN):
        raise SystemExit(f"emetgate binary not found at {SYN}; run `zig build` or set EMETGATE_BIN")
    print(HEADER)
    rows = []
    if os.path.isdir(EXPRESS):
        rows += run(EXPRESS, EXPRESS_SCENARIOS, "express")
    else:
        print(f"\nexpress copy not found at {EXPRESS}; set EMETGATE_EXPRESS")
    print("\n{:<44} {:>9} {:>9} {:>7} {:>11} {:>7}   {}".format("scenario", "built-in", "emetgate", "ratio", "turns b/e", "failed", "emitted edit alone: whole-file / udiff / S-R / emetgate"))
    below = []
    for label, scenario, builtin, emetgate, formats in rows:
        ratio = builtin.total / emetgate.total
        print("{:<44} {:>9} {:>9} {:>6.2f}x {:>5}/{:<5} {:>3}/{:<3}   {} / {} / {} / {}".format(
            scenario.name[:44], builtin.total, emetgate.total, ratio, builtin.turns, emetgate.turns, builtin.failed, emetgate.failed,
            formats["whole-file"], formats["udiff"], formats["search/replace"], emetgate.sent))
        if ratio < 3:
            below.append((scenario, ratio, builtin, emetgate))
    for label, scenario, builtin, emetgate, _formats in rows:
        if scenario.note:
            print(f"\nnote, {scenario.name}: {scenario.note}")
    if below:
        print("\nScenarios under 3x (not hidden):")
        for scenario, ratio, builtin, emetgate in below:
            print(f"  - {scenario.name}: {ratio:.2f}x; built-in sent {builtin.sent} and received {builtin.received}, emetgate sent {emetgate.sent} and received {emetgate.received}")
    if "--json" in sys.argv:
        print(json.dumps([{"scenario": s.name, "builtin": b.total, "emetgate": e.total, "builtin_turns": b.turns, "emetgate_turns": e.turns, "builtin_failed": b.failed, "emetgate_failed": e.failed} for _l, s, b, e, _f in rows]))


if __name__ == "__main__":
    main()
