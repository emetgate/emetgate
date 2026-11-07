import argparse
import hashlib
import json
import os
import sys
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from mine import EDIT_TOOLS, FOLLOW_DEPTH, SHELL_TOOLS, arg_kind, file_of, pattern, quantile, role, short
from transcripts import base_usd, iter_sessions, price_units

CHARS_PER_TOKEN = 3.2
HANDLE_TOKENS = 10.0
ASK_WRITE = 200.0
ASK_OUTPUT = 150.0
PART_TOKENS = 1000.0
PREFETCHABLE = ("read_top_search_hit", "read_symbol_after_skeleton", "test_after_edit", "same_file_reread")
TAIL_LABELS = ("same_file_reread", "read_symbol_after_skeleton")
MIN_SUPPORT = 20


def key_of(use):
    kind = arg_kind(use)
    return "%s:%s" % (short(use.name), kind) if kind else short(use.name)


def tokens_of(use):
    return use.result_chars / CHARS_PER_TOKEN


def split_of(session):
    digest = hashlib.sha1(("%s/%s" % (session.project, session.session_id)).encode()).digest()
    return "train" if digest[0] % 2 == 0 else "test"


class Prices:
    def __init__(self, model):
        units = price_units(model)
        self.write = units["cache_write_1h"]
        self.read = units["cache_read"]
        self.output = units["output"]
        self.usd = base_usd(model) / 1e6

    def turn(self, context):
        return self.read * context + self.write * ASK_WRITE + self.output * ASK_OUTPUT

    def rent(self, tokens, remaining):
        return tokens * (self.write + self.read * max(remaining, 0))


def gain(prices, context, remaining, need, tokens):
    return need * prices.turn(context) - prices.rent(tokens, remaining) + prices.rent(HANDLE_TOKENS, remaining)


class View:
    def __init__(self, session):
        self.session = session
        self.calls = session.calls
        later = [0] * len(self.calls)
        per_segment = Counter()
        for index in range(len(self.calls) - 1, -1, -1):
            if index + 2 < len(self.calls):
                per_segment[self.calls[index + 2].segment] += 1
            later[index] = per_segment[self.calls[index].segment]
        self.later = later
        self.flat = [(index, use) for index, call in enumerate(self.calls) for use in call.tool_uses if use.has_result]
        prompts = [0]
        for call in self.calls:
            prompts.append(prompts[-1] + int(call.prompt_after))
        self.prompts = prompts

    def follows(self, position):
        index, _ = self.flat[position]
        if self.calls[index].prompt_after:
            return []
        found = []
        for other_index, other in self.flat[position + 1:]:
            if other_index == index:
                continue
            if self.prompts[other_index] - self.prompts[index + 1] > 0:
                break
            found.append((other_index, other))
            if len(found) >= FOLLOW_DEPTH:
                break
        return found

    def labelled(self):
        for position, (index, use) in enumerate(self.flat):
            if self.calls[index].duplicate:
                continue
            follows = self.follows(position)
            labels = []
            for other_index, other in follows:
                labels.append((pattern(use, other), other_index, other))
            yield position, index, use, labels


def build_table(views):
    counts = defaultdict(lambda: {"n": 0, "labels": Counter(), "sizes": defaultdict(list)})
    remaining = []
    outputs = []
    for view in views:
        for call in view.calls:
            if not call.duplicate:
                outputs.append(call.output)
        for position, index, use, labels in view.labelled():
            row = counts[key_of(use)]
            row["n"] += 1
            remaining.append(view.later[index])
            seen = set()
            for label, _, other in labels:
                if label in seen:
                    continue
                seen.add(label)
                row["labels"][label] += 1
                row["sizes"][label].append(tokens_of(other))
    table = {}
    for key, row in counts.items():
        if row["n"] < MIN_SUPPORT:
            continue
        entry = {"n": row["n"], "follow": {}}
        for label, hits in row["labels"].items():
            entry["follow"][label] = {"p": hits / row["n"], "tokens": quantile(row["sizes"][label], 0.5)}
        table[key] = entry
    return {
        "parts": table,
        "remaining_median": quantile(remaining, 0.5),
        "output_median": quantile(outputs, 0.5),
        "prefetchable": list(PREFETCHABLE),
        "tail_labels": list(TAIL_LABELS),
    }


def tail_need(table, key):
    follow = (table["parts"].get(key) or {}).get("follow") or {}
    return sum(follow.get(label, {}).get("p", 0) for label in TAIL_LABELS)


def mutates(use, path):
    tool = short(use.name)
    if tool in EDIT_TOOLS:
        target = file_of(use)
        return target is None or path is None or target == path
    if tool in SHELL_TOOLS and role(use) in ("shell", "test"):
        return True
    return False


class Score:
    def __init__(self):
        self.parts = Counter()

    def add(self, name, units, usd_per_unit):
        self.parts[name] += units * usd_per_unit

    def total(self):
        return sum(self.parts.values())


def score_session(view, table, eg_only):
    main = Score()
    policy = Score()
    events = Counter()
    seen = {}
    error_next = set()
    for position, (index, use) in enumerate(view.flat):
        if use.is_error:
            nxt = view.follows(position)
            if nxt:
                error_next.add(nxt[0][0])
    prefetched = set()
    missed = set()
    saved = set()
    for position, index, use, labels in view.labelled():
        call = view.calls[index]
        prices = Prices(call.model)
        usd = prices.usd
        remaining = view.later[index]
        context = call.context
        size = tokens_of(use)
        rent = prices.rent(size, remaining)
        main.add("rent", rent, usd)
        governed = short(use.name).startswith("eg.") or not eg_only
        signature = (short(use.name), json.dumps(use.input, sort_keys=True))
        path = file_of(use)
        for earlier, (sig_index, sig_path) in list(seen.items()):
            if mutates(use, sig_path):
                del seen[earlier]
        if (index, use.id) in prefetched:
            policy.add("rent", prices.rent(HANDLE_TOKENS, remaining), usd)
            saved.add(index)
            events["prefetch_hit"] += 1
        elif governed and role(use) == "read" and signature in seen and not use.is_error:
            policy.add("rent", prices.rent(HANDLE_TOKENS, remaining), usd)
            events["unchanged"] += 1
        elif governed and size > PART_TOKENS:
            need = tail_need(table, key_of(use))
            tail = size - PART_TOKENS
            pieces = int(tail // PART_TOKENS) + (1 if tail % PART_TOKENS else 0)
            sent = PART_TOKENS
            expected = 0.0
            for piece in range(pieces):
                piece_tokens = min(PART_TOKENS, tail - piece * PART_TOKENS)
                share = need / pieces
                if gain(prices, context, remaining, share, piece_tokens) > 0:
                    sent += piece_tokens
                else:
                    sent += HANDLE_TOKENS
                    expected += share * (prices.turn(context) + prices.rent(piece_tokens, remaining))
                    events["tail_handle"] += 1
            policy.add("rent", prices.rent(sent, remaining), usd)
            policy.add("expected_miss", expected, usd)
        else:
            policy.add("rent", rent, usd)
        if governed and role(use) == "read" and not use.is_error:
            seen[signature] = (index, path)
        for label, other_index, other in labels:
            if label in PREFETCHABLE:
                missed.add(other_index)
        if governed:
            follow = (table["parts"].get(key_of(use)) or {}).get("follow") or {}
            for label in PREFETCHABLE:
                stat = follow.get(label)
                if not stat or not stat["tokens"]:
                    continue
                if gain(prices, context, remaining, stat["p"], stat["tokens"]) <= 0:
                    continue
                hit = next(((other_index, other) for found, other_index, other in labels if found == label), None)
                events["prefetch_sent"] += 1
                if hit:
                    prefetched.add((hit[0], hit[1].id))
                    policy.add("rent", prices.rent(tokens_of(hit[1]), remaining), usd)
                else:
                    policy.add("rent", prices.rent(stat["tokens"], remaining), usd)
                break
    for index in missed:
        call = view.calls[index]
        prices = Prices(call.model)
        main.add("missed_turn", prices.turn(call.context), prices.usd)
        if index not in saved:
            policy.add("missed_turn", prices.turn(call.context), prices.usd)
    for index in error_next:
        call = view.calls[index]
        prices = Prices(call.model)
        main.add("error_turn", prices.turn(call.context), prices.usd)
        policy.add("error_turn", prices.turn(call.context), prices.usd)
    return main, policy, events


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=os.path.join(os.path.expanduser("~"), ".claude", "projects"))
    parser.add_argument("--out", required=True)
    parser.add_argument("--modes", default="lockdown,mixed")
    parser.add_argument("--all-tools", action="store_true")
    args = parser.parse_args()
    out_dir = os.path.abspath(args.out)
    repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    if os.path.normcase(out_dir).startswith(os.path.normcase(repo) + os.sep):
        raise SystemExit("refusing to write replay output inside the repo")
    os.makedirs(out_dir, exist_ok=True)
    modes = set(args.modes.split(","))
    train, test = [], []
    for session in iter_sessions(args.root):
        if session.mode not in modes or not session.calls:
            continue
        (train if split_of(session) == "train" else test).append(View(session))
    table = build_table(train)
    with open(os.path.join(out_dir, "p_table.json"), "w", encoding="utf-8") as handle:
        json.dump(table, handle, indent=1, sort_keys=True)
    totals = {"main": Counter(), "policy": Counter()}
    events = Counter()
    for view in test:
        main_score, policy_score, found = score_session(view, table, not args.all_tools)
        totals["main"].update(main_score.parts)
        totals["policy"].update(policy_score.parts)
        events.update(found)
    j_main = sum(totals["main"].values())
    j_policy = sum(totals["policy"].values())
    report = {
        "train_sessions": len(train),
        "test_sessions": len(test),
        "j_main_usd": j_main,
        "j_policy_usd": j_policy,
        "reduction": 1 - j_policy / j_main if j_main else 0,
        "main_parts": dict(totals["main"]),
        "policy_parts": dict(totals["policy"]),
        "events": dict(events),
    }
    with open(os.path.join(out_dir, "replay.json"), "w", encoding="utf-8") as handle:
        json.dump(report, handle, indent=1, sort_keys=True)
    print(json.dumps(report, indent=1, sort_keys=True))


if __name__ == "__main__":
    main()
