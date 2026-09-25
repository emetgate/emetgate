import argparse
import json
import os
import queue
import re
import shutil
import subprocess
import sys
import tempfile
import threading
from collections import Counter
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_EXE = REPO_ROOT / "zig-out" / "bin" / "emetgate.exe"
DEFAULT_CORPUS = REPO_ROOT / "tests" / "attack" / "corpus.json"


class Server:
    def __init__(self, exe, cwd, test_cmd):
        self.proc = subprocess.Popen(
            [str(exe), "mcp", "--test", test_cmd],
            cwd=str(cwd),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        self.out_q = queue.Queue()
        self.reader = threading.Thread(target=self._pump, daemon=True)
        self.reader.start()
        self.next_id = 1

    def _pump(self):
        for line in self.proc.stdout:
            self.out_q.put(line)
        self.out_q.put(None)

    def call(self, tool, arguments, timeout=20):
        request = {
            "jsonrpc": "2.0",
            "id": self.next_id,
            "method": "tools/call",
            "params": {"name": tool, "arguments": arguments},
        }
        self.next_id += 1
        self.proc.stdin.write(json.dumps(request) + "\n")
        self.proc.stdin.flush()
        try:
            line = self.out_q.get(timeout=timeout)
        except queue.Empty:
            return None
        return line

    def close(self):
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=10)
        except Exception:
            self.proc.kill()


def resolve_hashes(server, fixture_path):
    line = server.call("emetgate_symbols", {"file": fixture_path})
    hashes = {}
    if line:
        pattern = r'hash\\+":\\+"([0-9a-f]{32})\\+".*?ref\\+":\\+"([A-Za-z0-9_.]+)\\+"'
        for match in re.finditer(pattern, line):
            hashes[match.group(2)] = match.group(1)
    return hashes


def expand_repeat(text):
    match = re.fullmatch(r"<REPEAT:(.*),(\d+)>", text, re.S)
    if not match:
        return text
    piece, count = match.group(1), int(match.group(2))
    return piece * count


def expand_value(value, hashes, outside_abs):
    if isinstance(value, str):
        if value == "<OUTSIDE_ABS>":
            return outside_abs
        if value.startswith("<REPEAT_EDITS:"):
            n = int(value[len("<REPEAT_EDITS:") : -1])
            return [
                {
                    "file": "src/target.ts",
                    "symbol": "privHelper",
                    "hash": hashes.get("privHelper", "absent"),
                    "body": "{ return a; }",
                }
                for _ in range(n)
            ]
        if value.startswith("<REPEAT:"):
            return expand_repeat(value)

        def sub_hash(match):
            name = match.group(1)
            return hashes.get(name, "absent")

        return re.sub(r"<HASH:([A-Za-z0-9_.]+)>", sub_hash, value)
    if isinstance(value, list):
        return [expand_value(v, hashes, outside_abs) for v in value]
    if isinstance(value, dict):
        return {k: expand_value(v, hashes, outside_abs) for k, v in value.items()}
    return value


def git(cwd, *args):
    result = subprocess.run(
        ["git", *args], cwd=str(cwd), capture_output=True, text=True
    )
    return result.stdout


def git_clean(cwd):
    return git(cwd, "status", "--porcelain").strip() == ""


def is_breach(clean, outside_changed, marker_exists, leaked=False):
    return (not clean) or outside_changed or marker_exists or leaked


def load_spec(corpus_path):
    return json.loads(corpus_path.read_text(encoding="utf-8"))


def run_cases(exe, spec, cases, verbose):
    workdir = Path(tempfile.mkdtemp(prefix="emetgate-attack-"))
    repo = workdir / "repo"
    repo.mkdir()
    subprocess.run(["git", "init", "-q"], cwd=str(repo), check=True)
    subprocess.run(["git", "config", "user.email", "attack@test"], cwd=str(repo), check=True)
    subprocess.run(["git", "config", "user.name", "attack"], cwd=str(repo), check=True)

    fixture = spec["fixture"]
    fixture_path = repo / fixture["path"]
    fixture_path.parent.mkdir(parents=True, exist_ok=True)
    fixture_path.write_text(fixture["source"], encoding="utf-8")

    second_fixture = spec["second_fixture"]
    second_fixture_path = repo / second_fixture["path"]
    second_fixture_path.parent.mkdir(parents=True, exist_ok=True)
    second_fixture_path.write_text(second_fixture["source"], encoding="utf-8")

    outside = spec["outside"]
    outside_path = (repo / outside["path"]).resolve()
    outside_path.write_text(outside["source"], encoding="utf-8")
    outside_before = outside_path.read_text(encoding="utf-8")

    linked = spec.get("linked_dir")
    if linked:
        (repo / ".gitignore").write_text(f"/{linked['name']}/\n", encoding="utf-8")

    subprocess.run(["git", "add", "-A"], cwd=str(repo), check=True)
    subprocess.run(["git", "commit", "-q", "-m", "baseline"], cwd=str(repo), check=True)

    if linked:
        external_dir = workdir / "external-linked"
        external_dir.mkdir()
        (external_dir / linked["external_file"]).write_text(linked["external_source"], encoding="utf-8")
        link_path = repo / linked["name"]
        subprocess.run(
            ["cmd", "/c", "mklink", "/J", str(link_path), str(external_dir)],
            capture_output=True,
            text=True,
            check=True,
        )

    breach_marker = repo / "BREACH_MARKER.txt"
    test_cmd = "cmd /c echo owned>BREACH_MARKER.txt"

    server = Server(exe, repo, test_cmd)
    hashes = resolve_hashes(server, fixture["path"])
    hashes.update(resolve_hashes(server, second_fixture["path"]))
    if not hashes:
        server.close()
        print("could not resolve fixture symbol hashes; aborting", file=sys.stderr)
        return 1, [], Counter()

    breaches = []
    rejected_ids = []
    category_counts = Counter()
    for case in cases:
        category_counts[case["category"]] += 1
        forbidden = case.get("forbidden_in_response")
        leaked = False
        for request in case["requests"]:
            arguments = expand_value(request["arguments"], hashes, str(outside_path))
            response = server.call(request["tool"], arguments)
            if verbose:
                print(f"[{case['id']}] {request['tool']} -> {response!r}")
            if forbidden and response and forbidden in response:
                leaked = True

        clean = git_clean(repo)
        outside_after = outside_path.read_text(encoding="utf-8")
        marker_exists = breach_marker.exists()
        if is_breach(clean, outside_after != outside_before, marker_exists, leaked):
            breaches.append(
                {
                    "id": case["id"],
                    "category": case["category"],
                    "git_dirty": not clean,
                    "outside_modified": outside_after != outside_before,
                    "breach_marker": marker_exists,
                    "leaked": leaked,
                }
            )
            if marker_exists:
                breach_marker.unlink()
            if not clean:
                subprocess.run(["git", "checkout", "-q", "--", "."], cwd=str(repo))
                subprocess.run(["git", "clean", "-q", "-fd"], cwd=str(repo))
            if outside_after != outside_before:
                outside_path.write_text(outside_before, encoding="utf-8")
        else:
            rejected_ids.append(case["id"])

    server.close()
    shutil.rmtree(workdir, ignore_errors=True)
    return 0, breaches, rejected_ids, category_counts


def run_corpus(exe, corpus_path, verbose):
    spec = load_spec(corpus_path)
    return run_cases(exe, spec, spec["cases"], verbose)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--exe", default=str(DEFAULT_EXE))
    parser.add_argument("--corpus", default=str(DEFAULT_CORPUS))
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    exe = Path(args.exe)
    if not exe.exists():
        print(f"executable not found: {exe}", file=sys.stderr)
        return 2

    status, breaches, rejected_ids, category_counts = run_corpus(exe, Path(args.corpus), args.verbose)
    if status != 0:
        return status

    total = sum(category_counts.values())
    print(f"nightly attacker: {total} case(s) run across {len(category_counts)} categorie(s)")
    for category, count in sorted(category_counts.items()):
        print(f"  {category}: {count}")

    if breaches:
        print(f"BREACH: {len(breaches)} attack(s) got through the gate")
        for breach in breaches:
            print(f"  {breach}")
        return 1

    print("all attacks rejected: no git change, no out-of-jail write, no sandbox escape")
    return 0


if __name__ == "__main__":
    sys.exit(main())
