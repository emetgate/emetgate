import argparse
import json
import os
import statistics
import subprocess
import sys
import time

BENCH = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BENCH)
from n8n_profile import DEFAULT_EXE, PROJECT_ROOT, McpSession

SCOREBOARD = os.path.join(PROJECT_ROOT, "eval", "scoreboard")
RG_ARGS = ["-n", "--no-heading", "--with-filename", "--hidden", "--no-config", "--path-separator", "/", "-g", "!.git", "-g", "!.emetgate", "-g", "!.serena"]
MAX_PAGES = 200


def rg_exe():
    for entry in os.environ.get("PATH", "").split(os.pathsep):
        entry = entry.strip().strip('"')
        if not os.path.isabs(entry):
            continue
        candidate = os.path.join(entry, "rg.exe")
        if os.path.isfile(candidate):
            return candidate
    sys.exit("rg.exe not found on PATH")


def rg_run(rg, repo, query):
    args = [rg, *RG_ARGS]
    args += ["-e", query["pattern"]] if query.get("regex") else ["-F", "-e", query["pattern"]]
    args.append(".")
    done = subprocess.run(args, cwd=repo, capture_output=True)
    text = done.stdout.decode("utf-8", "replace")
    hits = set()
    for line in text.splitlines():
        first = line.find(":")
        second = line.find(":", first + 1)
        if first < 0 or second < 0:
            continue
        path = line[:first]
        if path.startswith("./"):
            path = path[2:]
        hits.add((path, int(line[first + 1:second])))
    return text, hits


def parse_reply(text):
    lines = text.split("\n")
    status = lines[-1]
    hits = set()
    current = ""
    for line in lines[:-1]:
        if not line or line.startswith("|"):
            continue
        i = 0
        while i < len(line) and line[i].isdigit():
            i += 1
        if i and i < len(line) and line[i] in ":|*":
            hits.add((current, int(line[:i])))
        else:
            current = line
    return status, hits


def next_offset(status):
    marker = "next offset:"
    at = status.find(marker)
    if at < 0:
        return None
    return int(status[at + len(marker):].split(";")[0].strip())


def emetgate_run(session, query):
    args = {"pattern": query["pattern"], "regex": bool(query.get("regex"))}
    pages = []
    hits = set()
    offset = 0
    started = time.perf_counter()
    while len(pages) < MAX_PAGES:
        call = dict(args)
        if offset:
            call["offset"] = offset
        text, is_error, _ = session.call("emetgate_search", call)
        pages.append(text)
        if is_error:
            break
        status, page_hits = parse_reply(text)
        hits |= page_hits
        offset = next_offset(status)
        if offset is None:
            break
    return pages, hits, (time.perf_counter() - started) * 1000


def measure(exe, repo_name, rg):
    repo = os.path.join(SCOREBOARD, "repos", repo_name)
    queries = json.load(open(os.path.join(SCOREBOARD, "queries", f"{repo_name}-text.json"), encoding="utf-8"))["queries"]
    session = McpSession(exe, repo)
    rows = []
    try:
        session.call("emetgate_search", {"pattern": "warmup_token_absent_q"})
        for q in queries:
            rg_text, rg_hits = rg_run(rg, repo, q)
            pages, hits, ms = emetgate_run(session, q)
            first = pages[0] if pages else ""
            total_chars = sum(len(p) for p in pages)
            rows.append({
                "id": q["id"],
                "kind": q["kind"],
                "pattern": q["pattern"],
                "hits": len(rg_hits),
                "identical": hits == rg_hits,
                "missing": len(rg_hits - hits),
                "extra": len(hits - rg_hits),
                "calls": len(pages),
                "rg_chars": len(rg_text),
                "first_page_chars": len(first),
                "all_pages_chars": total_chars,
                "ratio_all": round(total_chars / len(rg_text), 3) if rg_text else None,
                "ratio_first": round(len(first) / len(rg_text), 3) if rg_text else None,
                "status": first.split("\n")[-1][:200],
                "ms": round(ms, 2),
            })
    finally:
        session.close()
    with_hits = [r for r in rows if r["ratio_all"] is not None]
    summary = {
        "repo": repo_name,
        "queries": len(rows),
        "identical": sum(r["identical"] for r in rows),
        "with_hits": len(with_hits),
        "ratio_all_median": round(statistics.median(r["ratio_all"] for r in with_hits), 3) if with_hits else None,
        "ratio_all_max": max((r["ratio_all"] for r in with_hits), default=None),
        "ratio_first_median": round(statistics.median(r["ratio_first"] for r in with_hits), 3) if with_hits else None,
        "chars_all": sum(r["all_pages_chars"] for r in with_hits),
        "chars_rg": sum(r["rg_chars"] for r in with_hits),
        "calls_max": max((r["calls"] for r in rows), default=0),
    }
    summary["ratio_total"] = round(summary["chars_all"] / summary["chars_rg"], 3) if summary["chars_rg"] else None
    return summary, rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", default=DEFAULT_EXE)
    ap.add_argument("--repos", nargs="*", default=["express", "eslint"])
    ap.add_argument("--json")
    args = ap.parse_args()
    rg = rg_exe()
    out = {"date": time.strftime("%Y-%m-%d"), "repos": []}
    for name in args.repos:
        summary, rows = measure(args.exe, name, rg)
        out["repos"].append({"summary": summary, "rows": rows})
        print(json.dumps(summary, ensure_ascii=False), flush=True)
        for r in rows:
            flag = "" if r["identical"] else "  NOT IDENTICAL"
            print(f"  {r['id']:12} {r['hits']:4} hits  rg {r['rg_chars']:6}  ours {r['all_pages_chars']:6} in {r['calls']} call(s)  ratio {r['ratio_all']}{flag}")
    if args.json:
        with open(args.json, "w", encoding="utf-8", newline="\n") as f:
            json.dump(out, f, indent=2, ensure_ascii=False)
            f.write("\n")


if __name__ == "__main__":
    main()
