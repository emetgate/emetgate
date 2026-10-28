import argparse
import csv
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
WORK = HERE / "work"
TASKS = HERE / "tasks"
RESULTS = HERE / "results.csv"
ESLINT_SRC = Path(r"C:\Users\ugur\Desktop\projects\emetgate\eval\eslint-test")
CLAUDE_BIN = Path(os.environ.get("APPDATA", "")) / "npm" / "node_modules" / "@anthropic-ai" / "claude-code" / "bin"
ESLINT_TEST = "node node_modules/mocha/bin/mocha.js tests/lib/rules/no-alert.js"
CHECKS = HERE / "checks"
PYREPO_SRC = HERE / "repos" / "more-itertools"
PLAIN_TOOLS = ["Write", "Edit", "Read", "Glob", "Grep", "Bash(node:*)", "Bash(npm:*)", "Bash(git:*)"]
PY_TOOLS = ["Bash(python:*)", "Bash(py:*)", "Bash(pip:*)", "Bash(pytest:*)", "Bash(uv:*)"]
VENV_TOOLS = ["Bash(.venv/Scripts/python:*)", "Bash(.venv/Scripts/python.exe:*)", "Bash(.venv/Scripts/pip:*)",
              "Bash(.venv/Scripts/pip.exe:*)", "Bash(.venv/Scripts/wordstat:*)", "Bash(.venv/Scripts/wordstat.exe:*)",
              "Bash(./.venv/Scripts/python:*)", "Bash(./.venv/Scripts/python.exe:*)", "Bash(./.venv/Scripts/pip:*)",
              "Bash(./.venv/Scripts/wordstat:*)", "Bash(./.venv/Scripts/wordstat.exe:*)"]
PY_REPO_TEST = "python -m pytest -q tests/test_more.py"
REFACTOR_OLD, REFACTOR_NEW = "isSpecificId", "isIdentifierWithName"
REFACTOR_TEST = "node node_modules/mocha/bin/mocha.js " + " ".join(
    ["tests/lib/rules/%s.js" % r for r in ["consistent-return", "no-eval", "no-implied-eval", "no-magic-numbers",
                                           "prefer-numeric-literals", "use-isnan"]] + ["tests/lib/rules/utils/ast-utils.js"])
WINDOWED_BUG = (b"padding = (fillvalue,) * (n - 1 if step >= n else step - 1)",
                b"padding = (fillvalue,) * (n - 1 if step >= n else step - 2)")
PEEKABLE_BUG = (b"        if (start < 0) or (stop < 0):", b"        if (start < 0) and (stop < 0):")
CS_SRC = HERE / "repos" / "cs-inventory"
CS_TOOLS = ["Bash(dotnet:*)"]
DOTNET_ENV = {"DOTNET_CLI_UI_LANGUAGE": "en", "DOTNET_CLI_TELEMETRY_OPTOUT": "1", "DOTNET_NOLOGO": "1"}
HISTORY_FN = "sample"
SEARCH_FN = "consume"
PY_RENAME = ("always_iterable", "ensure_iterable")
CS_RENAME_TYPE = ("StockItem", "InventoryItem")
WORKFLOW_BRANCH, WORKFLOW_MSG = "release-11.3.0", "Bump version to 11.3.0"

TASK_CFG = {
    "todo": {"max_turns": 100, "timeout": 2400, "kind": "scratch", "test": "npm test"},
    "eslint": {"max_turns": 100, "timeout": 2400, "kind": "eslint", "test": ESLINT_TEST},
    "read": {"max_turns": 60, "timeout": 1800, "kind": "eslint", "test": None},
    "py-scratch": {"max_turns": 100, "timeout": 2400, "kind": "scratch", "test": "python -m pytest -q", "tools": PY_TOOLS},
    "ts-scratch": {"max_turns": 100, "timeout": 2400, "kind": "scratch", "test": "npm test", "tools": ["Bash(npx:*)"]},
    "cs-scratch": {"max_turns": 100, "timeout": 3000, "kind": "scratch", "test": "dotnet test", "tools": ["Bash(dotnet:*)"]},
    "py-existing": {"max_turns": 100, "timeout": 2400, "kind": "pyrepo", "test": PY_REPO_TEST, "tools": PY_TOOLS},
    "bugfix": {"max_turns": 100, "timeout": 2400, "kind": "pyrepo-bug", "test": PY_REPO_TEST, "tools": PY_TOOLS},
    "multi-file-refactor": {"max_turns": 100, "timeout": 2400, "kind": "eslint", "test": REFACTOR_TEST},
    "git-history": {"max_turns": 60, "timeout": 1200, "kind": "pyclone", "test": None},
    "git-workflow": {"max_turns": 60, "timeout": 1200, "kind": "pyclone", "test": None},
    "search": {"max_turns": 60, "timeout": 1200, "kind": "pyclone", "test": None},
    "py-rename": {"max_turns": 100, "timeout": 2400, "kind": "pyclone", "test": "python -m pytest -q tests", "tools": PY_TOOLS},
    "debug-failing-test": {"max_turns": 100, "timeout": 2400, "kind": "pyarchive", "test": "python -m pytest -q tests",
                           "tools": PY_TOOLS, "bug": ("more_itertools/more.py", PEEKABLE_BUG)},
    "cs-existing": {"max_turns": 100, "timeout": 3000, "kind": "csrepo", "test": "dotnet test", "tools": CS_TOOLS},
    "cs-rename": {"max_turns": 100, "timeout": 3000, "kind": "csrepo", "test": "dotnet test", "tools": CS_TOOLS},
    "react-vite": {"max_turns": 100, "timeout": 2400, "kind": "scratch", "test": "npm test", "tools": ["Bash(npx:*)"]},
    "fastapi": {"max_turns": 100, "timeout": 2400, "kind": "scratch", "test": None, "tools": PY_TOOLS + VENV_TOOLS},
    "aspnet-webapi": {"max_turns": 100, "timeout": 3000, "kind": "scratch", "test": "dotnet test", "tools": CS_TOOLS},
    "express-api": {"max_turns": 100, "timeout": 2400, "kind": "scratch", "test": "npm test", "tools": ["Bash(npx:*)"]},
    "py-package": {"max_turns": 100, "timeout": 2400, "kind": "scratch", "test": None, "tools": PY_TOOLS + VENV_TOOLS},
}

FIELDS = ["date", "task", "mode", "emetgate_sha", "claude_version", "setup", "exit", "subtype", "duration_s",
          "turns", "api_calls", "tool_calls", "failed_tool_calls", "input_tokens", "cache_write_tokens",
          "cache_read_tokens", "output_tokens", "total_tokens", "cost_usd", "success", "verify", "workspace", "transcript",
          "tool", "tool_version"]

MODES = ["plain", "gate", "serena", "cbm", "rtk"]
TOOLS_DIR = HERE.parent / "tools"
SERENA_DIR = TOOLS_DIR / "serena"
SERENA_EXE = SERENA_DIR / "bin" / "serena.exe"
SERENA_HOOKS = SERENA_DIR / "bin" / "serena-hooks.exe"
SERENA_HOME = SERENA_DIR / "home"
CBM_EXE = Path(os.environ.get("CBM_EXE", Path.home() / ".local" / "bin" / "codebase-memory-mcp.exe"))
RTK_DIR = TOOLS_DIR / "rtk"
RTK_EXE = RTK_DIR / "rtk.exe"
RTK_MD = TOOLS_DIR / "rtk-init-sandbox" / "claude" / "RTK.md"
TOOL_NAME = {"plain": "", "gate": "emetgate", "serena": "serena", "cbm": "codebase-memory-mcp", "rtk": "rtk"}


def sh(cmd, cwd=None, timeout=600, env=None):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, encoding="utf-8", errors="replace",
                       timeout=timeout, env=env, stdin=subprocess.DEVNULL)
    return p.returncode, (p.stdout or "") + (p.stderr or "")


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()[:12]


def child_env(mode="plain", ws=None):
    env = dict(os.environ)
    if CLAUDE_BIN.is_dir():
        env["PATH"] = str(CLAUDE_BIN) + os.pathsep + env.get("PATH", "")
    if mode == "serena":
        env["PATH"] = str(SERENA_DIR / "bin") + os.pathsep + env["PATH"]
        env["SERENA_HOME"] = str(SERENA_HOME)
        env["MCP_TIMEOUT"] = "120000"
    elif mode == "cbm":
        env["PATH"] = str(CBM_EXE.parent) + os.pathsep + env["PATH"]
    elif mode == "rtk":
        env["PATH"] = str(RTK_DIR) + os.pathsep + env["PATH"]
        env["RTK_SUPPRESS_HOOK_WARNING"] = "1"
        if ws is not None:
            env["RTK_DB_PATH"] = str(ws.parent / (ws.name + ".rtk.db"))
            env["RTK_TEE_DIR"] = str(ws.parent / (ws.name + ".rtk-tee"))
    return env


def tool_version(mode):
    try:
        if mode == "serena":
            out = sh([str(SERENA_EXE), "--version"], env=child_env("serena"))[1]
            commit = ""
            direct = SERENA_DIR / "tools" / "serena-agent" / "Lib" / "site-packages"
            for p in direct.glob("serena_agent-*.dist-info/direct_url.json"):
                commit = json.loads(p.read_text(encoding="utf-8")).get("vcs_info", {}).get("commit_id", "")[:12]
            return (out.strip().splitlines() or [""])[-1] + (" @" + commit if commit else "")
        if mode == "cbm":
            return sh([str(CBM_EXE), "--version"])[1].strip().splitlines()[-1]
        if mode == "rtk":
            return sh([str(RTK_EXE), "--version"])[1].strip()
    except Exception as e:
        return "error: %r" % e
    return ""


def claude_exe():
    exe = CLAUDE_BIN / "claude.exe"
    return str(exe) if exe.is_file() else shutil.which("claude")


def junction(link, target):
    rc, out = sh(["cmd", "/c", "mklink", "/J", str(link), str(target)])
    if rc != 0:
        raise RuntimeError("mklink failed: " + out)


def unlink_junctions(root):
    for dirpath, dirnames, _ in os.walk(root):
        for d in list(dirnames):
            p = Path(dirpath) / d
            if os.path.islink(p) or (hasattr(os.path, "isjunction") and os.path.isjunction(p)):
                sh(["cmd", "/c", "rmdir", str(p)])
                dirnames.remove(d)


def remove_tree(root):
    unlink_junctions(root)

    def force(fn, path, _):
        os.chmod(path, 0o666)
        fn(path)

    shutil.rmtree(root, **({"onexc": force} if sys.version_info >= (3, 12) else {"onerror": force}))


def freeze_exe(src):
    digest = sha(src)
    dst_dir = WORK / "exe" / digest
    dst = dst_dir / "emetgate.exe"
    if not dst.exists():
        dst_dir.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
    return dst, digest


GATE_EXTRA = []


def write_mcp(ws, exe, test):
    args = ["mcp"] + (["--test", test] if test else []) + GATE_EXTRA
    cfg = {"mcpServers": {"emetgate": {"command": str(exe).replace("\\", "/"), "args": args}}}
    (ws / ".mcp.json").write_text(json.dumps(cfg), encoding="utf-8")


def git_exclude(ws, patterns):
    ex = ws / ".git" / "info" / "exclude"
    ex.parent.mkdir(parents=True, exist_ok=True)
    with open(ex, "a", encoding="utf-8") as f:
        f.write("\n" + "\n".join(patterns) + "\n")


def commit_all(ws, msg="init"):
    sh(["git", "add", "-A"], cwd=ws)
    sh(["git", "-c", "user.name=bench", "-c", "user.email=bench@local", "commit", "-qm", msg, "--allow-empty"], cwd=ws)


def gate_files(ws, exe, test):
    write_mcp(ws, exe, test)
    git_exclude(ws, [".mcp.json", ".emetgate/"])
    return " + .mcp.json" + (" --test '" + test + "'" if test else " (no --test)") + "".join(" " + x for x in GATE_EXTRA)


CBM_PROJECTS = {}


def cbm_index(ws):
    t0 = time.time()
    rc, out = sh([str(CBM_EXE), "cli", "index_repository", "--repo-path", str(ws)], timeout=1800)
    m = re.search(r'\{"project":.*\}', out)
    info = json.loads(m.group(0)) if m else {}
    if rc != 0 or info.get("status") != "indexed":
        raise RuntimeError("cbm index failed: " + out[-500:])
    CBM_PROJECTS[str(ws)] = info["project"]
    return " + cbm `cli index_repository` pre-index (%d nodes, %d edges, %ds)" % (info.get("nodes", 0), info.get("edges", 0), round(time.time() - t0))


def tool_files(task, mode, ws):
    has_git = (ws / ".git").is_dir()
    if mode == "serena":
        if has_git:
            git_exclude(ws, [".serena/"])
        return " + serena MCP (start-mcp-server --context claude-code --project <ws>, dashboard off) + serena-hooks remind/auto-approve/activate/cleanup via --settings"
    if mode == "cbm":
        if has_git:
            git_exclude(ws, [".codebase-memory/"])
        idx = cbm_index(ws) if any(ws.iterdir()) else " (empty dir, nothing to pre-index)"
        return " + cbm MCP" + idx + " + user-global cbm hooks"
    if mode == "rtk":
        return " + rtk PreToolUse(Bash) hook `rtk hook claude` via --settings + RTK.md via --append-system-prompt + Bash(rtk:*) allowed"
    return ""


def prepare_pyrepo(task, mode, ws, exe):
    cfg = TASK_CFG[task]
    if not (PYREPO_SRC / ".git").is_dir():
        raise RuntimeError("missing %s (git clone https://github.com/more-itertools/more-itertools.git there)" % PYREPO_SRC)
    rev = sh(["git", "rev-parse", "--short", "HEAD"], cwd=PYREPO_SRC)[1].strip()
    if cfg["kind"] == "pyrepo":
        rc, out = sh(["git", "clone", "-q", "--shared", str(PYREPO_SRC), str(ws)], timeout=900)
        if rc != 0:
            raise RuntimeError("clone failed: " + out)
        setup = "clone --shared more-itertools@" + rev
    else:
        ws.mkdir(parents=True)
        arc = ws.parent / (ws.name + ".zip")
        rc, out = sh(["git", "archive", "--format=zip", "-o", str(arc), "HEAD"], cwd=PYREPO_SRC)
        if rc != 0:
            raise RuntimeError("archive failed: " + out)
        with zipfile.ZipFile(arc) as z:
            z.extractall(ws)
        arc.unlink()
        target = ws / "more_itertools" / "more.py"
        src = target.read_bytes()
        if src.count(WINDOWED_BUG[0]) != 1:
            raise RuntimeError("bug anchor not found in more.py")
        target.write_bytes(src.replace(*WINDOWED_BUG))
        sh(["git", "init", "-q"], cwd=ws)
        commit_all(ws)
        setup = "git archive more-itertools@" + rev + " + planted windowed bug + fresh one-commit history"
    if mode == "gate":
        setup += gate_files(ws, exe, cfg["test"])
    return setup + tool_files(task, mode, ws)


def truth_file(ws):
    return ws.parent / (ws.name + ".truth.json")


def load_truth(ws):
    return json.loads(truth_file(ws).read_text(encoding="utf-8"))


def git_out(ws, *args):
    rc, out = sh(["git", *args], cwd=ws, timeout=600)
    if rc != 0:
        raise RuntimeError("git %s failed: %s" % (" ".join(args), out[-300:]))
    return out.strip()


def truth_history(ws):
    commit = git_out(ws, "log", "--reverse", "--format=%H", "-S", "def %s(" % HISTORY_FN, "--", "more_itertools").split()[0]
    numstat = [l.split("\t") for l in git_out(ws, "show", "--format=", "--numstat", commit).splitlines() if l.strip()]
    return {"commit": commit, "author": git_out(ws, "show", "-s", "--format=%an", commit),
            "subject": git_out(ws, "show", "-s", "--format=%s", commit),
            "files": [[int(a), int(d), p] for a, d, p in numstat]}


def python_files(ws):
    return [f for f in git_out(ws, "ls-files", "*.py").split() if f]


def truth_search(ws):
    import ast
    calls, defs = set(), set()
    for f in python_files(ws):
        tree = ast.parse((ws / f).read_text(encoding="utf-8"))
        for n in ast.walk(tree):
            if isinstance(n, ast.Call):
                fn = n.func
                if (isinstance(fn, ast.Name) and fn.id == SEARCH_FN) or (isinstance(fn, ast.Attribute) and fn.attr == SEARCH_FN):
                    calls.add("%s:%d" % (f, n.lineno))
            elif isinstance(n, ast.FunctionDef) and n.name == SEARCH_FN:
                defs.add("%s:%d" % (f, n.lineno))
    mentions = set()
    for l in git_out(ws, "grep", "-nw", SEARCH_FN, "--", "*.py").splitlines():
        path, line = l.split(":", 2)[:2]
        mentions.add("%s:%s" % (path, line))
    return {"calls": sorted(calls), "defs": sorted(defs), "decoys": sorted(mentions - calls)}


TRUTH = {"git-history": truth_history, "search": truth_search}


def prepare_pyclone(task, mode, ws, exe):
    cfg = TASK_CFG[task]
    if not (PYREPO_SRC / ".git").is_dir():
        raise RuntimeError("missing %s" % PYREPO_SRC)
    rc, out = sh(["git", "clone", "-q", "--shared", str(PYREPO_SRC), str(ws)], timeout=900)
    if rc != 0:
        raise RuntimeError("clone failed: " + out)
    sh(["git", "config", "user.name", "bench"], cwd=ws)
    sh(["git", "config", "user.email", "bench@local"], cwd=ws)
    truth = TRUTH[task](ws) if task in TRUTH else {}
    truth["head"] = git_out(ws, "rev-parse", "HEAD")
    truth["branch"] = git_out(ws, "rev-parse", "--abbrev-ref", "HEAD")
    truth_file(ws).write_text(json.dumps(truth, indent=1), encoding="utf-8")
    setup = "clone --shared more-itertools@" + truth["head"][:7] + (" + ground truth from git/ast" if task in TRUTH else "")
    if mode == "gate":
        setup += gate_files(ws, exe, cfg["test"])
    return setup + tool_files(task, mode, ws)


def prepare_pyarchive(task, mode, ws, exe):
    cfg = TASK_CFG[task]
    rev = sh(["git", "rev-parse", "--short", "HEAD"], cwd=PYREPO_SRC)[1].strip()
    ws.mkdir(parents=True)
    arc = ws.parent / (ws.name + ".zip")
    rc, out = sh(["git", "archive", "--format=zip", "-o", str(arc), "HEAD"], cwd=PYREPO_SRC)
    if rc != 0:
        raise RuntimeError("archive failed: " + out)
    with zipfile.ZipFile(arc) as z:
        z.extractall(ws)
    arc.unlink()
    rel, (old, new) = cfg["bug"]
    target = ws / rel
    src = target.read_bytes()
    if src.count(old) != 1:
        raise RuntimeError("bug anchor not found in " + rel)
    target.write_bytes(src.replace(old, new))
    sh(["git", "init", "-q"], cwd=ws)
    commit_all(ws)
    setup = "git archive more-itertools@" + rev + " + planted bug in " + rel + " + fresh one-commit history"
    if mode == "gate":
        setup += gate_files(ws, exe, cfg["test"])
    return setup + tool_files(task, mode, ws)


def prepare_csrepo(task, mode, ws, exe):
    shutil.copytree(CS_SRC, ws, ignore=shutil.ignore_patterns("bin", "obj", ".vs", "TestResults"))
    sh(["git", "init", "-q"], cwd=ws)
    commit_all(ws)
    setup = "copy repos/cs-inventory + fresh one-commit history"
    if mode == "gate":
        setup += gate_files(ws, exe, TASK_CFG[task]["test"])
    return setup + tool_files(task, mode, ws)


EXTRA_PREP = {"pyclone": prepare_pyclone, "pyarchive": prepare_pyarchive, "csrepo": prepare_csrepo}


def prepare(task, mode, ws, exe):
    kind = TASK_CFG[task]["kind"]
    if kind in EXTRA_PREP:
        return EXTRA_PREP[kind](task, mode, ws, exe)
    if kind.startswith("pyrepo"):
        return prepare_pyrepo(task, mode, ws, exe)
    ws.mkdir(parents=True)
    if kind == "scratch":
        return "empty dir (bare lockdown)" if mode == "gate" else "empty dir" + tool_files(task, mode, ws)
    ws.rmdir()
    rc, out = sh(["git", "clone", "-q", "-c", "core.longpaths=true", "--shared", str(ESLINT_SRC), str(ws)], timeout=900)
    if rc != 0:
        raise RuntimeError("clone failed: " + out)
    junction(ws / "node_modules", ESLINT_SRC / "node_modules")
    setup = "clone --shared + node_modules junction"
    if mode == "gate":
        setup += gate_files(ws, exe, TASK_CFG[task]["test"])
    return setup + tool_files(task, mode, ws)


def posix(p):
    return str(p).replace("\\", "/")


def hook(cmd):
    return [{"matcher": "", "hooks": [{"type": "command", "command": cmd}]}]


def mode_config(mode, ws):
    side = lambda suffix: ws.parent / (ws.name + suffix)
    servers, settings, tools, extra = {}, None, [], []
    if mode == "serena":
        servers["serena"] = {"command": posix(SERENA_EXE),
                             "args": ["start-mcp-server", "--context", "claude-code", "--project", str(ws),
                                      "--open-web-dashboard", "false"],
                             "env": {"SERENA_HOME": str(SERENA_HOME)}}
        h = posix(SERENA_HOOKS)
        settings = {"hooks": {
            "PreToolUse": hook(h + " remind --client=claude-code")
            + [{"matcher": "mcp__serena__*", "hooks": [{"type": "command", "command": h + " auto-approve --client=claude-code"}]}],
            "SessionStart": hook(h + " activate --client=claude-code"),
            "SessionEnd": hook(h + " cleanup --client=claude-code")}}
        tools = ["mcp__serena", "mcp__serena__*"]
    elif mode == "cbm":
        servers["codebase-memory-mcp"] = {"command": posix(CBM_EXE)}
        tools = ["mcp__codebase-memory-mcp", "mcp__codebase-memory-mcp__*"]
    elif mode == "rtk":
        settings = {"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": posix(RTK_EXE) + " hook claude"}]}]}}
        tools = ["Bash(rtk:*)"]
        extra = ["--append-system-prompt", RTK_MD.read_text(encoding="utf-8")]
    mcp = side(".mcp-%s.json" % ("empty" if not servers else mode))
    mcp.write_text(json.dumps({"mcpServers": servers}), encoding="utf-8")
    if settings:
        sp = side(".settings.json")
        sp.write_text(json.dumps(settings, indent=1), encoding="utf-8")
        extra = ["--settings", str(sp)] + extra
    return mcp, tools, extra


def command(task, mode, prompt, exe, ws):
    turns = str(TASK_CFG[task]["max_turns"])
    common = ["--output-format", "stream-json", "--verbose", "--max-turns", turns]
    if mode != "gate":
        mcp, mode_tools, extra = mode_config(mode, ws)
        tools = PLAIN_TOOLS + TASK_CFG[task].get("tools", []) + mode_tools
        return [claude_exe(), "-p", prompt, "--permission-mode", "acceptEdits", "--allowedTools", *tools,
                "--mcp-config", str(mcp), "--strict-mcp-config", *extra, *common]
    return [str(exe), "lockdown", "--no-marks", "-p", prompt, "--permission-mode", "auto", *common]


def parse(transcript):
    r, msg_ids, calls, failed, answer = {}, set(), 0, 0, ""
    with open(transcript, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                d = json.loads(line)
            except Exception:
                continue
            t = d.get("type")
            if t == "assistant":
                m = d.get("message", {})
                msg_ids.add(m.get("id") or len(msg_ids))
                calls += sum(1 for c in m.get("content", []) if c.get("type") == "tool_use")
            elif t == "user":
                content = d.get("message", {}).get("content", [])
                for c in content if isinstance(content, list) else []:
                    if isinstance(c, dict) and c.get("type") == "tool_result":
                        x = c.get("content")
                        x = "".join(i.get("text", "") for i in x if isinstance(i, dict)) if isinstance(x, list) else str(x)
                        if c.get("is_error") or '"status":"error"' in x or '"status":"rejected"' in x or x.startswith("Missing"):
                            failed += 1
            elif t == "result":
                r = d
                answer = d.get("result") or ""
    u = r.get("usage", {})
    vals = [u.get(k, 0) or 0 for k in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens")]
    return {
        "subtype": r.get("subtype", "none"),
        "turns": r.get("num_turns", ""),
        "api_calls": len(msg_ids),
        "tool_calls": calls,
        "failed_tool_calls": failed,
        "input_tokens": vals[0],
        "cache_write_tokens": vals[1],
        "cache_read_tokens": vals[2],
        "output_tokens": vals[3],
        "total_tokens": sum(vals),
        "cost_usd": round(r.get("total_cost_usd", 0) or 0, 4),
    }, answer


def verify_todo(ws):
    notes = []
    tests_ok = False
    if not (ws / "package.json").exists():
        notes.append("no package.json")
    else:
        rc = subprocess.run("npm test", cwd=ws, shell=True, capture_output=True, stdin=subprocess.DEVNULL, timeout=300).returncode
        tests_ok = rc == 0
        notes.append("npm test " + ("ok" if tests_ok else "FAIL"))
    smoke_ok = False
    entry = ws / "todo.js"
    if entry.exists():
        tmp = Path(tempfile.mkdtemp(prefix="todo-smoke-"))
        try:
            dst = tmp / "app"
            shutil.copytree(ws, dst, ignore=shutil.ignore_patterns("node_modules", ".git", ".emetgate", "todos.json"))
            run = lambda *a: sh(["node", "todo.js", *a], cwd=dst, timeout=60)
            run("add", "benchitem-xyz")
            _, listed = run("list")
            line = next((l for l in listed.splitlines() if "benchitem-xyz" in l), "")
            m = re.search(r"\d+", line)
            if m:
                tid = m.group(0)
                run("done", tid)
                _, listed2 = run("list")
                run("remove", tid)
                _, listed3 = run("list")
                smoke_ok = "benchitem-xyz" not in listed3 and listed2 != listed
            notes.append("cli " + ("ok" if smoke_ok else "FAIL"))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    else:
        notes.append("no todo.js")
    return tests_ok and smoke_ok, "; ".join(notes)


def verify_eslint(ws):
    rc, out = sh(ESLINT_TEST.split(), cwd=ws, timeout=600)
    m = re.search(r"(\d+) passing", out)
    f = re.search(r"(\d+) failing", out)
    _, stat = sh(["git", "diff", "HEAD", "--shortstat", "--", ".", ":!.mcp.json"], cwd=ws)
    _, names = sh(["git", "diff", "HEAD", "--name-only"], cwd=ws)
    stat = stat.strip()
    ok = rc == 0 and bool(stat)
    note = "mocha %s passing=%s failing=%s; diff: %s; files: %s" % (
        "ok" if rc == 0 else "FAIL", m.group(1) if m else "?", f.group(1) if f else "0",
        stat or "EMPTY", ",".join(names.split()))
    return ok, note


def changed(ws):
    _, stat = sh(["git", "diff", "HEAD", "--shortstat", "--", ".", ":!.mcp.json"], cwd=ws)
    _, names = sh(["git", "diff", "HEAD", "--name-only"], cwd=ws)
    _, new = sh(["git", "ls-files", "--others", "--exclude-standard"], cwd=ws)
    new = [n for n in new.split() if not n.startswith((".mcp.json", ".emetgate/", ".pytest_cache/")) and "__pycache__" not in n]
    names = [n for n in names.split() if n != ".mcp.json"] + new
    extra = " +%d untracked" % len(new) if new else ""
    return bool(stat.strip() or new), "diff: %s%s; files: %s" % (stat.strip() or "EMPTY", extra, ",".join(names))


def pytest_ok(args, cwd, env=None, timeout=900):
    rc, out = sh([sys.executable, "-m", "pytest", "-q", "-p", "no:cacheprovider", *args], cwd=cwd, env=env, timeout=timeout)
    lines = out.strip().splitlines()
    return rc == 0, lines[-1] if lines else ""


def shell(cmd, cwd, timeout=600):
    return subprocess.run(cmd, cwd=cwd, shell=True, capture_output=True, text=True, encoding="utf-8", errors="replace",
                          stdin=subprocess.DEVNULL, timeout=timeout)


def verify_py_scratch(ws):
    notes = []
    tests_ok, tail = pytest_ok([], ws)
    notes.append("pytest %s (%s)" % ("ok" if tests_ok else "FAIL", tail))
    smoke_ok = False
    if (ws / "csvsum").is_dir():
        tmp = Path(tempfile.mkdtemp(prefix="csvsum-smoke-"))
        try:
            dst = tmp / "app"
            shutil.copytree(ws, dst, ignore=shutil.ignore_patterns(".git", ".emetgate", "__pycache__", ".pytest_cache"))
            (dst / "bench_in.csv").write_text("name,qty,price,note\na,1,2.5,x\nb,3,,y\nc,5,4.5,\n", encoding="utf-8")
            run = lambda f: subprocess.run([sys.executable, "-m", "csvsum", f], cwd=dst, capture_output=True, text=True,
                                           stdin=subprocess.DEVNULL, timeout=60)
            p = run("bench_in.csv")
            close = lambda a, b: abs(float(a) - b) < 1e-9
            try:
                d = json.loads(p.stdout)
                c = d["columns"]
                summary_ok = (p.returncode == 0 and int(d["rows"]) == 3 and set(c) == {"qty", "price"}
                              and close(c["qty"]["min"], 1) and close(c["qty"]["max"], 5) and close(c["qty"]["mean"], 3)
                              and close(c["price"]["min"], 2.5) and close(c["price"]["max"], 4.5) and close(c["price"]["mean"], 3.5))
            except Exception:
                summary_ok = False
            q = run("nope-missing.csv")
            missing_ok = q.returncode == 2 and bool(q.stderr.strip())
            smoke_ok = summary_ok and missing_ok
            notes.append("cli summary %s, missing-file rc=%s" % ("ok" if summary_ok else "FAIL " + repr(p.stdout[:100]), q.returncode))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    else:
        notes.append("no csvsum/")
    return tests_ok and smoke_ok, "; ".join(notes)


def verify_ts_scratch(ws):
    if not (ws / "package.json").exists():
        return False, "no package.json"
    notes = []
    tests_ok = shell("npm test", ws).returncode == 0
    notes.append("npm test " + ("ok" if tests_ok else "FAIL"))
    tsc = ws / "node_modules" / ".bin" / "tsc.cmd"
    tsc_ok = tsc.exists() and shell('"%s" --noEmit' % tsc, ws).returncode == 0
    notes.append("tsc --noEmit " + ("ok" if tsc_ok else "FAIL" if tsc.exists() else "no local typescript"))
    check_ok = False
    if tsc.exists() and (ws / "src" / "index.ts").exists():
        out = Path(tempfile.mkdtemp(prefix="ts-check-"))
        try:
            compile = '"%s" --outDir "%s" --module commonjs --moduleResolution node --target es2020 --skipLibCheck --rootDir src src/index.ts' % (tsc, out)
            if "TS5112" in (lambda r: r.stdout + r.stderr)(shell(compile, ws)):
                shell(compile + " --ignoreConfig", ws)
            (out / "package.json").write_text('{"type":"commonjs"}', encoding="utf-8")
            r = shell('node "%s" "%s"' % (CHECKS / "check_duration.cjs", out / "index.js"), ws)
            check_ok = r.returncode == 0
            msg = (r.stdout + r.stderr).strip().splitlines()
            notes.append("behavior " + ("ok" if check_ok else "FAIL " + next((l for l in msg if "Error" in l), msg[-1] if msg else "")[:160]))
        finally:
            shutil.rmtree(out, ignore_errors=True)
    else:
        notes.append("no src/index.ts")
    return tests_ok and tsc_ok and check_ok, "; ".join(notes)


def verify_cs_scratch(ws):
    env = dict(os.environ, DOTNET_CLI_UI_LANGUAGE="en", DOTNET_CLI_TELEMETRY_OPTOUT="1", DOTNET_NOLOGO="1")
    rc, out = sh(["dotnet", "test"], cwd=ws, timeout=1200, env=env)
    passed = sum(int(x) for x in re.findall(r"Passed:\s*(\d+)", out))
    failed = sum(int(x) for x in re.findall(r"Failed:\s*(\d+)", out))
    return rc == 0 and passed > 0 and failed == 0, "dotnet test %s passed=%d failed=%d" % ("ok" if rc == 0 else "FAIL", passed, failed)


def verify_pyrepo(ws, check):
    env = dict(os.environ, PYTHONPATH=str(ws))
    hidden_ok, htail = pytest_ok([str(CHECKS / check)], ws, env=env)
    suite_ok, stail = pytest_ok(["tests/test_more.py"], ws, env=env)
    diff_ok, dnote = changed(ws)
    note = "hidden %s (%s); test_more %s (%s); %s" % ("ok" if hidden_ok else "FAIL", htail, "ok" if suite_ok else "FAIL", stail, dnote)
    return hidden_ok and suite_ok and diff_ok, note


def verify_py_existing(ws):
    ok, note = verify_pyrepo(ws, "check_circular_pairwise.py")
    pyi = (ws / "more_itertools" / "more.pyi").read_text(encoding="utf-8", errors="replace")
    api = (ws / "docs" / "api.rst").read_text(encoding="utf-8", errors="replace")
    docs_ok = "circular_pairwise" in pyi and "circular_pairwise" in api
    return ok and docs_ok, note + "; stub+docs " + ("ok" if docs_ok else "MISSING")


def verify_bugfix(ws):
    return verify_pyrepo(ws, "check_windowed.py")


def verify_refactor(ws):
    rc, out = sh(REFACTOR_TEST.split(), cwd=ws, timeout=900)
    m = re.search(r"(\d+) passing", out)
    f = re.search(r"(\d+) failing", out)
    old = sh(["git", "grep", "-lw", REFACTOR_OLD], cwd=ws)[1].split()
    new = sh(["git", "grep", "-lw", REFACTOR_NEW], cwd=ws)[1].split()
    diff_ok, dnote = changed(ws)
    ok = rc == 0 and not old and len(new) >= 7 and diff_ok
    return ok, "mocha %s passing=%s failing=%s; old name in %d files%s; new name in %d files; %s" % (
        "ok" if rc == 0 else "FAIL", m.group(1) if m else "?", f.group(1) if f else "0", len(old),
        " (" + ",".join(old) + ")" if old else "", len(new), dnote)


def answer_of(ws):
    transcript = ws.parent / (ws.name + ".jsonl")
    answer = parse(transcript)[1] if transcript.exists() else ""
    (ws.parent / (ws.name + ".answer.md")).write_text(answer, encoding="utf-8")
    return answer


def tracked_clean(ws):
    return not sh(["git", "status", "--porcelain", "--untracked-files=no"], cwd=ws)[1].strip()


def has_word(text, word):
    return re.search(r"(?<![\w.])%s(?!\w)" % re.escape(str(word)), text) is not None


def verify_git_history(ws):
    t, answer = load_truth(ws), answer_of(ws)
    sha_ok = t["commit"][:7].lower() in answer.lower()
    author_ok = t["author"] in answer
    missing = [p for _, _, p in t["files"] if not (p in answer or has_word(answer, p.rsplit("/", 1)[-1]))]
    counts = sorted({n for a, d, _ in t["files"] for n in (a, d)})
    missing_counts = [n for n in counts if not has_word(answer, n)]
    clean = tracked_clean(ws)
    ok = sha_ok and author_ok and not missing and not missing_counts and clean
    return ok, "commit %s %s; author %s %s; files missing: %s; counts missing: %s; tracked changes: %s" % (
        t["commit"][:7], "ok" if sha_ok else "MISSING", t["author"], "ok" if author_ok else "MISSING",
        ",".join(missing) or "none", ",".join(map(str, missing_counts)) or "none", "no" if clean else "YES")


def verify_search(ws):
    t, answer = load_truth(ws), answer_of(ws)
    key = lambda s: (s.rsplit(":", 1)[0].replace("\\", "/").rsplit("/", 1)[-1], int(s.rsplit(":", 1)[1]))
    found = {(p.replace("\\", "/").rsplit("/", 1)[-1], int(n)) for p, n in re.findall(r"([\w./\\-]+\.py):(\d+)", answer)}
    calls = {key(s) for s in t["calls"]}
    decoys = {key(s) for s in t["decoys"]}
    missing = calls - found
    wrong = found - calls - decoys
    listed_decoys = found & decoys
    count_ok = has_word(answer, len(calls))
    ok = not missing and not wrong and count_ok and tracked_clean(ws)
    fmt_ = lambda s: ",".join("%s:%d" % x for x in sorted(s)) or "none"
    return ok, "truth %d call sites; missing: %s; wrong: %s; decoys listed: %s; count %s" % (
        len(calls), fmt_(missing), fmt_(wrong), fmt_(listed_decoys), "ok" if count_ok else "MISSING")


def verify_git_workflow(ws):
    t, answer = load_truth(ws), answer_of(ws)
    notes, ok = [], True
    rc, tip = sh(["git", "rev-parse", "--verify", "-q", WORKFLOW_BRANCH], cwd=ws)
    if rc != 0:
        return False, "branch %s missing" % WORKFLOW_BRANCH
    tip = tip.strip()
    count = git_out(ws, "rev-list", "--count", "%s..%s" % (t["head"], tip))
    parent_ok = count == "1" and git_out(ws, "rev-parse", tip + "^") == t["head"]
    base_ok = git_out(ws, "rev-parse", t["branch"]) == t["head"]
    msg_ok = git_out(ws, "log", "-1", "--format=%B", tip) == WORKFLOW_MSG
    files = set(git_out(ws, "show", "--format=", "--name-only", tip).split())
    files_ok = files == {"more_itertools/__init__.py", "setup.cfg", "docs/versions.rst"}
    show = lambda p: sh(["git", "show", "%s:%s" % (tip, p)], cwd=ws)[1]
    init_ok = "__version__ = '11.3.0'" in show("more_itertools/__init__.py")
    cfg_ok = "current_version = 11.3.0" in show("setup.cfg")
    rst = show("docs/versions.rst").replace("\r\n", "\n")
    rst_ok = "\n11.3.0\n" in rst and rst.index("\n11.3.0\n") < rst.index("\n11.2.1\n") and "Version bump." in rst
    clean = tracked_clean(ws)
    stat = git_out(ws, "show", "--format=", "--shortstat", tip)
    nums = [int(n) for n in re.findall(r"(\d+) (?:files? changed|insertions?|deletions?)", stat)]
    report_ok = tip[:7].lower() in answer.lower() and all(has_word(answer, n) for n in nums)
    checks = [("one commit on base", parent_ok), ("base untouched", base_ok), ("message", msg_ok), ("files", files_ok),
              ("__init__", init_ok), ("setup.cfg", cfg_ok), ("versions.rst", rst_ok), ("clean", clean), ("report", report_ok)]
    ok = all(v for _, v in checks)
    return ok, "; ".join("%s %s" % (k, "ok" if v else "FAIL") for k, v in checks) + "; files: %s; stat: %s" % (",".join(sorted(files)), stat)


def verify_py_rename(ws):
    old, new = PY_RENAME
    env = dict(os.environ, PYTHONPATH=str(ws))
    left = sh(["git", "grep", "-lw", "--untracked", old, "--", ".", ":(exclude)docs/versions.rst"], cwd=ws)[1].split()
    need = ["more_itertools/more.py", "more_itertools/more.pyi", "tests/test_more.py", "README.rst", "docs/api.rst"]
    lacking = [p for p in need if new not in (ws / p).read_text(encoding="utf-8", errors="replace")]
    hist_ok = not sh(["git", "diff", "HEAD", "--name-only", "--", "docs/versions.rst"], cwd=ws)[1].strip()
    probe = ("import more_itertools as m\nf = m.%s\nassert not hasattr(m, %r)\nassert list(f('ab')) == ['ab']\n"
             "assert list(f(None)) == []\nassert list(f([1, 2])) == [1, 2]\nassert list(f(b'x', base_type=None)) == [120]\n"
             "assert list(f(3)) == [3]\n" % (new, old))
    rc, pout = sh([sys.executable, "-c", probe], cwd=ws, env=env)
    probe_note = "ok" if rc == 0 else "FAIL " + (pout.strip().splitlines() or [""])[-1][:120]
    suite_ok, tail = pytest_ok(["tests"], ws, env=env)
    ok = not left and not lacking and hist_ok and rc == 0 and suite_ok
    return ok, "pytest tests %s (%s); old name in: %s; new name missing in: %s; versions.rst %s; api probe %s" % (
        "ok" if suite_ok else "FAIL", tail, ",".join(left) or "none", ",".join(lacking) or "none",
        "untouched" if hist_ok else "CHANGED", probe_note)


def verify_debug(ws):
    env = dict(os.environ, PYTHONPATH=str(ws))
    hidden_ok, htail = pytest_ok([str(CHECKS / "check_peekable_slice.py")], ws, env=env)
    suite_ok, stail = pytest_ok(["tests"], ws, env=env)
    touched = sh(["git", "diff", "HEAD", "--name-only", "--", "tests"], cwd=ws)[1].split()
    touched += [n for n in sh(["git", "ls-files", "--others", "--exclude-standard", "--", "tests"], cwd=ws)[1].split() if "__pycache__" not in n]
    diff_ok, dnote = changed(ws)
    ok = hidden_ok and suite_ok and not touched and diff_ok
    return ok, "hidden %s (%s); tests %s (%s); test files touched: %s; %s" % (
        "ok" if hidden_ok else "FAIL", htail, "ok" if suite_ok else "FAIL", stail, ",".join(touched) or "none", dnote)


def cs_sources(root, exts=(".cs", ".csproj", ".sln")):
    skip = {"bin", "obj", ".git", ".emetgate", ".vs", "TestResults"}
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in skip]
        out += [Path(dirpath) / f for f in filenames if f.endswith(exts)]
    return out


def cs_test_attrs(root):
    return sum(len(re.findall(r"\[(?:Fact|Theory|InlineData)\b", p.read_text(encoding="utf-8", errors="replace")))
               for p in cs_sources(root / "tests", (".cs",)))


def dotnet_with_hidden(ws, hidden):
    tmp = Path(tempfile.mkdtemp(prefix="cs-check-"))
    try:
        dst = tmp / "sln"
        shutil.copytree(ws, dst, ignore=shutil.ignore_patterns("bin", "obj", ".git", ".emetgate", ".vs", "TestResults"))
        proj = dst / "tests" / "Inventory.Tests"
        if not proj.is_dir():
            return False, "tests/Inventory.Tests missing"
        shutil.copy2(CHECKS / "cs" / hidden, proj / hidden)
        rc, out = sh(["dotnet", "test"], cwd=dst, timeout=1200, env=dict(os.environ, **DOTNET_ENV))
        passed = sum(int(x) for x in re.findall(r"Passed:\s*(\d+)", out))
        failed = sum(int(x) for x in re.findall(r"Failed:\s*(\d+)", out))
        err = next((l.strip() for l in out.splitlines() if re.search(r"error CS\d+|\[FAIL\]", l)), "")
        ok = rc == 0 and passed > 0 and failed == 0
        return ok, "dotnet test+hidden %s passed=%d failed=%d%s" % ("ok" if ok else "FAIL", passed, failed, (" " + err[-200:]) if err else "")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def verify_cs_existing(ws):
    test_ok, tnote = dotnet_with_hidden(ws, "HiddenLowStockChecks.cs")
    decl = re.compile(r"record\s+(?:class\s+|struct\s+)?LowStockEntry\b")
    ns_ok = any(decl.search(t) and "namespace Inventory.Core.Models" in t
                for t in (p.read_text(encoding="utf-8", errors="replace") for p in cs_sources(ws / "src", (".cs",))))
    added = cs_test_attrs(ws) - cs_test_attrs(CS_SRC)
    diff_ok, dnote = changed(ws)
    ok = test_ok and ns_ok and added > 0 and diff_ok
    return ok, "%s; LowStockEntry in Models %s; new test attrs %d; %s" % (tnote, "ok" if ns_ok else "FAIL", added, dnote)


def verify_cs_rename(ws):
    old, new = CS_RENAME_TYPE
    word = re.compile(r"\b%s\b" % old)
    old_decl = re.compile(r"\bReserve\s*\(\s*Order\b")
    files = cs_sources(ws)
    texts = {p: p.read_text(encoding="utf-8", errors="replace") for p in files}
    old_left = [p.relative_to(ws).as_posix() for p, t in texts.items() if word.search(t)]
    old_files = [p.relative_to(ws).as_posix() for p in files if p.name.split(".")[0] == old]
    new_files = {p.name for p in files}
    renamed_ok = {new + ".cs", new + ".Reservations.cs"} <= new_files
    reserve_left = [p.relative_to(ws).as_posix() for p, t in texts.items() if old_decl.search(t)]
    test_ok, tnote = dotnet_with_hidden(ws, "HiddenRenameChecks.cs")
    diff_ok, dnote = changed(ws)
    ok = test_ok and not old_left and not old_files and renamed_ok and not reserve_left and diff_ok
    return ok, "%s; %s in: %s; old files: %s; new files %s; Reserve(Order) in: %s; %s" % (
        tnote, old, ",".join(old_left) or "none", ",".join(old_files) or "none", "ok" if renamed_ok else "MISSING",
        ",".join(reserve_left) or "none", dnote)


def tail_line(r):
    lines = (r.stdout + r.stderr).strip().splitlines()
    hit = next((l for l in lines if re.search(r"Error|FAIL|failed|Assertion", l)), lines[-1] if lines else "")
    return hit.strip()[:160]


def verify_react_vite(ws):
    if not (ws / "package.json").exists():
        return False, "no package.json"
    notes = []
    env = dict(os.environ, CI="1")
    r = subprocess.run("npm test", cwd=ws, shell=True, capture_output=True, text=True, encoding="utf-8", errors="replace",
                       stdin=subprocess.DEVNULL, timeout=600, env=env)
    tests_ok = r.returncode == 0
    notes.append("npm test " + ("ok" if tests_ok else "FAIL " + tail_line(r)))
    shutil.rmtree(ws / "dist", ignore_errors=True)
    r = shell("npm run build", ws)
    build_ok = r.returncode == 0 and (ws / "dist" / "index.html").exists()
    notes.append("build " + ("ok" if build_ok else "FAIL " + tail_line(r)))
    vitest = ws / "node_modules" / "vitest" / "vitest.mjs"
    hidden_ok = False
    if (ws / "src" / "Counter.tsx").exists() and vitest.exists():
        dst = ws / "src" / "bench-hidden.test.ts"
        shutil.copy2(CHECKS / "hidden_counter.test.ts", dst)
        try:
            r = shell('node "%s" run src/bench-hidden.test.ts --environment jsdom' % vitest, ws)
            hidden_ok = r.returncode == 0 and re.search(r"Tests\s+2 passed", re.sub(r"\x1b\[[0-9;]*m", "", r.stdout + r.stderr)) is not None
            notes.append("hidden " + ("ok" if hidden_ok else "FAIL " + tail_line(r)))
        finally:
            dst.unlink()
    else:
        notes.append("hidden: no src/Counter.tsx or vitest")
    return tests_ok and build_ok and hidden_ok, "; ".join(notes)


def venv_python(ws):
    p = ws / ".venv" / "Scripts" / "python.exe"
    return p if p.exists() else None


def verify_fastapi(ws):
    py = venv_python(ws)
    if not py:
        return False, "no .venv"
    notes = []
    env = dict(os.environ, PYTHONPATH=str(ws))
    rc, out = sh([str(py), "-m", "pytest", "-q", "-p", "no:cacheprovider"], cwd=ws, env=env, timeout=600)
    tests_ok = rc == 0
    notes.append("venv pytest %s (%s)" % ("ok" if tests_ok else "FAIL", (out.strip().splitlines() or [""])[-1][:120]))
    rc, out = sh([str(py), "-m", "pytest", "-q", "-p", "no:cacheprovider", "--rootdir", str(CHECKS),
                  str(CHECKS / "check_fastapi.py")], cwd=ws, env=env, timeout=600)
    hidden_ok = rc == 0
    notes.append("hidden %s (%s)" % ("ok" if hidden_ok else "FAIL", (out.strip().splitlines() or [""])[-1][:160]))
    req = ws / "requirements.txt"
    req_ok = req.exists() and "fastapi" in req.read_text(encoding="utf-8", errors="replace").lower()
    notes.append("requirements.txt " + ("ok" if req_ok else "MISSING"))
    return tests_ok and hidden_ok and req_ok, "; ".join(notes)


def verify_aspnet(ws):
    env = dict(os.environ, **DOTNET_ENV)
    slns = list(ws.glob("Shop.sln")) + list(ws.glob("Shop.slnx"))
    if not slns:
        return False, "no Shop.sln"
    _, lst = sh(["dotnet", "sln", str(slns[0]), "list"], cwd=ws, env=env)
    norm = lst.replace("\\", "/")
    sln_ok = "src/Shop.Api/" in norm and "tests/Shop.Api.Tests/" in norm
    rc, out = sh(["dotnet", "test"], cwd=ws, timeout=1200, env=env)
    passed = sum(int(x) for x in re.findall(r"Passed:\s*(\d+)", out))
    failed = sum(int(x) for x in re.findall(r"Failed:\s*(\d+)", out))
    own_ok = rc == 0 and passed > 0 and failed == 0
    tmp = Path(tempfile.mkdtemp(prefix="aspnet-check-"))
    try:
        dst = tmp / "sln"
        shutil.copytree(ws, dst, ignore=shutil.ignore_patterns("bin", "obj", ".git", ".emetgate", ".vs", "TestResults"))
        proj = dst / "tests" / "Shop.Api.Tests"
        hidden_ok, hnote = False, "tests/Shop.Api.Tests missing"
        if proj.is_dir():
            shutil.copy2(CHECKS / "cs" / "HiddenGreetChecks.cs", proj / "HiddenGreetChecks.cs")
            hrc, hout = sh(["dotnet", "test", str(proj), "--filter", "FullyQualifiedName~HiddenGreetChecks"], cwd=dst,
                           timeout=1200, env=env)
            hp = sum(int(x) for x in re.findall(r"Passed:\s*(\d+)", hout))
            hf = sum(int(x) for x in re.findall(r"Failed:\s*(\d+)", hout))
            err = next((l.strip() for l in hout.splitlines() if re.search(r"error CS\d+|\[FAIL\]|Assert", l)), "")
            hidden_ok = hrc == 0 and hp == 3 and hf == 0
            hnote = "hidden %s passed=%d failed=%d%s" % ("ok" if hidden_ok else "FAIL", hp, hf, (" " + err[-200:]) if err else "")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return sln_ok and own_ok and hidden_ok, "sln %s; dotnet test %s passed=%d failed=%d; %s" % (
        "ok" if sln_ok else "FAIL", "ok" if own_ok else "FAIL", passed, failed, hnote)


def verify_express(ws):
    if not (ws / "package.json").exists():
        return False, "no package.json"
    notes = []
    r = shell("npm test", ws)
    tests_ok = r.returncode == 0
    notes.append("npm test " + ("ok" if tests_ok else "FAIL " + tail_line(r)))
    pkg = json.loads((ws / "package.json").read_text(encoding="utf-8", errors="replace"))
    deps = {**pkg.get("dependencies", {}), **pkg.get("devDependencies", {})}
    deps_ok = "express" in pkg.get("dependencies", {}) and "jest" in deps and "supertest" in deps
    notes.append("deps " + ("ok" if deps_ok else "FAIL"))
    gi = ws / ".gitignore"
    gi_ok = gi.exists() and "node_modules" in gi.read_text(encoding="utf-8", errors="replace")
    readme = ws / "README.md"
    readme_ok = readme.exists() and len(readme.read_text(encoding="utf-8", errors="replace").strip()) > 80
    notes.append(".gitignore %s; README %s" % ("ok" if gi_ok else "FAIL", "ok" if readme_ok else "FAIL"))
    app = ws / "src" / "app.js"
    hidden_ok = False
    if app.exists():
        r = shell('node "%s" "%s"' % (CHECKS / "check_express.cjs", app), ws, timeout=120)
        hidden_ok = r.returncode == 0
        notes.append("hidden " + ("ok" if hidden_ok else "FAIL " + tail_line(r)))
    else:
        notes.append("no src/app.js")
    server_ok = (ws / "src" / "server.js").exists()
    return tests_ok and deps_ok and gi_ok and readme_ok and hidden_ok and server_ok, "; ".join(notes)


WORDSTAT_TEXT = "The cat and the dog. A cat of cats!\nDog dog bird, an owl to\n"
WORDSTAT_TOP3 = [["dog", 3], ["cat", 2], ["bird", 1]]


def verify_py_package(ws):
    notes = []
    readme_ok = (ws / "README.md").exists() and (ws / "README.md").stat().st_size > 40
    lic = ws / "LICENSE"
    lic_text = lic.read_text(encoding="utf-8", errors="replace") if lic.exists() else ""
    lic_ok = "MIT" in lic_text or "Permission is hereby granted" in lic_text
    gi = ws / ".gitignore"
    gi_text = gi.read_text(encoding="utf-8", errors="replace") if gi.exists() else ""
    gi_ok = "__pycache__" in gi_text or "*.pyc" in gi_text or "*.py[cod]" in gi_text
    sw = ws / "src" / "wordstat" / "data" / "stopwords.json"
    try:
        words = json.loads(sw.read_text(encoding="utf-8"))
        sw_ok = isinstance(words, list) and {"the", "a", "an", "and", "of", "to"} <= set(words)
    except Exception:
        sw_ok = False
    notes.append("README %s; LICENSE %s; .gitignore %s; stopwords.json %s" % tuple(
        "ok" if x else "FAIL" for x in (readme_ok, lic_ok, gi_ok, sw_ok)))
    py = venv_python(ws)
    unit_ok = False
    if py:
        rc, out = sh([str(py), "-m", "unittest", "discover", "-s", "tests"], cwd=ws, timeout=600)
        unit_ok = rc == 0 and re.search(r"Ran [1-9]\d* tests?", out) is not None
        notes.append("venv unittest %s (%s)" % ("ok" if unit_ok else "FAIL", (out.strip().splitlines() or [""])[-1][:100]))
    else:
        notes.append("no .venv")
    tmp = Path(tempfile.mkdtemp(prefix="wordstat-check-"))
    cli_ok = False
    try:
        src = tmp / "src"
        shutil.copytree(ws, src, ignore=shutil.ignore_patterns(".venv", ".git", ".emetgate", "build", "dist", "*.egg-info", "__pycache__"))
        rc, out = sh([sys.executable, "-m", "venv", str(tmp / "venv")], timeout=300)
        vpy = tmp / "venv" / "Scripts" / "python.exe"
        rc, out = sh([str(vpy), "-m", "pip", "install", "-q", str(src)], cwd=tmp, timeout=900)
        if rc != 0:
            notes.append("clean install FAIL " + (out.strip().splitlines() or [""])[-1][:160])
        else:
            exe = tmp / "venv" / "Scripts" / "wordstat.exe"
            (tmp / "in.txt").write_text(WORDSTAT_TEXT, encoding="utf-8")
            p = subprocess.run([str(exe), "in.txt", "--top", "3"], cwd=tmp, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=60)
            try:
                got = json.loads(p.stdout)
            except Exception:
                got = None
            q = subprocess.run([str(exe), "nope.txt"], cwd=tmp, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=60)
            p10 = subprocess.run([str(exe), "in.txt"], cwd=tmp, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=60)
            try:
                all_ok = len(json.loads(p10.stdout)) == 5
            except Exception:
                all_ok = False
            cli_ok = p.returncode == 0 and got == WORDSTAT_TOP3 and q.returncode == 2 and bool(q.stderr.strip()) and all_ok
            notes.append("clean install + cli %s (top3=%s, missing rc=%s)" % ("ok" if cli_ok else "FAIL", p.stdout.strip()[:80] or p.stderr.strip()[-80:], q.returncode))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return readme_ok and lic_ok and gi_ok and sw_ok and unit_ok and cli_ok, "; ".join(notes)


VERIFY = {"react-vite": verify_react_vite, "fastapi": verify_fastapi, "aspnet-webapi": verify_aspnet,
          "express-api": verify_express, "py-package": verify_py_package,
          "py-scratch": verify_py_scratch, "ts-scratch": verify_ts_scratch, "cs-scratch": verify_cs_scratch,
          "py-existing": verify_py_existing, "bugfix": verify_bugfix, "multi-file-refactor": verify_refactor,
          "git-history": verify_git_history, "search": verify_search, "git-workflow": verify_git_workflow,
          "py-rename": verify_py_rename, "debug-failing-test": verify_debug, "cs-existing": verify_cs_existing,
          "cs-rename": verify_cs_rename}


def verify_read(ws, answer):
    words = ["applyDisableDirectives", "getDirectiveComments", "disable-directives", "linter.js", "reportUnusedDisableDirectives"]
    hits = [w for w in words if w in answer]
    _, dirty = sh(["git", "status", "--porcelain", "--untracked-files=no"], cwd=ws)
    note = "answer %d chars; cites: %s; tracked changes: %s" % (len(answer), ",".join(hits) or "none", "yes" if dirty.strip() else "no")
    return bool(answer.strip()), note


def append_row(row):
    lock = RESULTS.with_suffix(".lock")
    for _ in range(600):
        try:
            fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            break
        except FileExistsError:
            time.sleep(0.5)
    else:
        raise RuntimeError("results.csv lock stuck: " + str(lock))
    try:
        rows, migrate = [], False
        if RESULTS.exists():
            with open(RESULTS, newline="", encoding="utf-8") as f:
                r = csv.DictReader(f)
                migrate = r.fieldnames != FIELDS
                rows = list(r) if migrate else []
        if migrate:
            with open(RESULTS, "w", newline="", encoding="utf-8") as f:
                w = csv.DictWriter(f, fieldnames=FIELDS)
                w.writeheader()
                w.writerows({k: v for k, v in old.items() if k in FIELDS} for old in rows)
        new = not RESULTS.exists()
        with open(RESULTS, "a", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=FIELDS)
            if new:
                w.writeheader()
            w.writerow(row)
    finally:
        os.close(fd)
        os.unlink(lock)


def run_one(task, mode, exe_src):
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    ws = WORK / ("%s-%s-%s" % (task, mode, stamp))
    exe, digest = (None, "")
    if mode == "gate":
        exe, digest = freeze_exe(exe_src)
    elif exe_src:
        digest = sha(exe_src)
    WORK.mkdir(parents=True, exist_ok=True)
    setup = prepare(task, mode, ws, exe)
    prompt = (TASKS / (task + ".txt")).read_text(encoding="utf-8").strip()
    transcript = WORK / (ws.name + ".jsonl")
    errlog = WORK / (ws.name + ".err")
    cmd = command(task, mode, prompt, exe, ws)
    print("[%s/%s] %s" % (task, mode, ws), flush=True)
    t0 = time.time()
    code = "?"
    with open(transcript, "w", encoding="utf-8") as out, open(errlog, "w", encoding="utf-8") as err:
        p = subprocess.Popen(cmd, cwd=ws, stdout=out, stderr=err, stdin=subprocess.DEVNULL, env=child_env(mode, ws))
        try:
            code = p.wait(timeout=TASK_CFG[task]["timeout"])
        except subprocess.TimeoutExpired:
            sh(["taskkill", "/T", "/F", "/PID", str(p.pid)])
            p.wait()
            code = "timeout"
    dur = round(time.time() - t0)
    stats, answer = parse(transcript)
    if task == "todo":
        ok, note = verify_todo(ws)
    elif task == "eslint":
        ok, note = verify_eslint(ws)
    elif task in VERIFY:
        try:
            ok, note = VERIFY[task](ws)
        except Exception as e:
            ok, note = False, "verify error: %r" % e
    else:
        ok, note = verify_read(ws, answer)
        (WORK / (ws.name + ".answer.md")).write_text(answer, encoding="utf-8")
    _, ver = sh([claude_exe(), "--version"], env=child_env())
    row = {"date": datetime.datetime.now().isoformat(timespec="seconds"), "task": task, "mode": mode,
           "emetgate_sha": digest if mode == "gate" else "", "claude_version": ver.strip().split(" ")[0],
           "setup": setup, "exit": code, "duration_s": dur, "success": int(ok), "verify": note,
           "workspace": str(ws), "transcript": str(transcript), "tool": TOOL_NAME.get(mode, ""),
           "tool_version": tool_version(mode), **stats}
    if mode == "cbm" and str(ws) in CBM_PROJECTS:
        sh([str(CBM_EXE), "cli", "delete_project", "--project", CBM_PROJECTS.pop(str(ws))])
    append_row(row)
    print("  -> success=%s turns=%s total=%s cost=%s | %s" % (int(ok), stats["turns"], stats["total_tokens"], stats["cost_usd"], note), flush=True)
    return row


def clean():
    if not WORK.exists():
        return
    for p in WORK.iterdir():
        if p.is_dir() and p.name != "exe":
            remove_tree(p)
    print("cleaned workspaces under", WORK)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--emetgate", help="path to emetgate.exe (required for gate mode)")
    ap.add_argument("--only", choices=MODES)
    ap.add_argument("--modes", help="comma list of modes to run (overrides --only): " + ",".join(MODES))
    ap.add_argument("--jobs", type=int, default=1, help="run up to N task/mode pairs concurrently")
    ap.add_argument("--tasks", default="todo,eslint,read", help="comma list of: " + ",".join(TASK_CFG))
    ap.add_argument("--repeat", type=int, default=1)
    ap.add_argument("--gate-mcp-arg", action="append", default=[], help="extra arg appended to the emetgate mcp server args (repeatable), e.g. --gate-mcp-arg=--shadow-tree --gate-mcp-arg=kept")
    ap.add_argument("--clean", action="store_true", help="delete old workspaces (junction-safe) and exit")
    a = ap.parse_args()
    if a.clean:
        clean()
        return
    GATE_EXTRA.extend(a.gate_mcp_arg)
    modes = [m.strip() for m in a.modes.split(",") if m.strip()] if a.modes else [a.only] if a.only else ["plain", "gate"]
    for m in modes:
        if m not in MODES:
            sys.exit("unknown mode " + m)
    if "gate" in modes and not (a.emetgate and Path(a.emetgate).is_file()):
        sys.exit("--emetgate <path-to-exe> is required for gate mode")
    missing = [str(p) for m, p in [("serena", SERENA_EXE), ("cbm", CBM_EXE), ("rtk", RTK_EXE), ("rtk", RTK_MD)] if m in modes and not p.is_file()]
    if missing:
        sys.exit("missing tool files: " + ", ".join(missing))
    exe = Path(a.emetgate).resolve() if a.emetgate else None
    tasks = [t.strip() for t in a.tasks.split(",") if t.strip()]
    for task in tasks:
        if task not in TASK_CFG:
            sys.exit("unknown task " + task)
    jobs = [(task, mode) for _ in range(a.repeat) for task in tasks for mode in modes]
    if a.jobs <= 1:
        for task, mode in jobs:
            run_one(task, mode, exe)
        return
    from concurrent.futures import ThreadPoolExecutor

    def safe(job):
        try:
            return run_one(job[0], job[1], exe)
        except Exception as e:
            print("[%s/%s] ERROR %r" % (job[0], job[1], e), flush=True)

    with ThreadPoolExecutor(max_workers=a.jobs) as pool:
        list(pool.map(safe, jobs))


if __name__ == "__main__":
    main()
