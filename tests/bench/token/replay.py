import argparse
import concurrent.futures
import glob
import json
import os
import queue
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time

CHARS_PER_TOKEN_CODE = 3.2
CHARS_PER_TOKEN_PROSE = 3.8
COVER_THRESHOLD = 0.9
MIN_LINE_CHARS = 6
CALL_TIMEOUT_S = 60
PRICE_CACHE_READ = 0.1
PRICE_CACHE_WRITE = 2.0
PRICE_OUTPUT = 5.0
MODEL_PRICES = (("fable", 15.0), ("opus", 5.0), ("sonnet", 3.0), ("haiku", 1.0))
DEFAULT_PRICE = 5.0
PREFIX = "mcp__emetgate__"
READ_ONLY = {
    "emetgate_skeleton", "emetgate_read_symbol", "emetgate_read_file", "emetgate_search",
    "emetgate_explore", "emetgate_find", "emetgate_evidence", "emetgate_git",
    "emetgate_symbols", "emetgate_list",
}
FILE_TOOLS = {"emetgate_skeleton", "emetgate_read_symbol", "emetgate_read_file", "emetgate_symbols"}
WRITE_HINT = re.compile(r"(emetgate_(try|edit|write|mutate|rename|move|commit|git_write|run)|^(Edit|Write|MultiEdit|NotebookEdit|Bash|PowerShell)$)")
DEFAULT_EXE = r"C:\Users\ugur\Desktop\projects\emetgate\wt-bench\zig-out\bin\emetgate.exe"
FORBIDDEN_ROOTS = (r"C:\Users\ugur\Desktop\APRYCO",)
CODE_CHARS = set("{}();=<>[]")



SERVER_ARGS: list = []  # extra arguments for `emetgate mcp`, set from --server-arg

def est_tokens(text):
    if not text:
        return 0.0
    stripped = text.lstrip()
    if stripped[:1] in "{[":
        return len(text) / CHARS_PER_TOKEN_PROSE
    code = sum(1 for ch in text if ch in CODE_CHARS)
    return len(text) / (CHARS_PER_TOKEN_CODE if code / len(text) > 0.02 else CHARS_PER_TOKEN_PROSE)


def model_price(model):
    m = (model or "").lower()
    for key, price in MODEL_PRICES:
        if key in m:
            return price
    return DEFAULT_PRICE


def result_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(x.get("text", "") for x in content if isinstance(x, dict) and x.get("type") == "text")
    return ""


def load_session(path):
    calls = []
    by_msg = {}
    tools = {}
    order = []
    cwd = None
    first_ts = None
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if not isinstance(d, dict):
                continue
            cwd = cwd or d.get("cwd")
            first_ts = first_ts or d.get("timestamp")
            m = d.get("message")
            if not isinstance(m, dict):
                continue
            content = m.get("content") if isinstance(m.get("content"), list) else []
            if d.get("type") == "assistant":
                mid = m.get("id") or d.get("uuid")
                if m.get("model") == "<synthetic>":
                    continue
                call = by_msg.get(mid)
                if call is None:
                    call = {"id": mid, "model": m.get("model"), "usage": {}, "tools": [], "ts": d.get("timestamp")}
                    by_msg[mid] = call
                    calls.append(call)
                if isinstance(m.get("usage"), dict):
                    call["usage"] = m["usage"]
                for b in content:
                    if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("id") not in tools:
                        tools[b["id"]] = {"id": b["id"], "name": b.get("name", ""), "input": b.get("input") or {}, "call": len(calls) - 1, "result": None, "error": False}
                        call["tools"].append(b["id"])
                        order.append(b["id"])
            elif d.get("type") == "user":
                for b in content:
                    if isinstance(b, dict) and b.get("type") == "tool_result" and b.get("tool_use_id") in tools:
                        t = tools[b["tool_use_id"]]
                        t["result"] = result_text(b.get("content"))
                        t["error"] = bool(b.get("is_error"))
    return {"path": path, "cwd": cwd, "first_ts": first_ts, "calls": calls, "tools": tools, "order": order}


def git(args, cwd, check=True):
    env = dict(os.environ, GIT_LFS_SKIP_SMUDGE="1", GIT_TERMINAL_PROMPT="0")
    p = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, encoding="utf-8", errors="replace", env=env)
    if check and p.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)}: {p.stderr.strip()}")
    return p


def inside(path, root):
    try:
        a = os.path.normcase(os.path.abspath(path))
        b = os.path.normcase(os.path.abspath(root))
        return os.path.commonpath([a, b]) == b
    except ValueError:
        return False


def forbidden(path):
    return any(inside(path, r) for r in FORBIDDEN_ROOTS)


def qualify(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            if '"name":"' + PREFIX not in f.read():
                return None, "no emetgate call"
    except OSError:
        return None, "unreadable"
    s = load_session(path)
    names = [s["tools"][t]["name"] for t in s["order"]]
    if not any(n.startswith(PREFIX) and n[len(PREFIX):] in READ_ONLY for n in names):
        return None, "no read-only emetgate call"
    cwd = s["cwd"]
    if not cwd or forbidden(cwd):
        return None, "read-only folder" if cwd else "no cwd"
    if not os.path.isdir(cwd):
        return None, "repo missing"
    top = git(["rev-parse", "--show-toplevel"], cwd, check=False)
    if top.returncode != 0:
        return None, "not git"
    top = os.path.normpath(top.stdout.strip())
    if forbidden(top):
        return None, "read-only folder"
    s["repo"] = top
    s["subdir"] = os.path.relpath(os.path.normpath(cwd), top)
    return s, None


class Server:
    def __init__(self, exe, cwd):
        self.proc = subprocess.Popen([exe, "mcp", *SERVER_ARGS], cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.lines = queue.Queue()
        threading.Thread(target=self._pump, daemon=True).start()
        self.next_id = 0
        self.send("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "replay", "version": "0"}})
        self.proc.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
        self.proc.stdin.flush()

    def _pump(self):
        for line in self.proc.stdout:
            self.lines.put(line)
        self.lines.put(None)

    def send(self, method, params):
        self.next_id += 1
        msg = {"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params}
        self.proc.stdin.write((json.dumps(msg) + "\n").encode("utf-8"))
        self.proc.stdin.flush()
        deadline = time.monotonic() + CALL_TIMEOUT_S
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                raise TimeoutError(method)
            line = self.lines.get(timeout=left)
            if line is None:
                raise RuntimeError("server exited")
            reply = json.loads(line.decode("utf-8", errors="replace"))
            if reply.get("id") == self.next_id:
                return reply

    def call(self, name, arguments):
        reply = self.send("tools/call", {"name": name, "arguments": arguments})
        result = reply.get("result") or {}
        text = "\n".join(c.get("text", "") for c in result.get("content") or [] if isinstance(c, dict))
        return text, bool(result.get("isError")) or "error" in reply

    def close(self):
        try:
            self.proc.stdin.close()
            self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()
            self.proc.wait(timeout=5)


HEX = re.compile(r"^[0-9a-f]{16,64}$")
PREFIXES = (re.compile(r"^\|\d+\s+"), re.compile(r"^\*?\d+(?::|\s)\s*"), re.compile(r"^[+\- ](?=\S)"))
PATHLIKE = re.compile(r"^[\w.@~-]*(?:[/\\][\w.@~-]+)+(?::\d+)?(?:\s+[\w.]+)?$|^[\w@~-]+\.\w{1,6}(?::\d+)?(?:\s+[\w.]+)?$")
WS = re.compile(r"\s+")


def leaf_strings(value, out):
    if isinstance(value, str):
        if not HEX.match(value):
            out.extend(value.split("\n"))
    elif isinstance(value, dict):
        for v in value.values():
            leaf_strings(v, out)
    elif isinstance(value, list):
        for v in value:
            leaf_strings(v, out)


def raw_lines(text):
    out = []
    for line in (text or "").split("\n"):
        s = line.strip()
        if s.startswith("{") and s.endswith("}"):
            try:
                leaf_strings(json.loads(s), out)
                continue
            except ValueError:
                pass
        out.append(line)
    return out


def norm(line):
    s = line.strip()
    for p in PREFIXES[:2]:
        s = p.sub("", s, count=1)
    return WS.sub(" ", s).strip()


def trivial(s):
    return len(s) < MIN_LINE_CHARS or not any(ch.isalnum() for ch in s) or s.startswith(("emetgate \u2713", "emetgate \u2717", "--- ", "\u2713", "next offset"))


def content_lines(text):
    keep, paths = [], []
    for line in raw_lines(text):
        s = norm(line)
        if trivial(s):
            continue
        (paths if PATHLIKE.match(s) else keep).append(s)
    return keep or paths


def pool_lines(text):
    out = set()
    for line in raw_lines(text):
        s = norm(line)
        if s:
            out.add(s)
    return out


def canon_path(p, cwd):
    p = str(p or "").replace("\\", "/")
    c = (cwd or "").replace("\\", "/").rstrip("/") + "/"
    if p.lower().startswith(c.lower()):
        p = p[len(c):]
    if p.startswith("./"):
        p = p[2:]
    return p.lower()


def files_of(tool, cwd):
    inp = tool["input"]
    fs = []
    if isinstance(inp.get("file"), str):
        fs.append(inp["file"])
    if isinstance(inp.get("files"), list):
        fs.extend(x if isinstance(x, str) else (x or {}).get("file", "") for x in inp["files"])
    if isinstance(inp.get("path"), str):
        fs.append(inp["path"])
    return [canon_path(f, cwd) for f in fs if f]


def read_key(tool, cwd):
    inp = {k: v for k, v in tool["input"].items() if k not in ("force",)}
    for k in ("file", "path"):
        if isinstance(inp.get(k), str):
            inp[k] = canon_path(inp[k], cwd)
    return tool["name"] + json.dumps(inp, sort_keys=True)


def changed_between(session, a, b, files):
    tools = session["tools"]
    order = session["order"]
    for tid in order[a + 1:b]:
        t = tools[tid]
        name = t["name"][len(PREFIX):] if t["name"].startswith(PREFIX) else t["name"]
        if name in READ_ONLY or not WRITE_HINT.search(name):
            continue
        if not files:
            return True
        blob = json.dumps(t["input"]).replace("\\\\", "/").lower()
        if any(f and (f in blob or os.path.basename(f) in blob) for f in files):
            return True
    return False


def analyse(session, replies):
    tools = session["tools"]
    order = session["order"]
    cwd = session["cwd"]
    lookups = [k for k, tid in enumerate(order) if tid in replies]
    out = {}
    pools = {"new": [], "rec": []}
    unions = {"new": set(), "rec": set()}
    seen_keys = {}
    for k in lookups:
        tid = order[k]
        t = tools[tid]
        rec = t["result"] or ""
        lines = content_lines(rec) if not t["error"] and "emetgate \u2717" not in rec else []
        entry = {"reread": False, "new": None, "rec": None, "lines": len(lines), "frac_new": None, "frac_rec": None}
        key = read_key(t, cwd)
        if key in seen_keys and not changed_between(session, seen_keys[key], k, files_of(t, cwd) if t["name"][len(PREFIX):] in FILE_TOOLS else []):
            entry["reread"] = True
        for side in ("new", "rec"):
            union = unions[side]
            if lines:
                frac = sum(1 for ln in lines if ln in union) / len(lines)
                entry["frac_" + side] = round(frac, 3)
                if frac >= COVER_THRESHOLD:
                    best, best_hits = None, 0
                    for src_k, plines in pools[side]:
                        hits = sum(1 for ln in lines if ln in plines)
                        if hits > best_hits:
                            best, best_hits = src_k, hits
                    entry[side] = {"by": best, "frac": round(frac, 3), "lines": len(lines)}
        out[k] = entry
        seen_keys.setdefault(key, k)
        for side, text in (("new", replies[tid]["text"]), ("rec", rec)):
            plines = pool_lines(text)
            pools[side].append((k, plines))
            unions[side] |= plines
    return out, lookups


def score(session, replies, coverage):
    order = session["order"]
    calls = session["calls"]
    pos = {tid: k for k, tid in enumerate(order)}
    res = {"saved": {}, "saved_rec": {}}
    for side, key in (("new", "saved"), ("rec", "saved_rec")):
        for ci, call in enumerate(calls):
            if not call["tools"]:
                continue
            ok = True
            for tid in call["tools"]:
                c = coverage.get(pos[tid])
                if not c or not (c["reread"] or c[side]):
                    ok = False
                    break
            if ok:
                u = call["usage"]
                units = u.get("cache_read_input_tokens", 0) * PRICE_CACHE_READ + u.get("cache_creation_input_tokens", 0) * PRICE_CACHE_WRITE + u.get("output_tokens", 0) * PRICE_OUTPUT
                res[key][ci] = {"units": units, "usd": units * model_price(call["model"]) / 1e6}
    return res


class Skip(Exception):
    pass


def named_paths(session):
    out = []
    for tid in session["order"]:
        t = session["tools"][tid]
        if not t["name"].startswith(PREFIX) or t["name"][len(PREFIX):] not in READ_ONLY:
            continue
        inp = t["input"]
        for k in ("file", "path", "dir"):
            if isinstance(inp.get(k), str) and inp[k] not in ("", "."):
                out.append(inp[k])
        if isinstance(inp.get("files"), list):
            out.extend(x for x in inp["files"] if isinstance(x, str))
    return out


def present_share(session, commit):
    named = named_paths(session)
    if not named:
        return 1.0
    listed = git(["ls-tree", "-r", "--name-only", commit], session["repo"]).stdout.lower().splitlines()
    files = set(listed)
    dirs = set()
    for f in listed:
        parts = f.split("/")
        for i in range(1, len(parts)):
            dirs.add("/".join(parts[:i]))
    sub = "" if session["subdir"] == "." else session["subdir"].replace("\\", "/").lower() + "/"
    hits = 0
    for n in named:
        rel = sub + canon_path(n, session["cwd"]).rstrip("/")
        hits += rel in files or rel in dirs
    return hits / len(named)


def pick_commit(session, ts):
    repo = session["repo"]
    head = git(["rev-list", "-1", f"--before={ts}", "HEAD"], repo, check=False).stdout.strip()
    if head and present_share(session, head) >= 0.5:
        session["commit_from"] = "HEAD"
        return head
    refs = git(["for-each-ref", "--sort=-committerdate", "--count=40", "--format=%(refname)", "refs/heads", "refs/remotes"], repo, check=False).stdout.split()
    best, best_share = head, present_share(session, head) if head else -1.0
    seen = {head}
    for ref in refs:
        c = git(["rev-list", "-1", f"--before={ts}", ref], repo, check=False).stdout.strip()
        if not c or c in seen:
            continue
        seen.add(c)
        share = present_share(session, c)
        if share > best_share:
            best, best_share = c, share
            session["commit_from"] = ref
        if share >= 0.9:
            break
    return best


def make_worktree(session, scratch, idx, locks, hooks_dir):
    repo = session["repo"]
    ts = session["first_ts"]
    commit = pick_commit(session, ts)
    if not commit:
        raise Skip("no commit before session start")
    if present_share(session, commit) < 0.5:
        raise Skip("read files not tracked at that commit")
    path = os.path.join(scratch, "wt", f"s{idx:04d}")
    if not inside(path, scratch) or forbidden(path):
        raise RuntimeError("worktree path outside scratch")
    if os.path.exists(path):
        raise RuntimeError("worktree path exists")
    with locks.setdefault(os.path.normcase(repo), threading.Lock()):
        git(["-c", f"core.hooksPath={hooks_dir}", "-c", "core.longpaths=true", "worktree", "add", "--detach", path, commit], repo)
    return path, commit


def remove_worktree(repo, path, scratch, locks):
    if not inside(path, scratch) or os.path.normcase(os.path.abspath(path)) == os.path.normcase(os.path.abspath(scratch)):
        return "refused: outside scratch"
    admin = None
    dotgit = os.path.join(path, ".git")
    if os.path.isfile(dotgit):
        with open(dotgit, encoding="utf-8") as f:
            line = f.read().strip()
        if line.startswith("gitdir:"):
            admin = os.path.normpath(line[7:].strip())
    with locks.setdefault(os.path.normcase(repo), threading.Lock()):
        for _ in range(3):
            if git(["-c", "core.longpaths=true", "worktree", "remove", "--force", path], repo, check=False).returncode == 0 or not os.path.exists(path):
                break
            time.sleep(0.5)
    if os.path.exists(path):
        shutil.rmtree(path, ignore_errors=True)
    if admin and os.path.isdir(admin):
        common = os.path.normpath(git(["rev-parse", "--git-common-dir"], repo).stdout.strip())
        if not os.path.isabs(common):
            common = os.path.normpath(os.path.join(repo, common))
        if inside(admin, os.path.join(common, "worktrees")) and os.path.basename(admin).startswith(os.path.basename(path)):
            shutil.rmtree(admin, ignore_errors=True)
    return "left" if os.path.exists(path) else "removed"


def replay_session(session, exe, scratch, idx, locks, hooks_dir):
    started = time.monotonic()
    path, commit = make_worktree(session, scratch, idx, locks, hooks_dir)
    session["worktree"] = path
    replies = {}
    errors = []
    try:
        root = os.path.normpath(os.path.join(path, session["subdir"])) if session["subdir"] != "." else path
        server = Server(exe, root if os.path.isdir(root) else path)
        try:
            for tid in session["order"]:
                t = session["tools"][tid]
                if not t["name"].startswith(PREFIX):
                    continue
                name = t["name"][len(PREFIX):]
                if name not in READ_ONLY or t["result"] is None:
                    continue
                try:
                    text, err = server.call(name, t["input"])
                except Exception as e:
                    errors.append(f"{name}: {type(e).__name__}")
                    if isinstance(e, (TimeoutError, RuntimeError)):
                        break
                    continue
                replies[tid] = {"text": text, "error": err}
        finally:
            server.close()
    finally:
        session["cleanup"] = remove_worktree(session["repo"], path, scratch, locks)
    return build_report(session, replies, commit, errors, time.monotonic() - started)


def build_report(session, replies, commit, errors, seconds):
    coverage, lookups = analyse(session, replies)
    sc = score(session, replies, coverage)
    tools = session["tools"]
    order = session["order"]
    calls = session["calls"]
    added_tokens = 0.0
    added_units = 0.0
    added_usd = 0.0
    per_call = []
    for k in lookups:
        tid = order[k]
        t = tools[tid]
        new_t = est_tokens(replies[tid]["text"])
        rec_t = est_tokens(t["result"] or "")
        delta = new_t - rec_t
        remaining = len(calls) - 1 - t["call"]
        units = delta * (PRICE_CACHE_WRITE + PRICE_CACHE_READ * remaining)
        added_tokens += delta
        added_units += units
        added_usd += units * model_price(calls[t["call"]]["model"]) / 1e6
        c = coverage[k]
        per_call.append({"k": k, "tool": t["name"][len(PREFIX):], "call": t["call"], "rec_chars": len(t["result"] or ""), "new_chars": len(replies[tid]["text"]), "delta_tokens": round(delta, 1), "lines": c["lines"], "frac_new": c["frac_new"], "reread": c["reread"], "covered_new": c["new"], "covered_rec": c["rec"]})
    saved = sc["saved"]
    lookahead = {ci: v for ci, v in saved.items() if ci not in sc["saved_rec"]}
    credit = {}
    pos = {tid: k for k, tid in enumerate(order)}
    for ci in saved:
        for tid in calls[ci]["tools"]:
            c = coverage[pos[tid]]
            src = c["new"]["by"] if c["new"] else None
            if src is not None:
                credit.setdefault(src, {"turns": set(), "usd": 0.0})
                if ci not in credit[src]["turns"]:
                    credit[src]["turns"].add(ci)
                    credit[src]["usd"] += saved[ci]["usd"]
    top = []
    for src, v in credit.items():
        t = tools[order[src]]
        top.append({"session": session["path"], "k": src, "tool": t["name"][len(PREFIX):], "args": sorted(t["input"].keys()), "saved_turns": len(v["turns"]), "saved_usd": round(v["usd"], 4)})
    saved_usd = sum(v["usd"] for v in saved.values())
    return {
        "session": session["path"],
        "repo_name": os.path.basename(session["repo"]),
        "commit": commit,
        "commit_from": session.get("commit_from", "HEAD"),
        "api_calls": len(calls),
        "calls_replayed": len(replies),
        "replay_errors": errors,
        "covered": sum(1 for c in coverage.values() if c["reread"] or c["new"]),
        "covered_reread": sum(1 for c in coverage.values() if c["reread"]),
        "covered_content_new": sum(1 for c in coverage.values() if c["new"] and not c["reread"]),
        "covered_content_rec": sum(1 for c in coverage.values() if c["rec"] and not c["reread"]),
        "saved_turns": len(saved),
        "saved_turns_lookahead": len(lookahead),
        "saved_usd": round(saved_usd, 4),
        "added_tokens": round(added_tokens, 1),
        "added_usd": round(added_usd, 4),
        "net_usd": round(saved_usd - added_usd, 4),
        "seconds": round(seconds, 2),
        "cleanup": session.get("cleanup"),
        "calls": per_call,
        "top": top,
    }


def totals(rows):
    keys = ("calls_replayed", "covered", "covered_reread", "covered_content_new", "covered_content_rec", "saved_turns", "saved_turns_lookahead", "saved_usd", "added_tokens", "added_usd", "net_usd")
    t = {k: round(sum(r[k] for r in rows), 4) for k in keys}
    t["sessions"] = len(rows)
    t["net_usd_per_session"] = round(t["net_usd"] / len(rows), 4) if rows else 0.0
    return t


def write_md(path, result, baseline):
    t = result["totals"]
    lines = ["# Replay result", "", f"exe: `{result['exe']}`  ", f"run: {result['seconds']} s, {result['workers']} workers  ",
             f"token estimate: chars/{CHARS_PER_TOKEN_CODE} code, chars/{CHARS_PER_TOKEN_PROSE} prose/JSON (estimates)", "",
             "| metric | value |", "|---|---|"]
    for k in ("sessions", "calls_replayed", "covered", "covered_reread", "covered_content_new", "covered_content_rec", "saved_turns", "saved_turns_lookahead", "added_tokens", "saved_usd", "added_usd", "net_usd", "net_usd_per_session"):
        lines.append(f"| {k} | {t[k]} |")
    lines += ["", "## Per session", "", "| session | repo | replayed | covered | saved turns | lookahead | net $ |", "|---|---|---|---|---|---|---|"]
    for r in result["sessions"]:
        lines.append(f"| {os.path.basename(r['session'])[:12]} | {r['repo_name']} | {r['calls_replayed']} | {r['covered']} | {r['saved_turns']} | {r['saved_turns_lookahead']} | {r['net_usd']} |")
    lines += ["", "## Top 10 calls by saved turns", "", "| session | call | tool | saved turns | saved $ |", "|---|---|---|---|---|"]
    for x in result["top"]:
        lines.append(f"| {os.path.basename(x['session'])[:12]} | {x['k']} | {x['tool']} | {x['saved_turns']} | {x['saved_usd']} |")
    if result["skipped"]:
        lines += ["", "## Skipped", ""] + [f"- {k}: {v}" for k, v in sorted(result["skipped"].items())]
    if baseline:
        bt = baseline["totals"]
        lines += ["", "## Delta against baseline", "", f"baseline exe: `{baseline.get('exe')}`", "", "| metric | baseline | this | delta |", "|---|---|---|---|"]
        for k in ("calls_replayed", "covered", "saved_turns", "saved_turns_lookahead", "added_tokens", "net_usd", "net_usd_per_session"):
            lines.append(f"| {k} | {bt.get(k)} | {t[k]} | {round(t[k] - (bt.get(k) or 0), 4)} |")
        base = {r["session"]: r for r in baseline.get("sessions", [])}
        changed = [(r, base[r["session"]]) for r in result["sessions"] if r["session"] in base and (r["saved_turns"], r["net_usd"]) != (base[r["session"]]["saved_turns"], base[r["session"]]["net_usd"])]
        if changed:
            lines += ["", "| session | saved turns delta | net $ delta |", "|---|---|---|"]
            for r, b in changed:
                lines.append(f"| {os.path.basename(r['session'])[:12]} | {r['saved_turns'] - b['saved_turns']} | {round(r['net_usd'] - b['net_usd'], 4)} |")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--emetgate", default=DEFAULT_EXE)
    ap.add_argument("--root", default=os.path.expanduser("~/.claude/projects"))
    ap.add_argument("--out", required=True)
    ap.add_argument("--scratch", default=os.path.join(tempfile.gettempdir(), "emetgate-replay"))
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--baseline")
    ap.add_argument("--workers", type=int, default=min(8, os.cpu_count() or 4))
    ap.add_argument("--server-arg", action="append", default=[], help="extra argument for emetgate mcp, repeatable, e.g. --server-arg=--explore-mode --server-arg=dense")
    a = ap.parse_args()
    SERVER_ARGS[:] = a.server_arg
    started = time.monotonic()
    exe = os.path.abspath(a.emetgate)
    if not os.path.isfile(exe):
        sys.exit(f"emetgate exe not found: {exe}")
    scratch = os.path.abspath(a.scratch)
    out = os.path.abspath(a.out)
    for p in (scratch, out):
        if forbidden(p):
            sys.exit(f"refused: {p} is in a read-only folder")
        probe = p
        while not os.path.isdir(probe):
            probe = os.path.dirname(probe)
        if git(["rev-parse", "--is-inside-work-tree"], probe, check=False).stdout.strip() == "true":
            sys.exit(f"refused: {p} is inside a git work tree")
    os.makedirs(os.path.join(scratch, "wt"), exist_ok=True)
    os.makedirs(out, exist_ok=True)
    hooks_dir = tempfile.mkdtemp(prefix="hooks-", dir=scratch)
    paths = sorted(glob.glob(os.path.join(a.root, "**", "*.jsonl"), recursive=True))
    skipped = {}
    picked = []
    with concurrent.futures.ThreadPoolExecutor(a.workers) as pool:
        for s, why in pool.map(qualify, paths):
            if s is None:
                skipped[why] = skipped.get(why, 0) + 1
            else:
                picked.append(s)
    qualified = len(picked)
    if a.limit:
        picked = picked[:a.limit]
    locks = {}
    rows = []
    failures = []
    try:
        with concurrent.futures.ThreadPoolExecutor(a.workers) as pool:
            futs = {pool.submit(replay_session, s, exe, scratch, i, locks, hooks_dir): s for i, s in enumerate(picked)}
            for fut in concurrent.futures.as_completed(futs):
                s = futs[fut]
                try:
                    rows.append(fut.result())
                except Skip as e:
                    skipped[str(e)] = skipped.get(str(e), 0) + 1
                except Exception as e:
                    failures.append({"session": s["path"], "error": f"{type(e).__name__}: {e}"})
                    skipped["replay failed"] = skipped.get("replay failed", 0) + 1
    finally:
        for s in picked:
            wt = s.get("worktree")
            if wt and os.path.exists(wt):
                remove_worktree(s["repo"], wt, scratch, locks)
        shutil.rmtree(hooks_dir, ignore_errors=True)
    rows.sort(key=lambda r: r["session"])
    top = sorted((x for r in rows for x in r["top"]), key=lambda x: (-x["saved_turns"], -x["saved_usd"]))[:10]
    result = {"exe": exe, "qualified": qualified, "skipped": skipped, "failures": failures, "workers": a.workers,
              "seconds": round(time.monotonic() - started, 2), "totals": totals(rows), "top": top, "sessions": rows,
              "constants": {"chars_per_token_code": CHARS_PER_TOKEN_CODE, "chars_per_token_prose": CHARS_PER_TOKEN_PROSE, "cover_threshold": COVER_THRESHOLD}}
    baseline = None
    if a.baseline:
        with open(a.baseline, encoding="utf-8") as f:
            baseline = json.load(f)
        result["baseline_delta"] = {k: round(result["totals"][k] - (baseline["totals"].get(k) or 0), 4) for k in ("saved_turns", "saved_turns_lookahead", "net_usd", "added_tokens")}
    with open(os.path.join(out, "result.json"), "w", encoding="utf-8") as f:
        json.dump(result, f, indent=1)
    write_md(os.path.join(out, "result.md"), result, baseline)
    print(json.dumps({"qualified": qualified, "seconds": result["seconds"], **result["totals"], "failures": len(failures)}))


if __name__ == "__main__":
    main()
