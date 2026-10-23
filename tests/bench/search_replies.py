import argparse
import glob
import json
import os
import sys

BENCH = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BENCH)
from n8n_profile import DEFAULT_EXE, DEFAULT_REPO, McpSession, percentile

ROOT = os.path.dirname(os.path.dirname(BENCH))
PROJECT_ROOT = os.path.dirname(ROOT)
DEFAULT_RUNS = os.path.join(PROJECT_ROOT, "eval", "session-map-runs")
SEARCH_TOOLS = ("mcp__emetgate__emetgate_search", "emetgate_search")


def result_text(content):
    if isinstance(content, str):
        return content
    parts = []
    for item in content or []:
        if isinstance(item, dict) and item.get("type") == "text":
            parts.append(item.get("text", ""))
    return "".join(parts)


def recorded_calls(runs):
    calls = []
    for path in sorted(glob.glob(os.path.join(runs, "**", "*.jsonl"), recursive=True)):
        pending = {}
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    event = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(event, dict):
                    continue
                if isinstance(event.get("event"), dict):
                    event = event["event"]
                message = event.get("message")
                if not isinstance(message, dict):
                    continue
                content = message.get("content")
                if not isinstance(content, list):
                    continue
                for item in content:
                    if not isinstance(item, dict):
                        continue
                    if item.get("type") == "tool_use" and item.get("name") in SEARCH_TOOLS:
                        pending[item.get("id")] = item.get("input") or {}
                    elif item.get("type") == "tool_result" and item.get("tool_use_id") in pending:
                        args = pending.pop(item["tool_use_id"])
                        calls.append({"source": os.path.relpath(path, runs).replace("\\", "/"), "args": args, "chars": len(result_text(item.get("content")))})
    return calls


def summary(values):
    if not values:
        return {}
    return {
        "calls": len(values),
        "p50": percentile(values, 0.5),
        "p90": percentile(values, 0.9),
        "p99": percentile(values, 0.99),
        "max": max(values),
        "total": sum(values),
        "over_6000": sum(1 for v in values if v > 6000),
    }


def replay(exe, repo, calls, detail):
    session = McpSession(exe, repo)
    sizes = []
    rows = []
    try:
        for c in calls:
            args = dict(c["args"])
            if detail:
                args["detail"] = detail
            if "dir" in args and not os.path.exists(os.path.join(repo, args["dir"])):
                continue
            text, is_error, _ = session.call("emetgate_search", args)
            sizes.append(len(text))
            first = text.split("\n", 1)[0]
            status = ""
            try:
                status = json.loads(first).get("status", "")
            except ValueError:
                pass
            rows.append({"args": args, "chars": len(text), "status": status, "error": is_error})
    finally:
        session.close()
    return sizes, rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", default=DEFAULT_RUNS)
    ap.add_argument("--exe", default=DEFAULT_EXE)
    ap.add_argument("--repo", default=DEFAULT_REPO)
    ap.add_argument("--replay", action="store_true")
    ap.add_argument("--json")
    args = ap.parse_args()
    calls = recorded_calls(args.runs)
    out = {"recorded": summary([c["chars"] for c in calls])}
    largest = sorted(calls, key=lambda c: -c["chars"])[:5]
    out["recorded_largest"] = [{"source": c["source"], "chars": c["chars"], "args": c["args"]} for c in largest]
    if args.replay:
        unique = []
        seen = set()
        for c in calls:
            key = json.dumps(c["args"], sort_keys=True)
            if key not in seen:
                seen.add(key)
                unique.append(c)
        for detail in ("full", "compact"):
            sizes, rows = replay(args.exe, os.path.abspath(args.repo), unique, detail)
            out[detail] = summary(sizes)
            out[detail + "_largest"] = sorted(rows, key=lambda r: -r["chars"])[:3]
    print(json.dumps(out, indent=2, ensure_ascii=False))
    if args.json:
        with open(args.json, "w", encoding="utf-8", newline="\n") as f:
            json.dump(out, f, indent=2, ensure_ascii=False)
            f.write("\n")


if __name__ == "__main__":
    main()
