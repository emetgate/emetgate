import os, subprocess, json, statistics
import tiktoken

BENCH = os.path.dirname(os.path.abspath(__file__))
MASTER = os.path.join(BENCH, "master")
SYN = r"C:\Users\ugur\Desktop\Emetgate\zig-out\bin\emetgate.exe"
ENC = tiktoken.get_encoding("o200k_base")

def toks(s): return len(ENC.encode(s))

SCENARIOS = [
    ("synthetic", "calc.ts", "sum", "{ return xs.reduce((a, b) => a + b, 0); }"),
    ("synthetic", "calc.ts", "clamp", "{ return Math.min(hi, Math.max(lo, x)); }"),
    ("synthetic", "engine.ts", "render", "{\n    return cells.map((v) => (v < 0 ? \"(\" + String(-v) + \")\" : String(v)).padStart(4, \" \")).join(\"|\");\n  }"),
    ("synthetic", "big.ts", "op8", "{ return a * b + 8; }"),
    ("real", "realworld/camelCase.ts", "camelCase", "{\n  return str.trim().replace(/[-_\\s]+(.)?/g, (_, c) => (c ? c.toUpperCase() : \"\")).replace(/^(.)/, (_, c) => c.toLowerCase());\n}"),
    ("real", "realworld/round.ts", "round", "{\n  const factor = 10 ** precision;\n  return Math.round(value * factor) / factor;\n}"),
]

def read(path):
    with open(os.path.join(MASTER, path), encoding="utf-8") as f:
        return f.read()

def skeleton(path):
    return subprocess.run([SYN, "skeleton", path], cwd=MASTER, capture_output=True, text=True).stdout

def sym_hash(path, sym):
    r = subprocess.run([SYN, "symbols", path, "--json"], cwd=MASTER, capture_output=True, text=True)
    for s in json.loads(r.stdout.strip().splitlines()[-1])["symbols"]:
        if s["ref"] == sym: return s["hash"]
    raise KeyError(sym)

def fn_text(content, sym):
    i = content.find("export function " + sym + "(")
    b = content.find("{", i)
    depth = 0
    for j in range(b, len(content)):
        if content[j] == "{": depth += 1
        elif content[j] == "}":
            depth -= 1
            if depth == 0: return content[i:j + 1], content[b:j + 1], content[i:b]
    raise ValueError(sym)

HEADER = """\
Emetgate token benchmark - surgical edit round-trip (ingest + emit)
Methodology (read before quoting a number):
- Tokenizer: o200k_base (GPT-4o-family proxy; NOT Claude's tokenizer). Absolute counts
  are approximate; the RATIO between approaches is the signal.
- Scope: a single symbol edit. Multi-turn sessions are NOT measured -> this is a floor.
- Primary baseline: Search/Replace (what modern diff/apply editors emit).
- Secondary: Full-file emit = UPPER BOUND, assumes a whole-file rewrite (whole-file .md
  style). Modern tools diff/apply, so treat full-file as the ceiling, not the norm.
- Counts: ingest (full/S-R read the whole file; Emetgate reads skeleton + one symbol body)
  + emit (full rewrites the whole file; S-R sends old+new block; Emetgate sends symbol
  ref + content hash + new body).
- MCP tool-schema / register-frame fixed cost: EXCLUDED (amortized once per session).
- Fixtures: synthetic (calc/engine/big) and real (es-toolkit, MIT; master/realworld/NOTICE.md).
- Reproduce: `python tests/bench/run4.py` (deterministic; reads vendored files, no network)."""

def main():
    print(HEADER)
    print("\n{:<24} {:<10} {:<10} {:>7} {:>8} {:>10} {:>7} {:>10}".format(
        "file", "kind", "symbol", "S/R", "emetgate", "S/R vs syn", "full", "full vs syn"))
    tot = {"full": 0, "sr": 0, "syn": 0}
    sr_ratios, full_ratios = [], []
    for kind, path, sym, new_body in SCENARIOS:
        content = read(path)
        old_line, body, sig = fn_text(content, sym)
        new_line = sig + new_body
        new_whole = content.replace(old_line, new_line, 1)
        h = sym_hash(path, sym)
        skel = skeleton(path)

        full = toks(content) + toks(new_whole)
        sr = toks(content) + toks(old_line) + toks(new_line)
        syn = (toks(skel) + toks(body)) + (toks(sym) + toks(h) + toks(new_body))
        tot["full"] += full; tot["sr"] += sr; tot["syn"] += syn
        sr_ratios.append(sr / syn); full_ratios.append(full / syn)
        print("{:<24} {:<10} {:<10} {:>7} {:>8} {:>9.2f}x {:>7} {:>9.2f}x".format(
            path, kind, sym, sr, syn, sr / syn, full, full / syn))

    print("{:<24} {:<10} {:<10} {:>7} {:>8} {:>9.2f}x {:>7} {:>9.2f}x".format(
        "TOTAL", "", "", tot["sr"], tot["syn"], tot["sr"] / tot["syn"], tot["full"], tot["full"] / tot["syn"]))

    print("\nPrimary (vs Search/Replace): min {:.2f}x  median {:.2f}x  max {:.2f}x".format(
        min(sr_ratios), statistics.median(sr_ratios), max(sr_ratios)))
    print("Secondary (vs full-file, UPPER BOUND): min {:.2f}x  median {:.2f}x  max {:.2f}x".format(
        min(full_ratios), statistics.median(full_ratios), max(full_ratios)))
    print("Note: the high end scales with file size (big.ts is a 15-function file); small")
    print("files sit near the median. Do not quote the max as typical.")

if __name__ == "__main__":
    main()
