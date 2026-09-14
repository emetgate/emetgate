import os, shutil, subprocess, json, sys
import tiktoken

BENCH = os.path.dirname(os.path.abspath(__file__))
MASTER = os.path.join(BENCH, "master")
WORK = os.path.join(BENCH, "work")
SYN = r"C:\Users\ugur\Desktop\Emetgate\zig-out\bin\emetgate.exe"
ENC = tiktoken.get_encoding("o200k_base")
TEST_CMD = "node node_modules/typescript/bin/tsc --noEmit -p tsconfig.json && node --test --experimental-strip-types tests.ts"

def toks(s): return len(ENC.encode(s))

FNS = {
    "add":   ("export function add(a: number, b: number): number", "{ return a + b; }"),
    "sub":   ("export function sub(a: number, b: number): number", "{ return a - b; }"),
    "mul":   ("export function mul(a: number, b: number): number", "{ let r = 0; for (let i = 0; i < b; i++) r += a; return r; }"),
    "clamp": ("export function clamp(x: number, lo: number, hi: number): number", "{ if (x < lo) return lo; if (x > hi) return hi; return x; }"),
    "sum":   ("export function sum(xs: number[]): number", "{ let t = 0; for (const x of xs) t += x; return t; }"),
    "label": ("export function label(n: number): string", "{ if (n >= 0) return \"pos\"; else return \"neg\"; }"),
}

TASKS = [
    {"id": 1, "cat": "valid: refactor",     "fn": "sum",   "body": "{ return xs.reduce((a, b) => a + b, 0); }", "pass": True},
    {"id": 2, "cat": "valid: refactor",     "fn": "clamp", "body": "{ return Math.min(hi, Math.max(lo, x)); }", "pass": True},
    {"id": 3, "cat": "valid: logic",        "fn": "mul",   "body": "{ return a * b; }", "pass": True},
    {"id": 4, "cat": "valid: logic",        "fn": "label", "body": "{ return n >= 0 ? \"pos\" : \"neg\"; }", "pass": True},
    {"id": 5, "cat": "type-error",          "fn": "add",   "body": "{ return \"oops\"; }", "pass": False},
    {"id": 6, "cat": "type-error",          "fn": "clamp", "body": "{ return x + \"!\"; }", "pass": False},
    {"id": 7, "cat": "placeholder",         "fn": "sub",   "body": "{ /* ...existing code... */ }", "pass": False},
    {"id": 8, "cat": "neighbor immutable",  "fn": "add",   "body": "{ return b + a; }", "pass": True},
]

def baseline():
    with open(os.path.join(MASTER, "calc.ts"), encoding="utf-8") as f:
        return f.read()

def old_line(fn):
    sig, body = FNS[fn]
    return sig + " " + body

def new_line(fn, body):
    return FNS[fn][0] + " " + body

def prep(dst, git):
    if os.path.exists(dst): shutil.rmtree(dst, ignore_errors=True)
    shutil.copytree(MASTER, dst, ignore=shutil.ignore_patterns("node_modules", ".git", "work"))
    subprocess.run(["cmd", "/c", "mklink", "/J", os.path.join(dst, "node_modules"), os.path.join(MASTER, "node_modules")],
                   capture_output=True)
    if git:
        for args in (["init", "-q"], ["config", "user.email", "t@t"], ["config", "user.name", "t"],
                     ["add", "."], ["commit", "-q", "-m", "init"]):
            subprocess.run(["git"] + args, cwd=dst, capture_output=True)

def run_tests(cwd):
    r = subprocess.run(["cmd", "/c", TEST_CMD], cwd=cwd, capture_output=True, text=True)
    return r.returncode == 0

def fn_text(content, fn):
    sig = FNS[fn][0]
    i = content.find(sig)
    if i < 0: return None
    j = content.find("}", i)
    return content[i:j+1]

def emetgate_hash(cwd, fn):
    r = subprocess.run([SYN, "symbols", "calc.ts", "--json"], cwd=cwd, capture_output=True, text=True)
    data = json.loads(r.stdout.strip().splitlines()[-1])
    for s in data["symbols"]:
        if s["ref"] == fn: return s["hash"]
    return None

def neighbors_intact(before, after, target):
    for fn in FNS:
        if fn == target: continue
        if fn_text(before, fn) != fn_text(after, fn): return False
    return True

def arm_emetgate(t):
    d = os.path.join(WORK, f"syn{t['id']}")
    prep(d, git=True)
    before = baseline()
    h = emetgate_hash(d, t["fn"])
    r = subprocess.run([SYN, "try", "calc.ts", "--symbol", t["fn"], "--hash", h,
                        "--body", t["body"], "--test", TEST_CMD], cwd=d, capture_output=True, text=True)
    with open(os.path.join(d, "calc.ts"), encoding="utf-8") as f: after = f.read()
    committed = r.returncode == 0
    broken_on_disk = (after != before) and (not run_tests(d))
    emit = toks(" ".join(["calc.ts", t["fn"], h, t["body"], TEST_CMD]))
    return {"emit": emit, "committed": committed, "exit": r.returncode,
            "broken_on_disk": broken_on_disk,
            "neighbors": neighbors_intact(before, after, t["fn"]) if t["cat"].startswith("neighbor") else None}

def arm_textedit(t, whole_file):
    d = os.path.join(WORK, ("full" if whole_file else "sr") + str(t["id"]))
    prep(d, git=False)
    before = baseline()
    ol, nl = old_line(t["fn"]), new_line(t["fn"], t["body"])
    after = before.replace(ol, nl, 1)
    with open(os.path.join(d, "calc.ts"), "w", encoding="utf-8", newline="\n") as f: f.write(after)
    ok = run_tests(d)
    broken_on_disk = (after != before) and (not ok)
    if whole_file:
        emit = toks("calc.ts " + after)
    else:
        emit = toks(" ".join(["calc.ts", ol, nl]))
    return {"emit": emit, "success": ok, "broken_on_disk": broken_on_disk,
            "neighbors": neighbors_intact(before, after, t["fn"]) if t["cat"].startswith("neighbor") else None}

def main():
    os.makedirs(WORK, exist_ok=True)
    rows = []
    for t in TASKS:
        syn = arm_emetgate(t)
        sr = arm_textedit(t, whole_file=False)
        full = arm_textedit(t, whole_file=True)
        rows.append((t, syn, sr, full))

    print("\n=== TOKEN (emit payload, tiktoken o200k_base) ===")
    print(f"{'#':>2} {'category':<20} {'Emetgate':>8} {'Search/Repl':>12} {'Full-File':>10} {'S vs Full':>10}")
    ts = tsr = tf = 0
    for t, syn, sr, full in rows:
        ratio = f"{full['emit']/syn['emit']:.1f}x"
        print(f"{t['id']:>2} {t['cat']:<20} {syn['emit']:>8} {sr['emit']:>12} {full['emit']:>10} {ratio:>10}")
        ts += syn["emit"]; tsr += sr["emit"]; tf += full["emit"]
    print(f"{'':>2} {'TOTAL':<20} {ts:>8} {tsr:>12} {tf:>10} {tf/ts:>9.1f}x")

    print("\n=== FAIL-CLOSED & CORRECTNESS ===")
    print(f"{'#':>2} {'category':<20} {'expect':<7} {'Emetgate':<22} {'Search/Repl':<16} {'Full-File':<16}")
    for t, syn, sr, full in rows:
        exp = "pass" if t["pass"] else "reject"
        s_state = ("committed" if syn["committed"] else f"blocked(exit {syn['exit']})")
        s_broken = "BROKEN ON DISK" if syn["broken_on_disk"] else "clean"
        sr_broken = "BROKEN ON DISK" if sr["broken_on_disk"] else ("ok" if sr["success"] else "clean")
        full_broken = "BROKEN ON DISK" if full["broken_on_disk"] else ("ok" if full["success"] else "clean")
        print(f"{t['id']:>2} {t['cat']:<20} {exp:<7} {s_state+'/'+s_broken:<22} {sr_broken:<16} {full_broken:<16}")

    print("\n=== NEIGHBOR IMMUTABILITY (task 8) ===")
    for t, syn, sr, full in rows:
        if not t["cat"].startswith("neighbor"): continue
        print(f"  Emetgate neighbors intact: {syn['neighbors']}")
        print(f"  Search/Replace neighbors intact: {sr['neighbors']}")
        print(f"  Full-File neighbors intact: {full['neighbors']}")

if __name__ == "__main__":
    main()
