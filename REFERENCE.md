# Emetgate reference

The full description of every tool, check, limit and measurement. The short version is [README.md](README.md).

## The name

The name comes from the legend of the Golem of Prague. The word **אמת** (*emet*, "truth") animates the golem; removing its first letter leaves **מת** (*met*, "dead"). Emetgate uses the name for the boundary it puts between generated code and the source tree: a proposed change must pass deterministic checks before it is written.

## Why this exists

LLM-generated code has several recurring failure modes:

- The code compiles and is still wrong.
- The model reports a task as done when it is not.
- A rule stated three turns ago is silently forgotten.
- A plan agreed at the start of a session has evaporated by the end of it.

These problems require checks outside the model. Emetgate puts a deterministic verification layer between the model and the source tree. The model proposes changes; the kernel decides whether they can be written.

## Core principle

> **The model proposes. The kernel verifies.**

- The model can read code and propose a change to a symbol, but it cannot write files directly.
- The kernel checks each proposal structurally. If the change is not provably contained, it also runs the project's test command. The change is then committed atomically or rejected with a reason.
- The kernel is **fail-closed**: if a required check cannot complete, the proposal is rejected.

The design follows LCF-style theorem provers, where an untrusted component may suggest a result but only a small trusted kernel can accept it. Emetgate applies that separation to model-generated code changes.

## How a change moves through the gate

```
 model ──propose──▶ ┌──────────────────────────────── kernel ────────────────────────────────┐
                    │                                                                          │
                    │  1. address     symbol + content hash must match what is on disk         │
                    │  2. parse       new body is spliced by byte range and re-parsed          │
                    │  3. guard       no syntax errors, no escape from the body, no            │
                    │                 placeholders, nothing outside the span may change        │
                    │  4. bound       blast radius is computed: BOUNDED or UNBOUNDED           │
                    │  5. test        UNBOUNDED changes run the full test gate in a sandbox    │
                    │  6. commit      journaled, atomic write-rename, or reject with a reason  │
                    │                                                                          │
                    └──────────────────────────────────────────────────────────────────────────┘
                                          │                          │
                                     committed                   rejected
```

**Content addressing.** Every symbol is identified by a reference (`Class.method`, `add`) and a 128-bit hash of its current content. A proposal must name the hash it was based on. If the file changed in the meantime, the hash no longer matches and the proposal is rejected. The model cannot overwrite code it has not seen.

**AST-verified mutation.** A change replaces exactly one function body. The new body is spliced into the source by byte range and the whole file is re-parsed with tree-sitter. The kernel then checks that the result parses cleanly, that the body did not break out of its braces, that it is not an empty or placeholder body, and that every byte outside the target span is untouched.

**Boundedness.** Before running anything, the kernel computes whether the change can affect code beyond the symbol itself. The analysis is a positive, closed-world count: a change is `BOUNDED` only when every way it could escape has been ruled out, and the verdict carries its provenance. Anything the analysis cannot account for is `UNBOUNDED`.

**Test gate.** `UNBOUNDED` changes are applied to a shadow copy and the project's test command is run against it inside a sandbox (a Windows Job Object with kill-on-close, wall-clock and memory limits, and an output cap). The command runs under a low-integrity restricted token, so a body proposed by the model cannot write anywhere outside the shadow copy; if that token cannot be built and verified, the command is refused rather than run unconfined. If the tests fail, the change is rejected and the output is returned to the model. A command that exits but leaves a process behind in the job fails too (`leftover_processes`). After the exit the sandbox reads the pipes to EOF and waits for the job to empty, for up to 2 s and never past the command's deadline; the exited command's own console host is not counted. Whatever is still running after that is killed and reported. When the sandbox kills a job, on a leftover, a timeout or the output limit, it returns only after every killed process has exited, so none of them still holds a file in the shadow copy.

**Where the shadow copy lives.** The shadow copy is built outside the repository, in `%LOCALAPPDATA%\emetgate\shadow\<key>\shadow`, where `<key>` is a hash of the repository root's absolute path, so two repositories never share one and nothing is added to the working tree. The operator can move it with `--shadow-root <dir>` on `try`, `mcp` and `recover`; the model cannot, and a tool call that names a shadow root is refused like one that names a test command. Before a shadow copy is built or removed, every directory from the shadow root down is checked for junctions and symlinks and refused if it has one. A shadow copy whose repository no longer exists is removed on the next run. Tracked files are copied. Linked directories (`node_modules`) are rebuilt as hardlink trees: real directories, one hardlink per file, so the low-integrity test command can read its dependencies but, because the files keep their own security descriptor, cannot write, truncate or change their attributes; deleting or renaming a link in the shadow copy leaves the real file alone. A file whose integrity label would let a low-integrity process write it is copied instead of linked, and so is a file on another volume from the shadow copy. Junctions and symlinks inside a linked directory are not followed. The result's `shadow` object gives the shadow root and how many files were linked, copied and skipped; `shadow_path_warning` is added when the shadow path has a segment starting with a dot, because some tools refuse to serve files from such paths (the `send` package behind express's `res.sendFile` answers 404). The journal and the batch commit record stay in `.emetgate/` inside the repository, next to the files they restore, so `emetgate recover` finds them without knowing where the shadow copy was.

**Durable commit.** Accepted changes go through a write-ahead journal and an atomic replace. Each batch writes one journal (format version 2) that lists every intent before any file changes; a changed file is first copied to a backup and then replaced in one rename, so its path always holds either the old file or the new one, never a torn write or a gap. The handle that checked the old content stays open, refusing other writers, until the replace. Journals written before version 2 are still read by `recover`. A batch from `emetgate_try_batch` commits as one: after a crash, `recover` leaves every file of the batch old or every file new. `recover` replays the journal and refuses anything it cannot prove: zero-byte files, entries that no longer re-parse, and malformed tags.

## Rules

A rule is written once, on the command line, and the ledger keeps it:

```
emetgate rule add "no networkidle waits" --check forbid:networkidle --enforce
emetgate rule add "no console.log" --check "cmd:npx eslint --rule no-console" --in src/ --enforce
emetgate rule add "no raw SQL" --check "cmd:scripts\no-raw-sql.cmd" --enforce
emetgate rule list
```

An `--enforce` rule runs at the edit gate: a proposal that violates it is rejected with
reason `rule_violation` before the tests are ever started. A rule without `--enforce` is
advisory — recorded and shown, never enforced. `--in` scopes a rule to a file, a directory
ending in `/`, or `file#symbol`; a rule out of scope for the file being edited does not run
at all.

### Predicates

`--check` names the predicate. Two kinds exist and the `cmd:` prefix decides which: a command, or a built-in check run in process.

| Form | Meaning |
|---|---|
| `no_comment`, `forbid:<text>`, `no_literal:<option>` | Built-in AST checks, run against the proposed body in memory |
| `q:<tree-sitter query>` | A tree-sitter query, run in process against the parsed file; see [The `q:` query predicate](#the-q-query-predicate) |
| `cmd:<command line>` | A command, run in the shadow copy inside the sandbox |

Anything without the `cmd:` prefix is looked up in the built-in registry. An unknown name
returns `UnknownCheck`; it is not interpreted as a shell command.

Every violation carries the rule id, the check, the file, `line` and `col` of its first
byte, and `end_line` and `end_col` of its end. `end_col` is the column just past the last
byte. Columns count bytes from 1; SARIF counts UTF-16 code units by default, so a column on a
line with non-ASCII text has to be converted before it goes into a SARIF file. The violation's
`text` is the node's text cut to its first 256 bytes, on a character boundary; the four
positions still span the whole node. A `cmd:` violation has no position and reports 0 for all
four.

A `cmd:` command is validated when the rule is added. Empty, blank and over-long commands
are refused, but the command is **not run** until a proposal is checked in a shadow copy.

A command runs through `cmd.exe /c`, so it must be something `cmd.exe` can start: a `.cmd`
or `.bat` script, an `.exe`, or an interpreter named explicitly (`cmd:node scripts/no-raw-sql.js`).
A POSIX script such as `./scripts/no-raw-sql.sh` does not run there: `cmd.exe` exits 1 on it,
which the gate would report as a violation on every proposal.

### What a command predicate is allowed to see

The command runs on the same path as the test gate: a Windows Job Object with kill-on-close,
the wall-clock and memory limits and the output cap, under a low-integrity restricted token.
If that token cannot be built or verified, the command is refused rather than run unconfined.
Its working directory is the **shadow copy**, not the real tree, so a command that writes,
deletes or rewrites files touches only the throwaway copy.

### Command outcomes

| Result | Meaning |
|---|---|
| exit code 0 | the rule is satisfied |
| non-zero exit, normal termination | **violation** — the command's stdout and stderr are returned to the model as the reason (subject to the output cap) |
| crash, timeout, output limit, leftover processes, program not found, sandbox unavailable | **not a verdict** — reason `rule_check_crashed`, with a `detail` naming which of them it was |

A crash does not count as a rule verdict. The proposal is refused, but the reported reason
distinguishes a rule violation from an execution failure. Because `cmd.exe /c` uses exit
code 1 both for a missing program and for ordinary command failures, the executable is
resolved against `PATH`, `PATHEXT`, the shadow working directory and the `cmd.exe` builtins
before it is spawned. If it cannot be resolved, the result is `command_not_found` rather
than a rule violation.

`emetgate scan` refuses a `cmd:` rule by name (`CommandCheckNotStatic`) instead of running
it: a scan reads the working tree and has no shadow copy to run anything in.

### What a command predicate costs

The following results were measured on the same machine and proposal using 30 interleaved,
paired runs (`python tests/bench/rule_command_cost.py`, as of 2026-09-23; not generated or checked in CI):

| | median | worst |
|---|---|---|
| proposal with no command rule | 203 ms | 278 ms |
| proposal with one `cmd:exit 0` rule | 265 ms | 285 ms |
| **added per proposal** (paired difference) | **62 ms** | **81 ms** |

These figures measure the kernel's overhead for starting one additional sandboxed process
in the shadow copy with a no-op command. They do not include the runtime of the command
configured after `cmd:`; for example, an `npx eslint` invocation adds its own runtime to
every proposal.

### The `q:` query predicate

`q:<query>` runs a tree-sitter query against the parsed file in the emetgate process.
Every node captured as `@violation` is a violation.

```
emetgate rule add "no eval" --check "q:((call_expression function: (identifier) @violation) (#eq? @violation \"eval\"))" --enforce
emetgate rule add "n11 does not read priceFloat" --check "q:([(identifier) (property_identifier)] @violation (#eq? @violation \"priceFloat\"))" --in src/scraper/n11.js --enforce
```

A comment and a string are nodes of their own, so `(identifier)` never matches a name that
only appears inside a comment. `forbid:` cannot make that distinction.

- **`@violation` is required.** Every pattern in the query must capture `@violation`. A query
  with a pattern that does not is refused with `QueryMissingViolation`, and the pattern is
  printed.
- **Scope.** At the edit gate only nodes that lie wholly inside the proposed body count. A node
  that starts or ends outside it is dropped, even when the body overlaps it. `scan` checks the
  whole file, or the symbol body with `--in file#symbol`.
- **Languages.** When the rule is added, the query is compiled against every language profile.
  It must compile for at least one, and `rule add` prints on stderr each language it does not
  compile for. At the gate the query is compiled against the edited file's language. If it does
  not compile there, the proposal is refused with `rule_check_crashed`, detail
  `query_not_for_language`. The rule is not skipped.
- **Captures.** A capture may not be repeated with `+` or `*` (`(_)+ @c`, `((_) @c)*`). A
  capture on a group or an alternation is refused too when a `+` or `*` sits at that group's own
  level (`((_)+) @c`, `[(a)+ (b)] @c`, `((b) (a)+) @c`): tree-sitter ties such a capture to the
  group's first step, a repeat can loop back to it, and the capture is recorded again on every
  pass. A repeat inside a node pattern of the group (`((call (arguments (_)+))) @c`) is allowed.
  On 20,000 lines of `a;` the refused `(program ((expression_statement)+) @violation)` had
  taken 41.6 s and its alternation form 65.7 s in a Debug build; both are now refused by name
  in under 0.2 s. A pattern may hold at most 8 captures; arguments of a predicate do not count. The query is
  refused with `QueryQuantifiedCapture` or `QueryTooManyCaptures` and the pattern is printed.
  `?` and a repeat that captures nothing (`(arguments (_)+)`) are allowed. The reason is work
  tree-sitter does inside its cursor that the operation budget cannot see: a repeated capture
  copies its capture list for every child, so 20,000 children took 4 to 6.5 s in a ReleaseSafe
  build (24 to 41 s in Debug), and one pattern with K captures grows about as K³ (231 captures
  over 2,000 children: 53.6 s, ReleaseSafe). `@violation` already yields one match per node, so
  a rule does not need either. A hand-edited ledger row that breaks a limit fails closed at the
  gate as `query_malformed`.

Predicates are evaluated by emetgate; tree-sitter only parses them.

| Predicate | Holds when |
|---|---|
| `#eq? @c "text"`, `#eq? @c @d` | the capture's text equals the string, or the other capture's text |
| `#not-eq?` | the same arguments, negated |
| `#any-of? @c "a" "b" ...` | the capture's text equals one of the strings |
| `#match? @c "regex"` | the regex matches somewhere in the capture's text |
| `#not-match?` | the same arguments, negated |

A capture name used twice in a pattern holds several nodes, and each must satisfy the
predicate. A capture under `?` that caught no node satisfies every predicate on it, as in
tree-sitter's Rust binding and in Neovim, so a query ported from either reports the same nodes:
`((call_expression arguments: (arguments . (identifier)? @a)) @violation (#eq? @a "x"))`
reports `f()` as well as `g(x)`. Leave out the `?` to require the node. Any other
predicate (`#is?`, `#lua-match?`, `#any-eq?` ...) is refused with `QueryUnknownPredicate`,
and any directive (`#set!`, `#select-adjacent!` ...) with `QueryDirective`, both naming it.

The regex is RE2 syntax run as a Thompson NFA: matching walks a set of states over the text,
never backtracks, and takes time linear in the text. It searches: `#match? @c "Api"` holds when
`Api` occurs anywhere in the capture's text; anchor with `^` and `$`, which mean the start and
end of the whole text (there is no multi-line mode). `\d \w \s` are ASCII only, as in RE2:
`\w` is `[0-9A-Za-z_]`, so it does not match `ş`. Supported: literals, `.` (any character but
a newline), `[...]` and `[^...]`, `\d \w \s \D \W \S`, `^` and `$`, `* + ?`, `|` and `( )`.
Anything else is refused with `RegexUnsupported` and its name: backreferences and named
backreferences, lookahead, lookbehind, named and non-capturing groups, comments `(?#...)`,
inline flags, lazy and possessive quantifiers, counted repetition `{n,m}` (escape a literal
brace as `\{`), word boundaries `\b`, `\<` and `\>`, text anchors `\A`, `\z`, `` \` `` and
`\'`, `\p{...}`, numeric escapes and POSIX classes. A pattern that is not valid UTF-8, or a
class shorthand used as a range end point (`[\d-z]`), is refused with `RegexSyntax`.

Numbers in this table are generated from the source constants they name by
`tools/readme_facts.py` and checked in CI; `python tools/readme_facts.py --check`
fails if a limit changes in code without this table changing too.

| Limit | Value |
|---|---|
| query text | <!-- generated:max_query_bytes -->4 KB<!-- /generated --> including `q:`, as for `cmd:` (`QueryTooLong`) |
| captures | at most <!-- generated:max_captures_per_pattern -->8<!-- /generated --> per pattern, none repeated with `+` or `*`, none on a group or alternation with `+` or `*` at its own level |
| operations per run | <!-- generated:query_operations -->20,000,000<!-- /generated -->, shared by the tree-sitter cursor (100 per progress callback and 100 per match), the regex (1 per state visited and 1 per probe into a character class) and the other predicates (1 per capture visited, also when the match is reported, and 1 plus the bytes compared for each comparison) |
| operations per `emetgate_scan` call | <!-- generated:max_scan_operations -->100,000,000<!-- /generated --> over all files; each file still gets at most 20,000,000 of it |
| in-progress matches | <!-- generated:query_match_limit -->1024<!-- /generated --> |
| tree depth times pattern depth | <!-- generated:max_depth_product -->6,000<!-- /generated --> (`query_depth_exceeded`); the tree depth is that of the deepest node the scope reaches, the pattern depth is how deeply the query's parentheses and brackets nest |

| Result | Meaning |
|---|---|
| a `@violation` node inside the scope | **violation**, reason `rule_violation` |
| operation budget spent, match limit passed, tree too deep for the query, query does not compile for the file's language, malformed query in a hand-edited ledger | **not a verdict**: reason `rule_check_crashed`, detail `query_budget_exceeded`, `query_match_limit_exceeded`, `query_depth_exceeded`, `call_budget_exceeded` (the `emetgate_scan` call budget ran out), `query_not_for_language` or `query_malformed` |

The cursor stops as soon as the budget runs out or the match limit is passed. When tree-sitter
drops an in-progress match past the limit, the result could be missing a violation, so it is
not used. `scan` lists such failures under `check_failures` and exits 38, also when it found
violations.

### What a query predicate costs

30 interleaved, paired proposals on the same machine, with and without one enforced
`q:` rule that runs a `#match?` (`python tests/bench/rule_query_cost.py`, as of 2026-09-23; not generated or checked in CI):

| | Debug build (`zig build`) | ReleaseSafe build |
|---|---|---|
| proposal with no `q:` rule, median / worst | 156 ms / 173 ms | 169 ms / 228 ms |
| proposal with one `q:` rule, median / worst | 203 ms / 234 ms | 171 ms / 204 ms |
| **added per proposal** (paired difference), median / worst | **46 ms / 76 ms** | **3.5 ms / 47 ms** |
| proposal whose `q:` rule spends the whole operation budget, median / worst | 525 ms / 581 ms | 134 ms / 135 ms |

The query is compiled against the file's grammar on every proposal and is not cached. The last
row is the ceiling the budget puts on one rule:
a 3,001-byte regex over a 20,000-character string, refused with `query_budget_exceeded`.
The ReleaseSafe worst case in the third row is noise from the process start; its best paired
difference was negative.

`python tests/bench/query_growth.py` runs `emetgate scan --check q:...` for 22 query shapes
(quantifiers, anchors, alternations, nesting, many captures, each predicate) over 6 source
shapes (wide statement lists, argument lists and arrays; deep `a + a + ...`, `a.b.b...` and
`f(f(...))` chains) at 2,000, 4,000, 8,000 and 16,000 elements, and flags every combination
that grows faster than n^1.35 (as of 2026-09-23; not generated or checked in CI). On a ReleaseSafe build, 123 of the 132 grow linearly. The
other 9 are all on a deep left-leaning chain (`a + a + ... + a` or `a.b.b...b`, 16,000 levels):
a pattern nested three levels deep (`(_ (_ (_) @violation))`, 10.9 s at 16,000), six levels
deep (past 30 s), or anchored to a last child (`(_ (_) @violation .)`, 3.9 s). That time is
spent inside tree-sitter's query cursor, where the operation budget and the match limit do not
reach. Two costs of emetgate's own that the run found are fixed: violations were placed by
rescanning the file from the start, and their text was copied whole, both n^2 on these inputs.

The depth limit answers the rest. Measured on a ReleaseSafe build over `a + a + ... + a`, with
`emetgate scan --check` on a file in the repository (as of 2026-09-23; not generated or checked in CI); `emetgate_scan` over MCP took the same
time within 25%. The times include the process start of about 0.2 s.

| query | 1,000 levels | 4,000 | 16,000 | 64,000 |
|---|---|---|---|---|
| `(call_expression) @violation` | 0.23 s | 0.24 s | 0.22 s | 0.39 s |
| `(_ (_ (_) @violation))` | 0.24 s | 1.4 s | 13.9 s | past 120 s |
| `(_ (_) @violation .)` | 0.23 s | 0.66 s | 5.4 s | past 120 s |

The depth of the query multiplies it. On 1,000 levels a pattern nested 6 deep took 0.61 s, 12
deep 1.7 s, 50 deep 19.6 s and 200 deep more than 60 s; a model can send any of them through
`emetgate_scan`. Across these runs the time follows the product of the two depths: 0.6 to 0.9 s
at 6,000 and 1.4 to 1.8 s at 12,000. A run whose tree depth times pattern depth passes 6,000 is
refused before the cursor starts, with `query_depth_exceeded`: a query of depth 1 may meet 6,000
levels, one of depth 3 2,000 and one of depth 6 1,000. The tree depth is counted with a
tree-sitter tree cursor, without recursion, only through the nodes that reach the scope, and the
count stops at the limit. With the limit, all four queries above (the three in the table and
the one nested 6 deep) are refused at 16,000 and 64,000 levels in 0.21 to 0.33 s, process start
included, through `scan` and through `emetgate_scan`, with a peak working set of 40 to 44 MB
at 64,000 levels.

The proposal itself also grows with depth before any rule runs: `emetgate mutate` took 0.33 s
on a body 4,000 levels deep and 6.3 s on one 16,000 levels deep (ReleaseSafe, no rules).

### Rules are readable by the model, never writable

`emetgate_skeleton` returns, beside the outline, every adopted rule that covers that file:
its id, its text, whether it is `enforce` or `advisory`, its predicate and its scope. The
model reads the rules before it writes a body, so it can obey them instead of proposing a
violation, getting rejected and trying again.

Rule management is available only from the command line. The model-facing tools cannot
adopt, change or remove a rule, or change an `enforce` rule to `advisory`. A test
(`red line: the served tool surface is exactly this list`) pins the served tool names and
fails if another tool is added. A second test verifies that the dispatcher rejects
rule-writing tool names.

### A ledger committed to the repository

The ledger lives in `.emetgate/ledger.ndjson`. If that file is tracked by git, it arrives with
a clone: its rules are the repository author's, not yours. Emetgate treats it like
`.emetgaterc.json` and does not run its commands until you opt in:

| Ledger | `cmd:` and `q:` rules | AST checks |
|---|---|---|
| untracked (written by `emetgate rule` on this machine) | run | enforced |
| tracked by git, no `--allow-repo-memory` | **never run**: a proposal a `cmd:` or `q:` rule covers is refused with `UntrustedRepoMemory` (exit code 37) | enforced |
| tracked by git, `try` or `mcp` started with `--allow-repo-memory` | run | enforced |

"Tracked" means `git ls-files` lists `.emetgate/ledger.ndjson`, or `.emetgate` itself (for
example as a symlink), under any spelling of case, since Windows opens `.EMETGATE/Ledger.ndjson`
as the same file. The refusal fails closed: the proposal is rejected with a named error, not
let through with the rule silently skipped. A `cmd:` or `q:` rule whose `--in` scope does not
cover the edit is not consulted, so it does not block. If git cannot answer, the proposal is
rejected.

A `q:` query runs in the emetgate process, and part of tree-sitter's work inside the query
cursor is not visible to the operation budget (see the capture limits above). The limits keep
the known cases small, but they are a guard for your own rules, not a proof about someone
else's, so a committed ledger's `q:` rules wait for the flag like its commands.

AST checks (`no_comment`, `forbid:`, `no_literal:`) from a tracked ledger stay enforced without
the flag. They execute nothing and cost time linear in the body: the most a hostile one can do
is refuse an edit, and every rule is visible in `emetgate_skeleton` and `emetgate rule list`.

`emetgate scan` follows the same rule for a tracked ledger. Without `--allow-repo-memory` it
does not run the ledger's `q:` rules; each one is listed by id, as a
`warning: rule <id> (<check>) not run: untrusted ledger` line in text and under
`untrusted_not_run` in `--json`, and the other rules are scanned as usual. The listing does not
change the exit code. A query the operator passes with `--check` runs without the flag.

`--allow-repo-memory` is a startup flag of `emetgate try`, `emetgate mcp` and `emetgate scan`. The model cannot
grant it: a tool call that carries `allow_repo_memory` is refused with `ModelSuppliedTestPolicy`
and runs nothing, and `tools/list` does not offer the argument. Review a shared ledger with
`emetgate rule list` before passing the flag.

## Architecture

```
src/
├── engine/      pure and deterministic, no I/O
│   ├── tree_sitter, loader, traversal, skeleton
│   ├── symbol, ref, functions        symbol table, references, content hashes
│   ├── cas                           AST-verified mutation and structural guards
│   └── boundedness                   closed-world blast-radius analysis
├── platform/    everything that touches the machine
│   ├── disk, commit_record           journal, atomic write, batch commit record, recovery
│   ├── sandbox                       Job Object isolation and resource limits
│   ├── shadow, repo, lockdown        shadow workspace, repo lock, locked-down launch
│   ├── runner, gate, batch           cas → boundedness → test gate
│   └── memory                        append-only decision ledger
└── protocol/    the MCP surface
    ├── server, handlers, wire        tools and typed results
    ├── policy, telemetry             repo-config and repo-ledger trust, event log
    └── read_tools, diagnostics       scoped reads, tsc diagnostics
```

The dependency direction is strict: `protocol → platform → engine`. The engine cannot import the platform. Everything that decides whether a change is valid is a pure function of its inputs, which is what makes it testable to the standard described below.

### MCP tools

| Tool | Purpose |
|---|---|
| `emetgate_symbols` | Symbols in a file, with references, positions and content hashes |
| `emetgate_skeleton` | Signatures and structure without bodies, plus every adopted rule that covers the file (read-only) |
| `emetgate_read_symbol` | The source of one symbol, several symbols at once, or a line range widened to the symbols it overlaps; a body over the read budget comes back folded (see Reader); with `nodes:true`, each declaration (or exactly the requested lines) with a node hash on every line that starts a node |
| `emetgate_mutate` | Verify a proposed body structurally and return the result without writing |
| `emetgate_try` | Verify, gate and commit a proposed body, or new text for one or more syntax nodes addressed by their hash |
| `emetgate_try_batch` | Several proposals as one unit |
| `emetgate_rename` | Rename a function, method, class, field, interface, type, enum or variable and every reference to it; the TypeScript language service proposes the locations, the kernel proves the result and commits it as one batch |
| `emetgate_move` | Move a top-level declaration to another file; the kernel derives and checks every import and commits source, target and users as one batch |
| `emetgate_move_file` | Move or rename a file and rewrite every relative import to and from it as one batch |
| `emetgate_write_doc` | Verify, gate and commit a hash-checked write to one node of a non-code file: a JSON pointer's value, a Markdown section or a text line range; can commit together with a code edit in `emetgate_try_batch` |
| `emetgate_read_file` | A JSON key tree or one pointer's value, a Markdown heading tree or one section, a line range of any other text file, or (with `raw:true`) the file verbatim or a line range of it, source files included; confined to the repository |
| `emetgate_list`, `emetgate_search` | Reads confined to the repository |
| `emetgate_scan` | Measure one check expression against the repository, optionally within a `where` scope; writes nothing |
| `emetgate_git` | Read-only `status`, `diff`, `log` or `show`, with a fixed argument list and safe overrides so nothing configured in the repository (pager, external diff, textconv, fsmonitor, a `clean`/`smudge` filter) can run; output is capped |
| `emetgate_run` | Run one command from the allowlist the user gave (`--allow-run`) in a shadow copy, under the test gate's sandbox; nothing reaches the working tree and output is capped |

**New symbols and new files.** A proposal with `"hash": "absent"` adds one top-level declaration (a function, class, interface, type alias, enum or a variable with one declarator): to the end of an existing file, or as the only content of a file that does not exist yet. `emetgate_try` and `emetgate_try_batch` both accept it, and in a batch it commits or rolls back together with the other edits. A new file is journaled as a create intent, placed with a rename that never replaces an existing path, and added to the git index after the commit point; if another process puts a file at that path before the commit, the batch is refused with `Conflict` and that file is kept. Recovery deletes an uncommitted new file only while it still has the journaled hash, and indexes a committed one. For each such edit the batch result carries `class` (`symmetry` or `unclassified`) and the evidence behind it: the file parses, the new name is mentioned nowhere else in the batch or the tracked files, the declaration has no top-level effect (no call, `new`, assignment or decorator outside a function), and, for a new file or an exported symbol, no other file mentions the module. The test gate still runs for every batch, whatever the class. Limits: the parent directory must already exist, one batch creates a path at most once and cannot also edit it, and the reference check is a whole-word text match, so it errs toward `unclassified`. If `git add` fails after the commit, the files stay on disk and the result is `WrittenButNotIndexed`.

**Deleting symbols and files.** A batch edit with `"op": "delete"` removes something. With `symbol` and `hash` it removes one top-level declaration and its line from a file that stays; the edit is refused with `TopLevelEffect` if the declaration runs code when the module loads, and with `SymbolReferenced` if something still uses the name. When the repository's TypeScript language service is available (see renaming below), it answers that question with `findReferences`: any reference outside the declaration, in a file the batch does not rewrite, refuses the delete; a file the batch rewrites is judged on its new text; and a string literal elsewhere that is exactly the name (`obj["name"]`) refuses it as possible dynamic access, since the language service cannot see that. A name that only a comment mentions no longer blocks the delete. Without the language service the text scan from before stays in force: the name must not be mentioned anywhere else in the batch, in the rest of its file or in the tracked files (or, for an exported symbol, the module in another file). Without `symbol` it deletes the whole file; `hash` is then required and must be the `file_hash` that `emetgate_read_file` or `emetgate_skeleton` reported for that file, so the model cannot delete a file whose content it has not seen or that changed since (`MissingFileHash`, `HashMismatch`). The file stays in place until the commit point, is then deleted through the handle that checked its content, and is removed from the git index. If recovery finds a committed deletion whose file has changed since, it leaves the file alone. The test gate runs on the tree without the file. Limits: while a batch holds a file it refuses other writers but lets another process rename or delete it, since the atomic replace needs delete sharing; such a rename is not detected until recovery checks hashes. A symlink or junction is never deleted (`ReparsePoint`), a declaration that shares its statement with another name (`const a = () => 1, b = () => 2`) cannot be removed alone, and members cannot be removed yet.

**Writing a node of a non-code file.** `emetgate_write_doc` takes `file`, `hash` and `content`, plus exactly one of `pointer` (a JSON pointer, e.g. `/dependencies/express`), `heading` (a Markdown section by its exact heading text) or the `line_start`/`line_end` pair (a plain text line range). `hash` is the content hash of the current node, from `emetgate_read_file`; a stale or wrong hash is refused (`HashMismatch`) before anything is parsed. The replacement is checked before it is written: a JSON value must itself parse as valid JSON, and after the splice the whole file is re-parsed and the same pointer must resolve back to exactly the bytes written, byte for byte, catching a value that reparses differently than it reads (for example, a trailing space a JSON number's span would not include); a Markdown replacement must itself start with a heading line of some level, and after the splice the edited section's node must end exactly where the replacement's own text ends — an unclosed code fence or HTML block in the replacement that swallows a later heading, or anything else that shifts where the section boundary falls, is refused (`DocSyntaxInvalid`) and nothing is written. A file over 1 MiB or one that looks binary is refused before it is parsed at all. The write runs through the same jailed path, shadow copy and test gate as `emetgate_try`, and commits through the same journaled atomic replace. In `emetgate_try_batch`, an edit with `"kind": "doc"` uses this same shape (`file`, `hash`, `content`, one selector) instead of `symbol`/`body`, and can commit alongside ordinary code edits in the same all-or-nothing batch, through the same journal and commit record.

**Editing one syntax node.** A body is often long and the change is one statement in it. `emetgate_read_symbol` with `nodes:true` returns the whole declaration with a short hash in front of every line that starts a syntax node (`3f9a0c1d2e4b|  if (x > limit) {`); the same works with `symbols` and with a `line_start`/`line_end` range, which is then not widened, so top-level code outside every symbol can be addressed too. `emetgate_try` then takes `file`, `node` (that hash, at least 12 hex characters) and `text` (the new source of just that node; an empty text deletes it), or `nodes: [{node, text}, ...]` for several nodes of one file in one call. `emetgate_try_batch` accepts the same shape as one of its edits.

- **Address.** The hash is BLAKE3 over the node's kind and exact text, with its own domain tag, so it names content: an edit elsewhere in the file leaves it valid, and a change to the node or anything inside it makes it stale (`HashMismatch`). A hash that matches two nodes is refused (`AmbiguousNode`); `read_symbol` prints no hash on a line whose node occurs twice, and the model then addresses the enclosing node. The printed prefix is the shortest one, from 12 characters up, that tells the node apart from every other node of the file. The alternative, a path such as `clamp#body/2/if/consequent`, shifts when a sibling is inserted before it; Unison's content addressing is the precedent for the choice.
- **Splice and proof.** Each text replaces its node's exact byte range and the file is reparsed. Two addressed nodes may not overlap (`OverlappingNodes`). Then both trees are walked in step: every node outside the replaced ranges must come back with the same kind, depth and span, shifted only by the length changes before it, and the new text must parse into whole nodes at the depth of the one it replaces. Anything else is `BodyEscape`: a text that closes the function and opens another, a comment or string that swallows or reshapes the neighbour after it, a text that turns one declarator into two. A syntax error is `MutationSyntaxInvalid`, and a node replaced by nothing but a placeholder comment is `PlaceholderBody`. The engine code has no language in it; the same primitive runs on the Zig profile.
- **What the gate sees.** Every symbol whose hash changed, and every replaced region that lies outside all symbols, goes through the rules as a unit, so a file-scoped `--enforce` rule still applies to a top-level statement. A node edit that removes a top-level function whose name is still mentioned anywhere in the repository is refused with `SymbolReferenced`, as `op: "delete"` is; the call site can go in the same call or batch. The typecheck and test commands run as for any write.
- **Reply.** `nodes` gives the new hash of every node each text parsed into, so the next edit to the same node needs no reread, and `symbols` lists each changed symbol with its new hash (or `deleted`). The receipt records the file and every changed symbol.

Limits: the address covers one file; a node whose text occurs twice can only be reached through an ancestor; moving code between nodes is two edits.

**Renaming symbols.** `emetgate_rename` takes `file`, `symbol`, `hash` and `new_name`; the model states the intent and nothing else. What can be renamed:

| Kind | Ref | Where the hash comes from |
|---|---|---|
| function, method, getter, setter, arrow or function bound to a name | `add`, `Class.method`, `Class.label@get` | `symbols` in `emetgate_symbols` |
| class, abstract class | `Repository` | `declarations` in `emetgate_symbols` and `emetgate_skeleton` |
| class field (not a function value) | `Repository.count`, `Repository.instances@static` | `declarations` |
| interface, type alias | `Clock`, `Handler` | `declarations` |
| enum and enum member | `Level`, `Level.Low` | `declarations` |
| top-level `const`, `let`, `var` (one name per declarator; destructuring is not listed) | `greeting` | `declarations` |

A declaration's hash covers its whole text and is domain-separated from function hashes, so the same text never has both hashes; function and method hashes are unchanged. Namespaces and nested declarations are not listed.

 The TypeScript language service proposes every location (`getRenameInfo`, `findRenameLocations`, without strings or comments), and the kernel accepts the proposal only if it can prove it:

- the kernel resolves names itself, file by file, and the proposal must agree with it (`ResolutionMismatch`, `IncompleteRename`, `MergedDeclaration`). A scope resolver built on the tree-sitter tree (a file-local form of scope graphs) records every declaration with its scope (block, function, module, type parameter list) and its namespace (value, type, or both for classes, enums and imports), and resolves every identifier to the nearest declaration in the same namespace. Every proposed use must resolve to a declaration that is also renamed, every use of a renamed declaration must be proposed, and declarations that merge (an interface and a class of one name, overloads) are renamed together or not at all. Property names (`this.x`, `obj.x`, method names) need types to resolve and are left to the service and the alpha hash;
- every location is an identifier leaf with the old name in a tracked TypeScript or JavaScript file inside the repository (`NotAnIdentifier`, `RenameOutsideRepo`); a location the service wants to expand, such as the shorthand `{ add }`, is refused (`ShorthandReference`);
- the new name is not already an identifier in any touched file (`NameTaken`), so nothing can be captured;
- every touched top-level statement and every symbol keeps its alpha hash (`AlphaMismatch`). The alpha hash walks the leaves and hashes each one's kind and text, except that a name is replaced by the index of the first leaf in the region that has the same name in the same namespace; type names, value names and property names are indexed separately, so renaming a type alias leaves a value of the same name alone. It is the same before and after exactly when the rename is a one-to-one change of names that keeps which leaves share a name: a missed occurrence next to a renamed one, a renamed use of a shadowing local whose declaration was left, or a capture all change it;
- no occurrence of the old name is left free (`IncompleteRename`): after the rename, every remaining identifier with the old name must still resolve to a declaration in its file; a tracked file that mentions the name but gets no location must resolve it the same way and must not import or re-export it;
- no touched or mentioning file has dynamic access that could reach the name (`DynamicReference`): a string that is exactly the name, `eval` or `new Function`, a `require` or `import()` with a computed argument, or a constructed property key (`obj["na" + "me"]`; for a method any non-literal key).

A rename that touches another file, or of a symbol that is exported (for a member, of its exported class or enum; types included), changes what other modules import and is refused with `InterfaceChangeNeedsApproval` unless the call passes `interface_change: true`. All touched files are written as one v2 journal batch, so a crash leaves all of them old or all new, and the typecheck and test commands still run first. The result reports `class: symmetry`, the `resolver` (`language_service` or `text`), the number of statements and symbols whose alpha hash was compared, and the old and new hash of every file.

The language service is the repository's own `node_modules/typescript`; a global install is never looked up, because its version may not match the code and it would be a second package to trust. It is started by the first rename or delete of an `emetgate mcp` session and kept for the rest of it. It runs `node` with a small host script built into the binary, not `tsserver.js`: tsserver loads the `plugins` a `tsconfig.json` lists and has no switch to turn that off, while the host script builds its own `LanguageService`, drops `compilerOptions.plugins` and never loads a plugin. The TypeScript package is still code from the repository, so the process runs in the same sandbox as the test command: a low-integrity token (it cannot write to the repository) inside its own job object. A request that gets no answer in 30 s kills the job; the next request starts a new process.

Without the language service (no `node_modules/typescript`, no `node`, a timeout or a crash) the rename falls back to a text path that accepts only the unambiguous case: a top-level function, class, interface, type, enum or variable that is not exported, whose name has exactly one declaration in its file (a type and a value of one name are refused), appears in no other tracked file and is used nowhere as a property name. Everything else is refused as `RenameUnresolved`, and the result names the reason the service was not used. An `export { Engine as Motor }` keeps its public name: only the local name changes. JSX tags (`<Panel>`, `</Panel>`) are identifiers and are renamed and checked like any use. Limits: a name used in a JSDoc type sits in a comment, so a rename the service proposes there is refused (`NotAnIdentifier`); `export default` of an anonymous class, namespaces and nested declarations cannot be renamed; the resolver does not model `with`, `eval` scopes or global script files, so a use it cannot resolve is refused; a missed reference in a file that never mentions the old name as an identifier (for example `x.method()` on a value of another type) is caught by the typecheck and the tests, not by the kernel; the language service is given the tracked files and the root `tsconfig.json` only.

**Moving a declaration.** `emetgate_move` takes `file`, `symbol`, `hash` and `target_file` (an existing file or a new one in an existing directory). The model writes no import; the kernel derives them:

- the moved statement (with its leading comment) is cut from the source and appended to the target byte for byte;
- its free names, found by the same scope resolver the rename uses, are imported in the target from the modules the source imported them from, with relative paths rewritten for the target's directory and the source's extension style (`./util` or `./util.js`); a name the source declares itself must be exported and is imported from the source (`import type` when only a type position uses a type);
- if the source still uses the name, it imports it from the target; every file that imported it from the source now imports it from the target, with the same alias and `type` marker; specifiers the move leaves unused in the source are removed, and an import that becomes empty stays as `import "./dep";` so module evaluation does not change;
- the users come from the kernel's own reading of every tracked file's imports, and the language service's `findReferences` must name exactly those files (`UnhandledReference` for a user the kernel cannot rewrite, such as a `require`, and `ResolutionMismatch` for one it does not report).

The kernel then proves the result on the new texts: the moved declaration has the same hash in the target (`ContentHashMismatch`), every other symbol and declaration of the source, the target and each user keeps its hash (`BodyChanged`), every use of the name and every free name of the moved code still resolves (`IncompleteMove`, `TargetCapture`), and no new import cycle runs through the target or the source (`ImportCycle`); a cycle is what would make a `const`, `let` or `class` read before its initialisation (the temporal dead zone), so refusing new cycles covers that case. Refused before any text is built: `export default` (`ExportDefault`), a statement that declares more than one name (`SharedStatement`), overloads or merged declarations (`MergedDeclaration`), a namespace import or a re-export of the name (`NamespaceImportUse`, `ReExported`), dynamic access (`DynamicReference`), a local dependency the source does not export (`SourceDependencyNotExported`), an unexported name the source still uses (`MoveNeedsExport`), a target that already binds the name or binds a free name of the moved code differently (`TargetNameTaken`, `TargetCapture`). A source or target with a module-level effect (a call, `new`, an assignment or an expression statement at the top level) or a `package.json` `sideEffects` entry that covers either file can change evaluation order: the move is refused (`ModuleSideEffect`, `DeclaredSideEffect`) unless `order_change` is true, and the result is then classed `spending` instead of `symmetry`. Moving an exported symbol needs `interface_change: true`. All files, the new target included (as a create intent), are one v2 journal batch, and the typecheck and test commands still run first.

Without the language service only a declaration that is not exported and whose name no other tracked file mentions is moved; anything else is `MoveUnresolved`. The kernel derives the imports itself instead of taking the language service's "Move to file" refactoring: its output depends on the TypeScript version and formatting settings, while the kernel's derivation is fixed and every line of it is checked above. Limits: CommonJS `require` users, re-exports, namespace imports and `export default` are refused rather than rewritten; tsconfig `paths` aliases are kept verbatim; the cycle check parses only the files the target and the source reach; a new target's directory must exist.

**Moving and renaming files.** `emetgate_move_file` takes `from`, `to` and `from_hash` (the whole-file hash). The target must not exist (`NoClobber`) and must stay inside the repository, outside `.git` and `.emetgate`, and not under a symlink or junction. The kernel rewrites every relative `import`, `export ... from` and bare `import "..."` that reaches the file, and the file's own relative imports for its new directory, keeping each specifier's extension style; a barrel (`./lib` resolving to `lib/index.ts`) is rewritten only when the path it resolves to moves. The language service's `getEditsForFileRename` must propose exactly the same edits, file, byte range and text (`ServiceMismatch` otherwise); on the development machine TypeScript 5.9.3 and the kernel agreed on the test repository. Without the language service only a file nothing imports is moved (`FileMoveUnresolved`). The proof: every symbol and declaration of every touched file keeps its hash, every rewritten specifier resolves to the intended file, no tracked file still imports the old path (`IncompleteMove`), and the moved file's imports reach the same files as before (`MovedImportBroken`). A `require` or `import()` whose literal path reaches the file, or a computed one in a file that mentions its name, cannot be rewritten and is refused (`DynamicPathUse`). A file that `package.json` (`main`, `module`, `types`, `exports`, `bin`, `browser`) or tsconfig `paths` names is part of the package's interface and needs `interface_change: true`. A rename that only changes letter case is refused (`CaseOnlyRename`): NTFS treats both names as one file, so a no-replace rename cannot place it, and a two-step rename through a third name would add an intent the journal protocol does not model.

On disk the move is the protocol's rename intent: the new content goes to a temp file next to the target and is placed with a rename that never replaces an existing file; the source stays until the commit record and is then deleted through the handle that verified its hash; missing directories are journaled as `created_dirs`, created top-down before the temps and, on rollback, removed bottom-up when they hold nothing but our temps. Every rename and delete is followed by a flush of its directory (`FlushFileBuffers` on a directory handle), so a crash never finds a rename that was reported but not durable; the crash tests also replay a crash right after a rename with the directory entry lost, and a crash in the middle of recovery. The git index is updated after the commit record: the target is added and the source removed. Paths longer than `MAX_PATH` are opened with the `\\?\` prefix, and git runs with `core.longpaths=true` for them.


`emetgate lockdown` starts Claude Code with only these tools available, so the model has no path to the disk other than the gate; with `emetgate_git` in that set, the model can now see what changed and why without a shell.

**Running allowed commands.** `emetgate_run` lets the model run the commands the user allowed, such as `npm test`, `npm run lint` or `zig build`, which lockdown otherwise leaves it no way to run. The allowlist comes only from the user: `emetgate mcp --allow-run "<command>"`, repeatable, and the `run` list of `.emetgaterc.json` when the server was started with `--allow-repo-config`. The model names a command by its exact text; a request that is not byte for byte one entry is refused with `not_allowed` and the allowlist, and nothing is added, joined or expanded. A request or an entry with a shell metacharacter (`&`, `|`, `<`, `>`, `^`, `%`, `!`, `;`, a backtick, `$`, `(`, `)` or a line break) is refused, and so is a call that names a policy field (`allow_run`, `test_cmd`, `typecheck_cmd`, `allow_repo_config`, `allow_repo_memory`, `shadow_root`). The command runs through the same code as the test gate: a fresh shadow copy with the hardlink tree for `node_modules`, `cmd.exe /d /c <command>` under the low-integrity token and job, the same 60 s timeout, 1 MiB output cap and leftover check; if the token cannot be built the call is refused with `sandbox_unavailable` and the command does not run. The shadow copy is deleted afterwards, so writes the command makes there are thrown away. The result gives `outcome` (`exited` with `exit_code`, `crashed` with `crash_code`, `timed_out` or `output_limit`), `killed_leftovers`, and the last 200 lines and 16 KiB of each stream with the number of lines left out. Out of scope in this version, and refused when `--allow-run` names them: installing dependencies (`npm install`, `npm ci`, `pnpm i`, `yarn add`, `pip install` and their aliases), because an install fetches packages, runs their install scripts and rewrites the linked `node_modules`, and `git commit` or `git push`.

The repository ships a Claude Code skill, `.claude/skills/md-audit/SKILL.md`, that audits a CLAUDE.md or AGENTS.md file: it sorts every instruction sentence into enforceable, waiting for a mechanism, unverifiable or belief, proposes a check and scope for the enforceable ones, measures each with `emetgate_scan` and reports, changing nothing. To use it in every project, copy the `md-audit` folder into `%USERPROFILE%\.claude\skills\` (`~/.claude/skills/` elsewhere).

### Lockdown

`emetgate lockdown [<claude args>...]` starts `claude` in the current directory with this argv in front of the user's arguments, and with `ENABLE_TOOL_SEARCH=false` added to its environment:

```
claude --tools "" --allowedTools "mcp__<server>__emetgate_symbols ... mcp__<server>__emetgate_mutate" --mcp-config <absolute .mcp.json> --strict-mcp-config
```

`--tools ""` leaves Claude Code no built-in tool: no shell, no file read or edit, no web access and no ToolSearch. `--strict-mcp-config` with the absolute path loads only the servers of that `.mcp.json`. A user argument that would change any of this (`--tools`, `--allowedTools`, `--allowed-tools`, `--mcp-config`, `--strict-mcp-config`, `--settings`, `--plugin-dir`, `--agents`, `--dangerously-skip-permissions`, `--allow-dangerously-skip-permissions`, alone or as `--flag=value`) is refused before anything starts.
`--permission-mode bypassPermissions` (also `--permission-mode=bypassPermissions`, in any letter case, though Claude Code 2.1.286 accepts only this spelling) is refused the same way, since it skips every permission check as `--dangerously-skip-permissions` does; the other modes (`acceptEdits`, `auto`, `manual`, `dontAsk`, `plan`) pass.

`--allowedTools` lists the emetgate tools that neither change the repository nor run a command, so Claude Code runs them without a permission check; in auto mode that check added 0.5 to 1.6 s to each call in the measurement below. The list comes from reading each handler:

| Tool | Why it is pre-allowed |
|---|---|
| `emetgate_symbols` | Loads one file through the repository jail and the in-memory tree cache and lists its symbols |
| `emetgate_skeleton` | Same load, plus a read of the rule ledger without taking its lock |
| `emetgate_read_symbol` | Same load; the session mirror lives in memory |
| `emetgate_read_file` | Reads one file inside the repository |
| `emetgate_list` | Runs `git ls-files` with a fixed argument list |
| `emetgate_search` | Reads tracked files; its only write is its own index cache under `%LOCALAPPDATA%\emetgate\index` |
| `emetgate_scan` | Measures one check in memory, writes nothing and does not read the ledger; a `cmd:` check is refused as not static, so no command runs |
| `emetgate_git` | Runs `status`, `diff`, `log` or `show` with a fixed argument list, `--no-optional-locks` and no pager, external diff, textconv or fsmonitor |
| `emetgate_mutate` | Builds the changed source in memory; it runs no command and writes nothing |

The other tools keep whatever permission mode the user chose: `emetgate_try`, `emetgate_try_batch` and `emetgate_write_doc` write files after the trusted test command passes, `emetgate_rename`, `emetgate_move` and `emetgate_move_file` write several files and run the TypeScript language service, and `emetgate_run` runs a command from the user's allowlist. Every call, pre-allowed or not, appends one line to `.emetgate/events.ndjson`, emetgate's own git-ignored log. A test in `tests/lockdown.zig` fails when the server gains a tool that is in neither list.

The server name comes from `.mcp.json`. Lockdown looks for the entry whose `command` is `emetgate` or `emetgate.exe` (any directory, any letter case) and whose first argument is `mcp` or `serve`, and turns its key into a tool name prefix the way Claude Code 2.1.286 does: every character outside `A-Z`, `a-z`, `0-9`, `_` and `-` becomes `_`, two of them for a character outside the Basic Multilingual Plane. The key `emetgate` gives `mcp__emetgate__emetgate_search`. With no such entry lockdown stops with `NoEmetgateServer`, with more than one with `SeveralEmetgateServers`, and with a file that is not a JSON object of servers with `McpConfigInvalid`; Claude Code is not started in any of these cases.

Measured on the n8n repository with Claude Code 2.1.286 and Opus, two `emetgate lockdown -p` sessions per launcher, on 2026-10-01. Both launchers used the same `.mcp.json` and so the same emetgate server binary:

| | Before (`--tools ToolSearch`) | After |
|---|---|---|
| Short read question: turns | 3, 3 | 2, 2 |
| Short read question: API time | 5.5 s, 6.5 s | 3.5 s, 3.9 s |
| Short read question: first request prompt | 18,514 tokens | 25,140 tokens |
| `emetgate_read_file`, `tool_use` to `tool_result` | 795 ms, 1,664 ms | 80 ms, 70 ms |
| Three searches in a row: turns | 5, 5 | 4, 4 |
| Three searches in a row: API time | 16.3 s, 19.7 s | 14.4 s, 16.3 s |
| Warm `emetgate_search`, `tool_use` to `tool_result` | 557, 698, 876, 588 ms | 69, 54, 60, 63 ms |

The lost turn is the ToolSearch round: with tool search on, Claude Code defers the MCP tool definitions and the model loads them first; with it off, the definitions are in the first request, which costs the extra 6,626 prompt tokens. The first search of a session builds the index in the server process and does not depend on the launcher: 76.0 s and 21.9 s before, 21.6 s and 21.5 s after.

`--tools ""` was chosen over `--tools ToolSearch`. With `ENABLE_TOOL_SEARCH=false` both gave the same 16 tools and the same 25,140-token first request in four sessions; with `--tools ""` and the variable unset, Claude Code still loaded the MCP tools up front in one session. So the model has one tool fewer, and turning tool search off does not depend on the variable alone.

### Reader

A 284-session measurement found that read tokens (`Read` plus shell `cat`/`sed`) were
about 57% of all tool-result tokens, three quarters of them a whole file, with a median
of 4.1K characters and a p90 of 22K. The read tools above are built to cut that:

- **Three levels for a source file of a registered language (TypeScript, JavaScript):**
  signatures (`emetgate_symbols`: ref, hash, line) → structure (`emetgate_skeleton`:
  every signature, bodies elided) → body (`emetgate_read_symbol`: one symbol, several at
  once, or a line range widened to the symbols it overlaps, each with its own hash). A
  raw whole-file read of such a file is refused by `emetgate_read_file`
  (`UseSymbolToolsForSource`) unless `raw:true` is passed explicitly; with `raw:true`,
  `line_start`/`line_end` return just those lines. A range that runs past the end of the
  file comes back with `status: partial` and the line the file ends at; an inverted range
  is `InvalidLineRange` and one that starts after the last line is `LineOutOfRange`.
- **Read budget for long bodies.** A body longer than the read budget (8,192 characters,
  `emetgate mcp --read-budget <chars>` to change it) comes back with `status: partial`:
  the signature, an outline of its nested blocks (`if`, `for`, `try`, inner functions, each
  with a line range), and the body folded from the deepest blocks outwards until it fits,
  every elided range named in place as `… lines A-B elided (N lines); read them with
  line_start/line_end` and listed under `elided`. If folding every block is not enough, the
  tail is cut the same way. A line range inside such a declaration returns the requested
  lines with the rest named the same way. `detail:"full"` returns every line. Bodies within
  the budget come back exactly as before. On n8n, `WorkflowExecute.processRunExecutionData`
  (20 KB body) went from a 25,147-character reply to 10,708, and `addNodeToBeExecuted` from
  16,519 to 11,591; 4,096 also folded 6 to 8 KB bodies for little gain and 16,384 saved
  little on the largest one (measured through a direct MCP session on n8n on 2026-10-01).
- **JSON**: `emetgate_read_file` defaults to a key tree (every JSON pointer, its value
  type and content hash) instead of the raw text; `pointer` reads one subtree.
- **Markdown**: `emetgate_read_file` defaults to a heading tree (heading, level, line,
  hash); `heading` reads one section, including its nested subsections.
- **Any other text file**: `line_start`/`line_end` reads just that line range with its
  own hash, the `cat`/`sed -n` replacement; without them the file is returned whole, up
  to 16 KiB.
- **Session mirror (opt-in, `emetgate mcp --mirror`).** The server remembers, in
  process memory only, the content hash of every unit (file, JSON pointer, Markdown
  heading or symbol) it has already sent this session. A repeat request for an
  unchanged unit gets back one line (`{"status":"unchanged", "hash": ...}`) instead of
  the full content; a request for `force:true` always gets the full content again, and
  every `unchanged` reply repeats that as a hint. Off by default: see Limits below for
  why.

Measured with `tests/bench/reader.py` (o200k_base tokens; reproduce with
`python tests/bench/reader.py`, a built `emetgate` binary, and, for the two real-project
rows, a local checkout of a second real repository — the exact numbers drift with both
codebases, the ratios are the signal):

| Scenario | Read | emetgate | ratio |
|---|---:|---:|---:|
| find + read a function in a 1.6k-line real file | 13313 | 2819 | 0.21x |
| read one key in a 50 KB real `package-lock.json` | 19859 | 319 | 0.02x |
| read one section of this repo's own README.md | 15432 | 1541 | 0.10x |
| read the same symbol a second time, `--mirror` on | 13313 | 84 | 0.01x |
| reread the same symbol after it changed, `--mirror` on | 18 | 74 | 4.11x |
| line range 10-15 of `build.zig` | 151 | 34 | 0.23x |

The `package-lock.json` row used to cost 2.23x a plain read: the default key tree walked
every nested key of every one of hundreds of packages. It now lists only the root's
direct children, with a `children` count on any object or array instead of recursing
into it; a pointer read (the second step counted above) still returns a full subtree
when the model asks for one.

One row is still worse than a plain read, left in on purpose: a hash-carrying JSON reply
on a genuinely tiny symbol costs more than the few bytes it wraps (a fixed 32-hex-char
hash plus the `file`/`symbol` JSON wrapper). Shrinking it further means accepting a
short hash prefix in `emetgate_try`, which touches the CAS engine's hash-equality check
on the write path; that change was judged too invasive to make safely in this pass, so
the physical lower bound is reported instead of hidden. Locating a symbol or a
JSON/Markdown node is not free either; both locate and fetch steps are counted above,
matching how `tests/bench/run4.py` counts a symbol edit's ingest side.

The tiny-symbol reread row above uses a synthetic two-line file, which understates the
wrapper's real cost relative to a plausible model action: a model that already has a real
file open would re-read either the whole file or, at best, just the changed function's
line range (if it somehow already knew that range without re-reading). Measured against
the same edit in the real 1.6k-line `affiliate-scraper/src/index.js`:

| Scenario | Read (full file) | Read (best-case line range) | emetgate |
|---|---:|---:|---:|
| reread a small changed symbol, `--mirror` on | 13323 | 218 | 328 |

Against the full file this is still a 41x win (13323 vs 328). Against the best case a
model cannot actually reach without having read the file first, emetgate costs 1.5x more
(218 vs 328) — a fixed cost (32-hex-char hash plus the `file`/`symbol` JSON wrapper) on
top of content that is already only a couple hundred tokens. This is the row's physical
floor: shrinking the wrapper further would need a shorter hash than `emetgate_try` accepts
today, which was judged out of scope for this pass (see the reader's remaining limits).

**Limits.** Claude Code can summarize (compact) its own context; the mirror only knows
what it sent, not whether the model still has it. An `unchanged` reply after compaction
is telling the model "you already have this" when it may not — the wrong direction to
get wrong, which is why `force:true` exists and every `unchanged` reply advertises it.
This branch does not wire an automatic reset on compaction: `src/platform/lockdown.zig`
only launches Claude Code with a fixed argv and one environment variable today and does not
manage `.claude/settings.json` or hooks, and a `PreCompact` hook would need to reach a
mirror that lives in a specific running MCP process's memory. Until that lands, the
mirror stays **off by default**; a project that opts in with `--mirror` is accepting
that a compaction mid-session can make one `unchanged` reply stale.

### Writer

`tests/bench/write_flow.py` compares whole edit flows. The built-in side follows Claude Code's rules: `Edit` needs a prior `Read` of the file (whole file, `cat -n` form), `old_string` is the changed lines, and when they occur more than once the call fails and is retried with one more line of context on each side, the failed call and its error included. The emetgate side is real MCP calls against a git copy of the file: `emetgate_read_symbol` with `nodes:true`, then one `emetgate_try` with node hashes and new texts; the file on disk is compared with the intended result after both flows. Tokens are o200k_base, counted two ways on both sides: bare (tool name, JSON arguments, returned text) and block (the `tool_use` and `tool_result` content blocks serialized as the Messages API holds them). The MCP JSON-RPC frame is transport and reaches neither context, so it is left out on both sides, as are tool schemas. ms is the wall clock of the calls: for emetgate the MCP round trip, which includes the shadow copy, the sandboxed test command (a no-op here) and the journal; for the built-in side the same file work done in-process in Python, a lower bound for Claude Code's tools, which run no test. "floor" is built-in tokens over emetgate's arguments alone, the best any reply format could reach.

Fixtures: express (`eval/express-test`, MIT) and a 1.6k-line file of a second real project (`affiliate-scraper/src/index.js`, read-only, copied per scenario). Run on 2026-09-27 with a ReleaseFast build, after `feat/compact-write-reply` shrank the default `emetgate_try`/`emetgate_try_batch`/`emetgate_write_doc` success reply to status plus the new hashes:

| Fixture | Scenario | Built-in bare | Emetgate bare | Ratio | Built-in block | Emetgate block | Ratio | Floor | Turns b/e | Failed b/e | ms b/e |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| express | one line in a large function | 10419 | 1248 | 8.35x | 13340 | 1551 | 8.60x | 128.63x | 2/2 | 0/0 | 31/235 |
| express | one line whose text occurs three times | 10505 | 1260 | 8.34x | 13506 | 1563 | 8.64x | 114.18x | 3/2 | 1/0 | 21/236 |
| express | replace an if block | 2518 | 720 | 3.50x | 3348 | 924 | 3.62x | 22.28x | 2/2 | 0/0 | 20/182 |
| express | replace a small function whole | 2476 | 306 | 8.09x | 3306 | 463 | 7.14x | 23.81x | 2/2 | 0/0 | 2/189 |
| express | delete a function and its one call site | 5981 | 358 | 16.71x | 7818 | 589 | 13.27x | 58.07x | 3/3 | 0/0 | 37/280 |
| express | two edits in one file | 10479 | 1311 | 7.99x | 13473 | 1618 | 8.33x | 102.74x | 3/2 | 0/0 | 46/246 |
| express | one line, file already read | 101 | 165 | 0.61x | 174 | 245 | 0.71x | 1.80x | 1/1 | 0/0 | 19/171 |
| affiliate | one line in a large function | 19359 | 1755 | 11.03x | 24646 | 2145 | 11.49x | 333.78x | 2/2 | 0/0 | 24/292 |
| affiliate | replace an if block | 19416 | 1801 | 10.78x | 24703 | 2191 | 11.27x | 188.50x | 2/2 | 0/0 | 20/257 |
| affiliate | replace a small function whole | 19447 | 344 | 56.53x | 24734 | 502 | 49.27x | 156.83x | 2/2 | 0/0 | 20/279 |
| affiliate | delete a function and its one call site | 19574 | 603 | 32.46x | 24934 | 810 | 30.78x | 244.68x | 3/2 | 0/0 | 40/315 |
| affiliate | two edits in one file | 19453 | 1821 | 10.68x | 24813 | 2213 | 11.21x | 170.64x | 3/2 | 0/0 | 49/278 |
| affiliate | one line, file already read | 66 | 113 | 0.58x | 139 | 191 | 0.73x | 1.94x | 1/1 | 0/0 | 20/205 |

Before/after for the two rows the compact reply targets, same fixtures and floor (built-in unchanged):

| Fixture | Scenario | Emetgate bare before | Emetgate bare after | Ratio before | Ratio after |
|---|---|---:|---:|---:|---:|
| express | one line, file already read | 258 | 165 | 0.39x | 0.61x |
| affiliate | one line, file already read | 206 | 113 | 0.32x | 0.58x |

What the numbers do not show, and where emetgate is behind:

- **File already read.** Both rows are still under 1x. `Edit` then sends the changed line and gets one line back (19 tokens); a compact `emetgate_try` reply is now `{"status":"committed","file":...,"nodes":[[...]],"symbols":[{"symbol":...,"new_hash":...}]}`, the new node hash plus the changed symbol's new hash and nothing else — the shadow copy summary, receipt ids and old hash moved behind `detail:"full"`. That reply is 79 to 109 tokens where it used to carry the always-on shadow note and receipt fields at 172 to 202 tokens. Even a reply of zero tokens would leave 1.8x and 1.9x, because emetgate's arguments alone (56 and 34 tokens) are more than a third of the whole built-in call (101 and 66); the two "already read" rows sit at that acknowledged ceiling, not at 3x.
- **Turns.** Each flow is one read and one write on both sides, so turns are equal except where `Edit` has to retry or makes one call per place; emetgate then saves one turn. A 3x turn ratio is not reachable with a read-then-write flow.
- **Time.** An emetgate edit takes 200 to 420 ms, a `read_symbol` about 60 ms of it; the rest is the gate: the shadow copy, starting the test command under the low-integrity token and job, and the journaled commit. The built-in edit runs no test. Measured against a flow that also runs the tests, the gate would be compared with the test run itself.
- **Delete.** Every function in both fixtures is called somewhere, and emetgate refuses to delete a function whose name is still mentioned, so the delete scenario removes the call site in the same call. In express the call site sits in `app.handle = function ...`, which is not a symbol, so emetgate reads those two lines by range.
- **Other formats.** For the model's emitted edit alone, without the read each one needs: the whole file costs 1421 to 13444 tokens, a unified diff with 3 lines of context 49 to 220, SEARCH/REPLACE 21 to 238 (5338 and 6612 for the deletes, as one block has to span both places), the emetgate call 34 to 124.

## Receipts and `emetgate verify`

Every commit the gate makes (`emetgate_try`, `emetgate_try_batch` including creations and deletions, `emetgate_rename`, `emetgate_move`, `emetgate_move_file`) leaves a receipt, so the change can be checked later without trusting Emetgate, the model or the log. A receipt is an [in-toto](https://in-toto.io) Statement v1: `subject` lists every file the commit wrote with its `blake3-128` and `sha256` digests, `predicateType` is `https://emetgate.dev/receipt/v1`, and the predicate records:

| Field | Content |
|---|---|
| `operation`, `class`, `evidence` | the tool, `symmetry` or `spending`, and what proves it (`test`, `alpha_hash`, `content_hash`, `unreferenced`) |
| `files` | every touched path with its whole-file digest before and after (`null` for absent) |
| `symbols` | every symbol or declaration the operation changed, created or removed, with its hash before and after |
| `checks` | the typecheck and test commands that passed, their `blake3-128` digest, exit code and duration |
| `rules` | the id and digest of every adopted rule that covers a touched file |
| `sandbox`, `emetgate` | the sandbox limits and the Emetgate version |

The JSON is canonical ([RFC 8785](https://www.rfc-editor.org/rfc/rfc8785), keys sorted by UTF-16 code units, integers only), so its `sha256` is the receipt's id and the same receipt always has the same bytes. Receipts are not signed yet; the format is the one Sigstore/cosign sign and a transparency log such as Rekor records, so signing adds a signature over these bytes and changes none of them.

**Storage.** Emetgate does not commit. A receipt is written to `.emetgate/receipts/` when the gate commits the files; after the user commits, `emetgate receipts attach [<commit>]` puts every pending receipt whose files that commit changed into a git note on it (`refs/notes/emetgate`, one canonical JSON array), in the order the gate wrote them. Notes were chosen over a trailer or a working-tree key: they attach to the commit without changing its hash, survive a rebase only when the user carries them, and are not fetched by a plain clone, so a cloned repository brings no receipts unless someone fetches `refs/notes/emetgate` on purpose. `.emetgate/` is outside every tool's reach (`InternalPath`), so the model cannot write a receipt. A receipt is still only a claim: `verify` recomputes every digest and never runs anything a receipt names (the PR #31 lesson: a command from the repository is untrusted); it reruns only the test and typecheck commands the person running `verify` passes, and only when their digest equals the one in the receipt.

**`emetgate verify <commit> [--test <cmd>] [--typecheck <cmd>] [--skip-tests] [--json]`** reads the commit, its first parent and the note, and replays the receipts in order over the parent's files:

- every receipt's `before` digests must match the parent or the previous receipt, its `after` digests its subjects, and the last receipt for a file the commit's content; a note that is not canonical JSON, an added or reordered receipt and an edited digest are all `mismatch`;
- every listed symbol hash is recomputed from the file content before and after;
- a `spending` receipt is `verified` only when the trusted test command, rerun in the sandbox on a worktree of the commit, passes (`mismatch` when it fails, `unverified` when it was not rerun or was a different command);
- a `symmetry` receipt is checked without running anything: a rename by the alpha hash of every top-level statement, a move or file move by the multiset of symbol and declaration hashes of the touched files, a creation or deletion by the other symbols keeping their hashes and the name appearing in no other file of the commit;
- a rule whose digest changed is `mismatch`, one that left the ledger is `unverified`;
- a file the commit changed that no receipt covers, or that was edited by hand after the gate, is `unverified`.

Each file and receipt is reported as `verified`, `unverified` or `mismatch`; the exit code is 0 only when everything is verified (53 for unverified, 54 for mismatch), so "not measured" is never reported green. In CI, `emetgate verify HEAD --test "<the project's test command>"` after `git fetch origin refs/notes/emetgate:refs/notes/emetgate` can run as a status check; that step is documented here, not shipped.

**The checker's size.** The decision logic is `src/verify/` (canonical JSON, the receipt format and the checker). It parses with tree-sitter and hashes, and imports no code that writes, no journal, no sandbox and no protocol code; a test (`verify tcb`) fails the build if it ever does. Git access and the test rerun live in `src/platform/verify_run.zig`, outside the checker. What the checker trusts: <!-- generated:verifier-tcb -->2,635 non-blank lines of Zig in 23 files, 727 of them in the 3 files of `src/verify/`<!-- /generated -->, plus the tree-sitter C runtime and grammars and the Zig standard library. A second checker, written in Python from the format above and not from the Zig code, lives in `tools/verify_py/` (<!-- generated:python-checker-size -->383 non-blank lines of Python, plus 298 in the vendored BLAKE3<!-- /generated -->): `python tools/verify_py/emetgate_verify.py <commit> [--repo <dir>] [--json]`, with the same verdicts, exit codes and JSON shape, plus one more verdict, `consistent` (exit code 55). It uses only the standard library, `git`, and the pure Python BLAKE3 by one of BLAKE3's authors (`vendor/pure_python_blake3`, CC0), which a test checks against BLAKE3's official test vectors; its RFC 8785 canonicalizer is its own. It checks the note's canonical form, the receipt format, the subject digests (`blake3-128` and `sha256`) against the commit's blobs, the `before`/`after` chain, the last `after` against the commit, the command digests and exit codes, and the changes no receipt covers. Symbol hashes, alpha hashes, the test rerun and rule digests need tree-sitter, a sandbox or the ledger format, so it lists them as `not_checked` and never counts them as verified. The Python checker is independent but partial: `consistent` means that everything it checks holds and that the fields in `not_checked` were not checked; it does not mean verified, and it reports `verified` only when `not_checked` is empty. Every scenario in `tests/verify_receipts.zig` runs both checkers and fails when they disagree on anything the Python checker checks (N-version), so it runs in `zig build test`, in `tools/accept.ps1` and in CI. Limits: a file touched by two receipts in one commit has an intermediate state that the commit does not contain, so the checks that need it report `unverified`; receipts are written for the MCP tools, not for the `emetgate try` CLI; receipts are not signed.

### Search

`emetgate_search` (`src/protocol/search_v1.zig`) finds a literal substring or, with
`regex:true`, a regular expression (`src/engine/regex.zig`) in git-tracked text files.
Unlike a flat grep, hits are grouped so a result can go straight into `emetgate_try` or
`emetgate_read_symbol` without a second lookup:

- In a registered language, hits are grouped by their **enclosing symbol** (ref + content
  hash), and each hit is tagged **code** / **comment** / **string** from the tree-sitter
  node at the match (`profile.isComment`, `profile.strings` — data-driven per language,
  the engine itself names no language). A hit that names a known symbol is further tagged
  **definition** (inside the symbol's own signature, matching its name) or **reference**
  (the callee of a call expression, per `profile.call`, or a generic identifier-reference
  node kind). Groups with a definition hit sort first, so "where is X defined" resolves in
  the same reply as "where is X used."
- In a `.json` file, hits are grouped by the JSON pointer of the value they fall in
  (`json_pointer.pointerAt`); in a `.md` file, by the innermost heading whose section
  contains them (`markdown_heading.sectionAt`). Any other tracked text file is ungrouped
  (line only).
- `kinds:["code"]` (etc.) filters the kind tag before the hit cap is applied; a kind name
  other than `code`, `comment` or `string` is refused (`UnknownKind`). At most 200 hits
  total, `truncated:true` when cut, matching `emetgate_scan`'s cap style.
- `dir` may name a file: the search then covers that one tracked file
  (`scope.is_file:true`).

Every reply says whether it is **complete** or **partial** and what it covered. `scope`
counts the tracked files under `dir` (`files`), how many of them were fully evaluated
(`evaluated`), and the ones left out by a declared rule (`skipped_large` for 1 MiB or more,
`skipped_binary`, `deleted_on_disk`). A reply is `partial` when the hit cap cut it or a
file could not be fully evaluated: an unreadable file, or a line on which the regex ran
past its step budget (2,000,000 steps per line); `missing` names those files and why. A
reply with no hit carries a `note` that says why the zero can be trusted or what did not
fit: `no match in 157 file(s)`, `7 matching line(s) (0 code, 0 comment, 7 string) were all
removed by kinds [code]`, `<path> is not a file git tracks`, or, for a literal that looks
like a regex, a pointer to `regex:true`. A literal with a `|` whose whole text is not found
is searched once more as the literal alternatives between the bars, and the reply says so
(`read_as:"literal alternatives"`): a model that writes `a(|b` without `regex:true` gets
the hits for `a(` and `b`. Errors (a path outside the repository, a bad regex) are the
refused answers.

Example reply shape:

```json
{"status":"complete","pattern":"loadPending","regex":false,
 "scope":{"path":"src","files":42,"evaluated":42},"matched_files":3,
 "groups":[{"file":"src/index.js","symbol":"loadPending","hash":"…",
            "hits":[{"line":93,"kind":"code","role":"definition","text":"function loadPending() {"},
                     {"line":112,"kind":"code","role":"reference","text":"loadPending();"}]}],
 "truncated":false}
```

**Candidate file index.** Each tracked file has an entry: its mtime and size stamp, its
sorted set of 3-byte grams, its content hash, and the spans a hit is classified from (for a
registered language the symbols, comment and string ranges and reference ranges from
`kind_spans`; for `.json` every value's pointer and range, for `.md` every section's
heading and range, from `doc_spans`). A file is a candidate only when its grams are a
superset of the query's grams; a file with no entry is always a candidate, so the index can
only skip files that cannot match. A candidate is read from disk, and its stored spans are
used only when the content hash of the bytes just read equals the entry's; otherwise the
file is parsed live, so a stale entry can cost time but never a wrong kind, symbol, pointer
or heading.

**On disk.** The index is saved at
`%LOCALAPPDATA%\emetgate\index\<repo-path-hash>\index.v2` (the same hashed-path
convention as the shadow root, so a repository is never written into and a poisoned clone
cannot carry a poisoned index) in a versioned, length-prefixed binary format
(`search_index_file.zig`): the `git ls-files` list with the git index file's stamp, then
every entry with its stamp, content hash, grams and spans, and a BLAKE3 checksum of all of
it at the end. A file with another magic or version, a bad checksum or a cut tail is
ignored and the index is built again; text in it is never escaped, only counted. It is
written when a session first builds it and when a session that changed it ends.

**Freshness.** Inside `emetgate mcp` the index, the file list, a change watcher
(`src/platform/change_watch.zig`) and a thread pool live for the session
(`search_session.zig`). The watcher starts with the session, before the saved index is
loaded. The first search of a session then checks every tracked file against the loaded
index: it lists each directory once (`FindFirstFileExW`, no file is opened), and re-reads
a file whose last-write time or size differs, or whose last-write time falls within 3 s of
when its entry was read (git's racy rule: a second write in the same instant as the read
can keep the stamp). Every entry carries that read time, whether it was built in this
process, refreshed, or loaded (then the save time stands in), and saving gives a racy entry
an impossible stamp, as git smudges a racily clean index entry, so the next session reads
that file again; every other entry is used as loaded. The file list is reused while the git index
file keeps its last-write time, size and file id: git replaces the file on every write
(a lock file renamed over it), so a new file id marks a change even within the same
timestamp, and no waiting period is needed. Every search first calls
the watcher's barrier (`sync`, 250 ms budget): it creates a cookie file under
`.emetgate/cookies/` and waits until the watcher reports it; NTFS reports changes to one
directory handle in order, so every change that finished before the call is in the dirty
set by then. Only the dirty files are read and re-indexed. When the git index file
changes (a `git add`, a commit, a checkout), the tracked paths are read from it directly
(`git_index.zig`: index versions 2 to 4, checked against the file's own SHA-1 or SHA-256
trailer; a split or sparse index, or any file that does not check out, falls back to
`git ls-files`), the paths that are new get an entry, and the dirty files are handled as
usual, with no full refresh. If the barrier overflows, times out or the watcher has stopped, the search falls
back to a full refresh that stats every tracked file and re-reads each one whose stamp
changed; nothing is reported clean on a failure. Outside a session (the CLI, tests without
one) every search lists the files and does that full refresh against the saved index. The
contract: a write whose handle was closed or flushed
before the search starts is in the result. **Limit:** a program that keeps a file open and
writes to it without closing or flushing is not reported by `ReadDirectoryChangesW` until it
does, and a stat can miss it too (NTFS updates the last-write time once per handle), so
such a write can be missing from a result until the writer closes the file. Editors, git,
package managers and emetgate itself close what they write.

**Sparse gram size — measured, not assumed.** GitHub's Blackbird search
(https://github.blog/2023-02-06-the-technology-behind-githubs-new-code-search/) uses
variable-length sparse grams, chosen by a trained weighting model, instead of fixed
trigrams; Zoekt (https://github.com/sourcegraph/zoekt) uses positional trigrams. This
project does not have Blackbird's trained model, so `tests/bench/gram_compare.py` measures
two real alternatives against trigram (n=3) on `eval/express-test` (215 files) and
`eval/eslint-test` (2362 files), five representative queries.

First, a fixed but longer gram (n=4, not itself a sparse scheme, just a cheap sanity check
on gram length):

| repo | n | distinct grams | candidates for 5 queries (of total files) |
|---|---:|---:|---|
| express-test | 3 | 20445 | 0, 15, 140, 133, 32 (of 213) |
| express-test | 4 | 47934 | 0, 15, 140, 133, 31 (of 213) |
| eslint-test | 3 | 68882 | 0, 44, 978, 733, 159 (of 2319) |
| eslint-test | 4 | 243210 | 0, 44, 978, 729, 159 (of 2319) |

n=4 costs 2.3-3.5x more distinct grams for candidate counts identical or within one file
of n=3. Second, a real sparse scheme: classical **winnowing**
(Schleimer, Wilkerson, Aiken, "Winnowing: Local Algorithms for Document Fingerprinting,"
2003) — hash every 5-byte k-gram, keep only the minimum-hash fingerprint in each window of
4 consecutive k-grams. Unlike a rarity-weighted selection (which cannot guarantee two
occurrences of the same string pick a shared fingerprint, and would silently break the
fail-closed contract), winnowing has a proven guarantee: any two occurrences of the same
string of at least `k+w-1` = 8 bytes select at least one common fingerprint, so it cannot
wrongly exclude a real match at or above that length; below it, this repo's index and this
script both fall back to a full scan, same as a query too short to trigram:

| repo | fingerprints (winnowing) | candidates for 5 queries: trigram vs winnowing (of total files) |
|---|---:|---|
| express-test | 35677 (vs 20445 trigram) | 0/0, 15/15, 140/140, 133/136, 32/31 |
| eslint-test | 264837 (vs 68882 trigram) | 0/0, 44/44, 978/1015, 733/914, 159/159 |

Winnowing's index is 1.7-3.8x bigger and 2-3x slower to build than trigram, and it never
narrows the candidate set further — on the two lowest-selectivity queries this benchmark
was chosen to stress (`function`: 978/2319, `require(`: 733/2319 with trigram) it is
strictly worse (1015 and 914). Winnowing is measured here as a documented alternative, not
as a stand-in for Blackbird: it is a *fingerprint-selection* scheme (which fixed-length
k-grams to keep), not the *variable-length sparse gram* Blackbird's post describes.

Third, that actual construction: Blackbird's post derives variable-length "features" from
byte-pair boundary weights, trained on real code. Without that trained model,
`gram_compare.py` reproduces the same boundary mechanism with an untrained proxy weight
(a hash of each byte pair): a substring `data[i:j]` (length 4-12) is indexed only when the
weight of both of its boundary byte-pairs exceeds the weight of every byte-pair strictly
between them, so boundaries fall on locally "rare" (high-hash) pairs the same way Blackbird's
trained rarity score would place them, just without the training. A query is checked against
the smallest set of its own sparse grams that covers it end to end (greedy interval cover),
matching the "cover the query, not just take one gram" approach the post describes:

| repo | distinct grams (sparse) | candidates for 5 queries: trigram vs sparse gram (of total files) |
|---|---:|---|
| express-test | 147131 (vs 20445 trigram) | 0/0, 15/15, 140/140, 133/133, 32/31 |
| eslint-test | 1254929 (vs 68882 trigram) | 0/0, 44/44, 978/979, 733/727, 159/159 |

This is the closer reproduction of Blackbird's actual mechanism, and it is roughly at parity
with trigram on 4 of 5 queries and marginally *better* on the one it was meant to help
(`require(`: 727 vs 733) — but its index is 7.2-18.2x bigger and 5.9-6.5x slower to build
than trigram's, because it stores a variable window of overlapping spans per position
instead of one fixed 3-byte gram, and the untrained hash-based weight does not concentrate
boundaries the way a trained rarity score would. **Trigram is kept**: neither winnowing nor this
boundary-weighted sparse gram won convincingly enough here to justify the larger, slower
index. This is a measurement on two repos, five queries, and one untrained weight function
— not a claim that a trained Blackbird-style model would not help; only that reproducing its
*mechanism* without its *training* did not, on this corpus. The reproduction command is in
the script if a different weight function or corpus is worth checking.

**Regex candidates.** Russ Cox's trigram-index regex matching
(https://swtch.com/~rsc/regexp/regexp4.html) derives the trigrams every match must contain,
alternation included, from the regex AST. This regex engine compiles straight to an NFA and
does not expose that AST, so `regex_hint.requiredLiterals` takes, for each branch of a
top-level alternation (also inside one group that encloses the whole pattern), the longest
literal run that every match of that branch must contain: text outside any group, with the
character before `?`, `*` or `{` left out. A match then holds at least one of those
literals; a branch with no literal (`foo|.*`) means no hint at all. A file is a candidate
when its grams cover the grams of one of the literals, a line is handed to the regex only
when it contains one, and the hit's kind and role are read at that literal's column. Each
line gets its own step budget, so one long line can make the reply partial but cannot hide
matches in other lines or files. An earlier version shared one budget per worker thread
across files and read a spent budget as no match; on n8n that returned 0 for
`handleNodeExecutionError|continueExecution` where `rg` finds 6.

Measured with `tests/bench/search.py` (ReleaseFast build, 10-run medians, run alone under
the lock script) against `rg` and `git grep` on `eval/express-test` and
`eval/eslint-test`: <!-- generated:search-summary -->a new session's first search 5.5 to 22.7 ms and later searches 1.9 to 10.1 ms, against rg 27.2 to 80.9 ms and git grep 29.1 to 65.7 ms; building the index the first time, once per repository, took 91 to 1,335 ms (2026-09-27, scan bandwidth 3.13 GB/s)<!-- /generated -->.
rg and git grep are timed as the process a tool call starts, since Claude Code's Grep starts
rg for every call; emetgate is timed as the MCP round trip of one call to a running server.
Cold is the first search of a new server with the index on disk, warm the second; both
include the barrier. Startup is that server's spawn and initialize round trip, which
includes starting the watcher and loading the index; it is paid once per session, when
Claude Code starts the server, not per search. Index build is the first search in a
repository with no saved index, once per repository. The floor is what a warm
search cannot avoid, measured in the same session: an MCP ping round trip, the barrier, the
candidate filter and one pass over the candidate bytes at the scan bandwidth `bytes.find`
reaches in memory. The `+edit` rows charge the built-in path for the `Read` Claude Code
requires before an `Edit`, in two versions: the whole file, and only the changed function's
lines (a best case the model cannot know without having read the file).
<!-- generated:search-table -->

| Scenario | rg ms | git grep ms | emetgate cold ms | emetgate warm ms | floor ms | startup ms | index build ms (one time) | rg tokens | emetgate tokens | turns rg/emetgate |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| an error message string | 28.1 | 34.8 | 6.2 | 3.1 | 0.72 | 50.8 | 91.2 | 315,999 | 267 | 1/1 |
| a term only in comments | 80.9 | 65.7 | 22.7 | 9.9 | 3.53 | 63.1 | 1335.3 | 29,371 | 7,668 | 1/1 |
| a JSON key value | 27.2 | 29.1 | 8.1 | 4.8 | 0.70 | 51.8 | 93.4 | 375,981 | 6,060 | 1/1 |
| a common short word | 33.3 | 35.9 | 11.4 | 6.5 | 0.75 | 68.7 | 116.9 | 414,187 | 6,088 | 1/1 |
| a regex pattern | 31.3 | 47.2 | 10.1 | 5.9 | 1.07 | 59.2 | 108.4 | 352,283 | 3,313 | 1/1 |
| tryRender usages (rg+Read full file) | 36.8 | 36.6 | 5.9 | 1.9 | 0.58 | 64.6 | 115.1 | 3,586 | 135 | 2/1 |
| tryRender usages (rg+Read best-case range) | 36.8 | 36.6 | 5.9 | 1.9 | 0.58 | 64.6 | 115.1 | 65 | 135 | 2/1 |
| logerror usages (rg+Read full file) | 28.4 | 37.9 | 5.5 | 2.1 | 0.59 | 52.8 | 98.4 | 3,647 | 130 | 2/1 |
| logerror usages (rg+Read best-case range) | 28.4 | 37.9 | 5.5 | 2.1 | 0.59 | 52.8 | 98.4 | 123 | 130 | 2/1 |
| search right after a committed write and a git commit | 32.0 | 29.2 | 13.6 | 10.1 | 0.50 | 49.7 | 377.9 | 15 | 103 | 1/1 |
<!-- /generated -->

Cold and warm search are faster than both rg and git grep in every scenario. Building
the index the first time is not: it reads, grams and parses every tracked file on up to 8
threads, about 0.1 s for express's 215 files and 1.3 s for eslint's 2362, once per
repository. Between warm and floor are the grouping and the JSON reply; on eslint the cold
search also re-reads the 43 files the index leaves out (binary or over 1 MiB) to see
whether they changed. Two `+edit` rows are at token
parity against the best-case range a model cannot reach without reading the file first:
ripgrep's output for a rare name is already near the minimum, and emetgate adds a fixed
grouping and hash wrapper. Against the whole-file `Read` both clear 3x by two orders of
magnitude.

**Limits:** no automatic index eviction (an index for a repo that is deleted or moved
stays on disk under its old path hash; harmless, since a rebuilt repo gets a fresh hash,
but it is never cleaned up); the regex engine's own feature set (no backreferences,
lookaround, or counted `{n,m}` repetition, see `src/engine/regex.zig`) bounds what
`regex:true` can express; definition/reference tagging is a heuristic over available
profile data (declaration span, call-site field), not a full tags.scm implementation, and
can miss less direct reference shapes (e.g. an identifier passed as a callback rather than
called directly stays untagged, not mistagged).

### Fact store

`emetgate facts` keeps the definitions, references, imports and exports of every
TypeScript and JavaScript file of the repository in one store and answers structural
questions from it without a model:

```
emetgate facts build
emetgate facts callers WorkflowExecute.processRunExecutionData
emetgate facts callees WorkflowExecute.processRunExecutionData --depth 2
emetgate facts refs C.m --file src/a.ts
emetgate facts defined_at handleNodeExecutionError
emetgate facts evidence --intent decides --target packages/core/src/execution-engine/workflow-execute.ts#WorkflowExecute.handleNodeExecutionError --term continueOnFail
emetgate facts bench --samples 200 --updates 50
```

The facts are `def(kind, name, qualified name, file, span, body hash, alpha hash)`,
`ref(from, target or unresolved(reason), file, line, kind: call | new | read | write | type | import)`,
containment through each definition's parent, and `imports(file, file | external)`. Names
resolve with `src/engine/scope.zig` and imports with `src/engine/modules.zig`: relative
paths, tsconfig `paths` and `baseUrl` (following `extends`), and workspace `package.json`
entries mapped from `outDir` to `rootDir` as the package's own tsconfig files declare them.
A member call binds through `this`, a class used statically, a namespace import, a declared
type, a constructor parameter property or a constant made with `new`. The last three are
labelled `typed`, the others `proven`. Everything else stays `unresolved` with its reason.

The store lives in `%LOCALAPPDATA%\emetgate\facts\<repo hash>\facts.v3`: versioned, with a
BLAKE3 checksum, written to a temporary file and moved into place. A refresh lists the
tracked files, compares directory stamps, re-reads only changed files (a file stamped within
2 s of the store's write time is always re-hashed), extracts a file again only when its
content hash changed, and relinks only the files whose links read a file whose exports or
definitions changed.

Answers use the answer algebra (`complete`, `partial`, `refused`) with a certificate over the
snapshot: an RFC 9162 Merkle root over each file's path and SHA-256. `callers` and `refs` are
`complete` only when nothing could bind to the subject without being resolved: no reference
with the subject's name on a receiver of unknown type anywhere, no dynamic-key call
(`obj[k](...)`, `eval`) in a file that reaches the subject's module through imports, and no
file that names the subject but was not analyzed (another language, syntax errors,
unreadable, over the size limit). Calls bind statically: a call on a receiver typed as the
base class is listed under the base member, not under its overrides.

`emetgate facts evidence` compiles the evidence for one request: targets in the order given
(`--target path#symbol`; several share the budget, none is dropped while another is shown
whole), an intent (`decides`, `callers`, `callees`, `flow`, `where_defined`, `explain`), terms,
and `--include callers,callees,tests|none` (all three by default, none for `where_defined`). The
block is plain text: a header line, then each file named once with its lines under it as
`line  code`, then the certificate line. A target is shown whole when it fits (default 9,500
characters, under the 10,000-character limit of a Claude Code hook); its body gets room before
callers and callees fill the rest. A body that does not fit is cut from a statement outline
kept in the store, so no file is parsed again: the complete statements around the lines that
hold a term or a call to another target, for `decides` the whole branch that holds a term, the
full signature and the headers of the blocks around them; every elided range is named and the
answer turns `partial`. Callers and callees are shown by signature and call line as `proven` or
`typed`; candidates that could not be resolved are listed and the `Partial because` line names
why. The tests section lists the `describe`/`it`/`test` titles of the test files (`*.test.*`,
`*.spec.*`, `__tests__`) that reference a target, resolved or by name in a test file that
imports the target's module, three per file and a count for the rest. Quoted files are read
without waiting on another program's lock: a file changed after the snapshot is extracted again
before it is quoted; a file that is gone or locked is named `vanished` or `unreadable`, and a
file that grew over the size limit is left out by the declared `too_large` rule, each with its
own reason line; an older state is never quoted as current.

n8n (2026-10-01, ReleaseFast, 16 logical CPUs, 8 worker threads):

| | |
|---|---|
| files in scope | 22,776: 21,453 parsed (175 with syntax errors), 1,323 not parsed (`.vue` and similar) |
| definitions, references | 130,040, 1,885,039 (743,276 resolved, 64,458 of them typed) |
| full build | 91.5 s wall with cold reads on this machine (about 15 ms per file); 16.8 s with the files in the OS cache (store version 3: parse 26.8 s and extraction 85.8 s of CPU over 8 threads, link 0.8 s, save 0.4 s) |
| store, memory | 54.7 MB on disk with the outline and the test blocks (47.8 MB before them); peak working set 749 MB while building, 410 MB loaded |
| warm open | load 0.85 s, file listing 0.1 s warm (2.8 s cold), stamps 0.08 s |
| query p50 / p99, 200 seeded samples | callers 0.25 / 3.0 ms, callees 0.11 / 0.29 ms, defined_at 0.19 / 0.90 ms, refs 0.24 / 3.0 ms |
| evidence p50 / p99, 200 seeded samples, callers, callees and tests included | explain 1.4 / 5.6 ms, decides 1.0 / 5.3 ms, callers 1.2 / 5.9 ms, callees 1.3 / 5.7 ms, flow 1.2 / 6.1 ms, two targets 2.0 / 6.9 ms; max 8.4 ms. Before the outline: 22 / 391 ms. A file read for the first time costs about 10 to 15 ms more on this machine |
| one-file update p50 / p99 | 9.9 / 16.8 ms (parse, extract with the outline, relink, snapshot root) |

`tests/bench/evidence_seen.py` asks for the evidence of the four seen questions (S1, S2, S5 and S6)
with the gold target given by hand and the default sections: the checklist items found in the
block are 5/5, 4/5, 4/5 and 5/5, in 3,756 to 8,748 characters, p99 at most 5.7 ms over 50 runs.

`tests/bench/facts_tsserver.py` compares `callers` with tsserver's `findReferences` call
sites on 30 seeded callables from `packages/core`, `packages/workflow` and six `@n8n`
packages (745 program files, TypeScript 6.0.3). n8n has no `node_modules`, so tsserver is
given emetgate's module map. 101 call sites are in both, 0 only in emetgate and 22 only in
tsserver: 11 emetgate lists as unresolved (`property_needs_type`) and 11 it binds to an
override or another implementation of the same interface member, a family tsserver merges.
Precision 1.00 and recall 0.82 against tsserver, no unclassified difference.

**Limits:** TypeScript namespaces are not definitions; `.vue`, `.svelte`, `.astro`, `.mts`
and `.cts` files are not parsed, only their identifiers are kept to decide whether an
answer must name them; a CommonJS `module.exports` is not read as an export table; return
types are not inferred, so a call on a value returned by a function stays unresolved; a
workspace package resolves only through the `outDir` and `rootDir` it declares; the
tsserver comparison shares emetgate's module map.

## How the kernel itself is verified

Numbers in this README that can be read out of the source or the mutation corpus are
generated by `tools/readme_facts.py` and `tools/verification_page.py` and checked in CI
and in `tools/accept.ps1`, so they cannot go stale without a build failing; numbers that
are the output of a benchmark script instead carry a one-line note naming the script and
the date they were last measured, since re-running a benchmark on every build is not
part of this check. See [`VERIFICATION.md`](VERIFICATION.md) for the full mutation and
red-team breakdown.

The kernel's guards are tested in two ways.

**Mutation testing.** Guards and branches that protect an invariant are mutated (a check removed, a condition weakened, a comparison flipped) and the test suite is run against each mutant. At least one test must fail. A surviving mutant is either made to fail with a new test or recorded in `tests/mutations.json` as equivalent, intentionally redundant, or open. The harness lives in `tools/mutate`. It copies the working tree's non-ignored files into `.zig-cache/mutate/tree` and works only there, so a run that is killed never leaves a mutant in the working tree. It puts every mutant into one test binary as a copy of the function it changes, with a dispatch on the function's first line, and runs each mutant in its own process with only the tests it names; a mutation that cannot be copied that way gets its own build, and so does one in the function that sets the active mutant, the runner's `main`, since it runs before the dispatch can see the mutant. An expected survivor names with `filter` the tests that reach its mutated line, so it proves survival in seconds instead of running the whole suite. `--changed-since <ref>` limits a run to the mutations on lines changed since `<ref>`. `zig build test` fails when a mutation's `from` text no longer occurs in its file as the harness would apply it, or when a test it expects to kill no longer exists by that name in a file some suite compiles, so a refactor cannot leave a mutant silently testing nothing.

For the engine (`cas`, `boundedness`, `symbol`, `functions`) that is <!-- generated:engine-mutant-summary -->64 mutants today: 57 killed, 4 proven equivalent, 2 redundant guards kept as defense in depth, 1 open<!-- /generated -->. Generated by `tools/readme_facts.py` from `tests/mutations.json`; the full breakdown by area is in [`VERIFICATION.md`](VERIFICATION.md).

**Adversarial tests.** Dedicated red-team suites attack the gate directly: bodies that escape their braces, stale hashes, torn journal entries, poisoned repository configuration and attempts to open files outside the repository.

**Fuzzing.** `tests/fuzz_regex.zig`, `tests/fuzz_protocol.zig`, `tests/fuzz_ledger.zig`, `tests/fuzz_cas.zig` and `tests/fuzz_journal.zig` each run a seed corpus through `zig build test` in seconds and check a stated invariant, not only the absence of a crash: `fuzz_cas` asserts that `cas.apply` on a fixed base and hash either refuses the input or leaves every byte outside the edited slot identical to the base; `fuzz_journal` asserts that `journal.parse` never returns the `.batch` variant for a `version` other than the current one. Zig 0.16's coverage-guided `--fuzz` runner is not wired up here, since it does not run on Windows in this toolchain; `tools/test_runner.zig`'s `fuzz` reimplements the corpus loop `std.testing.fuzz` expects, so the same seed inputs run as ordinary fast tests. Open-ended, time-boxed exploration instead lives in `tools/fuzz/main.zig`, built as `zig build fuzz-tool`: `emetgate-fuzz <regex|protocol|ledger|cas|journal> [seconds]` mutates the seed corpus with random byte edits for the given duration (default 20s) and reports the iteration count. `tests/mutations.json` records `FUZZ1-cas-splice-tail-off-by-one` and `FUZZ2-journal-version-equality-loosened`, mutants that only the fuzz invariant checks (not the surrounding unit tests) catch.

## Status

Emetgate currently has a narrow scope.

| Area | State |
|---|---|
| AST-verified mutation, content hashes, structural guards | Built, mutation-tested |
| Boundedness analysis and test gate | Built, mutation-tested |
| Journal, atomic commit, recovery, sandbox | Built |
| MCP server and locked-down launch | Built |
| Decision ledger (append-only, supersession, compaction, torn-tail recovery) | Built; readable by the model through `emetgate_skeleton`, writable only from the CLI |
| Rule enforcement at the edit gate | Built, mutation-tested: AST checks, `q:` tree-sitter queries and `cmd:` command predicates |
| Language support | see the table below; new languages are added as profiles under `src/engine/lang` and must pass the conformance suite in `tests/lang` |
| Platform | Windows only (the sandbox relies on Job Objects) |

On the token benchmark in `tests/bench` (tokenizer `o200k_base`, six scenarios, two of them real files), editing through symbol-level proposals uses a median of **1.80×** fewer tokens than search-and-replace editing, with a range of 1.15× to 3.77×. On the real files the gain is 1.15× to 1.17×.

### Supported languages

| Language | Extensions | Grammar | Notes |
|---|---|---|---|
| TypeScript | `.ts` | tree-sitter-typescript (typescript dialect) | full OOP conformance suite: classes, accessors, decorators |
| TSX | `.tsx` | tree-sitter-typescript (tsx dialect) | same profile shape as TypeScript, plus JSX |
| JavaScript | `.js`, `.mjs`, `.cjs`, `.jsx` | tree-sitter-javascript | JSX is parsed by the same grammar, no separate profile |
| Zig | `.zig` | tree-sitter-zig | top-level `fn` only; see the limits below |

Zig does not share the class/getter/setter shape the generic conformance suite in
`tests/lang/conformance.zig` was built around, so it is exempt from that suite
(`object_style_contract_exempt` in that file) and gets its own compatibility file,
`tests/lang/zig/compat.zig`, covering the same guarantees (stale hash, placeholder,
escaping body, untouched neighbour, boundedness escapes, a struct-nested function) in
idiomatic Zig instead.

Known Zig limits:

- **`test` blocks are not CAS-addressable.** `functions.classify` requires a `body` field
  on the node; tree-sitter-zig's `test_declaration` exposes its block positionally, with
  no field. A test block is therefore invisible to `symbols`/`mutate`/skeleton compression,
  but it also cannot corrupt a neighbouring function's hash or CAS span (covered by a test).
- **Struct/enum/union bodies are transparent**, not named containers, for the same reason:
  `const Foo = struct { ... }` exposes no `name` or `value` field on `variable_declaration`
  for a binding-name lookup to use. A function nested in a struct is tracked under its bare
  name; two same-named functions in different structs collide as an ambiguous symbol (a safe
  refusal, not a wrong mutation).
- **`pub`/`export` visibility needed one small engine change.** `boundedness.isExported`
  used to walk only ancestor node kinds (an `export_statement` wrapper, TypeScript/JavaScript
  style). Zig's `pub` and `export` are keyword tokens inside the declaration node itself, not
  a wrapping node, so no combination of profile data could express them. `Profile` gained a
  `visibility_keywords` list field (default `&.{}`, so TypeScript/JavaScript/TSX behaviour is
  unchanged) and a `hasVisibilityKeyword` helper, and `boundedness.isExported` now checks it
  first. Zig sets `visibility_keywords = &.{ "pub", "export" }` (`export fn` gives a symbol
  C ABI/linker visibility, same escape as `pub`). This is the one line changed under
  `src/engine` outside `src/engine/lang`.
- **Taking a function's address is already unbounded, with no Zig-specific code.**
  `&foo`, and `@export(&foo, .{...})`, put the `foo` identifier under a `unary_expression`
  (address-of), never as the direct callee of a plain call or a bare call argument. The
  engine's existing `classifyReference` fallback (any reference shape it does not
  specifically recognise as a safe plain call) already returns `.unrecognized_reference`,
  i.e. unbounded — the same fallback that already makes `obj[process]()` unbounded for
  JavaScript. Covered by dedicated Zig tests, not by new engine code.
- **Identifier-text matching has a pre-existing, language-independent limit**, not special
  to Zig: a reference built from a runtime/comptime-computed string (Zig: iterating
  `@typeInfo(@This()).@"struct".decls` and calling `@field(@This(), decl.name)`;
  JavaScript: `obj["process".slice(0)]()`) never spells the target name as a literal
  identifier or string anywhere in the file, so nothing in the engine's text-based scan has
  a match to flag. This is a property of the whole kernel's reference-matching design, not
  a Zig profile gap, and fixing it is out of this task's scope. `usingnamespace` was also
  reviewed: it only pulls other namespaces' `pub` declarations into scope, it does not change
  the exported visibility of this file's own declarations, so it needed no handling.
  `extern fn` (no body) is simply invisible to `classify` (same as any bodyless declaration),
  never mutated, so it cannot be wrongly marked BOUNDED.

Each scenario counts the tokens both approaches spend on one symbol edit: ingest plus emit. Search-and-replace reads the whole file and sends the old and new block; the kernel reads a skeleton plus one symbol body and sends a symbol reference, a content hash and the new body. Search-and-replace is the baseline; a whole-file rewrite is the upper bound (2.88× on the same set). The tokenizer is a GPT-4o-family proxy, so the ratio matters more than the absolute count. The benchmark runs offline and can be reproduced with `python tests/bench/run4.py` after building the binary; the numbers above are its output as of 2026-09-14, not generated or checked in CI.

## Security history

Findings against the gate, oldest first.

**F1 — the write tools were not confined to the served repository.** The read tools checked the repository boundary, but `emetgate_try` and `emetgate_try_batch` did not. Given an absolute path, the gate verified a file in another git repository on the machine against that repository's own tests and wrote to it. An audit showed this with a real MCP call that returned `committed`. The same audit attacked the splice, the parse error check, content hashes and the atomic commit, and none of those attacks got through. Fixed in `0226b07` (2026-09-15) and `cab97cd`, which send every tool through `repo.jail` against the served root, first released in v0.1.2.

**F2 — `.git` internals in a git worktree were refused for the wrong reason.** Low severity: the gate failed closed. `repo.jail` resolved a path before checking it for `.git`. In a worktree `.git` is a file, so `.git/HEAD` did not resolve and the read tools answered `FileNotFound` instead of `InternalPath`; the internal-path check never saw the request. Found in an audit. Fixed in `0795790` (2026-09-23): the path as written is checked before it is resolved, with a worktree test in `tests/readtools.zig`.

**F3 — a rejected proposal could write to the real repository during its tests.** The test command ran in a Job Object, which limited time and output but not where the command could write. A body that failed the tests on purpose changed a file in the real tree while they ran: the gate answered `rejected` and the write stayed. Since `6cc77b0` (2026-09-18) the command runs under a low-integrity restricted token, and if the token cannot be built the command does not run. Red-team tests are in `tests/redteam_sandbox.zig`; first released in v0.1.2.

**Repository ledger — `cmd:` rules from a committed ledger ran without consent.** A cloned repository that carried `.emetgate/ledger.ndjson` had its `cmd:` rules run in the sandbox on the first edit. This was found by reading the code during an audit. Fixed in PR #31 (`46f9173` to `66d1ed4`): without `--allow-repo-memory` those rules do not run and the edit is refused with `UntrustedRepoMemory`. Red-team tests are in `tests/redteam_ledger.zig`; first released in v0.1.5.

**F4 — a crash during `emetgate_try_batch` could leave the batch half applied.** `commitBatch` finalized the files one by one, deleting each backup and journal in turn. A crash after the first file and before the last left the finalized files new, and recovery rolled the others back. Each file was valid alone, but only part of the batch that passed the tests together was on disk. Found by model checking the journal protocol with TLA+ (TLC, two and three files). Fixed in `c03083e`: once every swap is verified, one durable batch commit record is written to the journal directory before any backup is deleted, and it is deleted after the last journal. Recovery rolls the batch forward when the record exists, after checking each target against the new hash its journal now carries, and rolls it back otherwise. Crash tests are in `tests/batch_crash.zig`; not yet released.

**F5 — the test command could not see its dependencies.** A functional failure, not a security one: the sandbox did not let anything through, it let too little through. The shadow copy linked `node_modules` with an NTFS junction, and a test command under the low-integrity token could not resolve paths through it: Node's `fs.existsSync`, `fs.realpathSync` and `require.resolve` failed with `ENOENT`, so the real `npm test` of express never found `mocha` and timed out or crashed. Found by an evaluation that ran real projects through the gate (repro scripts outside the repository). Fixed on `fix/linked-dirs-hardlink`: linked directories are rebuilt as hardlink trees, and the shadow copy moved out of `.emetgate/` to a per-repository directory under `%LOCALAPPDATA%`, because express's own tests refuse to serve files from a path with a dot segment. Red-team tests are in `tests/redteam_link_tree.zig`; not yet released.

**F6 — a crash in the middle of replacing a file could leave its path empty.** The swap renamed the target to a backup and then renamed the new content into place. Between the two renames the path did not exist; if the process died there and another tool created a file at that path before recovery ran, recovery could not put the backup back without overwriting that file, so the backup stayed on disk for someone to sort out by hand. No data was lost, but recovery could not finish. Found by model checking the journal protocol with TLA+ (the `modifyGap` variant). Fixed on branch `feat/journal-v2-delete`: the old content is copied to the backup and the new content replaces the target in one atomic rename, so the path never goes missing. Tests are in `src/platform/disk.zig` and `tests/batch_delete_crash.zig`; not yet released.

**F7 — a power cut could leave a batch half applied or roll a finished one back.** A data-loss fault, not a security one. The commit protocol flushed a file's directory after placing it, but four directory changes were never flushed on their own: the backup's name before the replacing rename, the deletion of a committed backup, the deletion of the journal before the commit record was removed, and the files recovery restored or deleted before their journal went away. On a file system that keeps directory changes in order (NTFS logs them that way) nothing went wrong, but that was an assumption nobody had written down, and SMB shares, network drives and file systems that flush each directory separately do not give it. After a power cut there, one file of a batch could stay new while the other was old, a finished batch could be rolled back with a newly created file deleted, and a backup could come back after it had been removed. Found by the second TLA+ model of the journal, which lets any unflushed directory change be lost. Fixed on branch `fix/dir-flush`: each of the four places now flushes its directory, and a failed flush stops the step that depends on it (the commit record stays, the journal is kept for the next recovery). Tests are in `tests/dir_flush_crash.zig`, which records unflushed directory changes and undoes a chosen set of them as a power cut would; not yet released.

## Nightly attacker

Every night, before a finding reaches this list by hand, an automated attacker tries to break the
gate from the same MCP surface a model uses: write outside the served repository, escape the test
sandbox, override the test/typecheck command or the repo-memory policy from a tool argument, read
or write `.git`/`.emetgate` internals, create a file through a batch edit outside the repo or
inside `.git`, reach outside the repo through a junction pointed at an external directory, abuse
the reader's `raw`, `pointer`, `heading`, `line_start`/`line_end` and `force` arguments, and feed
the `q:` query engine adversarial patterns. A success is never taken on the model's word: after
each attempt the harness checks `git status` in the served repository, the content of a canary
file kept outside it and one behind a junction, a marker the sandboxed test command would leave
behind if it ran in the real tree, and (for the junction cases) that the secret content never
appears in a tool's response. Only an observed change or leak counts.

Two modes, in `tools/attack/`:

- **Script mode (default, free, runs every night).** `tools/attack/run.py` starts a temporary git
  repository, launches `emetgate mcp --test <a command that would leave a marker file if it
  escaped the sandbox>`, and replays `tests/attack/corpus.json` over stdio: 73 attempts across
  stale/forged/absent hashes, body escapes, `test_cmd`/`typecheck_cmd`/`allow_repo_config`/
  `allow_repo_memory` injection through tool arguments, path traversal and absolute paths (plain
  files and `emetgate_try_batch`), `.git`/`.emetgate` internal paths, batch creation (hash
  `absent`) outside the repo and inside `.git`, the reader's new arguments taken outside the repo
  or onto internal paths, a `linked/` junction pointed at an external directory, adversarial `q:`
  queries, oversized bodies and symbol names, and mixed multi-step attempts. Run it with
  `python tools/attack/run.py` after `zig build`.
- **LLM mode (opt-in, off by default).** `tools/attack/llm_mode.py` runs the identical harness
  against attempts a model writes instead of the fixed corpus, under `emetgate lockdown` with a
  turn budget. Without `ANTHROPIC_API_KEY` set (and without `--fixture`, used only to test the
  wiring against a canned response) it prints that it is skipped and exits 0 — it never spends a
  token unless both the secret and an explicit `workflow_dispatch` input are given. Every attempt,
  successful or not, is written to `tests/attack/llm-sessions/` in the same shape as a corpus case,
  so a rejected model attempt can be copied into `tests/attack/corpus.json` as a permanent
  regression and a successful one becomes a Security History candidate.

`.github/workflows/ci.yml`'s `nightly-attacker` job runs script mode on every schedule and
`workflow_dispatch` run; LLM mode only runs when that dispatch sets `llm_attack: true`, so it never
runs on a schedule and never on a pull request.

The harness's own guard is covered too: `tools/attack/test_harness.py` checks that dropping any one
of the three observations (`git status`, the canary file, the sandbox marker) would hide a real
breach, and a manual check confirms the harness end to end — with `cas.propose`'s hash comparison
replaced by `if (false) return error.HashMismatch;`, the same 73-attempt corpus reports 5 breaches
(the stale/forged-hash, mixed and outside-repo batch-create cases) instead of 0, and exits 1.

The MCP tool descriptions themselves are scanned too: `tools/redteam/scan_tools.py` runs
`snyk-agent-scan inspect --dangerously-run-mcp-servers --json` against a config generated for the
built `emetgate.exe` (`inspect` only lists what a server advertises; it makes no network call and
needs no account, unlike `scan`'s hosted verification, which this repository does not run) and
checks each tool and argument description for injection-style phrasing ("ignore previous
instructions", "send this data to", a bare URL), zero-width or other invisible formatting
characters, and oversized descriptions. Run it with `python tools/redteam/scan_tools.py` after
`zig build`; it currently reports none of the ten served tools with a finding.

## Limits

The verification guarantees have the following limits:

- **Semantic correctness.** Code that parses, stays in bounds and passes the tests can still implement the wrong behaviour. The kernel does not replace tests that encode intent or human review where it is needed.
- **The quality of the test suite.** For unbounded changes the test gate is only as strong as the tests it runs.
- **Mediation.** The guarantees hold for changes that go through the gate. Edits made by other tools bypass it, which is why lockdown exists.
- **Sandbox scope.** The low-integrity token stops the test command from writing outside the shadow copy; it does not restrict reading or network access, so a hostile test command can still read the user's files and reach the network.
- **AppContainer (experimental, not wired).** `src/platform/appcontainer.zig` can run a command in an AppContainer or LPAC profile under the same job and limits; the test gate and `emetgate_run` do not use it. Red-team tests (`tests/redteam_appcontainer.zig`) show that inside it a file the profile was not granted cannot be read or written, a loopback listener cannot be reached and the shadow copy stays writable. Access is granted with `SetFileSecurityW` on the named directory only, so existing files, hardlinks into the real `node_modules` among them, keep their own ACL. It does not run real projects yet: 0 of 3 (express `npm test`, eslint `npm test`, `zig build` of a fixture) pass, and under LPAC `node -e` fails too. Three things block it: Node needs to read the drive root (`C:\`), the Zig install under the user profile is not readable, and `npm` is not found. Measurements are in `tests/appcontainer_compat.zig`.
- **Leftover processes.** A background process that the test command starts and that ends within 2 s of the command's exit is waited for and not reported. Only one that outlives that grace, or the deadline if it comes first, is a leftover. Either way the job is killed before the verdict, so nothing the command started keeps running after it.
- **A flaky test command refuses good proposals.** The gate runs the test command once and a crash is not a pass. Node.js 24.15.0 and earlier on Windows crash intermittently with `0xC0000409` when a test opens a loopback connection: libuv's Windows version check hands `RtlGetVersion` an uninitialised `OSVERSIONINFOW`, which can overwrite the stack cookie of `uv__tcp_connect` (libuv issue 5106, fixed in Node.js 24.16.0). On the development machine express's `npm test` crashed in 5 of 20 runs in the sandbox and 4 of 20 outside it on 24.15.0, and in none of 20 runs either way on 24.21.0. The fix is to upgrade Node.js; emetgate reports the crash code in the result so it can be told apart from a failing test.
- **Allowed commands.** `emetgate_run` confines writes the same way the test gate does and no further: an allowed command can read what the user can read and reach the network. The out-of-scope check reads the words of an entry, so an install hidden in a script (`npm run setup` that calls `npm install`) is not caught; the allowlist is the user's decision. On machines where `NoDefaultCurrentDirectoryInExePath` is set, a script in the repository must be named with its path (`.\build.cmd`).
- **Linked directory cost.** The hardlink tree is rebuilt for every proposal. On the development machine that takes 2 to 5 s for express's `node_modules` (6,634 files) and 20 to 33 s for eslint's (38,542 files), plus the time to delete it afterwards. A persistent tree keyed by the directory's content is planned.
- **Repository ledger.** With `--allow-repo-memory`, a committed ledger's `cmd:` rules run under the same confinement as the test command: they cannot write outside the shadow copy, but they can read and reach the network. Pass the flag only for a ledger you have reviewed. Without the flag only execution is withheld; the text of every rule in a committed ledger is still shown to the model in `emetgate_skeleton`, so a hostile rule text is data the model reads, not a command anything runs.
- **Taste.** Architecture, API design and user experience are not properties a kernel can check.

## Installing

The published binary is built for the x86_64 baseline CPU (`-Dcpu=baseline`), so it runs on any 64-bit x86 processor rather than only on ones with the build machine's instruction set.

Each release tag publishes a Windows binary and its SHA-256 checksum on the [releases page](https://github.com/emetgate/emetgate/releases). Download both into a fixed folder under your profile (this only downloads; nothing is run):

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\emetgate" | Out-Null
foreach ($f in "emetgate.exe", "emetgate.exe.sha256") { Invoke-WebRequest "https://github.com/emetgate/emetgate/releases/latest/download/$f" -OutFile "$env:USERPROFILE\emetgate\$f" }
```

Check the binary against the published checksum before running it; this prints `True` when they match:

```powershell
(Get-FileHash "$env:USERPROFILE\emetgate\emetgate.exe" -Algorithm SHA256).Hash -eq (Get-Content "$env:USERPROFILE\emetgate\emetgate.exe.sha256").Split(" ")[0]
```

Register it with Claude Code by its absolute path, because Claude Code runs the stored command as written and a relative path does not resolve when Claude Code is started from another directory:

```powershell
claude mcp add emetgate -- "$env:USERPROFILE\emetgate\emetgate.exe" mcp
```

The binary is not code-signed, so Windows SmartScreen warns on first run: it flags executables that carry no publisher signature and have little download history, not because it found anything in this one. The checksum above is how to confirm the file is the one the release built.

## Building

Requires Zig 0.16.0. tree-sitter and the TypeScript, TSX, JavaScript and Zig grammars are vendored.

```sh
zig build                   # zig-out/bin/emetgate
zig build test              # every test from one binary in four processes, then the CLI end-to-end tests
zig build test -Dslow=true  # also the tests over one second, which the nightly CI runs
zig build test-fast         # engine unit tests only: no git, no sandbox, a few seconds
zig build test-timing       # every test one by one, with the slowest tests and per-file totals
zig build test-bin          # the test binary alone, zig-out/bin/test-all
zig build bench             # session benchmarks at full size
zig build mutate-tool       # mutation harness
tools/accept.ps1 <ref>      # the tests three times, then the mutations on lines changed since <ref>
```

`zig build test` compiles one test binary, `test-all`, from `test_root.zig`: the `src` tests and
every file under `tests/`. Its runner, `tools/test_runner.zig`, chooses the tests at run time
(`--filter`, `--skip`, `--shard`, `--jobs`, `--slow`, `--mutant`), so `-Dtest-filter` does not
recompile anything, and a filter that matches no test fails the run. With `--jobs` the binary
starts itself as shards and fails unless together they ran every selected test exactly once.
`tests/suites.zig` fails the run if a test file under `tests/` is not imported exactly once by
`test_root.zig`. On the development machine (Windows, Debug) the binary compiles in about 10 s
with 0.7 GB of memory; the run takes about 20 s, and 40 s with the slow tests. The nine binaries
this replaced took 28 s to compile in parallel after a one-line change.

Register the server with an MCP client:

```json
{
  "mcpServers": {
    "emetgate": {
      "command": "C:/path/to/zig-out/bin/emetgate.exe",
      "args": ["mcp", "--typecheck", "npx tsc --noEmit", "--test", "npm test"]
    }
  }
}
```

`--typecheck` is optional. When it is set, the typecheck command runs on the shadow copy before the test command, and a failure rejects the change with reason `typecheck_failed` without running the tests. Both commands can instead come from `test_cmd` and `typecheck_cmd` in `.emetgaterc.json`, which is read only with `--allow-repo-config`. The model can never supply either command. `--allow-repo-memory` lets the `cmd:` rules of a ledger committed to the repository run; see [A ledger committed to the repository](#a-ledger-committed-to-the-repository).

## Roadmap

1. **Decision memory.** Rules and decisions stated once are written to the ledger, re-injected into the model's input on every relevant turn, and, where a rule can be checked mechanically, enforced at the edit gate. A decision changes only when the user changes it.
2. **Codebase understanding.** A content-addressed, incremental index of symbols, imports and git history, so the model is given the minimal slice of the program a task touches instead of the whole repository.
3. **Deterministic driver.** For tasks with a known shape, the kernel drives the work and calls the model only at the points that genuinely require judgment.
4. **Check packs.** Domain-specific mechanical checks for backend and frontend code, registered with the same gate.

## License

MIT. See [LICENSE](LICENSE). The vendored tree-sitter grammars under `vendor/` keep their own MIT licenses.
