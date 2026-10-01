import argparse
import ctypes
import json
import os
import struct
import subprocess
import sys
import threading
import time

BENCH = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BENCH)
from n8n_profile import DEFAULT_EXE, DEFAULT_REPO, McpSession, first_json, percentile

TARGET = "packages/core/src"
MOVE_DIR = "packages/core/src/errors"
RUN = format(int(time.time()) % 100000, "05d")


def git(repo, *args, check=True):
    return subprocess.run(["git", *args], cwd=repo, capture_output=True, text=True, encoding="utf-8", errors="replace", check=check)


def tracked(repo, under, suffix=".ts"):
    out = subprocess.run(["git", "ls-files", "-z", "--", under], cwd=repo, capture_output=True, check=True).stdout
    return sorted(p for p in out.decode("utf-8").split("\0") if p and p.endswith(suffix))


def clean(repo):
    return git(repo, "status", "--porcelain").stdout.strip() == ""


class Result:
    def __init__(self, files, status, ms, extra, stats, body):
        self.files = files
        self.status = status
        self.ms = ms
        self.extra = extra
        self.stats = stats
        self.body = body


class Probe:
    def __init__(self, exe, repo):
        self.repo = repo
        self.session = McpSession(exe, repo)

    def search(self, pattern, where="."):
        text, is_error, ms = self.session.call("emetgate_search", {"pattern": pattern, "dir": where, "stats": True, "detail": "full"})
        body = first_json(text) or {}
        stats = body.get("stats", {})
        files = sorted({g["file"] for g in body.get("groups", [])})
        extra = stats.get("sync_ms", 0) + stats.get("list_ms", 0) + stats.get("index_refresh_ms", 0) + stats.get("warm_wait_ms", 0)
        status = body.get("status") or ("error" if is_error else "")
        return Result(files, status, ms, extra, stats, body)

    def close(self):
        self.session.close()


STAGES = ["sync_ms", "list_ms", "index_refresh_ms", "refresh_work_ms", "filter_ms", "match_ms", "parse_ms", "root_ms", "json_ms", "total_ms", "warm_wait_ms"]


class Tally:
    def __init__(self, name):
        self.name = name
        self.e2e = []
        self.extra = []
        self.misses = []
        self.notes = {}
        self.stages = {k: [] for k in STAGES}

    def add(self, result, ok, detail=None):
        self.e2e.append(result.ms)
        self.extra.append(result.extra)
        for k in STAGES:
            v = result.stats.get(k)
            if isinstance(v, (int, float)):
                self.stages[k].append(v)
        if not ok:
            self.misses.append(detail if detail is not None else {"files": result.files, "status": result.status})

    def row(self):
        def p(values, q):
            return round(percentile(values, q), 3) if values else None
        return {
            "scenario": self.name,
            "rounds": len(self.e2e),
            "extra_p50_ms": p(self.extra, 0.5),
            "extra_p99_ms": p(self.extra, 0.99),
            "e2e_p50_ms": p(self.e2e, 0.5),
            "e2e_p99_ms": p(self.e2e, 0.99),
            "misses": len(self.misses),
            "first_misses": self.misses[:3],
            "stage_p50_ms": {k: round(percentile(v, 0.5), 3) for k, v in self.stages.items() if v},
            "notes": self.notes,
        }


def token_line(token):
    return f"\n// {token}\n".encode()


def baseline(probe, rounds):
    tally = Tally("baseline: search with no write before it")
    for i in range(rounds):
        r = probe.search(f"absent_{RUN}_{i}_z")
        tally.add(r, r.files == [])
    return tally


def save(probe, repo, rounds, replace):
    files = tracked(repo, TARGET)[:20]
    originals = {f: open(os.path.join(repo, f), "rb").read() for f in files}
    name = "save by rename over the file" if replace else "save in place (write + close)"
    tally = Tally(name)
    stale = 0
    previous = None
    try:
        for i in range(rounds):
            f = files[i % len(files)]
            token = f"fresh_{RUN}_{'r' if replace else 'w'}{i}_q"
            path = os.path.join(repo, f)
            data = originals[f] + token_line(token)
            if replace:
                tmp = path + ".emetgate-save~"
                with open(tmp, "wb") as out:
                    out.write(data)
                os.replace(tmp, path)
            else:
                with open(path, "wb") as out:
                    out.write(data)
            r = probe.search(token)
            tally.add(r, r.files == [f], {"round": i, "file": f, "got": r.files, "status": r.status})
            if previous is not None and i % 10 == 0:
                old = probe.search(previous)
                if old.files:
                    stale += 1
            previous = token
    finally:
        for f, data in originals.items():
            with open(os.path.join(repo, f), "wb") as out:
                out.write(data)
    tally.notes["stale_old_token_hits"] = stale
    return tally


def create_delete(probe, repo, rounds):
    create = Tally("create a file and git add it")
    delete = Tally("git rm and delete the file")
    unadded = Tally("create a file without git add (outside the tracked scope)")
    git_ms = []
    for i in range(rounds):
        rel = f"{TARGET}/fresh_{RUN}_{i}.ts"
        path = os.path.join(repo, rel)
        token = f"created_{RUN}_{i}_q"
        with open(path, "wb") as out:
            out.write(f"export const created = '{token}';\n".encode())
        if i % 20 == 0:
            r = probe.search(token)
            unadded.add(r, r.files == [], {"round": i, "got": r.files})
        started = time.perf_counter()
        git(repo, "add", "--", rel)
        git_ms.append((time.perf_counter() - started) * 1000)
        r = probe.search(token)
        create.add(r, r.files == [rel], {"round": i, "got": r.files, "status": r.status})
        git(repo, "rm", "-q", "--cached", "--", rel)
        os.remove(path)
        r = probe.search(token)
        delete.add(r, r.files == [] and r.status == "complete", {"round": i, "got": r.files, "status": r.status})
    create.notes["git_add_p50_ms"] = round(percentile(git_ms, 0.5), 1)
    return [create, delete, unadded]


def delete_restore(probe, repo, rounds):
    files = tracked(repo, TARGET)[20:40]
    originals = {f: open(os.path.join(repo, f), "rb").read() for f in files}
    gone = Tally("delete a tracked file from disk")
    back = Tally("put the deleted file back")
    try:
        for i in range(rounds):
            f = files[i % len(files)]
            token = f"deleted_{RUN}_{i}_q"
            path = os.path.join(repo, f)
            with open(path, "wb") as out:
                out.write(originals[f] + token_line(token))
            probe.search(token)
            os.remove(path)
            r = probe.search(token)
            missing = [m.get("path") for m in r.body.get("missing", []) if m.get("reason") == "vanished"]
            gone.add(r, r.files == [] and r.status == "partial" and missing == [f], {"round": i, "got": r.files, "status": r.status, "missing": missing})
            with open(path, "wb") as out:
                out.write(originals[f] + token_line(token))
            r = probe.search(token)
            back.add(r, r.files == [f] and r.status == "complete", {"round": i, "got": r.files, "status": r.status})
    finally:
        for f, data in originals.items():
            with open(os.path.join(repo, f), "wb") as out:
                out.write(data)
    return [gone, back]


def rename(probe, repo, rounds):
    files = tracked(repo, TARGET)[40:60]
    originals = {f: open(os.path.join(repo, f), "rb").read() for f in files}
    moved = Tally("git mv a tracked file")
    plain = Tally("rename a tracked file without git (old path vanished, new path untracked)")
    try:
        for i in range(rounds):
            f = files[i % len(files)]
            token = f"renamed_{RUN}_{i}_q"
            path = os.path.join(repo, f)
            with open(path, "wb") as out:
                out.write(originals[f] + token_line(token))
            git(repo, "add", "--", f)
            probe.search(token)
            target = f[:-3] + f"_moved{RUN}.ts"
            git(repo, "mv", "--", f, target)
            r = probe.search(token)
            moved.add(r, r.files == [target], {"round": i, "got": r.files, "status": r.status})
            git(repo, "mv", "--", target, f)
            if i % 10 == 0:
                os.rename(path, os.path.join(repo, target))
                r = probe.search(token)
                missing = [m.get("path") for m in r.body.get("missing", [])]
                plain.add(r, r.files == [] and r.status == "partial" and missing == [f], {"round": i, "got": r.files, "status": r.status, "missing": missing})
                os.rename(os.path.join(repo, target), path)
            git(repo, "reset", "-q", "--", f)
            with open(path, "wb") as out:
                out.write(originals[f])
    finally:
        for f, data in originals.items():
            with open(os.path.join(repo, f), "wb") as out:
                out.write(data)
        git(repo, "reset", "-q", "--", *files, check=False)
    return [moved, plain]


def dir_move(probe, repo, rounds):
    files = tracked(repo, MOVE_DIR, "")
    target_dir = MOVE_DIR + f"_moved{RUN}"
    tally = Tally(f"git mv a directory of {len(files)} tracked files")
    probe_file = next(f for f in files if b"export" in open(os.path.join(repo, f), "rb").read())
    try:
        for i in range(rounds):
            r_before = probe.search("export", probe_file)
            git(repo, "mv", "--", MOVE_DIR, target_dir)
            moved_file = target_dir + probe_file[len(MOVE_DIR):]
            r = probe.search("export", target_dir)
            expected = sorted(f.replace(MOVE_DIR, target_dir, 1) for f in {g for g in r_before.files})
            ok = moved_file in r.files and all(not x.startswith(MOVE_DIR + "/") for x in r.files)
            tally.add(r, ok and r.status in ("complete", "partial"), {"round": i, "got": r.files[:3], "status": r.status, "expected": expected[:3]})
            git(repo, "mv", "--", target_dir, MOVE_DIR)
            back = probe.search("export", MOVE_DIR)
            if probe_file not in back.files:
                tally.misses.append({"round": i, "back": back.files[:3]})
    finally:
        if os.path.exists(os.path.join(repo, target_dir)):
            git(repo, "mv", "--", target_dir, MOVE_DIR, check=False)
    return tally


def pick_commit(repo, want):
    depth = 1
    best = None
    while depth < 4096:
        out = git(repo, "diff", "--name-only", f"HEAD~{depth}", "HEAD").stdout.split()
        best = (depth, len(out))
        if len(out) >= want:
            break
        depth *= 2
    lo, hi = max(1, depth // 2), depth
    while lo < hi:
        mid = (lo + hi) // 2
        n = len(git(repo, "diff", "--name-only", f"HEAD~{mid}", "HEAD").stdout.split())
        if n >= want:
            hi = mid
        else:
            lo = mid + 1
    rev = git(repo, "rev-parse", f"HEAD~{lo}").stdout.strip()
    n = len(git(repo, "diff", "--name-only", rev, "HEAD").stdout.split())
    return rev, n


def added_tokens(repo, older, newer, count=4):
    diff = git(repo, "diff", "-U0", older, newer, "--", "*.ts").stdout.splitlines()
    tokens = []
    for line in diff:
        if line.startswith("+") and not line.startswith("+++"):
            for word in line[1:].replace("(", " ").replace(")", " ").replace(".", " ").replace(",", " ").split():
                if len(word) >= 14 and word.isidentifier() and word not in tokens:
                    tokens.append(word)
        if len(tokens) >= count * 6:
            break
    return tokens[::6][:count] or tokens[:count]


def git_grep_files(repo, pattern):
    out = subprocess.run(["git", "grep", "-l", "-I", "-F", "-e", pattern], cwd=repo, capture_output=True, text=True, encoding="utf-8", errors="replace")
    return sorted(f for f in out.stdout.split() if os.path.getsize(os.path.join(repo, f)) <= 1024 * 1024)


def checkout(probe, repo, rounds, want):
    head = git(repo, "rev-parse", "HEAD").stdout.strip()
    branch = git(repo, "rev-parse", "--abbrev-ref", "HEAD").stdout.strip()
    older, changed = pick_commit(repo, want)
    tokens = added_tokens(repo, older, head)
    tally = Tally(f"git checkout of {changed} changed files, first search")
    checks = 0
    try:
        for i in range(rounds):
            for rev in (older, branch if branch != "HEAD" else head):
                git(repo, "checkout", "-q", rev)
                token = tokens[i % len(tokens)] if tokens else "export"
                r = probe.search(token)
                truncated = r.body.get("truncated", False)
                want_files = git_grep_files(repo, token)
                ok = truncated or r.files == want_files
                checks += 0 if truncated else 1
                tally.add(r, ok, {"round": i, "rev": rev[:10], "token": token, "got": r.files[:5], "want": want_files[:5]})
    finally:
        git(repo, "checkout", "-q", branch if branch != "HEAD" else head, check=False)
    tally.notes["compared_with_git_grep"] = checks
    tally.notes["changed_files"] = changed
    return tally


def offline(exe, repo, rounds, count, delay):
    files = tracked(repo, "packages")[:count]
    originals = {f: open(os.path.join(repo, f), "rb").read() for f in files}
    tally = Tally(f"{count} files changed while no server ran, first search {'after a ' + str(delay) + ' s pause' if delay else 'right after initialize'}")
    init_ms = []
    warm_wait = []
    warmup = []
    try:
        Probe(exe, repo).close()
        for i in range(rounds):
            token = f"offline_{RUN}_{i}_q"
            for f in files:
                with open(os.path.join(repo, f), "wb") as out:
                    out.write(originals[f] + token_line(token))
            probe = Probe(exe, repo)
            init_ms.append(probe.session.initialize_ms)
            if delay:
                time.sleep(delay)
            r = probe.search(token)
            warm_wait.append(r.stats.get("warm_wait_ms", 0))
            warmup.append(r.stats.get("warmup_ms", 0))
            tally.add(r, r.files == sorted(files), {"round": i, "got": len(r.files), "status": r.status})
            probe.close()
    finally:
        for f, data in originals.items():
            with open(os.path.join(repo, f), "wb") as out:
                out.write(data)
    tally.notes["initialize_p50_ms"] = round(percentile(init_ms, 0.5), 1)
    tally.notes["warm_wait_p50_ms"] = round(percentile(warm_wait, 0.5), 1)
    tally.notes["warmup_p50_ms"] = round(percentile(warmup, 0.5), 1)
    tally.notes["warmup_p99_ms"] = round(percentile(warmup, 0.99), 1)
    return tally


def parallel(probe, repo, rounds):
    files = tracked(repo, TARGET)[60:80]
    noise = tracked(repo, TARGET)[80:100]
    originals = {f: open(os.path.join(repo, f), "rb").read() for f in files + noise}
    stop = threading.Event()
    writes = [0]

    def churn():
        j = 0
        while not stop.is_set():
            f = noise[j % len(noise)]
            with open(os.path.join(repo, f), "wb") as out:
                out.write(originals[f] + token_line(f"noise_{RUN}_{j}"))
            writes[0] += 1
            j += 1

    tally = Tally("save in place while another thread rewrites other tracked files")
    worker = threading.Thread(target=churn, daemon=True)
    worker.start()
    try:
        for i in range(rounds):
            f = files[i % len(files)]
            token = f"parallel_{RUN}_{i}_q"
            with open(os.path.join(repo, f), "wb") as out:
                out.write(originals[f] + token_line(token))
            r = probe.search(token)
            tally.add(r, r.files == [f], {"round": i, "got": r.files, "status": r.status})
    finally:
        stop.set()
        worker.join()
        for f, data in originals.items():
            with open(os.path.join(repo, f), "wb") as out:
                out.write(data)
    tally.notes["background_writes"] = writes[0]
    return tally


if os.name == "nt":
    from ctypes import wintypes as wt

    _k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    _k32.CreateFileW.argtypes = [wt.LPCWSTR, wt.DWORD, wt.DWORD, wt.LPVOID, wt.DWORD, wt.DWORD, wt.HANDLE]
    _k32.CreateFileW.restype = wt.HANDLE
    _k32.ReadDirectoryChangesW.argtypes = [wt.HANDLE, wt.LPVOID, wt.DWORD, wt.BOOL, wt.DWORD, ctypes.POINTER(wt.DWORD), wt.LPVOID, wt.LPVOID]
    _k32.ReadDirectoryChangesW.restype = wt.BOOL

NOTIFY_FILTER = 0x1 | 0x2 | 0x4 | 0x8 | 0x10 | 0x40 | 0x100


class RawWatcher(threading.Thread):
    def __init__(self, root):
        super().__init__(daemon=True)
        self.handle = _k32.CreateFileW(root, 0x1, 0x7, None, 3, 0x02000000, None)
        self.events = []
        self.lock = threading.Lock()

    def run(self):
        buf = ctypes.create_string_buffer(1 << 16)
        got = wt.DWORD()
        while True:
            if not _k32.ReadDirectoryChangesW(self.handle, buf, len(buf), True, NOTIFY_FILTER, ctypes.byref(got), None, None):
                return
            now = time.perf_counter()
            raw = buf.raw[:got.value]
            off = 0
            while got.value:
                nxt, action, length = struct.unpack_from("<III", raw, off)
                name = raw[off + 12: off + 12 + length].decode("utf-16-le").replace("\\", "/")
                with self.lock:
                    self.events.append((now, action, name))
                if nxt == 0:
                    break
                off += nxt

    def since(self, mark, name):
        with self.lock:
            return [(t, a) for t, a, n in self.events[mark:] if n == name]

    def mark(self):
        with self.lock:
            return len(self.events)


def first_after(events, t0):
    later = [t for t, _ in events if t >= t0]
    return round((later[0] - t0) * 1000, 2) if later else None


def open_handle(probe, repo, rounds, mode):
    files = tracked(repo, TARGET)[100:120]
    originals = {f: open(os.path.join(repo, f), "rb").read() for f in files}
    watcher = RawWatcher(repo)
    watcher.start()
    time.sleep(0.2)
    seen = {"after_write": 0, "after_write_250ms": 0, "after_flush": 0, "after_close": 0}
    events = {"write": [], "flush": [], "close": []}
    dir_entry_size_moved = 0
    live_size_moved = 0
    tally = Tally(f"writer keeps its handle open ({mode}), search after close")
    try:
        for i in range(rounds):
            f = files[i % len(files)]
            path = os.path.join(repo, f)
            token = f"open_{RUN}_{mode[0]}{i}_q"
            line = token_line(token)
            before_entry = next(e for e in os.scandir(os.path.dirname(path)) if e.name == os.path.basename(path)).stat().st_size
            fh = open(path, "r+b", buffering=0)
            mark = watcher.mark()
            if mode == "append":
                fh.seek(0, 2)
                payload = line
            else:
                payload = (f"/* {token} */").encode()
                fh.seek(0)
            t_write = time.perf_counter()
            fh.write(payload)
            r = probe.search(token)
            seen["after_write"] += r.files == [f]
            time.sleep(0.25)
            r = probe.search(token)
            seen["after_write_250ms"] += r.files == [f]
            entry = next(e for e in os.scandir(os.path.dirname(path)) if e.name == os.path.basename(path)).stat().st_size
            dir_entry_size_moved += entry != before_entry
            live_size_moved += os.stat(path).st_size != before_entry
            events["write"].append(first_after(watcher.since(mark, f), t_write))
            t_flush = time.perf_counter()
            os.fsync(fh.fileno())
            time.sleep(0.05)
            r = probe.search(token)
            seen["after_flush"] += r.files == [f]
            events["flush"].append(first_after(watcher.since(mark, f), t_flush))
            t_close = time.perf_counter()
            fh.close()
            r = probe.search(token)
            seen["after_close"] += r.files == [f]
            tally.add(r, r.files == [f], {"round": i, "got": r.files, "status": r.status})
            time.sleep(0.05)
            events["close"].append(first_after(watcher.since(mark, f), t_close))
            with open(path, "wb") as out:
                out.write(originals[f])
            probe.search(token)
    finally:
        for f, data in originals.items():
            with open(os.path.join(repo, f), "wb") as out:
                out.write(data)

    def summary(values):
        got = [v for v in values if v is not None]
        return {"events": len(got), "of": len(values), "p50_ms": round(percentile(got, 0.5), 2) if got else None}

    tally.notes["found"] = seen
    tally.notes["notification_after_write"] = summary(events["write"])
    tally.notes["notification_after_flush"] = summary(events["flush"])
    tally.notes["notification_after_close"] = summary(events["close"])
    tally.notes["directory_entry_size_moved_before_close"] = dir_entry_size_moved
    tally.notes["live_size_moved_before_close"] = live_size_moved
    return tally


SCENARIOS = ["baseline", "save", "replace", "create", "delete", "rename", "dirmove", "checkout50", "checkout500", "offline", "offline_delay", "parallel", "open_append", "open_overwrite"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", default=DEFAULT_EXE)
    ap.add_argument("--repo", default=DEFAULT_REPO)
    ap.add_argument("--rounds", type=int, default=200)
    ap.add_argument("--checkout-rounds", type=int, default=20)
    ap.add_argument("--offline-rounds", type=int, default=30)
    ap.add_argument("--open-rounds", type=int, default=40)
    ap.add_argument("--only", nargs="*", default=SCENARIOS)
    ap.add_argument("--json")
    args = ap.parse_args()
    repo = os.path.abspath(args.repo)
    if not clean(repo):
        sys.exit(f"{repo} has local changes; refusing to run")
    rows = []
    probe = Probe(args.exe, repo)
    try:
        probe.search("warmup_token_absent")
        for name in args.only:
            started = time.perf_counter()
            if name == "baseline":
                out = [baseline(probe, args.rounds)]
            elif name == "save":
                out = [save(probe, repo, args.rounds, False)]
            elif name == "replace":
                out = [save(probe, repo, args.rounds, True)]
            elif name == "create":
                out = create_delete(probe, repo, args.rounds)
            elif name == "delete":
                out = delete_restore(probe, repo, args.rounds)
            elif name == "rename":
                out = rename(probe, repo, args.rounds)
            elif name == "dirmove":
                out = [dir_move(probe, repo, max(1, args.rounds // 4))]
            elif name == "checkout50":
                out = [checkout(probe, repo, args.checkout_rounds, 50)]
            elif name == "checkout500":
                out = [checkout(probe, repo, args.checkout_rounds, 500)]
            elif name == "offline":
                probe.close()
                out = [offline(args.exe, repo, args.offline_rounds, 100, 0)]
                probe = Probe(args.exe, repo)
                probe.search("warmup_token_absent")
            elif name == "offline_delay":
                probe.close()
                out = [offline(args.exe, repo, args.offline_rounds, 100, 3)]
                probe = Probe(args.exe, repo)
                probe.search("warmup_token_absent")
            elif name == "parallel":
                out = [parallel(probe, repo, args.rounds)]
            elif name == "open_append":
                out = [open_handle(probe, repo, args.open_rounds, "append")]
            elif name == "open_overwrite":
                out = [open_handle(probe, repo, args.open_rounds, "overwrite")]
            else:
                sys.exit(f"unknown scenario {name}")
            for t in out:
                row = t.row()
                row["wall_s"] = round(time.perf_counter() - started, 1)
                rows.append(row)
                print(json.dumps(row, ensure_ascii=False), flush=True)
    finally:
        probe.close()
    if not clean(repo):
        print("WARNING: the repository is not clean after the run", file=sys.stderr)
        print(git(repo, "status", "--porcelain").stdout[:2000], file=sys.stderr)
    print()
    print("| scenario | rounds | extra p50 ms | extra p99 ms | e2e p50 ms | e2e p99 ms | misses |")
    print("|---|---:|---:|---:|---:|---:|---:|")
    for r in rows:
        print(f"| {r['scenario']} | {r['rounds']} | {r['extra_p50_ms']} | {r['extra_p99_ms']} | {r['e2e_p50_ms']} | {r['e2e_p99_ms']} | {r['misses']} |")
    if args.json:
        with open(args.json, "w", encoding="utf-8") as out:
            json.dump(rows, out, indent=2, ensure_ascii=False)


if __name__ == "__main__":
    main()
