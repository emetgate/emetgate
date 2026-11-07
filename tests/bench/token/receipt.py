import argparse
import csv
import json
import os
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from mine import short
from transcripts import base_usd, parse_session, price_units

TERMS = ["model_output", "model_kept", "base", "tool_results", "rebuild", "other"]


def receipt(session):
    calls = [c for c in session.calls if not c.duplicate]
    bill = Counter()
    tools = Counter()
    layers = []
    for i, call in enumerate(calls):
        prices = price_units(call.model)
        usd = base_usd(call.model) / 1e6
        bill["model_output"] += call.output * prices["output"] * usd
        bill["other"] += call.input * prices["input"] * usd
        write = (call.cache_write_1h * prices["cache_write_1h"] + call.cache_write_5m * prices["cache_write_5m"]) * usd
        fresh = i == 0 or call.segment != calls[i - 1].segment
        if fresh:
            layers = []
        held = sum(t for _, _, t in layers)
        if call.cache_read and held:
            cost = call.cache_read * prices["cache_read"] * usd
            for term, tool, tokens in layers:
                bill[term] += cost * tokens / held
                if tool:
                    tools[tool] += cost * tokens / held
        elif call.cache_read:
            bill["base"] += call.cache_read * prices["cache_read"] * usd
        if not call.cache_write:
            continue
        per = write / call.cache_write
        if fresh:
            bill["base"] += write
            layers.append(("base", "", call.context))
            continue
        prev = calls[i - 1]
        growth = max(0, min(call.cache_write, call.context - prev.context))
        bill["rebuild"] += (call.cache_write - growth) * per
        kept = min(growth, prev.output)
        added = [("model_kept", "", kept)]
        rest = growth - kept
        results = [u for u in prev.tool_uses if u.has_result]
        chars = sum(u.result_chars for u in results) + prev.other_chars
        if chars and rest:
            for use in results:
                added.append(("tool_results", short(use.name), rest * use.result_chars / chars))
            added.append(("other", "", rest * prev.other_chars / chars))
        elif rest:
            added.append(("other", "", rest))
        for term, tool, tokens in added:
            bill[term] += tokens * per
            if tool:
                tools[tool] += tokens * per
            if tokens:
                layers.append((term, tool, tokens))
    return {
        "usd": sum(bill.values()),
        "real_usd": sum(c.usd() for c in calls),
        "turns": len(calls),
        "base_context": calls[0].context if calls else 0,
        "output_tokens": sum(c.output for c in calls),
        "bill": dict(bill),
        "tools": dict(tools),
    }


def reported_output(path):
    total = 0
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if '"modelUsage"' not in line:
                continue
            try:
                record = json.loads(line)
            except ValueError:
                continue
            if record.get("type") != "result":
                continue
            usage = record.get("modelUsage") or {}
            total = sum(m.get("outputTokens") or 0 for m in usage.values())
    return total


def load(path):
    session = parse_session(path, os.path.dirname(path))
    calls = [c for c in session.calls if not c.duplicate]
    total = reported_output(path)
    known = sum(c.output for c in calls)
    weight = sum(c.text_chars for c in calls)
    if total > known and weight:
        for call in calls:
            call.output += (total - known) * call.text_chars / weight
    return receipt(session)


def money(value):
    return "$%.3f" % value


def print_rows(rows):
    head = ["task", "mode", "ok", "turns", "base", "out tok", "total"] + TERMS
    print("| " + " | ".join(head) + " |")
    print("|" + "---|" * len(head))
    for row in rows:
        r = row["receipt"]
        cells = [row["task"], row["mode"], row["ok"], str(r["turns"]), "%dk" % (r["base_context"] // 1000), str(int(r["output_tokens"])), money(r["usd"])]
        cells += [money(r["bill"].get(t, 0)) for t in TERMS]
        print("| " + " | ".join(cells) + " |")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--results", help="bench results.csv")
    parser.add_argument("--since", default="")
    parser.add_argument("files", nargs="*")
    args = parser.parse_args()
    rows = []
    if args.results:
        with open(args.results, encoding="utf-8") as handle:
            for row in csv.DictReader(handle):
                if row["date"] < args.since or not os.path.isfile(row["transcript"]):
                    continue
                rows.append({"task": row["task"], "mode": row["mode"], "ok": row["success"], "reported": float(row["cost_usd"] or 0), "receipt": load(row["transcript"])})
    for path in args.files:
        rows.append({"task": os.path.basename(path), "mode": "", "ok": "", "reported": 0.0, "receipt": load(path)})
    rows.sort(key=lambda r: (r["task"], r["mode"]))
    print_rows(rows)
    for row in rows:
        r = row["receipt"]
        print("check %s/%s: receipt %s, priced %s, reported %s" % (row["task"], row["mode"], money(r["usd"]), money(r["real_usd"]), money(row["reported"])))


if __name__ == "__main__":
    main()
