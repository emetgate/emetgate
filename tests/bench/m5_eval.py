import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import map_eval as base
import m2_eval as m2

OUT = os.path.join(base.PROJECT, "eval", "m3", "m5")
LABEL = "m2-names8k"
SECTIONS = ["Code that uses the definitions above:", "Where the top functions are called:", "Where the fields read above are written:", "Functions they call:", "Functions you named:"]


def questions():
    regions, files = base.load_files(LABEL)
    rows = []
    for q in base.seen_questions():
        rows.append({"part": "seen", "id": q["id"], "text": q["text"], "gold": base.gold_of(files, q)})
    for q in m2.part_questions("dev"):
        rows.append({"part": "dev", "id": q["id"], "text": q["text"], "gold": base.gold_of(files, q)})
    return rows


def section_of(text, at):
    name = "explore"
    best = -1
    for s in SECTIONS:
        i = text.rfind(s, 0, at)
        if i > best:
            best = i
            name = s
    return name


def main():
    rows = questions()
    os.makedirs(OUT, exist_ok=True)
    set_path = os.path.join(OUT, "set.json")
    base.write_json(set_path, {"questions": [{"id": r["id"], "text": r["text"]} for r in rows]})
    proc = subprocess.run([base.EXE, "map", "ask", "--set", set_path], cwd=base.N8N, capture_output=True)
    if proc.returncode != 0:
        raise SystemExit(proc.stderr.decode("utf-8", "replace")[-2000:])
    replies = {}
    for line in proc.stdout.decode("utf-8").splitlines():
        if line.strip():
            r = json.loads(line)
            replies[r["id"]] = r
    table = []
    summary = {}
    for r in rows:
        reply = replies.get(r["id"], {})
        text = reply.get("text", "")
        named = [g["qname"] for g in r["gold"] if g["qname"] in text]
        shown = []
        for g in r["gold"]:
            tag = "[target " + g["qname"] + " "
            at = text.find(tag)
            if at >= 0:
                shown.append(section_of(text, at))
        row = {"part": r["part"], "id": r["id"], "chars": len(text), "named": bool(named), "shown": bool(shown), "sections": shown,
               "has": {s: (s in text) for s in SECTIONS}}
        table.append(row)
        s = summary.setdefault(r["part"], {"n": 0, "named": 0, "shown": 0, "chars": [], "section_present": {k: 0 for k in SECTIONS}, "found_in": {}})
        s["n"] += 1
        s["named"] += row["named"]
        s["shown"] += row["shown"]
        s["chars"].append(row["chars"])
        for k in SECTIONS:
            s["section_present"][k] += row["has"][k]
        for sec in shown[:1]:
            s["found_in"][sec] = s["found_in"].get(sec, 0) + 1
    for s in summary.values():
        chars = sorted(s.pop("chars"))
        s["chars_p50"] = chars[len(chars) // 2]
        s["chars_max"] = chars[-1]
    base.write_json(os.path.join(OUT, "coverage.json"), {"summary": summary, "rows": table})
    print(json.dumps(summary, indent=1))
    for row in table:
        print(row["part"], row["id"], row["chars"], "shown" if row["shown"] else ("named" if row["named"] else "-"), row["sections"])


if __name__ == "__main__":
    main()
