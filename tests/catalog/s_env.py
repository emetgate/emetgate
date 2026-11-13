"""Environment and session scenarios (catalog-env.md), same ids as the catalog
with an E prefix (EF4 is row F4, EC5 row C5 ...)."""

import json
import os
import shutil
import subprocess
import threading
import time

from harness import (check, scenario, snap, snap_diff, git, has_fix, refused_disk_identical, Server, Skip)

RC = "fix/reply-contract"
LONGPATH = "long paths over 260 characters are not part of the current fixes"
CONC = "concurrency and cancellation are not part of the current fixes"
LOWIL = "the low-integrity label (--open-run) is not part of the current fixes"
HOOKS = "hooks that fail open are not part of the current fixes"
UNOWNED = "no fix for this is named in the current work"


def edit(file, old, new):
    return {"file": file, "old_string": old, "new_string": new}


@scenario("EF4", "E1 W1", "change of a tracked file whose path is over 260 characters", xfail=LONGPATH)
def ef4(ctx):
    root = ctx.fresh("longpath")
    s = ctx.server(root, "--test", "exit 0")
    rel = "/".join("d%02d_padding" % i for i in range(24)) + "/deep.py"
    r = ctx.call(s, "emetgate_change", {"edits": [edit(rel, "return 'needle'", "return 'found'")]})
    check(not r.refused, "a long path could not be changed: " + r.short())


@scenario("EF7", "E1 W1", ".emetgate is a junction: the write is refused with a fix", fixed_by=RC)
def ef7(ctx):
    root = ctx.fresh("gate")
    target = root + "_emetgate_target"
    os.makedirs(target)
    subprocess.run(["cmd", "/c", "mklink", "/J", os.path.join(root, ".emetgate"), target], capture_output=True, check=True)
    s = ctx.server(root, "--test", "node --test")
    before = snap(root)
    r = ctx.call(s, "emetgate_change", {"edits": [edit("lib.js", "return a + 1;", "return 1 + a;")]})
    refused_disk_identical(r, before, snap(root), ".emetgate junction")
    check(os.listdir(target) == [], "the junction target outside the repository was written to")
    has_fix(r, ".emetgate junction")


@scenario("EF9", "E1 W1", "a read-only file: the write is refused with a fix and the tree is untouched", fixed_by=RC)
def ef9(ctx):
    root = ctx.fresh("gate")
    p = os.path.join(root, "lib.js")
    os.chmod(p, 0o444)
    try:
        s = ctx.server(root, "--test", "node --test")
        before = snap(root)
        r = ctx.call(s, "emetgate_change", {"edits": [edit("lib.js", "return a + 1;", "return 1 + a;")]})
        refused_disk_identical(r, before, snap(root), "read-only file")
        has_fix(r, "read-only file")
        check("run emetgate recover" not in r.body, "a clean tree is told to run emetgate recover: " + r.short())
    finally:
        os.chmod(p, 0o644)


@scenario("ER4", "E1", "list during a merge conflict shows the conflicted file once", xfail=UNOWNED)
def er4(ctx):
    root = ctx.fresh("merge")
    s = ctx.server(root)
    r = ctx.call(s, "emetgate_list", {})
    n = r.body.count("src/calc.py")
    check(n == 1, "src/calc.py listed %d times" % n)


@scenario("ER5", "E1", "--commit during a merge: refused with a fix, tree and MERGE_HEAD kept", fixed_by=RC)
def er5(ctx):
    root = ctx.fresh("merge")
    with open(os.path.join(root, "src/calc.py"), "w", encoding="utf-8", newline="\n") as f:
        f.write("def calc():\n    return 4\n")
    s = ctx.server(root, "--test", "exit 0", "--commit")
    r = ctx.call(s, "emetgate_change", {"commit": "merge it"})
    has_fix(r, "commit during a merge")
    check(os.path.exists(os.path.join(root, ".git", "MERGE_HEAD")), "MERGE_HEAD was lost")


@scenario("EM5", "R4", "--mirror: after the context epoch changes, a repeated read sends the body again", xfail=UNOWNED)
def em5(ctx):
    root = ctx.fresh("small")
    ep = os.path.join(os.path.dirname(root), os.path.basename(root) + "_ctx", "ctx.epoch")
    os.makedirs(os.path.dirname(ep))
    extra = {"EMETGATE_CONTEXT": ep, "CLAUDE_CODE_SESSION_ID": "suite-1"}

    def hook():
        p = ctx.run_exe(["hook", "session"], root, input_text=json.dumps(
            {"session_id": "suite-1", "hook_event_name": "SessionStart", "source": "compact"}), env_extra=extra)
        check(p.returncode == 0, "hook session failed: " + p.stderr[:200])

    hook()
    s = ctx.server(root, "--mirror", env_extra=extra)
    ctx.call(s, "emetgate_read_file", {"file": "src/util.ts"})
    ctx.call(s, "emetgate_read_file", {"file": "src/util.ts"})
    time.sleep(0.05)
    hook()
    r = ctx.call(s, "emetgate_read_file", {"file": "src/util.ts"})
    check("x * 2" in r.body, "R4: after the context changed the body was not sent again: " + r.short())


@scenario("EM9", "E1", "an unknown server flag is named in the error")
def em9(ctx):
    root = ctx.fresh("small")
    p = ctx.run_exe(["mcp", "--bogus-flag"], root, input_text="", timeout=30)
    check(p.returncode != 0, "an unknown flag was accepted")
    check("bogus-flag" in (p.stderr + p.stdout), "the unknown flag is not named: " + p.stderr[:160])


@scenario("EL4", "E1", "a ping is answered while a slow gated write runs", xfail=CONC, timeout=60)
def el4(ctx):
    root = ctx.fresh("gate")
    s = ctx.server(root, "--test", "node slow.js")
    rid = s.request("tools/call", {"name": "emetgate_change", "arguments": {"edits": [edit("lib.js", "return a + 1;", "return 1 + a;")]}})
    time.sleep(0.5)
    t0 = time.time()
    pong = s.rpc("ping", {}, timeout=30)
    dt = time.time() - t0
    s.wait(rid, 60)
    check(pong is not None and dt < 1.5, "ping waited %.1fs behind the gated write" % dt)


@scenario("EL5", "E1", "notifications/cancelled stops a slow gated write", xfail=CONC, slow=True, timeout=60)
def el5(ctx):
    root = ctx.fresh("gate")
    s = ctx.server(root, "--test", "node slow10.js")
    rid = s.request("tools/call", {"name": "emetgate_change", "arguments": {"edits": [edit("lib.js", "return a + 1;", "return 1 + a;")]}})
    time.sleep(1.0)
    s.notify("notifications/cancelled", {"requestId": rid, "reason": "user pressed Esc"})
    t0 = time.time()
    r = s.call("emetgate_read_file", {"file": "lib.js"}, timeout=80)
    dt = time.time() - t0
    check(not r.timed_out and dt < 5, "a read after the cancel waited %.1fs" % dt)


@scenario("EC3", "E1", "two sessions writing to one repository both get through", xfail=CONC, slow=True, timeout=120)
def ec3(ctx):
    root = ctx.fresh("gate")
    a = ctx.server(root, "--test", "node --test")
    b = ctx.server(root, "--test", "node --test")
    busy = []

    def go(s, prefix, n):
        for i in range(n):
            for _ in range(20):
                item = {"file": "%s_%d.js" % (prefix, i), "content": "exports.v = %d;\n" % i}
                r = s.call("emetgate_change", {"edits": [item]}, timeout=100)
                if "WorkspaceBusy" in r.body:
                    busy.append(prefix)
                    time.sleep(0.2)
                    continue
                break

    ta = threading.Thread(target=go, args=(a, "a", 4))
    tb = threading.Thread(target=go, args=(b, "b", 4))
    ta.start(); tb.start(); ta.join(); tb.join()
    check(not busy, "WorkspaceBusy %d times; the lock does not queue the second session" % len(busy))


@scenario("EC5", "E1", "an emetgate.exe that carries a Low label still writes, or says why it cannot",
          xfail=LOWIL, slow=True, timeout=30)
def ec5(ctx):
    low_dir = os.path.join(ctx.suite.work, "lowexe")
    os.makedirs(low_dir, exist_ok=True)
    exe = os.path.join(low_dir, "emetgate.exe")
    if not os.path.exists(exe):
        shutil.copy2(ctx.exe, exe)
        p = subprocess.run(["icacls", exe, "/setintegritylevel", "low"], capture_output=True, text=True)
        if p.returncode != 0:
            raise Skip("icacls could not label the copy: " + p.stdout[:120])
    root = ctx.fresh("gate")
    try:
        s = Server(exe, root, ("--test", "node --test"), env=ctx.env(), timeout=30, init_timeout=30)
    except RuntimeError as e:
        check(False, "a Low-labelled exe does not even answer initialize: %s" % e)
    ctx.servers.append(s)
    r = ctx.call(s, "emetgate_change", {"edits": [edit("lib.js", "return a + 1;", "return 1 + a;")]}, timeout=45)
    check(not r.refused or "integrity" in r.body.lower(),
          "a Low-labelled exe fails with a message that does not name the label: " + r.short())


@scenario("EK3", "E1", "an as_user command does not run when no PreToolUse hook vouched for it", xfail=HOOKS)
def ek3(ctx):
    # Under lockdown the PreToolUse hook asks the user before an as_user command.
    # When that hook is missing or crashes, the client runs the tool anyway (a
    # failed hook does not block), so the server must not rely on it alone.
    root = ctx.fresh("small")
    s = ctx.server(root, "--open-run")
    marker = os.path.join(root, "as_user_ran.txt")
    r = ctx.call(s, "emetgate_run", {"command": "cmd /c echo ran> as_user_ran.txt", "as_user": True})
    check(r.refused and not os.path.exists(marker),
          "an as_user command ran with the user's full rights and no hook in the loop: " + r.short())
