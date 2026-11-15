"""Replay the discount example session against a real emetgate.exe.

The model's steps are fixed tool calls; every reply recorded here is what
emetgate returned. Standard library only; reuses the catalog suite's MCP
client (tests/catalog/harness.py).

    python examples/discount/replay.py --emetgate zig-out/bin/emetgate.exe
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(REPO, "tests", "catalog"))
sys.path.insert(0, os.path.join(REPO, "tools", "verify_py"))

import hashlib

import jcs
from harness import Server, clean_env, snap, snap_diff

PROJECT = os.path.join(HERE, "project")
VERIFY_PY = os.path.join(REPO, "tools", "verify_py", "emetgate_verify.py")
TEST_CMD = "node --test"
RULE = ["rule", "add", "tests are frozen", "--check", "frozen", "--in", "test/", "--enforce"]
COMMIT_MSG = "pricing: applyDiscount takes a rate; checkout passes 15 / 100"
WHO = {"GIT_AUTHOR_NAME": "shop dev", "GIT_AUTHOR_EMAIL": "dev@shop.example",
       "GIT_COMMITTER_NAME": "shop dev", "GIT_COMMITTER_EMAIL": "dev@shop.example"}
BASE_DATE = "2026-11-14T09:00:00+00:00"
RULE_DATE = "2026-11-14T09:05:00+00:00"
SESSION_DATE = "2026-11-14T10:00:00+00:00"

PRICING_OLD = "function applyDiscount(price, percent) {\n  return price * (1 - percent / 100);\n}"
PRICING_NEW = "function applyDiscount(price, rate) {\n  return price * (1 - rate);\n}"
TEST_OLD = "test('15% discount on 100 gives 85', () => assert.strictEqual(memberPrice(100), 85));"
TEST_NEW = "test('15% discount on 100 gives 85', () => assert.strictEqual(memberPrice(100), -1400));"
CHECKOUT_OLD = "return applyDiscount(price, 15);"
CHECKOUT_NEW = "return applyDiscount(price, 15 / 100);"


def edit(file, old, new):
    return {"file": file, "old_string": old, "new_string": new}


STEPS = [
    ("search", "emetgate_search", {"pattern": "applyDiscount"}),
    ("search_certificate", "emetgate_search", {"pattern": "applyDiscount", "certificate": True}),
    ("change_alone", "emetgate_change", {"edits": [edit("src/pricing.js", PRICING_OLD, PRICING_NEW)]}),
    ("edit_the_test", "emetgate_change", {"edits": [edit("src/pricing.js", PRICING_OLD, PRICING_NEW),
                                                    edit("test/checkout.test.js", TEST_OLD, TEST_NEW)]}),
    ("change_both", "emetgate_change", {"edits": [edit("src/pricing.js", PRICING_OLD, PRICING_NEW),
                                                  edit("src/checkout.js", CHECKOUT_OLD, CHECKOUT_NEW)]}),
    ("commit", "emetgate_change", {"commit": COMMIT_MSG}),
]


def run(cmd, cwd, env=None, timeout=300):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, encoding="utf-8", errors="replace",
                       env=env, timeout=timeout)
    return {"argv": cmd, "exit_code": p.returncode, "stdout": p.stdout, "stderr": p.stderr}


def git(root, *args, env=None):
    r = run(["git", "-c", "core.autocrlf=false", *args], root, env=env)
    if r["exit_code"] != 0:
        raise SystemExit("git %s failed: %s" % (" ".join(args), r["stderr"].strip()))
    return r["stdout"].strip()


def dated(date):
    env = dict(os.environ)
    env.update(WHO)
    env["GIT_AUTHOR_DATE"] = date
    env["GIT_COMMITTER_DATE"] = date
    return env


def build_repo(root):
    shutil.copytree(PROJECT, root)
    git(root, "init", "-q", "-b", "main")
    for k, v in (("user.name", WHO["GIT_AUTHOR_NAME"]), ("user.email", WHO["GIT_AUTHOR_EMAIL"]),
                 ("core.autocrlf", "false"), ("commit.gpgsign", "false")):
        git(root, "config", k, v)
    git(root, "add", "-A")
    git(root, "commit", "-q", "--no-verify", "-m", "baseline: 15% member discount", env=dated(BASE_DATE))


def first_json(text):
    t = text.lstrip()
    if not t or t[0] not in "{[":
        return None
    try:
        v, _ = json.JSONDecoder().raw_decode(t)
        return v
    except ValueError:
        return None


def stop(msg, record):
    print("STOP: " + msg, file=sys.stderr)
    print(json.dumps(record, indent=2, ensure_ascii=False)[:4000], file=sys.stderr)
    raise SystemExit(2)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--emetgate", default=os.path.join(REPO, "zig-out", "bin", "emetgate.exe"))
    ap.add_argument("--out", default=HERE)
    ap.add_argument("--work", default=None)
    ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()

    work = os.path.normpath(os.path.abspath(a.work or tempfile.mkdtemp(prefix="emetgate-discount-")))
    os.makedirs(work, exist_ok=True)
    exe = os.path.join(work, "emetgate.exe")
    shutil.copy2(os.path.abspath(a.emetgate), exe)
    root = os.path.join(work, "shop")
    lad = os.path.join(work, "localappdata")
    os.makedirs(lad, exist_ok=True)
    env = clean_env(local_app_data=lad)
    env.update(WHO)
    env["GIT_AUTHOR_DATE"] = SESSION_DATE
    env["GIT_COMMITTER_DATE"] = SESSION_DATE

    build_repo(root)
    baseline = git(root, "rev-parse", "HEAD")
    version = run([exe, "--version"], root, env=env)
    rule = run([exe, *RULE], root, env=env)
    if rule["exit_code"] != 0:
        stop("emetgate rule add failed", rule)
    git(root, "add", "-A")
    git(root, "commit", "-q", "--no-verify", "-m", "rules: tests are frozen", env=dated(RULE_DATE))
    rules_commit = git(root, "rev-parse", "HEAD")

    server_args = ["--test", TEST_CMD, "--search-internals"]
    s = Server(exe, root, server_args, env=env, timeout=180)
    calls = []
    try:
        for name, tool, args in STEPS:
            before = snap(root)
            head_before = git(root, "rev-parse", "HEAD")
            r = s.call(tool, args, timeout=180)
            after = snap(root)
            calls.append({
                "step": name, "tool": tool, "arguments": args,
                "reply": {"text": r.text, "isError": r.is_error, "rpc_error": r.rpc_error,
                          "timed_out": r.timed_out, "died": r.died},
                "disk_changed": snap_diff(before, after),
                "head_before": head_before, "head_after": git(root, "rev-parse", "HEAD"),
                "refused": r.refused,
            })
            if r.timed_out or r.died:
                stop("%s: emetgate gave no reply" % name, calls[-1])
    finally:
        s.close()

    by = {c["step"]: c for c in calls}
    expect_refused = {"search": False, "search_certificate": False, "change_alone": True, "edit_the_test": True, "change_both": False, "commit": False}
    for name, want in expect_refused.items():
        if by[name]["refused"] != want:
            stop("%s: expected refused=%s" % (name, want), by[name])
        if want and by[name]["disk_changed"]:
            stop("%s: refused but the disk changed" % name, by[name])

    commit = git(root, "rev-parse", "HEAD")
    if commit == rules_commit:
        stop("the commit step made no commit", by["commit"])
    note = run(["git", "notes", "--ref=emetgate", "show", commit], root)
    note_ids = [hashlib.sha256(jcs.canonicalize(x)).hexdigest() for x in jcs.parse(note["stdout"].strip().encode("utf-8"))]
    verify = run([exe, "verify", commit, "--test", TEST_CMD], root, env=env)
    verify_json = run([exe, "verify", commit, "--test", TEST_CMD, "--json"], root, env=env)
    verify_py = run([sys.executable, "-I", VERIFY_PY, commit, "--repo", root], root)

    os.makedirs(a.out, exist_ok=True)
    bundle = os.path.join(a.out, "session.bundle")
    if os.path.exists(bundle):
        os.remove(bundle)
    git(root, "bundle", "create", bundle, "--all")
    bundle_heads = run(["git", "bundle", "list-heads", bundle], root)

    clone = os.path.join(work, "clone")
    git(work, "clone", "-q", bundle, clone)
    git(clone, "fetch", "-q", bundle, "refs/notes/emetgate:refs/notes/emetgate")
    clone_verify = run([exe, "verify", commit, "--test", TEST_CMD], clone, env=env)
    clone_verify_py = run([sys.executable, "-I", VERIFY_PY, commit, "--repo", clone], clone)

    session = {
        "emetgate_version": version["stdout"].strip(),
        "server_args": server_args,
        "setup": {"rule_add": rule, "baseline_commit": baseline, "rules_commit": rules_commit},
        "calls": calls,
        "after": {
            "commit": commit,
            "git_log": git(root, "log", "--format=%H %an <%ae> %aI %cI %s"),
            "receipt_note": note,
            "receipt_ids_from_note": note_ids,
            "emetgate_verify": verify,
            "emetgate_verify_json": verify_json,
            "verify_py": verify_py,
            "bundle_heads": bundle_heads,
            "from_bundle": {"emetgate_verify": clone_verify, "verify_py": clone_verify_py},
        },
    }
    session = redact(session, [work, os.path.abspath(a.out), REPO, sys.executable])
    with open(os.path.join(a.out, "session.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(session, f, indent=2, ensure_ascii=False)
        f.write("\n")
    with open(os.path.join(a.out, "SESSION.md"), "w", encoding="utf-8", newline="\n") as f:
        f.write(render(session))

    print("work folder: " + work)
    print("commit: " + commit)
    print("emetgate verify: exit %d" % verify["exit_code"])
    print("verify_py: exit %d" % verify_py["exit_code"])
    print("from bundle: emetgate verify exit %d, verify_py exit %d" % (clone_verify["exit_code"], clone_verify_py["exit_code"]))
    if not a.keep and not a.work:
        shutil.rmtree(work, ignore_errors=True)


def path_forms(p):
    p = os.path.normpath(os.path.abspath(p))
    forms = {p, p.replace("\\", "/"), p.replace("\\", "\\\\")}
    for f in list(forms):
        forms.add(f.lower())
    return sorted(forms, key=len, reverse=True)


def redact(value, paths):
    names = [("<work>", paths[0]), ("<out>", paths[1]), ("<emetgate repo>", paths[2]), ("python", paths[3])]
    pairs = [(form, label) for label, p in names for form in path_forms(p)]
    pairs.sort(key=lambda x: len(x[0]), reverse=True)

    def fix(s):
        for form, label in pairs:
            low = s.lower()
            at = low.find(form.lower())
            while at >= 0:
                s = s[:at] + label + s[at + len(form):]
                low = s.lower()
                at = low.find(form.lower())
        return s

    def walk(v):
        if isinstance(v, str):
            return fix(v)
        if isinstance(v, list):
            return [walk(x) for x in v]
        if isinstance(v, dict):
            return {k: walk(x) for k, x in v.items()}
        return v

    return walk(value)


def fence(text, limit=60):
    lines = text.rstrip("\n").split("\n")
    if len(lines) > limit:
        lines = lines[:limit] + ["... (%d more lines in session.json)" % (len(lines) - limit)]
    return "```\n" + "\n".join(lines) + "\n```\n"


def pretty(text):
    t = text.lstrip()
    if not t or t[0] not in "{[":
        return text
    try:
        v, end = json.JSONDecoder().raw_decode(t)
    except ValueError:
        return text
    rest = t[end:].strip("\n")
    return json.dumps(v, indent=2, ensure_ascii=False) + ("\n" + rest if rest else "")


def first_line(r):
    t = r["stdout"].strip()
    return t.split("\n")[0] if t else ""


def failed_names(fails):
    names = []
    for block in fails.split("\n\n"):
        lines = block.split("\n")
        if len(lines) > 1 and lines[1].startswith("test at ") and not lines[0].startswith(" "):
            names.append(lines[0])
    return names


def facts(session):
    by = {c["step"]: c for c in session["calls"]}
    a = session["after"]
    out = {}
    sj = first_json(by["search_certificate"]["reply"]["text"]) or {}
    cert = sj.get("certificate", {})
    out["answer"] = sj.get("answer")
    out["search_status"] = sj.get("status")
    out["root"] = cert.get("snapshot", {}).get("root")
    out["tree"] = cert.get("snapshot", {}).get("tree")
    out["in_scope"] = cert.get("scope", {}).get("in_scope")
    out["evaluated"] = cert.get("scope", {}).get("evaluated")
    out["total"] = sj.get("total")
    e2 = (first_json(by["change_alone"]["reply"]["text"]) or {}).get("edits", {})
    out["reason2"] = e2.get("reason")
    out["tests2"] = e2.get("tests")
    fails = e2.get("failures") or ""
    out["failing_test"] = fails.split("\n")[0] if fails else None
    m = re.search(r"actual:\s*([^,\n]+)", fails)
    out["actual"] = m.group(1).strip() if m else None
    m = re.search(r"expected:\s*([^,\n]+)", fails)
    out["expected"] = m.group(1).strip() if m else None
    out["failed_names"] = failed_names(fails)
    out["disk2"] = by["change_alone"]["disk_changed"]
    e3 = (first_json(by["edit_the_test"]["reply"]["text"]) or {}).get("edits", {})
    out["reason3"] = e3.get("reason")
    out["rule3"] = (e3.get("violations") or [{}])[0]
    out["fix3"] = e3.get("fix")
    out["disk3"] = by["edit_the_test"]["disk_changed"]
    e4 = (first_json(by["change_both"]["reply"]["text"]) or {}).get("edits", {})
    out["status4"] = e4.get("status")
    out["tests4"] = e4.get("tests")
    out["verified4"] = e4.get("verified")
    vj = first_json(a["emetgate_verify_json"]["stdout"]) or {}
    out["receipt"] = (vj.get("receipts") or [{}])[0].get("id")
    out["receipt_from_note"] = (a.get("receipt_ids_from_note") or [None])[0]
    c5 = (first_json(by["commit"]["reply"]["text"]) or {}).get("commit", {})
    out["commit"] = c5.get("commit")
    out["commit_files"] = c5.get("files")
    out["commit_receipts"] = c5.get("receipts")
    out["verify"] = first_line(a["emetgate_verify"])
    out["verify_exit"] = a["emetgate_verify"]["exit_code"]
    out["verify_py"] = first_line(a["verify_py"])
    out["verify_py_exit"] = a["verify_py"]["exit_code"]
    out["bundle_verify"] = first_line(a["from_bundle"]["emetgate_verify"])
    out["bundle_verify_exit"] = a["from_bundle"]["emetgate_verify"]["exit_code"]
    out["bundle_verify_py"] = first_line(a["from_bundle"]["verify_py"])
    out["bundle_verify_py_exit"] = a["from_bundle"]["verify_py"]["exit_code"]
    return out


def quoted(args):
    return " ".join('"%s"' % x if " " in x else x for x in args)


TITLES = {
    "search": "1a. Find every use of applyDiscount (the reply the model reads)",
    "search_certificate": "1b. The same search with its certificate",
    "change_alone": "2. Change applyDiscount to take a rate, without touching checkout.js",
    "edit_the_test": "3. Make the failing test expect the broken value",
    "change_both": "4. Change pricing.js and checkout.js together",
    "commit": "5. Commit through emetgate",
}


def render(session):
    f = facts(session)
    a = session["after"]
    parts = [
        "# The discount session\n\n",
        "Recorded by `replay.py` with `%s`, the server started as `emetgate mcp %s`. " % (
            session["emetgate_version"], quoted(session["server_args"])),
        "The tool calls are scripted; every reply below is emetgate's own output. "
        "The only change made to it is that the temporary folder the replay ran in is written as `<work>`. "
        "`session.json` holds each call and its full reply. `--search-internals` only lets step 1b ask for the "
        "certificate; the search reply the model reads is the text of step 1a.\n\n",
        "## Setup\n\n",
        "The project in `project/` is committed as a baseline (`%s`), then one rule is added on the command line "
        "and committed (`%s`):\n\n" % (session["setup"]["baseline_commit"], session["setup"]["rules_commit"]),
        fence("$ emetgate " + quoted(RULE) + "\n" + session["setup"]["rule_add"]["stdout"] + session["setup"]["rule_add"]["stderr"]),
        "\n",
    ]
    for c in session["calls"]:
        parts.append("## %s\n\n" % TITLES[c["step"]])
        parts.append("Call `%s`:\n\n" % c["tool"])
        parts.append("```json\n" + json.dumps(c["arguments"], indent=2, ensure_ascii=False) + "\n```\n\n")
        parts.append("Reply (%s; files changed on disk: %s; HEAD %s):\n\n" % (
            "refused" if c["refused"] else "accepted",
            ", ".join(c["disk_changed"]) or "none",
            "unchanged" if c["head_before"] == c["head_after"] else "%s -> %s" % (c["head_before"][:12], c["head_after"][:12])))
        parts.append(fence(pretty(c["reply"]["text"]), 120))
        parts.append("\n")
        failures = ((first_json(c["reply"]["text"]) or {}).get("edits") or {}).get("failures")
        if failures:
            parts.append("The `failures` field of that reply, with its `\\n` escapes printed as line breaks:\n\n")
            parts.append(fence(failures, 120))
            parts.append("\n")
    parts.append("## Verify the commit\n\n")
    parts.append(fence("$ git notes --ref=emetgate show %s\n%s" % (a["commit"], a["receipt_note"]["stdout"].strip())))
    parts.append("\n")
    parts.append(fence('$ emetgate verify %s --test "node --test"\n%s%s(exit %d)' % (
        a["commit"], a["emetgate_verify"]["stdout"], a["emetgate_verify"]["stderr"], a["emetgate_verify"]["exit_code"])))
    parts.append("\n")
    parts.append(fence("$ python tools/verify_py/emetgate_verify.py %s --repo .\n%s%s(exit %d)" % (
        a["commit"], a["verify_py"]["stdout"], a["verify_py"]["stderr"], a["verify_py"]["exit_code"])))
    parts.append("\nThe same two checks on a fresh clone of `session.bundle` (see README.md): `%s` (exit %d) and `%s` (exit %d).\n\n" % (
        f["bundle_verify"], f["bundle_verify_exit"], f["bundle_verify_py"], f["bundle_verify_py_exit"]))
    r3 = f["rule3"]
    parts.append("## Footnotes\n\n")
    parts.append(
        "1. Step 1: the search answers `%s`, status `%s`: %s matches, %s of %s files in scope evaluated; "
        "the certificate's %s Merkle root over every file read is `%s`.\n" % (
            f["answer"], f["search_status"], f["total"], f["evaluated"], f["in_scope"], f["tree"], f["root"]))
    parts.append(
        "2. Step 2: refused, reason `%s`, `%s`. First failing test: `%s`, expected `%s`, actual `%s`. "
        "Failing: %s. Files changed on disk: %s.\n" % (
            f["reason2"], f["tests2"], f["failing_test"], f["expected"], f["actual"],
            ", ".join("`%s`" % n for n in f["failed_names"]), ", ".join(f["disk2"]) or "none"))
    parts.append(
        "3. Step 3: refused, reason `%s`: rule `%s` (\"%s\", check `%s`) holds `%s`. Fix: \"%s\". Files changed on disk: %s.\n" % (
            f["reason3"], r3.get("rule"), r3.get("rule_text"), r3.get("check"), r3.get("file"), f["fix3"],
            ", ".join(f["disk3"]) or "none"))
    parts.append(
        "4. Step 4: `%s`, `%s`, \"%s\". Receipt id `%s` (from `emetgate verify --json`; the SHA-256 of the canonical "
        "receipt in the note, computed by the replay, is `%s`).\n" % (
            f["status4"], f["tests4"], f["verified4"], f["receipt"], f["receipt_from_note"]))
    parts.append("5. Step 5: commit `%s`, %s files, %s receipt attached under `refs/notes/emetgate`.\n" % (
        f["commit"], f["commit_files"], f["commit_receipts"]))
    parts.append("6. `emetgate verify %s --test \"node --test\"`: `%s` (exit %d).\n" % (
        f["commit"], f["verify"], f["verify_exit"]))
    parts.append(
        "7. Independent Python checker `tools/verify_py/emetgate_verify.py`: `%s` (exit %d). It does not rerun tests, "
        "so `consistent` is the most it reports.\n" % (f["verify_py"], f["verify_py_exit"]))
    parts.append("8. From a fresh clone of `session.bundle`: `%s` (exit %d) and `%s` (exit %d).\n" % (
        f["bundle_verify"], f["bundle_verify_exit"], f["bundle_verify_py"], f["bundle_verify_py_exit"]))
    return "".join(parts)


if __name__ == "__main__":
    main()
