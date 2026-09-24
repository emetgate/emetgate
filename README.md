<p align="center">
  <img src="assets/banner.png" alt="Emetgate" width="640">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/status-early-E040FB?style=flat-square" alt="Status: early">
  <img src="https://img.shields.io/badge/zig-0.16.0-F7A41D?style=flat-square&logo=zig&logoColor=white" alt="Zig 0.16.0">
  <img src="https://img.shields.io/badge/platform-windows-0078D6?style=flat-square" alt="Platform: Windows">
  <img src="https://img.shields.io/badge/languages-typescript%20%7C%20tsx%20%7C%20javascript%20%7C%20zig-3178C6?style=flat-square" alt="Languages: TypeScript, TSX, JavaScript, Zig">
  <img src="https://img.shields.io/badge/protocol-MCP-1E1B26?style=flat-square" alt="Protocol: MCP">
</p>

<p align="center">
A deterministic verification kernel between language models and source code.</p>

<p align="center">
  <img src="assets/demo.gif" alt="Five proposals through the gate: four refused, one committed" width="900">
</p>

<p align="center"><sub>A session in which four invalid proposals are rejected and one valid proposal is committed.</sub></p>

---

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

**Durable commit.** Accepted changes go through a write-ahead journal and an atomic write-rename. A crash at any point leaves either the old file or the new one, never a torn write. A batch from `emetgate_try_batch` commits as one: after a crash, `recover` leaves every file of the batch old or every file new. `recover` replays the journal and refuses anything it cannot prove: zero-byte files, entries that no longer re-parse, and malformed tags.

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
paired runs (`python tests/bench/rule_command_cost.py`):

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

| Limit | Value |
|---|---|
| query text | 4 KB including `q:`, as for `cmd:` (`QueryTooLong`) |
| captures | at most 8 per pattern, none repeated with `+` or `*`, none on a group or alternation with `+` or `*` at its own level |
| operations per run | 20,000,000, shared by the tree-sitter cursor (100 per progress callback and 100 per match), the regex (1 per state visited and 1 per probe into a character class) and the other predicates (1 per capture visited, also when the match is reported, and 1 plus the bytes compared for each comparison) |
| operations per `emetgate_scan` call | 100,000,000 over all files; each file still gets at most 20,000,000 of it |
| in-progress matches | 1024 |
| tree depth times pattern depth | 6,000 (`query_depth_exceeded`); the tree depth is that of the deepest node the scope reaches, the pattern depth is how deeply the query's parentheses and brackets nest |

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
`q:` rule that runs a `#match?` (`python tests/bench/rule_query_cost.py`):

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
that grows faster than n^1.35. On a ReleaseSafe build, 123 of the 132 grow linearly. The
other 9 are all on a deep left-leaning chain (`a + a + ... + a` or `a.b.b...b`, 16,000 levels):
a pattern nested three levels deep (`(_ (_ (_) @violation))`, 10.9 s at 16,000), six levels
deep (past 30 s), or anchored to a last child (`(_ (_) @violation .)`, 3.9 s). That time is
spent inside tree-sitter's query cursor, where the operation budget and the match limit do not
reach. Two costs of emetgate's own that the run found are fixed: violations were placed by
rescanning the file from the start, and their text was copied whole, both n^2 on these inputs.

The depth limit answers the rest. Measured on a ReleaseSafe build over `a + a + ... + a`, with
`emetgate scan --check` on a file in the repository; `emetgate_scan` over MCP took the same
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
| `emetgate_read_symbol` | The source of one symbol |
| `emetgate_mutate` | Verify a proposed body structurally and return the result without writing |
| `emetgate_try` | Verify, gate and commit a proposed body |
| `emetgate_try_batch` | Several proposals as one unit |
| `emetgate_read_file`, `emetgate_list`, `emetgate_search` | Reads confined to the repository |
| `emetgate_scan` | Measure one check expression against the repository, optionally within a `where` scope; writes nothing |

**New symbols and new files.** A proposal with `"hash": "absent"` adds one top-level declaration: to the end of an existing file, or as the only content of a file that does not exist yet. `emetgate_try` and `emetgate_try_batch` both accept it, and in a batch it commits or rolls back together with the other edits. A new file is journaled as a create intent, placed with a rename that never replaces an existing path, and added to the git index after the commit point; if another process puts a file at that path before the commit, the batch is refused with `Conflict` and that file is kept. Recovery deletes an uncommitted new file only while it still has the journaled hash, and indexes a committed one. For each such edit the batch result carries `class` (`symmetry` or `unclassified`) and the evidence behind it: the file parses, the new name is mentioned nowhere else in the batch or the tracked files, the declaration has no top-level effect (no call, `new`, assignment or decorator outside a function), and, for a new file or an exported symbol, no other file mentions the module. The test gate still runs for every batch, whatever the class. Limits: the parent directory must already exist, one batch creates a path at most once and cannot also edit it, and the reference check is a whole-word text match, so it errs toward `unclassified`. If `git add` fails after the commit, the files stay on disk and the result is `WrittenButNotIndexed`.

`emetgate lockdown` starts Claude Code with only these tools available, so the model has no path to the disk other than the gate.

The repository ships a Claude Code skill, `.claude/skills/md-audit/SKILL.md`, that audits a CLAUDE.md or AGENTS.md file: it sorts every instruction sentence into enforceable, waiting for a mechanism, unverifiable or belief, proposes a check and scope for the enforceable ones, measures each with `emetgate_scan` and reports, changing nothing. To use it in every project, copy the `md-audit` folder into `%USERPROFILE%\.claude\skills\` (`~/.claude/skills/` elsewhere).

## How the kernel itself is verified

The kernel's guards are tested in two ways.

**Mutation testing.** Guards and branches that protect an invariant are mutated (a check removed, a condition weakened, a comparison flipped) and the test suite is run against each mutant. At least one test must fail. A surviving mutant is either made to fail with a new test or recorded in `tests/mutations.json` as equivalent, intentionally redundant, or open. The harness lives in `tools/mutate`. It copies the working tree's non-ignored files into `.zig-cache/mutate/tree` and works only there, so a run that is killed never leaves a mutant in the working tree. It puts every mutant into one test binary as a copy of the function it changes, with a dispatch on the function's first line, and runs each mutant in its own process with only the tests it names; a mutation that cannot be copied that way gets its own build, and so does one in the function that sets the active mutant, the runner's `main`, since it runs before the dispatch can see the mutant. An expected survivor names with `filter` the tests that reach its mutated line, so it proves survival in seconds instead of running the whole suite. `--changed-since <ref>` limits a run to the mutations on lines changed since `<ref>`. `zig build test` fails when a mutation's `from` text no longer occurs in its file as the harness would apply it, or when a test it expects to kill no longer exists by that name in a file some suite compiles, so a refactor cannot leave a mutant silently testing nothing.

For the engine (`cas`, `boundedness`, `symbol`, `functions`) that is 44 mutants today: 37 killed, 4 proven equivalent, 1 redundant guard kept as defense in depth, 2 open.

**Adversarial tests.** Dedicated red-team suites attack the gate directly: bodies that escape their braces, stale hashes, torn journal entries, poisoned repository configuration and attempts to open files outside the repository.

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

Each scenario counts the tokens both approaches spend on one symbol edit: ingest plus emit. Search-and-replace reads the whole file and sends the old and new block; the kernel reads a skeleton plus one symbol body and sends a symbol reference, a content hash and the new body. Search-and-replace is the baseline; a whole-file rewrite is the upper bound (2.88× on the same set). The tokenizer is a GPT-4o-family proxy, so the ratio matters more than the absolute count. The benchmark runs offline and can be reproduced with `python tests/bench/run4.py` after building the binary.

## Security history

Findings against the gate, oldest first.

**F1 — the write tools were not confined to the served repository.** The read tools checked the repository boundary, but `emetgate_try` and `emetgate_try_batch` did not. Given an absolute path, the gate verified a file in another git repository on the machine against that repository's own tests and wrote to it. An audit showed this with a real MCP call that returned `committed`. The same audit attacked the splice, the parse error check, content hashes and the atomic commit, and none of those attacks got through. Fixed in `0226b07` (2026-09-15) and `cab97cd`, which send every tool through `repo.jail` against the served root, first released in v0.1.2.

**F2 — `.git` internals in a git worktree were refused for the wrong reason.** Low severity: the gate failed closed. `repo.jail` resolved a path before checking it for `.git`. In a worktree `.git` is a file, so `.git/HEAD` did not resolve and the read tools answered `FileNotFound` instead of `InternalPath`; the internal-path check never saw the request. Found in an audit. Fixed in `0795790` (2026-09-23): the path as written is checked before it is resolved, with a worktree test in `tests/readtools.zig`.

**F3 — a rejected proposal could write to the real repository during its tests.** The test command ran in a Job Object, which limited time and output but not where the command could write. A body that failed the tests on purpose changed a file in the real tree while they ran: the gate answered `rejected` and the write stayed. Since `6cc77b0` (2026-09-18) the command runs under a low-integrity restricted token, and if the token cannot be built the command does not run. Red-team tests are in `tests/redteam_sandbox.zig`; first released in v0.1.2.

**Repository ledger — `cmd:` rules from a committed ledger ran without consent.** A cloned repository that carried `.emetgate/ledger.ndjson` had its `cmd:` rules run in the sandbox on the first edit. This was found by reading the code during an audit. Fixed in PR #31 (`46f9173` to `66d1ed4`): without `--allow-repo-memory` those rules do not run and the edit is refused with `UntrustedRepoMemory`. Red-team tests are in `tests/redteam_ledger.zig`; first released in v0.1.5.

**F4 — a crash during `emetgate_try_batch` could leave the batch half applied.** `commitBatch` finalized the files one by one, deleting each backup and journal in turn. A crash after the first file and before the last left the finalized files new, and recovery rolled the others back. Each file was valid alone, but only part of the batch that passed the tests together was on disk. Found by model checking the journal protocol with TLA+ (TLC, two and three files). Fixed in `c03083e`: once every swap is verified, one durable batch commit record is written to the journal directory before any backup is deleted, and it is deleted after the last journal. Recovery rolls the batch forward when the record exists, after checking each target against the new hash its journal now carries, and rolls it back otherwise. Crash tests are in `tests/batch_crash.zig`; not yet released.

## Limits

The verification guarantees have the following limits:

- **Semantic correctness.** Code that parses, stays in bounds and passes the tests can still implement the wrong behaviour. The kernel does not replace tests that encode intent or human review where it is needed.
- **The quality of the test suite.** For unbounded changes the test gate is only as strong as the tests it runs.
- **Mediation.** The guarantees hold for changes that go through the gate. Edits made by other tools bypass it, which is why lockdown exists.
- **Sandbox scope.** The low-integrity token stops the test command from writing outside the shadow copy; it does not restrict reading or network access, so a hostile test command can still read files it has permission to read and reach the network. Confining those requires an AppContainer, which is planned.
- **Leftover processes.** A background process that the test command starts and that ends within 2 s of the command's exit is waited for and not reported. Only one that outlives that grace, or the deadline if it comes first, is a leftover. Either way the job is killed before the verdict, so nothing the command started keeps running after it.
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
