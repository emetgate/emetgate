import os
import subprocess
import sys
import time
import zlib

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


WINNOW_K = 5
WINNOW_W = 4
WINNOW_MIN_LEN = WINNOW_K + WINNOW_W - 1


def kgram_hashes(data, k):
    return [zlib.crc32(data[i:i + k]) for i in range(len(data) - k + 1)]


def winnow(data, k=WINNOW_K, w=WINNOW_W):
    hashes = kgram_hashes(data, k)
    if len(hashes) < w:
        return frozenset(hashes)
    selected = set()
    for start in range(0, len(hashes) - w + 1):
        window = hashes[start:start + w]
        min_val = min(window)
        min_pos = start + w - 1 - window[::-1].index(min_val)
        selected.add(hashes[min_pos])
    return frozenset(selected)


def build_winnow_index(repo, files):
    started = time.perf_counter()
    per_file = {}
    total = set()
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
        g = winnow(data)
        per_file[rel] = g
        total |= g
    elapsed = time.perf_counter() - started
    return per_file, total, elapsed


def winnow_candidates(per_file, query):
    q = query.encode("utf-8")
    if len(q) < WINNOW_MIN_LEN:
        return len(per_file)
    needles = winnow(q)
    if not needles:
        return len(per_file)
    count = 0
    for g in per_file.values():
        if needles <= g:
            count += 1
    return count


def compare_winnowing():
    print()
    print("Real sparse gram: classical winnowing (Schleimer/Wilkerson/Aiken 2003)")
    print(f"vs exhaustive trigram (n=3). k={WINNOW_K}, w={WINNOW_W}, min filterable query length={WINNOW_MIN_LEN}.")
    print("Winnowing guarantees a shared fingerprint for any two occurrences of the same")
    print(f"string of length >= {WINNOW_MIN_LEN}, so it cannot wrongly exclude a real match at or above that length;")
    print(f"below it, this script (like production code) must fall back to a full scan.")
    print()
    for name, repo in REPOS.items():
        if not os.path.isdir(repo):
            continue
        files = tracked_files(repo)
        trigram_per_file, trigram_total, trigram_elapsed = build_index(repo, files, 3)
        winnow_per_file, winnow_total, winnow_elapsed = build_winnow_index(repo, files)
        print(f"== {name} ==")
        print(f"  trigram:  index build {trigram_elapsed:.2f}s, distinct grams {len(trigram_total)}")
        print(f"  winnowing: index build {winnow_elapsed:.2f}s, distinct fingerprints {len(winnow_total)}")
        for q in QUERIES:
            tri_c = candidates(trigram_per_file, q, 3)
            win_c = winnow_candidates(winnow_per_file, q)
            print(f"    query {q!r:20} trigram candidates {tri_c:5} | winnowing candidates {win_c:5} (of {len(files)})")
        print()


if __name__ == "__main__":
    main()
    compare_winnowing()
