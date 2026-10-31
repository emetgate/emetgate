import argparse
import collections
import os
import sys


def read_manifest(path):
    selected = []
    ran = []
    with open(path, encoding="utf-8") as f:
        for number, raw in enumerate(f, 1):
            line = raw.rstrip("\r\n")
            if not line:
                continue
            kind, sep, name = line.partition("\t")
            if not sep or not name or kind not in ("all", "ran"):
                raise ValueError(f"{path}:{number}: not an 'all' or 'ran' line: {line!r}")
            (selected if kind == "all" else ran).append(name)
    return selected, ran


def check(directory, count):
    errors = []
    found = sorted(name for name in os.listdir(directory) if os.path.isfile(os.path.join(directory, name)))
    expected = [f"part-{i}.{ext}" for i in range(1, count + 1) for ext in ("tsv", "passed")]
    for name in expected:
        if name not in found:
            what = "manifest" if name.endswith(".tsv") else "pass marker, so that part failed or did not finish"
            errors.append(f"{name} is missing: no {what}")
    for name in found:
        if name not in expected:
            errors.append(f"{name} is not a part {count} parts write")
    if errors:
        return errors, 0
    paths = [os.path.join(directory, f"part-{i}.tsv") for i in range(1, count + 1)]
    manifests = {}
    for path in paths:
        try:
            manifests[path] = read_manifest(path)
        except (OSError, UnicodeDecodeError, ValueError) as err:
            errors.append(str(err))
    if errors:
        return errors, 0
    first_path = paths[0]
    selected = manifests[first_path][0]
    if not selected:
        errors.append(f"{first_path} selects no test")
    if len(set(selected)) != len(selected):
        errors.append(f"{first_path} lists a selected test twice")
    for path in paths[1:]:
        if manifests[path][0] != selected:
            errors.append(f"{path} selects other tests than {first_path}")
    if errors:
        return errors, 0
    runs = collections.Counter()
    for path in paths:
        runs.update(manifests[path][1])
    wanted = set(selected)
    for name in selected:
        if runs[name] == 0:
            errors.append(f"no part ran {name}")
        elif runs[name] > 1:
            errors.append(f"{runs[name]} parts ran {name}")
    for name in sorted(set(runs) - wanted):
        errors.append(f"a part ran {name}, which is not selected")
    return errors, len(selected)


def main():
    parser = argparse.ArgumentParser(description="Check that the test parts together ran every selected test exactly once")
    parser.add_argument("--count", type=int, required=True)
    parser.add_argument("dir")
    args = parser.parse_args()
    errors, total = check(args.dir, args.count)
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    if errors:
        return 1
    print(f"{args.count} parts ran each of the {total} selected tests exactly once")
    return 0


if __name__ == "__main__":
    sys.exit(main())
