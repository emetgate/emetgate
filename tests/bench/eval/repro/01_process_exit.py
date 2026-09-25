import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import common

repo = common.make_repo("process-exit", {"a.js": "function add() { return 1; }\n"})
command = "node -e \"process.exit(0)\""
outside = common.run_outside_sandbox(repo, command)
inside = common.run_inside_sandbox(repo, "a.js", "add", command)
common.report("node -e process.exit(0)", outside, inside)
