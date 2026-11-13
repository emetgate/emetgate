"""Write-tool scenarios (catalog-write.md), same ids as the catalog."""

import os
import subprocess

from harness import (check, scenario, snap, snap_diff, git, read_bytes, refused_naming, refused_disk_identical,
                     if_refused_disk_identical, never_verified_without_tests, claims_verified, Skip)

ARGS = "fix/arg-check"
PYATOM = "fix/change-atomic-python"
CLAIMS = "fix/claims"
FUZZY = "fix/fallback-match-safe"
CLOSED = "fix/gate-fail-closed"

NODE_TEST = ("--test", "node --test")
T = "emetgate_change"


def change(ctx, s, root, args, timeout=None):
    before = snap(root)
    r = ctx.call(s, T, args, timeout)
    after = snap(root)
    return r, before, after


def node_repo(ctx, name="node", *flags):
    root = ctx.fresh(name)
    s = ctx.server(root, *(flags or NODE_TEST))
    return root, s


def edit(file, old, new, **kw):
    d = {"file": file, "old_string": old, "new_string": new}
    d.update(kw)
    return d


# ------------------------------------------------------------ positive control


@scenario("C01", "W5", "a passing edit is written and says which tests ran")
def c01(ctx):
    root, s = node_repo(ctx)
    r, b, a = change(ctx, s, root, {"edits": [edit("src/math.js", "return a + b;", "return b + a;")]})
    check(not r.refused, "a valid edit was refused: " + r.short())
    check(snap_diff(b, a) == ["src/math.js"], "unexpected disk change: %s" % snap_diff(b, a))
    never_verified_without_tests(r)


# ------------------------------------------------------------ W1 refused writes leave the disk alone


@scenario("C02", "W1", "an edit that breaks a test is refused and the disk is untouched")
def c02(ctx):
    root, s = node_repo(ctx)
    r, b, a = change(ctx, s, root, {"edits": [edit("src/math.js", "return a - b;", "return a + b;")]})
    refused_disk_identical(r, b, a)


@scenario("C03", "W1", "a syntax error is refused and the disk is untouched")
def c03(ctx):
    root, s = node_repo(ctx)
    r, b, a = change(ctx, s, root, {"edits": [edit("src/math.js", "return a * b;", "return a * ;")]})
    refused_disk_identical(r, b, a)


@scenario("C04", "W1", "old_string not found is refused and the disk is untouched")
def c04(ctx):
    root, s = node_repo(ctx)
    r, b, a = change(ctx, s, root, {"edits": [edit("src/math.js", "return a / b;", "return 0;")]})
    refused_disk_identical(r, b, a)


@scenario("C11", "W1", "overwriting an existing file without a hash is refused")
def c11(ctx):
    root, s = node_repo(ctx)
    r, b, a = change(ctx, s, root, {"edits": [{"file": "notes.txt", "content": "over\n"}]})
    refused_disk_identical(r, b, a)


@scenario("C14", "W1", "a stale hash is refused and the user's change is kept")
def c14(ctx):
    root, s = node_repo(ctx)
    h = ctx.file_hash(s, root, "notes.txt")
    with open(os.path.join(root, "notes.txt"), "wb") as f:
        f.write(b"changed by user\n")
    r, b, a = change(ctx, s, root, {"edits": [{"file": "notes.txt", "content": "over2\n", "hash": h}]})
    refused_disk_identical(r, b, a)
    check(read_bytes(root, "notes.txt") == b"changed by user\n", "the user's change was lost")


@scenario("C20", "W1", "a write into an ignored path is either written cleanly or refused with the disk untouched", fixed_by=CLOSED)
def c20(ctx):
    root, s = node_repo(ctx)
    r, b, a = change(ctx, s, root, {"edits": [{"file": "ignored/new.txt", "content": "hi\n"}]})
    if_refused_disk_identical(r, b, a, "write into an ignored path")


@scenario("C21", "W1 CONF", "writes outside the repo, into .git and into .emetgate are refused")
def c21(ctx):
    root, s = node_repo(ctx)
    outside = os.path.join(os.path.dirname(root), os.path.basename(root) + "_escape.txt")
    for f in ("../%s_escape.txt" % os.path.basename(root), outside, ".git/hooks/pre-commit", ".emetgate/x.txt"):
        r, b, a = change(ctx, s, root, {"edits": [{"file": f, "content": "x\n"}]})
        refused_disk_identical(r, b, a, "write to " + f)
    check(not os.path.exists(outside), "a file was written outside the repository")
    check(not os.path.exists(os.path.join(root, ".git", "hooks", "pre-commit")), "a hook was written into .git")


@scenario("PY1", "W1", "an exact edit that leaves an IndentationError is refused", fixed_by=PYATOM)
def py1(ctx):
    root = ctx.fresh("python")
    s = ctx.server(root, "--test", "python -m unittest")
    r, b, a = change(ctx, s, root, {"edits": [edit("pkg/q.py", "        a = 1\n", "    a = 1\n")]})
    refused_disk_identical(r, b, a, "IndentationError edit")


@scenario("PY2", "W1", "an exact edit that leaves an unexpected indent is refused", fixed_by=PYATOM)
def py2(ctx):
    root = ctx.fresh("python")
    s = ctx.server(root, "--test", "python -m unittest")
    r, b, a = change(ctx, s, root, {"edits": [edit("pkg/q.py", "    return 1\n", "    return 1\n        x = 2\n")]})
    refused_disk_identical(r, b, a, "unexpected indent edit")


@scenario("PY3", "W1", "an exact edit that mixes tabs and spaces is refused", fixed_by=PYATOM)
def py3(ctx):
    root = ctx.fresh("python")
    s = ctx.server(root, "--test", "python -m unittest")
    r, b, a = change(ctx, s, root, {"edits": [edit("pkg/q.py", "def g():\n    return 1\n", "def g():\n    y = 1\n\treturn y\n")]})
    refused_disk_identical(r, b, a, "tab/space edit")


@scenario("P01", "W5", "a Python edit passes unittest and is written")
def p01(ctx):
    root = ctx.fresh("python")
    s = ctx.server(root, "--test", "python -m unittest")
    r, b, a = change(ctx, s, root, {"edits": [edit("pkg/m.py", "def g():\n    return 1\n", "def g():\n    return 0 + 1\n")]},
                     timeout=120)
    check(not r.refused, "a valid Python edit was refused: " + r.short())
    never_verified_without_tests(r)


@scenario("G52", "W1", "a typecheck command that cannot run fails closed", fixed_by=CLOSED)
def g52(ctx):
    root = ctx.fresh("gate")
    s = ctx.server(root, "--test", "node --test", "--typecheck", "node does_not_exist.cjs")
    r, b, a = change(ctx, s, root, {"edits": [edit("lib.js", "return a + 1;", "return 1 + a;")]})
    refused_disk_identical(r, b, a, "edit with a typecheck that cannot run")


@scenario("G54", "W1", "a test command that cannot start fails closed", fixed_by=CLOSED)
def g54(ctx):
    root = ctx.fresh("gate")
    s = ctx.server(root, "--test", "node does_not_exist_test.js")
    r, b, a = change(ctx, s, root, {"edits": [edit("lib.js", "return a + 1;", "return 1 + a;")]})
    refused_disk_identical(r, b, a, "edit with a test command that cannot start")


@scenario("G55", "W1", "a test program that is not found fails closed", fixed_by=CLOSED)
def g55(ctx):
    root = ctx.fresh("gate")
    s = ctx.server(root, "--test", "nonexistent_program_xyz")
    r, b, a = change(ctx, s, root, {"edits": [edit("lib.js", "return a + 1;", "return 1 + a;")]})
    refused_disk_identical(r, b, a, "edit with a missing test program")


@scenario("G20", "E1 W1", "a test command that hangs is stopped and the edit refused", slow=True, timeout=200)
def g20(ctx):
    root = ctx.fresh("gate")
    s = ctx.server(root, "--test", "node hang.js")
    r, b, a = change(ctx, s, root, {"edits": [edit("lib.js", "return a + 1;", "return 1 + a;")]}, timeout=200)
    refused_disk_identical(r, b, a, "edit with a hanging test")


@scenario("I01", "W1", "a README change that breaks a test is refused", fixed_by=CLOSED)
def i01(ctx):
    root = ctx.fresh("inert")
    s = ctx.server(root, *NODE_TEST)
    r, b, a = change(ctx, s, root, {"edits": [edit("README.md", "## Install", "## Setup")]})
    refused_disk_identical(r, b, a, "README edit that breaks a test")


@scenario("I02", "W1", "a LICENSE change that breaks a test is refused", fixed_by=CLOSED)
def i02(ctx):
    root = ctx.fresh("inert")
    s = ctx.server(root, *NODE_TEST)
    r, b, a = change(ctx, s, root, {"edits": [edit("LICENSE", "MIT", "GPL")]})
    refused_disk_identical(r, b, a, "LICENSE edit that breaks a test")


@scenario("WD14", "W1", "a write_doc Markdown change that breaks a test is refused", fixed_by=CLOSED)
def wd14(ctx):
    root = ctx.fresh("inert")
    s = ctx.server(root, *NODE_TEST)
    h = ctx.doc_hash(s, "README.md", heading="Install")
    before = snap(root)
    r = ctx.call(s, "emetgate_write_doc", {"file": "README.md", "hash": h, "heading": "Install", "content": "## Setup\n\nnpm i\n"})
    refused_disk_identical(r, before, snap(root), "write_doc README breaking a test")


# ------------------------------------------------------------ W2 all or nothing


@scenario("C07", "W2", "two files, the second old_string missing: nothing is written")
def c07(ctx):
    root, s = node_repo(ctx)
    r, b, a = change(ctx, s, root, {"edits": [edit("src/math.js", "return a * b;", "return b * a;"),
                                              edit("src/dup.js", "NOPE", "x")]})
    refused_disk_identical(r, b, a, "two-file edit with one miss")


@scenario("C08", "W2", "two valid files whose tests fail: nothing is written")
def c08(ctx):
    root, s = node_repo(ctx)
    r, b, a = change(ctx, s, root, {"edits": [edit("src/dup.js", "const x = 1;", "const x = 7;"),
                                              edit("src/math.js", "return a - b;", "return a - b - 1;")]})
    refused_disk_identical(r, b, a, "two-file edit failing a test")


@scenario("C41", "W2", "delete plus create in one call, the create fails the tests: the delete is not applied")
def c41(ctx):
    root, s = node_repo(ctx)
    h = ctx.file_hash(s, root, "notes.txt")
    r, b, a = change(ctx, s, root, {"edits": [{"file": "notes.txt", "op": "delete", "hash": h},
                                              {"file": "test/new.test.js", "content": "require('node:test')('x', () => { throw new Error('boom'); });\n"}]})
    refused_disk_identical(r, b, a, "delete + failing create")


@scenario("RU02", "W2", "two files, the second breaks a rule: nothing is written")
def ru02(ctx):
    root = ctx.fresh("rules")
    p = ctx.run_exe(["rule", "add", "no eval in src", "--check", "forbid:eval", "--in", "src/", "--enforce"], root)
    check(p.returncode == 0, "rule add failed: " + (p.stdout + p.stderr)[:300])
    git(root, "add", "-A")
    git(root, "commit", "-q", "--no-verify", "-m", "rules")
    s = ctx.server(root, *NODE_TEST)
    r, b, a = change(ctx, s, root, {"edits": [edit("src/b.js", "return 2;", "return 3;"),
                                              edit("src/lib.js", "return a + 1;", "return eval('a + 1');")]})
    refused_disk_identical(r, b, a, "edit breaking a rule")


@scenario("RU06", "W2", "edits that pass plus a commit message a rule refuses: all or nothing", fixed_by=PYATOM)
def ru06(ctx):
    root = ctx.fresh("rules")
    p = ctx.run_exe(["rule", "add", "signed", "--check", "message:require:Signed-off-by:", "--enforce"], root)
    check(p.returncode == 0, "rule add failed: " + (p.stdout + p.stderr)[:300])
    git(root, "add", "-A")
    git(root, "commit", "-q", "--no-verify", "-m", "rules\n\nSigned-off-by: fx <fx@example.invalid>")
    s = ctx.server(root, *NODE_TEST)
    head = git(root, "rev-parse", "HEAD")
    r, b, a = change(ctx, s, root, {"edits": [edit("src/b.js", "return 2;", "return 4;")], "commit": "no signoff"})
    if r.refused:
        check(not snap_diff(b, a), "W2: the commit was refused but the edits were written: %s" % snap_diff(b, a))
        check(git(root, "rev-parse", "HEAD") == head, "W2: HEAD moved on a refused call")
    else:
        check(git(root, "rev-parse", "HEAD") != head, "W2: the call succeeded but nothing was committed")


@scenario("B01", "W2", "branch plus an edit that fails the tests: the branch is not left checked out", fixed_by=PYATOM)
def b01(ctx):
    root = ctx.fresh("gate")
    s = ctx.server(root, *NODE_TEST)
    r, b, a = change(ctx, s, root, {"branch": "feat/x", "edits": [edit("lib.js", "return a + 1;", "return a + 2;")]})
    refused_disk_identical(r, b, a, "branch + failing edit")
    check(git(root, "branch", "--show-current") == "main", "W2: the call was refused but HEAD moved to %s" % git(root, "branch", "--show-current"))


# ------------------------------------------------------------ W5 never "verified" without tests


@scenario("G42", "W5", "--detect-test with no test marker never says verified", fixed_by=CLAIMS)
def g42(ctx):
    root = ctx.fresh("notest")
    s = ctx.server(root, "--detect-test")
    r, b, a = change(ctx, s, root, {"edits": [edit("lib.js", "return a + 1;", "return 1 + a;")]})
    never_verified_without_tests(r, "--detect-test, no tests")
    check(r.refused or not claims_verified(r), "W5: verified without a test command: " + r.short())


@scenario("G40", "W1", "no test command at all: the write is refused with a fix")
def g40(ctx):
    root = ctx.fresh("notest")
    s = ctx.server(root)
    r, b, a = change(ctx, s, root, {"edits": [edit("lib.js", "return a + 1;", "return 1 + a;")]})
    refused_disk_identical(r, b, a, "write without a test command")
    check("NoTestCommand" in r.body and "fix" in r.body, "no NoTestCommand fix: " + r.short())


@scenario("G56", "W5", "a test command that runs no test ('exit 0') never says verified", fixed_by=CLAIMS)
def g56(ctx):
    root = ctx.fresh("gate")
    s = ctx.server(root, "--test", "exit 0")
    r, b, a = change(ctx, s, root, {"edits": [edit("lib.js", "return a + 1;", "return 1 + a;")]})
    check(r.refused or not claims_verified(r), "W5: 'exit 0' ran no test but the reply says verified: " + r.short())


@scenario("N01", "W5", "an edit in a nested repo the outer tests never see is not called verified", fixed_by=CLAIMS)
def n01(ctx):
    root = ctx.fresh("nested")
    s = ctx.server(root, *NODE_TEST)
    r, b, a = change(ctx, s, root, {"edits": [edit("inner/lib.js", "() => 2", "() => 3")]})
    never_verified_without_tests(r, "nested repo edit")
    if not r.refused and claims_verified(r):
        check("tests 0" not in r.body, "W5: verified with 0 tests: " + r.short())


@scenario("I03", "W5", "a later code edit does not call an earlier inert-file regression 'baseline'", fixed_by=CLOSED)
def i03(ctx):
    root = ctx.fresh("inert")
    s = ctx.server(root, *NODE_TEST)
    change(ctx, s, root, {"edits": [edit("README.md", "## Install", "## Setup")]})
    r, b, a = change(ctx, s, root, {"edits": [edit("lib.js", "=> 1", "=> 0 + 1")]})
    if read_bytes(root, "README.md").find(b"## Setup") >= 0:
        check(r.refused or "were there before" not in r.body,
              "W5: a regression made in this session is reported as baseline: " + r.short())


# ------------------------------------------------------------ fallback match must not lose text


@scenario("F01", "W5", "fallback match: indentation and a missing comment still apply on JS")
def f01(ctx):
    root = ctx.fresh("fuzzy")
    s = ctx.server(root, *NODE_TEST)
    r, b, a = change(ctx, s, root, {"edits": [edit("b.js", "function mul(a, b) {\n    return a * b;\n}", "function mul(a, b) {\n  return b * a;\n}")]})
    if not r.refused:
        check(b"b * a" in read_bytes(root, "b.js"), "reported written but the file does not hold the new text")
    else:
        check(not snap_diff(b, a), "refused but changed the disk")


@scenario("F02", "W5", "fallback match never deletes a comment the caller did not send", fixed_by=FUZZY)
def f02(ctx):
    root = ctx.fresh("fuzzy")
    s = ctx.server(root, *NODE_TEST)
    r, b, a = change(ctx, s, root, {"edits": [edit("a.js", "  first();\n  second();", "  first();\n  third();")]})
    check(b"IMPORTANT: keep this note" in read_bytes(root, "a.js"),
          "W5: the comment the caller did not send was deleted: " + r.short())
    if_refused_disk_identical(r, b, a)


@scenario("F04", "W5", "fallback match never deletes a YAML comment", fixed_by=FUZZY)
def f04(ctx):
    root = ctx.fresh("fuzzy")
    s = ctx.server(root, *NODE_TEST)
    r, b, a = change(ctx, s, root, {"edits": [edit("conf.yaml", "alpha: 1\nbeta: 2", "alpha: 1\nbeta: 3")]})
    check(b"# do not remove: license key below" in read_bytes(root, "conf.yaml"),
          "W5: the YAML comment was deleted: " + r.short())
    if_refused_disk_identical(r, b, a)


@scenario("F06", "W1", "fallback match never leaves Python that does not parse", fixed_by=FUZZY)
def f06(ctx):
    root = ctx.fresh("fuzzy")
    s = ctx.server(root, *NODE_TEST)
    r, b, a = change(ctx, s, root, {"edits": [edit("p.py", "if x:\n    a = 1\n    b = 2", "if x:\n    a = 1\n    c = 3")]})
    if_refused_disk_identical(r, b, a)
    p = subprocess.run(["python", "-I", "-c", "import ast,sys;ast.parse(open(sys.argv[1],encoding='utf-8').read())",
                        os.path.join(root, "p.py")], capture_output=True, text=True)
    check(p.returncode == 0, "W1: p.py no longer parses: " + (p.stderr.strip().splitlines() or [""])[-1])


# ------------------------------------------------------------ R3 unknown parameters on writes


@scenario("C23", "R3 W1", "change refuses an unknown dry_run and writes nothing", fixed_by=ARGS)
def c23(ctx):
    root, s = node_repo(ctx)
    r, b, a = change(ctx, s, root, {"edits": [edit("src/dup.js", "const y = 1;", "const y = 2;")], "dry_run": True})
    refused_naming(r, "dry_run")
    check(not snap_diff(b, a), "R3: dry_run was ignored and the change was written")


@scenario("C23b", "R3", "change refuses an unknown item field replaceAll", fixed_by=ARGS)
def c23b(ctx):
    root, s = node_repo(ctx)
    r, b, a = change(ctx, s, root, {"edits": [edit("src/dup.js", "const y = 1;", "const y = 4;", replaceAll=True)]})
    refused_naming(r, "replaceAll")


@scenario("C23c", "R3", "change refuses a top-level replace_all", fixed_by=ARGS)
def c23c(ctx):
    root, s = node_repo(ctx)
    r, b, a = change(ctx, s, root, {"edits": [edit("src/dup.js", "const y = 1;", "const y = 4;")], "replace_all": True})
    refused_naming(r, "replace_all")


@scenario("C23d", "R3", "change refuses message without commit", fixed_by=ARGS)
def c23d(ctx):
    root, s = node_repo(ctx)
    r, b, a = change(ctx, s, root, {"edits": [edit("src/dup.js", "const y = 1;", "const y = 5;")], "message": "msg"})
    refused_naming(r, "message")
    check(not snap_diff(b, a), "refused but wrote")


@scenario("C42", "R3", "an item with both old_string and content is refused", fixed_by=ARGS)
def c42(ctx):
    root, s = node_repo(ctx)
    h = ctx.file_hash(s, root, "notes.txt")
    r, b, a = change(ctx, s, root, {"edits": [{"file": "notes.txt", "old_string": "line1", "new_string": "LINE1",
                                               "content": "whole\n", "hash": h}]})
    check(r.refused, "R3: content beside old_string was silently ignored: " + r.short())
    check(not snap_diff(b, a), "refused but wrote")


@scenario("WD7", "R3", "write_doc with two selectors is refused", fixed_by=ARGS)
def wd7(ctx):
    root, s = node_repo(ctx)
    h = ctx.doc_hash(s, "config.json", pointer="/n")
    before = snap(root)
    r = ctx.call(s, "emetgate_write_doc", {"file": "config.json", "hash": h, "pointer": "/n", "heading": "Usage", "content": "4"})
    check(r.refused, "R3: pointer and heading both accepted: " + r.short())
    check(not snap_diff(before, snap(root)), "refused but wrote")


@scenario("WD12", "R3", "write_doc refuses an unknown append", fixed_by=ARGS)
def wd12(ctx):
    root, s = node_repo(ctx)
    h = ctx.doc_hash(s, "notes.txt", line_start=1, line_end=1)
    before = snap(root)
    r = ctx.call(s, "emetgate_write_doc", {"file": "notes.txt", "hash": h, "line_start": 1, "line_end": 1,
                                           "content": "first\n", "append": True})
    refused_naming(r, "append")
    check(not snap_diff(before, snap(root)), "refused but wrote")


@scenario("GW9", "R3", "git_write refuses an unknown dry_run and creates no branch", fixed_by=ARGS)
def gw9(ctx):
    root, s = node_repo(ctx)
    r = ctx.call(s, "emetgate_git_write", {"args": ["branch", "made-by-dry-run"], "dry_run": True})
    refused_naming(r, "dry_run")
    check("made-by-dry-run" not in git(root, "branch", "--list"), "R3: dry_run ignored, the branch was created")


@scenario("RA6", "R3", "run refuses timeout_s in allowlist mode", fixed_by=ARGS)
def ra6(ctx):
    root = ctx.fresh("gate")
    s = ctx.server(root, *NODE_TEST, "--allow-run", "node -v")
    r = ctx.call(s, "emetgate_run", {"command": "node -v", "timeout_s": 5})
    refused_naming(r, "timeout_s")


# ------------------------------------------------------------ W6 bytes kept


@scenario("C15", "W6", "a CRLF file edited with an LF old_string keeps CRLF")
def c15(ctx):
    root, s = node_repo(ctx)
    r, b, a = change(ctx, s, root, {"edits": [edit("src/crlf.js", "function crlf(a) {\n  return a + 1;\n}", "function crlf(a) {\n  return 1 + a;\n}")]})
    check(not r.refused, "refused: " + r.short())
    data = read_bytes(root, "src/crlf.js")
    check(b"return 1 + a;\r\n" in data and b"\n" not in data.replace(b"\r\n", b""), "CRLF not kept: %r" % data)


@scenario("C16", "W6", "a BOM file keeps its BOM after an edit")
def c16(ctx):
    root, s = node_repo(ctx)
    r, b, a = change(ctx, s, root, {"edits": [edit("src/bom.js", "return a + 2;", "return 2 + a;")]})
    check(not r.refused, "refused: " + r.short())
    check(read_bytes(root, "src/bom.js").startswith(b"\xef\xbb\xbf"), "BOM lost")


@scenario("C17", "W6", "a Turkish path and Turkish text are edited byte for byte")
def c17(ctx):
    root, s = node_repo(ctx)
    r, b, a = change(ctx, s, root, {"edits": [edit("src/türkçe/çalışma.js", "' — günaydın'", "' — iyi akşamlar ğüşıöç'")]})
    check(not r.refused, "refused: " + r.short())
    check("iyi akşamlar ğüşıöç".encode("utf-8") in read_bytes(root, "src/türkçe/çalışma.js"), "Turkish text not written")
