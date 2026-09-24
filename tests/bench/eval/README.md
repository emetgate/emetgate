# Large public repo evaluation harness

Measures Emetgate's cost and correctness against real public TypeScript/JavaScript
repositories, outside the kernel's own test suite. Three stages, matching the
plan in `buyuk-proje-deneme-durumu.md` and `saglamlik-ve-devam-karari-deneyi.md`:

- **Stage A** (`scale.py`, built): tree size, parse cost, end-to-end `try` cost
  on a real repo.
- **Stage B** (`replay.py`, first version): replay real single-function-body
  commits through `emetgate try` and check the result against the real commit.
- **Stage C** (`tasks.json`, candidate list only, not run): 20 candidate tasks
  from closed issue/fix commit pairs, for a future normal-Claude-Code vs.
  lockdown comparison.

None of these scripts touch the Emetgate core; they only shell out to the
`emetgate` CLI (`zig-out/bin/emetgate.exe`, or `EMETGATE_BIN`) and to `git`.

## Setup

Clone target repos outside this repository, e.g. under `emetgate/eval/` next
to (not inside) the worktrees:

```
git clone https://github.com/expressjs/express.git eval/express-test
git clone https://github.com/eslint/eslint.git eval/eslint-test
cd eval/express-test && npm install
cd eval/eslint-test && npm install
```

Build the CLI first: `zig build` from the repo root.

## Stage A: scale.py

```
python tests/bench/eval/scale.py --repo ../eval/express-test --name express \
  --test "npm test" --out ../eval/express-test/scale-result.json
```

Measures, in order:

1. Tracked file count and byte size (`git ls-files`), split into all files and
   JS/TS files only.
2. `emetgate skeleton` and `emetgate symbols` wall time over a sample of up to
   `SKELETON_SAMPLE` (default 40) JS/TS files.
3. A shadow-copy proxy: the script copies every tracked file into a scratch
   directory itself and times it, since the CLI does not expose the shadow
   preparation stage's own timing. This is an external approximation of
   `Shadow.prepare`, not an instrumented measurement of it.
4. One real `emetgate try` edit (a top-level function body replaced with a
   trivial stub) run twice against the same starting commit: once with the
   repo's real test command, once with `cmd /c exit 0` (gate-only cost, no
   test suite). Each run restores the target file afterwards.

Limits: the edit always breaks the chosen function on purpose, so the
`real_test` trial is expected to end in `rejected`, not `committed` — this
stage measures cost, not whether a real edit would pass. The stage-timing
breakdown (shadow / typecheck / test / write) is external wall-clock
around each phase we can invoke separately; it is not read from the CLI,
which does not currently report per-phase timing in its JSON output.

## Stage B: replay.py

```
python tests/bench/eval/replay.py --repo ../eval/express-test --name express \
  --test "npm test" --max-commits 400 --max-candidates 10 \
  --out ../eval/express-test/replay-result.json
```

1. Scans the last `--max-commits` commits for ones with exactly one parent and
   exactly one changed `.js`/`.ts` file.
2. For each, runs `emetgate symbols --json` on the file before and after the
   commit. A candidate is kept only if the set of non-ambiguous symbol refs is
   unchanged and exactly one ref's content hash changed — i.e. a single
   function/method body edit, nothing added, removed or renamed.
3. Extracts the new body as the exact `{ ... }` block text after the commit,
   using a brace-depth scan that skips over strings, template literals and
   comments (not a full parser; can still misidentify a body boundary in
   unusual syntax, in which case the resulting hash will not match and the
   candidate is recorded as rejected/failed rather than silently wrong).
4. Re-reads the actual pre-commit content hash from a real `git worktree`
   checkout of the parent commit (not from the raw git blob), because this
   repository's `core.autocrlf` normalizes line endings on checkout and the
   git-blob hash and checked-out-file hash can differ.
5. Applies the real body through `emetgate try --hash <parent-hash>`, against
   a `git worktree` of the parent commit with `node_modules` junctioned in
   from the main clone (so the repo's own `npm test` can run without a second
   `npm install` per candidate).
6. Classifies the outcome:
   - **correct_accept**: committed, and the resulting file is byte-identical
     to the real commit's version of that file (checked against a second,
     independent worktree checkout of the commit, not the git blob).
   - **wrongful_reject**: rejected even though the body is the real, valid
     fix.
   - **leak_accept**: committed but the resulting file differs from the real
     commit (extraction produced something that a naive comparison would
     have been happy with, or the gate should not have accepted it).
7. For every candidate, also submits two deliberately faulty bodies against
   the same parent commit and hash: `off_by_one` (flips a comparison operator
   at its boundary, e.g. `<` to `<=`) and `broken_syntax` (removes the
   trailing closing brace). Each is expected to be rejected
   (`correct_reject`); a `committed` result on either is counted as
   `leak_accept`.

`--test` controls what both the real and the fault-injection trials use as
the test gate. `cmd /c exit 0` only measures the structural/syntax gate
(fast, always available); the repo's real test command additionally measures
whether a semantically wrong body is caught. Only `off_by_one` and
`broken_syntax` are implemented; the task file lists more fault classes
(stale hash, escaping the body, poisoned config) which are already covered by
the adversarial suites in `tests/redteam_*.zig` and are not duplicated here.

Only the `function`/method single-body-replace primitive is covered. Insert,
delete, rename, move and JSON edits are out of scope for this first version,
per the task; the script is structured so each new primitive gets its own
candidate-finding and apply function alongside `find_candidates`/`apply_case`
rather than being folded into them.

## Stage C: tasks.json

Twenty candidate tasks (ten `expressjs/express`, ten `eslint/eslint`), each a
real closed issue or bug-fix commit with its own parent commit and its own
fail-to-pass tests, picked from `git log --grep=^fix` for commits that touch
exactly one non-test source file plus its own test file(s). `task` describes
the observed bug from the commit message and diff, without naming the fix.
`windows_tests_pass` is `null` for every entry: this stage was not run, only
assembled, per the task. Confirming it requires checking out `parent_commit`
and running the repo's test command on Windows before the task set is used.

Not checked against SWE-PolyBench or Multi-SWE-bench for overlap (no network
access to those datasets from this environment); if either has a same-repo,
same-commit TypeScript/JavaScript task, prefer that entry's existing hidden
tests over ad hoc ones.

## Known limits

- Stage A's per-phase timing is wall-clock around externally-invoked stand-ins
  (a Python-side file copy for shadow prepare), not an internal trace from the
  CLI. See "Stage A" above.
- Stage B's body-boundary extraction is a bracket-depth scan, not a real
  parser; it is only trusted because the resulting hash and the byte-for-byte
  tree comparison catch a wrong extraction as a rejection or a `leak_accept`,
  never as a silent `correct_accept`.
- Stage B only replays true single-function-body commits; commits that also
  touch imports, add/remove symbols or touch more than one file are excluded
  by construction, matching the current `hash: <hex>` single-body-replace
  primitive.
- Stage C's task list is unverified: nobody has run these repos' test suites
  against `parent_commit` on Windows yet.
