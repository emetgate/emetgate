import argparse
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST_PATH = os.path.join(ROOT, "vendor", "MANIFEST.md")
VENDOR_DIR = os.path.join(ROOT, "vendor")

ROW_RE = re.compile(r"^\|\s*`([^`]+)`\s*\|.*\|\s*([A-Za-z0-9. ]+?)\s*\|[^|]*\|$")

LICENSE_PREFIXES = {
    "MIT": "MIT License",
}


def parse_entries():
    with open(MANIFEST_PATH, encoding="utf-8") as f:
        lines = f.readlines()
    entries = {}
    for line in lines:
        if not line.startswith("| `"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 6:
            continue
        directory = cells[0].strip("`")
        license_name = cells[4]
        entries[directory] = license_name
    return entries


def check():
    problems = []
    entries = parse_entries()
    if not entries:
        problems.append("no entries parsed from vendor/MANIFEST.md")

    actual_dirs = {
        name for name in os.listdir(VENDOR_DIR) if os.path.isdir(os.path.join(VENDOR_DIR, name))
    }

    for name in sorted(actual_dirs):
        if name not in entries:
            problems.append(f"vendor/{name} has no MANIFEST.md entry")

    for name in sorted(entries):
        if name not in actual_dirs:
            problems.append(f"MANIFEST.md lists {name}, but vendor/{name} does not exist")
            continue
        license_path = os.path.join(VENDOR_DIR, name, "LICENSE")
        if not os.path.isfile(license_path):
            problems.append(f"vendor/{name} has a MANIFEST.md entry but no LICENSE file")
            continue
        license_name = entries[name]
        expected_prefix = LICENSE_PREFIXES.get(license_name)
        if expected_prefix is None:
            problems.append(f"vendor/{name}: unrecognized license name {license_name!r} in MANIFEST.md")
            continue
        with open(license_path, encoding="utf-8", errors="replace") as f:
            head = f.read(200)
        if expected_prefix not in head:
            problems.append(f"vendor/{name}/LICENSE does not start with {expected_prefix!r} as MANIFEST.md claims")

    return problems


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    problems = check()
    if problems:
        for p in problems:
            print(p)
        sys.exit(1)
    print("vendor/MANIFEST.md matches vendor/ and each LICENSE file")


if __name__ == "__main__":
    main()
