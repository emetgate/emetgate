# Quickstart

From download to a locked Claude Code session in five steps. Windows 10/11 only.

## 1. Get emetgate

**Release binary (recommended).** Download `emetgate.exe` and `emetgate.exe.sha256` from the [latest release](https://github.com/emetgate/emetgate/releases/latest) into `%USERPROFILE%\emetgate`, then check it:

```powershell
(Get-FileHash $env:USERPROFILE\emetgate\emetgate.exe -Algorithm SHA256).Hash.ToLower()
Get-Content $env:USERPROFILE\emetgate\emetgate.exe.sha256
```

**Or build from source.** You need Zig **0.16.0** ([download](https://ziglang.org/download/#release-0.16.0)); another Zig version fails to build it, often with errors inside `build.zig` that do not mention the version, so check `zig version` first:

```powershell
git clone https://github.com/emetgate/emetgate
cd emetgate
zig build -Doptimize=ReleaseSafe
New-Item -ItemType Directory -Force $env:USERPROFILE\emetgate | Out-Null
Copy-Item zig-out\bin\emetgate.exe $env:USERPROFILE\emetgate\
```

## 2. Put it on PATH

```powershell
[Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path','User') + ";$env:USERPROFILE\emetgate", 'User')
```

Open a **new** terminal, then `emetgate --version` should print the version.

You also need [Claude Code](https://docs.claude.com/en/docs/claude-code) signed in (`irm https://claude.ai/install.ps1 | iex`, then `claude auth login`) and [Git](https://git-scm.com/download/win) (`winget install --id Git.Git -e`).

## 3. Tell emetgate how to run your tests

Every write the model makes is applied to a copy of your repository and kept only if your tests pass there. Without a test command, lockdown still starts, but every write is refused with `NoTestCommand`. In the root of your repository:

```powershell
claude mcp add --scope project emetgate -- emetgate mcp --test "npm test"
```

Use whatever runs your tests (`zig build test`, `npx vitest run`, ...). This writes `.mcp.json`, which lockdown reads; commit it if your team uses emetgate too. Add `--typecheck "npx tsc --noEmit"` to also gate on the type checker.

## 4. Check the setup

```powershell
emetgate doctor
```

One line per check, each `ok`, `warn` or `FAIL`, and every `FAIL` ends with the command that fixes it:

```
ok    emetgate  0.8.0 at C:\Users\you\emetgate\emetgate.exe
ok    claude    2.1.311 (Claude Code) at C:\Users\you\AppData\Roaming\npm\claude.cmd
ok    login     signed in
ok    git       C:\Program Files\Git\cmd\git.exe
ok    repo      C:/Users/you/proje
ok    .mcp.json one emetgate server
ok    tests     "npm test"
ok    write     C:/Users/you/proje
ok    state     C:\Users\you\AppData\Local\emetgate\lockdown\...
ok    sandbox   low-integrity cmd.exe ran
ok    appcntr   AppContainer profile available
ok    console   UTF-8 output
ready: run `emetgate lockdown` here
```

It exits 1 while anything would stop lockdown from working. `warn` lines do not block.

## 5. Start a locked session

```powershell
emetgate lockdown
```

What to expect:

- Claude Code opens as usual, but with **no built-in tools**: no Bash, no Edit, no Write. It can only use the `emetgate_*` tools.
- Reading and searching run without permission prompts. Writes ask for permission as usual.
- Each write is reparsed, checked against your rules, and run against your tests in a sandboxed copy. If anything fails, nothing touches your files and the model is told why.
- Passed and refused writes are marked in the transcript; `/golem off` hides the marks, `/rule` adds a rule without going through the model.
- Arguments after `lockdown` go to `claude` (e.g. `emetgate lockdown -p "fix the failing test"`). Flags that would lift the lock (`--tools`, `--mcp-config`, `--dangerously-skip-permissions`, ...) are refused.
- The lock is per launch: a plain `claude` in the same folder is not locked.

## When something goes wrong

Run `emetgate doctor` first; most startup errors print the fix on the same line, for example:

```
error: ClaudeNotFound: claude (Claude Code) is not on PATH; install it with: irm https://claude.ai/install.ps1 | iex  then open a new terminal
```

## Reporting a bug

Open an issue at <https://github.com/emetgate/emetgate/issues> with:

1. the output of `emetgate --version` and `emetgate doctor`,
2. the exact command you ran and the full error line,
3. what you expected instead.

If the bug lets a change through the gate, report it privately instead; see [SECURITY.md](../SECURITY.md).
