"""Run the scenario catalog against an emetgate.exe.

    python -I tests/catalog/run.py --emetgate <exe> [--only ID[,ID]] [--json out] [--fast]

Exit code 0 when every scenario ended as expected (pass, or xfail for one
marked expected-fail), 1 otherwise (fail, error, or xpass: an expected-fail
that now passes, whose marker should be removed).
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)  # -I leaves the script folder off sys.path

import harness  # noqa: E402
from harness import SCENARIOS, Ctx, Fail, Skip, Server, clean_env  # noqa: E402
from fixtures import Fixtures  # noqa: E402
import s_read  # noqa: E402,F401
import s_write  # noqa: E402,F401
import s_env  # noqa: E402,F401

REPO = os.path.dirname(os.path.dirname(HERE))
EXPECTED = {"pass", "xfail", "skip"}


class Suite:
    def __init__(self, exe, work):
        self.work = work
        self.local_app_data = os.path.join(work, "localappdata")
        os.makedirs(self.local_app_data, exist_ok=True)
        # An exe that sits under a folder with a Low integrity label inherits it
        # and runs at Low integrity, where every write fails; run a copy.
        bin_dir = os.path.join(work, "bin")
        os.makedirs(bin_dir, exist_ok=True)
        self.exe = os.path.join(bin_dir, "emetgate.exe")
        shutil.copy2(exe, self.exe)
        self.fixtures = Fixtures(work)
        self.shared = {}

    def shared_server(self, root, args):
        key = (root, tuple(args))
        s = self.shared.get(key)
        if s is None or not s.alive:
            s = Server(self.exe, root, args, env=clean_env(None, self.local_app_data))
            self.shared[key] = s
        return s

    def close(self):
        for s in self.shared.values():
            s.close(wait=10)
        self.shared = {}


def select(args):
    picked = []
    only = set()
    for o in args.only or []:
        only.update(x.strip().upper() for x in o.split(",") if x.strip())
    for sc in SCENARIOS:
        if only and sc["id"].upper() not in only and not any(sc["id"].upper().startswith(o.rstrip("*")) and o.endswith("*") for o in only):
            continue
        if args.fast and sc["slow"] and not only:
            continue
        picked.append(sc)
    return picked


def run_one(suite, sc):
    ctx = Ctx(suite, sc)
    t0 = time.time()
    status, detail = "pass", ""
    try:
        sc["fn"](ctx)
    except Fail as e:
        status, detail = "fail", str(e)
    except Skip as e:
        status, detail = "skip", str(e)
    except Exception as e:  # a crash in the scenario or the harness
        status = "error"
        detail = "%s: %s | %s" % (type(e).__name__, e, traceback.format_exc().strip().splitlines()[-3:])
    finally:
        ctx.close()
        # A shared server that timed out was killed; drop it so the next one starts fresh.
        for k, s in list(suite.shared.items()):
            if not s.alive:
                del suite.shared[k]
    if sc["xfail"]:
        if status == "fail":
            status = "xfail"
        elif status == "pass":
            status = "xpass"
            detail = "expected to fail (%s) but passed: remove the xfail marker" % sc["xfail"]
    return {"id": sc["id"], "inv": sc["inv"], "title": sc["title"], "status": status,
            "seconds": round(time.time() - t0, 2), "detail": detail, "fixed_by": sc["fixed_by"],
            "xfail": sc["xfail"], "slow": sc["slow"],
            "max_reply": max([len(r) for r in ctx.calls] or [0])}


def table(results):
    w = max([len(r["id"]) for r in results] + [2])
    lines = ["%-*s  %-7s  %-6s  %7s  %s" % (w, "id", "status", "inv", "seconds", "note")]
    for r in results:
        note = r["detail"] if r["status"] != "pass" else r["title"]
        if r["status"] == "fail" and r["fixed_by"]:
            note = "[%s] %s" % (r["fixed_by"], note)
        note = note.replace("\n", " ")
        if len(note) > 160:
            note = note[:157] + "..."
        lines.append("%-*s  %-7s  %-6s  %7.1f  %s" % (w, r["id"], r["status"], r["inv"].split()[0], r["seconds"], note))
    return "\n".join(lines)


def find_exe(arg):
    if arg:
        return os.path.abspath(arg)
    p = os.path.join(REPO, "zig-out", "bin", "emetgate.exe")
    return p


def main():
    ap = argparse.ArgumentParser(description="Run the emetgate scenario catalog.")
    ap.add_argument("--emetgate", help="the emetgate.exe under test (default: zig-out/bin/emetgate.exe)")
    ap.add_argument("--only", action="append", help="scenario ids, comma separated; a trailing * matches a prefix")
    ap.add_argument("--json", help="write the results as JSON to this file")
    ap.add_argument("--fast", action="store_true", help="leave out the scenarios marked slow")
    ap.add_argument("--work", help="folder for fixtures and state (default: a new temp folder, removed after)")
    ap.add_argument("--keep", action="store_true", help="keep the work folder")
    ap.add_argument("--list", action="store_true", help="list the scenarios and exit")
    args = ap.parse_args()
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except AttributeError:
        pass

    picked = select(args)
    if args.list:
        for sc in picked:
            mark = " xfail: " + sc["xfail"] if sc["xfail"] else ""
            print("%-6s %-7s %s%s%s" % (sc["id"], sc["inv"].split()[0], sc["title"], " (slow)" if sc["slow"] else "", mark))
        print("%d scenarios" % len(picked))
        return 0
    if not picked:
        print("no scenario matches", args.only)
        return 1

    exe = find_exe(args.emetgate)
    if not os.path.isfile(exe):
        print("emetgate.exe not found at %s; build it or pass --emetgate" % exe)
        return 1
    version = subprocess.run([exe, "--version"], capture_output=True, text=True, env=clean_env()).stdout.strip()
    work = os.path.abspath(args.work) if args.work else tempfile.mkdtemp(prefix="emetgate-catalog-")
    os.makedirs(work, exist_ok=True)
    print("emetgate: %s (%s)" % (exe, version or "no --version"))
    print("work:     %s" % work)
    print("running %d scenarios%s" % (len(picked), " (fast)" if args.fast else ""))
    sys.stdout.flush()

    suite = Suite(exe, work)
    results = []
    t0 = time.time()
    try:
        for sc in picked:
            r = run_one(suite, sc)
            results.append(r)
            print("%-6s %-6s %6.1fs  %s" % (r["id"], r["status"], r["seconds"],
                                             (r["detail"] if r["status"] != "pass" else "")[:200].replace("\n", " ")))
            sys.stdout.flush()
    finally:
        suite.close()
    total = time.time() - t0

    counts = {}
    for r in results:
        counts[r["status"]] = counts.get(r["status"], 0) + 1
    unexpected = [r for r in results if r["status"] not in EXPECTED]
    print()
    print(table(results))
    print()
    print("%d scenarios in %.0fs: %s" % (len(results), total, ", ".join("%d %s" % (v, k) for k, v in sorted(counts.items()))))
    if unexpected:
        print("UNEXPECTED: " + ", ".join("%s (%s)" % (r["id"], r["status"]) for r in unexpected))
    if args.json:
        with open(args.json, "w", encoding="utf-8") as f:
            json.dump({"emetgate": exe, "version": version, "seconds": round(total, 1), "counts": counts,
                       "budget": harness.REPLY_BUDGET, "results": results}, f, ensure_ascii=False, indent=1)
    if not args.work and not args.keep:
        subprocess.run(["cmd", "/c", "rmdir", "/s", "/q", "\\\\?\\" + work], capture_output=True)
    return 1 if unexpected else 0


if __name__ == "__main__":
    sys.exit(main())
