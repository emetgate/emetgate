import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MUTATIONS_PATH = os.path.join(ROOT, "tests", "mutations.json")

STATUS_KEYWORDS = [
    ("control", "control"),
    ("compile_error", "compile-error control"),
    ("equivalent", "equivalent"),
    ("defense in depth", "defense in depth"),
    ("open:", "open"),
    ("redundant", "defense in depth"),
]


def load_mutations():
    with open(MUTATIONS_PATH, encoding="utf-8") as f:
        return json.load(f)["mutations"]


def classify(mutation):
    if mutation.get("expect") == "e2e-lockdown":
        return "verified end-to-end, not by the mutation harness"
    if "expect_status" not in mutation:
        return "killed"
    note = (mutation.get("note") or "").lower()
    prefix = note.split(":", 1)[0]
    for keyword, label in STATUS_KEYWORDS:
        if keyword.rstrip(":") in prefix:
            return label
    for keyword, label in STATUS_KEYWORDS:
        if keyword == "equivalent":
            continue
        if keyword in note:
            return label
    if mutation["expect_status"] == "compile_error":
        return "compile-error control"
    if mutation["expect_status"] == "timeout":
        return "not caught by a test, documented as unbounded cost"
    return "survives (unclassified)"


def counts_for_files(mutations, files):
    by_status = {}
    for m in mutations:
        if m["file"] not in files:
            continue
        by_status.setdefault(classify(m), []).append(m)
    return by_status
