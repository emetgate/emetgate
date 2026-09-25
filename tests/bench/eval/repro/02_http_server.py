import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import common

server_script = (
    "const http = require('http');\n"
    "const s = http.createServer((req, res) => res.end('ok'));\n"
    "s.listen(0, '127.0.0.1', () => { s.close(() => process.exit(0)); });\n"
)
repo = common.make_repo("http-server", {"a.js": "function add() { return 1; }\n", "server.js": server_script})
command = "node server.js"
outside = common.run_outside_sandbox(repo, command)
inside = common.run_inside_sandbox(repo, "a.js", "add", command)
common.report("node http.createServer listen+close", outside, inside)
