import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from run import is_breach


def mutant_ignore_git_status(clean, outside_changed, marker_exists):
    return outside_changed or marker_exists


def mutant_ignore_outside_file(clean, outside_changed, marker_exists):
    return (not clean) or marker_exists


def mutant_ignore_breach_marker(clean, outside_changed, marker_exists):
    return (not clean) or outside_changed


def expect(condition, message):
    if not condition:
        print(f"FAIL: {message}")
        return False
    return True


def main():
    ok = True

    ok &= expect(is_breach(True, False, False) is False, "a clean repo with nothing else changed is not a breach")
    ok &= expect(is_breach(False, False, False) is True, "a dirty repo alone is a breach")
    ok &= expect(is_breach(True, True, False) is True, "an outside-file change alone is a breach")
    ok &= expect(is_breach(True, False, True) is True, "a breach marker alone is a breach")

    ok &= expect(
        mutant_ignore_git_status(False, False, False) is False,
        "the git-status-skipping mutant misses a dirty repo (this is the bug it should catch)",
    )
    ok &= expect(
        mutant_ignore_outside_file(True, True, False) is False,
        "the outside-file-skipping mutant misses an out-of-jail write",
    )
    ok &= expect(
        mutant_ignore_breach_marker(True, False, True) is False,
        "the breach-marker-skipping mutant misses a sandbox escape",
    )

    if not ok:
        print("test_harness: FAILED")
        return 1
    print("test_harness: all guard checks and their mutants behave as expected")
    return 0


if __name__ == "__main__":
    sys.exit(main())
