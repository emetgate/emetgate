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


def spent():
    if not os.path.exists(LEDGER):
        return 0.0
    total = 0.0
    with open(LEDGER, encoding="utf-8") as f:
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
    if spent() + CALL_CAP_USD > BUDGET_USD:
        raise SystemExit(f"model budget reached: spent {spent():.4f} of {BUDGET_USD} USD")
    argv = [CLAUDE, "-p", question, "--model", MODEL, "--tools", "", "--append-system-prompt-file", prompt_file,
            "--output-format", "json", "--no-session-persistence", "--safe-mode", "--strict-mcp-config",
            "--mcp-config", '{"mcpServers":{}}', "--max-budget-usd", str(CALL_CAP_USD)]
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
    with open(LEDGER, "a", encoding="utf-8", newline="\n") as f:
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
    sub.add_parser("spent")
    args = parser.parse_args()
    if args.command == "rank":
        rank_eval(args.label, args.set)
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
        print(f"{spent():.4f}")


if __name__ == "__main__":
    main()
