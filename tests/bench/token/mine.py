import argparse
import heapq
import json
import os
import re
import sys
import time
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from transcripts import PRICE, base_usd, iter_sessions

BUCKETS = ["input", "cache_write_1h", "cache_write_5m", "cache_read", "output"]
CONTEXT_BANDS = [(0, 20000), (20000, 50000), (50000, 100000), (100000, 200000), (200000, 10 ** 12)]
RENT_WRITE = 2.0
RENT_READ = PRICE["cache_read"]
TOP_RESULTS = 30
FOLLOW_DEPTH = 3
MIN_TRIGGER_COUNT = 5

TEST_RE = re.compile(r"(\bzig\s+(build\s+)?test\b|\bpytest\b|\b(npm|pnpm|yarn)\s+(run\s+)?test\b|\b(go|cargo|dotnet|deno|bun)\s+test\b|\bjest\b|\bvitest\b|-m\s+(pytest|unittest)\b|\bnode\s+--test\b|\bmocha\b|\bctest\b)", re.I)
ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
SEGMENT_RE = re.compile(r"&&|\|\||;|\n")
SETUP_WORDS = {"cd", "export", "set", "source", ".", "set -e", "pushd"}
FAIL_RE = re.compile(r"(\bFAIL(ED)?\b|\b[1-9]\d* (failed|failing)\b|AssertionError|panic:|[Ee]xit code [1-9]|\"exit_code\":[1-9]|\"outcome\":\"(fail|error|timeout)|error: )")
PATH_RE = re.compile(r"(?:[A-Za-z]:)?[\w.\-/\\]*[\w\-]\.[A-Za-z][A-Za-z0-9]{0,5}\b")
READ_CMD_RE = re.compile(r"^\s*(cat|head|tail|less|type|Get-Content|gc|sed\s+-n\s+\S+)\s+(?:-\S+\s+)*['\"]?([^\s'\"|;&>]+)")
SEARCH_CMD_RE = re.compile(r"^\s*(grep|rg|findstr|Select-String|find|ls|dir|Get-ChildItem)\b")
LEAD_RE = re.compile(r"^\s*(cd\s+[^;&]+(?:&&|;)\s*)+")
SECRET_KEYS = {"content", "new_string", "old_string", "body", "text", "message", "prompt", "edits", "payload", "code", "questions", "actions"}

READ_TOOLS = {"Read", "eg.read_file", "eg.read_symbol", "eg.skeleton", "eg.symbols"}
EDIT_TOOLS = {"Edit", "Write", "NotebookEdit", "eg.edit", "eg.write", "eg.try_batch", "eg.mutate", "eg.try", "eg.rename", "eg.write_doc"}
SEARCH_TOOLS = {"Grep", "Glob", "eg.search", "eg.find", "eg.list"}
SHELL_TOOLS = {"Bash", "PowerShell", "eg.run"}


def short(name):
    if name.startswith("mcp__emetgate__emetgate_"):
        return "eg." + name[len("mcp__emetgate__emetgate_"):]
    if name.startswith("emetgate_"):
        return "eg." + name[len("emetgate_"):]
    if name.startswith("mcp__"):
        bits = name.split("__")
        return bits[1].split("_")[-1] + "." + bits[-1] if len(bits) > 2 else name
    return name


def command_of(use):
    cmd = use.input.get("command")
    if isinstance(cmd, list):
        cmd = " ".join(str(c) for c in cmd)
    return LEAD_RE.sub("", cmd or "")


def command_kind(cmd):
    if TEST_RE.search(cmd):
        return "test"
    words = []
    for segment in SEGMENT_RE.split(cmd):
        words = [w for w in segment.strip().split() if not ASSIGN_RE.match(w)]
        if words and words[0] not in SETUP_WORDS:
            break
        words = []
    if not words:
        return "empty"
    first = os.path.basename(words[0].strip("'\"&")).lower()
    if first in ("git", "gh") and len(words) > 1:
        return first + " " + words[1]
    if first == "zig" and len(words) > 1:
        return "zig " + words[1]
    return first[:20]


def arg_kind(use):
    tool = short(use.name)
    args = use.input
    if tool == "eg.read_file":
        if args.get("files"):
            return "multi"
        for key in ("heading", "pointer"):
            if args.get(key):
                return key
        if args.get("line_start") is not None or args.get("line_end") is not None:
            return "range"
        return "whole_raw" if args.get("raw") else "whole"
    if tool == "eg.read_symbol":
        if args.get("symbols"):
            return "symbols"
        if args.get("symbol"):
            return "symbol"
        if args.get("line_start") is not None:
            return "range"
        return "other"
    if tool == "eg.search":
        kind = "regex" if args.get("regex") else "literal"
        return kind + ("+detail" if args.get("detail") else "")
    if tool == "eg.git":
        return str(args.get("sub") or "")
    if tool == "Read":
        return "range" if args.get("offset") is not None or args.get("limit") is not None else "whole"
    if tool == "eg.run" and not command_of(use):
        return "default_test" if use.result_text.startswith('{"status":"ran"') else "allowlist"
    if tool in SHELL_TOOLS:
        return command_kind(command_of(use))
    if tool == "Grep":
        return str(args.get("output_mode") or "files_with_matches")
    return ""


def norm_path(path):
    if not isinstance(path, str) or not path:
        return None
    path = path.strip().strip("'\"").replace("\\", "/").lower()
    while path.startswith("./"):
        path = path[2:]
    return path or None


def same_path(a, b):
    if not a or not b:
        return False
    return a == b or a.endswith("/" + b) or b.endswith("/" + a)


def file_of(use):
    args = use.input
    keys = ("file_path", "file", "notebook_path", "path") if short(use.name) == "eg.git" else ("file_path", "file", "notebook_path")
    for key in keys:
        if isinstance(args.get(key), str):
            return norm_path(args[key])
    edits = args.get("edits")
    if isinstance(edits, list) and edits and isinstance(edits[0], dict):
        return norm_path(edits[0].get("file"))
    if short(use.name) in SHELL_TOOLS:
        match = READ_CMD_RE.match(command_of(use))
        if match:
            return norm_path(match.group(2))
    return None


def role(use):
    tool = short(use.name)
    if tool in READ_TOOLS:
        return "read"
    if tool in EDIT_TOOLS:
        return "edit"
    if tool in SEARCH_TOOLS:
        return "search"
    if tool in SHELL_TOOLS:
        cmd = command_of(use)
        if tool == "eg.run" and not cmd:
            return "test" if use.result_text.startswith('{"status":"ran"') else "other"
        if TEST_RE.search(cmd):
            return "test"
        if READ_CMD_RE.match(cmd):
            return "read"
        if SEARCH_CMD_RE.match(cmd):
            return "search"
        return "shell"
    return "other"


def failed(use):
    return use.is_error or bool(FAIL_RE.search(use.result_text[:20000]))


def hits(use):
    found = []
    for match in PATH_RE.finditer(use.result_text[:20000]):
        path = norm_path(match.group(0))
        if path and path not in found:
            found.append(path)
        if len(found) >= 50:
            break
    return found


def pattern(trigger, follow):
    t_tool, f_tool = short(trigger.name), short(follow.name)
    t_role, f_role = role(trigger), role(follow)
    t_file, f_file = file_of(trigger), file_of(follow)
    same = same_path(t_file, f_file)
    if t_role == "test" and failed(trigger):
        if f_role == "test":
            return "rerun_test_after_fail"
        return "after_failing_test:" + f_role
    if trigger.is_error:
        return "retry_same_tool_after_error" if f_tool == t_tool else "other_tool_after_error"
    if t_tool in ("eg.skeleton", "eg.symbols") and f_tool == "eg.read_symbol" and same:
        return "read_symbol_after_skeleton"
    if t_role == "read" and f_role == "read":
        return "same_file_reread" if same else "read_other_file"
    if t_role == "read" and f_role == "edit":
        return "edit_after_read_same_file" if same else "edit_other_file_after_read"
    if t_role == "edit" and f_role == "read":
        return "read_after_edit_same_file" if same else "read_other_file_after_edit"
    if t_role == "edit" and f_role == "edit":
        return "edit_same_file_again" if same else "edit_other_file"
    if t_role == "edit" and f_role == "test":
        return "test_after_edit"
    if t_role == "search" and f_role == "read":
        found = hits(trigger)
        if f_file and found and same_path(found[0], f_file):
            return "read_top_search_hit"
        if f_file and any(same_path(h, f_file) for h in found):
            return "read_other_search_hit"
        return "read_unlisted_file_after_search"
    if t_role == "search" and f_role == "search":
        return "search_again"
    if t_role == "test" and f_role == "test":
        return "test_again_after_pass"
    if f_role == "shell":
        return "then:shell:" + command_kind(command_of(follow))
    if f_role == "other":
        return "then:" + f_tool
    return "then:" + f_role


def args_summary(use):
    parts = []
    for key, value in use.input.items():
        if key in SECRET_KEYS:
            continue
        if isinstance(value, (dict, list)):
            value = "<%s>" % type(value).__name__
        parts.append("%s=%s" % (key, str(value).splitlines()[0][:100] if str(value) else ""))
    if isinstance(use.input.get("edits"), list):
        parts.append("edits=%d" % len(use.input["edits"]))
    return " ".join(parts)[:240]


def quantile(values, q):
    if not values:
        return None
    ordered = sorted(values)
    index = q * (len(ordered) - 1)
    low = int(index)
    high = min(low + 1, len(ordered) - 1)
    return ordered[low] + (ordered[high] - ordered[low]) * (index - low)


def stats(values):
    return {"median": quantile(values, 0.5), "p90": quantile(values, 0.9), "n": len(values)}


def band_of(context):
    for low, high in CONTEXT_BANDS:
        if low <= context < high:
            return "%dk-%s" % (low // 1000, "inf" if high > 10 ** 11 else "%dk" % (high // 1000))
    return "?"


class Miner:
    def __init__(self):
        self.sessions = []
        self.tool_attr = defaultdict(lambda: {"results": 0, "tokens": 0.0, "rent_units": 0.0, "rent_usd": 0.0, "chars": 0, "errors": 0})
        self.kind_attr = defaultdict(lambda: {"results": 0, "tokens": 0.0, "rent_units": 0.0, "rent_usd": 0.0, "chars": 0, "errors": 0})
        self.top = []
        self.turn_cost = defaultdict(list)
        self.next_counts = defaultdict(lambda: {"n": 0, "next1": Counter(), "within3": Counter(), "cost": defaultdict(list)})
        self.cost_pairs = []
        self.by_conversation = defaultdict(list)
        self.rebuild_units = 0.0
        self.rebuild_usd = Counter()
        self.written_units = 0.0
        self.serial = 0

    def add(self, session):
        calls = session.calls
        billed = [c for c in calls if not c.duplicate]
        if not billed:
            return
        mode = session.mode
        later_in_segment = [0] * len(calls)
        per_segment = Counter()
        for index in range(len(calls) - 1, -1, -1):
            if index + 2 < len(calls):
                per_segment[calls[index + 2].segment] += 1
            later_in_segment[index] = per_segment[calls[index].segment]
        written_tokens = 0
        tool_tokens = 0.0
        for index, call in enumerate(calls):
            if call.duplicate:
                continue
            written_tokens += call.input + call.cache_write
            cost = call.usd()
            self.turn_cost[(mode, band_of(call.context))].append(cost)
            self.turn_cost[("all", band_of(call.context))].append(cost)
            if index + 1 >= len(calls):
                continue
            nxt = calls[index + 1]
            pool = nxt.input + nxt.cache_write
            growth = nxt.context - call.context
            attributable = min(pool, growth) if growth > 0 else 0
            self.rebuild_units += (pool - attributable)
            if pool > attributable:
                cause = "after_user_prompt" if call.prompt_after else "compaction" if call.segment != nxt.segment else "inside_tool_loop"
                write_price = (nxt.cache_write_1h * PRICE["cache_write_1h"] + nxt.cache_write_5m * PRICE["cache_write_5m"]) / max(nxt.cache_write, 1)
                self.rebuild_usd["%s|%s|%s" % (mode, "subagent" if session.is_subagent else "main", cause)] += (pool - attributable) * write_price * base_usd(nxt.model) / 1e6
            self.written_units += pool
            remaining = attributable - min(attributable, call.output)
            results = [u for u in call.tool_uses if u.has_result]
            chars = sum(u.result_chars for u in results) + call.other_chars
            if remaining <= 0 or chars <= 0:
                continue
            base = base_usd(call.model)
            for use in results:
                tokens = remaining * use.result_chars / chars
                tool_tokens += tokens
                rent = tokens * (RENT_WRITE + RENT_READ * later_in_segment[index])
                rent_usd = rent * base / 1e6
                for table, key in ((self.tool_attr, short(use.name)), (self.kind_attr, (short(use.name), arg_kind(use)))):
                    row = table[key]
                    row["results"] += 1
                    row["tokens"] += tokens
                    row["rent_units"] += rent
                    row["rent_usd"] += rent_usd
                    row["chars"] += use.result_chars
                    row["errors"] += int(use.is_error)
                self.serial += 1
                entry = (rent, self.serial, {
                    "tool": short(use.name),
                    "kind": arg_kind(use),
                    "args": args_summary(use),
                    "tokens": round(tokens),
                    "chars": use.result_chars,
                    "later_calls": later_in_segment[index],
                    "rent_units": round(rent),
                    "rent_usd": round(rent_usd, 4),
                    "mode": mode,
                    "project": session.project,
                })
                if len(self.top) < TOP_RESULTS:
                    heapq.heappush(self.top, entry)
                else:
                    heapq.heappushpop(self.top, entry)
        self.add_next(calls)
        units = Counter()
        for call in billed:
            for bucket, value in call.units().items():
                units[bucket] += value * base_usd(call.model) / 1e6
        tokens = Counter()
        models = defaultdict(Counter)
        for call in billed:
            for bucket in BUCKETS:
                tokens[bucket] += getattr(call, bucket)
                models[call.model][bucket] += getattr(call, bucket)
        self.sessions.append({
            "mode": mode,
            "subagent": session.is_subagent,
            "model": session.model,
            "turns": len(billed),
            "usd": sum(units.values()),
            "usd_buckets": dict(units),
            "tokens": dict(tokens),
            "first_context": calls[0].context,
            "tool_share": tool_tokens / written_tokens if written_tokens else 0.0,
        })
        key = (session.project, session.session_id)
        self.by_conversation[key].append({"subagent": session.is_subagent, "models": {m: dict(c) for m, c in models.items()}, "cost_state": session.cost_state})

    def add_next(self, calls):
        prompts = [0]
        for call in calls:
            prompts.append(prompts[-1] + int(call.prompt_after))
        flat = []
        for index, call in enumerate(calls):
            for use in call.tool_uses:
                flat.append((index, use))
        for position, (index, use) in enumerate(flat):
            if calls[index].duplicate:
                continue
            follows = []
            stop = False
            boundary = calls[index].prompt_after
            for other_index, other in flat[position + 1:]:
                if other_index == index:
                    continue
                if boundary or prompts[other_index] - prompts[index + 1] > 0:
                    stop = True
                    break
                follows.append((other_index, other))
                if len(follows) >= FOLLOW_DEPTH:
                    break
            key = "%s:%s" % (short(use.name), arg_kind(use)) if arg_kind(use) else short(use.name)
            row = self.next_counts[key]
            row["n"] += 1
            if not follows:
                row["next1"]["stop_for_user" if stop or boundary else "session_end"] += 1
                continue
            seen = set()
            for depth, (other_index, other) in enumerate(follows):
                label = pattern(use, other)
                if depth == 0:
                    row["next1"][label] += 1
                    row["cost"][label].append(calls[other_index].usd())
                if label not in seen:
                    seen.add(label)
                    row["within3"][label] += 1

    def compare_costs(self):
        rows = []
        for parts in self.by_conversation.values():
            state = next((p["cost_state"] for p in parts if not p["subagent"] and p["cost_state"]), None)
            if not state:
                continue
            reported = state.get("modelUsage") or {}
            for include_subs in (False, True):
                mine = defaultdict(Counter)
                for part in parts:
                    if part["subagent"] and not include_subs:
                        continue
                    for model, buckets in part["models"].items():
                        mine[model].update(buckets)
                for model, buckets in mine.items():
                    theirs = reported.get(model)
                    if not theirs:
                        continue
                    my_read = buckets["cache_read"]
                    their_read = theirs.get("cacheReadInputTokens") or 0
                    my_usd = sum(buckets[b] * PRICE[b] for b in BUCKETS) * base_usd(model) / 1e6
                    rows.append({
                        "subagents_included": include_subs,
                        "model": model,
                        "token_ratio": my_read / their_read if their_read else None,
                        "usd_ratio": my_usd / theirs["costUSD"] if theirs.get("costUSD") else None,
                        "my_usd": my_usd,
                        "their_usd": theirs.get("costUSD") or 0,
                    })
        summary = {}
        for include_subs in (False, True):
            for model in sorted({r["model"] for r in rows}):
                chosen = [r for r in rows if r["subagents_included"] == include_subs and r["model"] == model]
                token_ratios = [r["token_ratio"] for r in chosen if r["token_ratio"]]
                usd_ratios = [r["usd_ratio"] for r in chosen if r["usd_ratio"]]
                summary["%s|subagents=%s" % (model, include_subs)] = {
                    "sessions": len(chosen),
                    "cache_read_token_ratio": stats(token_ratios),
                    "within_1pct_tokens": sum(1 for r in token_ratios if abs(r - 1) <= 0.01),
                    "usd_ratio": stats(usd_ratios),
                    "my_usd_total": sum(r["my_usd"] for r in chosen),
                    "reported_usd_total": sum(r["their_usd"] for r in chosen),
                }
        return summary

    def baseline(self):
        out = {}
        groups = defaultdict(list)
        for row in self.sessions:
            groups[(row["mode"], "all")].append(row)
            groups[(row["mode"], "subagent" if row["subagent"] else "main")].append(row)
            groups[("all", "all")].append(row)
        for (mode, scope), rows in sorted(groups.items()):
            total = sum(r["usd"] for r in rows)
            out["%s|%s" % (mode, scope)] = {
                "sessions": len(rows),
                "turns": stats([r["turns"] for r in rows]),
                "usd": stats([r["usd"] for r in rows]),
                "usd_total": total,
                "usd_buckets": {b: stats([r["usd_buckets"].get(b, 0) for r in rows]) for b in BUCKETS},
                "usd_bucket_share": {b: (sum(r["usd_buckets"].get(b, 0) for r in rows) / total if total else 0) for b in BUCKETS},
                "first_context": stats([r["first_context"] for r in rows]),
                "tool_result_share": stats([r["tool_share"] for r in rows]),
            }
        return out


def fmt(value, digits=2):
    if value is None:
        return "-"
    if isinstance(value, float):
        return ("%." + str(digits) + "f") % value
    return str(value)


def write_baseline(out_dir, miner, elapsed, files):
    base = miner.baseline()
    costs = miner.compare_costs()
    turn = {}
    for (mode, band), values in sorted(miner.turn_cost.items()):
        turn.setdefault(mode, {})[band] = stats(values)
    payload = {
        "files": files,
        "seconds": elapsed,
        "price_units": PRICE,
        "modes": base,
        "cost_check": costs,
        "turn_cost": turn,
        "rebuild_share_of_written": miner.rebuild_units / miner.written_units if miner.written_units else 0,
        "rebuild_usd": dict(sorted(miner.rebuild_usd.items())),
    }
    with open(os.path.join(out_dir, "baseline.json"), "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=1)
    lines = ["# Token baseline", "", "files %d, %.1fs, prices in input units %s" % (files, elapsed, json.dumps(PRICE)), ""]
    lines += ["## Sessions per mode", "", "| mode | scope | n | turns med/p90 | $ med/p90 | $ total | base ctx med/p90 | tool share med/p90 |", "|---|---|---|---|---|---|---|---|"]
    for key, row in base.items():
        mode, scope = key.split("|")
        lines.append("| %s | %s | %d | %s / %s | %s / %s | %s | %s / %s | %s / %s |" % (
            mode, scope, row["sessions"],
            fmt(row["turns"]["median"], 0), fmt(row["turns"]["p90"], 0),
            fmt(row["usd"]["median"], 3), fmt(row["usd"]["p90"], 3), fmt(row["usd_total"], 1),
            fmt(row["first_context"]["median"], 0), fmt(row["first_context"]["p90"], 0),
            fmt(row["tool_result_share"]["median"]), fmt(row["tool_result_share"]["p90"])))
    lines += ["", "## $ share by bucket", "", "| mode | scope | " + " | ".join(BUCKETS) + " |", "|---|---|" + "---|" * len(BUCKETS)]
    for key, row in base.items():
        mode, scope = key.split("|")
        lines.append("| %s | %s | %s |" % (mode, scope, " | ".join(fmt(row["usd_bucket_share"][b]) for b in BUCKETS)))
    lines += ["", "## Median $ by bucket per session", "", "| mode | scope | " + " | ".join(BUCKETS) + " |", "|---|---|" + "---|" * len(BUCKETS)]
    for key, row in base.items():
        mode, scope = key.split("|")
        lines.append("| %s | %s | %s |" % (mode, scope, " | ".join(fmt(row["usd_buckets"][b]["median"], 4) for b in BUCKETS)))
    lines += ["", "## Check against cost-state totalCostUSD", "", "| model / scope | n | cache_read tokens ratio med | within 1% | $ ratio med/p90 | mine $ | reported $ |", "|---|---|---|---|---|---|---|"]
    for key, row in costs.items():
        if not row["sessions"]:
            continue
        lines.append("| %s | %d | %s | %d | %s / %s | %s | %s |" % (
            key, row["sessions"], fmt(row["cache_read_token_ratio"]["median"], 3), row["within_1pct_tokens"],
            fmt(row["usd_ratio"]["median"], 3), fmt(row["usd_ratio"]["p90"], 3), fmt(row["my_usd_total"], 1), fmt(row["reported_usd_total"], 1)))
    lines += ["", "## Cost of one turn by context size", "", "| mode | band | n | $ med | $ p90 |", "|---|---|---|---|---|"]
    for mode, bands in turn.items():
        for band, row in sorted(bands.items(), key=lambda kv: int(kv[0].split("k")[0])):
            lines.append("| %s | %s | %d | %s | %s |" % (mode, band, row["n"], fmt(row["median"], 4), fmt(row["p90"], 4)))
    lines += ["", "## Cache rebuilds", "", "share of written tokens not explained by context growth: %s" % fmt(payload["rebuild_share_of_written"], 3), "", "| mode | scope | cause | $ |", "|---|---|---|---|"]
    for key, usd in payload["rebuild_usd"].items():
        lines.append("| %s | %.2f |" % (key.replace("|", " | "), usd))
    with open(os.path.join(out_dir, "baseline.md"), "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")


def write_attribution(out_dir, miner):
    tools = sorted(miner.tool_attr.items(), key=lambda kv: -kv[1]["rent_usd"])
    kinds = sorted(miner.kind_attr.items(), key=lambda kv: -kv[1]["rent_usd"])
    top = [entry for _, _, entry in sorted(miner.top, reverse=True)]
    payload = {
        "per_tool": {k: v for k, v in tools},
        "per_kind": {"%s:%s" % k: v for k, v in kinds},
        "top_results": top,
    }
    with open(os.path.join(out_dir, "attribution.json"), "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=1)
    lines = ["# Attribution and rent", "", "rent = tokens x (%.1f + %.1f x later calls in the same compaction segment), input units" % (RENT_WRITE, RENT_READ), ""]
    lines += ["## Per tool", "", "| tool | results | cache_write tok | tok/result | rent units | rent $ | errors |", "|---|---|---|---|---|---|---|"]
    for name, row in tools:
        lines.append("| %s | %d | %d | %d | %d | %.2f | %d |" % (name, row["results"], row["tokens"], row["tokens"] / max(row["results"], 1), row["rent_units"], row["rent_usd"], row["errors"]))
    lines += ["", "## Per tool and argument kind", "", "| tool | kind | results | cache_write tok | tok/result | rent $ |", "|---|---|---|---|---|---|"]
    for (name, kind), row in kinds:
        if row["results"] < 3 and not name.startswith("eg."):
            continue
        lines.append("| %s | %s | %d | %d | %d | %.2f |" % (name, kind or "-", row["results"], row["tokens"], row["tokens"] / max(row["results"], 1), row["rent_usd"]))
    lines += ["", "## %d most expensive single results" % TOP_RESULTS, "", "| tool | kind | args | tokens | later calls | rent units | rent $ | mode |", "|---|---|---|---|---|---|---|---|"]
    for row in top:
        lines.append("| %s | %s | %s | %d | %d | %d | %.3f | %s |" % (row["tool"], row["kind"] or "-", row["args"].replace("|", "/"), row["tokens"], row["later_calls"], row["rent_units"], row["rent_usd"], row["mode"]))
    with open(os.path.join(out_dir, "attribution.md"), "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")


def write_next(out_dir, miner):
    table = {}
    pairs = []
    for key, row in miner.next_counts.items():
        n = row["n"]
        entry = {"n": n, "next1": {}, "within3": {}}
        for label, count in row["next1"].most_common():
            costs = row["cost"].get(label, [])
            entry["next1"][label] = {"count": count, "p": count / n, "turn_usd": stats(costs)}
            pairs.append((count, key, label, count / n, stats(costs)))
        for label, count in row["within3"].most_common():
            entry["within3"][label] = {"count": count, "p": count / n}
        table[key] = entry
    with open(os.path.join(out_dir, "next.json"), "w", encoding="utf-8") as handle:
        json.dump(dict(sorted(table.items(), key=lambda kv: -kv[1]["n"])), handle, indent=1)
    totals = Counter()
    for row in miner.next_counts.values():
        totals.update(row["next1"])
    all_n = sum(totals.values())
    lines = ["# What the model asks for next", "", "## Most common immediate follow-up patterns", "", "| pattern | count | share |", "|---|---|---|"]
    for label, count in totals.most_common(25):
        lines.append("| %s | %d | %.3f |" % (label, count, count / all_n))
    lines += ["", "## Top trigger -> follow-up pairs", "", "| trigger | follow-up | count | P(next1) | turn $ med | turn $ p90 |", "|---|---|---|---|---|---|"]
    for count, key, label, p, cost in sorted(pairs, key=lambda x: -x[0])[:40]:
        lines.append("| %s | %s | %d | %.2f | %s | %s |" % (key, label, count, p, fmt(cost["median"], 4), fmt(cost["p90"], 4)))
    lines += ["", "## Per trigger (n >= %d)" % MIN_TRIGGER_COUNT, ""]
    for key, entry in sorted(table.items(), key=lambda kv: -kv[1]["n"]):
        if entry["n"] < MIN_TRIGGER_COUNT:
            continue
        first = ", ".join("%s %.2f (%d, $%s)" % (l, v["p"], v["count"], fmt(v["turn_usd"]["median"], 3)) for l, v in list(entry["next1"].items())[:5])
        within = ", ".join("%s %.2f" % (l, v["p"]) for l, v in list(entry["within3"].items())[:4])
        lines.append("- **%s** n=%d; next1: %s; within3: %s" % (key, entry["n"], first, within))
    with open(os.path.join(out_dir, "next.md"), "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=os.path.join(os.path.expanduser("~"), ".claude", "projects"))
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    out_dir = os.path.abspath(args.out)
    repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    if os.path.normcase(out_dir).startswith(os.path.normcase(repo) + os.sep):
        raise SystemExit("refusing to write miner output inside the repo")
    os.makedirs(out_dir, exist_ok=True)
    start = time.time()
    miner = Miner()
    files = 0
    for session in iter_sessions(args.root):
        files += 1
        miner.add(session)
    elapsed = time.time() - start
    write_baseline(out_dir, miner, elapsed, files)
    write_attribution(out_dir, miner)
    write_next(out_dir, miner)
    print("files %d sessions %d in %.1fs -> %s" % (files, len(miner.sessions), time.time() - start, out_dir))


if __name__ == "__main__":
    main()
