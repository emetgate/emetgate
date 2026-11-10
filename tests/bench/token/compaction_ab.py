"""Compaction A/B: drive a built emetgate MCP server through one realistic
"understand an area" session twice -- once with --no-compact (baseline) and once
with World A compaction on -- and report the real-token cost of each, plus the
resident integral (every reply is re-read on every later turn, so the integral is
the honest session cost). Needs: a release build at zig-out/bin/emetgate.exe and
tiktoken. Run from the repo root:  python tests/bench/token/compaction_ab.py
"""
import json, subprocess, os, tiktoken

enc = tiktoken.get_encoding("o200k_base")
def toks(s): return len(enc.encode(s))

CWD = os.getcwd()
EXE = os.path.join(CWD, "zig-out", "bin", "emetgate.exe")

CALLS = [
    ("emetgate_explore", {"question": "how is the read budget folding computed"}),
    ("emetgate_search", {"pattern": "default_budget", "dir": "src"}),
    ("emetgate_skeleton", {"file": "src/protocol/read_budget.zig"}),
    ("emetgate_read_symbol", {"file": "src/protocol/read_budget.zig", "symbol": "fold"}),
    ("emetgate_search", {"pattern": "Allocator", "dir": "src/engine"}),
    ("emetgate_read_file", {"file": "src/engine/facts_store.zig"}),
    ("emetgate_symbols", {"file": "src/engine/map_explore.zig"}),
    ("emetgate_evidence", {"names": ["fold", "render"]}),
    ("emetgate_read_symbol", {"file": "src/protocol/read_budget.zig", "symbol": "focus"}),
    ("emetgate_git", {"sub": "status"}),
]


def run(flags):
    args = [EXE, "mcp"] + flags
    msgs = [json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                        "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                                   "clientInfo": {"name": "b", "version": "1"}}})]
    for i, (name, a) in enumerate(CALLS, start=2):
        msgs.append(json.dumps({"jsonrpc": "2.0", "id": i, "method": "tools/call",
                                "params": {"name": name, "arguments": a}}))
    p = subprocess.run(args, input="\n".join(msgs) + "\n", capture_output=True,
                       text=True, cwd=CWD, timeout=300)
    resp = {}
    for line in p.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            o = json.loads(line)
            if "id" in o:
                resp[o["id"]] = o
        except Exception:
            pass
    out = []
    for i, (name, a) in enumerate(CALLS, start=2):
        o = resp.get(i)
        t = o["result"]["content"][0]["text"] if (o and "result" in o) else ""
        out.append((name, toks(t)))
    return out


def integral(per):
    cum = total = 0
    for _, tk in per:
        cum += tk
        total += cum
    return total


def main():
    base = run(["--no-compact"])
    world = run([])
    print(f"{'call':<26}{'baseline':>10}{'worldA':>10}")
    for (n, b), (_, w) in zip(base, world):
        print(f"{n:<26}{b:>10}{w:>10}")
    bt = sum(x for _, x in base)
    wt = sum(x for _, x in world)
    print(f"{'-- sum of replies --':<26}{bt:>10}{wt:>10}   ({bt / max(wt, 1):.1f}x)")
    bi = integral(base)
    wi = integral(world)
    print(f"{'-- resident INTEGRAL --':<26}{bi:>10}{wi:>10}   ({bi / max(wi, 1):.1f}x)")


if __name__ == "__main__":
    main()
