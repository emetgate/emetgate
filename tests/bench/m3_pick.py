import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import map_eval as base
import m2_eval as m2

PROOF = os.path.join(base.PROJECT, "eval", "proof-1h")
OUT = os.path.join(base.PROJECT, "eval", "m3", "pick")
LABEL = "m2-names8k"


def items():
    regions, files = base.load_files(LABEL)
    out = []
    for q in base.seen_questions():
        out.append(("seen", q["id"], q["text"], q))
    v5 = json.load(open(os.path.join(PROOF, "rows-v5.json"), encoding="utf-8"))
    for r in v5:
        for name, args in r["calls"]:
            if name == "explore":
                out.append(("seen-v5", f"{r['qid']}v{r['trial']}", args["question"], next(q for q in base.seen_questions() if q["id"] == r["qid"])))
                break
    for q in m2.part_questions("dev"):
        out.append(("dev", q["id"], q["text"], q))
    rows = []
    for part, qid, text, q in out:
        gold = base.gold_of(files, q)
        rows.append({"part": part, "id": qid, "text": text, "gold": gold})
    return rows


def run(extra):
    rows = items()
    os.makedirs(OUT, exist_ok=True)
    set_path = os.path.join(OUT, "set.json")
    base.write_json(set_path, {"questions": [{"id": r["id"], "text": r["text"], "regions": [],
                                               "gold_path": r["gold"][0]["file"] if r["gold"] else "",
                                               "gold_qname": r["gold"][0]["qname"] if r["gold"] else ""} for r in rows]})
    argv = [base.EXE, "map", "eval", "--set", set_path, "--budget-tokens", "8000", "--limit", "50", "--with-text", *extra]
    proc = subprocess.run(argv, cwd=base.N8N, capture_output=True)
    if proc.returncode != 0:
        raise SystemExit(proc.stderr.decode("utf-8", "replace")[-2000:])
    results = {}
    for line in proc.stdout.decode("utf-8").splitlines():
        if line.strip():
            r = json.loads(line)
            results[r["id"]] = r
    summary = {}
    table = []
    for r in rows:
        res = results.get(r["id"]) or {}
        explored = res.get("explored_regions") or []
        gold_regions = {g["region"] for g in r["gold"]}
        gold_names = {g["qname"] for g in r["gold"]}
        shown = {s[2] for s in res.get("shown") or []}
        text = res.get("explore_text") or ""
        listed = any(g["qname"] in text for g in r["gold"])
        row = {"part": r["part"], "id": r["id"], "region_hit": bool(gold_regions & set(explored)), "global_rank": res.get("global_rank"),
               "shown": bool(gold_names & shown), "listed": listed, "chars": res.get("explore_chars"), "pick_ms": res.get("pick_ms"),
               "explored": explored, "gold_regions": sorted(gold_regions)}
        table.append(row)
        s = summary.setdefault(r["part"], {"n": 0, "region_hit": 0, "shown": 0, "listed": 0, "global_at10": 0, "chars": []})
        s["n"] += 1
        s["region_hit"] += row["region_hit"]
        s["shown"] += row["shown"]
        s["listed"] += row["listed"]
        s["global_at10"] += bool(row["global_rank"] and row["global_rank"] <= 10)
        if row["chars"]:
            s["chars"].append(row["chars"])
    for s in summary.values():
        chars = sorted(s.pop("chars"))
        s["chars_p50"] = chars[len(chars) // 2] if chars else None
        s["chars_max"] = chars[-1] if chars else None
    tag = "-".join(a.lstrip("-") for a in extra) or "default"
    base.write_json(os.path.join(OUT, f"pick-{tag}.json"), {"extra": extra, "summary": summary, "rows": table})
    print(json.dumps(summary, indent=1))
    for row in table:
        if not row["shown"]:
            print(row["part"], row["id"], "region" if row["region_hit"] else "-", "listed" if row["listed"] else "-", "global", row["global_rank"], row["explored"], row["gold_regions"])


if __name__ == "__main__":
    run(sys.argv[1:])
