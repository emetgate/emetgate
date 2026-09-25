import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import common

target = os.path.join(os.path.dirname(common.ROOT), "eval", "express-test", "node_modules")
script = (
    "const fs = require('fs');\n"
    "const path = require('path');\n"
    "const link = path.join(process.cwd(), 'linked_modules');\n"
    "console.log('exists (fs.existsSync):', fs.existsSync(link));\n"
    "try {\n"
    "  const entries = fs.readdirSync(link);\n"
    "  console.log('readdir OK, entries:', entries.length);\n"
    "} catch (err) {\n"
    "  console.log('readdir FAILED', err.code, err.message);\n"
    "}\n"
    "try {\n"
    "  const real = fs.realpathSync(link);\n"
    "  console.log('realpath OK:', real);\n"
    "} catch (err) {\n"
    "  console.log('realpath FAILED', err.code, err.message);\n"
    "}\n"
    "try {\n"
    "  require.resolve(path.join(link, 'mocha', 'package.json'));\n"
    "  console.log('require.resolve OK');\n"
    "} catch (err) {\n"
    "  console.log('require.resolve FAILED', err.code, err.message);\n"
    "}\n"
    "process.exit(1);\n"
)
repo = common.make_repo("junction-traversal", {"a.js": "function add() { return 1; }\n", "probe.js": script})
common.run(["cmd", "/c", "mklink", "/J", os.path.join(repo, "linked_modules"), target])

command = "node probe.js"
outside = common.run_outside_sandbox(repo, command, timeout_s=20)
inside = common.run_inside_sandbox(repo, "a.js", "add", command, timeout_s=30)
common.report("fs.existsSync/readdir/realpath/require.resolve through a junction (matches shadow's node_modules link)", outside, inside)
print("outside stdout:\n", outside["stdout_tail"])
if inside["parsed"]:
    print("inside stdout:\n", inside["parsed"].get("stdout"))
    print("inside stderr:\n", inside["parsed"].get("stderr"))
