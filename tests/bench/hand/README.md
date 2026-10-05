# Three questions asked by hand

On 5 October 2026 the same three questions were typed into four Claude Code sessions side by side, one per tool, on the NestJS repository at `35142c3`. This folder holds what each session did and answered.

![Totals and per-question numbers of the four tools](three-questions.png)

| | Key points | Tokens | API time | Cost |
|---|---:|---:|---:|---:|
| emetgate | 18/18 | 494k | 80.3 s | $0.473 |
| Claude Code's own tools | 18/18 | 691k | 78.3 s | $0.435 |
| Serena | 18/18 | 680k | 105.0 s | $0.467 |
| codebase-memory-mcp | 18/18 | 764k | 106.5 s | $0.691 |

emetgate used the fewest tokens on all three questions. Claude Code's own tools were the cheapest and fastest overall. On the second question emetgate cost more than Serena and Claude Code: the model called `emetgate_explore` three times and the later replies were 22 and 28 thousand characters of mostly new code, which is billed as tokens written to the cache.

## Setup

- Claude Code 2.1.289, `claude-sonnet-5-5`, interactive sessions, no extra prompt.
- Each session started in its own copy of the repository with `--setting-sources project,local --strict-mcp-config`.
- The three tool sessions added `--mcp-config .mcp.json --tools "" --allowedTools mcp__<server>` and `ENABLE_TOOL_SEARCH=false`, so Claude Code's own tools were off and one MCP server was loaded.
- emetgate was the build of `d9148f6`, the code released as v0.4.0. Serena 1.7.0, codebase-memory-mcp 0.9.0.
- A new window was opened for every question, so no session carried context from an earlier one.

## What is in each folder

`q1`, `q2` and `q3` each hold the question, a screenshot of the four panes taken when the answers finished, a `README.md` with the numbers and the answer key, and for every tool a readable record (`<tool>.md`: the tool calls in order, the token counts, the full answer) and the reduced session (`<tool>.session.jsonl`: every call's input and every reply's text).

Tokens, cost and call counts come from the session files. API time is the figure Claude Code showed in the status line, read from the screenshot.

## Limits

- One run per question and tool. The numbers move from run to run.
- The author of emetgate wrote the questions and the answer keys. The keys were written before any tool answered.
- NestJS is one of the repositories emetgate's send rule was fitted on. The three topics were not used in any earlier measurement.
- A key point counts when the answer names it. It does not judge the explanation.
- In the third question the codebase-memory-mcp session made one call to a browser tool that Claude Code adds on its own; the call failed and returned nothing. That tool was defined in all four sessions.
- The home directory and the user name are removed from the session files.
