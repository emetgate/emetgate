# The discount session

Recorded by `replay.py` with `emetgate 0.10.4`, the server started as `emetgate mcp --test "node --test" --search-internals`. The tool calls are scripted; every reply below is emetgate's own output. The only change made to it is that the temporary folder the replay ran in is written as `<work>`. `session.json` holds each call and its full reply. `--search-internals` only lets step 1b ask for the certificate; the search reply the model reads is the text of step 1a.

## Setup

The project in `project/` is committed as a baseline (`0f6f238f06201fb9d95b180438763e3cdb3f2d90`), then one rule is added on the command line and committed (`f65b21cdba8d7f3b9f1e7d346f1493052f8a89c6`):

```
$ emetgate rule add "tests are frozen" --check frozen --in test/ --enforce
m646f290bae923802
```

## 1a. Find every use of applyDiscount (the reply the model reads)

Call `emetgate_search`:

```json
{
  "pattern": "applyDiscount"
}
```

Reply (accepted; files changed on disk: none; HEAD unchanged):

```
src/pricing.js
1*:function applyDiscount(price, percent) {
13:module.exports = { applyDiscount, roundCents, formatPrice };
src/checkout.js
1:const { applyDiscount, roundCents } = require('./pricing.js');
4:return applyDiscount(price, 15);
✓
```

## 1b. The same search with its certificate

Call `emetgate_search`:

```json
{
  "pattern": "applyDiscount",
  "certificate": true
}
```

Reply (accepted; files changed on disk: none; HEAD unchanged):

```
{
  "answer": "✓ 4 matches in 6 files @a4eb; excluded 1 internal",
  "status": "complete",
  "groups": [
    {
      "file": "src/pricing.js",
      "symbol": "applyDiscount",
      "hash": "acd77a6733724507d944db9754634365",
      "hits": [
        {
          "line": 1,
          "kind": "code",
          "role": "definition",
          "text": "function applyDiscount(price, percent) {"
        }
      ]
    },
    {
      "file": "src/checkout.js",
      "hits": [
        {
          "line": 1,
          "kind": "code",
          "role": "reference",
          "text": "const { applyDiscount, roundCents } = require('./pricing.js');"
        }
      ]
    },
    {
      "file": "src/checkout.js",
      "symbol": "memberPrice",
      "hash": "0c78bad83565705c4c4d14a3a3a1e73b",
      "hits": [
        {
          "line": 4,
          "kind": "code",
          "role": "reference",
          "text": "return applyDiscount(price, 15);"
        }
      ]
    },
    {
      "file": "src/pricing.js",
      "hits": [
        {
          "line": 13,
          "kind": "code",
          "role": "reference",
          "text": "module.exports = { applyDiscount, roundCents, formatPrice };"
        }
      ]
    }
  ],
  "truncated": false,
  "total": 4,
  "sees": "writes closed or flushed before this search",
  "certificate": {
    "answer": "complete",
    "snapshot": {
      "barrier": 2,
      "root": "a4eb1d5b5145585c23c9101ea97e1e3fc22e56f817eaa8e2199f9f69787e7a5a",
      "digest": "sha256",
      "tree": "rfc9162"
    },
    "scope": {
      "basis": "tracked",
      "prefix": "",
      "listed": 7,
      "excluded": {
        "binary": 0,
        "internal": 1,
        "too_large": 0
      },
      "excluded_paths": [
        {
          "path": ".emetgate/ledger.ndjson",
          "rule": "internal"
        }
      ],
      "evaluated": 6,
      "in_scope": 6
    },
    "semantics": {
      "text": {
        "pattern": "applyDiscount",
        "mode": "literal",
        "case": "sensitive",
        "kinds": [
          "code",
          "comment",
          "string"
        ],
        "filtered": 0
      }
    },
    "budgets": [
      {
        "limit": "file_bytes",
        "max": 1073741824,
        "used": 700
      },
      {
        "limit": "matches",
        "max": 200,
        "used": 4
      }
    ],
    "missing": []
  }
}
emetgate ✓ search · session 0 edits
```

## 2. Change applyDiscount to take a rate, without touching checkout.js

Call `emetgate_change`:

```json
{
  "edits": [
    {
      "file": "src/pricing.js",
      "old_string": "function applyDiscount(price, percent) {\n  return price * (1 - percent / 100);\n}",
      "new_string": "function applyDiscount(price, rate) {\n  return price * (1 - rate);\n}"
    }
  ]
}
```

Reply (refused; files changed on disk: none; HEAD unchanged):

```
{
  "edits": {
    "retry": "521149db",
    "status": "rejected",
    "reason": "tests_failed",
    "test_cmd": "node --test",
    "outcome": "exited",
    "tests": "ℹ tests 12 | ℹ pass 7 | ℹ fail 5",
    "diagnostics": [],
    "failures": "15% discount on 100 gives 85\ntest at test\\checkout.test.js:5:1\n  AssertionError [ERR_ASSERTION]: Expected values to be strictly equal:\n\n  -1400 !== 85\n\n      at TestContext.<anonymous> (test\\checkout.test.js:5:51)\n    generatedMessage: true,\n    code: 'ERR_ASSERTION',\n    actual: -1400,\n    expected: 85,\n    operator: 'strictEqual',\n    diff: 'simple'\n  }\n\n15% discount on 200 gives 170\ntest at test\\checkout.test.js:6:1\n  AssertionError [ERR_ASSERTION]: Expected values to be strictly equal:\n\n  -2800 !== 170\n\n      at TestContext.<anonymous> (test\\checkout.test.js:6:52)\n    generatedMessage: true,\n    code: 'ERR_ASSERTION',\n    actual: -2800,\n    expected: 170,\n    operator: 'strictEqual',\n    diff: 'simple'\n  }\n\ndiscount on 0 is 0\ntest at test\\checkout.test.js:7:1\n  AssertionError [ERR_ASSERTION]: Expected values to be strictly equal:\n  + actual - expected\n\n  + -0\n  - 0\n\n      at TestContext.<anonymous> (test\\checkout.test.js:7:41)\n    generatedMessage: true,\n    code: 'ERR_ASSERTION',\n    actual: -0,\n    expected: 0,\n    operator: 'strictEqual',\n    diff: 'simple'\n  }\n\ncart total discounts every item\ntest at test\\checkout.test.js:9:1\n  AssertionError [ERR_ASSERTION]: Expected values to be strictly equal:\n\n  -3080 !== 187\n\n      at TestContext.<anonymous> (test\\checkout.test.js:9:54)\n    generatedMessage: true,\n    code: 'ERR_ASSERTION',\n    actual: -3080,\n    expected: 187,\n    operator: 'strictEqual',\n    diff: 'simple'\n  }\n\ncart total rounds to cents\ntest at test\\checkout.test.js:10:1\n  AssertionError [ERR_ASSERTION]: Expected values to be strictly equal:\n\n  -419.58 !== 25.47\n\n      at TestContext.<anonymous> (test\\checkout.test.js:10:49)\n    generatedMessage: true,\n    code: 'ERR_ASSERTION',\n    actual: -419.58,\n    expected: 25.47,\n    operator: 'strictEqual',\n    diff: 'simple'\n  }",
    "fix": "the edit makes the tests named in failures fail; nothing was written; change the edit so they pass and send it again",
    "shadow": {
      "root": "<work>\\localappdata\\emetgate\\shadow",
      "linked_files": 0,
      "copied_files": 0,
      "skipped_links": 0
    },
    "gate_tree": {
      "kind": "kept",
      "private_copies": 0
    }
  },
  "status": "stopped",
  "stopped_at": "edits"
}
emetgate ✗ rejected · tests_failed · gate full · disk untouched · session 0 edits
```

The `failures` field of that reply, with its `\n` escapes printed as line breaks:

```
15% discount on 100 gives 85
test at test\checkout.test.js:5:1
  AssertionError [ERR_ASSERTION]: Expected values to be strictly equal:

  -1400 !== 85

      at TestContext.<anonymous> (test\checkout.test.js:5:51)
    generatedMessage: true,
    code: 'ERR_ASSERTION',
    actual: -1400,
    expected: 85,
    operator: 'strictEqual',
    diff: 'simple'
  }

15% discount on 200 gives 170
test at test\checkout.test.js:6:1
  AssertionError [ERR_ASSERTION]: Expected values to be strictly equal:

  -2800 !== 170

      at TestContext.<anonymous> (test\checkout.test.js:6:52)
    generatedMessage: true,
    code: 'ERR_ASSERTION',
    actual: -2800,
    expected: 170,
    operator: 'strictEqual',
    diff: 'simple'
  }

discount on 0 is 0
test at test\checkout.test.js:7:1
  AssertionError [ERR_ASSERTION]: Expected values to be strictly equal:
  + actual - expected

  + -0
  - 0

      at TestContext.<anonymous> (test\checkout.test.js:7:41)
    generatedMessage: true,
    code: 'ERR_ASSERTION',
    actual: -0,
    expected: 0,
    operator: 'strictEqual',
    diff: 'simple'
  }

cart total discounts every item
test at test\checkout.test.js:9:1
  AssertionError [ERR_ASSERTION]: Expected values to be strictly equal:

  -3080 !== 187

      at TestContext.<anonymous> (test\checkout.test.js:9:54)
    generatedMessage: true,
    code: 'ERR_ASSERTION',
    actual: -3080,
    expected: 187,
    operator: 'strictEqual',
    diff: 'simple'
  }

cart total rounds to cents
test at test\checkout.test.js:10:1
  AssertionError [ERR_ASSERTION]: Expected values to be strictly equal:

  -419.58 !== 25.47

      at TestContext.<anonymous> (test\checkout.test.js:10:49)
    generatedMessage: true,
    code: 'ERR_ASSERTION',
    actual: -419.58,
    expected: 25.47,
    operator: 'strictEqual',
    diff: 'simple'
  }
```

## 3. Make the failing test expect the broken value

Call `emetgate_change`:

```json
{
  "edits": [
    {
      "file": "src/pricing.js",
      "old_string": "function applyDiscount(price, percent) {\n  return price * (1 - percent / 100);\n}",
      "new_string": "function applyDiscount(price, rate) {\n  return price * (1 - rate);\n}"
    },
    {
      "file": "test/checkout.test.js",
      "old_string": "test('15% discount on 100 gives 85', () => assert.strictEqual(memberPrice(100), 85));",
      "new_string": "test('15% discount on 100 gives 85', () => assert.strictEqual(memberPrice(100), -1400));"
    }
  ]
}
```

Reply (refused; files changed on disk: none; HEAD unchanged):

```
{
  "edits": {
    "retry": "5aea9d4d",
    "status": "rejected",
    "reason": "rule_violation",
    "violations": [
      {
        "rule": "m646f290bae923802",
        "rule_text": "tests are frozen",
        "check": "frozen",
        "file": "test/checkout.test.js",
        "line": 1,
        "col": 1,
        "end_line": 1,
        "end_col": 1,
        "text": ""
      }
    ],
    "fix": "a rule holds this path: change the code instead; only the user changes a frozen path, by hand"
  },
  "status": "stopped",
  "stopped_at": "edits"
}
emetgate ✗ rejected · rule_violation · disk untouched · session 0 edits
```

## 4. Change pricing.js and checkout.js together

Call `emetgate_change`:

```json
{
  "edits": [
    {
      "file": "src/pricing.js",
      "old_string": "function applyDiscount(price, percent) {\n  return price * (1 - percent / 100);\n}",
      "new_string": "function applyDiscount(price, rate) {\n  return price * (1 - rate);\n}"
    },
    {
      "file": "src/checkout.js",
      "old_string": "return applyDiscount(price, 15);",
      "new_string": "return applyDiscount(price, 15 / 100);"
    }
  ]
}
```

Reply (accepted; files changed on disk: src/checkout.js, src/pricing.js; HEAD unchanged):

```
{
  "edits": {
    "status": "written",
    "edits": [
      {
        "file": "src/pricing.js",
        "symbol": "",
        "new_hash": "087b6dafb46c337bb6d72de0c16b4816"
      },
      {
        "file": "src/checkout.js",
        "symbol": "",
        "new_hash": "902b1a4ece3f3d9dd4a20d956a9c8ab6"
      }
    ],
    "tests": "ℹ tests 12 | ℹ pass 12 | ℹ fail 0",
    "verified": "tests ran on a mirror of this exact tree; no need to rerun them"
  },
  "parse": "verified: the language check passed after the reparse",
  "status": "applied"
}
emetgate ✓ written · gate full · sent 218 / file 617 chars · session 2 edits
```

## 5. Commit through emetgate

Call `emetgate_change`:

```json
{
  "commit": "pricing: applyDiscount takes a rate; checkout passes 15 / 100"
}
```

Reply (accepted; files changed on disk: none; HEAD f65b21cdba8d -> 24c442122e87):

```
{
  "commit": {
    "status": "applied",
    "commit": "24c442122e87b2075086109f358185d2b794f6b6",
    "base": "f65b21cdba8d7f3b9f1e7d346f1493052f8a89c6",
    "files": 2,
    "receipts": 1,
    "shortstat": "2 files changed, 3 insertions(+), 3 deletions(-)"
  },
  "after": {
    "branch": "main",
    "clean": true
  },
  "status": "applied"
}
```

## Verify the commit

```
$ git notes --ref=emetgate show 24c442122e87b2075086109f358185d2b794f6b6
[{"_type":"https://in-toto.io/Statement/v1","predicate":{"batch":"b1fcc70a47d6a096","checks":[{"command":"node --test","command_digest":"70aaf0767e3bf26b25a731ab8c017e9c","duration_ms":196,"exit_code":0,"kind":"test"}],"class":"spending","emetgate":{"version":"0.10.4"},"evidence":"test","files":[{"after":"087b6dafb46c337bb6d72de0c16b4816","before":"7983d83257be941c4b7c5968eb308cd2","path":"src/pricing.js"},{"after":"902b1a4ece3f3d9dd4a20d956a9c8ab6","before":"e415b8ee2502683c4f74a8792b8c533d","path":"src/checkout.js"}],"operation":"try_batch","resolver":null,"rules":[],"sandbox":{"active_process_limit":512,"integrity":"low","job_memory_bytes":2147483648,"output_limit_bytes":1048576,"timeout_ms":60000},"symbols":[]},"predicateType":"https://emetgate.dev/receipt/v1","subject":[{"digest":{"blake3-128":"087b6dafb46c337bb6d72de0c16b4816","sha256":"2bca84d7c8df3f43e5cd3a71d1b72af0cb6ab02c5e195127f4ce7acc84dcc6b7"},"name":"src/pricing.js"},{"digest":{"blake3-128":"902b1a4ece3f3d9dd4a20d956a9c8ab6","sha256":"680f83fa7eefa45da993a4449793e6136106588eee24681d850b86886e4e15b0"},"name":"src/checkout.js"}]}]
```

```
$ emetgate verify 24c442122e87b2075086109f358185d2b794f6b6 --test "node --test"
commit 24c442122e87b2075086109f358185d2b794f6b6: verified
  verified   src/pricing.js
  verified   src/checkout.js
  receipt d5598c51fadd225e try_batch: verified
(exit 0)
```

```
$ python tools/verify_py/emetgate_verify.py 24c442122e87b2075086109f358185d2b794f6b6 --repo .
commit 24c442122e87b2075086109f358185d2b794f6b6: consistent
  consistent src/pricing.js
  consistent src/checkout.js
  not checked here: tests
  consistent: everything this checker checks holds; it is not verified, the fields above were not checked
(exit 55)
```

The same two checks on a fresh clone of `session.bundle` (see README.md): `commit 24c442122e87b2075086109f358185d2b794f6b6: verified` (exit 0) and `commit 24c442122e87b2075086109f358185d2b794f6b6: consistent` (exit 55).

## Footnotes

1. Step 1: the search answers `✓ 4 matches in 6 files @a4eb; excluded 1 internal`, status `complete`: 4 matches, 6 of 6 files in scope evaluated; the certificate's rfc9162 Merkle root over every file read is `a4eb1d5b5145585c23c9101ea97e1e3fc22e56f817eaa8e2199f9f69787e7a5a`.
2. Step 2: refused, reason `tests_failed`, `ℹ tests 12 | ℹ pass 7 | ℹ fail 5`. First failing test: `15% discount on 100 gives 85`, expected `85`, actual `-1400`. Failing: `15% discount on 100 gives 85`, `15% discount on 200 gives 170`, `discount on 0 is 0`, `cart total discounts every item`, `cart total rounds to cents`. Files changed on disk: none.
3. Step 3: refused, reason `rule_violation`: rule `m646f290bae923802` ("tests are frozen", check `frozen`) holds `test/checkout.test.js`. Fix: "a rule holds this path: change the code instead; only the user changes a frozen path, by hand". Files changed on disk: none.
4. Step 4: `written`, `ℹ tests 12 | ℹ pass 12 | ℹ fail 0`, "tests ran on a mirror of this exact tree; no need to rerun them". Receipt id `d5598c51fadd225e0eac370875569de84abe5277e9b437f952b098b297ae0bfa` (from `emetgate verify --json`; the SHA-256 of the canonical receipt in the note, computed by the replay, is `d5598c51fadd225e0eac370875569de84abe5277e9b437f952b098b297ae0bfa`).
5. Step 5: commit `24c442122e87b2075086109f358185d2b794f6b6`, 2 files, 1 receipt attached under `refs/notes/emetgate`.
6. `emetgate verify 24c442122e87b2075086109f358185d2b794f6b6 --test "node --test"`: `commit 24c442122e87b2075086109f358185d2b794f6b6: verified` (exit 0).
7. Independent Python checker `tools/verify_py/emetgate_verify.py`: `commit 24c442122e87b2075086109f358185d2b794f6b6: consistent` (exit 55). It does not rerun tests, so `consistent` is the most it reports.
8. From a fresh clone of `session.bundle`: `commit 24c442122e87b2075086109f358185d2b794f6b6: verified` (exit 0) and `commit 24c442122e87b2075086109f358185d2b794f6b6: consistent` (exit 55).
