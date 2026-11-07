# Token benchmarks

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
