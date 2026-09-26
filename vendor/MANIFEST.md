# Vendored source manifest

Every directory under `vendor/` is a plain file copy, not a git submodule, so
there is no `.git` metadata in this tree to recover an upstream commit from.
This file records what is known for each one and is checked for staleness by
`tools/vendor_manifest.py --check` (also run by `tools/accept.ps1`): every
`vendor/*` directory must have an entry here, every entry's directory must
exist, and every entry's `license_file` must exist and start with the text
named in `license`.

| Directory | Upstream repository | Version | Upstream commit | License | Vendored in emetgate at |
|---|---|---|---|---|---|
| `tree-sitter` | https://github.com/tree-sitter/tree-sitter | v0.27.0 | not recorded | MIT | `61721f2` (2026-09-11) |
| `tree-sitter-typescript` | https://github.com/tree-sitter/tree-sitter-typescript | v0.23.2 | not recorded | MIT | `61721f2` (2026-09-11), tsx added `42ccaa3` (2026-09-24) |
| `tree-sitter-javascript` | https://github.com/tree-sitter/tree-sitter-javascript | not recorded | not recorded | MIT | `ce006aa` (2026-09-15) |
| `tree-sitter-json` | https://github.com/tree-sitter/tree-sitter-json | 0.24.8 | not recorded | MIT | `9ef9828` (2026-09-25) |
| `tree-sitter-markdown` | https://github.com/tree-sitter-grammars/tree-sitter-markdown | not recorded | not recorded | MIT | `b5bb2ba` (2026-09-25) |
| `tree-sitter-zig` | https://github.com/tree-sitter-grammars/tree-sitter-zig | not recorded | not recorded | MIT | `42ccaa3` (2026-09-24) |

"Version" and "upstream commit" are filled in only where the commit message
that first added the directory stated one; nobody pinned an exact upstream
commit hash at vendoring time for any of these, so that column is honest
about being unrecorded rather than guessed. `tree-sitter-markdown` and
`tree-sitter-zig` are grammars published under the community
`tree-sitter-grammars` GitHub organization, not the official `tree-sitter`
one; the other four are official.

Going forward, vendoring a new or updated grammar should record the exact
upstream commit hash (`git ls-remote <repo> <tag-or-branch>` at copy time) in
this table, not just a version tag, so this "not recorded" gap does not grow.
