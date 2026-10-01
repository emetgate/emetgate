import argparse
import collections
import json
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CALLABLE = {"function", "generator", "method", "getter", "setter", "arrow", "function_expression", "class"}
SOURCE_EXTENSIONS = (".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs")


def facts(exe, repo, *args):
    done = subprocess.run([exe, "facts", *args], cwd=repo, capture_output=True, text=True, encoding="utf-8")
    if done.returncode not in (0, 2):
        raise SystemExit(f"emetgate facts {' '.join(args)} failed: {done.stderr[-2000:]}")
    return done.stdout


def lines_of(text):
    return [json.loads(line) for line in text.splitlines() if line.strip()]


def tracked(repo, prefixes):
    out = subprocess.run(["git", "ls-files", "-z"], cwd=repo, capture_output=True).stdout.decode("utf-8")
    return sorted(f for f in out.split("\0") if f.endswith(SOURCE_EXTENSIONS) and f.startswith(prefixes) and "node_modules/" not in f)


def code_line(repo, rel, line):
    try:
        with open(os.path.join(repo, rel), encoding="utf-8", errors="replace") as handle:
            for number, text in enumerate(handle, 1):
                if number == line:
                    return text.strip()[:160]
    except OSError as error:
        return f"<unreadable: {error}>"
    return "<no such line>"


def classify_missing_from_ours(site, unknown, our_refs):
    key = (site["path"], site["start"])
    if key in unknown:
        return "emetgate lists it as unresolved: " + unknown[key]
    if key in our_refs:
        return "emetgate resolves it with another role: " + our_refs[key]
    return None


class SameName:
    def __init__(self, exe, repo, defs):
        self.exe = exe
        self.repo = repo
        self.by_name = collections.defaultdict(list)
        for d in defs:
            if d["kind"] in CALLABLE:
                self.by_name[d["name"]].append(d)
        self.cache = {}

    def sites_of(self, d):
        key = (d["path"], d["qname"])
        if key not in self.cache:
            found = json.loads(facts(self.exe, self.repo, "callers", d["qname"], "--file", d["path"], "--json"))
            self.cache[key] = {(s["path"], s["start"]) for s in found.get("sites", [])}
        return self.cache[key]

    def owner(self, subject, site):
        name = subject["name"]
        for other in self.by_name.get(name, []):
            if other["path"] == subject["path"] and other["qname"] == subject["qname"]:
                continue
            if (site["path"], site["start"]) in self.sites_of(other):
                return other["qname"]
        return None


def classify_missing_from_ts(site, ts_any, ts_error):
    key = (site["path"], site["start"])
    if ts_error:
        return "tsserver failed on the subject: " + ts_error[:80]
    if key in ts_any:
        return "tsserver resolves it with another role: " + ts_any[key]
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--exe", required=True)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--typescript", required=True)
    parser.add_argument("--prefix", action="append", required=True)
    parser.add_argument("--seed", type=int, default=20261001)
    parser.add_argument("--count", type=int, default=30)
    parser.add_argument("--result", required=True)
    parser.add_argument("--node", default="node")
    parser.add_argument("--heap-mb", type=int, default=3072)
    args = parser.parse_args()
    prefixes = tuple(args.prefix)

    program = tracked(args.repo, prefixes)
    program_set = set(program)
    modules = collections.defaultdict(dict)
    defs = []
    for prefix in prefixes:
        for entry in lines_of(facts(args.exe, args.repo, "modules", "--file", prefix)):
            if entry["target"]:
                modules[entry["file"]][entry["spec"]] = entry["target"]
        defs.extend(lines_of(facts(args.exe, args.repo, "defs", "--file", prefix)))
    candidates = [d for d in defs if d["kind"] in CALLABLE and len(d["name"]) > 2 and not d["parse_errors"] and d["path"] in program_set and d["qname"]]
    unique = {}
    for d in candidates:
        unique.setdefault((d["path"], d["qname"]), d)
    candidates = sorted(unique.values(), key=lambda d: (d["path"], d["name_start"]))
    sample = random.Random(args.seed).sample(candidates, min(args.count, len(candidates)))

    ours = []
    for i, d in enumerate(sample):
        callers = json.loads(facts(args.exe, args.repo, "callers", d["qname"], "--file", d["path"], "--json"))
        refs = json.loads(facts(args.exe, args.repo, "refs", d["qname"], "--file", d["path"], "--json"))
        ours.append((callers, refs))

    request = {"files": program, "modules": modules, "queries": [{"id": i, "path": d["path"], "offset": d["name_start"]} for i, d in enumerate(sample)]}
    request_path = args.result + ".request.json"
    ts_path = args.result + ".tsserver.json"
    with open(request_path, "w", encoding="utf-8") as handle:
        json.dump(request, handle)
    node = subprocess.run([args.node, f"--max-old-space-size={args.heap_mb}", os.path.join(HERE, "facts_tsserver.cjs"), args.typescript, args.repo, request_path, ts_path], capture_output=True, text=True)
    if node.returncode != 0:
        raise SystemExit("tsserver script failed: " + node.stderr[-3000:])
    with open(ts_path, encoding="utf-8") as handle:
        ts = json.load(handle)

    same_name = SameName(args.exe, args.repo, defs)
    overrides = []
    rows = []
    totals = collections.Counter()
    classes = collections.Counter()
    unexplained = []
    for i, d in enumerate(sample):
        callers, refs = ours[i]
        sites = [s for s in callers.get("sites", []) if s["path"] in program_set]
        unknown = {(u["path"], u["start"]): u["reason"] for u in callers.get("unknown", [])}
        our_refs = {(s["path"], s["start"]): s["kind"] for s in refs.get("sites", [])}
        our_calls = {(s["path"], s["start"]): s for s in sites}
        result = ts["results"][i]
        ts_all = [r for r in result["refs"] if not r["definition"] and r["path"] in program_set]
        ts_calls = {(r["path"], r["start"]): r for r in ts_all if r["role"] in ("call", "new")}
        ts_any = {(r["path"], r["start"]): r["role"] for r in ts_all}
        both = set(our_calls) & set(ts_calls)
        only_ours = sorted(set(our_calls) - set(ts_calls))
        only_ts = sorted(set(ts_calls) - set(our_calls))
        totals["both"] += len(both)
        totals["only_ours"] += len(only_ours)
        totals["only_ts"] += len(only_ts)
        for key in only_ts:
            site = ts_calls[key]
            reason = classify_missing_from_ours(site, unknown, our_refs)
            if reason is None:
                other = same_name.owner(d, site)
                if other is not None:
                    reason = "emetgate binds it statically to another member of the same name (an override or another implementation of the same interface member); tsserver merges that family"
                    overrides.append({"subject": d["qname"], "path": site["path"], "line": site["line"], "bound_to": other})
            if reason is None:
                unexplained.append({"side": "tsserver only", "subject": d["qname"], "path": site["path"], "line": site["line"], "code": code_line(args.repo, site["path"], site["line"])})
                reason = "unexplained"
            classes["tsserver only: " + reason] += 1
        for key in only_ours:
            site = our_calls[key]
            reason = classify_missing_from_ts(site, ts_any, result["error"])
            if reason is None:
                reason = "tsserver finds no reference at this site; emetgate binds it " + site["certainty"]
                unexplained.append({"side": "emetgate only", "subject": d["qname"], "path": site["path"], "line": site["line"], "certainty": site["certainty"], "code": code_line(args.repo, site["path"], site["line"])})
            classes["emetgate only: " + reason] += 1
        rules = collections.Counter(u["rule"] for u in callers.get("unknown", []))
        rows.append({"subject": d["qname"], "path": d["path"], "kind": d["kind"], "status": callers["certificate"]["answer"], "both": len(both), "only_ours": len(only_ours), "only_ts": len(only_ts), "unknown_listed": len(unknown), "unknown_same_name": rules["same_name"], "unknown_dynamic_key": rules["dynamic_key"], "ts_error": result["error"]})

    ours_total = totals["both"] + totals["only_ours"]
    ts_total = totals["both"] + totals["only_ts"]
    summary = {
        "seed": args.seed,
        "count": len(sample),
        "program_files": len(program),
        "typescript": ts["version"],
        "tsserver_ms": ts["ms"],
        "tsserver_rss_mb": round(ts["rss"] / 1048576),
        "modules_resolved_for_tsserver": ts["resolved"],
        "modules_unresolved_for_tsserver": ts["unresolved"],
        "both": totals["both"],
        "only_emetgate": totals["only_ours"],
        "only_tsserver": totals["only_ts"],
        "partial_without_dynamic_key_rule": sum(1 for r in rows if r["status"] == "partial" and r["unknown_same_name"] == 0),
        "precision": round(totals["both"] / ours_total, 4) if ours_total else None,
        "recall": round(totals["both"] / ts_total, 4) if ts_total else None,
        "classes": dict(sorted(classes.items())),
        "rows": rows,
        "overrides": overrides,
        "unexplained": unexplained,
    }
    with open(args.result, "w", encoding="utf-8") as handle:
        json.dump(summary, handle, indent=1)
    print(json.dumps({k: v for k, v in summary.items() if k not in ("rows", "unexplained")}, indent=1))
    print(f"unexplained differences: {len(unexplained)}")


if __name__ == "__main__":
    sys.exit(main())
