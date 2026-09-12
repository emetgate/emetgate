import os, subprocess, json
import tiktoken

BENCH = os.path.dirname(os.path.abspath(__file__))
MASTER = os.path.join(BENCH, "master")
SYN = r"C:\Users\ugur\Desktop\Synapse\zig-out\bin\synapse.exe"
ENC = tiktoken.get_encoding("o200k_base")

def toks(s): return len(ENC.encode(s))

SCENARIOS = [
    ("calc.ts", "sum", "{ return xs.reduce((a, b) => a + b, 0); }"),
    ("calc.ts", "clamp", "{ return Math.min(hi, Math.max(lo, x)); }"),
    ("engine.ts", "render", "{\n    return cells.map((v) => (v < 0 ? \"(\" + String(-v) + \")\" : String(v)).padStart(4, \" \")).join(\"|\");\n  }"),
    ("engine.ts", "grade", "{\n    for (const [t, g] of [[90, \"A\"], [80, \"B\"], [70, \"C\"], [60, \"D\"]] as [number, string][]) if (s >= t) return g;\n    return \"F\";\n  }"),
    ("big.ts", "op8", "{ return a * b + 8; }"),
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

def main():
    print("\n=== END-TO-END TOKEN COST per scenario (ingest + emit, tiktoken o200k_base) ===")
    print(f"{'file':<11} {'symbol':<8} {'full-file':>10} {'srch/repl':>10} {'synapse':>9} {'vs full':>9} {'vs s/r':>8}")
    tot = {"full": 0, "sr": 0, "syn": 0}
    for path, sym, new_body in SCENARIOS:
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
        print(f"{path:<11} {sym:<8} {full:>10} {sr:>10} {syn:>9} {full/syn:>8.2f}x {sr/syn:>7.2f}x")

    print(f"{'TOTAL':<11} {'':<8} {tot['full']:>10} {tot['sr']:>10} {tot['syn']:>9} {tot['full']/tot['syn']:>8.2f}x {tot['sr']/tot['syn']:>7.2f}x")
    print("\ningest = full/sr: whole file; synapse: skeleton + one symbol body")
    print("emit   = full: whole rewritten file; sr: old+new block; synapse: symbol ref + hash + new body")

if __name__ == "__main__":
    main()
