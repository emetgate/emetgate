import json
import os
import sys

RUNS = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))), "eval", "map-runs")
VARIANTS = [("m1p", 0), ("m1p3", 1), ("m1p4", 2)]
BUDGETS = [8, 12, 16, 20, 24]
POWERS = ["0", "0.5", "1"]


def read(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def main():
    seen = []
    for prefix, rank in VARIANTS:
        for budget in BUDGETS:
            label = f"{prefix}-{budget}k"
            path = os.path.join(RUNS, label, "m1p-regions.json")
            if not os.path.exists(path):
                continue
            summary = read(path)["summary"].get("seen")
            if summary and summary["calls"] == 12:
                seen.append((summary["hits"], -budget, -rank, label))
    if not seen:
        sys.exit("no seen region picks to choose from")
    seen.sort(reverse=True)
    label = seen[0][3]
    powers = []
    for power in POWERS:
        hits = 0
        for base in ("m1p-12k", "m1p-24k"):
            path = os.path.join(RUNS, base, f"m1p-rank-seen-idf{power}.json")
            if not os.path.exists(path):
                sys.exit(f"missing {path}")
            hits += read(path)["summary"]["seen"]["hits_at5"]
        powers.append((hits, -float(power), power))
    powers.sort(reverse=True)
    choice = {"label": label, "rank_args": f"--rank-idf-power {powers[0][2]}",
              "seen_region_hits": [{"label": s[3], "hits": s[0]} for s in seen],
              "seen_rank_hits_at5_12k_plus_24k": [{"idf_power": p[2], "hits": p[0]} for p in powers]}
    with open(os.path.join(RUNS, "m1p-choice.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(choice, f, indent=2)
        f.write("\n")
    print(json.dumps(choice))


if __name__ == "__main__":
    main()
