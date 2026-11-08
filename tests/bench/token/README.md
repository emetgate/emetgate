# Token bench

## Miner

`mine.py` reads local Claude Code transcripts (`~/.claude/projects/**/*.jsonl`, subagent files included) in one streaming pass and measures where billed tokens go. It never writes to the transcript folder.

What it measures:

- **Baseline** (`baseline.md`, `baseline.json`): per mode (`lockdown` = only emetgate tools, `mixed` = emetgate plus built-ins, `plain` = no emetgate, `none` = no tools), the session count and the median and p90 of turns, $ per session, $ per usage bucket, first-call context (system prompt plus tool definitions), and the tool-result share of written tokens. It checks the computed $ against `cost-state` records, reports the cost of one turn by context size, and the cache rebuilds that context growth does not explain.
- **Attribution and rent** (`attribution.md`, `attribution.json`): the cache write of call k+1 is split over the new content since call k. The assistant output takes its output tokens first, and the rest is split by char share across call k's tool results and other user content. Each result then gets a rent: `tokens x (2 + 0.1 x later calls in the same compaction segment)`, in input-price units. The reports list totals per tool and per argument kind, plus the 30 most expensive single results.
- **Follow-ups** (`next.md`, `next.json`): for each tool call, the next 1 to 3 tool calls the model made before the next user prompt, grouped into patterns such as same file re-read, read of the top search hit, retry after an error or rerun after a failing test. Each pattern comes with P(pattern | trigger) and the $ of the API call that issued the follow-up.

Prices live in one table at the top of `transcripts.py`. Rates are in input-price units: cache write 1h 2.0, 5m 1.25, cache read 0.1, input 1.0, output 5.0. The base $ per million input tokens depends on the model family.

Run it:

```
python tests/bench/token/mine.py --root ~/.claude/projects --out <dir outside the repo>
```

Privacy rule: outputs hold per-session detail, tool arguments and paths from other projects. They must stay outside the repo. `mine.py` refuses an `--out` inside the repo. Only the scripts are committed.

## Replay

`replay.py` estimates, with no model in the loop, how many model turns a new emetgate build would save on real recorded Claude Code sessions, and the net dollar effect.

```
python tests/bench/token/replay.py --emetgate <exe> --out <dir> [--root <transcripts dir>] [--scratch <dir>] [--limit N] [--baseline <previous result.json>] [--workers N]
```

`--root` defaults to `~/.claude/projects`. `--out` and `--scratch` must not be inside a git work tree; results and temporary worktrees go there, never into the repository.

What it does:

1. Loads every `*.jsonl` transcript under `--root`: API calls deduplicated by `message.id` with their final usage, the `tool_use` blocks and their `tool_result` text. The loader is `load_session` and is small on purpose, so it can be swapped for a shared one.
2. Keeps sessions that called a read-only `mcp__emetgate__` tool in a git repository that still exists. Sessions under `C:\Users\ugur\Desktop\APRYCO` are skipped. The commit is `git rev-list -1 --before=<first timestamp> HEAD`; when fewer than half the paths the session read are tracked there, the newest commit before the same timestamp on another local or remote branch is tried, and the session is skipped if none reaches half. The commit is checked out as a detached worktree under `--scratch` with repository hooks disabled.
3. Starts one `emetgate mcp` per session in its worktree, in parallel, and re-issues the recorded read-only calls in order: `skeleton`, `symbols`, `read_symbol`, `read_file`, `list`, `search`, `find`, `explore`, `evidence`, `git`. Writes and runs are skipped.
4. Coverage: a later lookup `j` is covered when at least 90 % of the non-trivial lines of its recorded result appear in the new replies of the calls before it (whitespace normalised, line-number and legend prefixes stripped, JSON headers expanded into their string values, footers and lines under 6 characters dropped, path-only lines dropped unless the result has nothing else), or when it repeats an earlier call with the same arguments and no write touched that file in between.
5. A turn is saved when every tool call of that API call is covered. Its value is `cache_read x 0.1 + cache_write x 2 + output x 5` input-token units, priced per million input tokens at opus 5, sonnet 3, haiku 1, fable 15. The added cost of a call is `(new reply tokens - recorded reply tokens) x (2 + 0.1 x remaining API calls)`. Tokens are estimated as chars / 3.2 for code-like text and chars / 3.8 for prose and JSON.
6. Writes `result.json` and `result.md` under `--out`: sessions, calls replayed, covered calls, saved turns, added tokens, net dollars per session, the ten calls that save the most turns, and with `--baseline` the delta against an earlier run.

`saved_turns_lookahead` counts the turns saved only by the new build's replies: the same rule run on the recorded replies is subtracted, so a build without lookahead shows about zero there while `saved_turns` still includes what the model already had and asked for again.

Every worktree is removed with `git worktree remove --force` at the end, also on error, after checking that its path is inside `--scratch`.

Limits: writes are not replayed, so calls after an edit see the files as they were at the commit; uncommitted work at session start is not reproduced; a covered call whose earlier reply ignored what the model asked for (for example a line range the tool did not honour) counts as saved although the model was not served; a saved turn's cache write is counted as saved although most of it would move to the next call; built-in `Read` and `Grep` calls are not considered.
