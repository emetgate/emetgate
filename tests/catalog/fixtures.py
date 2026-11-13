"""Deterministic fixture repositories for the catalog suite.

Every fixture is built from code below: no download, no randomness. Shared
fixtures are built once per run and must not be changed by a scenario; a
scenario that writes asks for a fresh copy.
"""

import json
import os
import subprocess

from harness import git

LONG = "\\\\?\\"

PKG = '{"name":"fx","version":"1.0.0","scripts":{"test":"node --test"}}\n'


def w(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data if isinstance(data, bytes) else data.encode("utf-8"))


def init(d):
    os.makedirs(d, exist_ok=True)
    git(d, "init", "-q", "-b", "main", check_rc=True)
    for k, v in (("user.email", "fx@example.invalid"), ("user.name", "fx"), ("core.autocrlf", "false"),
                 ("core.longpaths", "true"), ("commit.gpgsign", "false")):
        git(d, "config", k, v, check_rc=True)


def commit(d, msg="init"):
    """Commit whatever is on disk (git add -A); for small or special trees."""
    git(d, "add", "-A", check_rc=True)
    git(d, "commit", "-q", "--no-verify", "-m", msg, check_rc=True)


_tick = [0]


def commit_files(root, files, msg="init"):
    """Write files and commit exactly them on top of main through git
    fast-import: one pack instead of one loose object per file, which is
    minutes faster for thousands of files on Windows. The index is then reset
    to the new commit."""
    blobs = []
    for n, (rel, data) in enumerate(files.items(), 1):
        b = data if isinstance(data, bytes) else data.encode("utf-8")
        w(os.path.join(root, rel), b)
        blobs.append(b"blob\nmark :%d\ndata %d\n" % (n, len(b)) + b + b"\n")
    head = git(root, "rev-parse", "-q", "--verify", "refs/heads/main")
    _tick[0] += 1
    m = msg.encode("utf-8")
    cmd = [b"commit refs/heads/main\ncommitter fx <fx@example.invalid> %d +0000\ndata %d\n" % (1700000000 + _tick[0], len(m)) + m + b"\n"]
    if head:
        cmd.append(b"from %s\n" % head.encode())
    for n, rel in enumerate(files, 1):
        cmd.append(b"M 100644 :%d %s\n" % (n, rel.encode("utf-8")))
    p = subprocess.run(["git", "fast-import", "--quiet"], cwd=root, input=b"".join(blobs + cmd), capture_output=True)
    if p.returncode != 0:
        raise RuntimeError("git fast-import failed: %r" % p.stderr[:300])
    git(root, "reset", "-q", check_rc=True)


def repo(root, files, do_commit=True):
    init(root)
    if do_commit:
        commit_files(root, files)
    else:
        for rel, data in files.items():
            w(os.path.join(root, rel), data)
    return root


def junction(link, target):
    os.makedirs(target, exist_ok=True)
    p = subprocess.run(["cmd", "/c", "mklink", "/J", link, target], capture_output=True)
    if p.returncode != 0:
        raise RuntimeError("mklink /J failed: %r" % p.stderr)


# ------------------------------------------------------------------ builders


def build_huge(root):
    """5,000 tracked files in 50 x 10 folders, every one holds `needle`."""
    init(root)
    files = {}
    for i in range(5000):
        d = "pkg%02d/mod%d/" % (i % 50, (i // 50) % 10)
        if i % 2:
            files[d + "f%d.ts" % i] = "export function fn%d(x: number): number {\n  return x + %d; // needle\n}\n" % (i, i)
        else:
            files[d + "f%d.py" % i] = "def fn%d(x):\n    return x + %d  # needle\n" % (i, i)
    commit_files(root, files)


def build_mix(root, outside):
    """Mixed repo: CRLF, BOM, Turkish paths, big data files, a 20 MB log,
    a nested repo, untracked and modified files, junctions inside and outside."""
    init(root)
    m = root
    body = "".join("    v%d = %d  # needle\n    if v%d > 5:\n        v%d += 1\n" % (i, i, i, i) for i in range(1500))
    md = "# Root\n\n" + "".join("## Section %d\n\n" % i + ("para text needle\n" * 20) + "\n" for i in range(800))
    files = {
        "src/app.ts": "import { helper } from './util';\n\nexport class Cart {\n  items: number[] = [];\n  add(x: number): void {\n    this.items.push(helper(x));\n  }\n  total(): number {\n    return this.items.reduce((a, b) => a + b, 0);\n  }\n}\n",
        "src/util.ts": "export function helper(x: number): number {\n  return x * 2;\n}\n",
        "src/crlf.ts": "export function crlfFn(a: number): number {\r\n  const b = a + 1;\r\n  return b;\r\n}\r\n",
        "src/bom.py": "\ufeffdef bom_fn(x):\n    return x + 1\n",
        "src/çalışma/şifre_ğüöı.py": "def şifre_kontrol(parola):\n    \"\"\"Parolayı doğrular: ığüşöç İĞÜŞÖÇ\"\"\"\n    return len(parola) > 8\n",
        "notes/türkçe.md": "# Başlık\n\nİçerik ğüşıöç.\n\n## Alt başlık\n\nDaha fazla.\n",
        "src/lib.rs": "fn main() {\n    println!(\"hi\");\n}\n",
        "data/bin.dat": bytes(range(256)) * 64,
        "data/longline.txt": "x" * 300000 + " needle\nshort line\n",
        "src/bigfn.py": "def big_function(a):\n" + body + "    return a\n\ndef small_after():\n    return 2\n",
        "docs/big.md": md,
        "data/big.json": json.dumps({"key%d" % i: {"a": i, "b": [i] * 50, "s": "needle" * 10} for i in range(3000)}, indent=1),
        "data/wide.json": json.dumps({"root": {"k%d" % i: i for i in range(20000)}}),
        "data/huge.log": "".join("2026-11-13 INFO something happened needle id=%06d\n" % i for i in range(400000)),
        "data/many.txt": "".join("line %d needle needle\n" % i for i in range(50000)),
        ".gitignore": "ignored/\n*.secret\n",
    }
    for i in range(2500):
        files["many/sub%d/file_%05d.txt" % (i % 25, i)] = "needle %d\n" % i
    commit_files(m, files)
    w(os.path.join(m, "ignored/ign.py"), "def ignored_fn():\n    return 'needle'\n")
    w(os.path.join(m, "src/untracked.ts"), "export function untrackedFn() { return 'needle'; }\n")
    w(os.path.join(m, "src/util.ts"), "export function helper(x: number): number {\n  return x * 3; // modified\n}\n")
    n = os.path.join(m, "nested")
    init(n)
    commit_files(n, {"inner.py": "def inner_fn():\n    return 'needle'\n"})
    junction(os.path.join(m, "junc"), os.path.join(m, "src"))
    w(os.path.join(outside, "secret.txt"), "OUTSIDE SECRET needle\n")
    junction(os.path.join(m, "junc_out"), outside)


def build_minjs(root):
    """A small repo with one 300 KB single-line minified file of 15,000 functions."""
    repo(root, {
        "src/app.ts": "export function appMain(x: number): number {\n  return x + 1;\n}\n",
        "src/min.js": "var a=1;" + ";".join("function q%d(){return %d}" % (i, i) for i in range(15000)) + "\n",
    })


def build_hist(root):
    """History for the git tools: 30 commits, a 100,000-line unstaged rewrite,
    and a modified file with a Turkish name."""
    init(root)
    for i in range(30):
        commit_files(root, {"a.py": "".join("def f%d():\n    return %d\n\n" % (j, j + i) for j in range(50))}, "commit %d" % i)
    commit_files(root, {"big.txt": "".join("line %d\n" % i for i in range(100000)),
                        "notes/türkçe.md": "# Başlık\n\nbir\n"}, "big add")
    w(os.path.join(root, "big.txt"), "".join("LINE %d changed\n" % i for i in range(100000)))
    w(os.path.join(root, "notes/türkçe.md"), "# Başlık\n\niki\n")


def build_small(root):
    """A small read fixture a scenario may change (R4 freshness)."""
    repo(root, {
        "src/app.ts": "export class Cart {\n  add(x: number): number {\n    return x + 1;\n  }\n}\n",
        "src/util.ts": "export function helper(x: number): number {\n  return x * 2;\n}\n",
        "notes.md": "# Notes\n\n## Part\n\nfirst version\n",
        "data.json": '{"name":"first","n":1}\n',
    })


def build_node(root):
    """Node project with node --test, CRLF/BOM/Turkish files, docs and an ignored folder."""
    repo(root, {
        "package.json": PKG,
        "src/math.js": "function add(a, b) {\n  return a + b;\n}\n\nfunction sub(a, b) {\n  return a - b;\n}\n\nfunction mul(a, b) {\n  // multiply\n  return a * b;\n}\n\nmodule.exports = { add, sub, mul };\n",
        "src/dup.js": "const x = 1;\nconst y = 1;\nfunction one() { return 1; }\nfunction uno() { return 1; }\nmodule.exports = { one, uno, x, y };\n",
        "test/math.test.js": "const test = require('node:test');\nconst assert = require('node:assert');\nconst { add, sub } = require('../src/math.js');\ntest('add', () => assert.strictEqual(add(2, 3), 5));\ntest('sub', () => assert.strictEqual(sub(5, 3), 2));\n",
        "src/crlf.js": "function crlf(a) {\r\n  return a + 1;\r\n}\r\nmodule.exports = { crlf };\r\n",
        "src/bom.js": "\ufefffunction bom(a) {\n  return a + 2;\n}\nmodule.exports = { bom };\n",
        "src/türkçe/çalışma.js": "// Türkçe açıklama: şğüöçı\nfunction selam(ad) {\n  return 'Merhaba ' + ad + ' — günaydın';\n}\nmodule.exports = { selam };\n",
        "README.md": "# Title\n\nIntro\n\n## Usage\n\nRun it.\n",
        "config.json": '{"name":"n1","deps":{"a":"1.0.0"},"n":3}\n',
        "notes.txt": "line1\nline2\nline3\n",
        ".gitignore": "ignored/\n",
        "ignored/keep.txt": "ignored\n",
    })


def build_gate(root):
    """Node project whose test exercises lib.js."""
    repo(root, {
        "package.json": PKG,
        "lib.js": "function f(a) {\n  return a + 1;\n}\nfunction g(a) {\n  return a * 2;\n}\nmodule.exports = { f, g };\n",
        "test/t.test.js": "const test = require('node:test');\nconst assert = require('node:assert');\nconst { f, g } = require('../lib.js');\ntest('f', () => assert.strictEqual(f(1), 2));\ntest('g', () => assert.strictEqual(g(2), 4));\n",
        "hang.js": "setInterval(() => {}, 1000);\n",
        "slow.js": "setTimeout(() => console.log('done'), 4000);\n",
        "slow10.js": "setTimeout(() => console.log('done'), 10000);\n",
    })


def build_notest(root):
    """A project with no test anywhere."""
    repo(root, {
        "lib.js": "function f(a) {\n  return a + 1;\n}\nmodule.exports = { f };\n",
        "README.md": "# x\n",
    })


def build_python(root):
    """Python project tested with the standard library's unittest."""
    repo(root, {
        "pkg/__init__.py": "",
        "pkg/m.py": "def f(x):\n    if x:\n        a = 1\n    b = 2\n    return x + b\n\n\ndef g():\n    return 1\n",
        # No test imports q.py: only the reparse step can catch a broken edit there.
        "pkg/q.py": "def f(x):\n    if x:\n        a = 1\n    b = 2\n    return x\n\n\ndef g():\n    return 1\n",
        "test_m.py": "import unittest\nfrom pkg.m import f, g\n\n\nclass T(unittest.TestCase):\n    def test_f(self):\n        self.assertEqual(f(1), 3)\n\n    def test_g(self):\n        self.assertEqual(g(), 1)\n\n\nif __name__ == '__main__':\n    unittest.main()\n",
    })


def build_inert(root):
    """Tests that read README.md and LICENSE."""
    repo(root, {
        "package.json": PKG,
        "README.md": "# R\n\n## Install\n\nnpm i\n",
        "LICENSE": "MIT\n",
        "lib.js": "exports.f = () => 1;\n",
        "test/t.test.js": "const a = require('node:assert');\nconst fs = require('fs');\nconst t = require('node:test');\n"
                          "t('readme', () => a.ok(fs.readFileSync('README.md', 'utf8').includes('Install')));\n"
                          "t('license', () => a.ok(fs.readFileSync('LICENSE', 'utf8').includes('MIT')));\n"
                          "t('lib', () => a.strictEqual(require('../lib.js').f(), 1));\n",
    })


def build_fuzzy(root):
    """Files for the whitespace/comment-insensitive old_string match."""
    repo(root, {
        "package.json": PKG,
        "a.js": "function a() {\n  first();\n  // IMPORTANT: keep this note\n  second();\n}\nfunction first() {}\nfunction second() {}\nfunction third() {}\nmodule.exports = { a };\n",
        "b.js": "function mul(a, b) {\n  // multiply\n  return a * b;\n}\nmodule.exports = { mul };\n",
        "conf.yaml": "alpha: 1\n# do not remove: license key below\nbeta: 2\n",
        "p.py": "def f(x):\n    if x:\n        a = 1\n    b = 2\n    return x\n",
        "test/t.test.js": "require('node:test')('ok', () => {});\n",
    })


def build_rules(root):
    """Node project; the scenario adds rules with `emetgate rule add`."""
    repo(root, {
        "package.json": PKG,
        "src/lib.js": "function f(a) {\n  return a + 1;\n}\nmodule.exports = { f };\n",
        "src/b.js": "function b() { return 2; }\nmodule.exports = { b };\n",
        "config/frozen.json": '{"a":1}\n',
        "test/t.test.js": "require('node:test')('ok', () => {});\n",
    })


def build_nested(root):
    """Outer node project with an inner repository the outer one ignores."""
    repo(root, {
        "package.json": PKG,
        "lib.js": "exports.f = () => 1;\n",
        "test/t.test.js": "const a = require('node:assert');\nrequire('node:test')('outer', () => a.strictEqual(require('../lib.js').f(), 1));\n",
        ".gitignore": "inner/\n",
    })
    inner = os.path.join(root, "inner")
    repo(inner, {"lib.js": "exports.g = () => 2;\n"})


def build_merge(root):
    """A merge stopped on a conflict."""
    init(root)
    w(os.path.join(root, "src/calc.py"), "def calc():\n    return 1\n")
    commit(root)
    git(root, "checkout", "-q", "-b", "other", check_rc=True)
    w(os.path.join(root, "src/calc.py"), "def calc():\n    return 2\n")
    commit(root, "other")
    git(root, "checkout", "-q", "main", check_rc=True)
    w(os.path.join(root, "src/calc.py"), "def calc():\n    return 3\n")
    commit(root, "main")
    git(root, "merge", "-q", "other")  # stops on the conflict


def build_longpath(root):
    """A tracked file whose full path is over 260 characters."""
    init(root)
    deep = LONG + os.path.join(root, *["d%02d_padding" % i for i in range(24)])
    w(os.path.join(deep, "deep.py"), "def deep_fn():\n    return 'needle'\n")
    w(os.path.join(root, "top.py"), "def top():\n    return 1\n")
    commit(root)


BUILDERS = {
    "huge": build_huge,
    "mix": build_mix,
    "minjs": build_minjs,
    "hist": build_hist,
    "small": build_small,
    "node": build_node,
    "gate": build_gate,
    "notest": build_notest,
    "python": build_python,
    "inert": build_inert,
    "fuzzy": build_fuzzy,
    "rules": build_rules,
    "nested": build_nested,
    "merge": build_merge,
    "longpath": build_longpath,
}


class Fixtures:
    def __init__(self, work):
        self.work = work
        self.made = {}
        self.counter = 0

    def _build(self, name, root):
        if name == "mix":
            build_mix(root, os.path.join(self.work, "outside", os.path.basename(root)))
        else:
            BUILDERS[name](root)

    def shared(self, name):
        if name not in self.made:
            root = os.path.join(self.work, "fx", name)
            self._build(name, root)
            self.made[name] = root
        return self.made[name]

    def fresh(self, name):
        self.counter += 1
        root = os.path.join(self.work, "fresh", "%s%03d" % (name, self.counter))
        self._build(name, root)
        return root
