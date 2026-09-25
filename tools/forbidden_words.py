import argparse
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

CHECKED_FILES = ["README.md", "SECURITY.md", "VERIFICATION.md"]

FORBIDDEN = [
    "robust", "seamless", "seamlessly", "crucial", "leverage", "leveraging",
    "ensure", "ensures", "ensuring", "enhance", "enhances", "enhancing",
    "flawless", "flawlessly", "bulletproof", "never fails", "never fail",
    "100% secure", "100% safe", "zero bugs", "bug-free", "state-of-the-art",
    "cutting-edge", "cutting edge", "effortless", "effortlessly",
    "battle-tested", "battle tested", "world-class", "best-in-class",
    "guaranteed to never", "absolutely guaranteed", "100% guaranteed",
    "unbreakable", "impossible to break", "completely secure", "fully secure",
]


def find_violations(text):
    lower = text.lower()
    hits = []
    for word in FORBIDDEN:
        for match in re.finditer(re.escape(word), lower):
            line = text.count("\n", 0, match.start()) + 1
            hits.append((word, line))
    return hits


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    all_hits = []
    for name in CHECKED_FILES:
        path = os.path.join(ROOT, name)
        if not os.path.exists(path):
            continue
        with open(path, encoding="utf-8") as f:
            text = f.read()
        for word, line in find_violations(text):
            all_hits.append((name, line, word))

    if all_hits:
        for name, line, word in all_hits:
            print(f"{name}:{line}: forbidden word/phrase: {word!r}")
        sys.exit(1)

    print("no forbidden marketing words found in " + ", ".join(CHECKED_FILES))


if __name__ == "__main__":
    main()
