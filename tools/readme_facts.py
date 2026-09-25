import argparse
import re
import sys

import mutation_stats
from verification_page import ROOT, README_PATH

import os

QUERY_ZIG = os.path.join(ROOT, "src", "engine", "query.zig")
HANDLERS_ZIG = os.path.join(ROOT, "src", "protocol", "handlers.zig")

ENGINE_FILES = {
    "src/engine/cas.zig",
    "src/engine/boundedness.zig",
    "src/engine/symbol.zig",
    "src/engine/functions.zig",
}

STATUS_WORDS = {
    "killed": "killed",
    "equivalent": "proven equivalent",
    "defense in depth": ("redundant guard kept as defense in depth", "redundant guards kept as defense in depth"),
    "open": "open",
}


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def extract_const(source, name):
    pattern = re.compile(r"pub const %s(?:\s*:\s*[^=]+)?\s*=\s*([^;]+);" % re.escape(name))
    match = pattern.search(source)
    if not match:
        raise ValueError(f"constant {name} not found")
    return match.group(1).strip()


def eval_numeric(expr):
    expr = expr.replace("_", "")
    return eval(expr, {"__builtins__": {}}, {})


def with_commas(n):
    return f"{n:,}"


def fact_max_query_bytes():
    source = read(QUERY_ZIG)
    prefix_len = len("q:")
    raw = extract_const(source, "max_query_bytes")
    total = eval_numeric(raw.replace("prefix.len", str(prefix_len)))
    return f"{round(total / 1024)} KB"


def fact_max_captures_per_pattern():
    source = read(QUERY_ZIG)
    return str(eval_numeric(extract_const(source, "max_captures_per_pattern")))


def fact_max_depth_product():
    source = read(QUERY_ZIG)
    return with_commas(eval_numeric(extract_const(source, "max_depth_product")))


def fact_query_operations():
    source = read(QUERY_ZIG)
    match = re.search(r"operations:\s*u64\s*=\s*([0-9_]+)", source)
    if not match:
        raise ValueError("Limits.operations default not found")
    return with_commas(eval_numeric(match.group(1)))


def fact_query_match_limit():
    source = read(QUERY_ZIG)
    match = re.search(r"match_limit:\s*u32\s*=\s*([0-9_]+)", source)
    if not match:
        raise ValueError("Limits.match_limit default not found")
    return str(eval_numeric(match.group(1)))


def fact_max_scan_operations():
    source = read(HANDLERS_ZIG)
    raw = extract_const(source, "max_scan_operations")
    return with_commas(eval_numeric(raw))


def fact_engine_mutant_summary():
    mutations = mutation_stats.load_mutations()
    by_status = mutation_stats.counts_for_files(mutations, ENGINE_FILES)
    total = sum(len(v) for v in by_status.values())
    parts = []
    for key in ("killed", "equivalent", "defense in depth", "open"):
        n = len(by_status.get(key, []))
        if n == 0 and key != "killed":
            continue
        word = STATUS_WORDS[key]
        if isinstance(word, tuple):
            word = word[0] if n == 1 else word[1]
        parts.append(f"{n} {word}")
    return f"{total} mutants today: " + ", ".join(parts)


FACTS = {
    "max_query_bytes": fact_max_query_bytes,
    "max_captures_per_pattern": fact_max_captures_per_pattern,
    "query_operations": fact_query_operations,
    "max_scan_operations": fact_max_scan_operations,
    "query_match_limit": fact_query_match_limit,
    "max_depth_product": fact_max_depth_product,
    "engine-mutant-summary": fact_engine_mutant_summary,
}

MARKER = re.compile(r"<!-- generated:([a-zA-Z0-9_-]+) -->(.*?)<!-- /generated -->", re.DOTALL)


def render(readme_text):
    def replace(match):
        name = match.group(1)
        if name not in FACTS:
            raise ValueError(f"no fact generator registered for {name}")
        value = FACTS[name]()
        return f"<!-- generated:{name} -->{value}<!-- /generated -->"

    return MARKER.sub(replace, readme_text)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    current = read(README_PATH)
    updated = render(current)

    if args.check:
        if updated != current:
            names = [m.group(1) for m in MARKER.finditer(current)]
            print("README.md generated facts are stale for one or more of:", ", ".join(names))
            print("run: python tools/readme_facts.py")
            sys.exit(1)
        print("README.md generated facts are up to date")
        return

    if updated != current:
        with open(README_PATH, "w", encoding="utf-8", newline="\n") as f:
            f.write(updated)
        print("updated README.md")
    else:
        print("README.md already up to date")


if __name__ == "__main__":
    main()
