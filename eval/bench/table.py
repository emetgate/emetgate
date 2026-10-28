import argparse
import csv
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
METRICS = ["turns", "api_calls", "failed_tool_calls", "input_tokens", "cache_write_tokens", "cache_read_tokens",
           "output_tokens", "total_tokens", "cost_usd"]
ORDER = ["todo", "eslint", "read", "py-scratch", "ts-scratch", "cs-scratch", "py-existing", "bugfix", "multi-file-refactor",
         "git-history", "git-workflow", "search", "py-rename", "debug-failing-test", "cs-existing", "cs-rename",
         "react-vite", "fastapi", "aspnet-webapi", "express-api", "py-package"]
MODES = ["plain", "gate", "serena", "cbm", "rtk"]
SHORT = {"turns": "turns", "api_calls": "api", "failed_tool_calls": "fail", "input_tokens": "in",
         "cache_write_tokens": "cache_w", "cache_read_tokens": "cache_r", "output_tokens": "out",
         "total_tokens": "TOTAL", "cost_usd": "cost"}
WIDE = [("ok", None), ("tokens", "total_tokens"), ("cost", "cost_usd"), ("turns", "turns")]


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return 0.0


def fmt(m, v):
    if m == "cost_usd":
        return "%.3f" % v
    if v >= 10000:
        return "%.0fk" % (v / 1000)
    return "%.0f" % v


def render(lines, left=2):
    widths = [max(len(l[i]) for l in lines) for i in range(len(lines[0]))]
    for i, l in enumerate(lines):
        print("  ".join(c.rjust(w) if j >= left else c.ljust(w) for j, (c, w) in enumerate(zip(l, widths))))
        if i == 0:
            print("  ".join("-" * w for w in widths))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", default=str(HERE / "results.csv"))
    ap.add_argument("--sha", help="only gate rows with this emetgate_sha prefix")
    ap.add_argument("--last", type=int, default=0, help="use only the last N runs per task/mode")
    ap.add_argument("--modes", default=",".join(MODES), help="comma list of modes to show")
    ap.add_argument("--long", action="store_true", help="also print the per-metric long table with ratios vs plain")
    a = ap.parse_args()
    modes = [m for m in a.modes.split(",") if m]
    rows = list(csv.DictReader(open(a.csv, encoding="utf-8")))
    groups = defaultdict(list)
    for r in rows:
        if a.sha and r["mode"] == "gate" and not r["emetgate_sha"].startswith(a.sha):
            continue
        groups[(r["task"], r["mode"])].append(r)
    if a.last:
        groups = {k: v[-a.last:] for k, v in groups.items()}
    tasks = sorted({t for t, _ in groups}, key=lambda t: ORDER.index(t) if t in ORDER else 99)
    present = [m for m in modes if any((t, m) in groups for t in tasks)]

    def mean(t, mode):
        rs = groups.get((t, mode), [])
        return {m: sum(num(r[m]) for r in rs) / len(rs) for m in METRICS} if rs else None

    def ok(t, mode):
        rs = groups.get((t, mode), [])
        return "%d/%d" % (sum(int(num(r["success"])) for r in rs), len(rs)) if rs else "-"

    head = ["task"] + ["%s %s" % (mode, col) for mode in present for col, _ in WIDE]
    lines = [head]
    totals = {mode: {"ok": 0, "n": 0, "tasks": 0, **{m: 0.0 for m in METRICS}} for mode in present}
    for t in tasks:
        line = [t]
        for mode in present:
            mn = mean(t, mode)
            for col, m in WIDE:
                line.append(ok(t, mode) if m is None else (fmt(m, mn[m]) if mn else "-"))
            if mn:
                rs = groups[(t, mode)]
                totals[mode]["ok"] += sum(int(num(r["success"])) for r in rs)
                totals[mode]["n"] += len(rs)
                totals[mode]["tasks"] += 1
                for m in METRICS:
                    totals[mode][m] += mn[m]
        lines.append(line)
    line = ["SUM (task means)"]
    for mode in present:
        tt = totals[mode]
        line += ["%d/%d" % (tt["ok"], tt["n"]), fmt("total_tokens", tt["total_tokens"]), fmt("cost_usd", tt["cost_usd"]), fmt("turns", tt["turns"])]
    lines.append(line)
    if "plain" in present:
        common = [t for t in tasks if all((t, m) in groups for m in present)]
        line = ["vs plain (%d common tasks)" % len(common)]
        for mode in present:
            s = lambda m, mo: sum(mean(t, mo)[m] for t in common)
            for col, m in WIDE:
                if m is None:
                    line.append("")
                else:
                    p = s(m, "plain")
                    line.append("%.2fx" % (s(m, mode) / p) if p else "-")
        lines.append(line)
    render(lines, left=1)
    tv = {}
    for r in rows:
        if r.get("tool") and r["mode"] in present:
            tv.setdefault(r["mode"], set()).add("%s %s" % (r["tool"], r.get("tool_version", "")))
    shas = sorted({r["emetgate_sha"] for (t, m), rs in groups.items() if m == "gate" for r in rs if r["emetgate_sha"]})
    if shas:
        tv.setdefault("gate", set()).add("emetgate sha " + ",".join(shas))
    for mode in present:
        if mode in tv:
            print("%s: %s" % (mode, "; ".join(sorted(tv[mode]))))
    if not a.long:
        return
    print()
    head = ["task", "mode", "n", "ok"] + [SHORT[m] for m in METRICS] + ["sha"]
    lines = [head]
    for t in tasks:
        for mode in present:
            rs = groups.get((t, mode), [])
            if not rs:
                continue
            mn = mean(t, mode)
            shas = sorted({r["emetgate_sha"] for r in rs if r["emetgate_sha"]})
            lines.append([t, mode, str(len(rs)), ok(t, mode)] + [fmt(m, mn[m]) for m in METRICS] + [",".join(shas)])
        base = mean(t, "plain")
        for mode in present:
            mn = mean(t, mode)
            if mode == "plain" or not base or not mn:
                continue
            ratio = ["%.2fx" % (mn[m] / base[m]) if base[m] else "-" for m in METRICS]
            note = "" if all(num(r["success"]) for mo in ["plain", mode] for r in groups[(t, mo)]) else "(failed runs included)"
            lines.append([t, mode + "/plain", "", ""] + ratio + [note])
    render(lines)


if __name__ == "__main__":
    main()
