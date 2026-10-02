import argparse
import json
import subprocess
import sys

SEEN = ("S1", "S2", "S5", "S6")


def intent_of(kind):
    return "flow" if ("calls" in kind or "flows" in kind) else "decides"


def run(exe, repo, intent, targets, terms, budget, include, repeat):
    args = [exe, "facts", "evidence", "--intent", intent, "--budget", str(budget), "--repeat", str(repeat), "--json"]
    for path, qname in targets:
        args += ["--target", f"{path}#{qname}"]
    for term in terms:
        args += ["--term", term]
    if include:
        args += ["--include", include]
    done = subprocess.run(args, cwd=repo, capture_output=True, text=True, encoding="utf-8")
    if done.returncode not in (0, 2):
        raise SystemExit(f"emetgate facts evidence failed ({done.returncode}): {done.stderr[-2000:]}")
    return json.loads(done.stdout)


def variants(q):
    gold = [(q["target"]["file"], q["target"]["symbol"])]
    listed = list(gold)
    for item in q["checklist"]:
        key = (item["file"], item["symbol"])
        if key not in listed:
            listed.append(key)
    intent = intent_of(q["kind"])
    return [
        ("gold", intent, gold, None),
        ("gold all", intent, gold, "callers,callees,tests"),
        ("checklist", intent, listed, None),
    ]


def main():
    parser = argparse.ArgumentParser(description="Checklist coverage, size and time of the evidence compiler on the seen questions, gold targets given by hand")
    parser.add_argument("--exe", required=True)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--questions", required=True)
    parser.add_argument("--budget", type=int, default=9500)
    parser.add_argument("--repeat", type=int, default=50)
    parser.add_argument("--result", required=True)
    args = parser.parse_args()
    questions = json.load(open(args.questions, encoding="utf-8"))["questions"]
    rows = []
    for qid in SEEN:
        q = questions.get(qid)
        if q is None:
            continue
        terms = q.get("instruction_keywords", [])
        for name, intent, targets, include in variants(q):
            out = run(args.exe, args.repo, intent, targets, terms, args.budget, include, args.repeat)
            text = out.get("text", "")
            met = [item["id"] for item in q["checklist"] if any(m in text for m in item["match"])]
            rows.append({
                "question": qid,
                "variant": name,
                "targets": [f"{p}#{s}" for p, s in targets],
                "intent": intent,
                "include": include or "default",
                "status": out["status"],
                "chars": len(text),
                "covered": len(met),
                "items": len(q["checklist"]),
                "met": met,
                "tests": out.get("tests", 0),
                "elided_ranges": len(out.get("elided", [])),
                "cut": out.get("cut", 0),
                "first_us": out.get("evidence_us"),
                "p50_us": out.get("p50_us"),
                "p99_us": out.get("p99_us"),
                "text": text,
            })
    with open(args.result, "w", encoding="utf-8") as handle:
        json.dump(rows, handle, indent=1, ensure_ascii=False)
    print(f"{'q':<3} {'variant':<10} {'intent':<8} {'status':<9} {'cover':>5} {'chars':>6} {'tests':>5} {'first ms':>8} {'p50 ms':>7} {'p99 ms':>7}  missing")
    for r in rows:
        missing = sorted(set(i["id"] for i in questions[r["question"]]["checklist"]) - set(r["met"]))
        print(f"{r['question']:<3} {r['variant']:<10} {r['intent']:<8} {r['status']:<9} {r['covered']}/{r['items']:<3} {r['chars']:>6} {r['tests']:>5} {(r['first_us'] or 0) / 1000:>8.2f} {(r['p50_us'] or 0) / 1000:>7.2f} {(r['p99_us'] or 0) / 1000:>7.2f}  {missing}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
