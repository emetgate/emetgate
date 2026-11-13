# Scenario catalog suite

This folder turns the scenario catalog (read tools, write tools, environment) into
tests that run against a real `emetgate.exe` over stdio JSON-RPC. Each scenario
builds the repository it needs, starts `emetgate mcp` with the flags it needs,
makes the calls, and checks one or more invariants. It uses the Python standard
library only and runs under `python -I`.

CI runs it in the `catalog` job of `.github/workflows/ci.yml` on every pull
request, against a ReleaseSafe build.

## Running it

```
zig build -Doptimize=ReleaseSafe
python -I tests/catalog/run.py --emetgate zig-out/bin/emetgate.exe
```

| Option | Meaning |
|---|---|
| `--emetgate <exe>` | the server under test; default `zig-out/bin/emetgate.exe` |
| `--only C23,PY1` | run these ids only; `--only RF*` runs every id that starts with `RF` |
| `--fast` | leave out the scenarios marked slow (about a minute less) |
| `--json out.json` | write every result, with timings and the longest reply, to a file |
| `--work <dir>` | build fixtures and state there and keep them (default: a temp folder, removed at the end) |
| `--keep` | keep the temp work folder |
| `--list` | print the scenarios and exit |

The runner copies the exe into its work folder and runs the copy. An exe that sits
below a folder with a Low integrity label (a repository where `--open-run` ran)
inherits the label and runs at Low integrity, where every gated write fails.

Each server gets a clean environment: every `CLAUDE*`, `ANTHROPIC*` and
`EMETGATE*` variable is dropped, `EMETGATE_NO_UPDATE=1` is set, and
`LOCALAPPDATA` points into the work folder, so no state of the machine is read or
changed. The runner stops only the processes it started, by their handle.

It needs `git`, `node` (for `node --test`) and `python` on `PATH`.

## Results

| Status | Meaning | Expected |
|---|---|---|
| `pass` | every check held | yes |
| `fail` | a check did not hold; the note names the invariant and, when known, the branch meant to fix it | no |
| `error` | the scenario or the harness crashed | no |
| `xfail` | a scenario marked expected-fail failed | yes |
| `xpass` | a scenario marked expected-fail passed: remove its `xfail=` marker | no |
| `skip` | the machine cannot run it (for example `icacls` refused) | yes |

The exit code is 1 when any result is not expected.

A full run takes about 7 minutes on a developer machine; `--fast` leaves out the
seven slow scenarios (about 4 minutes of that). A server that exits during a call
has its stderr saved as `stderr-<id>-<pid>.txt` in the work folder.

### Expected-fail markers

A scenario is marked `xfail` only when its fix is outside the current work:

| Reason | Scenarios |
|---|---|
| long paths over 260 characters | RF31, EF4 |
| concurrency and cancellation | EL4, EL5, EC3 |
| the Low integrity label left by `--open-run` | EC5 |
| hooks that fail open | EK3 |
| explore on a minified file does not answer in 60 s | EX08 |
| no fix named yet | ER4, EM5, EM9 |

Every other scenario is expected to pass. A failing one names, in brackets, the
branch whose change it waits for.

## Invariants

| Id | Checked by | Holds when |
|---|---|---|
| R1 | `within_budget` | a reply is at most `REPLY_BUDGET` (65,536) characters, or the smaller budget the scenario names |
| R2 | `cut_named`, `bounded_and_named` | a cut reply says it was cut and names how to get the rest (`line_start`, `offset`, `cursor`, ...) |
| R3 | `refused_naming` | an unknown or inapplicable parameter is refused and the reply names it |
| R4 | the R4 scenarios | a read after a change on disk shows the new content |
| W1 | `refused_disk_identical` | a refused write leaves every file byte-identical |
| W2 | the W2 scenarios | a multi-part call is all or nothing, git state included |
| W5 | `never_verified_without_tests` | a reply never says verified unless at least one test ran |
| W6 | the W6 scenarios | CRLF, BOM and non-ASCII paths survive byte for byte |
| E1 | `Ctx.call` | every call answers within its timeout (90 s unless the scenario sets one), and errors carry a `fix` |
| CONF | the CONF scenarios | no reply holds content from outside the repository |

`Ctx.call` checks E1 on every call: a call that does not answer in time fails the
scenario, and the server is killed and replaced.

## Ids

Write and environment ids are the catalog's own (`C23`, `PY1`, `F02`, `I01`;
environment rows get an `E` prefix: `EF4` is row F4). Read ids are the tool's
prefix plus the row number of that tool's table in `catalog-read.md`:
`RF` read_file, `RS` read_symbol, `SK` skeleton, `SY` symbols, `LS` list,
`SE` search, `FI` find, `EX` explore, `XP` expand, `GI` git, `SC` scan.

## Fixtures

`fixtures.py` builds every repository from code, with no randomness and no
download. Shared fixtures are built once per run and must not be changed:

| Name | What it holds |
|---|---|
| `huge` | 5,000 tracked files in 500 folders |
| `mix` | CRLF, BOM, Turkish paths, a 20 MB log, 300 KB line, 1.8 MB JSON, 800-section Markdown, 4,500-line Python function, 2,500-file folder, ignored, untracked and modified files, a nested repository, a junction inside and a junction to a folder outside the repository |
| `minjs` | a 300 KB single-line minified file with 15,000 functions |
| `hist` | 30 commits, a 100,000-line unstaged rewrite, a Turkish file name |
| `longpath` | a tracked file whose path is over 260 characters |

Scenarios that write call `ctx.fresh(name)` for a private copy: `small`, `node`
(node --test, CRLF/BOM/Turkish files), `gate`, `notest`, `python` (unittest),
`inert` (tests that read README.md and LICENSE), `fuzzy`, `rules`, `nested`,
`merge`.

## Adding a scenario

1. Pick the module: `s_read.py`, `s_write.py` or `s_env.py`.
2. Write a function that takes `ctx` and decorate it:

```python
@scenario("C99", "W1", "what the scenario shows, in one line", fixed_by="fix/branch")
def c99(ctx):
    root = ctx.fresh("node")                      # or ctx.fixture("mix") to read only
    s = ctx.server(root, "--test", "node --test")  # flags as in .mcp.json
    before = snap(root)
    r = ctx.call(s, "emetgate_change", {"edits": [...]})
    refused_disk_identical(r, before, snap(root))
```

3. Check with the helpers in `harness.py` or with `check(cond, message)`. Start
   the message with the invariant id so a failure reads on its own.
4. Mark it `slow=True` when it takes more than about 20 seconds.
5. When the behaviour is wrong today and its fix is not being worked on, add
   `xfail="why"`. The suite stays green, and the run fails with `xpass` as soon
   as the fix lands, so the marker gets removed.
6. To add a fixture, write a `build_<name>(root)` in `fixtures.py` and add it to
   `BUILDERS`.

Run the new scenario alone with `--only C99`.
