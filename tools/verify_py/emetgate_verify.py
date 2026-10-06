import argparse
import hashlib
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "..", "vendor", "pure_python_blake3"))

import jcs
from pure_blake3 import Hasher

STATEMENT_TYPE = "https://in-toto.io/Statement/v1"
PREDICATE_TYPE = "https://emetgate.dev/receipt/v1"
FILE_DIGEST = "blake3-128"
NOTES_REF = "emetgate"
OPERATIONS = {"try", "try_batch", "rename", "move", "move_file"}
CLASSES = {"symmetry", "spending"}
CHECK_KINDS = {"typecheck", "test"}
HEX = re.compile(r"^[0-9a-f]*$")

VERIFIED = "verified"
UNVERIFIED = "unverified"
MISMATCH = "mismatch"
CONSISTENT = "consistent"
NOT_CHECKED_OUT = "the checked-out form of a filtered file is not available"
NO_FILTER = (b"unspecified", b"unset", b"set", b"")
RANK = {VERIFIED: 0, UNVERIFIED: 1, MISMATCH: 2}
EXIT = {VERIFIED: 0, CONSISTENT: 55, UNVERIFIED: 53, MISMATCH: 54}


class Invalid(Exception):
    pass


def blake3_128(data):
    hasher = Hasher()
    hasher.update(data)
    return hasher.finalize(32)[:16].hex()


def sha256(data):
    return hashlib.sha256(data).hexdigest()


class Outcome:
    def __init__(self):
        self.verdict = VERIFIED
        self.reason = ""

    def raise_to(self, verdict, reason):
        if RANK[verdict] > RANK[self.verdict]:
            self.verdict = verdict
            self.reason = reason


class Git:
    def __init__(self, repo):
        self.repo = repo

    def run(self, *args):
        result = subprocess.run(["git", "-C", self.repo, "-c", "core.longpaths=true", *args], capture_output=True)
        return result.stdout if result.returncode == 0 else None

    def commit(self, spec):
        out = self.run("rev-parse", "--verify", "--quiet", spec + "^{commit}")
        return out.decode().strip() if out else None

    def blob(self, rev, path):
        if rev is None:
            return None
        return self.run("cat-file", "blob", rev + ":" + path)

    def filtered(self, rev, path):
        out = self.run("check-attr", "-z", "--source", rev, "filter", "--", path)
        if out is None:
            out = self.run("check-attr", "-z", "filter", "--", path)
        if out is None:
            return False
        fields = out.split(b"\0")
        return len(fields) >= 3 and fields[2] not in NO_FILTER

    def form(self, rev, path):
        stored = self.blob(rev, path)
        if stored is None or not self.filtered(rev, path):
            return stored, False, True
        text = self.run("--attr-source=" + rev, "cat-file", "--filters", rev + ":" + path)
        return text, True, text is not None

    def changed(self, rev):
        out = self.run("diff-tree", "--no-commit-id", "--root", "-r", "--name-only", "-z", rev)
        if out is None:
            raise SystemExit("git diff-tree failed")
        return [p.decode("utf-8") for p in out.split(b"\0") if p]

    def note(self, rev):
        out = self.run("notes", "--ref=" + NOTES_REF, "show", rev)
        if out is None:
            return None
        return out.rstrip(b"\r\n")


def exact_keys(obj, keys):
    if not isinstance(obj, dict) or set(obj) != set(keys):
        raise Invalid("unexpected or missing members")


def text(value):
    if not isinstance(value, str):
        raise Invalid("expected a string")
    return value


def integer(value):
    if isinstance(value, bool) or not isinstance(value, int):
        raise Invalid("expected an integer")
    return value


def digest(value, size):
    value = text(value)
    if len(value) != size * 2 or not HEX.match(value):
        raise Invalid("bad digest")
    return value


def optional_digest(value):
    return None if value is None else digest(value, 16)


def valid_path(path):
    path = text(path)
    if not path or path.startswith("/") or "\\" in path or (len(path) > 1 and path[1] == ":"):
        raise Invalid("bad path")
    for part in path.split("/"):
        if part in ("", ".", ".."):
            raise Invalid("bad path")
    return path


def read_receipt(value):
    exact_keys(value, ["_type", "subject", "predicateType", "predicate"])
    if value["_type"] != STATEMENT_TYPE or value["predicateType"] != PREDICATE_TYPE:
        raise Invalid("not an emetgate receipt")
    p = value["predicate"]
    exact_keys(p, ["batch", "operation", "class", "evidence", "resolver", "files", "symbols", "checks", "rules", "sandbox", "emetgate"])
    subjects = []
    for s in list_of(value["subject"]):
        exact_keys(s, ["name", "digest"])
        exact_keys(s["digest"], [FILE_DIGEST, "sha256"])
        subjects.append({"path": valid_path(s["name"]), "blake3": digest(s["digest"][FILE_DIGEST], 16), "sha256": digest(s["digest"]["sha256"], 32)})
    files = []
    for f in list_of(p["files"]):
        exact_keys(f, ["path", "before", "after"])
        entry = {"path": valid_path(f["path"]), "before": optional_digest(f["before"]), "after": optional_digest(f["after"])}
        if entry["before"] is None and entry["after"] is None:
            raise Invalid("a file entry with neither side")
        if any(e["path"] == entry["path"] for e in files):
            raise Invalid("a path listed twice")
        files.append(entry)
    if not files:
        raise Invalid("no files")
    symbols = []
    for s in list_of(p["symbols"]):
        exact_keys(s, ["path", "ref", "before", "after"])
        if not any(f["path"] == s["path"] for f in files):
            raise Invalid("a symbol in a file the receipt does not list")
        symbols.append({"path": s["path"], "ref": text(s["ref"]), "before": optional_digest(s["before"]), "after": optional_digest(s["after"])})
    checks = []
    for c in list_of(p["checks"]):
        exact_keys(c, ["kind", "command", "command_digest", "exit_code", "duration_ms"])
        if c["kind"] not in CHECK_KINDS:
            raise Invalid("unknown check kind")
        if c["duration_ms"] is not None:
            integer(c["duration_ms"])
        checks.append({"kind": c["kind"], "command": text(c["command"]), "command_digest": digest(c["command_digest"], 16), "exit_code": integer(c["exit_code"])})
    rules = []
    for r in list_of(p["rules"]):
        exact_keys(r, ["id", "digest"])
        rules.append({"id": text(r["id"]), "digest": digest(r["digest"], 16)})
    exact_keys(p["sandbox"], ["integrity", "job_memory_bytes", "active_process_limit", "timeout_ms", "output_limit_bytes"])
    exact_keys(p["emetgate"], ["version"])
    if p["operation"] not in OPERATIONS or p["class"] not in CLASSES:
        raise Invalid("unknown operation or class")
    text(p["evidence"])
    if p["resolver"] is not None:
        text(p["resolver"])
    digest(p["batch"], 8)
    return {"batch": p["batch"], "operation": p["operation"], "class": p["class"], "subjects": subjects, "files": files, "symbols": symbols, "checks": checks, "rules": rules}


def list_of(value):
    if not isinstance(value, list):
        raise Invalid("expected an array")
    return value


def not_checked(r):
    out = []
    if r["symbols"]:
        out.append("symbols")
    if r["class"] == "spending":
        out.append("tests")
    else:
        out.append("symmetry")
    if r["rules"]:
        out.append("rules")
    return out


def reported(verdict, skipped):
    if verdict == VERIFIED and skipped:
        return CONSISTENT
    return verdict


def verify(git, spec):
    rev = git.commit(spec)
    if rev is None:
        raise SystemExit("unknown commit: " + spec)
    parent = git.commit(rev + "^")
    changed = git.changed(rev)
    note = git.note(rev)

    files = {}
    order = []

    def raise_file(path, verdict, reason):
        if path not in files:
            files[path] = Outcome()
            order.append(path)
        files[path].raise_to(verdict, reason)

    results = []
    receipts = []
    note_ok = True
    if note is not None:
        try:
            value = jcs.parse(note)
            if not isinstance(value, list) or jcs.canonicalize(value) != note:
                note_ok = False
        except jcs.NotCanonical:
            note_ok = False
        if note_ok:
            for item in value:
                ident = sha256(jcs.canonicalize(item))
                try:
                    r = read_receipt(item)
                    receipts.append(r)
                    results.append({"id": ident, "batch": r["batch"], "operation": r["operation"], "outcome": Outcome(), "receipt": r})
                except Invalid:
                    outcome = Outcome()
                    outcome.raise_to(MISMATCH, "the receipt does not follow the format")
                    results.append({"id": ident, "batch": "", "operation": "", "outcome": outcome, "receipt": None})

    last = {}
    for index, r in enumerate(receipts):
        for f in r["files"]:
            last[f["path"]] = index

    state = {}

    def current(path):
        if path not in state:
            data, driven, available = git.form(parent, path)
            state[path] = (blob_digest(data), driven, available)
        return state[path]

    index = 0
    for result in results:
        r = result["receipt"]
        if r is None:
            continue
        outcome = result["outcome"]
        for s in r["subjects"]:
            if not any(f["path"] == s["path"] and f["after"] == s["blake3"] for f in r["files"]):
                outcome.raise_to(MISMATCH, "a subject does not match the files of the predicate")
        for f in r["files"]:
            if f["after"] is not None and not any(s["path"] == f["path"] for s in r["subjects"]):
                outcome.raise_to(MISMATCH, "a written file is not a subject")
        for f in r["files"]:
            before, driven, available = current(f["path"])
            if driven and (not available or before != f["before"]):
                outcome.raise_to(UNVERIFIED, NOT_CHECKED_OUT)
            elif before != f["before"]:
                outcome.raise_to(MISMATCH, "the before digest does not match the parent commit or the previous receipt")
            if last[f["path"]] == index:
                data, driven, available = git.form(rev, f["path"])
                if not available:
                    outcome.raise_to(UNVERIFIED, NOT_CHECKED_OUT)
                    raise_file(f["path"], UNVERIFIED, NOT_CHECKED_OUT)
                elif blob_digest(data) == f["after"]:
                    for s in r["subjects"]:
                        if s["path"] == f["path"] and sha256(data) != s["sha256"]:
                            outcome.raise_to(MISMATCH, "a subject's sha256 does not match the commit")
                else:
                    raise_file(f["path"], UNVERIFIED, "the file changed after the receipt, outside the gate")
            state[f["path"]] = (f["after"], False, True)
        for c in r["checks"]:
            if blake3_128(c["command"].encode("utf-8")) != c["command_digest"]:
                outcome.raise_to(MISMATCH, "a check's command does not match its digest")
            if c["exit_code"] != 0:
                outcome.raise_to(MISMATCH, "the receipt records a failing check")
        if r["class"] == "spending" and not r["checks"]:
            outcome.raise_to(UNVERIFIED, "a spending receipt without a check")
        result["not_checked"] = not_checked(r)
        for f in r["files"]:
            raise_file(f["path"], outcome.verdict, outcome.reason)
        index += 1

    for path in changed:
        if path not in last:
            raise_file(path, UNVERIFIED, "no receipt covers this change")
    verdict = VERIFIED
    for outcome in [files[p] for p in order] + [r["outcome"] for r in results]:
        if RANK[outcome.verdict] > RANK[verdict]:
            verdict = outcome.verdict
    if not note_ok:
        verdict = MISMATCH
        for path in changed:
            raise_file(path, MISMATCH, "the receipt note is not canonical JSON")
    skipped = sorted({name for r in results for name in r.get("not_checked", [])})
    file_skipped = {p: set() for p in order}
    for r in results:
        if r["receipt"] is None:
            continue
        for f in r["receipt"]["files"]:
            file_skipped[f["path"]].update(r.get("not_checked", []))

    def file_entry(p):
        entry = {"path": p, "verdict": reported(files[p].verdict, file_skipped[p]), "not_checked": sorted(file_skipped[p])}
        if files[p].reason:
            entry["reason"] = files[p].reason
        return entry

    def receipt_entry(r):
        entry = {"id": r["id"], "batch": r["batch"], "operation": r["operation"], "verdict": reported(r["outcome"].verdict, r.get("not_checked", [])), "not_checked": r.get("not_checked", [])}
        if r["outcome"].reason:
            entry["reason"] = r["outcome"].reason
        return entry

    return {
        "commit": rev,
        "verdict": reported(verdict, skipped),
        "files": [file_entry(p) for p in order],
        "receipts": [receipt_entry(r) for r in results],
        "not_checked": skipped,
    }


def blob_digest(data):
    return None if data is None else blake3_128(data)


def main():
    parser = argparse.ArgumentParser(description="Second, independent checker for emetgate receipts")
    parser.add_argument("commit")
    parser.add_argument("--repo", default=".")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    report = verify(Git(args.repo), args.commit)
    if args.json:
        print(json.dumps(report))
    else:
        print("commit %s: %s" % (report["commit"], report["verdict"]))
        for f in report["files"]:
            print("  %-10s %s%s" % (f["verdict"], f["path"], ("  (" + f["reason"] + ")") if "reason" in f else ""))
        if report["not_checked"]:
            print("  not checked here: " + ", ".join(report["not_checked"]))
        if report["verdict"] == CONSISTENT:
            print("  consistent: everything this checker checks holds; it is not verified, the fields above were not checked")
    return EXIT[report["verdict"]]


if __name__ == "__main__":
    sys.exit(main())
