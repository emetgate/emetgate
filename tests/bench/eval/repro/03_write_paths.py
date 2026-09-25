import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import common

script = (
    "const fs = require('fs');\n"
    "const path = require('path');\n"
    "const targets = {\n"
    "  TEMP: process.env.TEMP,\n"
    "  TMP: process.env.TMP,\n"
    "  LOCALAPPDATA: process.env.LOCALAPPDATA,\n"
    "  APPDATA: process.env.APPDATA,\n"
    "  USERPROFILE: process.env.USERPROFILE,\n"
    "  os_tmpdir: require('os').tmpdir(),\n"
    "  cwd: process.cwd(),\n"
    "};\n"
    "for (const [name, dir] of Object.entries(targets)) {\n"
    "  if (!dir) { console.log(name, 'unset'); continue; }\n"
    "  const file = path.join(dir, 'emetgate-repro-probe.txt');\n"
    "  try {\n"
    "    fs.writeFileSync(file, 'ok');\n"
    "    fs.unlinkSync(file);\n"
    "    console.log(name, dir, 'write OK');\n"
    "  } catch (err) {\n"
    "    console.log(name, dir, 'write FAILED', err.code);\n"
    "  }\n"
    "}\n"
    "process.exit(1);\n"
)
repo = common.make_repo("write-paths", {"a.js": "function add() { return 1; }\n", "probe.js": script})
command = "node probe.js"
outside = common.run_outside_sandbox(repo, command)
inside = common.run_inside_sandbox(repo, "a.js", "add", command)
common.report("write probe to TEMP/LOCALAPPDATA/APPDATA/USERPROFILE/os.tmpdir/cwd", outside, inside)
print("outside stdout:\n", outside["stdout_tail"])
if inside["parsed"]:
    print("inside stdout:\n", inside["parsed"].get("stdout"))
