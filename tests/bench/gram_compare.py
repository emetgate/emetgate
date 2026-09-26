import os
import subprocess
import sys
import time

CODE_A = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PROJECT_ROOT = os.path.dirname(CODE_A)
EVAL_ROOT = os.environ.get("EMETGATE_EVAL_ROOT", os.path.join(PROJECT_ROOT, "eval"))

REPOS = {
    "express-test": os.path.join(EVAL_ROOT, "express-test"),
    "eslint-test": os.path.join(EVAL_ROOT, "eslint-test"),
}

QUERIES = [
    "loadPending",
    "TypeError",
    "function",
    "require(",
    "console.log",
]

MAX_FILE_BYTES = 1 * 1024 * 1024


def tracked_files(repo):
    out = subprocess.run(["git", "ls-files"], cwd=repo, capture_output=True, text=True, check=True)
    return [line for line in out.stdout.splitlines() if line]


def grams_of(data, n):
    if len(data) < n:
        return frozenset()
    return frozenset(data[i:i + n] for i in range(len(data) - n + 1))


def build_index(repo, files, n):
    started = time.perf_counter()
    per_file = {}
    total_grams = set()
    for rel in files:
        path = os.path.join(repo, rel)
        try:
            if os.path.getsize(path) > MAX_FILE_BYTES:
                continue
            with open(path, "rb") as f:
                data = f.read()
        except OSError:
            continue
        if b"\x00" in data:
            continue
        g = grams_of(data, n)
        per_file[rel] = g
        total_grams |= g
    elapsed = time.perf_counter() - started
    return per_file, total_grams, elapsed


def candidates(per_file, query, n):
    q = query.encode("utf-8")
    needles = grams_of(q, n)
    if not needles:
        return len(per_file)
    count = 0
    for g in per_file.values():
        if needles <= g:
            count += 1
    return count


def main():
    print("Sparse gram size comparison: n=3 (trigram, Zoekt-style) vs n=4")
    print("(a simple proxy for the 'longer/sparser gram' direction Blackbird explores;")
    print("this does NOT reimplement Blackbird's trained feature-weighting model)")
    print()
    for name, repo in REPOS.items():
        if not os.path.isdir(repo):
            print(f"skip {name}: not found at {repo}")
            continue
        files = tracked_files(repo)
        print(f"== {name} ({len(files)} tracked files) ==")
        for n in (3, 4):
            per_file, total_grams, elapsed = build_index(repo, files, n)
            print(f"  n={n}: index build {elapsed:.2f}s, distinct grams {len(total_grams)}, indexed files {len(per_file)}")
            for q in QUERIES:
                c = candidates(per_file, q, n)
                print(f"    query {q!r:20} candidates {c:5} / {len(per_file)}")
        print()


if __name__ == "__main__":
    main()
