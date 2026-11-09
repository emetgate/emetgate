# Security policy

Emetgate's whole purpose is to be the thing that refuses. A flaw that lets a change reach the disk without passing the gate is the most serious kind of bug this project can have, and it is treated that way.

## Reporting a vulnerability

Report privately through GitHub's [private vulnerability reporting](https://github.com/emetgate/emetgate/security/advisories/new). Please do not open a public issue for something that lets code through the gate.

A useful report includes:

- **What the gate answered** (`committed`, `rejected`, or an error) and what the disk looked like afterwards.
- **A reproduction**: the repository shape, the symbol, the proposed body and the test command.
- **The commit** you tested, and whether you built from source or used a release.

You will get a first reply within a week. When a report is confirmed, the fix and the reproduction are published together, the way [issue-driven findings are already written up](https://emetgate.dev/blog). Credit is given unless you ask otherwise.

Past findings and their fixes are listed in the reference under [Security history](REFERENCE.md#security-history) and on [emetgate.dev/security](https://emetgate.dev/security).

## Supported versions

Emetgate is early. Only the latest commit on `main` is supported; there are no maintained release branches yet.

## In scope

Anything that breaks one of the guarantees the kernel claims:

- **Mediation**: a change reaching the disk without passing address, parse, guard, bound, test and commit.
- **Tamper-proofness**: a proposed body, a test command or repository configuration that escapes the sandbox or alters the kernel's own decision.
- **Confinement**: writes outside the shadow copy during the test phase.
- **Content addressing**: writing over a symbol whose hash no longer matches, or a hash collision that the gate accepts.
- **Atomicity**: a crash or a race that leaves a torn file, or a journal that replays into an unprovable state.
- **Jail**: reading or writing outside the served repository through any MCP tool.
- **Repository ledger trust**: a `cmd:` rule from a ledger tracked by git (`.emetgate/ledger.ndjson`, under any spelling) running without `--allow-repo-memory`, or the model supplying that opt-in through a tool call.

## Known limits, not vulnerabilities

These are documented in the README and are not treated as reports:

- **Reads and network from the test command.** The low-integrity token stops writing outside the shadow copy. It does not restrict reading or network access. Confining those requires an AppContainer, which is planned.
- **Semantic correctness.** Code that parses, stays in bounds and passes the tests can still do the wrong thing. The kernel raises the floor; it does not replace tests that encode intent.
- **Test-suite quality.** For unbounded changes the test gate is only as strong as the tests it runs.
- **Unmediated edits.** Changes made by other tools bypass the gate entirely; that is what `emetgate lockdown` exists for.
- **A trusted operator.** The person running Emetgate supplies the test command and the repository configuration and is trusted with them; the model is not.

## Updates

`emetgate doctor` and `emetgate lockdown` install a newer release by themselves at most once a day, and `emetgate update` does it on demand; [REFERENCE.md](REFERENCE.md#updating) has the steps. The trust model:

- **What is trusted.** The Ed25519 public key in `src/update/release_key.pub`, compiled into the binary. Its private half lives only in the `EMETGATE_SIGNING_KEY` secret of this repository, and the release workflow signs `emetgate.exe` with it after the tests pass. `zig build sign-tool` builds the signer; `emetgate-sign sign` refuses a secret whose public key is not the one in `release_key.pub`.
- **What is not trusted.** GitHub's API answer, the download, the network and any proxy on the way. A download replaces the installed exe only when its signature verifies against the built-in key, and when the downloaded exe itself reports `emetgate X.Y.Z` for the tag it came from. A tampered file, a file signed by another key, a missing or malformed signature, and an older signed binary served under a newer tag are all refused with a `warning:` line, and the installed exe stays.
- **No downgrade.** Only a plain `vX.Y.Z` tag strictly newer than the running version is taken; drafts, prereleases and tags with `-` or `+` are skipped.
- **Failure is safe.** No network, a timeout (2 seconds for the check) or a failed download prints nothing and changes nothing. A failed swap puts the old exe back; if even that fails, the warning names the rename that restores it.
- **Opt-out.** `EMETGATE_NO_UPDATE=1` or any `CI` value turns the daily check off; Debug builds never check. A build whose `release_key.pub` holds no key never downloads.
- **The installer.** `install.ps1` checks the SHA256 from `emetgate.exe.sha256`, which comes from the same release as the exe, so it catches a damaged download but not a release whose files were all replaced. PowerShell 5.1 cannot check Ed25519, so the signature is checked from the first update on, not at install. To check the install itself, compare the hash with the [build provenance attestation](https://github.com/emetgate/emetgate/attestations) of the release (`gh attestation verify emetgate.exe --repo emetgate/emetgate`).
- **In scope.** An update that installs a binary not signed by the release key, installs an older version, or leaves no working `emetgate.exe` behind is a vulnerability; report it as above.

## How the guarantees are held

Every guard is covered by tests that fail when the guard is removed, including red-team suites that attack the gate directly and fault injection for each step of building the sandbox token. If you find a guard whose removal breaks no test, that is worth reporting too.
