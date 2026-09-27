import os
import shutil
import subprocess
import sys
import tempfile

BENCH = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(BENCH))
ESLINT = os.environ.get("EMETGATE_ESLINT") or os.path.join(ROOT, "..", "eval", "eslint-test")
ITERATIONS = int(os.environ.get("CHANGE_WATCH_ITERATIONS", "1000"))

HEADER = """\
Change watch benchmark: the sync barrier against a stat of every tracked file
Methodology:
- The watcher (src/platform/change_watch.zig) is built ReleaseFast with `zig build-exe`
  from tests/bench/change_watch_bench.zig; timings are wall clock inside that process.
- "sync, nothing changed": one barrier with an empty dirty set (cookie create, wait for
  its event, cookie delete, hand over the set).
- "sync, one file written before it": the write itself is not timed; the sync must
  report that file or the run stops.
- "stat scan": one stat (open + query) of every file `git ls-files` lists, the check a
  search does today to find changed files; two untimed rounds first, so the copy is
  past the first antivirus scan and the cache is warm.
- Fixtures: an empty directory, and a copy of eval/eslint-test (its 2362 tracked files)
  in a temporary directory, so the barrier's cookie never lands in the shared copy.
- Reproduce: `python tests/bench/change_watch.py` (needs zig on PATH)."""


def build(out_dir):
    exe = os.path.join(out_dir, "change_watch_bench.exe")
    subprocess.run([
        "zig", "build-exe", "-OReleaseFast",
        "--dep", "change_watch",
        "-Mroot=" + os.path.join(BENCH, "change_watch_bench.zig"),
        "-Mchange_watch=" + os.path.join(ROOT, "src", "platform", "change_watch.zig"),
        "-femit-bin=" + exe,
    ], check=True, cwd=out_dir)
    return exe


def copy_tracked(source, target):
    listed = subprocess.run(["git", "ls-files", "-z"], cwd=source, check=True, capture_output=True).stdout
    files = [f for f in listed.decode("utf-8").split("\0") if f]
    for rel in files:
        dest = os.path.join(target, rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        shutil.copyfile(os.path.join(source, rel), dest)
    listing = os.path.join(target, "..", "files.txt")
    with open(listing, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(files))
    return os.path.abspath(listing)


def run(argv):
    done = subprocess.run(argv, capture_output=True, text=True)
    print(done.stdout + done.stderr, end="")
    if done.returncode != 0:
        raise SystemExit(f"benchmark failed with exit code {done.returncode}")


def main():
    print(HEADER)
    work = tempfile.mkdtemp(prefix="emetgate-watch-")
    try:
        exe = build(work)
        empty = os.path.join(work, "empty")
        os.makedirs(empty)
        print("\nfixture: empty directory")
        run([exe, empty, str(ITERATIONS)])
        if os.path.isdir(ESLINT):
            copy = os.path.join(work, "eslint")
            os.makedirs(copy)
            listing = copy_tracked(ESLINT, copy)
            print("\nfixture: eslint copy")
            run([exe, copy, str(ITERATIONS), listing])
        else:
            print(f"\neslint copy not found at {ESLINT}; set EMETGATE_ESLINT")
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
