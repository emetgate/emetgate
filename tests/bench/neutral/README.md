# Neutral runs: what a code question costs an agent

300 recorded Claude Code sessions, the questions and answer keys they were scored with, and one script that turns them into the numbers quoted in the release notes of v0.3.0.

```
python laws.py
```

It needs Python 3 and nothing else, and it makes no network call.

## What was run

- **Model:** `claude-sonnet-5-5`, through Claude Code 2.1.288 and 2.1.289 in print mode.
- **Questions:** 15 questions of the form "which code decides X, and what happens in case Y", in Turkish, on four TypeScript repositories. `questions.json` holds them with the commit of each repository.
- **Answer keys:** `keys/<repo>.json`, written from the code before any arm ran. An item counts as met when one of its `match` strings appears in the answer, ignoring case.
- **Runs:** three per question and arm. Every run started in a fresh copy of the repository with `--setting-sources project,local --strict-mcp-config` and no extra prompt. Tool arms added `--mcp-config .mcp.json --tools= --allowedTools mcp__<server>` and `ENABLE_TOOL_SEARCH=false`, so the model had the tools of that one server only.

| Arm | What the model had |
|---|---|
| `claude-code` | Claude Code's own tools |
| `serena` | Serena 1.7.0 |
| `codebase-memory-mcp` | codebase-memory-mcp 0.9.0 |
| `emetgate` | emetgate at `f9f26bf`, the build released as v0.3.0 |
| `emetgate-prototype-1`, `-2`, `-3` | three Python prototypes of the read tools, first set only |
| `emetgate-9236f27-instructed` | an earlier build whose server told the model to answer in ten lines, first set only; left out of every fit |

| Set | Repositories | Questions | Sessions |
|---|---|---|---|
| first | nest `35142c3`, typeorm `17e858d`, actual `954ad61` | 10 | 240 |
| OpenBot | CopilotKit/OpenBot `cb5dc32`, a repository created on 2026-08-17 | 5 | 60 |

## What a session record holds

One JSON object per line in `sessions/<repo>.jsonl.gz`: the arm, question and trial, the reported cost and API time, the four token counts, the final answer, and the events in order. A `model` event lists the tool calls of one model message with their inputs. A `result` event holds the text of one tool reply and its length in characters.

Removed from the raw transcripts: session, request and message identifiers, rate-limit events, the start-up event, and the home directory and user name in paths. 26 tool replies that listed other projects indexed on the machine are replaced by a note; their length is kept.

## Limits

- One model, 15 questions, four repositories. The fits are correlations.
- A score counts names in the answer. It does not judge the explanation.
- "In the context" means a key item's name appeared in a tool reply.
- The author of emetgate wrote the questions and the keys, and the send rule of the `emetgate` arm was fitted on the first set. The OpenBot set was not used to fit anything.
- The first set's rival sessions were recorded on 2 and 3 October 2026, the `emetgate` and OpenBot sessions on 4 October.

## Code quoted in the sessions

The tool replies quote source code from nest, typeorm, actual and OpenBot. All four are MIT licensed; the code belongs to their authors.
