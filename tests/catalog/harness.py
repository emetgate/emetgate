"""Scenario registry, MCP client and checks for the catalog suite.

Standard library only. Everything here runs under `python -I`.
"""

import hashlib
import json
import os
import re
import shutil
import subprocess
import threading
import time

# R1: no tool reply may be longer than this many characters unless the caller
# opted in to a bigger one (detail:"full"). The largest cap in the code today is
# the 64 KiB multi-file reply of emetgate_read_file.
REPLY_BUDGET = 65536

# E1: the longest any single call may take before the suite calls it a hang.
DEFAULT_CALL_TIMEOUT = 90.0

SCENARIOS = []


class Fail(Exception):
    """An invariant did not hold."""


class Skip(Exception):
    """The scenario cannot run on this machine (for example no node)."""


def scenario(sid, inv, title, *, slow=False, xfail=None, fixed_by=None, timeout=None):
    """Register a scenario.

    sid      the catalog id (C23, PY1, RF08 ...)
    inv      the invariant(s) it checks (R1, R2, R3, R4, W1, W2, W5, W6, E1, CONF)
    xfail    reason string when the fix is not part of the current work; the
             scenario is then expected to fail, and passing is reported as xpass
    fixed_by the branch or area expected to make it pass, shown when it fails
    timeout  per-call timeout in seconds for this scenario (E1)
    """

    def wrap(fn):
        SCENARIOS.append({
            "id": sid, "inv": inv, "title": title, "fn": fn, "slow": slow,
            "xfail": xfail, "fixed_by": fixed_by,
            "timeout": timeout or DEFAULT_CALL_TIMEOUT,
        })
        return fn

    return wrap


def check(cond, msg):
    if not cond:
        raise Fail(msg)


def clean_env(extra=None, local_app_data=None):
    env = {}
    for k, v in os.environ.items():
        u = k.upper()
        if u.startswith("CLAUDE") or u.startswith("ANTHROPIC") or u.startswith("EMETGATE"):
            continue
        env[k] = v
    env["EMETGATE_NO_UPDATE"] = "1"
    if local_app_data:
        env["LOCALAPPDATA"] = local_app_data
    if extra:
        env.update(extra)
    return env


def git(root, *args, check_rc=False):
    p = subprocess.run(["git", "-c", "core.autocrlf=false", *args], cwd=root, capture_output=True,
                       text=True, encoding="utf-8", errors="replace")
    if check_rc and p.returncode != 0:
        raise RuntimeError("git %s failed: %s" % (" ".join(args), p.stderr.strip()))
    return p.stdout.strip()


def snap(root):
    """SHA-256 of every file below root, outside .git and .emetgate."""
    out = {}
    for d, dirs, files in os.walk(root):
        dirs[:] = [x for x in dirs if x not in (".git", ".emetgate", "node_modules", "__pycache__")]
        for f in files:
            p = os.path.join(d, f)
            try:
                with open(p, "rb") as fh:
                    out[os.path.relpath(p, root).replace("\\", "/")] = hashlib.sha256(fh.read()).hexdigest()
            except OSError:
                out[os.path.relpath(p, root).replace("\\", "/")] = "unreadable"
    return out


def snap_diff(a, b):
    return sorted(k for k in set(a) | set(b) if a.get(k) != b.get(k))


def read_bytes(root, rel):
    with open(os.path.join(root, rel), "rb") as fh:
        return fh.read()


class Reply:
    """One tools/call result."""

    def __init__(self, tool, args):
        self.tool = tool
        self.args = args
        self.text = ""
        self.is_error = False
        self.rpc_error = None
        self.ms = 0
        self.timed_out = False
        self.died = False

    @property
    def body(self):
        """The text a model would see, including a JSON-RPC error message."""
        if self.rpc_error is not None:
            return json.dumps(self.rpc_error, ensure_ascii=False)
        return self.text

    def json(self):
        """The first JSON value of the reply text, or None."""
        t = self.body.lstrip()
        if not t or t[0] not in "{[":
            return None
        try:
            v, _ = json.JSONDecoder().raw_decode(t)
            return v
        except ValueError:
            return None

    def statuses(self):
        out = []

        def walk(v):
            if isinstance(v, dict):
                for k, x in v.items():
                    if k in ("status", "outcome") and isinstance(x, str):
                        out.append(x)
                    walk(x)
            elif isinstance(v, list):
                for x in v:
                    walk(x)

        walk(self.json())
        return out

    @property
    def refused(self):
        """True when the call says it did not do what was asked."""
        if self.rpc_error is not None or self.is_error:
            return True
        st = self.statuses()
        bad = {"error", "rejected", "refused", "stopped", "failed"}
        if st and st[-1] in bad:
            return True
        top = self.json()
        if isinstance(top, dict) and top.get("status") in bad:
            return True
        return bool(re.match(r"^\s*error\b", self.text))

    def has(self, *words, ci=False):
        b = self.body.lower() if ci else self.body
        return all((w.lower() if ci else w) in b for w in words)

    def short(self, n=240):
        b = self.body.replace("\n", " / ")
        return b[:n] + ("..." if len(b) > n else "")

    def __len__(self):
        return len(self.body)


class Server:
    """An `emetgate mcp` process driven over stdio JSON-RPC.

    Only this process is ever killed, by its own handle, never by image name.
    """

    def __init__(self, exe, cwd, args=(), env=None, timeout=DEFAULT_CALL_TIMEOUT, init_timeout=60):
        self.exe = exe
        self.cwd = cwd
        self.args = list(args)
        self.timeout = timeout
        self.p = subprocess.Popen([exe, "mcp", *self.args], cwd=cwd, stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env,
                                  creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        self.next_id = 0
        self.msgs = {}
        self.cv = threading.Condition()
        self.eof = False
        self.stderr = []
        threading.Thread(target=self._read_out, daemon=True).start()
        threading.Thread(target=self._read_err, daemon=True).start()
        r = self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                    "clientInfo": {"name": "catalog-suite", "version": "1"}}, timeout=init_timeout)
        if r is None:
            self.kill()
            raise RuntimeError("emetgate did not answer initialize; stderr: " + "".join(self.stderr)[-400:])
        self.notify("notifications/initialized", None)

    def _read_out(self):
        for line in self.p.stdout:
            try:
                m = json.loads(line)
            except ValueError:
                continue
            with self.cv:
                if isinstance(m, dict) and "id" in m:
                    self.msgs[m["id"]] = m
                self.cv.notify_all()
        with self.cv:
            self.eof = True
            self.cv.notify_all()

    def _read_err(self):
        for line in self.p.stderr:
            self.stderr.append(line.decode("utf-8", "replace"))
            if len(self.stderr) > 400:
                del self.stderr[:200]

    @property
    def alive(self):
        return self.p.poll() is None and not self.eof

    def send(self, obj):
        self.p.stdin.write((json.dumps(obj, ensure_ascii=False) + "\n").encode("utf-8"))
        self.p.stdin.flush()

    def notify(self, method, params):
        m = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            m["params"] = params
        self.send(m)

    def request(self, method, params):
        """Send a request without waiting; returns its id."""
        self.next_id += 1
        self.send({"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params})
        return self.next_id

    def wait(self, rid, timeout):
        end = time.time() + timeout
        with self.cv:
            while rid not in self.msgs:
                left = end - time.time()
                if left <= 0 or self.eof:
                    return None
                self.cv.wait(min(left, 1.0))
            return self.msgs.pop(rid)

    def rpc(self, method, params, timeout=None):
        return self.wait(self.request(method, params), timeout or self.timeout)

    def call(self, tool, args, timeout=None):
        r = Reply(tool, args)
        if not self.alive:
            r.died = True
            r.text = "emetgate process is not running"
            return r
        t0 = time.time()
        try:
            rid = self.request("tools/call", {"name": tool, "arguments": args})
        except OSError:
            r.died = True
            return r
        m = self.wait(rid, timeout or self.timeout)
        r.ms = int((time.time() - t0) * 1000)
        if m is None:
            if self.eof:
                r.died = True
                r.text = "emetgate exited during the call"
            else:
                r.timed_out = True
                self.kill()
            return r
        if "error" in m:
            r.rpc_error = m["error"]
            return r
        res = m.get("result") or {}
        r.text = "".join(c.get("text", "") for c in res.get("content", []) if isinstance(c, dict))
        r.is_error = bool(res.get("isError", False))
        return r

    def tools(self):
        m = self.rpc("tools/list", {})
        return [t["name"] for t in (m or {}).get("result", {}).get("tools", [])]

    def kill(self):
        if self.p.poll() is None:
            self.p.kill()
        try:
            self.p.wait(10)
        except subprocess.TimeoutExpired:
            pass

    def close(self, wait=15):
        try:
            self.p.stdin.close()
        except OSError:
            pass
        try:
            self.p.wait(wait)
        except subprocess.TimeoutExpired:
            self.kill()


class Ctx:
    """What a scenario gets: fixtures, servers, the exe and checks."""

    def __init__(self, suite, sc):
        self.suite = suite
        self.exe = suite.exe
        self.sid = sc["id"]
        self.timeout = sc["timeout"]
        self.servers = []
        self.calls = []

    def fixture(self, name):
        """A shared fixture. Scenarios must not change it."""
        return self.suite.fixtures.shared(name)

    def fresh(self, name, **kw):
        """A new private copy of a fixture this scenario may change."""
        return self.suite.fixtures.fresh(name, **kw)

    def env(self, extra=None):
        return clean_env(extra, self.suite.local_app_data)

    def server(self, root, *args, shared=False, env_extra=None):
        if shared and not env_extra:
            return self.suite.shared_server(root, args)
        s = Server(self.exe, root, args, env=self.env(env_extra), timeout=self.timeout)
        self.servers.append(s)
        return s

    def call(self, s, tool, args, timeout=None):
        r = s.call(tool, args, timeout or self.timeout)
        self.calls.append(r)
        check(not r.timed_out, "E1: %s gave no reply within %ss" % (tool, int(timeout or self.timeout)))
        if r.died:
            time.sleep(0.2)
            err = "".join(s.stderr)
            dump = os.path.join(self.suite.work, "stderr-%s-%d.txt" % (self.sid, s.p.pid))
            with open(dump, "w", encoding="utf-8") as f:
                f.write(err)
            at = max(err.find("panic"), err.find("error"), 0)
            tail = err[at:at + 300].strip().replace("\n", " | ") + " (stderr: %s)" % dump
            check(False, "E1: emetgate exited during %s (exit code %s): %s" % (tool, s.p.poll(), tail))
        return r

    def run_exe(self, args, cwd, input_text=None, env_extra=None, timeout=60):
        return subprocess.run([self.exe, *args], cwd=cwd, input=input_text, capture_output=True, text=True,
                              encoding="utf-8", errors="replace", env=self.env(env_extra), timeout=timeout)

    def file_hash(self, s, root, rel):
        r = self.call(s, "emetgate_read_file", {"file": rel, "raw": True})
        m = re.search(r'"file_hash"\s*:\s*"([0-9a-f]+)"', r.text)
        check(m is not None, "could not read the file_hash of %s: %s" % (rel, r.short()))
        return m.group(1)

    def doc_hash(self, s, rel, **selector):
        """The hash emetgate_write_doc wants: the one read_file gives for the
        same pointer, heading or line range."""
        r = self.call(s, "emetgate_read_file", dict(file=rel, **selector))
        m = re.search(r'"hash"\s*:\s*"([0-9a-f]{32})"', r.text)
        check(m is not None, "could not read the hash of %s %s: %s" % (rel, selector, r.short()))
        return m.group(1)

    def close(self):
        for s in self.servers:
            s.close(wait=10)
        self.servers = []


# ---------------------------------------------------------------- invariants

CUT_WORDS = re.compile(r"partial|truncat|elided|left out|not shown|not_sent|more\b|omitted|cut\b|of \d+|total", re.I)
NEXT_WORDS = re.compile(r"line_start|offset|cursor|next|page|handle|detail|\bdir\b|where|pointer|heading|symbol|path|range", re.I)


def within_budget(r, budget=REPLY_BUDGET, what=""):
    check(len(r) <= budget, "R1: %s reply is %d chars, budget %d" % (what or r.tool, len(r), budget))


def cut_named(r, what=""):
    """R2: a reply that was cut says so and names how to get the rest."""
    b = r.body
    check(CUT_WORDS.search(b) is not None, "R2: %s was cut without saying so: %s" % (what or r.tool, r.short()))
    check(NEXT_WORDS.search(b) is not None, "R2: %s does not say how to get the rest: %s" % (what or r.tool, r.short()))


def bounded_and_named(r, what=""):
    within_budget(r, what=what)
    cut_named(r, what=what)


def refused_naming(r, name, what=""):
    """R3: an unknown or inapplicable parameter is refused, and the reply names it."""
    check(r.refused, "R3: %s accepted %r without refusing it: %s" % (what or r.tool, name, r.short()))
    check(name in r.body, "R3: %s refused but did not name %r: %s" % (what or r.tool, name, r.short()))


def has_fix(r, what=""):
    """E1: an error reply carries a way to recover."""
    check(r.refused, "%s was expected to be refused: %s" % (what or r.tool, r.short()))
    j = r.json()
    found = False

    def walk(v):
        nonlocal found
        if isinstance(v, dict):
            if isinstance(v.get("fix"), str) and v["fix"].strip():
                found = True
            for x in v.values():
                walk(x)
        elif isinstance(v, list):
            for x in v:
                walk(x)

    walk(j)
    if r.rpc_error is not None:
        found = found or bool(re.search(r"fix|pass |use |call ", json.dumps(r.rpc_error), re.I))
    check(found, "E1: %s error has no fix: %s" % (what or r.tool, r.short()))


def claims_verified(r):
    j = r.json()
    hit = False

    def walk(v):
        nonlocal hit
        if isinstance(v, dict):
            if "verified" in v:
                hit = True
            for x in v.values():
                walk(x)
        elif isinstance(v, list):
            for x in v:
                walk(x)

    walk(j)
    return hit or "tests ran on a mirror" in r.body


def tests_counted(r):
    """How many tests the reply says ran (node: "tests 2", unittest: "Ran 2 tests",
    pytest: "2 passed"), or None when it names no count."""
    for pat in (r"\btests (\d+)", r"\bRan (\d+) tests?", r"(\d+) passed"):
        m = re.search(pat, r.body)
        if m:
            return int(m.group(1))
    return None


def never_verified_without_tests(r, what=""):
    """W5: a reply never says "verified" unless at least one test ran."""
    if r.refused:
        return
    if claims_verified(r):
        n = tests_counted(r)
        check(n is not None and n > 0,
              "W5: %s says verified but no test ran (tests=%s): %s" % (what or r.tool, n, r.short()))


def refused_disk_identical(r, before, after, what=""):
    """W1: a refused write leaves the disk byte-identical."""
    check(r.refused, "W1: %s was expected to be refused: %s" % (what or r.tool, r.short()))
    d = snap_diff(before, after)
    check(not d, "W1: %s was refused but changed %s" % (what or r.tool, d[:5]))


def if_refused_disk_identical(r, before, after, what=""):
    if r.refused:
        d = snap_diff(before, after)
        check(not d, "W1: %s was refused but changed %s: %s" % (what or r.tool, d[:5], r.short()))


def copy_tree(src, dst):
    shutil.copytree(src, dst, symlinks=True)
