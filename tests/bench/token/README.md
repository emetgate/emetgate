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
