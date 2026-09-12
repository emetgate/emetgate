import os, shutil, subprocess, json
import tiktoken

BENCH = os.path.dirname(os.path.abspath(__file__))
MASTER = os.path.join(BENCH, "master")
WORK = os.path.join(BENCH, "work2")
SYN = r"C:\Users\ugur\Desktop\Synapse\zig-out\bin\synapse.exe"
ENC = tiktoken.get_encoding("o200k_base")
TEST_CMD = "node node_modules/typescript/bin/tsc --noEmit -p tsconfig.json && node --test --experimental-strip-types engine.test.ts"
FILE = "engine.ts"

def toks(s): return len(ENC.encode(s))

SIG = {
    "abs1":   "export function abs1(x: number): number",
    "grade":  "export function grade(s: number): string",
    "render": "export function render(cells: number[]): string",
}

NEW_BODY = {
    "abs1": "{ return Math.abs(x); }",
    "grade": "{\n    const table: Array<[number, string]> = [[90, \"A\"], [80, \"B\"], [70, \"C\"], [60, \"D\"]];\n    for (const [t, g] of table) if (s >= t) return g;\n    return \"F\";\n  }",
    "render": "{\n    return cells\n      .map((v) => {\n        const s = v < 0 ? \"(\" + String(-v) + \")\" : String(v);\n        return s.padStart(4, \" \");\n      })\n      .join(\"|\");\n  }",
}

def master_engine():
    with open(os.path.join(MASTER, FILE), encoding="utf-8") as f:
        return f.read()

def fn_text(content, fn):
    i = content.find(SIG[fn])
    b = content.find("{", i)
    depth = 0
    for j in range(b, len(content)):
        if content[j] == "{": depth += 1
        elif content[j] == "}":
            depth -= 1
            if depth == 0: return content[i:j+1]
    raise ValueError(fn)

def new_fn(fn):
    return SIG[fn] + " " + NEW_BODY[fn]

def prep(dst, git):
    if os.path.exists(dst): shutil.rmtree(dst, ignore_errors=True)
    shutil.copytree(MASTER, dst, ignore=shutil.ignore_patterns("node_modules", ".git", "work", "work2"))
    subprocess.run(["cmd", "/c", "mklink", "/J", os.path.join(dst, "node_modules"), os.path.join(MASTER, "node_modules")], capture_output=True)
    if git:
        with open(os.path.join(dst, ".synapserc.json"), "w", encoding="utf-8") as f:
            f.write(json.dumps({"test_cmd": TEST_CMD}))
        for a in (["init","-q"],["config","user.email","t@t"],["config","user.name","t"],["add","."],["commit","-q","-m","i"]):
            subprocess.run(["git"]+a, cwd=dst, capture_output=True)

def run_tests(cwd):
    return subprocess.run(["cmd","/c",TEST_CMD], cwd=cwd, capture_output=True, text=True).returncode == 0

def syn_hash(cwd, fn):
    r = subprocess.run([SYN,"symbols",FILE,"--json"], cwd=cwd, capture_output=True, text=True)
    for s in json.loads(r.stdout.strip().splitlines()[-1])["symbols"]:
        if s["ref"] == fn: return s["hash"]

def emit_syn(fn, h):     return toks(" ".join([FILE, fn, h, NEW_BODY[fn]]))
def emit_sr(content, fn): return toks(" ".join([FILE, fn_text(content, fn), new_fn(fn)]))
def emit_full(content):   return toks(FILE + " " + content)

def single(fn):
    base = master_engine()
    # synapse
    d = os.path.join(WORK, "syn_"+fn); prep(d, git=True)
    h = syn_hash(d, fn)
    r = subprocess.run([SYN,"try",FILE,"--symbol",fn,"--hash",h,"--body",NEW_BODY[fn]], cwd=d, capture_output=True, text=True)
    syn_ok = r.returncode == 0 and run_tests(d)
    # text edits
    after = base.replace(fn_text(base, fn), new_fn(fn), 1)
    d2 = os.path.join(WORK, "sr_"+fn); prep(d2, git=False)
    with open(os.path.join(d2, FILE), "w", encoding="utf-8", newline="\n") as f: f.write(after)
    te_ok = run_tests(d2)
    return {
        "syn_emit": emit_syn(fn, h), "sr_emit": emit_sr(base, fn), "full_emit": emit_full(after),
        "syn_ok": syn_ok, "te_ok": te_ok,
    }

def multi(seq):
    base = master_engine()
    # synapse: sequential commits in one repo
    d = os.path.join(WORK, "syn_multi"); prep(d, git=True)
    hashes = {fn: syn_hash(d, fn) for fn in seq}
    syn_emit = 0
    for fn in seq:
        syn_emit += emit_syn(fn, hashes[fn])
        subprocess.run([SYN,"try",FILE,"--symbol",fn,"--hash",hashes[fn],"--body",NEW_BODY[fn]], cwd=d, capture_output=True, text=True)
    syn_ok = run_tests(d)
    # search/replace: cumulative, each edit emits old+new of current content
    content = base; sr_emit = 0
    for fn in seq:
        sr_emit += emit_sr(content, fn)
        content = content.replace(fn_text(content, fn), new_fn(fn), 1)
    # full-file: each edit re-emits the whole current file
    content2 = base; full_emit = 0
    for fn in seq:
        content2 = content2.replace(fn_text(content2, fn), new_fn(fn), 1)
        full_emit += emit_full(content2)
    d2 = os.path.join(WORK, "te_multi"); prep(d2, git=False)
    with open(os.path.join(d2, FILE), "w", encoding="utf-8", newline="\n") as f: f.write(content)
    te_ok = run_tests(d2)
    return {"syn_emit": syn_emit, "sr_emit": sr_emit, "full_emit": full_emit, "syn_ok": syn_ok, "te_ok": te_ok}

def body_lines(fn): return NEW_BODY[fn].count("\n") + 1

def main():
    os.makedirs(WORK, exist_ok=True)
    base = master_engine()
    print("\n=== ROUND 2: SIZE SWEEP (single valid refactor, emit tokens, Synapse test_cmd from config) ===")
    print(f"{'function':<10} {'orig lines':>10} {'Synapse':>8} {'Srch/Repl':>10} {'Full-File':>10} {'S vs SR':>8} {'S vs Full':>10} {'ok'}")
    for fn in ["abs1", "grade", "render"]:
        n = fn_text(base, fn).count("\n") + 1
        r = single(fn)
        ok = "OK" if (r["syn_ok"] and r["te_ok"]) else "FAIL"
        print(f"{fn:<10} {n:>10} {r['syn_emit']:>8} {r['sr_emit']:>10} {r['full_emit']:>10} "
              f"{r['sr_emit']/r['syn_emit']:>7.2f}x {r['full_emit']/r['syn_emit']:>9.2f}x  {ok}")

    print("\n=== ROUND 2: MULTI-EDIT (3 sequential edits to one file) ===")
    m = multi(["abs1", "grade", "render"])
    print(f"{'':<10} {'':>10} {'Synapse':>8} {'Srch/Repl':>10} {'Full-File':>10} {'S vs SR':>8} {'S vs Full':>10} {'ok'}")
    ok = "OK" if (m["syn_ok"] and m["te_ok"]) else "FAIL"
    print(f"{'3 edits':<10} {'':>10} {m['syn_emit']:>8} {m['sr_emit']:>10} {m['full_emit']:>10} "
          f"{m['sr_emit']/m['syn_emit']:>7.2f}x {m['full_emit']/m['syn_emit']:>9.2f}x  {ok}")

if __name__ == "__main__":
    main()
