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

**AST-verified mutation.** A change replaces exactly one function body. The new body is spliced into the source by byte range and the whole file is re-parsed with tree-sitter. The kernel then checks that the result parses cleanly, that the body did not break out of its symbol, that it is not an empty or placeholder body, and that every byte outside the target span is untouched.

**Boundedness.** Before running anything, the kernel computes whether the change can affect code beyond the symbol itself. The analysis is a positive, closed-world count: a change is `BOUNDED` only when every way it could escape has been ruled out, and the verdict carries its provenance. Anything the analysis cannot account for is `UNBOUNDED`.

**Test gate.** `UNBOUNDED` changes are applied to a shadow copy and the project's test command is run against it inside a sandbox (a Windows Job Object with kill-on-close, wall-clock and memory limits, and an output cap). The command runs under a low-integrity restricted token, so a body proposed by the model cannot write anywhere outside the shadow copy; if that token cannot be built and verified, the command is refused rather than run unconfined. If the tests fail, the change is rejected and each failing test's output is returned to the model (see Failure output below). A command that exits but leaves a process behind in the job fails too (`leftover_processes`). After the exit the sandbox reads the pipes to EOF and waits for the job to empty, for up to 2 s and never past the command's deadline; the exited command's own console host is not counted. Whatever is still running after that is killed and reported. When the sandbox kills a job, on a leftover, a timeout or the output limit, it returns only after every killed process has exited, so none of them still holds a file in the shadow copy.

**Failure output.** When a write is rejected because tests failed, or lands while tests fail (`failing_tests`, `regressed`, `baseline_failing`), the reply carries `failures`: one block per failing test, headed by its id, with the assertion or error the runner printed and a short traceback. It is read from the output of pytest, dotnet test (by the layout of its lines, so a localized console works), Jest, Vitest, mocha, `node --test` (spec and TAP), `go test`, `cargo test`, `zig build test` and a Zig test binary. Tests named in `regressed` or owed in `failing_tests` come first. In each block, ANSI colours, frames under `node_modules`, `site-packages` and Node internals, numbered source lines around the marked one and rule lines are left out; the first frame and the assertion lines are kept longest. A block is cut to 40 lines and 2 KiB, and each cut is written in place as `… N line(s) left out`. The whole field stays under 6 KiB; when tests or lines do not fit it ends with `left out: N more failing test(s) (ids) and M lines cut from the ones above`. With no runner layout found, compiler and interpreter errors are read instead (`file:line:col: error`, `file(line,col): error`, rustc `error[...]` with its `-->` and `|` lines, a Python traceback), each with its notes, and a rejected typecheck carries them the same way; one-line diagnostics already given in `diagnostics` are not repeated. When nothing of that is found, the reply gives the earlier `output` digest with `output_dropped_lines`. A passing run gives only the one-line `tests` summary.

**Where the shadow copy lives.** The shadow copy is built outside the repository, in `%LOCALAPPDATA%\emetgate\shadow\<key>\shadow`, where `<key>` is a hash of the repository root's absolute path, so two repositories never share one and nothing is added to the working tree. The operator can move it with `--shadow-root <dir>` on `try`, `mcp` and `recover`; the model cannot, and a tool call that names a shadow root is refused like one that names a test command. Before a shadow copy is built or removed, every directory from the shadow root down is checked for junctions and symlinks and refused if it has one. A shadow copy whose repository no longer exists is removed on the next run. Tracked files are copied. Linked directories (`node_modules`) are rebuilt as hardlink trees: real directories, one hardlink per file, so the low-integrity test command can read its dependencies but, because the files keep their own security descriptor, cannot write, truncate or change their attributes; deleting or renaming a link in the shadow copy leaves the real file alone. A file whose integrity label would let a low-integrity process write it is copied instead of linked, and so is a file on another volume from the shadow copy. Junctions and symlinks inside a linked directory are not followed. The result's `shadow` object gives the shadow root and how many files were linked, copied and skipped; `shadow_path_warning` is added when the shadow path has a segment starting with a dot, because some tools refuse to serve files from such paths (the `send` package behind express's `res.sendFile` answers 404). The journal and the batch commit record stay in `.emetgate/` inside the repository, next to the files they restore, so `emetgate recover` finds them without knowing where the shadow copy was.

**The kept tree.** By default the shadow is kept between calls instead of being deleted and copied again; `--shadow-tree copy` on `try` and `mcp` selects the full copy described above, built for each call and deleted after it, and `--shadow-tree kept` names the default. The model cannot choose: a tool call that names `shadow_tree` or `shadow_private` is refused like one that names a test command. In the kept tree every tracked file and every file of a linked directory is a hard link to the working file itself, so nothing is copied and nothing is compared by content, size or time: on each call one bulk read of every directory involved, on the working side and on the tree side, gives each name's file id, and a name is right exactly when both sides carry the same id. An edit saved in place is therefore visible at once, a save that replaces the file gives the working name a new id and the name is linked again, and anything else in the tree (a file a test wrote, a directory it created, a name it replaced, renamed or deleted, a junction or symlink) is removed or repaired before the next command runs, without following a link. Nothing is recorded between calls: there is no manifest to forge, and a call that stops half way is followed by one that proves the tree again from the two directory reads. The proposed edit is written by removing the name and creating a new file, never by opening the linked file. What changes for a test command compared with the full copy:

- **A tracked file cannot be written in place.** The test command runs at low integrity and the linked file keeps the working file's own label, so opening it for writing, appending, truncating, changing its attributes or times or adding a stream fails with access denied (`EPERM` in Node), and the working file is untouched. Deleting the name, renaming it, or writing a new file over it (write to a temporary name, then rename) works and affects only the tree. A test that has to write tracked files in place needs `--shadow-private <path>` (repeatable on `mcp`): every tracked file at or under that path is a private copy made again on each call, at the cost of copying those files each time; or `--shadow-tree copy`.
- **A tracked file missing from the working tree is absent from the tree.** The tree mirrors the working tree; before this change such a call failed with `FileNotFound`. The full copy now behaves the same way.
- **The tree stays on disk.** `%LOCALAPPDATA%\emetgate\shadow\<key>\shadow` holds one name per tracked file and no file content of its own; each working file shows two names (link count 2) while it exists. What a test left behind stays until the next call on that repository, which removes it first. A person or tool that edits a file inside the kept tree in place edits the working file.
- **An edit the user saves in place while a test runs is visible to that test**, because the tree and the working tree share the file. With the full copy the test saw the state at copy time.
- **The first call on a repository builds the links**, one per file; later calls only read directories.

A working file that a low-integrity process could write (an explicit low integrity label) and a file that already has the 1,024 names NTFS allows are given private copies, made again on each call, instead of links. When the repository is on another volume than the shadow root, or the volume has no hard links, the full copy is used for that call. The result says which tree the gate used: `"gate_tree":{"kind":"kept","private_copies":N}`, or `"gate_tree":{"kind":"full_copy","reason":"requested" | "other_volume" | "no_hard_links"}`. The field is in every rejected reply of `emetgate_try`, `emetgate_try_batch` and `emetgate_write_doc`, in every `emetgate_run` reply that ran the command, and in a committed reply with `detail:"full"`, next to the `shadow` object; a compact committed reply leaves it out with the rest of the shadow summary. A full copy is removed when the call ends; when that removal fails, the field carries the error as well, `"gate_tree":{"kind":"full_copy","reason":...,"left_behind":"<error>"}`, in a compact committed reply too, and the CLI prints a warning. The verdict of the call is not changed by it. The next call that uses a full copy removes the tree that was left before it copies, and fails when it still cannot. To get the kept tree for a repository on another drive, start emetgate with `--shadow-root <dir>` on that drive. The directory is labelled for the test command without propagating the label to what is already in it: applying the label with inheritance to a populated tree would stamp it on every linked working file and make them writable from the sandbox. A kept tree whose repository was deleted or moved keeps the names, and through them the content, of that repository's files until it is removed: every gated call and `emetgate recover` remove the trees under the same shadow root whose recorded repository path no longer exists, and `emetgate recover` removes the tree of the repository it is run in. A tree is not removed while its repository path exists, or when no gated call or `recover` runs again under that shadow root. Removing a tree only removes names; the working files stay.

**Rights the kept tree needs.** The gate opens every directory, in the working tree and in the kept tree, only to list it and to read its attributes; no directory handle asks for a right to add or to delete. The working tree is only read: each directory involved must allow listing, and a file is linked when it allows reading its permissions and writing its attributes; a file that allows less, for example read only, gets a private copy. The kept tree, under the shadow root, is changed by creating and deleting names inside it, which Windows checks against the permissions of those directories and names: the user needs to add files and subdirectories there and to delete each name. The Modify permission covers all of this on both sides, and so does the journal directory `.emetgate\journal` that a commit uses; Full control is needed nowhere. In 0.5.0 every directory was opened asking for the right to delete children, which belongs to Full control, so a repository in a folder that grants Modify only (the usual case outside the user profile) failed with `ScanDenied` on every gated call, and a commit there failed with `WorkspaceOpenFailed`. When a directory cannot be opened because access is denied or another process holds it, the call fails and the reply names the path, the reason and the side: `{"status":"error","error":"ScanDenied","exit_code":1,"message":"access denied: src (working tree)"}`. There is no fallback to the full copy for such a path: the fallbacks are for a volume that cannot hold the links, not for a path the user may not read.

Time of one gated call with a test command that exits at once (`cmd /c exit 1`), measured on 2026-10-06 on the development machine (16 logical cores, NTFS, Defender real-time protection on). "Loaded" rows were measured while other builds and test runs were using the machine, "quiet" rows with nothing else running. Full-copy figures are from the Debug build of the previous release line, kept-tree figures from a ReleaseSafe build; later calls are the median of 7 with their range, except the quiet row, which is 5 calls.

| Repository | Machine | Full copy, each call | Kept tree, first call | Kept tree, later calls |
|---|---|---|---|---|
| zod (741 tracked files) | loaded | 2.8 to 3.4 s (3 calls) | 1.2 s | 0.61 s (0.59 to 0.64) |
| express (215 tracked, 6,634 in `node_modules`) | loaded | 9.3 to 13.9 s (3 calls) | 6.8 s | 0.76 s (0.69 to 0.78) |
| eslint (2,362 tracked, 38,542 in `node_modules`) | loaded | 78.1 to 88.5 s (2 calls) | 31.0 s | 1.05 s (0.95 to 1.09) |
| n8n (29,129 tracked) | loaded | 162.4 s (1 call) | 20.2 s | 1.08 s (0.94 to 1.24) |
| n8n (29,129 tracked) | quiet | 91 to 97 s (2 calls) | 22.9 s | 0.81 to 0.86 s |

A call refused before the shadow is prepared takes 0.15 to 0.21 s on the same machine (3 calls, zod), so about that much of every figure is not the tree. After a restart or a long pause the directory reads are not in the file cache and one read of the n8n working tree took 5.1 s (1 measurement, single thread).

**Durable commit.** Accepted changes go through a write-ahead journal and an atomic replace. Each batch writes one journal (format version 2) that lists every intent before any file changes; a changed file is first copied to a backup and then replaced in one rename, so its path always holds either the old file or the new one, never a torn write or a gap. The handle that checked the old content stays open, refusing other writers, until the replace. Journals written before version 2 are still read by `recover`. A batch from `emetgate_try_batch` commits as one: after a crash, `recover` leaves every file of the batch old or every file new. `recover` replays the journal and refuses anything it cannot prove: zero-byte files, entries that no longer re-parse, and malformed tags.

**Emetgate's own directories are never reached through a link.** `.emetgate\journal`, `.emetgate\receipts` (with `receipts\attached`), the scratch directory of `emetgate verify` for a merge commit and the workspace of the shadow copy are opened through one piece of code (`src/platform/own_dir.zig`). It opens the directory and the directory above it without following a link, refuses either one when it is a junction or any other reparse point (`WorkspaceIsLink`), and keeps both open in a way that lets no other process rename, delete or replace them until the step is over. The workspace lock refuses a `.emetgate` that is a link by the same name, before it creates its lock file. Inside the journal directory emetgate removes only names it wrote itself: sixteen lower case hex digits followed by `.json`, `.json.tmp`, `.commit` or `.commit.tmp`. A file with any other name is never read as a record and never removed. `emetgate recover` counts a `.json` file in the journal directory whose name is not one of its own as failed and leaves it where it is; when the journal directory or `.emetgate` is a link it stops with `WorkspaceIsLink` and touches nothing behind the link, and a gated write stops the same way before any file changes. A directory is removed only when it is empty and is not a link. The rules ledger in `.emetgate` and the worktree `emetgate verify` adds for the test rerun are not opened through this code.

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
| `no_comment`, `forbid:<text>`, `no_literal:<option>` | Built-in AST checks, run in memory against the file the write produces; see [What a write is checked against](#what-a-write-is-checked-against) |
| `q:<tree-sitter query>` | A tree-sitter query, run in process against the parsed file; see [The `q:` query predicate](#the-q-query-predicate) |
| `added:<check>` | A built-in check or a `q:` query, counted only where the change adds it; see below |
| `cmd:<command line>` | A command, run in the shadow copy inside the sandbox |
| `frozen` | No code is read. The paths in the rule's `--in` scope cannot change through a gated call; see below |

`added:` in front of a built-in check or a query makes the rule judge the change, not the code: its violations are those of the file after the change minus those of the content the writer started from, matched by their text. For a moved file that content is the file at its old path, and it counts only when the rule covered that path; a file that comes into the rule's scope has nothing before it. Under `added:no_comment` a body that keeps a comment that was already there passes and a body that adds one is refused with that one comment as the violation; a second copy of a text the file already holds counts as added, and every violation of a new file is added. `added:` does not take a `cmd:` check. `emetgate scan` and `emetgate_scan` measure code, not a change, and report nothing for an `added:` rule.

```
emetgate rule add "no new comments" --check added:no_comment --enforce
```

`frozen` judges which paths a call changes, not what it writes. Every write tool hands the gate the set of paths it would change before anything else runs: the edited file for `emetgate_try` on a symbol or a node and for `emetgate_write_doc`, every edited, created and deleted file and every rewritten doc of `emetgate_try_batch`, every file a rename or a move rewrites, and both the path a file move leaves and the path it enters. A call that touches a path in the scope is refused as a `rule_violation` that names the rule, the check `frozen` and the path, with and without `--commit`; nothing is written. With no scope the rule freezes every path. It takes no argument (`UnexpectedCheckArgument`) and no `added:` form (`UnknownCheck`). An `advisory` rule refuses nothing. It runs nothing, so a rule from a ledger committed to the repository applies without `--allow-repo-memory`, like `forbid`. There is no built-in frozen path: without such a rule every path can be changed as before.

```
emetgate rule add "the lint config is edited by hand" --check frozen --in .eslintrc.json --enforce
```

This is how you stop the call a code checker judges from loosening that checker. A `cmd:` rule, the typecheck and the tests judge the tree the call produces, and that tree holds their own configuration; emetgate cannot tell the configuration from the code. Freeze the files the checker reads (its config, its script) and they change only by a commit you make yourself.

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

### What a write is checked against

Every file a gated write produces is new in full. A writer may tell the gate which byte
ranges it changed; the gate compares everything outside those ranges with the content the
writer started from, byte for byte, and only bytes that compare equal count as untouched. A
claim that does not hold ends the call with `UntouchedClaimFalse` and nothing is written; it
is never widened to "the whole file is new", because a wrong claim is a defect in the writer.
A writer that makes no claim has its whole file judged.

A match of a rule in the new file is old, and does not block the write, only when all three
hold: it lies wholly in untouched bytes, the rule already covered the file at the path it had
before the write, and the same rule matched the content before the write at the same place.
Every other match is a violation. So a comment that was in the file before a `no_comment`
rule was adopted does not stop an edit elsewhere in that file, a `q:` match that contains
changed bytes is new, and a node the write did not touch is new when it matches only because
of what the write changed beside it. `emetgate scan` and the gate use the same code to decide
which range of a file a rule judges: the whole file, or the body of the symbol for a rule
scoped to `file#symbol`. A rule scoped to a symbol judges that symbol's body in the new file
whichever symbol the call names.

| Tool and edit | What counts as changed |
|---|---|
| `emetgate_try`, `emetgate_try_batch`: a symbol body | the whole new body |
| the same with `hash: absent` | the added declaration; a new file in full |
| `emetgate_try`, `emetgate_try_batch`: nodes | each replaced node, and the whole body of every symbol whose hash changed |
| `emetgate_try_batch`: `op: delete` on a symbol | the place the declaration was cut from; a match that spans it is new |
| `emetgate_try_batch`: `op: delete` on a file | nothing is judged; see leaving a scope below |
| `emetgate_rename` | every occurrence of the new name, in every file the rename rewrites |
| `emetgate_move` | in the target, the moved declaration and the imports derived for it; in the source and in each user file, every import line the move rewrites or adds |
| `emetgate_move_file` | every import specifier the move rewrites, in the moved file and in the files that import it |
| `emetgate_write_doc`, `"kind": "doc"` | the syntax forms do not apply to a file that is not of a registered language; `cmd:` rules, `frozen` and the message rules do |

**Entering a scope.** Content that comes under a rule through the write is new there in full:
a file moved into the rule's directory, a declaration moved into a file the rule covers. An
`added:` rule counts all of it as added.

**Leaving a scope.** A write that takes a file out of the scope of an enforced rule is
refused: a file move whose old path the rule covers and whose new path it does not, the
deletion of the file a rule is scoped to (by path or by `file#symbol`), and a rename, a move,
a deletion or a node edit after which the symbol a rule is scoped to no longer resolves in
its file. The refusal is a `rule_violation` that names the rule, its check and the path, with
the text `leaves the scope <scope>`. A rule is emptied by its owner, with `emetgate rule
supersede` or `emetgate rule forget`, not through the gate. Deleting a file under a directory
scope is not refused, and neither is moving one declaration out of a directory scope; see
Limits.

**Commands.** A `cmd:` rule is due when the write changes a path its scope covers; a rule
scoped to `file#symbol` is due on every write to that file, and a rule with no scope on every
write, document writes included. The command sees the tree and gives the verdict; it is not
told what is new.

**Refusal.** A rename, a move or a file move that breaks an enforced rule is refused whole,
like a batch: no file of it is written. When a rule forbids text the kernel itself derives
(an import path that climbs two directories, for example), that move cannot be made through
the gate until the rule or the target changes.

**Recovery.** Finishing an interrupted commit after a crash writes working files without
running the rules again: the content passed the gate before the commit record was written,
and the working tree is being brought level with a commit that already exists. Three ties are
checked before a byte is written: the staged bytes hash to the value in the record, git
stores those bytes as the blob the record names, and that blob is what the commit on the
branch holds at that path. A record made by hand that fails any of them is not applied.

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
- **Scope.** The gate and `scan` both run the query over the whole file, or over the symbol
  body with `--in file#symbol`; inside that range only nodes that lie wholly in it count. At
  the gate a match is then old or new as described under "What a write is checked against":
  a node that contains changed bytes is new, so a function a query already matched cannot be
  edited inside while the rule stands.
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

### A write that is also a commit

`emetgate mcp --commit` makes every accepted `emetgate_try`, `emetgate_try_batch`, `emetgate_rename`, `emetgate_move`, `emetgate_move_file` and `emetgate_write_doc` one git commit. The model sends the commit message in the same call, as `message`; the tool list shows that argument on these tools, and marks it required, only when `--commit` is on. Without `--commit` a call that carries a `message` is refused (`CommitNotEnabled`), and with it a call without one is refused (`MissingCommitMessage`).

**Before anything runs.** The message is checked against the message rules below. A commit an earlier call or a crash left unfinished is finished first (see "What a crash leaves"); when it cannot be, the call is refused (`CommitStillPending`). Then the repository is checked: `HEAD` names a branch under `refs/heads/` (`DetachedHead`, also for a `HEAD` that points at a tag), the branch has a commit (`NoCommitYet`), no merge, rebase, cherry-pick, revert or bisect is in progress (`OperationInProgress`), no `index.lock` exists (`IndexLocked`), and the repository does not ask for signed commits (`SigningNotSupported`). On Windows a `HEAD` tree that holds two names differing only in letter case, a file and a directory of the same spelling included, is not supported and is refused with `TrackedNamesDifferOnlyInCase`: a volume that ignores case cannot hold both, so the tree could not be tested as committed. The reply names the two paths in `paths`. The names are folded the way the file system folds them (`RtlUpcaseUnicodeChar`) and compared from one listing of the tree, before any file is checked out, so the refusal costs the same on every call and builds nothing. One directory spelled in two cases is not refused: its files land in one directory.

**Each target is measured by its bytes, not by `git status`.** `git status` stays silent about a file marked `assume-unchanged` or `skip-worktree` and about an ignored file, so emetgate does not ask it. For every path the call would write, delete or move:

| The path | Must be | Otherwise |
|---|---|---|
| exists on disk | in the tree of `HEAD` | `TargetNotInHead` |
| exists on disk | the same blob in `HEAD`, in the index and on disk, where the disk side is what `git hash-object --stdin --path` gives for the bytes emetgate read from the file | `TargetHasUncommittedChanges` |
| does not exist on disk | absent from `HEAD` and from the index | `TargetHasUncommittedChanges` |
| carries the `skip-worktree` bit | not a target at all | `TargetSkipWorktree` |

So a hand edit is never committed under the model's message, whether git status shows it or not, and an untracked or ignored file does not enter history through an edit. A path given in another letter case is matched to the tracked name when `core.ignorecase` is on. The letter case of a new file's directories is taken as given. Emetgate reads each target once, hands those bytes to git, and keeps their hash: that hash is the measured state every later step is held to.

**The gate tests the tree the commit will hold.** With `--commit` no tracked name in the gate tree leads to a working file. Every path `HEAD` holds is a file emetgate itself checked out of the object store, through git's checkout filters and with the attributes `HEAD` holds, and the call's own change is written on top. So the working tree is not asked anything: a file edited by hand, with or without a new size or time, a staged file, a file deleted or hidden behind `assume-unchanged` or `skip-worktree`, and a path a sparse checkout leaves out are all tested as `HEAD` has them, and a path `HEAD` does not hold is absent. The rules, the `cmd:` rules, the typecheck and the tests run there. Your uncommitted work in other files is not tested and not committed, and stays in the working tree untouched. A test that only passes thanks to a file you staged but did not commit is rejected. Without `--commit` the gate tree is the working tree, as before.

- **Where the files come from.** `%LOCALAPPDATA%\emetgate\shadow\<key>\committed\tree` holds one file per path of `HEAD` (a submodule entry has none). It is written only by emetgate and lies outside the directory the test command may write. `committed\state` names the tree and the conversion settings the files were checked out under and how many there are. A call whose `HEAD` tree is the one named checks nothing out: it lists the store and the gate tree once each and links by file id, exactly as the kept tree does with working files; the content of every file is then read as the next point says. When `HEAD` has moved, only the paths `git diff-tree` names between the two trees are removed or checked out again, the files written are flushed, and the state is marked before the first file changes, so a call that stops half way is finished by the next one. The whole store is built again when no usable state is found, when the diff touches a `.gitattributes` file, when the number of files in the store is not the number recorded, or when a setting that shapes a checkout has changed: `core.autocrlf`, `core.eol`, `core.symlinks`, `core.attributesFile`, any `filter.*` key, the repository's `info/attributes` and the user-wide attributes file. A change to the system-wide attributes file of the Git installation is not noticed by this state; the reading below then finds every file whose stored form it changed. While the store is updated its directory is held open, so it cannot be renamed away and replaced; a stored file is removed through directory handles that refuse a link anywhere in its path; and git is not told to replace a file that is already there (`checkout-index` without `-f`). A junction put under the store therefore cannot make emetgate delete or replace a file elsewhere: the call is refused with `WorkspaceIsLink` or `CommittedTreeUnavailable`. A file that does not exist yet where such a junction points can still be created there by git when the junction appears between emetgate's check and git's write.
- **The commit is built from the files the gate read.** After the call's own change is written into the gate tree, and before a `cmd:` rule, the typecheck or the test runs, git reads every tracked file of the gate tree: `git hash-object --stdin-paths` with the gate tree as its working tree and a private index that holds `HEAD`, in up to eight processes side by side. The blob names it prints are the tree of the commit. When the gate passes, the tree object is written from that list and from nothing else, so the commit cannot hold a file other than the one the test command was started on. Three things are held to that reading, each before the test runs:
  - A file the call did not propose must store as the blob `HEAD` has. When it does not, the file is checked out of `HEAD` again into the store and the tested file is compared byte for byte with that fresh checkout. Equal means `HEAD` itself holds a form git would normalise (a blob with CRLF under a `text` attribute, for one): the blob of `HEAD` is kept and the call goes on. Different means the gate tree does not hold what `HEAD` holds: the call is refused with `GateTreeNotHead`, `paths` names the files (as many as fit in 512 bytes, `paths_more` counts the rest), and the store has already been mended, so the next call passes.
  - A file the call proposed must hold, in the gate tree, exactly the proposed bytes (`GateTreeNotHead` otherwise), so the commit and the working file written after it cannot part.
  - A tracked file git cannot read, or whose clean filter fails, is named the same way.

  A commit cannot be prepared from a tree that was not read, or for other changes than the ones read (`GateTreeNotDerived`). The attributes that decide a stored form are the ones the gate tree holds, that is the ones of the tree being committed. A clean filter runs with the gate tree as its directory.
- **What the reply says.** `gate_tree` carries `"tracked_files":"head"` on a committing call, with either kind of tree. `--shadow-tree copy`, another volume or a volume without hard links give a full copy made from the same store, never from working files. `--shadow-private <path>` gives the test command a private copy of the stored file.
- **What is not `HEAD`.** A linked directory (`node_modules`) is still the working directory's own files, linked as before, except that a path `HEAD` holds inside it comes from the store. So the committing gate guarantees every tracked byte and nothing else: an untracked or ignored file in a linked directory is whatever is on disk when the test reads it, a hand edit to one is tested, and an untracked or ignored file outside a linked directory is absent from the gate tree.
- **What it rests on.** The gate does not compare working files with anything, and it does not take the files under `committed\tree` on trust either: every call reads them. The test command runs at low integrity and cannot write the store; a name it deletes or replaces in the gate tree is found by its file id on the next call, and a file missing from the store is found by the count. What still rests on your own account: a process with your rights can change a file of the gate tree after it was read, while the rules, the typecheck or the test run, or change it before the reading and put it back in time. The test would then have run on bytes the commit does not hold, and nothing notices. Such a process can also replace `git.exe`, write git objects, or change emetgate's own memory.
- **A checkout that fails.** A checkout filter that fails gives `CommittedTreeUnavailable`; a store that does not hold one file per path of `HEAD` gives `CommittedTreeIncomplete`.
- **Two trees, two places.** The gate tree of a committing call is `<key>\committed\shadow`; the kept tree of working files, used by `emetgate_run` and by every call that does not commit, stays at `<key>\shadow`. Neither is touched by the other kind of call, so a server with `--commit` and one without it on the same repository, or `emetgate_run` between two commits, cost no relinking. `emetgate recover` removes both and the store.
- **Cost.** Measured on 2026-10-07 on the development machine with a ReleaseSafe build, on a clone of n8n (29,131 tracked files, 206 megabytes), median of 7 later calls with their range. A committing call whose test fails (`cmd /c exit 1`): 2.74 s (2.59 to 3.15) with 18 git processes, against 0.66 s (0.63 to 0.84) with 2 git processes for a call that does not commit. Before every tracked file was read on each call the same call took 1.15 s (1.11 to 1.34) with 7 git processes; the difference, about 1.6 s, is the reading: eight `git hash-object` processes over the 29,131 files, one for the call's own file and one `git read-tree`. A committing call whose test passes: 5.74 s (5.36 to 6.83) with 32 git processes, the commit and the update of the store for the next call included; before, 3.49 s (2.88 to 5.49) with 22. The first committing call took 33.9 s: git checks the files out with its parallel workers, they are flushed, the tree is linked and then read. The reading grows with the number and size of the tracked files, and a `filter` driver's clean command runs for each of its files on every committing call. The store is a second copy of the tracked files on disk.

**The commit object.** When the gate passes, the commit is built from that reading: a private index file is filled from the list of blob names (`git update-index --index-info`), `git write-tree` writes the tree and `git commit-tree` the commit. The blobs of the call's own files are written when they are read, before the test runs, so a call the test rejects leaves those blobs in the object store, unreachable, as `git add` followed by `git restore --staged` would; a call refused by a measurement leaves no object behind. With `core.safecrlf=true` git refuses to store a file whose line ends it could not give back, and the call is refused with `GitFailed` before the test runs. The blob is the tested file in the form git stores it for that path, the same blob `git add` would write: line end conversion, `ident` and the clean filters of `.gitattributes` apply. With `core.autocrlf` on, a file tested with CRLF line ends is stored with LF, `git status` is clean after the commit and `git diff HEAD` is empty. The message is stored as UTF-8 whatever `i18n.commitEncoding` says. A file keeps the mode it has in `HEAD`, and a moved file takes the mode of the path it left. A change that leaves the tree as it was is refused (`NothingToCommit`).

**The decision is the branch move, and every write is held to what was measured.** Nothing that cannot be undone happens before the branch moves, and nothing is changed that is not still what emetgate measured:

1. Every target that exists is opened with a handle that lets other processes read it and nothing else: until the write is done no other process can write to it, delete it, rename it or rename another file over it (their tool reports the file as in use). The bytes behind that handle must be the bytes that were measured and that the change was computed from; otherwise the call is refused (`TargetHasUncommittedChanges`) and the file stays as the user left it. A target the call creates has no file to hold; its write is the condition (step 6).
2. An intent record is written to `.emetgate\intents`, with the commit, the commit it replaces, the branch, the SHA-256 of the index it was prepared against and of the index it prepared, every path with its old and new content hash, and a copy of the bytes to write.
3. The new index is built in a copy of the index. Before anything is put into the copy, the entry of every target in it must be the entry that was measured, the blob of `HEAD` with no flag and no conflict, or absent for a file the call creates; a change staged on a target since the measurement is found here and the call is refused (`TargetHasUncommittedChanges`), with the staged entry untouched. The copy is then moved into place as `.git\index.lock`. That is git's own lock: while it is there, the commands of another process that write the index, `git commit` and `git checkout` among them, fail at once instead of interleaving. A lock that is already there is refused (`IndexLocked`) and never touched. An index that changed between the copy and the lock is not replaced; the step is tried again. Emetgate keeps the handle of the lock file it created, and no other process can remove or replace that file while the call runs.
4. The branch `HEAD` names is read before the record is written, so the commit lands on the branch checked out at this moment, and it is read once more under the lock, where `git checkout` can no longer change it (`BranchMoved` if it did in between). `git update-ref` moves that branch from the commit that was measured to the new one. If it does not move, nothing was written: the lock and the record are removed and the call is refused, with `BranchMoved` when someone else's commit is there, or `BranchUpdateRefused` when the branch is where it was and git refused the update (a `reference-transaction` hook, a ref lock).
5. The lock file is renamed to `index` through the handle emetgate kept, which publishes the index and releases the lock in one step; a lock file that is not the one emetgate created cannot be published this way. The rename is tried again for half a second when another process has the index open.
6. The files are written with the same journal as every other write, each in two moves through handles: the held file is moved aside to a backup name beside it, and the new file is put at the path only if nothing is there. For about half a millisecond the path has no file. If another process creates a file at the path in that gap, that file is kept, the write of this path is given up and named (`TargetChangedAfterCommit`), and the backup is removed, because its bytes are the ones the replaced commit holds. A file the call creates is put in place the same way, and a file it deletes is deleted through the handle that was checked. Every write of an existing file is made in these two moves, also without `--commit`. There, when another process creates a file at the path in the gap, the call fails with `Conflict`, the file that was created is kept, and the old bytes stay beside it as `<file name>.emetgate-<16 hex digits>.bak` in the same directory: without a commit they exist nowhere else, so emetgate does not remove them. `emetgate recover` leaves both files as they are and reports no failure for them; it removes only its own `.tmp` files. You settle it by deleting the `.bak` file or by renaming it back over the path.
7. The record is removed and the receipt is attached to the commit. Nothing is asked of git again after the index was published when every file was written.

The reply carries the commit id as `commit` whenever the branch moved. When a later step did not finish, the same reply also carries `commit_unfinished` with the step: `IndexNotPublished` (the lock is still held and the record stays, the next call or `emetgate recover` finishes it), `IndexLocked` or `IndexNotUpdated`, `FileNotWritten`, or `TargetChangedAfterCommit` together with `files_left_as_found`, the count, and `left_as_found`, the paths. In that last case the commit is complete, the index holds it, and the file shows in `git status` as your modification on top of it; nothing of yours is overwritten. When the recovery that runs at the start of a call left something as it found it, the reply of that call carries `recovered` with the reason and `recovered_left_as_found` with the paths; the same finding at the start of `emetgate mcp` is printed to standard error.

Emetgate builds the commit with git's plumbing commands, so `pre-commit` and `commit-msg` hooks do not run and the commit is not signed. A `reference-transaction` hook does run, and can refuse the branch move. A check a hook did belongs in the test command or in a rule.

A call that touches several files is still one commit: every file a batch, a rename or a move edits, creates or deletes is in it, and a moved file leaves its old path and enters its new one in the same commit. Every write tool goes through the same code for these steps.

**Receipts.** The digests in the receipt of a `--commit` write are taken from the blobs of the commit and of its parent, and its symbol hashes from the same blobs, so `emetgate verify` accepts the commit under a line end conversion too. Only the receipt of the call is attached to its commit, by its id; an older pending receipt for the same path is left where it is. `emetgate_write_doc` has no receipt, with or without `--commit`, so its commit carries no receipt note, and `emetgate_try_batch` does not list a rewritten doc in its receipt: `emetgate verify` reports such a commit as `unverified` ("no receipt covers this change"), never as `verified`. Outside `--commit` the receipt digests are taken from the working tree file, as before, and `verify` accepts those under a line end conversion too: see the checked-out form below.

#### What a crash leaves

`emetgate recover`, the start of `emetgate mcp`, and the start of every `--commit` call first finish or undo a file write the journal shows was cut short, then read the intent records and finish each one. What a record may do is derived from the commit it names, never from what the record says about itself. The record must name a commit with exactly one parent, that parent must be the commit the record says it replaced, and the commit must hold, at every path of the record, the blob the record names; anything else is `CorruptIntent`, counted as failed and removed. Then, for each path:

| The process died | What is there | What recovery does |
|---|---|---|
| before the branch moved | the record, perhaps the lock | removes both; nothing was written |
| after the branch moved, before the index was published | the commit, the lock, the old files | publishes the index, writes the files |
| between the two moves of a file write | the commit, the new index, no file at the path, the old bytes under a backup name | puts the old file back, then writes the new one |
| after the index was published | the commit, the new index, some old files | writes the files that still have their old bytes |

- **The index entry** is written only when emetgate can show nothing touched the index since it prepared the commit: its own `index.lock` is still there (compared by SHA-256) and `HEAD` is on the commit, or the index file is byte for byte the one the record was prepared against. An entry that already holds the commit's blob needs nothing. In every other case, after you removed the lock and any command rewrote the index, the entry is left as it is, the path is named (`IndexChangedAfterCommit`) and its file is not written either; `git reset -- <path>` or `git add <path>` settles it your way.
- **The file** is written only when the checked out commit and the index hold the commit's blob at that path and the file on disk is still the replaced commit's: its bytes, as git would store them, are the blob of the commit's parent, and they are the bytes the record noted. A file with any other content is left and named (`TargetChangedAfterCommit`). A file that is missing with emetgate's backup beside it, the trace of a crash between the two moves, is put back by the journal first and then written.

After recovery `git status` is clean, apart from files you edited yourself and entries you staged yourself. `emetgate recover` prints a second line when it found a record: commits completed, dropped undecided, files written, files left as found, still pending, failed, the name of the last reason, and the paths it left. It exits 16 while a commit is still pending.

Until recovery runs, the lock of a commit that died between steps 3 and 5 keeps git's index commands refused, with git's own "index.lock exists" message. Emetgate removes or publishes that lock only when its content is byte for byte the index it prepared, which the record names by SHA-256. Any other `index.lock` is left alone, and the commit stays pending (`IndexLocked`) until it is gone.

**Emetgate's own directories are never reached through a link.** `.emetgate\intents`, `.emetgate\journal`, `.emetgate\commit`, `.emetgate\receipts` and the workspace of the shadow copy are opened through one piece of code. It opens `.emetgate` and the directory below it without following a link, refuses either one when it is a junction or any other reparse point (`WorkspaceIsLink`), and keeps both open in a way that lets no other process rename, delete or replace them until the step is over. The workspace lock refuses a `.emetgate` that is a link by the same name, before it creates its lock file. Inside these directories emetgate removes only names it wrote itself: sixteen lower case hex digits followed by one of its own endings (`.json`, `.json.tmp`, `.index`, `.<n>.new` for an intent; `.json`, `.json.tmp`, `.commit`, `.commit.tmp` for the journal), and `index`, `index.lock`, `message` and `blob-<n>` in `.emetgate\commit`. A file with any other name is never read as a record and never removed. `emetgate recover` counts a `.json` file in the journal directory whose name is not one of its own as failed and leaves it where it is. A directory is removed only when it is empty and is not a link. The rules ledger in `.emetgate`, the work directory of `emetgate verify` and the message file in the shadow copy are not opened through this code.

What you do with git before recovery runs is respected:

- You remove the lock and commit before the index was published: your commit is made from the old index, so it undoes the change in history. Recovery sees that the checked out commit does not hold the new blobs, writes nothing and removes the record. The tree is clean.
- You commit, or make a branch, after the index was published: your commit holds the change. Recovery writes the files it holds. The tree is clean.
- You run `git reset --soft` to the commit before, while the lock is held: recovery removes the lock, writes nothing and removes the record. The tree is clean.
- You edit a target, or change only its line ends: it is left as found and reported (`TargetChangedAfterCommit`).
- You stage something on a target: the entry is left as you staged it and reported (`IndexChangedAfterCommit`).

Limits, each one as measured by a test or named as not measured:

- `git reset --soft` to the commit before, after the index was published, keeps the published entries staged, as a soft reset is defined to do. Recovery writes nothing; `git status` shows the staged change.
- `git update-ref` and `git reset --soft` do not take the index lock, so they can move the branch during steps 4 to 6 of a running call. The files are then written by the rule of step 6 against the commit `HEAD` names at that moment.
- A commit completed by recovery has no receipt, because the receipt is written after step 6. `emetgate verify` reports it as `unverified`.
- A repository with a split index is covered by a test. A sparse index, and a git directory on another volume than the working tree, are not measured.
- A record that arrives with a clone, or that someone wrote by hand, can at most bring a file and an index entry that are exactly at the parent of the checked out commit up to that commit. It cannot write over bytes that are not already in a commit: the hash it claims for the file is not what decides.

### Rules for a commit message

A check that starts with `message:` judges the commit message of a `--commit` write, not code. The kernel itself asks only what git needs of a message: it is not blank, it is valid UTF-8, it has no NUL byte and it is at most 16 KiB. Everything else is a rule the user adds, and with no rule any message git accepts passes.

| Check | A violation is |
|---|---|
| `message:forbid:<text>` | each place the exact text stands |
| `message:forbid_any_case:<text>` | the same, in any letter case (ASCII) |
| `message:require:<text>` | the text is missing |
| `message:require_any_case:<text>` | the same, in any letter case (ASCII) |
| `message:max_lines:<n>` | the lines after the nth; line ends at the end of the message do not count |
| `message:max_subject:<n>` | the characters of the first line after the nth |
| `message:max_line:<n>` | the characters after the nth, on every line that has them |

```
emetgate rule add "one line" --check message:max_lines:1 --enforce
emetgate rule add "signed off" --check "message:require:Signed-off-by:" --enforce
emetgate rule add "short subject" --check message:max_subject:72 --enforce
```

A message rule takes no `--in` scope (`MessageRuleWithScope`) and no `added:` form. It is not listed in a file's skeleton and `emetgate scan` reports nothing for it. A violation comes back as `rule_violation` with the rule id, the check, the line and column in the message and the text, before any test runs.

`message:cmd:<command line>` hands the message to a checker of your own. The message is written, as git will store it, to the file `.emetgate\COMMIT_EDITMSG` in the shadow copy, and the command runs there like any `cmd:` rule: same sandbox, same limits, same outcomes table, the shadow copy as its working directory. The command names that file itself, as an argument or redirected to standard input. That is the contract of git's own `commit-msg` hook, which passes the path of the message file, and both forms below are the ones the two tools document:

```
emetgate rule add "gitlint" --check "message:cmd:gitlint --msg-filename .emetgate\COMMIT_EDITMSG" --enforce
emetgate rule add "commitlint" --check "message:cmd:npx commitlint < .emetgate\COMMIT_EDITMSG" --enforce
```

commitlint's `--edit <file>` resolves the path against the git top-level it finds above its working directory, which from a shadow copy is not the shadow copy; its standard input has no such step. Neither line above is run by emetgate's own tests, which use `findstr` in both forms.

A message command runs after the text rules and the repository checks, in the gate tree as it stands before the call's own change is written into it, and before the `cmd:` rules, the typecheck and the tests; the message file is removed before those start. So a call cannot loosen, in the same commit, a file its message checker reads: a call that rewrites the allow-list of a checker and uses the loosened prefix is judged by the list as it was. To change what the checker allows, change its file in one commit, under the rules in force, and use it in the next. What the command sees is exactly this: at every path `HEAD` holds, the file emetgate checked out of the object store for `HEAD` (see "The gate tests the tree the commit will hold"), so neither this call's change nor anything in the working tree, staged or not, reaches a tracked path; in a linked directory, the working directory's own untracked and ignored files; the message in `.emetgate\COMMIT_EDITMSG`; and nothing else. The command's working directory is the root of that tree. A checker that reads an untracked or ignored file in a linked directory reads what is on disk at that moment. Exit code 0 passes; any other exit is a `rule_violation` whose text is what the command printed, with no position; a command that cannot run is `rule_check_crashed`. A command from a ledger committed to the repository does not run without `--allow-repo-memory` (`UntrustedRepoMemory`), exactly as a `cmd:` rule. Without `--commit` there is no message and the command does not run. A repository that tracks a file at `.emetgate\COMMIT_EDITMSG` is refused (`MessageFileInTheWay`). The message reaches the command on every tool that commits.

### Rules are readable by the model, never writable

`emetgate_skeleton` returns, beside the outline, every adopted rule that covers that file:
its id, its text, whether it is `enforce` or `advisory`, its predicate and its scope. The
model reads the rules before it writes a body, so it can obey them instead of proposing a
violation, getting rejected and trying again.

Rule management is available only to the user: from the command line, and as `/rule` typed
in a session started by `emetgate lockdown` (see "Rules from the prompt" under Lockdown). The
model-facing tools cannot adopt, change or remove a rule, or change an `enforce` rule to
`advisory`; under lockdown a command run through `emetgate_run` could, and the `PreToolUse` hook asks the user before an `emetgate rule add`, `supersede` or `forget`. A test (`red line: the served tool surface is exactly this list`) pins the served
tool names and fails if another tool is added. A second test verifies that the dispatcher
rejects rule-writing tool names.

When `emetgate rule` refuses a check it does not know (`UnknownCheck`), it prints the names
that exist before the error: `no_comment forbid no_literal q frozen cmd: added:` and the `message:`
checks. When `supersede` or `forget` names an id that is not active (`DecisionNotActive`), it
prints the active rules, in the `rule list` format, before the error.

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
| `emetgate_explore` | For a question and optional names: every definition of each named symbol whole, then the functions and top-level constants ranked by BM25 over names, paths and bodies. A ranked definition is sent whole while its size costs less than the model call it may save; the others are listed by address. A named class is listed and shown through its matching members. Every line carries its number. No call graph is used |
| `emetgate_evidence` | The full code of up to 6 names. A name defined in several files returns every definition; `file.name` picks the definition in that file; an accessor is found by its bare name. A name that is not a symbol is reported with the closest symbols, and names past the limit are listed |
| `emetgate_symbols` | Symbols in a file, with references, positions and content hashes |
| `emetgate_skeleton` | Signatures and structure without bodies, a C# `=>` body shortened like a block, plus every adopted rule that covers the file (read-only) |
| `emetgate_read_symbol` | The source of one symbol, declaration or statement, several at once, or a line range widened to the symbols it overlaps; a body over the read budget comes back folded (see Reader); with `nodes:true`, each declaration (or exactly the requested lines) with a node hash on every line that starts a node |
| `emetgate_mutate` | Verify a proposed body structurally and return the result without writing |
| `emetgate_try` | Verify, gate and commit a proposed body, or new text for one or more syntax nodes addressed by their hash |
| `emetgate_try_batch` | Several proposals as one unit |
| `emetgate_rename` | Rename a function, method, class, field, interface, type, enum or variable and every reference to it; the TypeScript language service proposes the locations, the kernel proves the result and commits it as one batch. Also takes a Python or C# file, where the references come from the kernel's own cross-reference facts |
| `emetgate_move` | Move a top-level declaration to another file; the kernel derives and checks every import and commits source, target and users as one batch |
| `emetgate_move_file` | Move or rename a file and rewrite every relative import to and from it as one batch |
| `emetgate_write_doc` | Verify, gate and commit a hash-checked write to one node of a non-code file: a JSON pointer's value, a Markdown section or a text line range; a file of a registered language is refused (`UseSymbolToolsForSource`); can commit together with a code edit in `emetgate_try_batch` |
| `emetgate_read_file` | For one file, or up to 32 in one call: a JSON key tree or one pointer's value, a Markdown heading tree or one section, a line range of any other text file, or (with `raw:true`) the file verbatim or a line range of it, source files included; confined to the repository |
| `emetgate_list`, `emetgate_search` | Reads confined to the repository |
| `emetgate_find` | Every place a literal text occurs in the project's files, from a prebuilt index (see Find) |
| `emetgate_scan` | Measure one check expression against the repository, optionally within a `where` scope; writes nothing |
| `emetgate_git` | Read-only `status`, `diff`, `log`, `show` or `blame`, with a fixed argument list and safe overrides so nothing configured in the repository (pager, external diff, textconv, fsmonitor, a `clean`/`smudge` filter) can run; output is capped. `diff` and `show` answer compactly by default: per file its added and removed line counts and changed symbols (`+` added, `-` removed, `~` changed), then only the changed lines without context, with a rename repeated on several lines folded to `@lines old->new`, all under the read budget (`detail:"full"` for every hunk with `symbol_changes`, `symbols_only:true` for `symbol_changes` and no lines); `blame` reads one `git blame --porcelain` pass (up to 32 MiB, so a file of any size answers) and replies with `symbol_blame`, the commit that last touched each symbol, then `ranges` (`"first-last commit8"` for each run of lines from one commit) and `commits` (`commit8` to author, date and subject); the reply stays under the read budget and, when cut, gives `symbols_left`, `ranges_left` and `next_line` to continue from with `line_start`/`line_end`. `symbols_only:true` drops the ranges; `line_start`/`line_end` or `detail:"full"` give per-line `line commit text` instead. `commit` blames the file as it was at that commit (HEAD or a hash, optionally with `^` or `~N`) and maps the symbols in that version. When git itself fails, the error carries git's first stderr line as `message`; output over the cap is `GitOutputTooLarge`, not a generic failure. With `args`, `emetgate_git` runs any read-only form of `log`, `diff`, `show`, `status`, `grep`, `ls-files`, `reflog`, `describe`, `shortlog`, `rev-parse`, `rev-list`, `merge-base`, `cat-file`, `for-each-ref`, `ls-remote`, `cherry` or `count-objects` with the same flag lists as `emetgate_git_write`, `--no-optional-locks` and no lock; a form that changes the repository (`reflog expire`) is refused with `not_read_only`, and the reply is the last 200 lines within the read budget with `exit_code` (exit 1 with no stderr, as from `grep` with no match, is not a failure). `status` lists unmerged paths in a `conflicted` group. `log` marks each commit `receipt` when a receipt note is attached and `no_receipt` otherwise; `receipt` does not mean the receipt holds, only `emetgate verify <commit>` checks that. Every git child emetgate starts has stdin closed, runs in a job that is killed on return, and is stopped after 120 s (180 s for `fetch`, `pull` and `push`) |
| `emetgate_git_write` | Changes the repository with git: `args` is the git argument list (a string is split on spaces; a leading `git` is dropped) for `branch`, `switch`, `checkout`, `tag`, `stash`, `add`, `rm`, `mv`, `commit`, `restore`, `reset`, `merge`, `rebase`, `cherry-pick`, `revert`, `fetch`, `pull`, `push`, `init`, `clone`, `remote`, `config`, `clean`, `worktree`, `submodule`, `apply`, `am`, `format-patch` or `bisect`, and the read-only forms listed under `emetgate_git`. Each subcommand has its own flag list, read flag by flag (short clusters such as `-fd`, attached values such as `-mfix` or `--message=x`, counts such as `-U3`); any other flag, subcommand or action is refused (`unsupported_flag`, `unsupported_subcommand`, `unsupported_action`), so nothing runs a program (`rebase --exec`, `--upload-pack`, `-c`, `bisect run`, `submodule foreach`), skips hooks (`--no-verify`) or picks an unknown merge strategy (`unsupported_value`). Paths, `init` and `clone` targets, worktree and patch paths, and local remotes must resolve inside the root and outside `.git` (`outside_root`); a remote is an `https`, `http`, `ssh`, `git` or scp-like URL or a local path, and a `::` transport such as `ext::` is refused (`unsupported_url`). `config` reads any key but writes only a fixed list (`user.*`, `core.autocrlf`/`eol`/`safecrlf`/`ignorecase`/`filemode`/`quotepath`/`whitespace`, `init.defaultBranch`, `pull.*`, `push.*`, `fetch.prune*`, `merge.ff`/`conflictstyle`, `rebase.*`, `rerere.*`, `diff.renames`/`algorithm`, `status.showUntrackedFiles`, `tag.sort`, `branch.sort`, `log.date`, `commit.cleanup`, and `branch.<name>.*` and `remote.<name>.*` with a remote URL checked as above); any other key, such as `core.hooksPath` or `alias.*`, is `unsupported_config_key`. `.emetgate` never enters a git write: `add` (with `-A`, `-u` or paths, `-f` included), `stash` and `stash push` (with `-u` or `--all`) and `clean` get the pathspec `:(exclude,icase).emetgate`, relative to the served root, with `:/` (or `.` for `clean`) when the call names no path, so neither the index, a stash nor a cleanup takes or removes it in a worktree, a clone or a subdirectory root, and `commit -a` stages only tracked files, which `.emetgate` then never is; `stash save` is refused in favour of `stash push`. A form that discards uncommitted work or rewrites a remote is refused with `would_lose_work` unless `force:true`: `reset --hard`, `restore` of the working tree, `checkout` of paths, `switch --discard-changes`, `stash drop`/`clear`, `branch -D`, a forced or deleting `push` and a `+` or `:` refspec, `clean` without `-n`, `rm -f`, `remote remove`, `worktree remove` or `add -B`, `submodule deinit` and `reflog expire`/`delete`. No editor, pager, credential prompt or auto gc runs: the child gets `GIT_EDITOR=:`, `GIT_SEQUENCE_EDITOR=:`, `GIT_PAGER=cat`, `GIT_TERMINAL_PROMPT=0`, `GIT_MERGE_AUTOEDIT=no` and `GCM_INTERACTIVE=never`, loses `GIT_EXTERNAL_DIFF`, the askpass and SSH command variables and injected config, and runs with `protocol.ext.allow=never`; the call holds the shadow lock. The reply gives `status` (`ok`, `failed` or `refused`), `exit_code`, `head`, `branch`, `from` and `shortstat` when HEAD moved, and the last 40 lines of output |
| `emetgate_run` | Run one command from the allowlist the user gave (`--allow-run`) in a shadow copy, under the test gate's sandbox; nothing reaches the working tree and output is capped. A toolchain command (install, build or check for npm, pnpm, yarn, bun, pip, uv, dotnet, cargo or go; see below) runs in the repository itself, with the user's rights, without an allowlist entry |
| `emetgate_edit` | Replace an exact `old_string` (unique unless `replace_all`) with `new_string` in any file, through the gate |
| `emetgate_write` | Create or overwrite a whole file, through the gate |
| `emetgate_commit` | Commit the pending gated writes as one commit built from HEAD, with a receipt note attached; refused, naming the files, if a file changed outside the gate since its receipt; refused as `TargetHasUncommittedChanges`, naming the file, with a `fix` that unstages it with `emetgate_git_write` `restore --staged`, if the index holds a staged copy of a file that no gated write produced (what the gated creates, moves and deletes left in the index is committed); and refused as `TestsFailing`, naming the tests, while a test that passed or did not exist when the session started fails. The CLI form is `emetgate commit -m <message>` |

**New symbols and new files.** A proposal with `"hash": "absent"` adds one top-level declaration (a function, class, interface, type alias, enum or a variable with one declarator): to the end of an existing file, or as the only content of a file that does not exist yet. `emetgate_try` and `emetgate_try_batch` both accept it, and in a batch it commits or rolls back together with the other edits. A new file is journaled as a create intent, placed with a rename that never replaces an existing path, and added to the git index after the commit point; if another process puts a file at that path before the commit, the batch is refused with `Conflict` and that file is kept. Recovery deletes an uncommitted new file only while it still has the journaled hash, and indexes a committed one. For each such edit the batch result carries `class` (`symmetry` or `unclassified`) and the evidence behind it: the file parses, the new name is mentioned nowhere else in the batch or the tracked files, the declaration has no top-level effect (no call, `new`, assignment or decorator outside a function), and, for a new file or an exported symbol, no other file mentions the module. The test gate still runs for every batch, whatever the class. Limits: the parent directory must already exist, one batch creates a path at most once and cannot also edit it, and the reference check is a whole-word text match, so it errs toward `unclassified`. If `git add` fails after the commit, the files stay on disk and the result is `WrittenButNotIndexed`.

**Deleting symbols and files.** A batch edit with `"op": "delete"` removes something. With `symbol` and `hash` it removes one top-level declaration and its line from a file that stays; the edit is refused with `TopLevelEffect` if the declaration runs code when the module loads, and with `SymbolReferenced` if something still uses the name. When the repository's TypeScript language service is available (see renaming below), it answers that question with `findReferences`: any reference outside the declaration, in a file the batch does not rewrite, refuses the delete; a file the batch rewrites is judged on its new text; and a string literal elsewhere that is exactly the name (`obj["name"]`) refuses it as possible dynamic access, since the language service cannot see that. A name that only a comment mentions no longer blocks the delete. Without the language service the text scan from before stays in force: the name must not be mentioned anywhere else in the batch, in the rest of its file or in the tracked files (or, for an exported symbol, the module in another file). Without `symbol` it deletes the whole file; `hash` is then required and must be the `file_hash` that `emetgate_read_file` or `emetgate_skeleton` reported for that file, so the model cannot delete a file whose content it has not seen or that changed since (`MissingFileHash`, `HashMismatch`). The file stays in place until the commit point, is then deleted through the handle that checked its content, and is removed from the git index. If recovery finds a committed deletion whose file has changed since, it leaves the file alone. The test gate runs on the tree without the file. Limits: while a batch holds a file it refuses other writers but lets another process rename or delete it, since the atomic replace needs delete sharing; such a rename is not detected until recovery checks hashes. A symlink or junction is never deleted (`ReparsePoint`), a declaration that shares its statement with another name (`const a = () => 1, b = () => 2`) cannot be removed alone, and members cannot be removed yet.

**Writing a node of a non-code file.** `emetgate_write_doc` takes `file`, `hash` and `content`, plus exactly one of `pointer` (a JSON pointer, e.g. `/dependencies/express`), `heading` (a Markdown section by its exact heading text) or the `line_start`/`line_end` pair (a plain text line range). `hash` is the content hash of the current node, from `emetgate_read_file`; a stale or wrong hash is refused (`HashMismatch`) before anything is parsed. The replacement is checked before it is written: a JSON value must itself parse as valid JSON, and after the splice the whole file is re-parsed and the same pointer must resolve back to exactly the bytes written, byte for byte, catching a value that reparses differently than it reads (for example, a trailing space a JSON number's span would not include); a Markdown replacement must itself start with a heading line of some level, and after the splice the edited section's node must end exactly where the replacement's own text ends — an unclosed code fence or HTML block in the replacement that swallows a later heading, or anything else that shifts where the section boundary falls, is refused (`DocSyntaxInvalid`) and nothing is written. A file over 1 MiB or one that looks binary is refused before it is parsed at all. The write runs through the same jailed path, shadow copy and test gate as `emetgate_try`, and commits through the same journaled atomic replace. In `emetgate_try_batch`, an edit with `"kind": "doc"` uses this same shape (`file`, `hash`, `content`, one selector) instead of `symbol`/`body`, and can commit alongside ordinary code edits in the same all-or-nothing batch, through the same journal and commit record. A batch may also hold doc edits only.

A doc edit is for documents, not for code. When the file's extension belongs to a registered language (TypeScript, TSX, JavaScript, Python, C#, Zig), `emetgate_write_doc` refuses the call and `emetgate_try_batch` refuses the whole batch with `UseSymbolToolsForSource` (exit code 18), whichever selector is used: the check runs on the resolved path of every doc edit before any edit of the batch is planned, so no rule or test runs and nothing is written. Code is changed through a symbol or a node edit, which is where the rules are applied. This is the same line `emetgate_read_file` draws when it is asked for a source file without `raw:true`; a hash from a `raw:true` read does not open a write.

No rule runs because of a doc edit. The built-in checks, `q:` queries and their `added:` forms need a parsed source file and a symbol, and a `cmd:` rule is started by a symbol or node edit that its scope covers; in a batch that also has such an edit the command sees the shadow copy with the doc edit applied. A doc edit leaves no receipt: a batch of doc edits only writes none, and the receipt of a mixed batch covers its code files.

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


`emetgate lockdown` starts Claude Code with only these tools available. Its `emetgate_run` runs any command (see "Any command under lockdown" below), so a command the model runs reaches the disk with the user's rights and outside the gate's checks; the gate judges the edits made through its write tools, and every command lands in the event log with its exit code. With `emetgate_git` in that set, the model can see what changed and why.

**Running allowed commands.** `emetgate_run` lets the model run the commands the user allowed, such as `npm test`, `npm run lint` or `zig build`, which lockdown otherwise leaves it no way to run. The allowlist comes only from the user: `emetgate mcp --allow-run "<command>"`, repeatable, the test command given with `--test` or found by `--detect-test`, and the `run` list of `.emetgaterc.json` when the server was started with `--allow-repo-config`. The model names a command by its exact text; a request that is not byte for byte one entry is refused with `not_allowed` and the allowlist, and nothing is added, joined or expanded. A request or an entry with a shell metacharacter (`&`, `|`, `<`, `>`, `^`, `%`, `!`, `;`, a backtick, `$`, `(`, `)` or a line break) is refused, and so is a call that names a policy field (`allow_run`, `test_cmd`, `typecheck_cmd`, `allow_repo_config`, `allow_repo_memory`, `shadow_root`). The command runs through the same code as the test gate: the same shadow (the kept tree unless the server was started with `--shadow-tree copy`), `cmd.exe /d /c <command>` under the low-integrity token and job, the same 60 s timeout, 1 MiB output cap and leftover check; if the token cannot be built the call is refused with `sandbox_unavailable` and the command does not run. What the command writes in the shadow never reaches the working tree: in the kept tree it is removed before the next command runs there, and a full copy is deleted after the call. The result gives `gate_tree` (which tree was used, as for the test gate), `outcome` (`exited` with `exit_code`, `crashed` with `crash_code`, `timed_out` or `output_limit`), `killed_leftovers`, and the last 200 lines and 16 KiB of each stream with the number of lines left out. Toolchain commands are the exception: an install, build or check with npm, pnpm, yarn, bun, pip, `python -m pip`, uv, dotnet, cargo or go (and `npx`, `tsc`, `eslint`, `pytest`, `mypy`, `ruff`) is recognised by its program and subcommand and runs in the repository itself with the user's own rights (not the low-integrity token, since it has to write there), under the shadow lock, with a 600 s timeout, a 4 MiB output cap and no allowlist entry; when it exits 0 and changed files, the reply gives `files_changed` and a `receipt` naming them. The `fix` of a refused call lists the accepted forms. As an `--allow-run` entry, still out of scope and refused: installing dependencies (`npm install`, `npm ci`, `pnpm i`, `yarn add`, `pip install` and their aliases), because an install fetches packages, runs their install scripts and rewrites the linked `node_modules`, and `git commit` or `git push`, which go through `emetgate_git_write`. With no entry at all, the allowlist reply carries a `fix` naming `--test` and `--detect-test`.

**Any command under lockdown.** The allowlist above is what `emetgate mcp` serves. `emetgate lockdown` starts its server with `--open-run`, and then `emetgate_run` takes `command` (any shell command), `raw` (boolean) and `timeout_s` (1 to 600; 120 by default, 600 for the test command). The command runs in the repository root with the user's own rights, through Git Bash (`bash.exe` beside the `git` found on PATH, as `bash -c <command>`) when it is installed and through `cmd.exe /d /s /c <command>` otherwise; the reply names the shell in `shell` (`git bash` or `cmd`). There is no allowlist, shadow, low-integrity token or metacharacter check in this mode: pipes, `&&` and redirects work as in a terminal. The reply gives `status` `ran`, `command`, `shell`, `exit_code` (or `outcome` `crashed`, `timed_out` with `timeout_s` and a `fix`, or `output_limit` past 16 MiB), `duration_ms`, `files_changed` and a `receipt` when tracked or untracked (not ignored) files changed, and `content`. A nonzero exit is a normal reply, not a tool error. The output is cut by what ran, and every cut says so in the text:

| Command | What `content` holds |
|---|---|
| `git ...` (also behind `cd x &&`, `env`, `sudo` or a path) | The output without line-ending warnings, `hint:` lines, `remote:` chatter, object counting and other progress lines, then `[emetgate: N git noise lines dropped (...); raw:true returns all]` |
| The test command (`--test`, or the one `--detect-test` finds) or a known test runner (`pytest`, `npm test`, `cargo test`, `go test`, `dotnet test`, `zig build test` and others) | A passing run is one `ok: ` line with the summary. A failing run keeps the failing tests as the test gate's digest does and says how many lines of passing tests and runner noise were cut |
| `cat`, `sed`, `head`, `tail`, `type`, `Get-Content` and other file printers | Up to 16 KiB: the head and the tail, with `[emetgate: N lines (B bytes) cut; raw:true returns all]` between them |
| Anything else | The same, up to 4 KiB |

stderr follows stdout after a `[stderr]` line. When anything was cut the reply adds `output_bytes` and `full_log`, a call (`emetgate_run command="log <id>" raw=true`) that returns the whole output, kept under `.emetgate`. `raw: true` returns the output uncut up to 64 KiB, again with a labeled cut beyond that. Each call appends its `command` and `exit_code` to `.emetgate/events.ndjson`, as allowlisted runs now do too.

Lockdown pre-allows `emetgate_run` (see the table below) and gives Claude Code a `PreToolUse` hook for it, `emetgate hook pretool`, matched to `^mcp__.+__emetgate_run$`. The hook reads the tool call from stdin and splits the command into words and parts the way a shell does: quotes, escapes, `&&`, `||`, `;`, `|`, `&`, line breaks, `$( )`, backticks, `bash -c`, `cmd /c`, `powershell -Command`, `eval`, `sudo`, `env`, `timeout`, `xargs` and `npx` are followed, eight levels deep. A part that deletes recursively or by force (`rm -r`/`-f`, `rmdir /s`, `del /s`, `Remove-Item -Recurse`, `rimraf`, `find -delete`), rewrites or deletes remote history (`git push --force`, `--delete`, `--mirror`, a `+` or `:` refspec), discards changes (`git reset --hard`, `git clean -f`, `git checkout -- .`, `git restore`, `git switch -f`, `git branch -D`, `git stash drop`), rewrites history (`filter-branch`, `filter-repo`), drops or truncates a database object, formats or overwrites a disk, shuts the machine down, changes permissions recursively, pipes a download into a shell, runs an encoded PowerShell command, or adds, replaces or forgets an emetgate rule makes the hook print `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"emetgate: this command <reason>: <part>"}}`, and Claude Code asks the user before the call. Any other command gets no output and runs. Tool input the hook cannot read also asks. The list is a judgment over words, not a sandbox: a script the model writes and then runs, or a program that deletes on its own, is not recognised, and a rule ledger edited by a command is not caught.

Lockdown also gives Claude Code a `SessionStart` hook, `emetgate hook session`, in exec form with no matcher, and sets `EMETGATE_CONTEXT` for that launch to a new file under `%LOCALAPPDATA%\emetgate\lockdown\<hash>\context\`, which it deletes when Claude Code exits. After a compaction or `/clear` the hook moves the file and the server sends every file again; see [the session mirror](#reader) for the rules. A value of `EMETGATE_CONTEXT` in the parent environment is replaced.

The repository ships a Claude Code skill, `.claude/skills/md-audit/SKILL.md`, that audits a CLAUDE.md or AGENTS.md file: it sorts every instruction sentence into enforceable, waiting for a mechanism, unverifiable or belief, proposes a check and scope for the enforceable ones, measures each with `emetgate_scan` and reports, changing nothing. To use it in every project, copy the `md-audit` folder into `%USERPROFILE%\.claude\skills\` (`~/.claude/skills/` elsewhere).

### Lockdown

`emetgate lockdown [--test <command>] [--no-marks] [<claude args>...]` starts `claude` in the current directory with this argv in front of the user's arguments, and with `ENABLE_TOOL_SEARCH=false` added to its environment:

```
claude --add-dir <lockdown directory> --settings <lockdown directory>\settings.json --setting-sources project --tools "" --allowedTools "mcp__<server>__emetgate_symbols ... mcp__<server>__emetgate_mutate mcp__<server>__emetgate_run" --mcp-config <absolute MCP config> --strict-mcp-config --plugin-dir <lockdown directory>\marks
```

The first two flags give the session the `/rule` command and are described under "Rules from the prompt" below. The last one loads a plugin that only draws and is described under "Marks in the transcript"; `--no-marks`, as the first argument after `lockdown` (or the first after `--test <command>`), leaves it out. `--setting-sources project` loads only the project's `.claude/settings.json`: the user's own settings and their hooks (a `SessionStart` hook that tells the model to use tools this session does not have, for one) do not reach a locked session.

**Starting in an empty folder.** When the current directory is in no git repository, lockdown runs `git init` there and says so on stderr (`emetgate lockdown: the directory was not a git repository, ran git init`); the gate needs a repository for its shadow copy and receipts. The `git init` is the last step before Claude Code starts: `claude` is found, the `.mcp.json` is read and the lockdown files are written first, so a launch that stops (`ClaudeNotFound`, `NoEmetgateServer` and the rest) leaves the folder as it was. Lockdown does not run `git init`, and stops with `LockdownInitRefused` and a stderr line naming the folder, when the folder is a drive root (`C:\`, `\\server\share`), is or holds the folder of `USERPROFILE`, `HOME`, `APPDATA`, `LOCALAPPDATA`, `SystemRoot`, `ProgramFiles`, `ProgramFiles(x86)`, `ProgramData` or `PUBLIC` (so `C:\Users` and the home folder itself), holds an `NTUSER.DAT` in itself or a subfolder (a user profile), or has a `.git` one or two folders down (a folder of projects); the scan stops after 4096 folders and does not follow links. The fix is to `cd` into a project folder, or to run `git init` there yourself. Lockdown finds `claude` on PATH but skips every PATH folder that lies inside the current folder, so a `claude.cmd` planted in a repository is never run. npm puts `claude.cmd` in `%APPDATA%\npm`, inside the home folder, so lockdown started from the home folder skips it: it then stops with `ClaudeOnlyUnderWorkingDir` and the stderr line `emetgate lockdown: skipped <path>: its PATH folder lies inside the current folder, and lockdown runs no program from there`, and `emetgate doctor` reports the same, instead of `ClaudeNotFound`. A project `.mcp.json` emetgate entry whose arguments name no `--test`, `--test=` or `--detect-test` gets `--detect-test` added in the config lockdown hands Claude Code, so writes and `emetgate_run` have a test command; the file itself is not changed. Without a `.mcp.json`, lockdown's own config starts the server as `emetgate mcp --test <command>` when `--test <command>` (or `--test=<command>`) is given, and as `emetgate mcp --detect-test` otherwise. `--test` together with a project `.mcp.json` stops with `LockdownTestWithMcpConfig`, since that file sets the server's arguments; put `--test` in the `.mcp.json` entry instead. A test command added with `claude mcp add ... --test` does not reach lockdown: lockdown starts its own server, not the one registered with Claude Code.

**Tool names the model calls.** Claude Code offers an MCP tool to the model as `mcp__<server>__<tool>`, so a model that copies a short name such as `emetgate_try_batch` from the server's text gets `No such tool available`. Lockdown therefore starts every emetgate server it hands Claude Code with `--tool-prefix mcp__<server>__`, the server name written the way Claude Code writes it (its own config gives `mcp__emetgate__`); a `.mcp.json` entry that already names `--tool-prefix` keeps its own. With the flag the server writes that prefix before every tool name in `instructions`, the tool and argument descriptions and every `fix` and note; tool names in `tools/list`, and the names it accepts in `tools/call`, stay short. Without it, as for any other MCP client, the text is unchanged. A prefix holds 1 to 96 letters, digits, `_` or `-`; any other value stops the server with its usage line.

**Detected tests.** With `--detect-test` the server looks for the test command on every write, in the repository root, so a project that gains its tests during the session is gated from that write on: `package.json` with a `scripts.test` other than npm's `no test specified` placeholder gives `npm test`, then `build.zig` gives `zig build test`, `Cargo.toml` `cargo test`, `go.mod` `go test ./...`, `pyproject.toml` or `pytest.ini` `python -m pytest`, and a `.sln` or `.csproj` file `dotnet test`. When none is there yet, the write is still checked (parse, hash, symmetry, rules) and lands with `"status":"unverified_no_tests"` and a `tests` field that says no test ran; once a marker exists every write runs its command and is judged as the test gate describes. The detected command is also on the `emetgate_run` allowlist, as a command given with `--test` is.

**Write statuses.** A write that passed its gate replies `"status":"written"`: the bytes are on disk and no commit was made. It says `"committed"` only when the server runs with `--commit` and the call made a git commit, whose id is in `commit`.

`--tools ""` leaves Claude Code no built-in tool: no built-in shell, no file read or edit, no web access and no ToolSearch; the one shell is `emetgate_run`. `--strict-mcp-config` with the absolute path loads only the servers of that file. The file is the `.mcp.json` of the current directory; when there is none, lockdown writes `mcp.json` into the lockdown directory with one server, `emetgate`, that runs the lockdown's own executable with `mcp`, and nothing is written into the repository. A user argument that would change any of this (`--tools`, `--allowedTools`, `--allowed-tools`, `--mcp-config`, `--strict-mcp-config`, `--settings`, `--setting-sources`, `--plugin-dir`, `--agents`, `--dangerously-skip-permissions`, `--allow-dangerously-skip-permissions`, alone or as `--flag=value`) is refused before anything starts.
`--permission-mode bypassPermissions` (also `--permission-mode=bypassPermissions`, in any letter case, though Claude Code 2.1.286 accepts only this spelling) is refused the same way, since it skips every permission check as `--dangerously-skip-permissions` does; the other modes (`acceptEdits`, `auto`, `manual`, `dontAsk`, `plan`) pass.

`--allowedTools` lists the emetgate tools that neither change the repository nor run a command, so Claude Code runs them without a permission check; in auto mode that check added 0.5 to 1.6 s to each call in the measurement below. The list comes from reading each handler:

| Tool | Why it is pre-allowed |
|---|---|
| `emetgate_explore` | Reads tracked source files; its only write is its own fact store under `%LOCALAPPDATA%\emetgate\facts` |
| `emetgate_evidence` | Reads tracked source files; its only write is its own fact store under `%LOCALAPPDATA%\emetgate\facts` |
| `emetgate_symbols` | Loads one file through the repository jail and the in-memory tree cache and lists its symbols |
| `emetgate_skeleton` | Same load, plus a read of the rule ledger without taking its lock |
| `emetgate_read_symbol` | Same load; the session mirror lives in memory |
| `emetgate_read_file` | Reads one or more files inside the repository |
| `emetgate_list` | Runs `git ls-files` with a fixed argument list |
| `emetgate_search` | Reads tracked files; its only write is its own index cache under `%LOCALAPPDATA%\emetgate\index` |
| `emetgate_find` | Reads the files `git ls-files` lists; its only write is its own index under `%LOCALAPPDATA%\emetgate\find` |
| `emetgate_scan` | Measures one check in memory, writes nothing and does not read the ledger; a `cmd:` check is refused as not static, so no command runs |
| `emetgate_git` | Runs `status`, `diff`, `log`, `show` or `blame` with a fixed argument list, or a read-only form given in `args`, with `--no-optional-locks` and no pager, external diff, textconv or fsmonitor; `log` also lists the receipt notes, and `diff`, `show` and `blame` parse the files they name to map the change to symbols |
| `emetgate_mutate` | Builds the changed source in memory; it runs no command and writes nothing |

`emetgate_run` is pre-allowed as well, for another reason: it runs commands, and its `PreToolUse` hook (see "Any command under lockdown") decides per command. A command the hook names gets `ask`, which Claude Code shows the user as a permission prompt; any other command runs without one.

The other tools keep whatever permission mode the user chose: `emetgate_try`, `emetgate_try_batch`, `emetgate_edit`, `emetgate_write` and `emetgate_write_doc` write files after the trusted test command passes, `emetgate_commit` makes a git commit, `emetgate_rename`, `emetgate_move` and `emetgate_move_file` write several files and run the TypeScript language service, and `emetgate_git_write` changes branches, commits and the working tree with git. Every call, pre-allowed or not, appends one line to `.emetgate/events.ndjson`, emetgate's own git-ignored log. A test in `tests/lockdown.zig` fails when the server gains a tool that is in none of the lists.

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

#### Rules from the prompt

In a session started by `emetgate lockdown`, the user manages rules by typing `/rule`:

```
/rule add "no networkidle waits" --check forbid:networkidle --enforce
/rule list
/rule supersede <id> "use integer cents"
/rule forget <id>
/rule pick 1 19 26 in src/
/rule show 19
```

The text after `/rule` is the argument list of `emetgate rule`: it is split into words and handed to the same code, so both forms accept and refuse the same things and write the same ledger. Words are separated by spaces, tabs and line breaks. Single quotes keep everything between them as typed. Double quotes do the same, except that `\"` is one double quote; a backslash anywhere else is an ordinary character, so `"cmd:scripts\lint.cmd"` needs no doubling. A quote that never closes is answered with the usage.

The prompt does not reach the model. Lockdown gives Claude Code a `UserPromptSubmit` hook, `emetgate hook prompt`, which Claude Code runs on every prompt before any request is sent. The hook reads the hook JSON from stdin and looks at its `prompt` field:

| Prompt | What the hook does |
|---|---|
| `/rule`, alone or followed by a space, a tab or a line break. Spaces, tabs and line breaks in front of it are dropped first, and so is one UTF-8 byte order mark | Runs the rule command and prints `{"decision":"block","reason":"<answer>"}`. Claude Code shows the answer and sends nothing to the model |
| anything else, `/rules`, `/ruler`, `/RULE` and a `/rule` that follows any other character (a vertical tab, a no-break space, a word) included | Prints nothing and exits 0; the prompt goes on unchanged |
| stdin that is not a JSON object with a string `prompt` | Prints `error: HookInputInvalid` to stderr and exits 2, which stops the prompt. Every prompt is stopped until this is fixed, so a `/rule` line cannot slip through to the model unseen |

Measured on Claude Code 2.1.291 in print mode: the hook receives the prompts ` /rule list`, a line break followed by `/rule list`, and a tab followed by `/rule list` exactly as typed, with the leading character still there. That is why the hook drops it.

The answer is written for a person, while `emetgate rule` on the command line keeps its terse output for scripts. `add` answers `rule added: <text>` and a second line with the id, `enforce` or `advisory`, the check or `no check`, and the scope or `whole repository`; `supersede` answers the same with `rule replaced`; `forget` answers `rule forgotten: <id>`; `list` answers a header line (`id`, `state`, `mode`, `check`, `where`, `rule`) and one row per rule in padded columns, or `no rules`. A refusal answers the lines `emetgate rule` writes to stderr, with the rules as that table, followed by `error: <name>`. An answer that would be empty is `ok`, because Claude Code replaces an empty reason with its own `Blocked by hook`. A `/rule` line the grammar does not define answers with the usage lines. The JSON the hook prints is plain ASCII: every other character is written as a `\u` escape, so the answer does not depend on a code page.

`/rule pick` alone lists the rule catalog: numbered rules under the headings Code style, Security, Git hygiene and Architecture, one line per rule and two columns where they fit, every line at most 80 columns and plain ASCII, with the usage line `/rule pick <numbers> [in <path>]` and an example on top. A rule this repository already enforces (an active `enforce` rule in the ledger with the same check) is marked `*`; with no ledger, or outside a repository, nothing is marked and nothing fails. `/rule pick 1 19 26` enforces those rules on the whole repository; a trailing `in <path>` scopes the code rules to that path and leaves the commit message rules unscoped; rule 30, freeze a path, takes its own path right after its number (`/rule pick 30 src/core`) and is skipped without one. The answer is one line, such as `enforcing 3 rules: 1 no console.log, 19 no new comments, 26 no Co-authored-by`, after a `skip` line for each number that is not in the catalog, was picked twice or lacks its path. The list shows no check specs; `/rule show N` prints rule N's title, what it applies to and its check spec in full, and a number outside the catalog answers one line, `show 31: no such rule; give a number from 1 to 30`. `emetgate rule pick` and `emetgate rule show` do the same from the command line, where a refused `show` exits 1.

The hook is of type `command` in exec form (`"command": "<absolute emetgate.exe>", "args": ["hook", "prompt"]`), so no shell reads the path. It is not an `mcp_tool` hook: that would need a rule-writing tool on the MCP surface, where the model could call it. The served tool list is unchanged. The model can type `emetgate rule add`, `supersede` or `forget` into `emetgate_run`; the `PreToolUse` hook asks the user before such a command runs.

Lockdown writes two files, both under its own directory `%LOCALAPPDATA%\emetgate\lockdown\<key of the emetgate.exe path>\`, and nothing into the project or into `~/.claude`:

| File | Why |
|---|---|
| `settings.json` | Holds the two hooks, `UserPromptSubmit` for `/rule` and `PreToolUse` for `emetgate_run`. Passed with `--settings`; hooks from the user's own settings files still run |
| `.claude\commands\rule.md` | Claude Code answers `Unknown command` to a slash name it has no file for, before any hook runs. The directory is passed with `--add-dir`, which loads its `.claude/commands`. The file is front matter only, with `disable-model-invocation: true`, and has no body |

Each emetgate executable has its own directory, so two builds do not rewrite each other's hook. A file that already has the right bytes is left alone; otherwise it is written beside its place and renamed over it. Without `LOCALAPPDATA` lockdown stops with `LocalAppDataUnavailable` before Claude Code starts. `--add-dir` takes several values, so both flags stand in front of the lock, where the user's prompt cannot become one of them. The user's own `--settings` is still refused; `--add-dir` from the user still passes.

`/rule` exists only in a session started by `emetgate lockdown`. Emetgate installs no hook and no command file for a `claude` started any other way.

Measured with Claude Code 2.1.291 on Windows, 2026-10-06, through `emetgate lockdown -p "<prompt>" --output-format json` in a new repository:

| Prompt | Turns | `total_cost_usd` | Answer shown |
|---|---|---|---|
| `/rule add "ğüşıöç İĞÜŞÖÇ 'tek' \"çift\"" --check 'forbid:"şık"' --enforce` | 0 | 0 | `m1fd2c285aedca4d4` |
| `/rule list` | 0 | 0 | the row, with `forbid:"şık"` and `ğüşıöç İĞÜŞÖÇ 'tek' "çift"` unchanged |
| `/rule add typo --check frbid:x` | 0 | 0 | the check names, then `error: UnknownCheck` |
| `/rule` | 0 | 0 | the four usage lines |
| `/rule forget mdeadbeefdeadbeef` | 0 | 0 | the active row, then `error: DecisionNotActive` |
| `/rule forget m1fd2c285aedca4d4` | 0 | 0 | `ok` |
| `/rule list` with no rule left | 0 | 0 | `ok` |

The answers in this table are those of the version that was measured, which answered with the bare id, tab-separated rows and `ok`. The wording described above has not been measured in print mode.

Claude Code printed each answer as `UserPromptSubmit operation blocked by hook:`, the answer, and `Original prompt:` with the prompt. After the seven runs the project held `.emetgate/ledger.ndjson` and no `.claude` directory.

The session's `init` message listed `rule` among its slash commands with the `--add-dir` directory and did not list it without. Not measured: the interactive screen. In print mode Claude Code hands the raw text to the hook whether or not the command file exists, so only an interactive session shows that typing `/rule list` there reaches the hook.

`--tools ""` was chosen over `--tools ToolSearch`. With `ENABLE_TOOL_SEARCH=false` both gave the same 16 tools and the same 25,140-token first request in four sessions; with `--tools ""` and the variable unset, Claude Code still loaded the MCP tools up front in one session. So the model has one tool fewer, and turning tool search off does not depend on the variable alone.

#### Marks in the transcript

`emetgate lockdown` loads one Claude Code plugin, `emetgate-marks`, from `<lockdown directory>\marks` with `--plugin-dir`. It draws in the terminal and does nothing else: it registers no tool, adds nothing to the system prompt, rewrites no prompt and no tool result, and the model reads the same bytes with it and without it.

| Where | What it draws |
|---|---|
| Under a write call (`try`, `try_batch`, `write_doc`, `rename`, `move`, `move_file`), also when Claude Code folds calls into one `Called emetgate N times` row | Once the gate has answered that call, the word in Hebrew letters, then the file and symbol: **אמת** in green when the call was accepted; when it was refused the first letter is faded out and **מת** stands in red |
| The line that animates while a turn runs | The word says what the turn is doing: `Awaiting the word` while the request is out, `Pondering the letters` while the model thinks, `Speaking` while it answers, `Shaping the clay` while it writes a tool call, `Reading the clay` while an emetgate read runs, `Weighing at the gate` while a write is at the gate, then `Sealed` or `Turned away`. Before the word stand the three letters: written one after another while the turn works, whole while emetgate reads, yellow at the gate, and as under a write call once the verdict is in |
| The line that closes a turn | When the turn made a write call, the word becomes `Sealed`, `Turned away` or `Weighed`, and a second line counts `passed` and `refused`; otherwise the word is `Spoke` |

`/golem off` stops all of it and `/golem on` brings it back; `/golem scene`, `/golem big` and `/golem small` also draw a larger picture in place of the working line. The choice is kept by Claude Code for the plugin and holds in later sessions. `emetgate lockdown --no-marks` starts without the plugin: nothing is written under `marks` and no `--plugin-dir` is passed. The flag is read only as the first argument; anywhere else it is the user's own argument to Claude Code.

The plugin's five files are part of the executable and are written as the `/rule` files are: byte for byte, left alone when already right, repaired when changed. `--plugin-dir` takes one value and stands after the lock and before the user's arguments. A `--plugin-dir` of the user's own is still refused. The letters are given in reading order and Claude Code lays them out right to left; measured on Claude Code 2.1.292 in Windows Terminal with its default font. Not measured: the time the plugin's `tool.call` hook adds to a call, and how the marks look in another terminal or with a font that has no Hebrew letters.

### Reader

A 284-session measurement found that read tokens (`Read` plus shell `cat`/`sed`) were
about 57% of all tool-result tokens, three quarters of them a whole file, with a median
of 4.1K characters and a p90 of 22K. The read tools above are built to cut that:

- **Three levels for a source file of a registered language (TypeScript, JavaScript,
  Python, C#):**
  signatures (`emetgate_symbols`: ref, hash, line) → structure (`emetgate_skeleton`:
  every signature, bodies elided) → body (`emetgate_read_symbol`: one symbol, several at
  once, or a line range widened to the symbols it overlaps, each with its own hash). A
  raw whole-file read of such a file is refused by `emetgate_read_file`
  (`UseSymbolToolsForSource`) unless `raw:true` is passed explicitly; with `raw:true`,
  `line_start`/`line_end` return just those lines. A range that runs past the end of the
  file comes back with `status: partial` and the line the file ends at; an inverted range
  is `InvalidLineRange` and one that starts after the last line is `LineOutOfRange`.
- **Refs.** `emetgate_symbols` lists the ref of every member. Each one reads through
  `emetgate_read_symbol` and writes through `emetgate_try` with the same ref and hash:

  | Member | Python | C# |
  |---|---|---|
  | method, constructor | `A.f`, `A.__init__` | `Box.Add`, `Box.Box` |
  | static method | `A.make@static` | `Box.Empty@static` |
  | property | `A.size@get`, `A.size@set`, `A.size@delete` | `Box.Area@get`, `Box.Area@set` |
  | event accessor | | `Box.Changed@add`, `Box.Changed@remove` |
  | indexer | | `Box.this@get`, `Box.this@set` |
  | operator, conversion | | `Box.operator+@static`, `Box.operator int@static` |
  | destructor | | `Box.~Box` |
  | explicit interface member | | `Box.IComparable.CompareTo` |
  | overload | `A.f(int)` | `Box.Add(int)`, `Box.this(string)@get` |

  An overload gets its parameter types in the ref only when a name would otherwise be
  shared. A Python `@overload` stub is keyed; the implementation stays `A.f`, as a
  TypeScript implementation does. A C# method with no overload answers to both `C.F` and
  `C.F(int)`; once a second overload joins, `C.F` is ambiguous. Overloads that differ only
  in generics or in `params` stay apart as well (`C.F<T>(List<T>)`, `C.F(params int[])`).

  Python and C# also take a short ref: a namespace prefix, an outer class, `@static` and
  the accessor can be left off where exactly one member fits, so `Box.Add(int)`,
  `Empty` and `Box.Area` reach `Shop.Box.Add(int)`, `Shop.Box.Empty@static` and
  `Shop.Box.Area@get`. A ref that fits several members is `AmbiguousSymbol`, and its `fix`
  lists each one with its line (`C.F matches: C.F(int) (line 3), C.F(string) (line 4);
  send one of these refs`). Two members with the same signature, as `#if` branches can
  have, are listed the same way and have no ref of their own. TypeScript and JavaScript
  ask for the whole ref.

  A C# property with an accessor list is a declaration under its bare name: `C.P` is the
  whole `int P { get; set; }`, and `C.P@get` is one accessor. A body in a `=>` or a block
  can be sent back in either form.
- **Docs.** The doc of a Python symbol is its docstring, which wins over a comment above
  the `def` or `class`; the doc of a C# symbol is the text of the `<summary>` of its `///`
  comment, without the XML. TypeScript and JavaScript keep the JSDoc or comment above.
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
- **Several files in one call**: `files` takes up to 32 entries, each a path or an
  object `{file, raw, pointer, heading, line_start, line_end, force}` whose fields
  override the same fields given at the top level; `file`, if also given, is read
  first. Each file comes back under its own `== path` line with the rendering it would
  get alone, a file that fails as its own error reply in its place. The reply is capped
  at 64 KiB: a file that would push it over is left out, and a last line
  `{"status":"partial","not_sent":[...],"fix":...}` names every such file and says to
  read it in another call, alone or by line range. A file left out is not remembered
  as sent.
- **Session mirror (on by default, `emetgate mcp --no-mirror` turns it off).** The
  server remembers, in process memory only, the content hash of every unit it has
  already sent this session, keyed by path and selector (whole file, line range, JSON
  key tree or pointer, Markdown heading tree or section, skeleton, symbol), together
  with the hash of the whole file it came from and the number of the tool call that
  sent it. A repeat request answers one line
  (`{"status":"unchanged","hash":...,"file_hash":...,"since_call":N,"hint":...}`)
  only when the unit and the whole file both hash the same as when it was sent, so the
  same text would be sent again; any change to the file, through an emetgate write or
  on disk, even outside the requested range, makes the next read send the content. A
  different range or selector is its own key and is never answered `unchanged` from
  another. `force:true` always sends the full content and records it again; every
  `unchanged` reply says so in its hint. Symbol reads (`emetgate_read_symbol`) are
  keyed by the symbol's own hash and do not carry `since_call`.
  A compaction or `/clear` empties the mirror, and without a `SessionStart` hook the
  server sends everything: see **Compaction and `/clear`** below.

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

**Compaction and `/clear`.** The mirror knows what it sent, not whether the model still has it: after a compaction or `/clear` an `unchanged` reply would point at content the model has lost. So the server trusts the mirror only while a *context epoch* stands still.

- `emetgate hook session` is a `SessionStart` hook. It writes a new random token and the hook's `session_id` to an epoch file, atomically, and prints nothing, so nothing enters the context. It does this for every source (`startup`, `resume`, `clear`, `compact`, `fork`, and any later one) and when stdin is empty or not JSON. If it cannot write, it deletes the old file and exits 1.
- Before every tool call the server reads that file, about 100 bytes. If the bytes moved, it drops every mirror record, so the next read of any file, range, skeleton or symbol sends the content, and a repeat inside the new window answers `unchanged` again. `since_call` keeps counting across a reset: it numbers tool calls of the server process and names the call that last sent the content, never one from before the reset.
- The mirror works only once it is armed: the file exists and either names this server's own `CLAUDE_CODE_SESSION_ID` or was seen to move while the server ran. A missing or unreadable file, a file left by an earlier session, and an environment that names no file all mean a reset on every call. Every failure sends content.
- The file is the one `EMETGATE_CONTEXT` names, and otherwise `%LOCALAPPDATA%\emetgate\context\<hash of CLAUDE_PROJECT_DIR>.epoch`. The hook and the server work it out the same way from their environment. Lockdown sets `EMETGATE_CONTEXT` to a new file for each launch and adds the hook itself, so two lockdown sessions on one repository never reset each other. Without lockdown, sessions on one project share the file, so a compaction in one also resets the other: one extra resend each, never a missed reset.

**`emetgate mcp` without lockdown.** With no hook the file never appears, so the server sends full content on every read and answers `unchanged` to nothing. That costs tokens and is always correct, which is the side to fail on. To get `unchanged` replies, add the hook to your Claude Code settings, with no matcher so that it runs for every source:

```json
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"C:\\path\\to\\emetgate.exe","args":["hook","session"]}]}]}}
```

A client with no compaction, or a script that holds on to every reply, can pass `--mirror`: it turns the epoch check off and trusts the mirror for the life of the process. `--no-mirror` turns the mirror off. `force:true` still sends the content in every mode.

**Limits.** The epoch is one per server, while Claude Code subagents without lockdown share their parent's server and mirror, so a subagent can get `unchanged` for a file only its parent read. Lockdown runs with no built-in tools and so no subagents. The file is compared when a tool call arrives, so the fix relies on Claude Code finishing the `SessionStart` hook before it sends the next tool call. A lockdown process that is killed leaves its epoch file behind; it is about 100 bytes and no later launch reads it.

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

- **File already read.** Both rows are still under 1x. `Edit` then sends the changed line and gets one line back (19 tokens); a compact `emetgate_try` reply is now `{"status":"written","file":...,"nodes":[[...]],"symbols":[{"symbol":...,"new_hash":...}]}`, the new node hash plus the changed symbol's new hash and nothing else — the shadow copy summary, receipt ids and old hash moved behind `detail:"full"`. That reply is 79 to 109 tokens where it used to carry the always-on shadow note and receipt fields at 172 to 202 tokens. Even a reply of zero tokens would leave 1.8x and 1.9x, because emetgate's arguments alone (56 and 34 tokens) are more than a third of the whole built-in call (101 and 66); the two "already read" rows sit at that acknowledged ceiling, not at 3x.
- **Turns.** Each flow is one read and one write on both sides, so turns are equal except where `Edit` has to retry or makes one call per place; emetgate then saves one turn. A 3x turn ratio is not reachable with a read-then-write flow.
- **Time.** An emetgate edit takes 200 to 420 ms, a `read_symbol` about 60 ms of it; the rest is the gate: the shadow copy, starting the test command under the low-integrity token and job, and the journaled commit. The built-in edit runs no test. Measured against a flow that also runs the tests, the gate would be compared with the test run itself.
- **Delete.** Every function in both fixtures is called somewhere, and emetgate refuses to delete a function whose name is still mentioned, so the delete scenario removes the call site in the same call. In express the call site sits in `app.handle = function ...`, which is not a symbol, so emetgate reads those two lines by range.
- **Other formats.** For the model's emitted edit alone, without the read each one needs: the whole file costs 1421 to 13444 tokens, a unified diff with 3 lines of context 49 to 220, SEARCH/REPLACE 21 to 238 (5338 and 6612 for the deletes, as one block has to span both places), the emetgate call 34 to 124.

## Receipts and `emetgate verify`

Every commit the gate makes (`emetgate_try`, `emetgate_try_batch` including creations and deletions, `emetgate_rename`, `emetgate_move`, `emetgate_move_file`) leaves a receipt, so the change can be checked later without trusting Emetgate, the model or the log. A doc edit (`emetgate_write_doc`, or `"kind": "doc"` in a batch) is not in a receipt; `emetgate verify` reports a file changed only that way as `unverified`. A receipt is an [in-toto](https://in-toto.io) Statement v1: `subject` lists every file the commit wrote with its `blake3-128` and `sha256` digests, `predicateType` is `https://emetgate.dev/receipt/v1`, and the predicate records:

| Field | Content |
|---|---|
| `operation`, `class`, `evidence` | the tool, `symmetry` or `spending`, and what proves it (`test`, `alpha_hash`, `content_hash`, `unreferenced`) |
| `files` | every touched path with its whole-file digest before and after (`null` for absent) |
| `symbols` | every symbol or declaration the operation changed, created or removed, with its hash before and after |
| `checks` | the typecheck and test commands that passed, their `blake3-128` digest, exit code and duration |
| `rules` | the id and digest of every adopted rule that covers a touched file |
| `sandbox`, `emetgate` | the sandbox limits and the Emetgate version |

The JSON is canonical ([RFC 8785](https://www.rfc-editor.org/rfc/rfc8785), keys sorted by UTF-16 code units, integers only), so its `sha256` is the receipt's id and the same receipt always has the same bytes. Receipts are not signed yet; the format is the one Sigstore/cosign sign and a transparency log such as Rekor records, so signing adds a signature over these bytes and changes none of them.

**Storage.** A receipt is written to `.emetgate/receipts/` when the gate writes the files. Who makes the commit decides how it reaches a note (`refs/notes/emetgate`, one canonical JSON array per commit, the receipts in the order the gate wrote them):

- `emetgate mcp --commit`: every accepted write is its own commit, and the receipt of that call is attached to it in the same call (see "A write that is also a commit").
- `emetgate commit -m <message> [--shadow-root <dir>]`: one commit of every pending gated change. It refuses, writes nothing and exits 1 when a file differs from the `after` digest its latest pending receipt names (`refused: N file(s) changed outside the gate and are uncertified`, with the paths), when a frozen-file or message rule forbids it or cannot be run, when a test that passed or did not exist when the session started fails (`refused: N test(s) ...`, with the tests; pytest and dotnet test results are read per test, and the tests are run again on the committed tree when the ledger still owes one), and when nothing is pending (`nothing to commit`). Otherwise it builds the commit from `HEAD` plus the gated content without touching the working tree, attaches every pending receipt whose files the commit changed, prints `committed <oid> (N file(s), M receipt(s) attached under refs/notes/emetgate)` and exits 0.
- a commit the user makes with `git commit`: `emetgate receipts attach [<commit>]` puts every pending receipt whose files that commit changed into its note.

Notes were chosen over a trailer or a working-tree key: they attach to the commit without changing its hash, survive a rebase only when the user carries them, and are not fetched by a plain clone, so a cloned repository brings no receipts unless someone fetches `refs/notes/emetgate` on purpose. `.emetgate/` is outside every tool's reach (`InternalPath`), so the model cannot write a receipt. A receipt is still only a claim: `verify` recomputes every digest and never runs anything a receipt names (the PR #31 lesson: a command from the repository is untrusted); it reruns only the test and typecheck commands the person running `verify` passes, and only when their digest equals the one in the receipt.

**`emetgate verify <commit> [--test <cmd>] [--typecheck <cmd>] [--skip-tests] [--json]`** reads the commit, its parent and the note, and replays the receipts in order over the parent's files:

- every receipt's `before` digests must match the parent or the previous receipt, its `after` digests its subjects, and the last receipt for a file the commit's content; a note that is not canonical JSON, an added or reordered receipt and an edited digest are all `mismatch`;
- every listed symbol hash is recomputed from the file content before and after;
- a receipt says which form of a file its digests are over. A receipt written by a `--commit` call carries `"form":"stored"` in its predicate: its file digests and its subject are over the blob the commit stores, which every verifier reads the same whatever its line end and filter settings. A receipt without that field, every receipt written without `--commit` and every receipt written before the field existed, is over the checked-out form, the working file the gate tested, and is verified as described next. For a path without a `filter` driver that form is what `git --attr-source=<commit> cat-file --filters` gives under the verifier's own line end settings (`core.autocrlf`, `core.eol`, `text`/`eol` attributes), or the stored blob when that is what the working file held; each digest is compared with both, and the one that matches is the form its symbol hashes are taken over, so a receipt over a CRLF working file of an LF blob verifies, and a forged digest matches neither. The Python checker does the same. `"form":"checked_out"` says the same explicitly. In both forms, for a path whose `.gitattributes` name a `filter` driver, the symbol hashes are taken over what the driver checks out, and a `stored` receipt is `unverified` ("the checked-out form of a filtered file is not available"), never `mismatch`, when that output cannot be produced or does not parse;
- for a path whose `.gitattributes` in that commit name a `filter` driver (Git LFS is one), the stored blob is not the file the gate tested. A receipt measures the working file, so for such a path the file digests and the symbol hashes are both taken over what the driver checks out (`git --attr-source=<commit> cat-file --filters`, which runs the smudge command from the user's own git configuration). When that output cannot be produced, because the driver is not configured or fails, or when it is not the file the receipt measured before the change, the receipt is `unverified` ("the checked-out form of a filtered file is not available"), never `mismatch`. Output that differs after the change is `unverified` like any file changed outside the gate. The second checker in `tools/verify_py` reads filter drivers the same way and gives the same verdict;
- a `spending` receipt is `verified` only when the trusted test command, rerun in the sandbox on a worktree of the commit, passes (`mismatch` when it fails, `unverified` when it was not rerun or was a different command);
- a `symmetry` receipt is checked without running anything: a rename by the alpha hash of every top-level statement, a move or file move by the multiset of symbol and declaration hashes of the touched files, a creation or deletion by the other symbols keeping their hashes and the name appearing in no other file of the commit;
- a rule whose digest changed is `mismatch`, one that left the ledger is `unverified`;
- a file the commit changed that no receipt covers, or that was edited by hand after the gate, is `unverified`.

**Merge commits.** A commit with more than one parent is never `verified`, and its note is not read. `verify` asks git for the tree it merges from the two parents on its own (`git merge-tree --write-tree`, git 2.38 or later) and compares it with the commit's tree:

| The commit | Verdict | Reason printed |
|---|---|---|
| two parents, and its tree is the tree git merges from them | `merged` | adds nothing to its parents; the combination was not gated |
| two parents, and its tree differs: a hand edit in the merge, or a conflict resolved by hand | `unverified`, and every path that differs is listed | holds content that git's own merge of its two parents does not produce |
| more than two parents | `unverified` | has more than two parents; what it adds cannot be told |
| two parents that git cannot merge on its own: an older git, no common history, or the command failed | `unverified` | git could not merge the two parents on its own (git merge-tree --write-tree, git 2.38 or later); what the commit adds cannot be told |

`merged` says only that the commit holds nothing but its parents; the parents are verified on their own, and nothing ran the tests on the combination. `verify` writes no object into the repository for this: git writes the merged tree into `.emetgate\verify\<16 hex digits>.objects` (`GIT_OBJECT_DIRECTORY`, with the repository's own object directory as `GIT_ALTERNATE_OBJECT_DIRECTORIES`), and that directory is emptied of git's object files and removed before `verify` returns. A test compares every file under `.git/objects` byte for byte before and after. The reason is the line after the verdict in the text output and the top-level `reason` in the JSON.

| Verdict | Exit code | Meaning |
|---|---|---|
| `verified` | 0 | every changed file is covered by receipts that hold |
| `unverified` | 53 | something was not measured, or a merge carries content of its own or cannot be told |
| `mismatch` | 54 | a receipt contradicts the commit |
| `consistent` | 55 | Python checker only: everything it checks holds, and the fields in `not_checked` were not checked |
| `merged` | 58 | a merge commit that adds nothing to its two parents |

Each file and receipt is reported as `verified`, `unverified` or `mismatch`; the exit code is 0 only when everything is verified, so "not measured" is never reported green. In CI, `emetgate verify HEAD --test "<the project's test command>"` after `git fetch origin refs/notes/emetgate:refs/notes/emetgate` can run as a status check; that step is documented here, not shipped.

**`emetgate verify --branch <base[..head]> [--test <cmd>] [--typecheck <cmd>] [--skip-tests] [--json]`** runs the single-commit `verify` above on every commit of `git rev-list --reverse base..head` (`head` defaults to `HEAD`; `--range` is the same flag), oldest first, and chains the results: each link's certificate is `blake3(parent certificate || commit id || verdict || receipt note)`, and the last one is the chain tip it prints. The tip is computed on every run and not stored or published anywhere, so it shows a change only to someone who kept an earlier tip to compare with. An empty `base` walks the whole history of `head`.

| Branch verdict | Exit code | Meaning |
|---|---|---|
| `verified` | 0 | every commit in the range is `verified` (a `merged` commit counts as verified here) |
| `partial` | 53 | no commit is `mismatch`, but at least one is not verified: no receipt, a hand edit, a test not rerun |
| `broken` | 54 | at least one commit is `mismatch` |
| `empty` | 53 | the range holds no commit (`base` equals `head` or is ahead of it); nothing was verified, so it is not green |

The text output is one header line (`branch <verdict>: N commit(s)`), then one line per commit with its verdict and certificate; `--json` prints the verdict, the count, the tip and every link. Receipts are not signed and the tip is not kept, so the chain shows tampering only when a receipt is edited inconsistently with its commit; a history rewritten together with freshly made, consistent receipts verifies as well as the original did.

**The checker's size.** The decision logic is `src/verify/` (canonical JSON, the receipt format and the checker). It parses with tree-sitter and hashes, and imports no code that writes, no journal, no sandbox and no protocol code; a test (`verify tcb`) fails the build if it ever does. Git access and the test rerun live in `src/platform/verify_run.zig`, outside the checker. What the checker trusts: <!-- generated:verifier-tcb -->4,254 non-blank lines of Zig in 33 files, 816 of them in the 3 files of `src/verify/`<!-- /generated -->, plus the tree-sitter C runtime and grammars and the Zig standard library. A second checker, written in Python from the format above and not from the Zig code, lives in `tools/verify_py/` (<!-- generated:python-checker-size -->479 non-blank lines of Python, plus 298 in the vendored BLAKE3<!-- /generated -->): `python tools/verify_py/emetgate_verify.py <commit> [--repo <dir>] [--json]`, with the same verdicts, exit codes and JSON shape, `merged` and the merge rules included, plus one more verdict, `consistent` (exit code 55). For a merge it keeps git's merged tree in a temporary directory of the system, not in the repository. It uses only the standard library, `git`, and the pure Python BLAKE3 by one of BLAKE3's authors (`vendor/pure_python_blake3`, CC0), which a test checks against BLAKE3's official test vectors; its RFC 8785 canonicalizer is its own. It checks the note's canonical form, the receipt format, the subject digests (`blake3-128` and `sha256`) against the commit's blobs, the `before`/`after` chain, the last `after` against the commit, the command digests and exit codes, and the changes no receipt covers. Symbol hashes, alpha hashes, the test rerun and rule digests need tree-sitter, a sandbox or the ledger format, so it lists them as `not_checked` and never counts them as verified. The Python checker is independent but partial: `consistent` means that everything it checks holds and that the fields in `not_checked` were not checked; it does not mean verified, and it reports `verified` only when `not_checked` is empty. Every scenario in `tests/verify_receipts.zig` runs both checkers and fails when they disagree on anything the Python checker checks (N-version), so it runs in `zig build test`, in `tools/accept.ps1` and in CI. Limits: a file touched by two receipts in one commit has an intermediate state that the commit does not contain, so the checks that need it report `unverified`; receipts are written for the MCP tools, not for the `emetgate try` CLI; receipts are not signed.

### Search

`emetgate_search` (`src/protocol/search_v1.zig`) finds a literal substring or, with
`regex:true`, a regular expression (`src/engine/regex.zig`) in the git-tracked text files
under `dir`, which may name a directory or one file. A file up to 16 MiB is indexed and
searched; a file over 1 MiB is searched line by line without a parse, so its lines carry no
definition mark and, under a `kinds` filter, a source file of that size is named
`unclassified`. A binary file, a file over 16 MiB and the internal paths are left out.

**The reply.** Inside `emetgate mcp` the reply is plain text (`src/protocol/search_text.zig`),
shaped to cost fewer characters than ripgrep's own output for the same pattern:

```
|1 import { greet } from './greet';
src/greet.ts
1*:export function greet(name: string) {
src/app.ts
1|1
4:greet('main');
src/other.ts
1|1
3:export const other = () => greet('other');
docs/notes.md
3:Call greet to say hello.
✓
```

- Each file path stands on its own line, followed by its matching lines as `line:text`. A
  `*` after the line number marks a definition: the symbol's own name in its signature.
- Leading and trailing spaces are dropped. A line longer than 120 characters is cut to a
  window around the match, with `…` at each cut end.
- A text met on two or more lines (an import repeated across files) is written once in a
  legend line `|N text` at the top, and those lines read `line|N`.
- Files are ranked: files with a definition first, then those whose enclosing symbol names
  the pattern, then code before comments and strings, then files with more hits, then path.
  Lines within a file follow their line numbers.
- The last line is the status. `✓` means every tracked text file in scope was searched
  and every match is shown; with no match it says why the zero can be trusted
  (`✓ no match in 157 file(s)`, `✓ 7 matching line(s) (0 code, 0 comment, 7 string) were
  all removed by kinds [code]`, `✓ <path> is not a file git tracks, so nothing was
  searched`, or, for a literal that looks like a regex, a pointer to `regex:true`).
  Otherwise it starts with `partial:` and lists the matches shown with the exact total
  (`matches 1-145 of 300`), then each file that could not be read or fully evaluated with
  its reason, then `; next offset:145` when more matches follow. Other notes join with `; `:
  `read as literal alternatives: a|b`, `7 hidden by kinds`, `index rebuilt: ...`. Nothing
  follows the status: unlike the other tools, a text search reply carries no `emetgate ...`
  session footer.

The text has one reading on Windows, where `:`, `|` and `*` cannot appear in a file name: a
line that starts with digits followed by `:`, `|` or `*` is a hit, a line that starts with
`|` is a legend entry, the last line is the status, and every other line is a path. An
error reads `error: <Name>` (with a detail after a colon where there is one, such as
ripgrep's message for a bad pattern).

The reasons a file is named: `unreadable` (could not be opened or read, for example held by
another process without sharing, or a tracked path that is now a directory or a link),
`vanished` (tracked but gone from the work tree; only a "not found" from the file system
counts, a held file is never taken for gone because its size and times are read through
attributes alone, and a read that meets a sharing or lock violation gives up at once
instead of retrying), `budget` (a line ran past the regex step budget of 2,000,000 steps)
and `unclassified` (a `kinds` filter was given and the file did not parse cleanly, so its
hits cannot be classified). `kinds:["code"]` (etc.) keeps hits of those kinds, judged from
the tree-sitter node at the match in a registered language; a kind name other than `code`,
`comment` or `string` is refused (`UnknownKind`). A literal with a `|` whose whole text is
not found is searched once more as the literal alternatives between the bars.

**Regular expressions the index cannot run.** A pattern the index's engine refuses (word
boundaries `\b`, counted repetition `{n,m}`, non-capturing groups `(?:...)`, look-around,
backreferences) is not refused to the model: the same tracked text files in scope, after
the same refresh, are searched by ripgrep (`src/platform/rg_search.zig`: `rg --json
--no-config --no-ignore --hidden --crlf -e <pattern> -- <files>`, started by its absolute
path from a PATH entry outside the repository and the working directory). The text reply
reads as any other, since the hits are the same; only the structured reply says
`delegated:"rg"`. A pattern ripgrep rejects too answers `error: InvalidRegex:
<ripgrep's message>`; with no ripgrep on PATH the answer is `error: RegexNeedsRipgrep`.
`kinds` cannot be applied to a delegated pattern (`KindsNeedAnIndexedPattern`).

**Structured reply.** The model's tool has no `format`, `certificate` or `stats`:
`emetgate mcp` leaves them out of the tool's schema and ignores them in a call, so the model
always gets the text above and its tool list carries none of their descriptions. They serve
the benches, the simulation runner and the certificate checker. In library calls and tests
the structured reply is the default; `emetgate mcp --search-internals` keeps the text reply
but obeys `format:"json"` (an unknown format is `UnknownFormat`), and a call there with
`certificate:true` or `stats:true` gets the structured reply as well. It starts
with `answer`, one line built by `src/engine/answer.zig` (`✓ 18 matches in 157 files @3fa2`
or `partial: 31 matches in 120 of 157 files @3fa2; missing 37 match_limit`, with `;
excluded 412 binary, 2 > 16 MiB` when a declared rule left files out), then `status`,
`groups` (by enclosing symbol with its ref and content hash, by JSON pointer in a `.json`
file, by heading in a `.md` file; each hit with `line`, `kind`, `role` and `text`),
`truncated`, `total` (the exact number of matches, with `total_exact:false` when a `kinds`
filter stopped the count), `delegated:"rg"`, `more`, `missing` (the reasons above plus
`match_limit`, matches that were found but are not in this reply, counted as files) and
`note`. An answer whose counts do not add up (evaluated and missing files against the scope,
a budget overspent, a missing reason with no declared limit, excluded paths against their
counts) is refused as `InconsistentCertificate` instead of being shown.

`certificate:true` adds the whole certificate: the snapshot (`barrier`, the barriers this
session has passed, and `root`, the RFC 9162 Merkle root over every in-scope file that was
read, each leaf its path and the SHA-256 of its bytes, in byte order of path), the scope
(`prefix`, `listed`, `excluded` per rule with `excluded_paths`, `evaluated`, `in_scope`),
the semantics (pattern, literal or regex, case, kinds, and `filtered`, the hits a kinds
filter hid) and the budgets (`file_bytes`, `matches`, and `steps` for a regex). The session
keeps one Merkle tree per scope it has answered and updates it from a journal of changed
paths, so a write recomputes one path from leaf to root; adding or removing a tracked file
rebuilds that scope's tree.

**Reply size and paging.** A reply holds about 5,000 characters. When the cut leaves
matches out, the answer is partial, the status gives the range shown and the exact total,
and `offset:N` (the number in `next offset:N`) gives the next page; `detail:"full"` lifts
the size budget. The scan collects at most 200 matches past the offset but keeps counting,
so the total is exact on every page (with `kinds` a stopped count shows as `300+`). On the
searches of the recorded sessions: <!-- generated:search-reply-sizes -->82 distinct searches from the recorded sessions, replayed on n8n: without the budget p50 1,748, p90 7,788, max 35,258 characters; with it p50 1,748, p90 5,293, max 5,727 (201,478 against 394,762 characters in total)<!-- /generated -->.

**The index.** One index per repository lives under
`%LOCALAPPDATA%\emetgate\index\<repo-path-hash>\` (the same hashed-path convention as the
shadow root, so a repository is never written into and a poisoned clone cannot carry a
poisoned index) and is mapped read-only into memory (`index_map.zig`,
`search_index_file.zig`). It holds the records sorted by case-folded path (path, stamp,
state, SHA-256 of the content), the text of every indexed file, its spans (symbols,
comment and string ranges, reference ranges, JSON pointers, Markdown headings;
`span_codec.zig`), and for every trigram a posting list of file ids stored as Elias–Fano
or as a bitmap, whichever is smaller (`postings.zig`). A query intersects the posting lists
of the trigrams of each literal the pattern must contain and reads the candidates straight
from the mapped text; a file is never re-read from disk for a search. The body is checked
by a BLAKE3 hash per 4 MiB chunk and the header by its own hash when a session loads it; an
index of another version is refused by its version byte, any other damage as corrupt, and
either way it is rebuilt and the reply says so (`index`). A new index goes to a new
generation file (`index.v4.<tag>`, written durably, then renamed), a pointer file names the
current generation, and generations older than 60 s are removed. On n8n: <!-- generated:search-n8n-summary -->245.1 MB on disk for 179.0 MB of indexable text (1.37x) across 29,124 tracked files, and a new session loads and checks it in 116 to 134 ms (slowest 143 ms) while the first search can already wait for it (2026-10-02)<!-- /generated -->.

**Freshness.** Inside `emetgate mcp` a session owns the mapped index, an in-memory delta of
the files that changed since, a change watcher (`src/platform/change_watch.zig`) and a
thread pool (`search_session.zig`). `initialize` starts the watcher on the server's own
thread and then loads, checks and reconciles the saved index on a background thread; the
first search waits for that only if it is still running. (Windows cancels a read that was
issued by a thread that has ended; an earlier version started the watcher on the warm-up
thread, so every new session's first search found it gone and fell back to a full stat.)
Reconciling lists every directory once (`stat_scan.zig`, no file is opened) and re-reads a
file whose size, last-write time or change time differs from its stamp; the change time
catches a rewrite that sets the last-write time back. A file whose last-write or change
time lies within 3 s of the moment it was read is given an impossible stamp at that moment
(git's racy smudge), so the next comparison re-reads it; this applies to the saved index
and to the in-memory delta alike. A file that could not be read is tried again at every
search. Every search first passes the barrier: a cookie file is created (delete-on-close)
under `.emetgate/cookies/` and the search waits until the watcher reports it; NTFS reports
the changes to one directory handle in order, so every change closed or flushed before the
call has been delivered by then. Only the changed files are read again (content, digest and
trigrams; their spans are parsed when a hit in them needs a kind or a symbol). The tracked
list comes from the git index file (`git_index.zig`: versions 2 to 4, checked against the
file's SHA-1 or SHA-256 trailer; a conflicted path is listed once and a submodule entry is
not a file; a split or sparse index falls back to `git ls-files`), and it is read again
only when that file's last-write time, size or file id changes. If the barrier overflows,
times out or finds the watcher gone, the search falls back to a full refresh that stats
every tracked file and re-reads each one whose stamp changed; nothing is reported clean on
a failure. Outside a session (the CLI, tests without one) every search does that full
refresh against the saved index.

Measured on the n8n clone with `tests/bench/n8n_fresh.py` (ReleaseFast, each change
followed at once by a search for a token only the changed state has; "barrier + refresh"
is the server's own time for the barrier, the list and the refresh, "search" the MCP round
trip of that search): <!-- generated:search-fresh-table -->

| Change, then search at once | rounds | barrier + refresh p50 ms | barrier + refresh p99 ms | search p50 ms | search p99 ms | misses |
|---|---:|---:|---:|---:|---:|---:|
| baseline: search with no write before it | 200 | 0.31 | 0.53 | 1.22 | 1.80 | 0 |
| save in place (write + close) | 200 | 0.51 | 0.93 | 2.15 | 5.23 | 0 |
| save by rename over the file | 200 | 0.77 | 1.14 | 2.63 | 5.73 | 0 |
| create a file and git add it | 200 | 14.37 | 25.08 | 24.23 | 40.23 | 0 |
| git rm and delete the file | 200 | 14.12 | 24.39 | 23.82 | 40.81 | 0 |
| create a file without git add (outside the tracked scope) | 10 | 0.43 | 2.00 | 1.57 | 3.27 | 0 |
| delete a tracked file from disk | 200 | 0.35 | 0.55 | 8.39 | 9.41 | 0 |
| put the deleted file back | 200 | 0.48 | 1.60 | 8.96 | 20.42 | 0 |
| git mv a tracked file | 200 | 15.25 | 28.07 | 27.89 | 59.63 | 0 |
| rename a tracked file without git (old path vanished, new path untracked) | 20 | 14.95 | 28.56 | 24.31 | 44.12 | 0 |
| git mv a directory of 15 tracked files | 50 | 14.96 | 18.92 | 17.07 | 22.88 | 0 |
| git checkout of 59 changed files, first search | 40 | 34.14 | 46.80 | 51.61 | 89.49 | 0 |
| git checkout of 523 changed files, first search | 40 | 172.71 | 233.02 | 260.75 | 359.40 | 0 |
| 100 files changed while no server ran, first search right after initialize | 30 | 233.89 | 277.24 | 152.38 | 174.00 | 0 |
| 100 files changed while no server ran, first search after a 3 s pause | 30 | 93.63 | 108.15 | 11.28 | 16.17 | 0 |
| save in place while another thread rewrites other tracked files | 200 | 1.87 | 2.95 | 4.60 | 9.59 | 0 |
| writer keeps its handle open (append), search after close | 40 | 0.28 | 0.65 | 1.47 | 2.74 | 0 |
| writer keeps its handle open (overwrite), search after close | 40 | 0.42 | 0.96 | 1.77 | 3.75 | 0 |
<!-- /generated -->

**What a search does not see.** Three things are outside the snapshot, and each is said
where the model reads it:

- *A write through a handle that is still open and not flushed.* Measured on n8n (40
  rounds each, `n8n_fresh.py`): after an append or an in-place overwrite through a handle
  kept open, `ReadDirectoryChangesW` reported nothing, not even 250 ms later (0 of 40),
  and the directory entry's size did not move either, so neither the barrier nor a full
  stat can see the write; the size read through a handle did move (40 of 40 for appends).
  Before the flush the search found the new text in 0 of 40 append rounds and 1 of 40
  overwrite rounds (that file was read again for an earlier change). After
  `FlushFileBuffers` the notification arrived every time, 0.3 to 0.5 ms later, and the
  next search found the new text in every round; closing the file has the same effect. The tool description says it ("a write is in the answer once its writer has
  closed or flushed the file"), and with `certificate:true` the reply carries
  `"sees":"writes closed or flushed before this search"`. Closing the gap would mean
  opening and querying files on every search: a handle stat costs 20 to 40 µs per file,
  about 1 s for every tracked file of n8n, so it only pays for a short list of files that
  changed recently, and a writer that has never flushed is not on any such list.
- *Files git does not track.* The scope is the tracked files (`basis: tracked`), as for
  `git grep`; a file that is created and not yet added is not searched, and a tracked file
  that was renamed on disk without git is reported `vanished` under its old name.
  Listing untracked, not ignored files took 1.3 to 5.3 s on n8n (`git ls-files -o
  --exclude-standard`), and one `git check-ignore` call 0.3 s.
- *Submodules and links.* A submodule entry is not a file and is not listed; a tracked
  symbolic link that is a real link on disk (`core.symlinks`) is reported `unreadable`,
  since following it could leave the repository.

Measured on n8n (29,000 tracked files) with `tests/bench/n8n_search.py` (ReleaseFast; rg
and git grep as the process a tool call starts; emetgate as the MCP round trip to a running
server and, for the kernel, the server's own time; "new session" is the first search after
`initialize`, at once or after 3 s; "right after a write" rewrites one file in scope before
each search): <!-- generated:search-n8n-table -->

| Search | rg ms | git grep ms | new session, at once ms | new session, after 3 s ms | warm p50 ms | warm p99 ms | kernel p50 ms | kernel p99 ms | barrier p50 ms | right after a write ms |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| a rare name in one package | 21.3 | 28.0 | 136.3 | 3.02 | 1.43 | 1.65 | 0.89 | 1.03 | 0.28 | 8.60 |
| a common name in one package | 22.3 | 29.7 | 124.8 | 3.54 | 2.10 | 2.97 | 1.54 | 2.36 | 0.26 | 10.66 |
| a regex with four alternatives | 22.2 | 30.0 | 120.2 | 3.93 | 2.54 | 2.96 | 2.00 | 2.26 | 0.26 | 3.26 |
| a name across the whole repository | 477.2 | 382.7 | 125.7 | 11.90 | 1.80 | 2.09 | 1.21 | 1.37 | 0.27 | 2.53 |
| a name in one file | 13.3 | 27.5 | 117.4 | 2.21 | 1.98 | 3.98 | 1.14 | 2.15 | 0.46 | 2.56 |
| read one symbol | - | - | - | - | 0.96 | 8.55 | - | - | - | - |
| read a line range | - | - | - | - | 2.04 | 2.93 | - | - | - | - |
<!-- /generated -->

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
search also re-reads the 43 files the index then left out (binary or over 1 MiB, the size
limit when this was measured) to see
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

### Find

`emetgate_find` (`src/protocol/find_tools.zig`, index in `src/platform/emet_file.zig`)
returns every place a literal text occurs in the files git lists for the repository
(tracked and untracked, not ignored): any bytes, any language, any encoding, case folded
by Unicode. The reply gives the hit and file counts, the 20 files with the most hits and
the first 40 hits with their lines, so its size does not grow with the number of hits.

The index is one `.emet` file per repository under `%LOCALAPPDATA%\emetgate\find`: a
suffix array over the folded text with a wavelet matrix that maps each suffix to its
file, plus the size and modification time of every file. A search is a binary search
over the suffix array and a walk of the wavelet matrix, so its cost depends on the
pattern and the number of files hit, not on the size of the repository.

The index is built once in the background and kept. Changed files do not rebuild it:
the server watches the working tree, hides the indexed copy of a changed or removed file
and indexes the current copies of the changed files in a small in-memory index searched
together with the large one. Only when more than 256 files or 4 MB have changed is the
whole index built again, in the background, and swapped in when ready. A file git
ignores never enters either index. When the server starts it compares every indexed
file's size and modification time against the disk, reading each directory once.

```
emetgate find <pattern> [--root <dir>]
emetgate find build [--root <dir>]
emetgate find bench <pattern>... [--root <dir>]
```

On n8n (29,129 files, 204 MB of text, a 2.5 GB index) the index builds in about 105 s,
the first search after the server starts takes about 1 s, and a search then takes
0.1 to 0.25 ms at the median and under 0.5 ms at p99.

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

The facts are `def(kind, name, qualified name, file, span, body hash, alpha hash, signature, first doc line)`,
`ref(from, target or unresolved(reason), file, line, kind: call | new | read | write | type | import)`,
containment through each definition's parent, and `imports(file, file | external)`. Names
resolve with `src/engine/scope.zig` and imports with `src/engine/modules.zig`: relative
paths, tsconfig `paths` and `baseUrl` (following `extends`), and workspace `package.json`
entries mapped from `outDir` to `rootDir` as the package's own tsconfig files declare them.
A member call binds through `this`, a class used statically, a namespace import, a declared
type, a constructor parameter property or a constant made with `new`. The last three are
labelled `typed`, the others `proven`. Everything else stays `unresolved` with its reason.

The store lives in `%LOCALAPPDATA%\emetgate\facts\<repo hash>\facts.v4`: versioned, with a
BLAKE3 checksum, written to a temporary file and moved into place. A refresh lists the
tracked files, compares directory stamps, re-reads only changed files (a file stamped within
2 s of the store's write time is always re-hashed), extracts a file again only when its
content hash changed, and relinks only the files whose links read a file whose exports or
definitions changed.

`emetgate mcp` runs this refresh on a background thread that it starts before it reads the
first message, so `initialize` and `tools/list` are answered without waiting for the store.
`emetgate_explore` and `emetgate_evidence` wait for a refresh that is still running and then
answer from the whole store; the telemetry event of such a call carries the reason `waited for
the fact store build`. The other tools do not read the store and answer while it is being
built. If the build fails, the next call to either tool builds the store once more before it
answers; if that fails too, the tool refuses with `explore is unavailable` or `evidence is
unavailable` and the event names the error. Neither tool answers from the part that was read.
When the client closes the server during the build, the build stops before it reads the next
file and writes no store, and the next start builds it again.

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
| store, memory | 62.7 MB on disk with the outline, the test blocks, each definition's signature and the first line of its doc comment (54.7 MB without the last two, 47.8 MB before the outline); peak working set 794 MB while building, 410 MB loaded |
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

For the engine (`cas`, `boundedness`, `symbol`, `functions`) that is <!-- generated:engine-mutant-summary -->69 mutants today: 58 killed, 6 proven equivalent, 4 redundant guards kept as defense in depth, 1 open<!-- /generated -->. Generated by `tools/readme_facts.py` from `tests/mutations.json`; the full breakdown by area is in [`VERIFICATION.md`](VERIFICATION.md).

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
| Python | `.py`, `.pyi` | tree-sitter-python | cross-reference facts and `emetgate_rename`; overload stubs, deleters and short refs (see Reader) |
| C# | `.cs` | tree-sitter-c-sharp | cross-reference facts and `emetgate_rename`; every member kind, overloads and short refs (see Reader) |
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

**F8 — a doc edit in a batch wrote a source file past the rules, and a batch of doc edits only ended the server.** Up to v0.5.1, `emetgate_try_batch` and `emetgate_write_doc` took a line range, with a hash from a `raw:true` read, on a file of a registered language. No rule is applied to a doc edit, so a change an enforced rule forbids (two comment lines under `no_comment`, which the same change as a symbol edit answers with `rule_violation`) was written once the tests passed. Separately, the reply code of a committed batch took the repository root from its first code edit; with doc edits only that list was empty, so after the files were written the server stopped on an index out of bounds, sent no reply and logged no event. This held for a batch with one Markdown edit as well. Found by a user replaying one call over stdio. Fixed on `fix/batch-doc-on-source`: a doc edit of a file of a registered language is refused with `UseSymbolToolsForSource` before anything is planned, by the single call and by the batch alike, and the reply code takes the root from the edits the call has and writes a receipt only when the batch changed code. Tests are in `tests/batch_doc_source.zig`; not yet released.

**F9 — Emetgate's own folder could be read through its short name, and a repository reached through a short path refused its own files.** Up to v0.5.2 the jail compared paths as they were spelled. `realPathFileAlloc` does not expand a Windows short (8.3) name, so a path given as `EMETGA~1/ledger.ndjson` did not start with `.emetgate` as text and `emetgate_read_file` with `raw:true` returned the ledger. A write through the same name was refused (`UnsafePath`), and `GIT~1/...` was refused only by the nested-repository check, as `FileOutsideRepo`. The same comparison failed the other way when the working directory was spelled with a short name: git reports the repository root by its long name, the file kept the short one, and every tool answered `FileOutsideRepo` for the repository's own files. That is how it was found: the nightly attack corpus runs in the runner's temp folder, `C:\Users\RUNNER~1\...`, and had failed every night since 26 September behind an unrelated error of its runner. Fixed on `fix/short-path-root`: the served root and every path are compared by their final long name, a path whose final name cannot be read is refused, and both aliases answer `InternalPath`. `tests/short_path_jail.zig` serves a repository through its short path and checks that a path outside, a junction, a nested repository, a subst drive and the two aliases are still refused; mutants `SP1` to `SP5` and `EP9` to `EP11` guard it. Not tried against v0.5.2: creating a new file under the short name.

**F10 — a rename, a move and a file move wrote text an enforced rule forbids.** In every release that has `emetgate_rename`, `emetgate_move` or `emetgate_move_file`, from v0.2.0 to v0.6.0, the gate judged the range a writer handed it and nothing else, and a file a writer rewrote without naming a symbol was not judged at all. The other files of a rename, the source and user files of a move, the imports the kernel derives and a moved file as a whole reached disk without a check; in the declaring file of a rename only the function body was read, so the new name itself was not. A `cmd:` rule ran only for a file edited under a symbol name, so it did not run on a file move at all, and a rule scoped to another symbol of the same file did not run. An `added:` rule compared against the target path on disk. A write could also take the file or the symbol a rule was scoped to out of that scope, after which the rule covered nothing and `emetgate scan` stopped with `ScopeUnresolved`. The release notes of v0.5.2 to v0.6.0 named the first part as a limit that had been read and not tested. Found by a review of the rule loop and proven with twenty-one scripts against the published v0.6.0, without `--commit` as well. Fixed in v0.6.1 by reversing the default: every file a write produces is new except the bytes a writer claims and the gate confirms, content that enters a scope is new there, a write that leaves a scope is refused, and a command rule is due for every path a write changes (see "What a write is checked against"). Each proven case is a test (`tests/every_write.zig`, `tests/every_write_scope.zig`, `tests/every_write_old.zig`), and `tests/write_invariant.zig` runs seeded operations through every write tool the server lists and requires that a scan finds nothing new after an accepted write.

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
- **Linked directory cost.** In the kept tree the links of a linked directory are made once and checked on each call by reading its directories; the table under "The kept tree" gives the measured times (eslint's `node_modules`, 38,542 files: 31.0 s for the first call, about 1 s afterwards). With `--shadow-tree copy`, on another volume than the shadow root, or without hard links, the hardlink tree is rebuilt for every proposal as before: 2 to 5 s for express's `node_modules` (6,634 files) and 20 to 33 s for eslint's, plus the time to delete it afterwards. Junctions and symlinks inside a linked directory are still skipped, so a package manager layout made of links (pnpm) is not reproduced in either tree.
- **Committing gate.** Tracked files of a committing call come from emetgate's own checkout of `HEAD`; what that rests on, and what it does not cover (untracked and ignored files of a linked directory, the system-wide attributes file, two names that differ only in case), is listed under "The gate tests the tree the commit will hold".
- **Kept tree.** A test command cannot write a tracked file in place (see "The kept tree" for `--shadow-private` and `--shadow-tree copy`). Whether a working file may be linked is decided when the link is made: a file whose integrity label is lowered afterwards stays linked until its name changes. A tracked symlink is copied by following it and a submodule entry is left out, in both trees. The fallbacks for another volume and for a volume without hard links are tested through a seam, not on such a volume.
- **Repository ledger.** With `--allow-repo-memory`, a committed ledger's `cmd:` rules run under the same confinement as the test command: they cannot write outside the shadow copy, but they can read and reach the network. Pass the flag only for a ledger you have reviewed. Without the flag only execution is withheld; the text of every rule in a committed ledger is still shown to the model in `emetgate_skeleton`, so a hostile rule text is data the model reads, not a command anything runs.
- **Documents.** The syntax forms (`no_comment`, `forbid:`, `no_literal:`, `q:` and their `added:` forms) are not applied to a doc edit (`emetgate_write_doc`, `"kind": "doc"`): a JSON, Markdown or other text file that is not of a registered language has no tree for them to read. `cmd:` rules, `frozen` and the message rules do apply to it. A source file edited that way is refused (F8 in Security history).
- **Rules on a write.** What the gate judges is listed under "What a write is checked against". It does not cover: a write path added later that does not call the one entry (nothing in the compiler stops that yet; the invariant test covers only tools the server lists); the working files recovery finishes after a crash, which are tied to the commit and not judged again; a declaration moved out of a directory scope and a file deleted under one, neither of which is refused; a rule adopted after the content was written, which is `scan`'s job; text outside any changed range whose syntax node changes kind because of a change beside it, unless a rule matches it; and anything written by another tool. A declaration that already breaks a rule cannot be moved into a file under that rule even when the rule also covered its old file, because the moved text is new in the target. A `cmd:` rule cannot tell old from new: on a tree that already fails it, it refuses every write its scope covers.
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
starts itself as shards that take the tests from one queue, slowest first by the times of the
last run kept in `.zig-cache/test-all/times.tsv`, and fails unless together they ran every
selected test exactly once. `-Dtest-part=I/N` (`--part I/N`) runs only part I of N: the selected
tests are split by the times committed in `tests/test_times.tsv`, the slowest first, each to the
part with the least time so far, so every machine computes the same split; the CLI end-to-end
cases run in part 1. `-Dtest-manifest=PATH` (`--manifest=PATH`) writes every selected test and
every test the part ran. CI runs each optimize mode in four parts on four machines, and the
`test (Debug)` and `test (ReleaseSafe)` checks fail unless `tools/check_parts.py` finds that all
four parts passed, selected the same tests and together ran each of them exactly once. A test
missing from `tests/test_times.tsv` counts as one second.
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
