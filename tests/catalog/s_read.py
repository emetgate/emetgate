"""Read-tool scenarios (catalog-read.md). Ids: RF read_file, RS read_symbol,
SK skeleton, LS list, SE search, FI find, EX explore, XP expand, GI git,
SC scan, followed by the item number of that tool's table in the catalog."""

import os
import time

from harness import (check, scenario, within_budget, cut_named, bounded_and_named, refused_naming,
                     has_fix, REPLY_BUDGET)

RC = "fix/reply-contract"
ARGS = "fix/arg-check"
CONF = "fix/confine"
GITB = "fix/git-scan-bounds"


def mix(ctx):
    root = ctx.fixture("mix")
    return root, ctx.server(root, shared=True)


# ------------------------------------------------------------ read_file


@scenario("RF04", "R2", "read_file range past the end says where the file ends")
def rf04(ctx):
    root, s = mix(ctx)
    r = ctx.call(s, "emetgate_read_file", {"file": "src/app.ts", "line_start": 2, "line_end": 99})
    check(not r.refused, "range past the end was refused: " + r.short())
    check("partial" in r.body or "ends at line" in r.body, "R2: no note that the file is shorter: " + r.short())


@scenario("RF08", "R1 R2", "read_file range 1-50,000 of a 50,000-line file", fixed_by=RC)
def rf08(ctx):
    root, s = mix(ctx)
    r = ctx.call(s, "emetgate_read_file", {"file": "data/many.txt", "line_start": 1, "line_end": 50000})
    bounded_and_named(r, "read_file range 1-50000")


@scenario("RF09", "R1 R2", "read_file range 1-400,000 of a 20 MB log", fixed_by=RC)
def rf09(ctx):
    root, s = mix(ctx)
    r = ctx.call(s, "emetgate_read_file", {"file": "data/huge.log", "line_start": 1, "line_end": 400000})
    bounded_and_named(r, "read_file range of 20 MB")


@scenario("RF10", "R1", "read_file range 1-1 of one 300 KB line", fixed_by=RC)
def rf10(ctx):
    root, s = mix(ctx)
    r = ctx.call(s, "emetgate_read_file", {"file": "data/longline.txt", "line_start": 1, "line_end": 1})
    bounded_and_named(r, "read_file one 300 KB line")


@scenario("RF11", "R1", "read_file range 1-1 of a minified file", fixed_by=RC)
def rf11(ctx):
    root = ctx.fixture("minjs")
    s = ctx.server(root, shared=True)
    r = ctx.call(s, "emetgate_read_file", {"file": "src/min.js", "line_start": 1, "line_end": 1, "raw": True})
    bounded_and_named(r, "read_file minified line")


@scenario("RF12", "R1 R2", "read_file of a 20 MB log says it was cut and how to read on", fixed_by=RC)
def rf12(ctx):
    root, s = mix(ctx)
    r = ctx.call(s, "emetgate_read_file", {"file": "data/huge.log"})
    within_budget(r)
    check("truncated" in r.body or "partial" in r.body, "R2: no cut marker: " + r.short())
    check("line_start" in r.body or "line_end" in r.body, "R2: the cut does not name line_start/line_end: " + r.short())


@scenario("RF18", "W6", "read_file keeps CRLF and BOM bytes")
def rf18(ctx):
    root, s = mix(ctx)
    r = ctx.call(s, "emetgate_read_file", {"file": "src/crlf.ts", "raw": True})
    check("\r\n" in r.text or "\\r\\n" in r.text, "CRLF not kept: " + r.short())
    r = ctx.call(s, "emetgate_read_file", {"file": "src/bom.py", "raw": True})
    check("bom_fn" in r.text, "BOM file not read: " + r.short())


@scenario("RF19", "W6", "read_file of a Turkish path and a Turkish Markdown heading")
def rf19(ctx):
    root, s = mix(ctx)
    r = ctx.call(s, "emetgate_read_file", {"file": "src/çalışma/şifre_ğüöı.py", "raw": True})
    check("şifre_kontrol" in r.text, "Turkish path not read: " + r.short())
    r = ctx.call(s, "emetgate_read_file", {"file": "notes/türkçe.md", "heading": "Alt başlık"})
    check("Daha fazla" in r.text, "Turkish heading not read: " + r.short())


@scenario("RF20", "R1", "read_file heading tree of an 800-section Markdown file", fixed_by=RC)
def rf20(ctx):
    root, s = mix(ctx)
    r = ctx.call(s, "emetgate_read_file", {"file": "docs/big.md"})
    within_budget(r, what="Markdown heading tree")


@scenario("RF21", "R1 R2", "read_file heading that spans the whole 300 KB document", fixed_by=RC)
def rf21(ctx):
    root, s = mix(ctx)
    r = ctx.call(s, "emetgate_read_file", {"file": "docs/big.md", "heading": "Root"})
    bounded_and_named(r, "Markdown section Root")


@scenario("RF24", "R1", "read_file key tree of a 1.8 MB JSON file", fixed_by=RC)
def rf24(ctx):
    root, s = mix(ctx)
    r = ctx.call(s, "emetgate_read_file", {"file": "data/big.json"})
    within_budget(r, what="JSON key tree")


@scenario("RF26", "R1 R2", "read_file JSON pointer to a 20,000-key object", fixed_by=RC)
def rf26(ctx):
    root, s = mix(ctx)
    r = ctx.call(s, "emetgate_read_file", {"file": "data/wide.json", "pointer": "/root"})
    bounded_and_named(r, "JSON pointer /root")


@scenario("RF27", "R1 R2", "read_file JSON pointer \"\" to the whole 1.8 MB document", fixed_by=RC)
def rf27(ctx):
    root, s = mix(ctx)
    r = ctx.call(s, "emetgate_read_file", {"file": "data/big.json", "pointer": ""})
    bounded_and_named(r, "JSON pointer \"\"")


@scenario("RF30", "R3", "read_file heading on a JSON file is refused, not dropped", fixed_by=ARGS)
def rf30(ctx):
    root, s = mix(ctx)
    r = ctx.call(s, "emetgate_read_file", {"file": "data/big.json", "heading": "Root"})
    within_budget(r, what="heading on JSON")
    refused_naming(r, "heading")


@scenario("RF35", "CONF", "read_file through a junction to outside the repo is refused")
def rf35(ctx):
    root, s = mix(ctx)
    for f in ("junc_out/secret.txt", "../outside/secret.txt", "C:/Windows/win.ini"):
        r = ctx.call(s, "emetgate_read_file", {"file": f, "raw": True})
        check(r.refused, "read outside the repo was served: %s -> %s" % (f, r.short()))
        check("OUTSIDE SECRET" not in r.body, "content from outside the repo: " + f)


@scenario("RF36", "CONF", "read_file of .git/config is refused")
def rf36(ctx):
    root, s = mix(ctx)
    r = ctx.call(s, "emetgate_read_file", {"file": ".git/config"})
    check(r.refused and "InternalPath" in r.body, "reading .git/config was not refused as InternalPath: " + r.short())


@scenario("RF31", "E1", "read_file of a tracked file whose path is over 260 characters",
          xfail="long paths over 260 characters are not part of the current fixes")
def rf31(ctx):
    root = ctx.fixture("longpath")
    s = ctx.server(root, shared=True)
    rel = "/".join("d%02d_padding" % i for i in range(24)) + "/deep.py"
    r = ctx.call(s, "emetgate_read_file", {"file": rel, "raw": True})
    check(not r.refused and "deep_fn" in r.text, "long path not readable: " + r.short())


@scenario("RF37", "E1", "read_file of a directory says how to recover", fixed_by=RC)
def rf37(ctx):
    root, s = mix(ctx)
    r = ctx.call(s, "emetgate_read_file", {"file": "src"})
    has_fix(r, "read_file of a directory")


@scenario("RF07", "E1", "read_file with only line_start says how to recover", fixed_by=RC)
def rf07(ctx):
    root, s = mix(ctx)
    r = ctx.call(s, "emetgate_read_file", {"file": "src/app.ts", "line_start": 2})
    has_fix(r, "read_file with only line_start")


@scenario("RF42", "R1 R2", "read_file of 32 files incl. big ones stays within 64 KiB and names what it left out")
def rf42(ctx):
    root, s = mix(ctx)
    files = ["data/huge.log", "data/many.txt", "data/longline.txt", "docs/big.md", "data/big.json", "src/app.ts"]
    r = ctx.call(s, "emetgate_read_file", {"files": files})
    bounded_and_named(r, "read_file files[]")


@scenario("RF46", "R3", "read_file refuses unknown parameters", fixed_by=ARGS)
def rf46(ctx):
    root, s = mix(ctx)
    r = ctx.call(s, "emetgate_read_file", {"file": "src/lib.rs", "bogus": 1})
    refused_naming(r, "bogus")


@scenario("RF47", "R3", "read_file refuses raw:\"yes\" (wrong type)", fixed_by=ARGS)
def rf47(ctx):
    root, s = mix(ctx)
    r = ctx.call(s, "emetgate_read_file", {"file": "src/lib.rs", "raw": "yes"})
    refused_naming(r, "raw")


@scenario("RF52", "R4", "read_file after a change on disk returns the new content")
def rf52(ctx):
    root = ctx.fresh("small")
    s = ctx.server(root)
    r1 = ctx.call(s, "emetgate_read_file", {"file": "notes.md", "raw": True})
    check("first version" in r1.text, "first read: " + r1.short())
    with open(os.path.join(root, "notes.md"), "w", encoding="utf-8", newline="\n") as f:
        f.write("# Notes\n\n## Part\n\nsecond version\n")
    r2 = ctx.call(s, "emetgate_read_file", {"file": "notes.md", "raw": True})
    check("second version" in r2.text, "R4: stale content after a disk change: " + r2.short())


# ------------------------------------------------------------ read_symbol


@scenario("RS03", "R2", "read_symbol symbols[] with one unknown name names it", fixed_by=RC)
def rs03(ctx):
    root, s = mix(ctx)
    r = ctx.call(s, "emetgate_read_symbol", {"file": "src/app.ts", "symbols": ["Cart.add", "Cart.total", "nope"]})
    check("nope" in r.body, "R2: the missing name is not named: " + r.short())


@scenario("RS04", "R3", "read_symbol with symbol and symbols refuses or reads both", fixed_by=ARGS)
def rs04(ctx):
    root, s = mix(ctx)
    r = ctx.call(s, "emetgate_read_symbol", {"file": "src/app.ts", "symbol": "Cart.add", "symbols": ["Cart.total"]})
    if not r.refused:
        check("push" in r.text and "reduce" in r.text, "R3: one of symbol/symbols was dropped silently: " + r.short())
    else:
        check("symbol" in r.body, "refusal does not name the parameter: " + r.short())


@scenario("RS08", "R1 R2", "read_symbol of a 4,500-line function is folded with a note")
def rs08(ctx):
    root, s = mix(ctx)
    r = ctx.call(s, "emetgate_read_symbol", {"file": "src/bigfn.py", "symbol": "big_function"})
    bounded_and_named(r, "read_symbol big_function")


@scenario("RS10", "R1", "read_symbol nodes:true keeps the read budget", fixed_by=RC)
def rs10(ctx):
    root, s = mix(ctx)
    r = ctx.call(s, "emetgate_read_symbol", {"file": "src/bigfn.py", "symbol": "big_function", "nodes": True})
    within_budget(r, what="read_symbol nodes:true")


@scenario("RS11", "R1 R2", "read_symbol line range over a huge function keeps the budget", fixed_by=RC)
def rs11(ctx):
    root, s = mix(ctx)
    r = ctx.call(s, "emetgate_read_symbol", {"file": "src/bigfn.py", "line_start": 1, "line_end": 4600})
    within_budget(r, 32768, what="read_symbol line range")
    cut_named(r, "read_symbol line range")


@scenario("RS21", "R4", "read_symbol after a change on disk returns the new body")
def rs21(ctx):
    root = ctx.fresh("small")
    s = ctx.server(root)
    r1 = ctx.call(s, "emetgate_read_symbol", {"file": "src/util.ts", "symbol": "helper"})
    check("x * 2" in r1.text, "first read: " + r1.short())
    with open(os.path.join(root, "src/util.ts"), "w", encoding="utf-8", newline="\n") as f:
        f.write("export function helper(x: number): number {\n  return x * 7;\n}\n")
    r2 = ctx.call(s, "emetgate_read_symbol", {"file": "src/util.ts", "symbol": "helper"})
    check("x * 7" in r2.text, "R4: stale body: " + r2.short())


# ------------------------------------------------------------ skeleton / symbols


@scenario("SK04", "R1 R2", "skeleton of a minified file with 15,000 functions keeps the budget", fixed_by=RC)
def sk04(ctx):
    root = ctx.fixture("minjs")
    s = ctx.server(root, shared=True)
    r = ctx.call(s, "emetgate_skeleton", {"file": "src/min.js"})
    bounded_and_named(r, "skeleton of min.js")


@scenario("SY03", "R1 R2", "symbols of a minified file elides with a note")
def sy03(ctx):
    root = ctx.fixture("minjs")
    s = ctx.server(root, shared=True)
    r = ctx.call(s, "emetgate_symbols", {"file": "src/min.js"})
    bounded_and_named(r, "symbols of min.js")


# ------------------------------------------------------------ list


@scenario("LS01", "R1 R2", "list of a 5,000-file repository gives a total and a way to page", fixed_by=RC)
def ls01(ctx):
    root = ctx.fixture("huge")
    s = ctx.server(root, shared=True)
    r = ctx.call(s, "emetgate_list", {})
    within_budget(r, what="list of 5,000 files")
    check("5000" in r.body or "5,000" in r.body, "R2: list does not give the total of 5000: " + r.short())
    check("offset" in r.body or "cursor" in r.body or "next" in r.body, "R2: list gives no way to page: " + r.short())


@scenario("LS03", "CONF", "list does not show files behind a junction to outside the repo", fixed_by=CONF)
def ls03(ctx):
    root, s = mix(ctx)
    r = ctx.call(s, "emetgate_list", {"dir": "."})
    check("junc_out/secret.txt" not in r.body and "junc_out\\\\secret.txt" not in r.body,
          "CONF: list shows a file outside the repository: junc_out/secret.txt")


@scenario("LS05", "R3", "list with an offset it does not support refuses it or honours it", fixed_by=ARGS)
def ls05(ctx):
    root, s = mix(ctx)
    a = ctx.call(s, "emetgate_list", {"dir": "many"})
    b = ctx.call(s, "emetgate_list", {"dir": "many", "offset": 100})
    check(b.refused or a.body != b.body, "R3: offset was silently ignored")


@scenario("LS06", "R3", "list with a file as dir is refused", fixed_by=ARGS)
def ls06(ctx):
    root, s = mix(ctx)
    r = ctx.call(s, "emetgate_list", {"dir": "src/app.ts"})
    check(r.refused, "R3: a file passed as dir answered an empty list: " + r.short())


# ------------------------------------------------------------ search


@scenario("SE01", "R1 R2", "search with 73,000 matches pages with an offset")
def se01(ctx):
    root, s = mix(ctx)
    r = ctx.call(s, "emetgate_search", {"pattern": "needle"})
    bounded_and_named(r, "search needle")


@scenario("SE05", "R2", "search does not answer a complete 'no match' when the hit is in a file over 16 MiB", fixed_by=RC)
def se05(ctx):
    root, s = mix(ctx)
    r = ctx.call(s, "emetgate_search", {"pattern": "id=399999"})
    check("huge.log" in r.body, "R2: search says nothing about data/huge.log, the file that holds the match: " + r.short())


@scenario("SE15", "R4", "search after a change on disk finds the new text")
def se15(ctx):
    root = ctx.fresh("small")
    s = ctx.server(root)
    r1 = ctx.call(s, "emetgate_search", {"pattern": "first version"})
    check("notes.md" in r1.body, "first search: " + r1.short())
    with open(os.path.join(root, "notes.md"), "w", encoding="utf-8", newline="\n") as f:
        f.write("# Notes\n\n## Part\n\nthird edition\n")
    r2 = ctx.call(s, "emetgate_search", {"pattern": "third edition"})
    check("notes.md" in r2.body, "R4: search missed the new text: " + r2.short())


@scenario("SE19", "E1", "search with an unknown kind says how to recover", fixed_by=RC)
def se19(ctx):
    root, s = mix(ctx)
    r = ctx.call(s, "emetgate_search", {"pattern": "needle", "kinds": ["bogus"]})
    has_fix(r, "search kinds:[bogus]")


@scenario("SE20", "R3", "search refuses an unknown parameter", fixed_by=ARGS)
def se20(ctx):
    root, s = mix(ctx)
    r = ctx.call(s, "emetgate_search", {"pattern": "NEEDLE", "case_insensitive": True})
    refused_naming(r, "case_insensitive")


# ------------------------------------------------------------ find


@scenario("FI03", "CONF", "find does not return content from outside the repo through a junction", fixed_by=CONF)
def fi03(ctx):
    root, s = mix(ctx)
    r = ctx.call(s, "emetgate_find", {"pattern": "OUTSIDE SECRET"})
    check("junc_out" not in r.body, "CONF: find returned a hit outside the repository: " + r.short())


@scenario("FI09", "R3", "find with an empty pattern is an error, not 'no hits'", fixed_by=ARGS)
def fi09(ctx):
    root, s = mix(ctx)
    r = ctx.call(s, "emetgate_find", {"pattern": ""})
    check(r.refused, "R3: an invalid pattern was answered as a normal result: " + r.short())


@scenario("FI10", "R3", "find refuses or honours dir", fixed_by=ARGS)
def fi10(ctx):
    root, s = mix(ctx)
    r = ctx.call(s, "emetgate_find", {"pattern": "needle", "dir": "src"})
    check(r.refused or "many/" not in r.body, "R3: dir was silently ignored: " + r.short())


@scenario("FI11", "R4", "find right after a change on disk finds the new text")
def fi11(ctx):
    root = ctx.fresh("small")
    s = ctx.server(root)
    ctx.call(s, "emetgate_find", {"pattern": "first version"})
    # The miss is a race with the index refresh, so try several rounds.
    for i in range(4):
        time.sleep(2)
        word = "draft%dword" % i
        with open(os.path.join(root, "notes.md"), "w", encoding="utf-8", newline="\n") as f:
            f.write("# Notes\n\n## Part\n\n%s\n" % word)
        r = ctx.call(s, "emetgate_find", {"pattern": word})
        check("notes.md" in r.body, "R4: find missed the new text in round %d: %s" % (i + 1, r.short()))


# ------------------------------------------------------------ explore / evidence


@scenario("EX06", "R1 R2", "explore over 5,000 matching functions keeps the budget and does not claim 'everything'",
          slow=True, fixed_by=RC, timeout=180)
def ex06(ctx):
    root = ctx.fixture("huge")
    s = ctx.server(root, shared=True)
    r = ctx.call(s, "emetgate_explore", {"question": "which functions add a number to x (needle)"}, timeout=180)
    within_budget(r, what="explore over 5,000 functions")
    check("This is everything the index matched" not in r.body,
          "R2: explore says it showed everything the index matched while 5,000 functions match")


@scenario("EX08", "E1", "explore on a repository with a minified file answers within the call timeout",
          slow=True, timeout=60)
def ex08(ctx):
    root = ctx.fixture("minjs")
    s = ctx.server(root, shared=True)
    r = ctx.call(s, "emetgate_explore", {"question": "what does appMain return", "names": ["appMain"]}, timeout=60)
    check("appMain" in r.body, "explore did not find appMain: " + r.short())


@scenario("EX10", "R4", "explore after a change on disk shows the new body")
def ex10(ctx):
    root = ctx.fresh("small")
    s = ctx.server(root)
    ctx.call(s, "emetgate_explore", {"question": "what does helper return", "names": ["helper"]})
    with open(os.path.join(root, "src/util.ts"), "w", encoding="utf-8", newline="\n") as f:
        f.write("export function helper(x: number): number {\n  return x * 9;\n}\n")
    r = ctx.call(s, "emetgate_explore", {"question": "what does helper return", "names": ["helper"]})
    check("x * 9" in r.body, "R4: explore shows a stale body: " + r.short())


# ------------------------------------------------------------ expand


@scenario("XP03", "R1", "expand of a compacted big reply keeps the budget", fixed_by=RC)
def xp03(ctx):
    root = ctx.fixture("mix")
    s = ctx.server(root, "--compact", shared=True)
    r = ctx.call(s, "emetgate_read_file", {"file": "data/many.txt", "line_start": 1, "line_end": 20000})
    import re as _re
    m = _re.search(r'emetgate_expand \{"handle":"([^"]+)"', r.body)
    if not m:
        within_budget(r, what="compacted range read")
        return
    e = ctx.call(s, "emetgate_expand", {"handle": m.group(1)})
    within_budget(e, what="expand")


# ------------------------------------------------------------ git


def hist(ctx):
    root = ctx.fixture("hist")
    return root, ctx.server(root, shared=True)


@scenario("GI03", "R1 R2", "git diff of a 100,000-line change answers within the budget", fixed_by=GITB)
def gi03(ctx):
    root, s = hist(ctx)
    r = ctx.call(s, "emetgate_git", {"sub": "diff"})
    check(not r.refused, "git diff of a big change failed: " + r.short())
    bounded_and_named(r, "git diff")


@scenario("GI03b", "R3", "git diff with line_start refuses it or honours it", fixed_by=ARGS)
def gi03b(ctx):
    root, s = hist(ctx)
    r = ctx.call(s, "emetgate_git", {"sub": "diff", "path": "big.txt", "line_start": 1, "line_end": 5})
    if r.refused:
        check("line_start" in r.body and "GitOutputTooLarge" not in r.body, "R3: line_start silently ignored for diff: " + r.short())
    else:
        within_budget(r, 8192, what="diff lines 1-5")


@scenario("GI13", "R1", "git blame of a 100,000-line file detail:full stays within 16 KiB", fixed_by=GITB)
def gi13(ctx):
    root, s = hist(ctx)
    r = ctx.call(s, "emetgate_git", {"sub": "blame", "path": "big.txt", "detail": "full"})
    within_budget(r, 16384, what="blame detail:full")


@scenario("GI15", "R1 R2", "git blame of a whole 20 MB file answers, cut and named", fixed_by=GITB, slow=True)
def gi15(ctx):
    root, s = mix(ctx)
    r = ctx.call(s, "emetgate_git", {"sub": "blame", "path": "data/huge.log"})
    check(not r.refused, "blame of a 20 MB file failed: " + r.short())
    bounded_and_named(r, "blame of 20 MB")


@scenario("GI21", "R2", "git args log -p over the output cap shows a cut, not nothing", fixed_by=GITB)
def gi21(ctx):
    root, s = hist(ctx)
    r = ctx.call(s, "emetgate_git", {"sub": "log", "args": ["-p"]})
    within_budget(r, what="git log -p")
    check("commit" in r.body and len(r) > 200, "R2: git log -p gave nothing back: " + r.short())
    cut_named(r, "git log -p")


@scenario("GI26", "R3", "git refuses an unknown parameter", fixed_by=ARGS)
def gi26(ctx):
    root, s = hist(ctx)
    r = ctx.call(s, "emetgate_git", {"sub": "status", "bogus": 1})
    refused_naming(r, "bogus")


@scenario("GI27", "W6", "git diff prints a Turkish path as text, not octal escapes", fixed_by=GITB)
def gi27(ctx):
    root, s = hist(ctx)
    r = ctx.call(s, "emetgate_git", {"sub": "diff", "path": "notes/türkçe.md"})
    check("türkçe.md" in r.body, "Turkish path quoted or missing: " + r.short())


# ------------------------------------------------------------ scan


@scenario("SC01", "R2", "scan with 1,500 violations names how to get past the first 100", fixed_by=GITB)
def sc01(ctx):
    root, s = mix(ctx)
    r = ctx.call(s, "emetgate_scan", {"check": "forbid:needle"})
    within_budget(r, what="scan")
    check("offset" in r.body or "cursor" in r.body or "next" in r.body, "R2: scan gives no way to the rest: " + r.short())


@scenario("SC05", "E1", "scan with an unknown check says how to recover", fixed_by=RC)
def sc05(ctx):
    root, s = mix(ctx)
    r = ctx.call(s, "emetgate_scan", {"check": "zzz:qq"})
    has_fix(r, "scan unknown check")


# ------------------------------------------------------------ R1 across every reply of this module


@scenario("RB01", "R1", "default views of small files stay small")
def rb01(ctx):
    root, s = mix(ctx)
    for f in ("src/app.ts", "src/lib.rs", "notes/türkçe.md", "src/bigfn.py"):
        r = ctx.call(s, "emetgate_read_file", {"file": f})
        within_budget(r, 16384 + 512, what="read_file " + f)
    check(REPLY_BUDGET > 0, "budget")
