import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import common

package_json = "{\n  \"name\": \"repro\",\n  \"version\": \"1.0.0\",\n  \"scripts\": { \"test\": \"node test.js\" }\n}\n"
test_js = "console.log('running'); process.exit(0);\n"
repo = common.make_repo("npm-test-minimal", {"a.js": "function add() { return 1; }\n", "package.json": package_json, "test.js": test_js})
command = "npm test"
outside = common.run_outside_sandbox(repo, command)
inside = common.run_inside_sandbox(repo, "a.js", "add", command, timeout_s=90)
common.report("npm test (package.json script: node test.js)", outside, inside)
if inside["parsed"]:
    print("inside outcome/reason:", inside["parsed"].get("outcome"), inside["parsed"].get("reason"))
    print("inside stdout tail:", (inside["parsed"].get("stdout") or "")[-800:])
    print("inside stderr tail:", (inside["parsed"].get("stderr") or "")[-800:])
