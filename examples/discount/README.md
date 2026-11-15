# Example: the discount session

A small JavaScript shop (`project/`, 12 tests run by `node --test`, no npm
dependencies) goes through one session with emetgate. The model's tool calls are
scripted; every reply is real emetgate output.

| Step | Call | What emetgate did |
|---|---|---|
| 1 | `emetgate_search` for `applyDiscount` | a complete answer, with the Merkle root over every file it read |
| 2 | change `applyDiscount(price, percent)` to take a rate, leave `checkout.js` alone | refused (`tests_failed`), disk untouched |
| 3 | the same change, plus a test edited to expect the broken value | refused by the rule `tests are frozen` on `test/` |
| 4 | change `pricing.js` and `checkout.js` together (`15 / 100`) | written, all 12 tests pass |
| 5 | `emetgate_change` with `commit` | one commit, its receipt attached as a git note |

Then `emetgate verify` and the independent Python checker check that commit.

| File | What it holds |
|---|---|
| `SESSION.md` | the readable transcript and the footnotes: each claim with its evidence |
| `session.json` | every call, its full reply, and the output of every command run after it |
| `session.bundle` | the example repository, with the receipt note (`refs/notes/emetgate`) |
| `project/` | the shop as it was before the session |
| `replay.py` | the script that recorded all of the above |

The only change made to the recorded output is that the temporary folder the replay
ran in is written as `<work>`.

## Verify the bundle yourself

You need `git`, `node`, Python 3 and an `emetgate.exe`. Run this from any empty
folder outside the emetgate repository; `<emetgate repo>` is your checkout of it.

```
git clone "<emetgate repo>/examples/discount/session.bundle" discount-shop
cd discount-shop
git fetch "<emetgate repo>/examples/discount/session.bundle" refs/notes/emetgate:refs/notes/emetgate
git notes --ref=emetgate show HEAD
emetgate verify HEAD --test "node --test"
python "<emetgate repo>/tools/verify_py/emetgate_verify.py" HEAD --repo .
```

A plain clone does not bring notes, so the `git fetch` line is needed: without it
`emetgate verify` reports both files `unverified` ("no receipt covers this change")
and exits 53. With it, `emetgate verify` prints
`verified` for `src/pricing.js`, `src/checkout.js` and the one receipt, and exits 0;
it reruns `node --test` in its sandbox on the committed tree, because the receipt
names that exact command. The Python checker prints `consistent` and exits 55: it
recomputes every digest but runs no tests, so it never says `verified`.

## Record it again

```
zig build -Doptimize=ReleaseSafe
python examples/discount/replay.py --emetgate zig-out/bin/emetgate.exe
```

`replay.py` copies the exe and the project into a new folder under the system temp
folder, so neither runs below the repository (a folder with a Low integrity label
makes every gated write fail). Unset `TMP` and `TEMP` if they point inside the
repository. It writes `SESSION.md`, `session.json` and `session.bundle` here, and stops
with the reply it got when a step does not behave as described above. Options:
`--out <dir>` writes elsewhere, `--work <dir>` uses that folder, `--keep` keeps the
temporary one.

What a rerun changes: `emetgate rule add` stamps the rule with the time, so the rule
id, the rules commit, the session commit and the note change on every run, and the
receipt holds the test run's duration and a batch id, so its id changes too. The
commit dates are fixed by the replay. The Merkle root, the failing tests with their
expected and actual values, the refusal reasons, the test counts and both verdicts
stay the same.

Not in this example: what emetgate's lockdown adds (asking the user before a force
push or before an `emetgate rule add` the model types). Those need `emetgate lockdown`
and a Claude Code session.
