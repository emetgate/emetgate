import argparse
import json
import os
import re
import shutil
import subprocess
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
EXE = os.environ.get("EMETGATE_BIN") or os.path.join(ROOT, "zig-out", "bin", "emetgate.exe")
JS_EXTENSIONS = (".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx")


def run(argv, cwd=None, timeout=None):
    return subprocess.run(argv, cwd=cwd, capture_output=True, text=True, timeout=timeout)


def changed_files(repo, sha):
    out = run(["git", "show", "--name-only", "--pretty=format:", sha], cwd=repo)
    return [line for line in out.stdout.splitlines() if line.strip()]


def parents_of(repo, sha):
    out = run(["git", "rev-list", "--parents", "-n", "1", sha], cwd=repo)
    parts = out.stdout.strip().split()
    return parts[1:] if len(parts) > 1 else []


def file_at(repo, sha, path):
    out = subprocess.run(["git", "show", f"{sha}:{path}"], cwd=repo, capture_output=True)
    if out.returncode != 0:
        return None
    return out.stdout


def symbols_of(content, suffix):
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as f:
        f.write(content)
        temp_path = f.name
    try:
        out = run([EXE, "symbols", temp_path, "--json"], timeout=20)
        if out.returncode != 0:
            return None
        try:
            return json.loads(out.stdout)
        except json.JSONDecodeError:
            return None
    finally:
        try:
            os.unlink(temp_path)
        except OSError:
            pass


def find_matching_brace_end_bytes(source, brace_start):
    depth = 0
    i = brace_start
    n = len(source)
    while i < n:
        ch = source[i : i + 1]
        if ch in (b'"', b"'", b"`"):
            quote = ch
            i += 1
            while i < n and source[i : i + 1] != quote:
                if source[i : i + 1] == b"\\":
                    i += 1
                i += 1
        elif ch == b"/" and source[i + 1 : i + 2] == b"/":
            while i < n and source[i : i + 1] != b"\n":
                i += 1
        elif ch == b"/" and source[i + 1 : i + 2] == b"*":
            i += 2
            while i + 1 < n and not (source[i : i + 1] == b"*" and source[i + 1 : i + 2] == b"/"):
                i += 1
            i += 1
        elif ch == b"{":
            depth += 1
        elif ch == b"}":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return None


def extract_block_bytes(source, symbol):
    lines = source.splitlines(keepends=True)
    offset = sum(len(l) for l in lines[: symbol["line"] - 1]) + (symbol["col"] - 1)
    brace_start = source.find(b"{", offset)
    if brace_start == -1:
        return None
    end = find_matching_brace_end_bytes(source, brace_start)
    if end is None:
        return None
    return brace_start, end


def splice_reproduces(before, before_symbol, after, after_symbol):
    before_span = extract_block_bytes(before, before_symbol)
    after_span = extract_block_bytes(after, after_symbol)
    if before_span is None or after_span is None:
        return False
    b_start, b_end = before_span
    a_start, a_end = after_span
    spliced = before[:b_start] + after[a_start:a_end] + before[b_end:]
    return spliced == after


def single_body_change(before_json, after_json):
    if not before_json or not after_json:
        return None
    before = {s["ref"]: s for s in before_json.get("symbols", []) if not s.get("ambiguous")}
    after = {s["ref"]: s for s in after_json.get("symbols", []) if not s.get("ambiguous")}
    if set(before.keys()) != set(after.keys()):
        return None
    changed = [ref for ref in before if before[ref]["hash"] != after[ref]["hash"]]
    if len(changed) != 1:
        return None
    ref = changed[0]
    return {"ref": ref, "before_hash": before[ref]["hash"], "after_hash": after[ref]["hash"]}


def find_candidates(repo, max_commits, max_candidates):
    out = run(["git", "log", "--pretty=format:%H", "-n", str(max_commits)], cwd=repo)
    shas = [s for s in out.stdout.splitlines() if s]
    candidates = []
    for sha in shas:
        if len(candidates) >= max_candidates:
            break
        parents = parents_of(repo, sha)
        if len(parents) != 1:
            continue
        parent = parents[0]
        files = [f for f in changed_files(repo, sha) if f.lower().endswith(JS_EXTENSIONS)]
        if len(files) != 1:
            continue
        rel = files[0]
        before = file_at(repo, parent, rel)
        after = file_at(repo, sha, rel)
        if before is None or after is None or before == after:
            continue
        suffix = os.path.splitext(rel)[1]
        before_json = symbols_of(before, suffix)
        after_json = symbols_of(after, suffix)
        change = single_body_change(before_json, after_json)
        if change is None:
            continue
        before_symbol = next(s for s in before_json["symbols"] if s["ref"] == change["ref"])
        after_symbol = next(s for s in after_json["symbols"] if s["ref"] == change["ref"])
        if not splice_reproduces(before, before_symbol, after, after_symbol):
            continue
        candidates.append(
            {
                "commit": sha,
                "parent": parent,
                "file": rel,
                "symbol": change["ref"],
                "before_hash": change["before_hash"],
                "after_hash": change["after_hash"],
            }
        )
    return candidates


def checkout_worktree(repo, sha, workdir, link_node_modules=False):
    if os.path.exists(workdir):
        shutil.rmtree(workdir)
    out = run(["git", "worktree", "add", "--detach", workdir, sha], cwd=repo, timeout=120)
    if out.returncode == 0 and link_node_modules:
        src = os.path.join(repo, "node_modules")
        dst = os.path.join(workdir, "node_modules")
        if os.path.isdir(src) and not os.path.exists(dst):
            run(["cmd", "/c", "mklink", "/J", dst, src])
    return out.returncode == 0, out.stderr


def remove_worktree(repo, workdir):
    run(["git", "worktree", "remove", "--force", workdir], cwd=repo, timeout=60)


def apply_case(repo, parent_sha, rel, ref, before_hash, new_body, test_command, label, tmp_root, compare_sha=None):
    workdir = os.path.join(tmp_root, f"apply-{label}-{parent_sha[:10]}")
    ok, err = checkout_worktree(repo, parent_sha, workdir, link_node_modules=True)
    if not ok:
        return {"ok": False, "error": err}
    try:
        path = os.path.join(workdir, rel)
        argv = [
            EXE,
            "try",
            path,
            "--symbol",
            ref,
            "--hash",
            before_hash,
            "--body",
            new_body,
            "--test",
            test_command,
            "--json",
        ]
        t0 = time.perf_counter()
        out = run(argv, timeout=600)
        elapsed = (time.perf_counter() - t0) * 1000
        try:
            parsed = json.loads(out.stdout) if out.stdout.strip() else None
        except json.JSONDecodeError:
            parsed = None
        status = (parsed or {}).get("status")
        tree_matches = None
        if status == "committed" and compare_sha is not None:
            resulting = None
            try:
                with open(path, "rb") as f:
                    resulting = f.read()
            except OSError:
                resulting = None
            compare_dir = os.path.join(tmp_root, f"compare-{compare_sha[:10]}")
            expected = None
            if checkout_worktree(repo, compare_sha, compare_dir)[0]:
                try:
                    with open(os.path.join(compare_dir, rel), "rb") as f:
                        expected = f.read()
                except OSError:
                    expected = None
                remove_worktree(repo, compare_dir)
            tree_matches = resulting is not None and expected is not None and resulting == expected
        return {
            "ok": True,
            "status": status,
            "returncode": out.returncode,
            "elapsed_ms": elapsed,
            "parsed": parsed,
            "tree_matches_commit": tree_matches,
        }
    finally:
        remove_worktree(repo, workdir)


def mutate_off_by_one(body):
    match = re.search(r"([<>]=?)", body)
    if not match:
        return body.replace(" 0", " 1", 1) if " 0" in body else body + " "
    table = {"<": "<=", "<=": "<", ">": ">=", ">=": ">"}
    op = match.group(1)
    return body[: match.start()] + table.get(op, op) + body[match.end() :]


def mutate_broken_syntax(body):
    return body.rstrip()[:-1] if body.rstrip().endswith("}") else body + " {"


def replay_repo(repo, name, max_commits, max_candidates, test_command, out_path):
    tmp_root = os.path.join(tempfile.gettempdir(), "emetgate-replay-work")
    os.makedirs(tmp_root, exist_ok=True)
    candidates = find_candidates(repo, max_commits, max_candidates)

    outcomes = {"correct_accept": 0, "wrongful_reject": 0, "leak_accept": 0, "correct_reject": 0}
    records = []

    for cand in candidates:
        after_worktree = os.path.join(tmp_root, f"after-{cand['commit'][:10]}")
        ok, err = checkout_worktree(repo, cand["commit"], after_worktree)
        if not ok:
            continue
        after_path = os.path.join(after_worktree, cand["file"])
        new_body = extract_block_from_file(after_path, cand["symbol"])
        remove_worktree(repo, after_worktree)

        if new_body is None:
            continue

        before_worktree = os.path.join(tmp_root, f"before-{cand['commit'][:10]}")
        ok_b, err_b = checkout_worktree(repo, cand["parent"], before_worktree)
        if not ok_b:
            continue
        before_path = os.path.join(before_worktree, cand["file"])
        actual_before_hash = current_hash(before_path, cand["symbol"])
        remove_worktree(repo, before_worktree)
        if actual_before_hash is None:
            continue

        real = apply_case(
            repo, cand["parent"], cand["file"], cand["symbol"], actual_before_hash, new_body,
            test_command, "real", tmp_root, compare_sha=cand["commit"],
        )
        record = {"candidate": cand, "real": real}

        if real.get("status") == "committed":
            if real.get("tree_matches_commit"):
                outcomes["correct_accept"] += 1
                record["classification"] = "correct_accept"
            else:
                outcomes["leak_accept"] += 1
                record["classification"] = "leak_accept_tree_mismatch"
        else:
            outcomes["wrongful_reject"] += 1
            record["classification"] = "wrongful_reject"

        record["fault_injections"] = {}
        faults = {"off_by_one": mutate_off_by_one(new_body), "broken_syntax": mutate_broken_syntax(new_body)}
        for fault_name, faulty_body in faults.items():
            if faulty_body == new_body:
                continue
            fault = apply_case(
                repo, cand["parent"], cand["file"], cand["symbol"], actual_before_hash, faulty_body, test_command, fault_name, tmp_root
            )
            record["fault_injections"][fault_name] = fault
            if fault.get("status") == "committed":
                outcomes["leak_accept"] += 1
                fault["classification"] = "leak_accept"
            else:
                outcomes["correct_reject"] += 1
                fault["classification"] = "correct_reject"

        records.append(record)

    result = {"name": name, "repo": repo, "candidates_found": len(candidates), "outcomes": outcomes, "records": records}
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(result, f, indent=2)
    return result


def current_hash(path, ref):
    if not os.path.exists(path):
        return None
    out = run([EXE, "symbols", path, "--json"], timeout=20)
    if out.returncode != 0:
        return None
    try:
        data = json.loads(out.stdout)
    except json.JSONDecodeError:
        return None
    target = next((s for s in data.get("symbols", []) if s.get("ref") == ref), None)
    return target["hash"] if target else None


def find_matching_brace_end(source, brace_start):
    depth = 0
    i = brace_start
    n = len(source)
    while i < n:
        ch = source[i]
        if ch in "\"'`":
            quote = ch
            i += 1
            while i < n and source[i] != quote:
                if source[i] == "\\":
                    i += 1
                i += 1
        elif ch == "/" and i + 1 < n and source[i + 1] == "/":
            while i < n and source[i] != "\n":
                i += 1
        elif ch == "/" and i + 1 < n and source[i + 1] == "*":
            i += 2
            while i + 1 < n and not (source[i] == "*" and source[i + 1] == "/"):
                i += 1
            i += 1
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return None


def extract_block_from_file(after_path, ref):
    if not os.path.exists(after_path):
        return None
    with open(after_path, "r", encoding="utf-8", errors="surrogateescape", newline="") as f:
        after_source = f.read()
    out = run([EXE, "symbols", after_path, "--json"], timeout=20)
    if out.returncode != 0:
        return None
    data = json.loads(out.stdout)
    target = next((s for s in data.get("symbols", []) if s.get("ref") == ref), None)
    if target is None:
        return None
    line = target["line"]
    col = target["col"]
    lines = after_source.splitlines(keepends=True)
    offset = sum(len(l) for l in lines[: line - 1]) + (col - 1)
    brace_start = after_source.find("{", offset)
    if brace_start == -1:
        return None
    end = find_matching_brace_end(after_source, brace_start)
    if end is None:
        return None
    return after_source[brace_start:end]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--test", default="cmd /c exit 0")
    parser.add_argument("--max-commits", type=int, default=400)
    parser.add_argument("--max-candidates", type=int, default=10)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    result = replay_repo(
        os.path.abspath(args.repo), args.name, args.max_commits, args.max_candidates, args.test, args.out
    )
    print(json.dumps(result["outcomes"], indent=2))
    print(f"candidates_found={result['candidates_found']}")


if __name__ == "__main__":
    main()
