import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import common

test_js = (
    "const http = require('http');\n"
    "const request = require('supertest');\n"
    "describe('probe', function () {\n"
    "  it('gets a response over a real socket', function (done) {\n"
    "    const server = http.createServer((req, res) => res.end('ok'));\n"
    "    request(server).get('/').expect(200, done);\n"
    "  });\n"
    "});\n"
)
repo = common.make_repo("mocha-supertest", {"a.js": "function add() { return 1; }\n", "probe.test.js": test_js})
node_modules_src = os.path.join(os.path.dirname(common.ROOT), "eval", "express-test", "node_modules")
node_modules_dst = os.path.join(repo, "node_modules")
common.run(["cmd", "/c", "mklink", "/J", node_modules_dst, node_modules_src])

command = "node_modules\\.bin\\mocha.cmd probe.test.js"
outside = common.run_outside_sandbox(repo, command, timeout_s=30)
inside = common.run_inside_sandbox(repo, "a.js", "add", command, timeout_s=90)
common.report("mocha + supertest, one test, real http socket", outside, inside)
if inside["parsed"]:
    print("inside outcome/reason:", inside["parsed"].get("outcome"), inside["parsed"].get("reason"), inside["parsed"].get("crash_code"))
    print("inside stdout tail:", (inside["parsed"].get("stdout") or "")[-800:])
    print("inside stderr tail:", (inside["parsed"].get("stderr") or "")[-800:])
