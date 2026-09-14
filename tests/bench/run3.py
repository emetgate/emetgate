import os, subprocess
import tiktoken

BENCH = os.path.dirname(os.path.abspath(__file__))
MASTER = os.path.join(BENCH, "master")
SYN = r"C:\Users\ugur\Desktop\Emetgate\zig-out\bin\emetgate.exe"
ENC = tiktoken.get_encoding("o200k_base")

def toks(s): return len(ENC.encode(s))

CASES = [
    ("calc.ts", "sum"),
    ("engine.ts", "render"),
    ("big.ts", "op8"),
]

def read(path):
    with open(os.path.join(MASTER, path), encoding="utf-8") as f:
        return f.read()

def skeleton(path):
    r = subprocess.run([SYN, "skeleton", path], cwd=MASTER, capture_output=True, text=True)
    return r.stdout

def body_of(content, fn):
    i = content.find(fn + "(")
    i = content.rfind("export function", 0, i)
    b = content.find("{", i)
    depth = 0
    for j in range(b, len(content)):
        if content[j] == "{": depth += 1
        elif content[j] == "}":
            depth -= 1
            if depth == 0: return content[b:j+1]
    raise ValueError(fn)

def main():
    print("\n=== INGEST TOKENS: read a file to edit ONE symbol (tiktoken o200k_base) ===")
    print(f"{'file':<12} {'fns':>4} {'target':<8} {'cat whole':>10} {'skeleton':>9} {'+1 body':>8} {'Emetgate':>8} {'cat vs Emetgate':>15}")
    for path, fn in CASES:
        content = read(path)
        n = content.count("export function")
        cat = toks(content)
        sk = toks(skeleton(path))
        body = toks(body_of(content, fn))
        syn = sk + body
        print(f"{path:<12} {n:>4} {fn:<8} {cat:>10} {sk:>9} {body:>8} {syn:>8} {cat/syn:>14.2f}x")

if __name__ == "__main__":
    main()
