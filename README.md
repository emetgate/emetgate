<p align="center">
  <img src="assets/banner.png" alt="Emetgate" width="640">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/status-early-E040FB?style=flat-square" alt="Status: early">
  <img src="https://img.shields.io/badge/zig-0.16.0-F7A41D?style=flat-square&logo=zig&logoColor=white" alt="Zig 0.16.0">
  <img src="https://img.shields.io/badge/platform-windows-0078D6?style=flat-square" alt="Platform: Windows">
  <img src="https://img.shields.io/badge/languages-typescript%20%7C%20javascript-3178C6?style=flat-square" alt="Languages: TypeScript, JavaScript">
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

**Test gate.** `UNBOUNDED` changes are applied to a shadow copy and the project's test command is run against it inside a sandbox (a Windows Job Object with kill-on-close, wall-clock and memory limits, and an output cap). The command runs under a low-integrity restricted token, so a body proposed by the model cannot write anywhere outside the shadow copy; if that token cannot be built and verified, the command is refused rather than run unconfined. If the tests fail, the change is rejected and the output is returned to the model. A command that exits but leaves a process behind in the job fails too (`leftover_processes`). After the exit the sandbox reads the pipes to EOF and waits for the job to empty, for up to 2 s and never past the command's deadline; the exited command's own console host is not counted. Whatever is still running after that is killed and reported.

**Durable commit.** Accepted changes go through a write-ahead journal and an atomic write-rename. A crash at any point leaves either the old file or the new one, never a torn write. `recover` replays the journal and refuses anything it cannot prove: zero-byte files, entries that no longer re-parse, and malformed tags.

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

`--check` names the predicate. Two kinds exist and the prefix decides which:

| Form | Meaning |
|---|---|
| `no_comment`, `forbid:<text>`, `no_literal:<option>` | Built-in AST checks, run against the proposed body in memory |
| `cmd:<command line>` | A command, run in the shadow copy inside the sandbox |

Anything without the `cmd:` prefix is looked up in the built-in registry. An unknown name
returns `UnknownCheck`; it is not interpreted as a shell command.

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

| Ledger | `cmd:` rules | AST checks |
|---|---|---|
| untracked (written by `emetgate rule` on this machine) | run | enforced |
| tracked by git, no `--allow-repo-memory` | **never run**: a proposal a `cmd:` rule covers is refused with `UntrustedRepoMemory` (exit code 37) | enforced |
| tracked by git, `try` or `mcp` started with `--allow-repo-memory` | run | enforced |

"Tracked" means `git ls-files` lists `.emetgate/ledger.ndjson`, or `.emetgate` itself (for
example as a symlink), under any spelling of case, since Windows opens `.EMETGATE/Ledger.ndjson`
as the same file. The refusal fails closed: the proposal is rejected with a named error, not
let through with the rule silently skipped. A `cmd:` rule whose `--in` scope does not cover the
edit is not consulted, so it does not block. If git cannot answer, the proposal is rejected.

AST checks (`no_comment`, `forbid:`, `no_literal:`) from a tracked ledger stay enforced without
the flag. They execute nothing: the most a hostile static rule can do is refuse an edit, and every
rule is visible in `emetgate_skeleton` and `emetgate rule list`.

`--allow-repo-memory` is a startup flag of `emetgate try` and `emetgate mcp`. The model cannot
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
│   ├── disk                          journal, atomic write, recovery
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

`emetgate lockdown` starts Claude Code with only these tools available, so the model has no path to the disk other than the gate.

The repository ships a Claude Code skill, `.claude/skills/md-audit/SKILL.md`, that audits a CLAUDE.md or AGENTS.md file: it sorts every instruction sentence into enforceable, waiting for a mechanism, unverifiable or belief, proposes a check and scope for the enforceable ones, measures each with `emetgate_scan` and reports, changing nothing. To use it in every project, copy the `md-audit` folder into `%USERPROFILE%\.claude\skills\` (`~/.claude/skills/` elsewhere).

## How the kernel itself is verified

The kernel's guards are tested in two ways.

**Mutation testing.** Guards and branches that protect an invariant are mutated (a check removed, a condition weakened, a comparison flipped) and the test suite is run against each mutant. At least one test must fail. A surviving mutant is either made to fail with a new test or recorded in `tests/mutations.json` as equivalent, intentionally redundant, or open. The harness lives in `tools/mutate`.

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
| Rule enforcement at the edit gate | Built, mutation-tested: AST checks and `cmd:` command predicates |
| Language support | TypeScript and JavaScript (`.js`, `.mjs`, `.cjs`); new languages are added as profiles under `src/engine/lang` and must pass the conformance suite in `tests/lang` |
| Platform | Windows only (the sandbox relies on Job Objects) |

On the token benchmark in `tests/bench` (tokenizer `o200k_base`, six scenarios, two of them real files), editing through symbol-level proposals uses a median of **1.80×** fewer tokens than search-and-replace editing, with a range of 1.15× to 3.77×. On the real files the gain is 1.15× to 1.17×.

Each scenario counts the tokens both approaches spend on one symbol edit: ingest plus emit. Search-and-replace reads the whole file and sends the old and new block; the kernel reads a skeleton plus one symbol body and sends a symbol reference, a content hash and the new body. Search-and-replace is the baseline; a whole-file rewrite is the upper bound (2.88× on the same set). The tokenizer is a GPT-4o-family proxy, so the ratio matters more than the absolute count. The benchmark runs offline and can be reproduced with `python tests/bench/run4.py` after building the binary.

## Security history

Findings against the gate, oldest first.

**F1 — the write tools were not confined to the served repository.** The read tools checked the repository boundary, but `emetgate_try` and `emetgate_try_batch` did not. Given an absolute path, the gate verified a file in another git repository on the machine against that repository's own tests and wrote to it. An audit showed this with a real MCP call that returned `committed`. The same audit attacked the splice, the parse error check, content hashes and the atomic commit, and none of those attacks got through. Fixed in `0226b07` (2026-09-15) and `cab97cd`, which send every tool through `repo.jail` against the served root, first released in v0.1.2.

**F3 — a rejected proposal could write to the real repository during its tests.** The test command ran in a Job Object, which limited time and output but not where the command could write. A body that failed the tests on purpose changed a file in the real tree while they ran: the gate answered `rejected` and the write stayed. Since `6cc77b0` (2026-09-18) the command runs under a low-integrity restricted token, and if the token cannot be built the command does not run. Red-team tests are in `tests/redteam_sandbox.zig`; first released in v0.1.2.

**Repository ledger — `cmd:` rules from a committed ledger ran without consent.** A cloned repository that carried `.emetgate/ledger.ndjson` had its `cmd:` rules run in the sandbox on the first edit. This was found by reading the code during an audit. Fixed in PR #31 (`46f9173` to `66d1ed4`): without `--allow-repo-memory` those rules do not run and the edit is refused with `UntrustedRepoMemory`. Red-team tests are in `tests/redteam_ledger.zig`; first released in v0.1.5.

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

Requires Zig 0.16.0. tree-sitter and the TypeScript grammar are vendored.

```sh
zig build                 # zig-out/bin/emetgate
zig build test            # unit and end-to-end tests
zig build mutate-tool     # mutation harness
```

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
