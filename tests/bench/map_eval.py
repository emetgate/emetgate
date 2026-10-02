import argparse
import datetime
import hashlib
import json
import os
import random
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
PROJECT = os.path.dirname(ROOT)
RUNS = os.path.join(PROJECT, "eval", "map-runs")
SEEN = os.path.join(PROJECT, "eval", "session-map-runs", "seen_questions.json")
N8N = os.environ.get("EMETGATE_N8N") or "C:/Users/ugur/Desktop/md-test/full/n8n"
EXE = os.environ.get("EMETGATE_BIN") or os.path.join(ROOT, "zig-out", "bin", "emetgate.exe")
CLAUDE = os.environ.get("CLAUDE_EXE") or os.path.join(os.environ.get("APPDATA", ""), "npm", "node_modules", "@anthropic-ai", "claude-code", "bin", "claude.exe")
MODEL = "claude-sonnet-5-5"
INSTRUCTION = "List the symbols and regions you would read to answer, most important first, as JSON"
BUDGET_USD = 5.0
CALL_CAP_USD = 0.5
HEAD = "69b0c527fa"
CUTOFF = "2026-08-01T00:00:00+00:00"
SEED = 20261002
GENERAL_SIZE = 64
SUBJECT = re.compile(r"^(fix|feat|perf|refactor)(\([^)]*\))?!?:\s*(.+?)\s*(\(#\d+\))?\s*$")
SOURCE_EXTENSIONS = (".ts", ".tsx", ".js", ".mjs", ".cjs")
TEST_SEGMENTS = {"__tests__", "__mocks__", "__fixtures__", "test", "tests", "e2e", "fixtures", "mocks", "testing"}
TEST_INFIXES = (".test.", ".spec.", ".e2e.", "-spec.")
MIN_CHANGED_LINES = 2
MAX_SOURCE_FILES = 3
MAX_FUNCTIONS = 4
SESSION_ENV_VARS = (
    "CLAUDECODE",
    "CLAUDE_CODE_SESSION_ID",
    "CLAUDE_CODE_CHILD_SESSION",
    "CLAUDE_CODE_SESSION_ATTENDED",
    "CLAUDE_CODE_ENTRYPOINT",
    "CLAUDE_CODE_EXECPATH",
    "CLAUDE_CODE_MESSAGING_SOCKET",
    "CLAUDE_CODE_MESSAGING_TOKEN",
    "CLAUDE_CODE_BRIDGE_SESSION_ID",
)
HUNK = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")
LEDGER = os.path.join(RUNS, "ledger.jsonl")
M1P_PREFIX = "m1p"
M1P_LEDGER = os.path.join(RUNS, "m1p-ledger.jsonl")
M1P_BUDGET_USD = 3.0
M1P_CALL_CAP_USD = 0.1
M2_PREFIX = "m2-"
M2_LEDGER = os.path.join(RUNS, "m2-ledger.jsonl")
M2_BUDGET_USD = 5.0
M2_CALL_CAP_USD = 0.1
REGION_INSTRUCTION = 'Pick the regions of the map most likely to hold the code that answers the question, at most 3, most likely first. Reply with JSON only: {"regions": ["r1", "r2", "r3"]}'


def now():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def write_json(path, value):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(value, f, indent=2, ensure_ascii=False)
        f.write("\n")


def read_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def label_dir(label):
    return os.path.join(RUNS, label)


def ledger_of(label):
    if label.startswith(M2_PREFIX):
        return M2_LEDGER
    return M1P_LEDGER if label.startswith(M1P_PREFIX) else LEDGER


def caps_of(label):
    if label.startswith(M2_PREFIX):
        return (M2_BUDGET_USD, M2_CALL_CAP_USD)
    return (M1P_BUDGET_USD, M1P_CALL_CAP_USD) if label.startswith(M1P_PREFIX) else (BUDGET_USD, CALL_CAP_USD)


def spent(ledger=LEDGER):
    if not os.path.exists(ledger):
        return 0.0
    total = 0.0
    with open(ledger, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                total += json.loads(line).get("total_cost_usd") or 0.0
    return total


def prepare(label, extra):
    out = label_dir(label)
    os.makedirs(out, exist_ok=True)
    map_path = os.path.join(out, "map.txt")
    stats = subprocess.run([EXE, "map", "build", "--out", map_path, *extra], cwd=N8N, capture_output=True, check=True)
    with open(os.path.join(out, "map.stats.json"), "wb") as f:
        f.write(stats.stdout)
    files = subprocess.run([EXE, "map", "files", *[a for a in extra if not a.startswith("--out")]], cwd=N8N, capture_output=True, check=True)
    with open(os.path.join(out, "files.jsonl"), "wb") as f:
        f.write(files.stdout)
    write_json(os.path.join(out, "config.json"), {"args": extra, "prepared_at": now(), "head": HEAD})
    print(stats.stdout.decode("utf-8").strip())


def load_files(label):
    regions = {}
    files = {}
    with open(os.path.join(label_dir(label), "files.jsonl"), encoding="utf-8") as f:
        for line in f:
            row = json.loads(line)
            if "file" in row:
                files[row["file"]] = row
            else:
                regions[row["region"]] = row
    return regions, files


def simple(name):
    name = name.split("@")[0]
    return name.rsplit(".", 1)[-1]


def owner(name):
    name = name.split("@")[0]
    return name.rsplit(".", 1)[0].rsplit(".", 1)[-1] if "." in name else ""


def resolve_gold(files, path, symbol):
    row = files.get(path)
    if row is None:
        return None
    wanted = symbol.split("@")[0]
    exact = [q for q in row["symbols"] if q.split("@")[0] == wanted]
    if exact:
        return {"file": path, "qname": exact[0], "region": row["region"]}
    by_simple = [q for q in row["symbols"] if simple(q) == simple(wanted)]
    if len(by_simple) >= 1:
        return {"file": path, "qname": by_simple[0], "region": row["region"]}
    return None


def child_env():
    env = dict(os.environ)
    for key in list(env):
        if key.upper() in SESSION_ENV_VARS:
            del env[key]
    return env


def call(label, qid, trial, question, prompt_file, cwd):
    out_dir = os.path.join(label_dir(label), "calls")
    os.makedirs(out_dir, exist_ok=True)
    record_path = os.path.join(out_dir, f"{qid}-{trial}.json")
    if os.path.exists(record_path):
        return read_json(record_path)
    ledger = ledger_of(label)
    budget, cap = caps_of(label)
    if spent(ledger) + cap > budget:
        raise SystemExit(f"model budget reached: spent {spent(ledger):.4f} of {budget} USD")
    argv = [CLAUDE, "-p", question, "--model", MODEL, "--tools", "", "--append-system-prompt-file", prompt_file,
            "--output-format", "json", "--no-session-persistence", "--safe-mode", "--strict-mcp-config",
            "--mcp-config", '{"mcpServers":{}}', "--max-budget-usd", str(cap)]
    started = time.perf_counter()
    proc = subprocess.run(argv, cwd=cwd, env=child_env(), stdin=subprocess.DEVNULL, capture_output=True, timeout=600)
    wall_ms = round((time.perf_counter() - started) * 1000)
    text = proc.stdout.decode("utf-8", "replace")
    try:
        result = json.loads(text)
    except json.JSONDecodeError:
        result = {"unparsed_stdout": text}
    record = {
        "label": label,
        "qid": qid,
        "trial": trial,
        "question": question,
        "argv": [a if a != question else "<question>" for a in argv],
        "cwd": cwd,
        "started_at": now(),
        "wall_ms": wall_ms,
        "exit_code": proc.returncode,
        "stderr": proc.stderr.decode("utf-8", "replace")[-2000:],
        "result": result,
    }
    write_json(record_path, record)
    with open(ledger, "a", encoding="utf-8", newline="\n") as f:
        f.write(json.dumps({
            "label": label,
            "qid": qid,
            "trial": trial,
            "at": record["started_at"],
            "total_cost_usd": result.get("total_cost_usd"),
            "usage": result.get("usage"),
            "duration_api_ms": result.get("duration_api_ms"),
            "wall_ms": wall_ms,
        }) + "\n")
    return record


def prompt_file(label):
    path = os.path.join(label_dir(label), "prompt.txt")
    with open(os.path.join(label_dir(label), "map.txt"), encoding="utf-8") as f:
        body = f.read()
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(body.rstrip("\n") + "\n\n" + INSTRUCTION + "\n")
    return path


def seen_questions():
    data = read_json(SEEN)
    out = []
    for qid in ("S1", "S2", "S5", "S6"):
        q = data["questions"][qid]
        out.append({"id": qid, "text": q["text"], "gold": [{"file": q["target"]["file"], "symbol": q["target"]["symbol"]}]})
    return out


def run_seen(label, trials):
    prompt = prompt_file(label)
    for q in seen_questions():
        for trial in range(1, trials + 1):
            record = call(label, q["id"], trial, q["text"], prompt, RUNS)
            print(q["id"], trial, (record["result"].get("total_cost_usd")), record["wall_ms"], "ms")


def run_general(label, set_path):
    prompt = prompt_file(label)
    data = read_json(set_path)
    for q in data["questions"]:
        record = call(label, q["id"], 1, q["text"], prompt, RUNS)
        print(q["id"], record["result"].get("total_cost_usd"), record["wall_ms"], "ms")


def json_spans(text):
    blocks = re.findall(r"```(?:json)?\s*(.*?)```", text, re.S)
    candidates = blocks + [text]
    for chunk in candidates:
        for opener, closer in (("{", "}"), ("[", "]")):
            start = chunk.find(opener)
            while start != -1:
                depth = 0
                in_string = False
                escape = False
                for i in range(start, len(chunk)):
                    c = chunk[i]
                    if in_string:
                        if escape:
                            escape = False
                        elif c == "\\":
                            escape = True
                        elif c == '"':
                            in_string = False
                        continue
                    if c == '"':
                        in_string = True
                    elif c == opener:
                        depth += 1
                    elif c == closer:
                        depth -= 1
                        if depth == 0:
                            try:
                                yield json.loads(chunk[start:i + 1])
                            except json.JSONDecodeError:
                                pass
                            break
                start = chunk.find(opener, start + 1)


def strings_of(value, out):
    if isinstance(value, str):
        out.append(value)
    elif isinstance(value, dict):
        for k, v in value.items():
            if re.fullmatch(r"[rR]\d+", k):
                out.append(k)
            strings_of(v, out)
    elif isinstance(value, list):
        for v in value:
            strings_of(v, out)


REGION = re.compile(r"^[rR](\d+)$")
IDENT = re.compile(r"[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$#]*)*")


def selection(text):
    strings = []
    for parsed in json_spans(text):
        strings_of(parsed, strings)
        break
    regions = []
    symbols = []
    paths = []
    for s in strings:
        t = s.strip()
        m = REGION.match(t)
        if m:
            regions.append("r" + m.group(1))
            continue
        for found in re.findall(r"\b[rR](\d+)\b", t):
            if len(t) <= 12:
                regions.append("r" + found)
        if "/" in t:
            paths.append(t)
        for piece in re.split(r"[\s:#,()]+", t):
            piece = piece.strip("`'\".;")
            if not piece or "/" in piece:
                continue
            if IDENT.fullmatch(piece) and not REGION.match(piece):
                symbols.append(piece)
    return {"regions": regions, "symbols": symbols, "paths": paths, "strings": len(strings)}


def symbol_hit(candidates, gold_qname):
    g_simple = simple(gold_qname)
    g_owner = owner(gold_qname)
    for c in candidates:
        c = c.replace("#", ".").split("@")[0]
        if simple(c) != g_simple:
            continue
        c_owner = owner(c)
        if not c_owner or not g_owner or c_owner == g_owner:
            return True
    return False


def score_record(record, gold, regions):
    result = record["result"]
    text = result.get("result") or ""
    picked = selection(text)
    region_paths = {r["path"]: r["region"] for r in regions.values()}
    picked_regions = set(picked["regions"])
    for p in picked["paths"]:
        if p in region_paths:
            picked_regions.add(region_paths[p])
    direct = any(symbol_hit(picked["symbols"], g["qname"]) for g in gold if g)
    region = direct or any(g and g["region"] in picked_regions for g in gold)
    usage = result.get("usage") or {}
    return {
        "qid": record["qid"],
        "trial": record["trial"],
        "region_hit": bool(region),
        "symbol_hit": bool(direct),
        "picked_regions": len(picked_regions),
        "picked_symbols": len(picked["symbols"]),
        "cost": result.get("total_cost_usd") or 0.0,
        "duration_api_ms": result.get("duration_api_ms"),
        "input_tokens": usage.get("input_tokens", 0),
        "cache_creation_input_tokens": usage.get("cache_creation_input_tokens", 0),
        "cache_read_input_tokens": usage.get("cache_read_input_tokens", 0),
        "output_tokens": usage.get("output_tokens", 0),
        "gold": [g["qname"] + " @" + g["region"] for g in gold if g],
    }


def score(label, set_path):
    regions, files = load_files(label)
    calls = os.path.join(label_dir(label), "calls")
    rows = []
    seen = {q["id"]: q for q in seen_questions()}
    general = {}
    if set_path and os.path.exists(set_path):
        for q in read_json(set_path)["questions"]:
            general[q["id"]] = q
    for name in sorted(os.listdir(calls)) if os.path.isdir(calls) else []:
        record = read_json(os.path.join(calls, name))
        hooked = record["qid"].endswith("h")
        base = record["qid"][:-1] if hooked else record["qid"]
        q = seen.get(base) or general.get(base)
        if q is None:
            continue
        gold = [resolve_gold(files, g["file"], g["symbol"]) for g in q["gold"]]
        row = score_record(record, gold, regions)
        row["set"] = ("seen" if base in seen else "general") + ("-hook" if hooked else "")
        rows.append(row)
    summary = {}
    for name in ("seen", "general", "seen-hook", "general-hook"):
        part = [r for r in rows if r["set"] == name]
        if not part:
            continue
        summary[name] = {
            "calls": len(part),
            "region_or_symbol": sum(r["region_hit"] for r in part),
            "symbol": sum(r["symbol_hit"] for r in part),
            "region_rate": round(sum(r["region_hit"] for r in part) / len(part), 4),
            "symbol_rate": round(sum(r["symbol_hit"] for r in part) / len(part), 4),
            "cost_usd": round(sum(r["cost"] for r in part), 4),
            "median_api_ms": sorted(r["duration_api_ms"] or 0 for r in part)[len(part) // 2],
        }
    report = {"label": label, "scored_at": now(), "summary": summary, "rows": rows, "ledger_usd": round(spent(), 4)}
    write_json(os.path.join(label_dir(label), "score.json"), report)
    print(json.dumps(summary, indent=2))
    for r in rows:
        print(r["set"], r["qid"], r["trial"], "region" if r["region_hit"] else "-", "symbol" if r["symbol_hit"] else "-", r["gold"])


def git(*args, check=True):
    proc = subprocess.run(["git", "-C", N8N, *args], capture_output=True, stdin=subprocess.DEVNULL)
    if check and proc.returncode != 0:
        raise SystemExit("git " + " ".join(args) + " failed: " + proc.stderr.decode("utf-8", "replace"))
    return proc.stdout.decode("utf-8", "replace") if proc.returncode == 0 else None


def is_test(path):
    parts = path.split("/")
    base = parts[-1]
    if any(infix in base for infix in TEST_INFIXES):
        return True
    return any(p in TEST_SEGMENTS for p in parts[:-1])


class Functions:
    def __init__(self):
        import tree_sitter_typescript
        from tree_sitter import Language, Parser
        self.parsers = {
            "ts": Parser(Language(tree_sitter_typescript.language_typescript())),
            "tsx": Parser(Language(tree_sitter_typescript.language_tsx())),
        }

    FUNCTIONS = {"function_declaration", "generator_function_declaration", "method_definition", "function_expression", "generator_function", "arrow_function"}
    HOLDERS = {"variable_declarator", "public_field_definition", "pair", "assignment_expression"}
    CLASSES = {"class_declaration", "abstract_class_declaration", "class"}

    def ranges(self, path, text):
        if text is None:
            return []
        parser = self.parsers["tsx" if path.endswith((".tsx", ".jsx")) else "ts"]
        source = text.encode("utf-8")
        tree = parser.parse(source)
        found = []
        stack = [tree.root_node]
        while stack:
            node = stack.pop()
            if node.type in self.FUNCTIONS:
                name = self.qualified(node, source)
                if name is not None:
                    found.append((node.start_point[0] + 1, node.end_point[0] + 1, name))
            stack.extend(node.children)
        return found

    def qualified(self, node, source):
        def text(n):
            return source[n.start_byte:n.end_byte].decode("utf-8", "replace")
        name = None
        holder = node
        if node.type in ("function_declaration", "generator_function_declaration", "method_definition"):
            field = node.child_by_field_name("name")
            name = text(field) if field is not None else None
        elif node.parent is not None and node.parent.type in self.HOLDERS:
            holder = node.parent
            field = holder.child_by_field_name("name") or holder.child_by_field_name("key") or holder.child_by_field_name("left")
            name = text(field) if field is not None else None
        if not name or not re.fullmatch(r"[A-Za-z_$][\w$]*", name):
            return None
        scope = holder.parent
        while scope is not None and scope.type not in self.CLASSES:
            scope = scope.parent
        if scope is not None and scope.child_by_field_name("name") is not None:
            return text(scope.child_by_field_name("name")) + "." + name
        return name


def innermost(line, ranges):
    best = None
    for start, end, name in ranges:
        if start <= line <= end and (best is None or end - start < best[1] - best[0]):
            best = (start, end, name)
    return best[2] if best else None


def changed(commit, path):
    diff = git("diff", "-U0", "--no-color", "--no-ext-diff", f"{commit}^", commit, "--", path)
    removed, added = [], []
    old_line = new_line = 0
    for line in diff.splitlines():
        m = HUNK.match(line)
        if m:
            old_line, new_line = int(m.group(1)), int(m.group(3))
            continue
        if line.startswith("---") or line.startswith("+++"):
            continue
        if line.startswith("-"):
            if any(c.isalnum() for c in line[1:]):
                removed.append(old_line)
            old_line += 1
        elif line.startswith("+"):
            if any(c.isalnum() for c in line[1:]):
                added.append(new_line)
            new_line += 1
    return removed, added


def examine(commit, subject, functions, files):
    m = SUBJECT.match(subject)
    if not m:
        return None, "subject is not fix, feat, perf or refactor"
    paths = [line.split("\t", 1)[1] for line in git("diff-tree", "--no-commit-id", "-r", "--no-renames", "--name-status", commit).splitlines() if "\t" in line]
    sources = [p for p in paths if p.endswith(SOURCE_EXTENSIONS) and not is_test(p)]
    if not sources:
        return None, "no non-test source file"
    if len(sources) > MAX_SOURCE_FILES:
        return None, f"{len(sources)} non-test source files"
    counts = {}
    for path in sources:
        removed, added = changed(commit, path)
        old = functions.ranges(path, git("show", f"{commit}^:{path}", check=False))
        new = functions.ranges(path, git("show", f"{commit}:{path}", check=False))
        for line in removed:
            name = innermost(line, old)
            if name:
                counts[(path, name)] = counts.get((path, name), 0) + 1
        for line in added:
            name = innermost(line, new)
            if name:
                counts[(path, name)] = counts.get((path, name), 0) + 1
    touched = sorted(k for k, v in counts.items() if v >= MIN_CHANGED_LINES)
    if not touched:
        return None, "no function with two changed lines"
    if len(touched) > MAX_FUNCTIONS:
        return None, f"{len(touched)} functions changed"
    gold = []
    for path, name in touched:
        g = resolve_gold(files, path, name)
        if g and simple(g["qname"]) == simple(name):
            gold.append({"file": path, "symbol": g["qname"]})
    if not gold:
        return None, "no changed function still stands at the snapshot"
    question = m.group(3).strip()
    question = question[0].upper() + question[1:]
    return {"commit": commit, "subject": subject, "text": question, "gold": gold, "functions": [f"{p}::{n}" for p, n in touched]}, None


def select(label, out_path, size):
    _, files = load_files(label)
    log = git("log", "--no-merges", f"--before={CUTOFF}", "--format=%H%x09%cI%x09%s", HEAD, "--", "packages")
    commits = []
    for line in log.splitlines():
        commit, date, subject = line.split("\t", 2)
        if date >= CUTOFF[:19]:
            continue
        if SUBJECT.match(subject):
            commits.append((commit, date, subject))
    rng = random.Random(SEED)
    rng.shuffle(commits)
    functions = Functions()
    chosen = []
    rejected = {}
    examined = 0
    for commit, date, subject in commits:
        if len(chosen) >= size:
            break
        examined += 1
        item, why = examine(commit, subject, functions, files)
        if item is None:
            rejected[why] = rejected.get(why, 0) + 1
            continue
        item["date"] = date
        item["id"] = f"G{len(chosen) + 1:02d}"
        chosen.append(item)
    write_json(out_path, {
        "rule": {
            "head": HEAD,
            "before": CUTOFF,
            "subject": SUBJECT.pattern,
            "source_extensions": SOURCE_EXTENSIONS,
            "test_segments": sorted(TEST_SEGMENTS),
            "test_infixes": TEST_INFIXES,
            "max_source_files": MAX_SOURCE_FILES,
            "min_changed_lines_per_function": MIN_CHANGED_LINES,
            "max_functions": MAX_FUNCTIONS,
            "gold": "changed functions that still exist in the snapshot file under the same qualified name",
            "seed": SEED,
            "order": "subject-matching commits shuffled with random.Random(seed), examined in that order until the set is full",
        },
        "candidates": len(commits),
        "examined": examined,
        "rejected": rejected,
        "questions": chosen,
    })
    print(f"{len(chosen)} questions from {examined} examined of {len(commits)} candidates; rejected {rejected}")


def probe(label):
    out = label_dir(label)
    os.makedirs(out, exist_ok=True)
    path = os.path.join(out, "prompt.txt")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(INSTRUCTION + "\n")
    record = call(label, "P", 1, "Reply with the single word ok.", path, RUNS)
    print(json.dumps(record["result"].get("usage"), indent=2), record["result"].get("total_cost_usd"))


LEXICON_COMMIT = "0faeaa5"
LEXICON_PATH = "src/engine/question_lexicon.txt"
FOLD = str.maketrans("çÇğĞıİöÖşŞüÜâÂîÎûÛ", "ccggiioossuuaaiiuu")
EN_RULES = sorted([("ies", "y", 2), ("sses", "ss", 2), ("ss", "ss", 2), ("us", "us", 2), ("is", "is", 2), ("s", "", 2),
                   ("ing", "", 3), ("ed", "", 3), ("ions", "", 3), ("ion", "", 3), ("ers", "", 3), ("er", "", 3),
                   ("ors", "", 3), ("or", "", 3), ("ments", "", 3), ("ment", "", 3), ("ly", "", 3), ("e", "", 3)], key=lambda r: -len(r[0]))
EN_STOP = {"a", "an", "and", "any", "are", "as", "at", "be", "by", "can", "do", "does", "for", "from", "get", "has", "have", "if", "in",
           "into", "is", "it", "its", "no", "not", "of", "on", "or", "set", "so", "than", "that", "the", "then", "this", "to", "too",
           "up", "was", "were", "will", "with", "all", "new", "use", "out", "via", "per", "one", "two", "my", "we", "our", "you", "your",
           "ts", "js", "tsx", "jsx", "mjs", "cjs", "src", "lib", "dist", "index", "when", "which", "what", "where", "how", "why", "who",
           "instead", "only", "also", "more", "than", "after", "before", "should", "would", "could", "make", "keep", "don", "doesn", "isn"}
HOOK_CHARS = 9500
BM25_K1 = 1.2
BM25_B = 0.75


def fold(text):
    return text.translate(FOLD).lower()


def en_stem(word):
    w = word
    for _ in range(3):
        for suffix, replacement, min_stem in EN_RULES:
            if len(w) >= len(suffix) + min_stem and w.endswith(suffix):
                break
        else:
            break
        if suffix == replacement:
            break
        w = w[: len(w) - len(suffix)] + replacement
    return w


def identifier_parts(text):
    parts = []
    for run in re.findall(r"[A-Za-z0-9]+", text):
        pieces = re.findall(r"[A-Z]+(?=[A-Z][a-z])|[A-Z]?[a-z]+|[A-Z]+|[0-9]+", run)
        for p in pieces:
            low = p.lower()
            if len(low) >= 2 and not low.isdigit():
                parts.append(low)
    return parts


def stems_of(text):
    return [en_stem(p) for p in identifier_parts(text) if p not in EN_STOP]


class Lexicon:
    def __init__(self, text):
        self.entries = []
        self.stop = set()
        for line in text.splitlines():
            parts = line.split(None, 1)
            if len(parts) < 2:
                continue
            kind, rest = parts
            if kind in ("stop", "stopverb"):
                self.stop.update(fold(w) for w in rest.split())
            elif kind in ("noun", "verb") and "=" in rest:
                keys, values = rest.split("=", 1)
                terms = [v.strip() for v in values.split(",") if v.strip()]
                for key in keys.split("|"):
                    words = tuple(fold(w) for w in key.split())
                    if words:
                        self.entries.append((words, terms))
        self.entries.sort(key=lambda e: (-len(e[0]), -len(e[0][-1])))

    @staticmethod
    def matches(word, key):
        if word == key:
            return True
        for marker in ("si", "su", "i", "u"):
            if key.endswith(marker) and len(key) - len(marker) >= 3 and word.startswith(key[: -len(marker)]) and len(word) - len(key) + len(marker) <= 10:
                return True
        return len(key) >= 3 and word.startswith(key) and len(word) - len(key) <= 10

    def query(self, question):
        raw = re.findall(r"[^\s.,;:!?()\"]+", question)
        words = [fold(w.split("'")[0].split("’")[0]) for w in raw]
        terms = {}
        used = [False] * len(words)
        for i in range(len(words)):
            if used[i]:
                continue
            for key, values in self.entries:
                n = len(key)
                if i + n > len(words):
                    continue
                if all(words[i + k] == key[k] for k in range(n - 1)) and self.matches(words[i + n - 1], key[-1]):
                    for v in values:
                        for s in stems_of(v):
                            terms[s] = terms.get(s, 0) + 1
                    for k in range(n):
                        used[i + k] = True
                    break
        for i, w in enumerate(raw):
            if used[i] or fold(w) in self.stop:
                continue
            base = w.split("'")[0].split("’")[0]
            if not re.search(r"[A-Za-z]", base) or re.search(r"[^\x00-\x7f]", base):
                continue
            for s in stems_of(base):
                terms[s] = terms.get(s, 0) + 1
        return terms


def load_lexicon():
    text = subprocess.run(["git", "-C", ROOT, "show", f"{LEXICON_COMMIT}:{LEXICON_PATH}"], capture_output=True, check=True).stdout.decode("utf-8")
    return Lexicon(text)


class Index:
    def __init__(self, label):
        self.regions, files = load_files(label)
        self.files = files
        self.symbols = []
        region_terms = {}
        for path, row in files.items():
            region = row["region"]
            if self.regions[region]["family"] != "code":
                continue
            stem_terms = stems_of(path.rsplit("/", 1)[-1].split(".")[0])
            bag = region_terms.setdefault(region, {})
            for t in stems_of(path):
                bag[t] = bag.get(t, 0) + 1
            spans = row.get("spans") or [[0, 0]] * len(row["symbols"])
            lines = row.get("lines") or [0] * len(row["symbols"])
            for qname, span, line in zip(row["symbols"], spans, lines):
                terms = stems_of(qname.split("@")[0]) + stem_terms
                self.symbols.append({"path": path, "qname": qname, "region": region, "span": span, "line": line, "terms": terms})
                for t in stems_of(qname.split("@")[0]):
                    bag[t] = bag.get(t, 0) + 1
        self.region_terms = region_terms
        self.region_df = {}
        for bag in region_terms.values():
            for t in bag:
                self.region_df[t] = self.region_df.get(t, 0) + 1
        self.region_len = {r: sum(b.values()) for r, b in region_terms.items()}
        self.region_avg = sum(self.region_len.values()) / max(1, len(self.region_len))
        self.symbol_df = {}
        for s in self.symbols:
            for t in set(s["terms"]):
                self.symbol_df[t] = self.symbol_df.get(t, 0) + 1
        self.symbol_avg = sum(len(s["terms"]) for s in self.symbols) / max(1, len(self.symbols))

    @staticmethod
    def bm25(query, tf, length, avg, df, n):
        score = 0.0
        for t, q in query.items():
            f = tf.get(t, 0)
            if f == 0:
                continue
            idf = max(0.0, __import__("math").log((n - df.get(t, 0) + 0.5) / (df.get(t, 0) + 0.5) + 1))
            score += q * idf * f * (BM25_K1 + 1) / (f + BM25_K1 * (1 - BM25_B + BM25_B * length / avg))
        return score

    def rank_regions(self, query):
        n = len(self.region_terms)
        scored = [(self.bm25(query, bag, self.region_len[r], self.region_avg, self.region_df, n), r) for r, bag in self.region_terms.items()]
        scored.sort(key=lambda x: (-x[0], int(x[1][1:])))
        return [r for s, r in scored if s > 0]

    def rank_symbols(self, query, regions):
        n = len(self.symbols)
        allowed = set(regions)
        scored = []
        for s in self.symbols:
            if s["region"] not in allowed:
                continue
            tf = {}
            for t in s["terms"]:
                tf[t] = tf.get(t, 0) + 1
            score = self.bm25(query, tf, len(s["terms"]), self.symbol_avg, self.symbol_df, n)
            if score <= 0:
                continue
            size = max(1, s["span"][1] - s["span"][0])
            scored.append((score + 0.15 * __import__("math").log(size), s))
        scored.sort(key=lambda x: (-x[0], x[1]["path"], x[1]["line"]))
        return [s for _, s in scored]


def source_slice(path, span):
    with open(os.path.join(N8N, path), "rb") as f:
        data = f.read()
    start, end = span
    first = data.count(b"\n", 0, start) + 1
    return first, data[start:end].decode("utf-8", "replace")


def hook_block(index, question_terms, top_regions=3, top_symbols=12, code_symbols=3):
    regions = index.rank_regions(question_terms)[:top_regions]
    symbols = index.rank_symbols(question_terms, regions)
    lines = ["Kernel guess for this question, made without a model; it can be wrong."]
    lines.append("likely regions: " + ", ".join(f"{r} {index.regions[r]['path']}" for r in regions))
    picked = symbols[:top_symbols]
    lines.append("likely symbols: " + ", ".join(f"{s['qname']} {s['path'].rsplit('/', 1)[-1]}:{s['line']}" for s in picked))
    used = sum(len(l) + 1 for l in lines)
    shown = []
    for s in picked[:code_symbols]:
        first, body = source_slice(s["path"], s["span"])
        numbered = "\n".join(f"{first + k} {text}" for k, text in enumerate(body.splitlines()))
        head = f"code {s['path']}:{first}-{first + body.count(chr(10))} {s['qname']}"
        room = HOOK_CHARS - used - len(head) - 2
        if room <= 200:
            break
        if len(numbered) > room:
            numbered = numbered[: room - 60] + "\n... rest not shown (hook budget)"
            lines.append(head)
            lines.append(numbered)
            shown.append((s["qname"], False))
            used += len(head) + len(numbered) + 2
            break
        lines.append(head)
        lines.append(numbered)
        shown.append((s["qname"], True))
        used += len(head) + len(numbered) + 2
    return "\n".join(lines), regions, [s["qname"] for s in symbols], shown


def rank_eval(label, set_path):
    lexicon = load_lexicon()
    index = Index(label)
    rows = []
    questions = [dict(q, set="seen") for q in seen_questions()]
    if set_path and os.path.exists(set_path):
        questions += [dict(q, set="general") for q in read_json(set_path)["questions"]]
    for q in questions:
        gold = [resolve_gold(index.files, g["file"], g["symbol"]) for g in q["gold"]]
        gold = [g for g in gold if g]
        terms = lexicon.query(q["text"])
        block, regions, ranked, shown = hook_block(index, terms)
        gold_regions = {g["region"] for g in gold}
        def sym_rank():
            for i, name in enumerate(ranked):
                if any(symbol_hit([name], g["qname"]) and True for g in gold):
                    return i
            return None
        pos = sym_rank()
        rows.append({
            "set": q["set"],
            "id": q["id"],
            "region_at1": bool(regions[:1] and regions[0] in gold_regions),
            "region_at3": bool(gold_regions & set(regions[:3])),
            "symbol_rank": pos,
            "code_full": any(full and any(symbol_hit([name], g["qname"]) for g in gold) for name, full in shown),
            "code_any": any(any(symbol_hit([name], g["qname"]) for g in gold) for name, full in shown),
            "block_chars": len(block),
            "terms": sorted(terms),
        })
    summary = {}
    for name in ("seen", "general"):
        part = [r for r in rows if r["set"] == name]
        if not part:
            continue
        n = len(part)
        summary[name] = {
            "questions": n,
            "region_at1": round(sum(r["region_at1"] for r in part) / n, 3),
            "region_at3": round(sum(r["region_at3"] for r in part) / n, 3),
            "symbol_at3": round(sum(r["symbol_rank"] is not None and r["symbol_rank"] < 3 for r in part) / n, 3),
            "symbol_at12": round(sum(r["symbol_rank"] is not None and r["symbol_rank"] < 12 for r in part) / n, 3),
            "code_full": round(sum(r["code_full"] for r in part) / n, 3),
            "code_any": round(sum(r["code_any"] for r in part) / n, 3),
            "mean_block_chars": round(sum(r["block_chars"] for r in part) / n),
        }
    write_json(os.path.join(label_dir(label), "rank.json"), {"summary": summary, "rows": rows})
    print(json.dumps(summary, indent=2))
    for r in rows:
        if r["set"] == "seen":
            print(r["id"], "region@1" if r["region_at1"] else "-", "region@3" if r["region_at3"] else "-", "symbol rank", r["symbol_rank"], "code" if r["code_full"] else "-", r["terms"])


def run_seen_hook(label, trials):
    lexicon = load_lexicon()
    index = Index(label)
    prompt = prompt_file(label)
    for q in seen_questions():
        block, _, _, _ = hook_block(index, lexicon.query(q["text"]))
        for trial in range(1, trials + 1):
            record = call(label, q["id"] + "h", trial, q["text"] + "\n\n" + block, prompt, RUNS)
            print(q["id"], trial, record["result"].get("total_cost_usd"), record["wall_ms"], "ms")


PRICE = {"input": 2.0e-6, "output": 10.0e-6, "cache_read": 0.2e-6, "cache_write": 4.0e-6}
QUESTION_TOKENS = 60
TOOL_CALL_TOKENS = 80
ANSWER_TOKENS = 600
EVIDENCE_TOKENS = round(HOOK_CHARS / 2.02)
LISTING_TOKENS = round(8000 / 2.02)


def first_usage(label, qid="S1"):
    calls = os.path.join(label_dir(label), "calls")
    names = sorted(n for n in os.listdir(calls) if n.startswith(qid + "-"))
    usage = read_json(os.path.join(calls, names[0]))["result"].get("usage") or {}
    return usage.get("input_tokens", 0) + usage.get("cache_creation_input_tokens", 0) + usage.get("cache_read_input_tokens", 0)


class Session:
    def __init__(self, prefix):
        self.prefix = prefix
        self.context = prefix
        self.cost = 0.0
        self.tokens = {"cache_write": 0, "cache_read": 0, "output": 0}
        self.turns = 0
        self.warm = False

    def turn(self, new_tokens, output_tokens):
        if self.warm:
            self.tokens["cache_read"] += self.context
            self.cost += self.context * PRICE["cache_read"]
        else:
            self.tokens["cache_write"] += self.context
            self.cost += self.context * PRICE["cache_write"]
            self.warm = True
        self.tokens["cache_write"] += new_tokens
        self.cost += new_tokens * PRICE["cache_write"] + output_tokens * PRICE["output"]
        self.tokens["output"] += output_tokens
        self.context += new_tokens + output_tokens
        self.turns += 1


def expected_session(prefix, questions, p_one, p_two, hook_tokens):
    total_cost = 0.0
    totals = {"cache_write": 0, "cache_read": 0, "output": 0}
    turns = 0.0
    for outcome, weight in (("one", p_one), ("two", p_two), ("three", 1 - p_one - p_two)):
        if weight <= 0:
            continue
        s = Session(prefix)
        for _ in range(questions):
            if outcome == "one":
                s.turn(QUESTION_TOKENS + hook_tokens, ANSWER_TOKENS)
            elif outcome == "two":
                s.turn(QUESTION_TOKENS + hook_tokens, TOOL_CALL_TOKENS)
                s.turn(EVIDENCE_TOKENS, ANSWER_TOKENS)
            else:
                s.turn(QUESTION_TOKENS + hook_tokens, TOOL_CALL_TOKENS)
                s.turn(LISTING_TOKENS, TOOL_CALL_TOKENS)
                s.turn(EVIDENCE_TOKENS, ANSWER_TOKENS)
        total_cost += weight * s.cost
        turns += weight * s.turns / questions
        for k in totals:
            totals[k] += weight * s.tokens[k]
    return {"usd": round(total_cost, 4), "turns_per_question": round(turns, 2), **{k: round(v) for k, v in totals.items()}}


def cost_model(rows_spec):
    probe = first_usage("probe", "P")
    out = []
    for spec in rows_spec:
        name, label, p_sym, p_hook, hook = spec
        prefix = first_usage(label) - QUESTION_TOKENS if label else probe
        p_one = p_hook
        p_two = (1 - p_hook) * p_sym
        row = {"option": name, "prefix_tokens": prefix, "hook_tokens": hook, "p_one_turn": round(p_one, 3), "p_two_turns": round(p_two, 3)}
        for q in (1, 3, 10):
            row[f"q{q}"] = expected_session(prefix, q, p_one, p_two, hook)
        out.append(row)
    return out


def region_prompt_file(label):
    path = os.path.join(label_dir(label), "region-prompt.txt")
    with open(os.path.join(label_dir(label), "map.txt"), encoding="utf-8") as f:
        body = f.read()
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(body.rstrip("\n") + "\n\n" + REGION_INSTRUCTION + "\n")
    return path


def general_questions(set_path):
    return read_json(set_path)["questions"] if set_path and os.path.exists(set_path) else []


def m1p_seen(label, trials):
    prompt = region_prompt_file(label)
    for q in seen_questions():
        for trial in range(1, trials + 1):
            record = call(label, q["id"], trial, q["text"], prompt, RUNS)
            print(q["id"], trial, record["result"].get("total_cost_usd"), record["wall_ms"], "ms")


def m1p_general(label, set_path):
    prompt = region_prompt_file(label)
    for q in general_questions(set_path):
        record = call(label, q["id"], 1, q["text"], prompt, RUNS)
        print(q["id"], record["result"].get("total_cost_usd"), record["wall_ms"], "ms")


REGION_ID = re.compile(r"\b[rR](\d+)\b")


def picked_regions(text, known):
    def take(items):
        out = []
        for item in items:
            if isinstance(item, dict):
                item = item.get("region") or item.get("id") or ""
            if not isinstance(item, str):
                continue
            m = REGION_ID.search(item)
            if m and ("r" + m.group(1)) in known and ("r" + m.group(1)) not in out:
                out.append("r" + m.group(1))
        return out
    for parsed in json_spans(text):
        if isinstance(parsed, dict) and isinstance(parsed.get("regions"), list):
            return take(parsed["regions"])[:3], "json"
        if isinstance(parsed, list):
            return take(parsed)[:3], "json"
    found = []
    for m in REGION_ID.finditer(text):
        r = "r" + m.group(1)
        if r in known and r not in found:
            found.append(r)
    return found[:3], "text"


def gold_of(files, q):
    return [g for g in (resolve_gold(files, x["file"], x["symbol"]) for x in q["gold"]) if g]


def m1p_score(label, set_path):
    regions, files = load_files(label)
    known = set(regions)
    calls = os.path.join(label_dir(label), "calls")
    seen = {q["id"]: q for q in seen_questions()}
    general = {q["id"]: q for q in general_questions(set_path)}
    rows = []
    for name in sorted(os.listdir(calls)) if os.path.isdir(calls) else []:
        record = read_json(os.path.join(calls, name))
        q = seen.get(record["qid"]) or general.get(record["qid"])
        if q is None:
            continue
        gold = gold_of(files, q)
        text = record["result"].get("result") or ""
        picked, how = picked_regions(text, known)
        gold_regions = sorted({g["region"] for g in gold})
        usage = record["result"].get("usage") or {}
        rows.append({
            "set": "seen" if record["qid"] in seen else "general",
            "qid": record["qid"],
            "trial": record["trial"],
            "picked": picked,
            "parsed": how,
            "gold_regions": gold_regions,
            "hit": bool(set(picked) & set(gold_regions)),
            "cost": record["result"].get("total_cost_usd") or 0.0,
            "duration_api_ms": record["result"].get("duration_api_ms"),
            "output_tokens": usage.get("output_tokens", 0),
            "cache_read_input_tokens": usage.get("cache_read_input_tokens", 0),
            "cache_creation_input_tokens": usage.get("cache_creation_input_tokens", 0),
            "input_tokens": usage.get("input_tokens", 0),
        })
    summary = {}
    for part_name in ("seen", "general"):
        part = [r for r in rows if r["set"] == part_name]
        if not part:
            continue
        summary[part_name] = {
            "calls": len(part),
            "hits": sum(r["hit"] for r in part),
            "rate": round(sum(r["hit"] for r in part) / len(part), 4),
            "json_parsed": sum(r["parsed"] == "json" for r in part),
            "cost_usd": round(sum(r["cost"] for r in part), 4),
            "median_api_ms": sorted(r["duration_api_ms"] or 0 for r in part)[len(part) // 2],
            "median_output_tokens": sorted(r["output_tokens"] for r in part)[len(part) // 2],
        }
    report = {"label": label, "scored_at": now(), "instruction": REGION_INSTRUCTION, "summary": summary, "rows": rows, "m1p_ledger_usd": round(spent(M1P_LEDGER), 4)}
    write_json(os.path.join(label_dir(label), "m1p-regions.json"), report)
    print(json.dumps(summary, indent=2))
    for r in rows:
        if r["set"] == "seen" or not r["hit"]:
            print(r["set"], r["qid"], r["trial"], "hit" if r["hit"] else "MISS", r["picked"], r["gold_regions"])


def run_eval_set(label, items, extra, out_name):
    cfg = read_json(os.path.join(label_dir(label), "config.json"))
    set_path = os.path.join(label_dir(label), out_name + ".set.json")
    write_json(set_path, {"questions": items})
    argv = [EXE, "map", "eval", "--set", set_path, *cfg["args"], *extra]
    proc = subprocess.run(argv, cwd=N8N, capture_output=True)
    if proc.returncode != 0:
        raise SystemExit("map eval failed: " + proc.stderr.decode("utf-8", "replace")[-2000:])
    out_path = os.path.join(label_dir(label), out_name + ".jsonl")
    with open(out_path, "wb") as f:
        f.write(proc.stdout)
    rows = [json.loads(line) for line in proc.stdout.decode("utf-8").splitlines() if line.strip()]
    return {r["id"]: r for r in rows}


def gold_rank(ranking, gold):
    for i, (qname, path, line, score) in enumerate(ranking["hits"]):
        if path == gold["file"] and qname == gold["qname"]:
            return i + 1
    return None


def percentile(values, q):
    if not values:
        return None
    values = sorted(values)
    return values[min(len(values) - 1, int(len(values) * q))]


def m1p_rank(label, set_path, include_general, limit, rank_args=(), tag=""):
    regions, files = load_files(label)
    questions = [dict(q, set="seen") for q in seen_questions()]
    if include_general:
        questions += [dict(q, set="general") for q in general_questions(set_path)]
    items = []
    gold_by_id = {}
    for q in questions:
        gold = gold_of(files, q)
        gold_by_id[q["id"]] = gold
        items.append({"id": q["id"], "text": q["text"], "regions": sorted({g["region"] for g in gold}, key=lambda r: int(r[1:]))})
    base_name = ("m1p-rank-general" if include_general else "m1p-rank-seen") + (f"-{tag}" if tag else "")
    results = run_eval_set(label, items, ["--limit", str(limit), *rank_args], base_name)
    rows = []
    times = []
    for q in questions:
        result = results.get(q["id"])
        if result is None:
            continue
        by_region = {r["region"]: r for r in result["rankings"]}
        for r in result["rankings"]:
            times.append(r["rank_ms"])
        ranks = []
        for g in gold_by_id[q["id"]]:
            ranking = by_region.get(g["region"])
            ranks.append(gold_rank(ranking, g) if ranking else None)
        best = min([r for r in ranks if r is not None], default=None)
        rows.append({"set": q["set"], "id": q["id"], "gold": [g["qname"] + " @" + g["region"] for g in gold_by_id[q["id"]]], "ranks": ranks, "best": best,
                     "candidates": [by_region[g["region"]]["candidates"] for g in gold_by_id[q["id"]] if g["region"] in by_region]})
    summary = {}
    for part_name in ("seen", "general"):
        part = [r for r in rows if r["set"] == part_name]
        if not part:
            continue
        summary[part_name] = {"questions": len(part)}
        for k in (1, 3, 5, 8, 10):
            summary[part_name][f"at{k}"] = round(sum(r["best"] is not None and r["best"] <= k for r in part) / len(part), 4)
            summary[part_name][f"hits_at{k}"] = sum(r["best"] is not None and r["best"] <= k for r in part)
    summary["rank_ms"] = {"count": len(times), "p50": percentile(times, 0.5), "p99": percentile(times, 0.99), "max": max(times) if times else None}
    write_json(os.path.join(label_dir(label), base_name + ".json"), {"label": label, "rank_args": list(rank_args), "summary": summary, "rows": rows})
    print(json.dumps(summary, indent=2))
    for r in rows:
        if r["set"] == "seen" or r["best"] is None or r["best"] > 5:
            print(r["set"], r["id"], "best", r["best"], r["ranks"], r["gold"])


def m1p_combined(label, set_path):
    regions_report = read_json(os.path.join(label_dir(label), "m1p-regions.json"))
    rank_report = read_json(os.path.join(label_dir(label), "m1p-rank-general.json"))
    ranks = {r["id"]: r for r in rank_report["rows"]}
    rows = []
    for r in regions_report["rows"]:
        rank_row = ranks.get(r["qid"])
        if rank_row is None:
            continue
        per_k = {}
        for k in (3, 5, 8):
            ok = False
            for gold, gr in zip(rank_row["gold"], rank_row["ranks"]):
                region = gold.rsplit(" @", 1)[1]
                if region in r["picked"] and gr is not None and gr <= k:
                    ok = True
            per_k[k] = ok
        rows.append({"set": r["set"], "qid": r["qid"], "trial": r["trial"], "region_hit": r["hit"], **{f"at{k}": v for k, v in per_k.items()}})
    summary = {}
    for part_name in ("seen", "general"):
        part = [x for x in rows if x["set"] == part_name]
        if not part:
            continue
        summary[part_name] = {"calls": len(part), "region": round(sum(x["region_hit"] for x in part) / len(part), 4)}
        for k in (3, 5, 8):
            summary[part_name][f"combined_at{k}"] = round(sum(x[f"at{k}"] for x in part) / len(part), 4)
            summary[part_name][f"combined_hits_at{k}"] = sum(x[f"at{k}"] for x in part)
    write_json(os.path.join(label_dir(label), "m1p-combined.json"), {"label": label, "summary": summary, "rows": rows})
    print(json.dumps(summary, indent=2))


def m1p_explore(label, set_path, include_general, ks, budget, rank_args=()):
    regions_report = read_json(os.path.join(label_dir(label), "m1p-regions.json"))
    texts = {q["id"]: q["text"] for q in seen_questions()}
    if include_general:
        texts.update({q["id"]: q["text"] for q in general_questions(set_path)})
    items = []
    for r in regions_report["rows"]:
        if r["trial"] != 1 or r["qid"] not in texts or not r["picked"]:
            continue
        items.append({"id": r["qid"], "text": texts[r["qid"]], "regions": r["picked"]})
    out = {}
    for k in ks:
        results = run_eval_set(label, items, ["--k", str(k), "--explore-budget", str(budget), "--limit", "8", "--with-text", *rank_args], f"m1p-explore-k{k}")
        chars = [x.get("explore_chars", 0) for x in results.values()]
        ms = [x.get("explore_ms", 0) for x in results.values()]
        shown = [len(x.get("shown", [])) for x in results.values()]
        out[f"k{k}"] = {"questions": len(results), "chars_p50": percentile(chars, 0.5), "chars_max": max(chars) if chars else None,
                        "explore_ms_p50": percentile(ms, 0.5), "explore_ms_p99": percentile(ms, 0.99), "shown_mean": round(sum(shown) / max(1, len(shown)), 2),
                        "partial": sum(x.get("explore_status") == "partial" for x in results.values())}
    write_json(os.path.join(label_dir(label), "m1p-explore.json"), {"label": label, "budget": budget, "summary": out})
    print(json.dumps(out, indent=2))


def m1p_calibrate(label, qid, k):
    rows = [json.loads(line) for line in open(os.path.join(label_dir(label), f"m1p-explore-k{k}.jsonl"), encoding="utf-8") if line.strip()]
    row = next(r for r in rows if r["id"] == qid)
    path = os.path.join(label_dir(label), f"explore-{qid}-k{k}.txt")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(row["explore_text"])
    record = call(label, f"X{qid}k{k}", 1, "Reply with the single word ok.", path, RUNS)
    usage = record["result"].get("usage") or {}
    total = usage.get("input_tokens", 0) + usage.get("cache_creation_input_tokens", 0) + usage.get("cache_read_input_tokens", 0)
    base = first_usage("probe", "P")
    tokens = total - base
    result = {"qid": qid, "k": k, "chars": len(row["explore_text"]), "tokens": tokens, "chars_per_token": round(len(row["explore_text"]) / max(1, tokens), 3), "probe_base_tokens": base, "cost": record["result"].get("total_cost_usd")}
    write_json(os.path.join(label_dir(label), f"m1p-calibration-{qid}-k{k}.json"), result)
    print(json.dumps(result, indent=2))


def m1p_speed(label):
    regions, _ = load_files(label)
    code = sorted((r for r, row in regions.items() if row["family"] == "code"), key=lambda r: int(r[1:]))
    items = []
    for q in seen_questions():
        for i in range(0, len(code), 3):
            items.append({"id": f"{q['id']}-{i}", "text": q["text"], "regions": code[i:i + 3]})
    results = run_eval_set(label, items, ["--limit", "1", "--k", "5"], "m1p-speed")
    rank_ms = [r["rank_ms"] for x in results.values() for r in x["rankings"]]
    explore_ms = [x["explore_ms"] for x in results.values() if "explore_ms" in x]
    candidates = [r["candidates"] for x in results.values() for r in x["rankings"]]
    summary = {
        "rankings": len(rank_ms),
        "rank_ms": {"p50": percentile(rank_ms, 0.5), "p90": percentile(rank_ms, 0.9), "p99": percentile(rank_ms, 0.99), "max": max(rank_ms) if rank_ms else None},
        "explore_ms": {"count": len(explore_ms), "p50": percentile(explore_ms, 0.5), "p99": percentile(explore_ms, 0.99), "max": max(explore_ms) if explore_ms else None},
        "candidates": {"p50": percentile(candidates, 0.5), "max": max(candidates) if candidates else None},
    }
    write_json(os.path.join(label_dir(label), "m1p-speed.json"), {"label": label, "summary": summary})
    print(json.dumps(summary, indent=2))


SESSIONS = os.path.join(PROJECT, "eval", "session-map-runs")
OPUS_PRICE = {"cache_read": 0.2e-6, "cache_write": 8.0e-6, "output": 20.0e-6, "input": 4.0e-6}
TOOL_TOKENS = 300


def flat_sessions():
    import glob
    rows = []
    for meta_path in glob.glob(os.path.join(SESSIONS, "**", "*.meta.json"), recursive=True):
        meta = read_json(meta_path)
        if meta.get("arm") not in ("A", "Aprime") or not str(meta.get("model_flag", "")).startswith("claude-opus"):
            continue
        result = None
        with open(meta_path.replace(".meta.json", ".jsonl"), encoding="utf-8") as f:
            for line in f:
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue
                event = event.get("event", event)
                if isinstance(event, dict) and event.get("type") == "result":
                    result = event
        if not result or not result.get("total_cost_usd"):
            continue
        usage = result.get("usage") or {}
        rows.append({"arm": meta["arm"], "question": meta["question"], "phase": meta["phase"], "turns": result.get("num_turns"),
                     "usd": result["total_cost_usd"], "api_ms": result.get("duration_api_ms"),
                     "cache_write": usage.get("cache_creation_input_tokens", 0), "cache_read": usage.get("cache_read_input_tokens", 0),
                     "output": usage.get("output_tokens", 0), "path": os.path.relpath(meta_path, SESSIONS)})
    return rows


def median(values):
    values = sorted(values)
    if not values:
        return 0
    mid = len(values) // 2
    return values[mid] if len(values) % 2 else (values[mid - 1] + values[mid]) / 2


class PricedSession:
    def __init__(self, prefix, price, warm):
        self.price = price
        self.context = prefix
        self.warm = warm
        self.cost = 0.0
        self.tokens = {"cache_write": 0, "cache_read": 0, "output": 0}
        self.turns = 0

    def turn(self, new_tokens, output_tokens):
        if self.warm:
            self.tokens["cache_read"] += self.context
            self.cost += self.context * self.price["cache_read"]
        else:
            self.tokens["cache_write"] += self.context
            self.cost += self.context * self.price["cache_write"]
            self.warm = True
        self.tokens["cache_write"] += new_tokens
        self.cost += new_tokens * self.price["cache_write"] + output_tokens * self.price["output"]
        self.tokens["output"] += output_tokens
        self.context += new_tokens + output_tokens
        self.turns += 1


def flat_model(rows, arm):
    repeat = [r for r in rows if r["arm"] == arm and r["phase"] == "repeat"]
    first = [r for r in rows if r["arm"] == arm and r["phase"] == "first"]
    turns = median([r["turns"] for r in repeat])
    output = median([r["output"] for r in repeat])
    growth = median([r["cache_write"] for r in repeat])
    prefix = round(median([r["cache_write"] for r in first]) - growth)
    return {"arm": arm, "sessions": len(repeat) + len(first), "turns_per_question": turns, "output_per_question": output,
            "new_tokens_per_question": growth, "prefix_tokens": prefix,
            "measured_one_question_warm_usd": round(median([r["usd"] for r in repeat]), 4),
            "measured_one_question_cold_usd": round(median([r["usd"] for r in first]), 4),
            "measured_api_ms_warm": median([r["api_ms"] for r in repeat])}


def simulate_flat(model, questions, warm):
    s = PricedSession(model["prefix_tokens"], OPUS_PRICE, warm)
    turns = max(1, round(model["turns_per_question"]))
    for _ in range(questions):
        for _ in range(turns):
            s.turn(QUESTION_TOKENS / turns + model["new_tokens_per_question"] / turns, model["output_per_question"] / turns)
    return {"usd": round(s.cost, 4), "turns_per_question": turns, **{k: round(v) for k, v in s.tokens.items()}}


def simulate_explore(prefix, questions, p_two, call_out, explore_tokens, answer_tokens, evidence_tokens, warm):
    total = {"usd": 0.0, "cache_write": 0.0, "cache_read": 0.0, "output": 0.0, "turns": 0.0}
    for outcome, weight in (("two", p_two), ("three", 1 - p_two)):
        if weight <= 0:
            continue
        s = PricedSession(prefix, PRICE, warm)
        for _ in range(questions):
            s.turn(QUESTION_TOKENS, call_out)
            if outcome == "two":
                s.turn(explore_tokens, answer_tokens)
            else:
                s.turn(explore_tokens, TOOL_CALL_TOKENS)
                s.turn(evidence_tokens, answer_tokens)
        total["usd"] += weight * s.cost
        total["turns"] += weight * s.turns / questions
        for k in ("cache_write", "cache_read", "output"):
            total[k] += weight * s.tokens[k]
    return {"usd": round(total["usd"], 4), "turns_per_question": round(total["turns"], 2), **{k: round(total[k]) for k in ("cache_write", "cache_read", "output")}}


def m1p_cost(label, k, explore_tokens):
    regions_report = read_json(os.path.join(label_dir(label), "m1p-regions.json"))
    combined = read_json(os.path.join(label_dir(label), "m1p-combined.json"))["summary"]
    calls = [r for r in regions_report["rows"]]
    first = min(calls, key=lambda r: (r["set"] != "seen", r["qid"], r["trial"]))
    map_prefix = first["input_tokens"] + first["cache_creation_input_tokens"] + first["cache_read_input_tokens"] - QUESTION_TOKENS
    prefix = map_prefix + TOOL_TOKENS
    call_out = median([r["output_tokens"] for r in calls])
    rows = flat_sessions()
    flats = [flat_model(rows, "A"), flat_model(rows, "Aprime")]
    out = {"assumptions": {"sonnet_price": PRICE, "opus_price": OPUS_PRICE, "question_tokens": QUESTION_TOKENS, "tool_definition_tokens": TOOL_TOKENS,
                           "turn1_output_tokens_measured_median": call_out, "explore_tokens": explore_tokens, "answer_tokens": ANSWER_TOKENS,
                           "third_turn_evidence_tokens": EVIDENCE_TOKENS, "map_prefix_tokens_measured": map_prefix, "k": k},
           "flat": flats, "rows": []}
    for set_name in ("seen", "general"):
        if set_name not in combined:
            continue
        p_two = combined[set_name][f"combined_at{k}"]
        for q in (1, 3, 10):
            for warm in (True, False):
                row = {"option": f"map + explore (Sonnet), {set_name} combined@{k} = {p_two}", "questions": q, "cache": "warm" if warm else "cold",
                       **simulate_explore(prefix, q, p_two, call_out, explore_tokens, ANSWER_TOKENS, EVIDENCE_TOKENS, warm)}
                out["rows"].append(row)
    for model in flats:
        for q in (1, 3, 10):
            for warm in (True, False):
                out["rows"].append({"option": f"flat Claude {model['arm']} (Opus)", "questions": q, "cache": "warm" if warm else "cold", **simulate_flat(model, q, warm)})
    write_json(os.path.join(label_dir(label), "m1p-cost.json"), out)
    for model in flats:
        print(model)
    for r in out["rows"]:
        print(r["option"], r["questions"], r["cache"], r["usd"], r["turns_per_question"])


def main():
    parser = argparse.ArgumentParser(description="M1 map selection gate: the model picks regions and symbols from the map alone")
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("prepare")
    p.add_argument("label")
    p.add_argument("extra", nargs=argparse.REMAINDER)
    s = sub.add_parser("seen")
    s.add_argument("label")
    s.add_argument("--trials", type=int, default=3)
    g = sub.add_parser("select")
    g.add_argument("label")
    g.add_argument("--out", default=os.path.join(RUNS, "general_set.json"))
    g.add_argument("--size", type=int, default=GENERAL_SIZE)
    r = sub.add_parser("general")
    r.add_argument("label")
    r.add_argument("--set", default=os.path.join(RUNS, "general_set.json"))
    c = sub.add_parser("score")
    c.add_argument("label")
    c.add_argument("--set", default=os.path.join(RUNS, "general_set.json"))
    b = sub.add_parser("probe")
    b.add_argument("label")
    k = sub.add_parser("rank")
    k.add_argument("label")
    k.add_argument("--set", default=os.path.join(RUNS, "general_set.json"))
    h = sub.add_parser("seen-hook")
    h.add_argument("label")
    h.add_argument("--trials", type=int, default=1)
    m = sub.add_parser("cost")
    m.add_argument("--hook-label", default="v2-24k")
    m.add_argument("--small-tokens", type=int, default=8000)
    sub.add_parser("spent")
    ms = sub.add_parser("m1p-seen")
    ms.add_argument("label")
    ms.add_argument("--trials", type=int, default=3)
    mg = sub.add_parser("m1p-general")
    mg.add_argument("label")
    mg.add_argument("--set", default=os.path.join(RUNS, "general_set.json"))
    mc = sub.add_parser("m1p-score")
    mc.add_argument("label")
    mc.add_argument("--set", default=os.path.join(RUNS, "general_set.json"))
    mr = sub.add_parser("m1p-rank")
    mr.add_argument("label")
    mr.add_argument("--set", default=os.path.join(RUNS, "general_set.json"))
    mr.add_argument("--general", action="store_true")
    mr.add_argument("--limit", type=int, default=50)
    mr.add_argument("--rank-args", default="")
    mr.add_argument("--tag", default="")
    mb = sub.add_parser("m1p-combined")
    mb.add_argument("label")
    mb.add_argument("--set", default=os.path.join(RUNS, "general_set.json"))
    me = sub.add_parser("m1p-explore")
    me.add_argument("label")
    me.add_argument("--set", default=os.path.join(RUNS, "general_set.json"))
    me.add_argument("--general", action="store_true")
    me.add_argument("--ks", default="3,5,8")
    me.add_argument("--budget", type=int, default=12000)
    me.add_argument("--rank-args", default="")
    mo = sub.add_parser("m1p-cost")
    mo.add_argument("label")
    mo.add_argument("--k", type=int, default=5)
    mo.add_argument("--explore-tokens", type=int, required=True)
    mp = sub.add_parser("m1p-speed")
    mp.add_argument("label")
    mk = sub.add_parser("m1p-calibrate")
    mk.add_argument("label")
    mk.add_argument("--qid", default="S1")
    mk.add_argument("--k", type=int, default=5)
    args = parser.parse_args()
    if args.command == "m1p-seen":
        m1p_seen(args.label, args.trials)
        return
    if args.command == "m1p-general":
        m1p_general(args.label, args.set)
        return
    if args.command == "m1p-score":
        m1p_score(args.label, args.set)
        return
    if args.command == "m1p-rank":
        m1p_rank(args.label, args.set, args.general, args.limit, args.rank_args.split(), args.tag)
        return
    if args.command == "m1p-combined":
        m1p_combined(args.label, args.set)
        return
    if args.command == "m1p-explore":
        m1p_explore(args.label, args.set, args.general, [int(k) for k in args.ks.split(",")], args.budget, args.rank_args.split())
        return
    if args.command == "m1p-cost":
        m1p_cost(args.label, args.k, args.explore_tokens)
        return
    if args.command == "m1p-speed":
        m1p_speed(args.label)
        return
    if args.command == "m1p-calibrate":
        m1p_calibrate(args.label, args.qid, args.k)
        return
    if args.command == "rank":
        rank_eval(args.label, args.set)
        return
    if args.command == "cost":
        def rate(label, key):
            s = read_json(os.path.join(label_dir(label), "score.json"))["summary"]["seen"]
            return s[key] / s["calls"]
        rank = read_json(os.path.join(label_dir(args.hook_label), "rank.json"))["summary"]
        hook_tokens = round(rank["seen"]["mean_block_chars"] / 2.02)
        small_prefix = args.small_tokens + first_usage("probe", "P")
        rows = cost_model([
            ("map 16k budget (v1, measured 26k)", "v1", rate("v1", "symbol"), 0.0, 0),
            ("map 24k", "v2-24k", rate("v2-24k", "symbol"), 0.0, 0),
            ("map 32k", "v3-32k", rate("v3-32k", "symbol"), 0.0, 0),
        ])
        for name, p_hook in (("small map + hook, seen ranker hit", rank["seen"]["code_full"]), ("small map + hook, general ranker hit", rank["general"]["code_full"])):
            row = {"option": f"{name} ({args.small_tokens} map tokens)", "prefix_tokens": small_prefix, "hook_tokens": hook_tokens, "p_one_turn": p_hook, "p_two_turns": 0.0}
            for q in (1, 3, 10):
                row[f"q{q}"] = expected_session(small_prefix, q, p_hook, 0.0, hook_tokens)
            rows.append(row)
        write_json(os.path.join(RUNS, "cost-model.json"), {"prices_per_token": PRICE, "assumptions": {"question": QUESTION_TOKENS, "tool_call": TOOL_CALL_TOKENS, "answer": ANSWER_TOKENS, "evidence": EVIDENCE_TOKENS, "listing": LISTING_TOKENS}, "rows": rows})
        for r in rows:
            print(r["option"], "prefix", r["prefix_tokens"], "hook", r["hook_tokens"], "1-turn", r["p_one_turn"], "2-turn", r["p_two_turns"])
            for q in (1, 3, 10):
                print("   ", q, "questions:", r[f"q{q}"])
        return
    if args.command == "seen-hook":
        run_seen_hook(args.label, args.trials)
        return
    if args.command == "prepare":
        prepare(args.label, args.extra)
    elif args.command == "seen":
        run_seen(args.label, args.trials)
    elif args.command == "select":
        select(args.label, args.out, args.size)
    elif args.command == "general":
        run_general(args.label, args.set)
    elif args.command == "score":
        score(args.label, args.set)
    elif args.command == "probe":
        probe(args.label)
    elif args.command == "spent":
        print(f"m1 {spent():.4f} m1p {spent(M1P_LEDGER):.4f}")


if __name__ == "__main__":
    main()
