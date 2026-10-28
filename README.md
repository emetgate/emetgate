<p align="center">
  <img src="assets/aleph.svg" alt="Emetgate" width="190">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-windows-0078D6?style=flat-square" alt="Platform: Windows">
  <img src="https://img.shields.io/badge/languages-typescript%20%7C%20javascript%20%7C%20python%20%7C%20c%23%20%7C%20zig-3178C6?style=flat-square" alt="Languages: TypeScript, JavaScript, Python, C#, Zig">
  <img src="https://img.shields.io/badge/protocol-MCP-1E1B26?style=flat-square" alt="Protocol: MCP">
  <a href="https://github.com/emetgate/emetgate/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/emetgate/emetgate/ci.yml?branch=main&style=flat-square&label=tests" alt="Tests"></a>
  <a href="https://github.com/emetgate/emetgate/releases/latest"><img src="https://img.shields.io/github/v/release/emetgate/emetgate?style=flat-square" alt="Latest release"></a>
</p>

<p align="center"><b>English</b> · <a href="translations/README.tr.md">Türkçe</a> · <a href="translations/README.ko.md">한국어</a> · <a href="translations/README.zh-CN.md">简体中文</a> · <a href="translations/README.es.md">Español</a></p>

# Emetgate

LLMs are fast and capable — hours of work in minutes. But whether they follow your rules is up to them: a model can read "never use this" and use it anyway.

The usual answer is a better prompt, a longer `AGENTS.md` — rules the model is *asked* to obey. Emetgate takes the other path: a layer between the model and your source tree. Not an instruction it can skip — a gate it has to pass. The model proposes a change; the kernel verifies it; nothing reaches disk unless it passes.

It runs as an MCP server, on Windows, for TypeScript, JavaScript, Python, C# and Zig. Below, each capability is broken into its parts — what each part is, and what it does here. No claim without the code and the real output under it.

## The gate

A change names a symbol and the hash of the code it was based on. Emetgate puts the new body in place, reparses the file, runs your rules, then runs your typecheck and your tests on a copy of the repository inside a sandbox. If every step passes it is written and bound to a receipt; if any step fails, nothing is written.

```
proposal ─▶ reparse ─▶ rules ─▶ typecheck ─▶ tests ─▶ write + receipt  (אמת)
                  └── any step fails ─▶ nothing is written (מת)
```

| part | what it is | what it does here |
| --- | --- | --- |
| shadow workspace | an isolated copy of the repository | the proposed write is applied here first, so tests and typecheck run without touching the real tree; on failure the disk never changed |
| tree-sitter | an incremental parser | reparses the file to show the change actually parses, and did not break the tree |
| in-toto receipt | a supply-chain provenance format | binds each passing write to a record of what was built from what, with which tests — checkable later (not signed yet) |

## Search

Two engines: a literal index for speed, and a certified engine for proof.

### `emetgate_find` — literal search

Plain-text and indexable-pattern search, without going back to disk. Sub-ms warm.

| part | what it is | what it does here |
| --- | --- | --- |
| suffix array (SA-IS) | the sorted array of every suffix of the text, built in linear time | finds a literal in one `O(m·log n)` binary search, with all its matches at once |
| two wavelet trees | position→file and repeat-chain maps over the array | tells which match sits in which file, without re-reading the file from disk |
| mmap'd `.emet` index | one memory-mapped index file | files are not reopened during a search; `~0.7–1 ms` warm |

### `emetgate_search` — certified search

Search that carries, with the result, a proof that it missed nothing.

| part | what it is | what it does here |
| --- | --- | --- |
| trigram postings | a compressed inverted index (Elias-Fano / bitmap) | narrows the candidate files fast, without scanning the whole repo |
| RFC 9162 Merkle tree | a root over the SHA-256 of every file read | the reply carries the root, so a complete or partial answer is provable, not asserted |
| fail-closed | the certificate is refused as `InconsistentCertificate` if the numbers do not add up | a wrong "complete" is never shown; when in doubt it stays silent |
| NTFS change barrier | file-change notice via `ReadDirectoryChangesW` | only a changed file is re-read (freshness); zero misses in the benchmark |
| ripgrep delegation | a regex the index cannot serve (`\b`, lookaround…) | is handed to ripgrep; the reply says `delegated: rg` — no loss of capability |

The reply carries proof, not a claim — real output:

```
$ search "InconsistentCertificate"
✓ 6 matches in 429 files            # complete, with the Merkle root
$ search "Allocator"
partial: matches 1-46 of 1617; next offset:46
$ search "zzzNeverOccurs"
✓ no match in 569 files              # even zero is proven
```

> warm ~1.5–3.5 ms · cold (index build) 661 ms · line-for-line parity with ripgrep

## Rules

A policy you set once is held on every write. The model reads the rules and cannot change them.

| part | what it is | what it does here |
| --- | --- | --- |
| tree-sitter queries | structural matches over the syntax tree | span/symbol/comment checks: `no_comment`, `require_comment`, `max_function_lines`, `forbid_import`… |
| regex engine (budgeted) | a step-limited matcher | `forbid_regex` / `no_todo`: a pattern or marker hunt in the changed span |
| `ledger.ndjson` | an append-only rule book (`.emetgate/`) | rules live here; the model reads them but cannot write them — policy stays human |
| commit-message check | a message-surface rule | `message:conventional`: conventional commits held at commit time |

```
emetgate rule add "ban lodash"        --check forbid_import:lodash --enforce
emetgate rule add "document exports"  --check require_comment --in src/ --enforce
```

## Verified Git

`emetgate verify --branch base..head` replays every commit of a range against its receipts and returns one verdict for the range. Receipts are not signed and the chain tip is not stored or published, so this catches a receipt edited inconsistently with its commit; it does not catch a commit rewritten together with a freshly made, consistent receipt.

| part | what it is | what it does here |
| --- | --- | --- |
| blake3 hash chain | each cert = blake3(parent ‖ oid ‖ verdict ‖ receipt) | a changed verdict or receipt shifts the tip, which shows only against a tip kept from an earlier run |
| CAS refs + private index | write-tree / commit-tree without touching the working tree | a gated, receipted commit — without disturbing your editor |
| in-toto receipts | provenance bound to the commit (`refs/notes/emetgate`) | no receipt → `partial` (fail-closed); no fabricated "verified" |
| git rev-list replay | walks the `base..head` range | re-runs the single-commit verify for each, weaving the chain; an empty range is `empty` and fails, never green |

```
$ emetgate verify --branch main..HEAD
branch partial: 48 commit(s)          # no receipt → fail-closed
  a179a7f unverified (no receipt)  cert 84c2…

# tamper with one receipt:
branch broken: 1 commit(s)
  3ff23a0 MISMATCH  cert ec79…         # the chain tip shifted → caught
```

## How it's tested

| part | what it is | what it does here |
| --- | --- | --- |
| mutation testing | breaks the code on purpose and checks the suite notices | proves the tests *catch* a fault, not just that they pass |
| fuzz & red-team | random mutation plus attack corpora | no crash or escape on unexpected or hostile input |
| ripgrep parity gate | compares the hit-set against rg on every run | search cannot be "fast but wrong"; checked line for line |

For the engine: <!-- generated:engine-mutant-summary -->69 mutants today: 62 killed, 4 proven equivalent, 2 redundant guards kept as defense in depth, 1 open<!-- /generated -->. The list is in [VERIFICATION.md](VERIFICATION.md).

## Measured

| surface | measure | result |
| --- | --- | --- |
| full test suite | pass / fail / leaked | 1908 / 0 / 0 |
| search parity | rg lines = emetgate | 1617=1617 · 6=6 · 2=2 |
| search warm | median | 1.5–3.5 ms |
| find warm | median | 0.7–1.0 ms |
| verify (hand-edited receipt) | verdict | broken (caught) |

```
python tests/bench/n8n_search.py   ·   zig build test
```

## Install

New here? Follow [docs/QUICKSTART.md](docs/QUICKSTART.md): install, run `emetgate doctor`, then `emetgate lockdown`.

Download the Windows binary from the [latest release](https://github.com/emetgate/emetgate/releases/latest) and put its folder on your `PATH` (PowerShell; open a new terminal afterwards):

```
New-Item -ItemType Directory -Force "$env:USERPROFILE\emetgate" | Out-Null
Invoke-WebRequest "https://github.com/emetgate/emetgate/releases/latest/download/emetgate.exe" -OutFile "$env:USERPROFILE\emetgate\emetgate.exe"
[Environment]::SetEnvironmentVariable("Path", [Environment]::GetEnvironmentVariable("Path", "User") + ";$env:USERPROFILE\emetgate", "User")
```

Then, in the project folder:

```
emetgate lockdown --test "npm test"
```

Windows · TypeScript / JavaScript / Python / C# / Zig. `emetgate lockdown` starts the agent with only the emetgate tools, fail-closed. Leave `--test` out and the test command is detected on every write (`package.json` `scripts.test`, `build.zig`, `Cargo.toml`, `go.mod`, `pyproject.toml`, a `.sln` or `.csproj`). In an empty folder lockdown runs `git init`, and writes land as `unverified_no_tests` until the project has a test command.

Lockdown reads only the project's own `.mcp.json`, never a server registered at user scope. To use emetgate as a server next to the other tools, or to give lockdown your own server arguments, register it for the project:

```
claude mcp add --scope project emetgate -- emetgate mcp --test "npm test"
```

With that `.mcp.json` in place, lockdown takes the test command from it, and `emetgate lockdown --test` is refused.

## Dig deeper

- [REFERENCE.md](REFERENCE.md) — every tool
- [VERIFICATION.md](VERIFICATION.md) — receipts & proof
- [tests/bench](tests/bench) — the benchmarks

## Limits

Windows only; TypeScript, JavaScript, Python, C# and Zig. The sandbox blocks writes, not reads or the network. Passing the gate proves a change parses and passes *your* tests — it is only as strong as those tests. The benchmarks are our own, from one machine, and reproducible.

## Where the name comes from

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/golem-ales-dark.jpg">
  <img src="assets/golem-ales-light.jpg" alt="A 1899 pen drawing: Rabbi Loew raises his hand and the golem's face forms in smoke, Hebrew letters on its forehead" width="220" align="left">
</picture>

In the Prague legend, the golem is brought to life by the word **אמת** (*emet*, "truth") on its forehead. Erase the first letter and **אמת** becomes **מת** (*met*, "dead") — the golem falls still. The gate writes the first letter when a change holds; a failing test erases it.

<br clear="left">

## License

MIT. See [LICENSE](LICENSE).
