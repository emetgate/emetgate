import argparse
import collections
import hashlib
import json
import math
import os
import random
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import map_eval as base

SPLIT = os.path.join(base.HERE, "m2_split.json")
GENERAL = os.path.join(base.RUNS, "general_set.json")
CHOICE = os.path.join(base.RUNS, "m2-choice.json")
REPORT = os.path.join(base.RUNS, "m2-report.json")
BASE_LABEL = "m2-base"
SPLIT_SEED = 20261002
DEV_SIZE = 32
SEEN_TRIALS = 3
SEEN_CALLS = 12
GATE_TEST_RATE = 0.90
GATE_SEEN_HITS = 12
GATE_MAP_TOKENS = 8000
SPLIT_RULE = "random.Random(seed).shuffle of the sorted question ids of the general set; the first 32 are dev, the other 32 are test"
CHOICE_RULE = ("candidates with 12 seen calls, 32 dev calls and an api map token count; eligible when seen hits are 12 of 12 and the map "
               "has at most 8000 tokens; order: eligible first, then more dev hits, more seen hits, fewer map tokens, label")


def sha256_of(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def make_split():
    data = base.read_json(GENERAL)
    ids = sorted(q["id"] for q in data["questions"])
    order = list(ids)
    random.Random(SPLIT_SEED).shuffle(order)
    split = {"seed": SPLIT_SEED, "rule": SPLIT_RULE, "source": "eval/map-runs/general_set.json", "source_sha256": sha256_of(GENERAL),
             "dev": sorted(order[:DEV_SIZE]), "test": sorted(order[DEV_SIZE:])}
    if os.path.exists(SPLIT):
        if base.read_json(SPLIT) != split:
            raise SystemExit("the committed split differs from its rule; it is never rewritten")
        print("split unchanged")
        return
    base.write_json(SPLIT, split)
    print(json.dumps({"dev": split["dev"], "test": split["test"]}))


def read_split():
    split = base.read_json(SPLIT)
    if split["source_sha256"] != sha256_of(GENERAL):
        raise SystemExit("the general set changed after the split")
    return split


def part_questions(part):
    wanted = set(read_split()[part])
    return [q for q in base.read_json(GENERAL)["questions"] if q["id"] in wanted]


def m2_labels():
    if not os.path.isdir(base.RUNS):
        return []
    return sorted(n for n in os.listdir(base.RUNS) if n.startswith(base.M2_PREFIX) and n != BASE_LABEL and os.path.isdir(os.path.join(base.RUNS, n)))


def calls_of(label):
    calls = os.path.join(base.label_dir(label), "calls")
    if not os.path.isdir(calls):
        return []
    return [base.read_json(os.path.join(calls, n)) for n in sorted(os.listdir(calls))]


def test_runs():
    test_ids = set(read_split()["test"])
    return {label for label in m2_labels() if any(r["qid"] in test_ids for r in calls_of(label))}


def run_seen(label):
    prompt = base.region_prompt_file(label)
    for q in base.seen_questions():
        for trial in range(1, SEEN_TRIALS + 1):
            record = base.call(label, q["id"], trial, q["text"], prompt, base.RUNS)
            print(q["id"], trial, record["result"].get("total_cost_usd"), record["wall_ms"], "ms")


def guard_test(label):
    if not os.path.exists(CHOICE):
        raise SystemExit("test32 runs only after m2-choice.json names the chosen candidate")
    choice = base.read_json(CHOICE)
    if choice["label"] != label:
        raise SystemExit(f"test32 runs only for the chosen candidate {choice['label']}")
    others = test_runs() - {label}
    if others:
        raise SystemExit("test32 already ran for " + ", ".join(sorted(others)))


def run_part(label, part):
    if part == "test":
        guard_test(label)
    prompt = base.region_prompt_file(label)
    for q in part_questions(part):
        record = base.call(label, q["id"], 1, q["text"], prompt, base.RUNS)
        print(q["id"], record["result"].get("total_cost_usd"), record["wall_ms"], "ms")


def run_base():
    out = base.label_dir(BASE_LABEL)
    os.makedirs(out, exist_ok=True)
    path = os.path.join(out, "region-prompt.txt")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(base.REGION_INSTRUCTION + "\n")
    q = base.seen_questions()[0]
    record = base.call(BASE_LABEL, q["id"], 1, q["text"], path, base.RUNS)
    print(json.dumps(record["result"].get("usage"), indent=2))


def total_input(record):
    usage = record["result"].get("usage") or {}
    return usage.get("input_tokens", 0) + usage.get("cache_creation_input_tokens", 0) + usage.get("cache_read_input_tokens", 0)


def first_call(label, qid):
    path = os.path.join(base.label_dir(label), "calls", f"{qid}-1.json")
    return base.read_json(path) if os.path.exists(path) else None


def map_tokens(label):
    q = base.seen_questions()[0]["id"]
    with_map = first_call(label, q)
    without = first_call(BASE_LABEL, q)
    if with_map is None or without is None:
        return None
    return total_input(with_map) - total_input(without)


def score(label):
    regions, files = base.load_files(label)
    known = set(regions)
    split = read_split()
    part_of = {i: "dev" for i in split["dev"]}
    part_of.update({i: "test" for i in split["test"]})
    seen = {q["id"]: q for q in base.seen_questions()}
    general = {q["id"]: q for q in base.read_json(GENERAL)["questions"]}
    rows = []
    for record in calls_of(label):
        qid = record["qid"]
        if qid in seen:
            part, q = "seen", seen[qid]
        elif qid in part_of:
            part, q = part_of[qid], general[qid]
        else:
            continue
        gold = base.gold_of(files, q)
        picked, how = base.picked_regions(record["result"].get("result") or "", known)
        gold_regions = sorted({g["region"] for g in gold}, key=lambda r: int(r[1:]))
        usage = record["result"].get("usage") or {}
        rows.append({"set": part, "qid": qid, "trial": record["trial"], "picked": picked, "parsed": how, "gold_regions": gold_regions,
                     "hit": bool(set(picked) & set(gold_regions)), "cost": record["result"].get("total_cost_usd") or 0.0,
                     "duration_api_ms": record["result"].get("duration_api_ms"), "output_tokens": usage.get("output_tokens", 0),
                     "input_tokens": total_input(record)})
    summary = {}
    for part in ("seen", "dev", "test"):
        chunk = [r for r in rows if r["set"] == part]
        if not chunk:
            continue
        summary[part] = {"calls": len(chunk), "hits": sum(r["hit"] for r in chunk), "rate": round(sum(r["hit"] for r in chunk) / len(chunk), 4),
                         "json_parsed": sum(r["parsed"] == "json" for r in chunk), "cost_usd": round(sum(r["cost"] for r in chunk), 4)}
    stats = base.read_json(os.path.join(base.label_dir(label), "map.stats.json"))
    config = base.read_json(os.path.join(base.label_dir(label), "config.json"))
    report = {"label": label, "args": config["args"], "scored_at": base.now(), "instruction": base.REGION_INSTRUCTION, "summary": summary,
              "map_tokens": map_tokens(label), "est_tokens": stats["est_tokens"], "text_chars": stats["text_chars"],
              "text_sha256": stats["text_sha256"], "regions": stats["regions"], "code_regions": stats["code_regions"],
              "ledger_usd": round(base.spent(base.M2_LEDGER), 4), "rows": rows}
    base.write_json(os.path.join(base.label_dir(label), "m2-score.json"), report)
    print(json.dumps({k: report[k] for k in ("label", "args", "summary", "map_tokens", "est_tokens", "regions", "ledger_usd")}, indent=2))
    for r in rows:
        if not r["hit"]:
            print(r["set"], r["qid"], r["trial"], "MISS", r["picked"], r["gold_regions"])


def candidates():
    out = []
    for label in m2_labels():
        path = os.path.join(base.label_dir(label), "m2-score.json")
        if not os.path.exists(path):
            continue
        s = base.read_json(path)
        seen = s["summary"].get("seen") or {}
        dev = s["summary"].get("dev") or {}
        if seen.get("calls") != SEEN_CALLS or dev.get("calls") != DEV_SIZE or s.get("map_tokens") is None:
            continue
        out.append({"label": label, "args": s["args"], "seen_hits": seen["hits"], "dev_hits": dev["hits"], "dev_rate": dev["rate"],
                    "map_tokens": s["map_tokens"], "est_tokens": s["est_tokens"], "regions": s["regions"], "code_regions": s["code_regions"],
                    "eligible": seen["hits"] >= GATE_SEEN_HITS and s["map_tokens"] <= GATE_MAP_TOKENS})
    out.sort(key=lambda c: (not c["eligible"], -c["dev_hits"], -c["seen_hits"], c["map_tokens"], c["label"]))
    return out


def choose():
    ran = test_runs()
    if ran:
        raise SystemExit("test32 already ran for " + ", ".join(sorted(ran)) + "; the choice is final")
    pool = candidates()
    if not pool:
        raise SystemExit("no scored candidate")
    choice = {"label": pool[0]["label"], "args": pool[0]["args"], "eligible": pool[0]["eligible"], "rule": CHOICE_RULE, "chosen_at": base.now(), "candidates": pool}
    base.write_json(CHOICE, choice)
    print(json.dumps({k: choice[k] for k in ("label", "args", "eligible")}))


def report():
    pool = candidates()
    choice = base.read_json(CHOICE) if os.path.exists(CHOICE) else None
    test = None
    if choice:
        path = os.path.join(base.label_dir(choice["label"]), "m2-score.json")
        if os.path.exists(path):
            test = base.read_json(path)["summary"].get("test")
    gate = None
    if choice and test:
        chosen = next(c for c in pool if c["label"] == choice["label"])
        gate = {"test_rate": test["rate"], "test_hits": test["hits"], "test_calls": test["calls"], "seen_hits": chosen["seen_hits"],
                "map_tokens": chosen["map_tokens"], "passed": test["calls"] == len(read_split()["test"]) and test["rate"] >= GATE_TEST_RATE
                and chosen["seen_hits"] >= GATE_SEEN_HITS and chosen["map_tokens"] <= GATE_MAP_TOKENS}
    base.write_json(REPORT, {"reported_at": base.now(), "candidates": pool, "choice": choice and choice["label"], "test": test, "gate": gate,
                             "ledger_usd": round(base.spent(base.M2_LEDGER), 4)})
    print("| label | args | seen | dev32 | map tokens (api) | est tokens | regions |")
    print("|---|---|---|---|---|---|---|")
    for c in pool:
        print(f"| {c['label']} | {' '.join(c['args'])} | {c['seen_hits']}/12 | {c['dev_hits']}/32 ({c['dev_rate']:.2f}) | {c['map_tokens']} | {c['est_tokens']} | {c['regions']} |")
    print(json.dumps({"choice": choice and choice["label"], "test": test, "gate": gate, "ledger_usd": round(base.spent(base.M2_LEDGER), 4)}, indent=2))


def rank(label):
    regions, files = base.load_files(label)
    questions = [dict(q, set="seen") for q in base.seen_questions()] + [dict(q, set="dev") for q in part_questions("dev")]
    items = []
    gold_by_id = {}
    for q in questions:
        gold = base.gold_of(files, q)
        gold_by_id[q["id"]] = gold
        if gold:
            items.append({"id": q["id"], "text": q["text"], "regions": sorted({g["region"] for g in gold}, key=lambda r: int(r[1:]))})
    results = base.run_eval_set(label, items, ["--limit", "50"], "m2-rank")
    rows = []
    for q in questions:
        result = results.get(q["id"])
        by_region = {r["region"]: r for r in result["rankings"]} if result else {}
        ranks = [base.gold_rank(by_region[g["region"]], g) if g["region"] in by_region else None for g in gold_by_id[q["id"]]]
        best = min([r for r in ranks if r is not None], default=None)
        rows.append({"set": q["set"], "id": q["id"], "best": best, "candidates": [by_region[r]["candidates"] for r in by_region]})
    summary = {}
    for part in ("seen", "dev"):
        chunk = [r for r in rows if r["set"] == part]
        summary[part] = {f"at{k}": sum(r["best"] is not None and r["best"] <= k for r in chunk) for k in (3, 5, 8)}
        summary[part]["questions"] = len(chunk)
        sizes = sorted(c for r in chunk for c in r["candidates"])
        summary[part]["median_candidates"] = sizes[len(sizes) // 2] if sizes else None
    base.write_json(os.path.join(base.label_dir(label), "m2-rank.json"), {"label": label, "summary": summary, "rows": rows})
    print(json.dumps(summary))


def region_lines(label):
    lines = {}
    heading = ""
    with open(os.path.join(base.label_dir(label), "map.txt"), encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith("## "):
                heading = line[3:]
                continue
            m = re.match(r"^(r\d+) (.*)$", line)
            if m:
                lines[m.group(1)] = heading + " " + m.group(2)
    return lines


def proxy(label):
    lexicon = base.load_lexicon()
    regions, files = base.load_files(label)
    bags = {r: collections.Counter(base.stems_of(text)) for r, text in region_lines(label).items() if regions[r]["family"] == "code"}
    df = collections.Counter(t for bag in bags.values() for t in bag)
    lengths = {r: sum(bag.values()) for r, bag in bags.items()}
    avg = sum(lengths.values()) / max(1, len(lengths))
    rows = []
    for part, questions in (("seen", base.seen_questions()), ("dev", part_questions("dev"))):
        for q in questions:
            terms = lexicon.query(q["text"])
            scored = sorted(((base.Index.bm25(terms, bag, lengths[r], avg, df, len(bags)), r) for r, bag in bags.items()), key=lambda x: (-x[0], int(x[1][1:])))
            top = [r for s, r in scored[:3] if s > 0]
            gold = {g["region"] for g in base.gold_of(files, q)}
            rows.append({"set": part, "qid": q["id"], "hit": bool(gold & set(top)), "top": top, "gold": sorted(gold)})
    summary = {part: sum(r["hit"] for r in rows if r["set"] == part) for part in ("seen", "dev")}
    base.write_json(os.path.join(base.label_dir(label), "m2-proxy.json"), {"label": label, "summary": summary, "rows": rows})
    print(json.dumps(summary))
    return summary


def main():
    parser = argparse.ArgumentParser(description="M2 map gate: region picks on the seen set and the dev and test halves of the general set")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("split")
    p = sub.add_parser("prepare")
    p.add_argument("label")
    p.add_argument("extra", nargs=argparse.REMAINDER)
    for name in ("seen", "dev", "test", "score", "proxy", "rank", "tokens"):
        c = sub.add_parser(name)
        c.add_argument("label")
    sub.add_parser("base")
    sub.add_parser("choose")
    sub.add_parser("report")
    args = parser.parse_args()
    if args.command == "split":
        make_split()
    elif args.command == "prepare":
        if not args.label.startswith(base.M2_PREFIX):
            raise SystemExit("m2 labels start with " + base.M2_PREFIX)
        base.prepare(args.label, args.extra)
    elif args.command == "seen":
        run_seen(args.label)
    elif args.command in ("dev", "test"):
        run_part(args.label, args.command)
    elif args.command == "score":
        score(args.label)
    elif args.command == "proxy":
        proxy(args.label)
    elif args.command == "rank":
        rank(args.label)
    elif args.command == "tokens":
        tokens = map_tokens(args.label)
        print(args.label, "map tokens", tokens)
        if tokens is None or tokens > GATE_MAP_TOKENS:
            raise SystemExit(1)
    elif args.command == "base":
        run_base()
    elif args.command == "choose":
        choose()
    elif args.command == "report":
        report()


if __name__ == "__main__":
    main()
