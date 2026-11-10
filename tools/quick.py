"""Run the tests that sit next to a change, and only compile those.

    python tools/quick.py                 tests for what differs from HEAD
    python tools/quick.py main            tests for what differs from main
    python tools/quick.py src/engine/cas.zig tests/rule.zig
    python tools/quick.py --wide          also the suites of the files that import the change
    python tools/quick.py --all           follow importers all the way up
    python tools/quick.py --list          print the selection and stop

The selection is the tests in each changed file, the tests in the source files
that import it directly, and the suites under tests/ that name its module.
--wide adds the suites that name a direct importer's module, --all follows the
importers to the top. The default is the quick loop, not the whole proof: a
change to a low file can break a suite that reaches it through three others,
and only `zig build test` runs them all. A change this script cannot map to a
test file runs every test.

The times are the sums of tests/test_times.tsv, as one process would take them.
Tests inside src/ always run. The suites under tests/ run cheapest first until
--budget seconds of them are in; the rest are named as left out. --budget 0
runs the whole selection.
"""

import argparse
import os
import re
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IMPORT = re.compile(r'@import\("([^"]+\.zig)"\)')
MODULE_USE = re.compile(r'(?:\bemetgate|@import\("emetgate"\))\.([a-z_0-9]+)')
ROOT_DECL = re.compile(r'^pub const ([a-z_0-9]+) = @import\("([^"]+\.zig)"\);', re.M)
HAS_TEST = re.compile(r'^test ["{]', re.M)
EVERYTHING = ("build.zig", "build.zig.zon", "test_root.zig", "src/root.zig", "tools/test_runner.zig", "src/c.h")


def read(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8", errors="replace") as f:
        return f.read()


def zig_files(top):
    out = []
    for folder, _, names in os.walk(os.path.join(ROOT, top)):
        for name in names:
            if name.endswith(".zig"):
                out.append(os.path.relpath(os.path.join(folder, name), ROOT).replace("\\", "/"))
    return sorted(out)


def imports_of(rel, text):
    here = os.path.dirname(rel)
    found = set()
    for target in IMPORT.findall(text):
        path = os.path.normpath(os.path.join(here, target)).replace("\\", "/")
        if os.path.isfile(os.path.join(ROOT, path)):
            found.add(path)
    return found


class Graph:
    def __init__(self):
        self.text = {rel: read(rel) for rel in zig_files("src") + zig_files("tests")}
        self.imports = {rel: imports_of(rel, text) for rel, text in self.text.items()}
        self.importers = {rel: set() for rel in self.text}
        for rel, targets in self.imports.items():
            for target in targets:
                if target in self.importers and rel != "src/root.zig":
                    self.importers[target].add(rel)
        self.module_of = {"src/" + path: name for name, path in ROOT_DECL.findall(self.text["src/root.zig"])}
        self.users = {}
        for rel, text in self.text.items():
            if rel.startswith("tests/"):
                for name in set(MODULE_USE.findall(text)):
                    self.users.setdefault(name, set()).add(rel)

    def has_tests(self, rel):
        return bool(HAS_TEST.search(self.text[rel]))

    def above(self, rel, all_the_way):
        seen = {rel}
        frontier = [rel]
        while frontier:
            nxt = []
            for item in frontier:
                for importer in self.importers.get(item, ()):
                    if importer not in seen:
                        seen.add(importer)
                        nxt.append(importer)
            frontier = nxt if all_the_way else []
        return seen

    def select(self, changed, reach):
        picked = set()
        for rel in changed:
            if rel.startswith("tests/"):
                picked |= self.above(rel, True)
                continue
            sources = self.above(rel, reach == "all")
            picked |= sources
            for source in sources if reach != "near" else [rel]:
                name = self.module_of.get(source)
                if name:
                    for suite in self.users.get(name, ()):
                        picked |= self.above(suite, True)
                stem = os.path.basename(source)[: -len(".zig")]
                for suite in self.text:
                    base = os.path.basename(suite)
                    if suite.startswith("tests/") and (base == stem + ".zig" or base.startswith(stem + "_")):
                        picked |= self.above(suite, True)
        return sorted(rel for rel in picked if self.has_tests(rel))


def recorded_seconds():
    seconds = {}
    try:
        lines = read("tests/test_times.tsv").splitlines()
    except OSError:
        return seconds
    for line in lines:
        fields = line.split("	")
        if len(fields) >= 3 and fields[0].isdigit():
            key = fields[2].split(".test.")[0] + "."
            seconds[key] = seconds.get(key, 0.0) + int(fields[0]) / 1e6
    return seconds


def prefix(rel):
    return rel[: -len(".zig")].replace("/", ".") + "."


def git(*args):
    done = subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if done.returncode != 0:
        sys.exit("quick: git %s failed: %s" % (" ".join(args), done.stderr.strip()))
    return [line for line in done.stdout.splitlines() if line]


def changed_since(ref):
    return sorted(set(git("diff", "--name-only", ref, "--") + git("ls-files", "--others", "--exclude-standard")))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("what", nargs="*", help="a git ref to compare with (default HEAD), or the changed files themselves")
    parser.add_argument("--wide", action="store_true", help="also the suites that name a direct importer's module")
    parser.add_argument("--all", action="store_true", help="follow importers of the change all the way up")
    parser.add_argument("--budget", type=float, default=300.0, help="seconds of tests/ suites to run, summed as one process (default 300, 0 for no limit)")
    parser.add_argument("--list", action="store_true", help="print the selection and stop")
    parser.add_argument("--slow", action="store_true", help="also run the tests marked slow")
    parser.add_argument("--jobs", type=int, default=min(os.cpu_count() or 4, 12), help="test processes (default: logical cores, at most 12)")
    args = parser.parse_args()

    files = [w.replace("\\", "/") for w in args.what if w.endswith(".zig") or os.path.isfile(os.path.join(ROOT, w))]
    refs = [w for w in args.what if w.replace("\\", "/") not in files]
    if len(refs) > 1 or (refs and files):
        sys.exit("quick: give one git ref, or files, not both")
    changed = files or changed_since(refs[0] if refs else "HEAD")

    graph = Graph()
    whole = [rel for rel in changed if rel in EVERYTHING or rel.startswith("vendor/")]
    unknown = [rel for rel in changed if rel.endswith(".zig") and rel not in graph.text and rel not in whole and not rel.startswith("tools/")]
    zig_changed = [rel for rel in changed if rel in graph.text and rel not in whole]

    print("quick: %d changed file(s), %d of them Zig under src/ or tests/" % (len(changed), len(zig_changed)))
    command = ["zig", "build", "test", "-Dtest-jobs=%d" % args.jobs]
    if args.slow:
        command.append("-Dslow=true")
    if whole or unknown:
        print("quick: %s changes every test binary, so every test runs" % ", ".join(whole + unknown))
    else:
        reach = "all" if args.all else "wide" if args.wide else "near"
        selected = graph.select(zig_changed, reach)
        if not selected:
            print("quick: nothing to run")
            return 0
        seconds = recorded_seconds()
        cost = lambda rel: seconds.get(prefix(rel), 0.0)
        kept = [rel for rel in selected if rel.startswith("src/")]
        left_out = []
        spent = 0.0
        for rel in sorted((rel for rel in selected if rel.startswith("tests/")), key=cost):
            if args.budget > 0 and spent + cost(rel) > args.budget:
                left_out.append(rel)
                continue
            spent += cost(rel)
            kept.append(rel)
        total = sum(cost(rel) for rel in kept)
        print("quick: %d test file(s), reach %s, about %.0f s of tests in one process:" % (len(kept), reach, total))
        for rel in kept:
            print("  %6.1f s  %s" % (cost(rel), rel))
        if left_out:
            print("quick: %d suite(s) over the budget of %.0f s are left out, about %.0f s (--budget 0 runs them):" % (len(left_out), args.budget, sum(cost(rel) for rel in left_out)))
            for rel in left_out:
                print("  %6.1f s  %s" % (cost(rel), rel))
        selected = kept
        command += ["-Dtest-filter=" + prefix(rel) for rel in selected]
    if args.list:
        return 0

    started = time.monotonic()
    code = subprocess.run(command, cwd=ROOT).returncode
    print("quick: %s in %.1f s" % ("passed" if code == 0 else "FAILED", time.monotonic() - started))
    return code


if __name__ == "__main__":
    sys.exit(main())
