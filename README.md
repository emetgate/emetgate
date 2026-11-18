<p align="center">
  <img src="assets/readme/hero-once-en.svg" alt="emetgate: say it once" width="100%">
</p>

<p align="center"><a href="docs/QUICKSTART.md"><b>Quickstart</b></a> · <a href="REFERENCE.md"><b>Reference</b></a> · <a href="VERIFICATION.md"><b>Verification</b></a> · <a href="examples/discount"><b>A real session</b></a></p>

<p align="center"><sub><b>English</b> · <a href="translations/README.tr.md">Türkçe</a> · <a href="translations/README.ko.md">한국어</a> · <a href="translations/README.zh-CN.md">简体中文</a> · <a href="translations/README.es.md">Español</a></sub></p>

> [!NOTE]
> Windows only, for now. Built for Claude Code; works on TypeScript, JavaScript, Python, C# and Zig projects.

You tell your agent "no comments". It listens for a while. Then the session gets long, the context is compacted, a new session starts the next day, and the same comment comes back. You put it in CLAUDE.md; it stays a request there too.

In emetgate a rule does not live in the conversation. It lives in a separate rule book and is applied to every write the agent makes. If the agent breaks a rule, the write never reaches the disk; the agent sees why and fixes it in the same turn.

This is not a feeling. Claude Code's own documentation says the same:

> *"CLAUDE.md instructions shape Claude's behavior but are not a hard enforcement layer."* ([code.claude.com/docs/en/memory](https://code.claude.com/docs/en/memory))

<p align="center">
  <a href="assets/video/emetgate-ad-en.mp4"><img src="assets/readme/emetgate-ad-en-cover.png" alt="Video: a rule in a Markdown file is a request, in emetgate it is a gate" width="100%"></a>
  <br><sub>Watch the video: we ask the agent to break the rule on purpose, and the gate still doesn't write it.</sub>
</p>

## How it works

<p align="center">
  <img src="assets/readme/pillars-once-en.svg" alt="Say it once; the rule stays; fixed before you see it" width="100%">
</p>

### Say it once

When you give a lasting instruction in chat ("from now on", "never"), emetgate asks the agent to offer the `/rule` line that turns it into a rule. You confirm it, and it becomes a rule. You can also write your own rule in one line:

```
emetgate rule add "no lint suppression" --check forbid_regex:eslint-disable --enforce
```

Or pick from the ready catalog, where the common ones live: no `console.log`, no new comments, no `Co-authored-by`:

<img src="assets/readme/term-rules-en.svg" alt="emetgate rule pick and emetgate rule add in a terminal" width="100%">

### The session ends, the rule stays

The rule lives in a ledger under `.emetgate/`. However long the session runs, after compaction, in tomorrow's new session, the same rule applies to every write.

A rule you want in every project goes in your global ledger: add `--global` to `emetgate rule add` or `emetgate rule pick`. It lives in `%LOCALAPPDATA%\emetgate\rules`, outside every repository, and applies together with each repository's own rules; a repository cannot change or remove it.

Under `emetgate lockdown`, Claude Code's own edit and write tools are off; the agent changes files through emetgate's tools, and every change passes the same rules. The agent has no tool to add, change or remove a rule; a command that tries to is asked about first.

Adding a rule to an old repository breaks nothing: only new violations are refused.

### Fixed before you see it

A refusal goes back to the agent with its line and column; the agent fixes it in the same turn. You see the result that follows the rule.

```
rejected: rule mf97c482341f15e82 (forbid:console.log) at src\pricing.js:3:3: console.log
rejected: rule me2014a06b646515d (added:no_comment) at src\pricing.js:2:3: // clamp the percent
```

## Why a hook or ESLint is not enough

You can build part of this yourself with Claude Code hooks and ESLint. The difference:

- **The gate is the same for every write tool.** Lockdown turns off Claude Code's own edit tools; edits, renames, moves and deletes pass the same rules. If the agent changes a file with a shell command, it is recorded, frozen paths are put back, and a change that did not pass the gate cannot be committed through emetgate.
- **The agent can switch ESLint off.** An `eslint-disable` line and `.eslintrc` live in files the agent can edit. emetgate's rules live in a ledger the agent has no tool to change; adding `eslint-disable` can itself hit a rule.
- **The change is checked as a whole.** A change that touches several files is checked together on a copy of the repository; if it passes all of it is written, if not none of it is.
- **From chat to rule.** A lasting instruction you give is offered as a rule; you do not write a script per rule.

## Also

**Search says what it read.** When the agent says "I found every use", the answer shows how many files it scanned and whether it read them all. If the numbers do not add up, no result is shown.

<img src="assets/readme/term-search-en.svg" alt="emetgate search output with file counts" width="100%">

**Commits carry a record.** Every commit made through the gate carries, in `refs/notes/emetgate`, which files were written and which checks ran. It is a record, not a signature: it shows later how something was written.

<img src="assets/readme/term-verify-en.svg" alt="emetgate verify output" width="100%">

Check a commit with the test command you trust; the command a receipt records is never rerun, so without `--test` the commit stays `unverified`:

```
emetgate verify HEAD --test "npm test"
```

**See what a session cost.** `emetgate report` sums up the latest session in the project that called emetgate's tools: duration, model turns, input, output and cache tokens, an estimated cost in USD, tool calls by name, and what the gate did (writes applied and rejected, rule violations, test runs, receipts, commits). `--session <id>` picks one session, `--all` lists every session in a table, `--json` prints the same numbers as JSON. Tokens come from Claude Code's own transcript (`projects/` under `CLAUDE_CONFIG_DIR`, or `~/.claude`); the cost uses built-in list prices per model, so it is an estimate, not your bill.

**Watch what the agent touches.** Under `emetgate lockdown`, emetgate calls show in the transcript the way Claude Code's own tools do, also when calls fold together: `Read(file)` with the lines it read, `Search("…")` with the first hits, `Update(file)` with the changed lines and their context, `Write(file)`, `Bash(command)` with its output. Next to a read or an edit, a thin strip shows which parts of the file the agent has seen so far, and an edit to a part it never read is marked `edited without reading`. While a read runs, a strip scans the file; when the turn ends, one line sums up the turn and lists every file it touched with how much of each was read. It only draws: the model gets the same replies. A secret file (`.env`, keys, credentials) shows its name, never its content. `emetgate lockdown --no-marks` turns it off.

## Databases

The agent can read your project's database without seeing what you keep private. Set it up once in a terminal:

```
emetgate db add main data/app.db
emetgate db hide main users.password_hash
emetgate db mask main users.email --mode email
emetgate db block main api_keys
emetgate db protect main
```

The agent reads with `emetgate_db`: it lists tables, describes them, samples rows and runs one `SELECT` per call, as JSON, CSV or Markdown, with caps on rows, cell size, reply size and time. The file is opened read-only and every statement passes SQLite's authorizer before it runs. A hidden column reads as NULL wherever it appears (`SELECT *`, a view, a subquery, a `WHERE`); a blocked table is refused even through a view; a masked column comes back masked under any alias, and a query that puts it inside an expression is refused. The rules follow the column a value comes from, not the name it is given.

**MongoDB** works the same way. `db add` logs in once to check the URI, then seals it, password included, with Windows DPAPI:

```
emetgate db add shop "mongodb://app:secret@db.local:27017/shop?authSource=admin&tls=true"
emetgate db hide shop users.ssn
emetgate db mask shop users.email --mode email
emetgate db block shop audit_log
```

Collections play the part of tables and a rule names a top-level field. Instead of SQL the agent sends one JSON command: `find` (filter, projection, sort, limit, skip), `aggregate` (pipeline), `distinct` or `countDocuments`. emetgate parses every command and walks it before anything is sent. It refuses a hidden or masked field named anywhere (a filter, a sort, `$expr`, a dotted path, `$getField`), whole-document references like `$$ROOT`, server-side JavaScript, `$out` and `$merge`, and joins (`$lookup`, `$unionWith`, `$graphLookup`) into a collection that has rules. The pipeline that runs removes hidden fields first and last, and the reply drops them and masks masked ones by name once more. A view is checked like the pipeline it stands for.

**Writing needs you.** The agent only reads. To let it change data, type `/db write` as a prompt: the hook answers it and the model never sees it. Only during the turn of your next prompt may `emetgate_db_write` run `INSERT`, `UPDATE`, `DELETE` or DDL (on MongoDB: `insertOne`, `insertMany`, `updateOne`, `updateMany`, `deleteOne`, `deleteMany`, `drop`), each statement logged with its row count. Dropping a table, emptying one or changing every row is still refused unless you typed `/db write --destructive`; `/db read` ends write mode at once.

**PostgreSQL** works the same way. Add it by URL. The password is sealed with DPAPI under `%LOCALAPPDATA%\emetgate\db\credentials`, never written to the repository; leave it out of the URL and set `PGPASSWORD` for the `db add` command instead:

```
emetgate db add prod "postgres://reader@db.example.com:5432/shop?sslmode=verify-full"
emetgate db hide prod users.password_hash
emetgate db mask prod users.email --mode email
emetgate doctor
```

emetgate speaks the PostgreSQL protocol itself: SCRAM-SHA-256 login, TLS checked against the Windows root store or `sslrootcert` with `sslmode=verify-full`. Every read runs in a `READ ONLY` transaction with a statement timeout and is rolled back. Before a query runs, emetgate asks the server for its plan (`EXPLAIN (VERBOSE)`) and checks every table the plan touches, through views and subqueries, and every column and function it uses. A hidden or masked column may only be selected directly, and then comes back NULL or masked; anywhere else (`WHERE`, `ORDER BY`, `GROUP BY`, a function, `row_to_json(t)`, a whole row `t`, `UNION`, a scalar subquery) the query is refused. System catalogs such as `pg_stats`, `COPY`, and every function off a built-in list (`pg_read_file`, `lo_get`, `dblink`, `query_to_xml`, `set_config`, functions defined in the database) are refused too. Connect with a role that has only `SELECT`: `emetgate doctor` warns when the role is a superuser or can write.

## Start in 2 minutes

In PowerShell, then open a new terminal:

```
irm https://github.com/emetgate/emetgate/releases/latest/download/install.ps1 | iex
```

In your project folder:

```
emetgate doctor
emetgate rule pick 1 19 26
emetgate lockdown
```

`emetgate doctor` is a one-screen install check, one `ok`, `warn` or `FAIL` line each with its fix: which emetgate PATH runs and any shadowed copies, whether a newer release is out, claude and the config folder it reads (`CLAUDE_CONFIG_DIR` or `~/.claude`), where emetgate is registered as an MCP server, other running emetgate processes, the data folder's size, and whether this folder is a git repository. `--json` prints the same as JSON.

`emetgate lockdown` starts Claude Code with only emetgate's tools. Run it inside your project folder (a git repo), not from your home folder or a drive root. Step by step: [docs/QUICKSTART.md](docs/QUICKSTART.md).

## Uninstall

```
emetgate uninstall
emetgate uninstall --yes
```

The first command removes nothing: it lists the program folder (`%LOCALAPPDATA%\Programs\emetgate`), its entry in your user PATH and the data folder (`%LOCALAPPDATA%\emetgate`, caches that can reach a few GB) with its size. `--yes` removes them; add `--keep-cache` to keep the data folder. The program folder goes a few seconds after the command exits, since a running emetgate.exe cannot delete itself. If other emetgate processes are running, it lists their PIDs and removes nothing until you close them. The `.emetgate` folder and `.mcp.json` entry in each project stay; delete them by hand.

### Disk use

emetgate keeps per-project caches (search index, facts, the copy the tests run on) under `%LOCALAPPDATA%\emetgate`. The server removes caches unused for 30 days once a day. To see and trim them yourself:

```
emetgate cache size                  # total, per folder and per project (--json for scripts)
emetgate cache prune --dry-run       # what would go, nothing deleted
emetgate cache prune                 # remove caches unused for 14 days (--older-than <days>)
emetgate cache prune --all           # remove every cache no running emetgate is using
```

A cache that a running emetgate holds a lease on is never removed. The shared `cache` and `run-tmp` folders (package caches and TEMP of sandboxed commands) are cleared only by `--all`, and only while no other emetgate process runs.

## Limits

- Windows only, for now.
- Databases: SQLite, PostgreSQL and MongoDB; MySQL comes later. Keep a SQLite database with hidden or masked columns outside the repository and run `emetgate db protect`, so no file tool or command reads the file itself. On PostgreSQL a query the plan check cannot trace is refused rather than run, so some valid queries over tables with hidden or masked columns are refused (a view, a `UNION` or a scalar subquery that returns such a column). Implicit casts and the type functions that extensions define run without the check; a least-privilege role is the backstop. A MongoDB server must ask for a password, or any program on the machine can read it directly; emetgate logs in with SCRAM only, does not resolve `mongodb+srv://` (list the hosts instead) and cannot connect to a server that asks for a TLS client certificate.
- Rules apply to changes made through emetgate's write tools. A command the agent runs does not pass the gate: the files it changes are reported and frozen paths are put back, but the other rules do not apply to commands. A command that deletes files in the repository without recursion is refused under lockdown; the agent deletes them with `emetgate_delete`, which passes the gate. `git rm` through `emetgate_git_write` is refused the same way, even with `force:true`; `git rm --cached`, which leaves the file on disk, still runs.
- The rule ledger is a file under `.emetgate/`. The agent has no tool to write it, but an edit made by a command is not caught by the hook that watches rule commands.
- Outside lockdown, in a session opened with the agent's own tools, there is no gate. In other agents that speak MCP, the gate works as long as the agent uses emetgate's tools.
- Every write takes about 0.2–0.4 s at the gate. We do not promise fewer tokens.
- Receipts are not signed: they catch a receipt edited out of step with its commit, not a rewritten history.
- The destructive-command check looks at words; it is not a sandbox.

## Under the hood

<details>
<summary>The gate: reparse, rules, typecheck and tests on a copy, then one write</summary>

A change names a symbol and the hash of the code it was based on. emetgate puts the new body in place, reparses the file, runs the rules, then runs the typecheck and the tests on a copy of the repository inside a low-integrity sandbox. If every step passes it is written; if one fails, nothing is written. The write goes through a journal; if it is cut off, `emetgate recover` repairs it.

</details>

<details>
<summary>Rules: syntax-tree queries, patterns, commands, frozen paths, commit messages</summary>

Rule checks are syntax-tree queries (`no_comment`, `require_comment`, `max_function_lines`, `forbid_import`), step-limited regex in the changed span (`forbid_regex`, `no_todo`), commands, frozen paths and commit-message checks (`message:conventional`, no Co-authored-by). The ledger `ledger.ndjson` is append-only; the model reads it and has no tool to write it. Lockdown's chat hook handles a `/rule` line before it reaches the model and offers to turn a lasting instruction into a rule.

</details>

<details>
<summary>Search and verification: the techniques</summary>

Search uses a suffix-array index and trigram lists; it shows whether an answer is complete or partial with an RFC 9162 Merkle root over the SHA-256 of every file read, and is compared line for line with ripgrep. Commit records are in-toto statements, and `emetgate verify --branch main..HEAD --test "<cmd>"` checks a whole range; a commit without a receipt counts as `partial`. Details: [REFERENCE.md](REFERENCE.md), [VERIFICATION.md](VERIFICATION.md).

</details>

## Where the name comes from

In the Prague legend, the golem comes to life by the word **אמת** (*emet*, "truth") on its forehead; erase the first letter and it becomes **מת** (*met*, "dead"), and it stops. In emetgate, a change that breaks a rule is not written.

MIT. See [LICENSE](LICENSE).
