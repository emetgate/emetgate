import argparse
import json
import os
import shutil
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
EXE = os.environ.get("EMETGATE_BIN") or os.path.join(ROOT, "zig-out", "bin", "emetgate.exe")
JS_EXTENSIONS = (".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx")
SKELETON_SAMPLE = int(os.environ.get("SKELETON_SAMPLE", "40"))


def run(argv, cwd=None, timeout=None):
    return subprocess.run(argv, cwd=cwd, capture_output=True, text=True, timeout=timeout)


def tracked_files(repo):
    out = subprocess.run(["git", "ls-files", "-z"], cwd=repo, capture_output=True)
    if out.returncode != 0:
        raise RuntimeError(f"git ls-files failed: {out.stderr}")
    return [f.decode("utf-8", "surrogateescape") for f in out.stdout.split(b"\x00") if f]


def file_size(repo, rel):
    try:
        return os.path.getsize(os.path.join(repo, rel))
    except OSError:
        return 0


def measure_tree(repo):
    files = tracked_files(repo)
    total_bytes = sum(file_size(repo, f) for f in files)
    js_files = [f for f in files if f.lower().endswith(JS_EXTENSIONS)]
    js_bytes = sum(file_size(repo, f) for f in js_files)
    return {
        "tracked_files": len(files),
        "tracked_bytes": total_bytes,
        "js_files": len(js_files),
        "js_bytes": js_bytes,
    }, js_files


def measure_skeleton_symbols(repo, js_files):
    sample = js_files[:SKELETON_SAMPLE]
    skeleton_ms = []
    symbols_ms = []
    ok = 0
    for rel in sample:
        path = os.path.join(repo, rel)
        t0 = time.perf_counter()
        r1 = run([EXE, "skeleton", path], timeout=30)
        skeleton_ms.append((time.perf_counter() - t0) * 1000)
        t0 = time.perf_counter()
        r2 = run([EXE, "symbols", path, "--json"], timeout=30)
        symbols_ms.append((time.perf_counter() - t0) * 1000)
        if r1.returncode == 0 and r2.returncode == 0:
            ok += 1
    return {
        "sampled_files": len(sample),
        "ok_files": ok,
        "skeleton_ms_total": sum(skeleton_ms),
        "skeleton_ms_mean": (sum(skeleton_ms) / len(skeleton_ms)) if skeleton_ms else 0.0,
        "symbols_ms_total": sum(symbols_ms),
        "symbols_ms_mean": (sum(symbols_ms) / len(symbols_ms)) if symbols_ms else 0.0,
    }


def pick_edit_target(repo, js_files):
    for rel in js_files:
        path = os.path.join(repo, rel)
        out = run([EXE, "symbols", path, "--json"], timeout=30)
        if out.returncode != 0:
            continue
        try:
            data = json.loads(out.stdout)
        except json.JSONDecodeError:
            continue
        for sym in data.get("symbols", []):
            if sym.get("kind") == "function" and not sym.get("ambiguous", False):
                return rel, sym
    return None, None


def shadow_copy_proxy(repo, files):
    dest = repo + ".shadow-proxy"
    if os.path.exists(dest):
        shutil.rmtree(dest)
    t0 = time.perf_counter()
    for rel in files:
        src = os.path.join(repo, rel)
        dst = os.path.join(dest, rel)
        try:
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copyfile(src, dst)
        except OSError:
            pass
    elapsed = (time.perf_counter() - t0) * 1000
    shutil.rmtree(dest, ignore_errors=True)
    return elapsed


def run_try(repo, rel, sym, test_command, typecheck_command=None):
    path = os.path.join(repo, rel)
    body = "{ return undefined; }"
    argv = [
        EXE,
        "try",
        path,
        "--symbol",
        sym["ref"],
        "--hash",
        sym["hash"],
        "--body",
        body,
        "--test",
        test_command,
        "--json",
    ]
    if typecheck_command:
        argv += ["--typecheck", typecheck_command]
    t0 = time.perf_counter()
    out = run(argv, timeout=600)
    elapsed = (time.perf_counter() - t0) * 1000
    try:
        parsed = json.loads(out.stdout) if out.stdout.strip() else None
    except json.JSONDecodeError:
        parsed = None
    return {
        "elapsed_ms": elapsed,
        "returncode": out.returncode,
        "stdout_tail": out.stdout[-2000:],
        "stderr_tail": out.stderr[-2000:],
        "parsed": parsed,
    }


def restore(repo, rel):
    run(["git", "checkout", "--", rel], cwd=repo)


def measure_repo(repo, name, test_command, gate_only_command="cmd /c exit 0", typecheck_command=None):
    result = {"name": name, "path": repo}
    tree, js_files = measure_tree(repo)
    result["tree"] = tree
    result["parse"] = measure_skeleton_symbols(repo, js_files)

    rel, sym = pick_edit_target(repo, js_files)
    result["edit_target"] = {"file": rel, "symbol": sym.get("ref") if sym else None}
    if rel is None:
        result["try"] = {"error": "no editable function symbol found"}
        return result

    tracked = tracked_files(repo)
    result["shadow_copy_proxy_ms"] = shadow_copy_proxy(repo, tracked)

    trials = {}
    for label, cmd in (("real_test", test_command), ("gate_only", gate_only_command)):
        try:
            trials[label] = run_try(repo, rel, sym, cmd, typecheck_command)
        finally:
            restore(repo, rel)
    result["try"] = trials
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True, help="path to a git checkout")
    parser.add_argument("--name", required=True)
    parser.add_argument("--test", required=True, help="the repo's real test command")
    parser.add_argument("--typecheck", default=None)
    parser.add_argument("--out", default=None, help="write JSON result to this path")
    args = parser.parse_args()

    result = measure_repo(os.path.abspath(args.repo), args.name, args.test, typecheck_command=args.typecheck)
    text = json.dumps(result, indent=2)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(text)
    print(text)


if __name__ == "__main__":
    main()
