<p align="center">
  <img src="assets/banner.png" alt="Emetgate" width="640">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-windows-0078D6?style=flat-square" alt="Platform: Windows">
  <img src="https://img.shields.io/badge/languages-typescript%20%7C%20javascript%20%7C%20zig-3178C6?style=flat-square" alt="Languages: TypeScript, JavaScript, Zig">
  <img src="https://img.shields.io/badge/protocol-MCP-1E1B26?style=flat-square" alt="Protocol: MCP">
</p>

<p align="center"><b>English</b> · <a href="README.tr.md">Türkçe</a> · <a href="README.ko.md">한국어</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.es.md">Español</a></p>

# Emetgate

A gate between a coding model and your source tree. The model proposes a change, Emetgate checks it, and the change reaches disk only if the checks pass.

It runs as an MCP server for Claude Code, on Windows, for TypeScript and JavaScript projects.

<p align="center">
  <img src="assets/demo.gif" alt="The gate refusing a placeholder and a test-breaking body and committing a correct one; a search against rg; a node edit against Read and Edit" width="900">
</p>

## What it does

**It checks every write.** A change names a symbol and the hash of the code it was based on. Emetgate puts the new body in place, reparses the file, runs your rules, then runs your typecheck and your tests on a copy of the repository inside a sandbox. If any step fails, nothing is written. Each commit leaves a receipt that `emetgate verify` can check again later without trusting the process that wrote it.

**It reads code for the model.** `emetgate_explore` answers a question about the codebase with whole definitions and line numbers. `emetgate_evidence` returns the full code of the symbols you name. There are also tools for symbols, files, search and git; the list is in [REFERENCE.md](REFERENCE.md#mcp-tools).

**It keeps your rules.** You add a rule once from the command line. The model can read the rules and cannot change or remove them.

```
emetgate rule add "no console.log" --check "cmd:npx eslint --rule no-console" --in src/ --enforce
emetgate rule add "no networkidle waits" --check forbid:networkidle --enforce
```

## Install

Each release publishes `emetgate.exe` and its SHA-256 on the [releases page](https://github.com/emetgate/emetgate/releases).

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\emetgate" | Out-Null
foreach ($f in "emetgate.exe", "emetgate.exe.sha256") { Invoke-WebRequest "https://github.com/emetgate/emetgate/releases/latest/download/$f" -OutFile "$env:USERPROFILE\emetgate\$f" }
(Get-FileHash "$env:USERPROFILE\emetgate\emetgate.exe" -Algorithm SHA256).Hash -eq (Get-Content "$env:USERPROFILE\emetgate\emetgate.exe.sha256").Split(" ")[0]
claude mcp add emetgate -- "$env:USERPROFILE\emetgate\emetgate.exe" mcp --test "npm test"
```

The binary is not code-signed, so SmartScreen warns on first run. Compare the checksum instead.

`emetgate lockdown` starts Claude Code with only Emetgate's tools, so every write goes through the gate.

## Measured

I asked 15 questions about four repositories through Emetgate, Serena, codebase-memory-mcp and Claude Code's own tools: the same model (`claude-sonnet-5-5`), a fresh copy of the repository for every run, no extra prompt, three runs per question. The score is the share of answer-key points the answer names; I wrote the keys before any tool ran.

| Tool | Score | Tokens | Cost |
|---|---:|---:|---:|
| Emetgate | 240/252 | 86.7k | $0.132 |
| Serena | 242/252 | 143.8k | $0.143 |
| Claude Code's own tools | 234/252 | 171.4k | $0.150 |
| codebase-memory-mcp | 246/252 | 178.5k | $0.204 |

Emetgate uses the fewest tokens and costs the least in this set. It is not the most accurate: two tools score higher. A gap of two points in 252 is inside the run-to-run spread, so these runs do not rank the tools on score.

I also typed three more questions into the four tools by hand, one run each. Emetgate again used the fewest tokens, and Claude Code's own tools were cheaper and faster:

<p align="center">
  <img src="tests/bench/hand/three-questions.png" alt="Three questions, four tools, one model: tokens, API time and cost of each tool" width="900">
</p>

What the 345 recorded sessions showed about cost:

- A session's cost is fixed by four token counts, and a token written to the cache costs 20 times a token read from it. Fewer tokens does not always mean a lower bill.
- One more model call costs about as much as 8,000 characters of tool output.
- The model writes what it asked for. A key point it named in its own tool call reached the answer 98.5% of the time; one it only saw in a reply, 90.5%.

The sessions, questions, answer keys and the script that produces these numbers are in [tests/bench/neutral](tests/bench/neutral). The hand test with its full answers is in [tests/bench/hand](tests/bench/hand). Token counts for single reads, edits and searches are in [REFERENCE.md](REFERENCE.md).

## How the gate is tested

- **Mutation testing.** Each guard is broken on purpose and at least one test must fail. For the engine: <!-- generated:engine-mutant-summary -->64 mutants today: 57 killed, 4 proven equivalent, 2 redundant guards kept as defense in depth, 1 open<!-- /generated -->. The list is in [VERIFICATION.md](VERIFICATION.md).
- **Model checking.** The commit journal is specified in TLA+ and checked with TLC, including crashes during recovery.
- **Crash tests.** Batches are cut after every step and recovered.
- **Red-team and fuzz suites** against the MCP surface, the sandbox, the journal and the parsers.

Findings against the gate and their fixes are listed in [REFERENCE.md](REFERENCE.md#security-history).

## Limits

- Windows only. TypeScript, JavaScript and Zig only.
- Passing the gate means the code parses, stays in bounds and passes your tests. It does not mean the code is correct, and the test gate is as strong as your tests.
- The sandbox blocks writes outside the copy. It does not block reads or network access.
- Changes made outside the gate are not covered. That is what lockdown is for.
- Node.js 24.15.0 and earlier crash intermittently on Windows loopback connections; use 24.16.0 or later.

## Build

Zig 0.16.0. tree-sitter and the grammars are vendored.

```sh
zig build                  # zig-out/bin/emetgate
zig build test             # all tests
tools/accept.ps1 <ref>     # tests three times, then the mutants on lines changed since <ref>
```

## License

MIT. The vendored grammars under `vendor/` keep their own MIT licenses.

<p align="center"><b>English</b> · <a href="README.tr.md">Türkçe</a> · <a href="README.ko.md">한국어</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.es.md">Español</a></p>
