import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(__file__))
import common
import low_integrity as li

EVAL_DIR = os.path.join(os.path.dirname(common.ROOT), "eval")


def fresh_dir(name):
    base = os.path.join(tempfile.gettempdir(), "emetgate-repro-" + name)
    if os.path.isdir(base):
        common.run(["cmd", "/c", "rmdir", "/s", "/q", base])
    os.makedirs(base)
    return base


def part1_read_through_hardlinks():
    src = os.path.join(EVAL_DIR, "express-test", "node_modules")
    dst_root = fresh_dir("hardlink-read")
    dst = os.path.join(dst_root, "node_modules")
    stats = common.build_hardlink_tree(src, dst)
    script = (
        "const fs = require('fs');\n"
        "const path = require('path');\n"
        "const dir = path.join(__dirname, 'node_modules');\n"
        "try {\n"
        "  const entries = fs.readdirSync(dir);\n"
        "  console.log('readdir OK', entries.length);\n"
        "} catch (e) { console.log('readdir FAILED', e.code); }\n"
        "try {\n"
        "  const real = fs.realpathSync(path.join(dir, 'mocha'));\n"
        "  console.log('realpath OK', real);\n"
        "} catch (e) { console.log('realpath FAILED', e.code); }\n"
        "try {\n"
        "  require.resolve(path.join(dir, 'mocha', 'package.json'));\n"
        "  console.log('require.resolve OK');\n"
        "} catch (e) { console.log('require.resolve FAILED', e.code); }\n"
        "process.exit(1);\n"
    )
    with open(os.path.join(dst_root, "probe.js"), "w", encoding="utf-8", newline="\n") as f:
        f.write(script)
    out_path = os.path.join(dst_root, "out.txt")
    res = li.run_low_integrity("node probe.js", dst_root, out_path)
    output = open(out_path, encoding="utf-8", errors="replace").read()
    print("=== part 1: read through a hardlink tree (node_modules-shaped) ===")
    print("tree build:", stats["file_count"], "files,", round(stats["elapsed_s"], 2), "s,", len(stats["link_failures"]), "failures,", len(stats["skipped_symlinks"]), "symlinks skipped")
    print("low-integrity run:", res)
    print(output)


def part2_write_denied():
    src = os.path.join(EVAL_DIR, "express-test", "node_modules", "mocha")
    dst_root = fresh_dir("hardlink-write")
    dst = os.path.join(dst_root, "mocha")
    stats = common.build_hardlink_tree(src, dst)
    target = os.path.join(dst, "package.json")
    original_hash_before = common.run(["certutil", "-hashfile", os.path.join(src, "package.json"), "SHA256"]).stdout
    script = (
        "const fs = require('fs');\n"
        "const target = process.argv[2];\n"
        "try {\n"
        "  fs.appendFileSync(target, '\\n// tampered');\n"
        "  console.log('write OK (unexpected)');\n"
        "} catch (e) { console.log('write FAILED', e.code); }\n"
        "process.exit(1);\n"
    )
    with open(os.path.join(dst_root, "probe.js"), "w", encoding="utf-8", newline="\n") as f:
        f.write(script)
    out_path = os.path.join(dst_root, "out.txt")
    res = li.run_low_integrity(f'node probe.js "{target}"', dst_root, out_path)
    output = open(out_path, encoding="utf-8", errors="replace").read()
    original_hash_after = common.run(["certutil", "-hashfile", os.path.join(src, "package.json"), "SHA256"]).stdout
    print("=== part 2: write to a hardlinked file must be denied ===")
    print("tree build:", stats["file_count"], "files")
    print("low-integrity run:", res)
    print(output)
    print("original file unchanged:", original_hash_before == original_hash_after)


def part3_delete_only_unlinks():
    src = os.path.join(EVAL_DIR, "express-test", "node_modules", "mocha")
    dst_root = fresh_dir("hardlink-delete")
    dst = os.path.join(dst_root, "mocha")
    common.build_hardlink_tree(src, dst)
    target_link = os.path.join(dst, "package.json")
    target_original = os.path.join(src, "package.json")
    existed_before = os.path.isfile(target_original)
    os.remove(target_link)
    existed_after = os.path.isfile(target_original)
    link_gone = not os.path.isfile(target_link)
    print("=== part 3: deleting the shadow's hardlink only removes the link ===")
    print("original existed before:", existed_before, "after:", existed_after, "link removed:", link_gone)


def part4_real_express_test():
    express_root = os.path.join(EVAL_DIR, "express-test")
    dst_root = fresh_dir("hardlink-express-run")
    for name in ("lib", "test", "examples", "index.js", "package.json", "History.md"):
        src = os.path.join(express_root, name)
        dst = os.path.join(dst_root, name)
        if os.path.isdir(src):
            shutil.copytree(src, dst)
        else:
            shutil.copy2(src, dst)
    stats = common.build_hardlink_tree(os.path.join(express_root, "node_modules"), os.path.join(dst_root, "node_modules"))
    out_path = os.path.join(dst_root, "out.txt")
    res = li.run_low_integrity("npm test", dst_root, out_path, timeout_ms=60000)
    output = open(out_path, encoding="utf-8", errors="replace").read()
    print("=== part 4: real express npm test against a hardlinked node_modules ===")
    print("tree build:", stats["file_count"], "files,", round(stats["elapsed_s"], 2), "s,", len(stats["link_failures"]), "failures,", len(stats["skipped_symlinks"]), "symlinks skipped")
    print("low-integrity run:", res)
    print(output[-2000:].encode("ascii", "replace").decode("ascii"))


def part5_tree_build_timing():
    print("=== part 5: hardlink tree build timing ===")
    for repo_name in ("express-test", "eslint-test"):
        src = os.path.join(EVAL_DIR, repo_name, "node_modules")
        if not os.path.isdir(src):
            print(repo_name, "node_modules missing, skipped")
            continue
        dst_root = fresh_dir("hardlink-timing-" + repo_name)
        stats = common.build_hardlink_tree(src, os.path.join(dst_root, "node_modules"))
        print(repo_name, stats["file_count"], "files,", round(stats["elapsed_s"], 2), "s,", len(stats["link_failures"]), "failures,", len(stats["skipped_symlinks"]), "symlinks skipped")


if __name__ == "__main__":
    part1_read_through_hardlinks()
    part2_write_denied()
    part3_delete_only_unlinks()
    part5_tree_build_timing()
    part4_real_express_test()
