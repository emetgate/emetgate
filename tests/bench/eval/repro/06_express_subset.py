import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import common

express_test = os.path.join(os.path.dirname(common.ROOT), "eval", "express-test")
repo = common.make_repo("express-subset", {"a.js": "function add() { return 1; }\n"})
for name in ("node_modules", "lib", "test", "package.json"):
    src = os.path.join(express_test, name)
    dst = os.path.join(repo, name)
    common.run(["cmd", "/c", "mklink", "/J" if os.path.isdir(src) else "/H", dst, src])

command = "node_modules\\.bin\\mocha.cmd --require test/support/env --reporter spec test/res.send.js"
outside = common.run_outside_sandbox(repo, command, timeout_s=30)
inside = common.run_inside_sandbox(repo, "a.js", "add", command, timeout_s=90)
common.report("mocha test/res.send.js only (real express lib+tests, junctioned)", outside, inside)
if inside["parsed"]:
    print("inside outcome/reason:", inside["parsed"].get("outcome"), inside["parsed"].get("reason"), inside["parsed"].get("crash_code"))
    print("inside stdout tail:", (inside["parsed"].get("stdout") or "")[-1500:])
    print("inside stderr tail:", (inside["parsed"].get("stderr") or "")[-1500:])
