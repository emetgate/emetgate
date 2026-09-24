# Sandbox diagnosis: why real npm test suites break under emetgate's low-integrity gate

This is a diagnosis, not a fix. Each script here builds its own tiny git repo
under a scratch temp directory, then runs a candidate command both directly
(`common.run_outside_sandbox`) and through `emetgate try --test "<command>"`
(`common.run_inside_sandbox`, which spawns the command exactly the way
`src/platform/runner.zig`'s `runCommand` does, under the same restricted
low-integrity token and job object as `src/platform/sandbox.zig`). Nothing
in `src/` was changed except the CLI help text (see bottom).

Run any script directly, e.g. `python tests/bench/eval/repro/07_junction_traversal.py`.
`EMETGATE_BIN` can override the binary path; default is `zig-out/bin/emetgate.exe`.

## Repro table

| # | Command | Outside sandbox | Inside sandbox | Result |
|---|---|---|---|---|
| 01 | `node -e "process.exit(0)"` | exit 0 | exit 0, committed | passes |
| 02 | `node server.js` (opens an HTTP server on 127.0.0.1, closes it) | exit 0 | exit 0, committed | passes — a plain socket bind/listen/close is not the problem |
| 03 | `node probe.js` writing to `TEMP`, `TMP`, `LOCALAPPDATA`, `APPDATA`, `USERPROFILE`, `os.tmpdir()`, and the shadow cwd | all writes succeed | writes to `TEMP`/`TMP`/`LOCALAPPDATA`/`APPDATA`/`USERPROFILE`/`os.tmpdir()` fail with `EPERM`; write to the shadow cwd itself succeeds | expected and correct — `shadow.zig`'s `grantLowIntegrityWrite` only lowers the integrity label on the shadow directory itself, nothing else; this is the sandbox working as designed (F1 lesson: nothing outside the shadow should be writable) |
| 04 | `npm test` on a minimal `package.json` (`"test": "node test.js"`, no dependencies) | exit 0, 2.8 s | exit 0, 0.6 s, committed | passes — npm's own startup is not the problem |
| 05 | `mocha` + `supertest` (junctioned in from `eval/express-test/node_modules`), one test making a real HTTP round trip | exit 0 | exit 0, committed | passes — mocha, supertest and a real socket round trip through a *working* `node_modules` junction are all fine on their own |
| 06 | real express `lib/`, `test/`, `package.json` and `node_modules` junctioned into a fresh repo, running one real test file with `--require test/support/env` | exit 0 | `tests_failed`: `ERR_MODULE_NOT_FOUND: Cannot find package 'test'` | fails, but this repro also junctions `test/` and `lib/` itself (for convenience, not something `shadow.zig` does — it copies tracked files and only junctions `node_modules`), so it mixes two effects; kept for the trail but **07 isolates the real cause** |
| 07 | `node probe.js` doing `fs.existsSync`, `fs.readdirSync`, `fs.realpathSync` and `require.resolve` through a plain junction (`mklink /J`) to `eval/express-test/node_modules`, the same reparse-point mechanism `shadow.zig` uses for every "linked" directory | `existsSync` true, `readdir` 306 entries, `realpath` resolves, `require.resolve` finds `mocha/package.json` | `existsSync` **false**, `readdir` **ENOENT**, `realpath` **ENOENT**, `require.resolve` **MODULE_NOT_FOUND** — all against the exact same junction, same path | **root cause** |

## Root cause

`shadow.zig` links every "heavy" directory (`node_modules` by default, see
`runner.Options.linked`) into the shadow copy as an NTFS mount-point junction
(`FSCTL_SET_REPARSE_POINT`, tag `IO_REPARSE_TAG_MOUNT_POINT`), instead of
copying it, to avoid copying gigabytes of dependencies per attempt.
`sandbox.zig`'s `LowToken.create()` builds the test process's token with
`CreateRestrictedToken(..., DISABLE_MAX_PRIVILEGE, ...)` and a Low mandatory
integrity label.

Repro 07 shows that under that exact token, Node's `fs` calls cannot see the
junction at all — not `EPERM`/`EACCES` (a permission error a caller could
catch and explain), but `ENOENT`, indistinguishable from the directory never
having existed. `fs.existsSync` on the junction path itself returns `false`.
Every one of `readdirSync`, `realpathSync` and `require.resolve` through it
fails the same way. The exact same script, same path, same junction, run
outside the sandboxed token, works with no error.

This is consistent with Windows denying the low-integrity token the ability
to open/traverse a reparse point whose target lies on a normal
(medium-integrity, no explicit label) tree — `DISABLE_MAX_PRIVILEGE` strips
every privilege except `SeChangeNotifyPrivilege`, and reparse-point
processing on `CreateFile`/`FindFirstFile` for a low-IL caller appears to
fail closed rather than traverse through to a target it would then also need
read access to. This diagnosis did not go further into the exact NT API
rule (no `ProcMon`/ETW capture was taken in this environment); the important,
proven fact is *which* filesystem operation breaks and under *which* one
condition (the restricted token, nothing else), not the precise kernel-level
reason.

Because every real npm project's dependencies live in `node_modules`, and
`shadow.zig` always junctions it (never copies it), **any real test command
that needs `node_modules` — which is effectively all of them — cannot find
its own dependencies once run through the sandboxed test/typecheck runner.**
This matches the D1 finding exactly: `npm test` on `express` needs
`node_modules/mocha`, `node_modules/supertest`, etc.; when those become
invisible mid-run, `mocha`'s own module loader and its dependents fail in
whatever way they individually handle a missing package — some paths retry
or hang (the git-worktree run's `timed_out`), others hit an unhandled
rejection or an internal invariant that Node's crash reporter turns into a
hard process abort (the main-clone run's `test_crashed`, `0xC0000409`). Both
are different symptoms of the same missing-`node_modules` root cause, not
two separate bugs — this diagnosis found no evidence that the git-worktree
vs. main-clone distinction from the D1 report matters on its own; a worktree's
`.git` being a file rather than a directory did not reproduce as a separate
failure in any script here.

## Fix options (not applied — this is diagnosis only)

1. **Give the linked target directory a low-integrity label too**, the same
   way `grantLowIntegrityWrite` already does for the shadow directory, applied
   read-only (`SYSTEM_MANDATORY_LABEL_ACE` with just the no-write-up policy,
   not no-read-up) to the *real* `node_modules` the junction points at, before
   spawning the test command, and removed after. Security effect: this label
   would sit on the user's actual `node_modules` in their real repository
   (outside the shadow) for the duration of the run — a new place where the
   low-integrity boundary touches the real tree. Needs care that it is always
   removed (crash-safe) and that it does not admit writes, only traversal;
   otherwise it re-opens exactly the class of bug F1 fixed.
2. **Copy `node_modules` instead of junctioning it**, at least for the
   directories the test command will need, or lazily copy on first access.
   Security effect: neutral (matches how every other tracked file is already
   handled), but reintroduces the cost `shadow.zig`'s comment says junctioning
   was added to avoid; would need to be measured (this is exactly what
   `tests/bench/eval/scale.py`'s `shadow_copy_proxy_ms` already estimates:
   1.2–1.5 s for `eslint`'s `node_modules`-sized tree).
2b. **Copy-on-write / hardlink tree** (Windows hardlinks work within the same
   volume) as a middle ground: real files, no reparse point, no full copy.
   Same security profile as a copy; only worth it if plain copying turns out
   too slow on a very large `node_modules`.
3. **Do not run the restricted token at low integrity for the *directory
   traversal* step**, e.g. resolve and pre-open the directories the test
   needs at medium integrity before dropping to low, then hand the process
   already-open handles. More invasive change to `spawnRestricted`'s handle
   inheritance list; would need its own adversarial tests to make sure a
   test command cannot use a pre-opened handle to escape the shadow (F1
   again).

Whichever direction is chosen, the fix must keep the invariant this sandbox
exists for: nothing the test command does should be able to write outside
the shadow copy. Options 1 and 3 touch the boundary directly and need new
adversarial tests before landing; option 2/2b keeps the existing boundary
and only changes performance.

## CLI help text

`emetgate mutate`/`try --help` now documents (this was the only product file
touched, help text only): with `--hash <hex>` (replacing an existing
symbol), `--body`/`--body-file` must be just the replacement block
(`{ ... }`), not the full declaration — a full `function f() { ... }` there
is rejected as `MutationSyntaxInvalid`. This was the D1 trap: the CLI usage
line didn't say it, only `src/engine/cas.zig`'s own tests documented the
convention.
