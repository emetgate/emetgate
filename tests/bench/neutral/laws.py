import collections
import glob
import gzip
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
CURRENT = ['emetgate', 'emetgate-v0.3.0', 'serena', 'claude-code', 'codebase-memory-mcp']
INSTRUCTED = 'emetgate-9236f27-instructed'
FIRST_SET = ('nest', 'typeorm', 'actual')
WRITE, READ, OUTPUT = 2.0, 0.1, 5.0


def load():
    keys = {}
    for path in glob.glob(HERE + '/keys/*.json'):
        data = json.load(open(path, encoding='utf-8'))
        keys[data['repo']] = {q: [[m.lower() for m in item['match']] for item in body['items'] if item['match']] for q, body in data['questions'].items()}
    sessions = []
    for path in sorted(glob.glob(HERE + '/sessions/*.jsonl.gz')):
        with gzip.open(path, 'rt', encoding='utf-8') as f:
            for line in f:
                s = json.loads(line)
                s['items'] = keys[s['repo']][s['question']]
                sessions.append(s)
    return sessions


def ols(X, y):
    n = len(X[0])
    A = [[sum(x[i] * x[j] for x in X) for j in range(n)] for i in range(n)]
    b = [sum(x[i] * t for x, t in zip(X, y)) for i in range(n)]
    for i in range(n):
        p = A[i][i]
        for j in range(i, n):
            A[i][j] /= p
        b[i] /= p
        for k in range(n):
            if k != i:
                f = A[k][i]
                for j in range(i, n):
                    A[k][j] -= f * A[i][j]
                b[k] -= f * b[i]
    return b


def r2(X, y, c):
    pred = [sum(a * b for a, b in zip(x, c)) for x in X]
    mean = sum(y) / len(y)
    return 1 - sum((p - t) ** 2 for p, t in zip(pred, y)) / sum((t - mean) ** 2 for t in y)


def units(s):
    u = s['usage']
    return WRITE * u['cache_write'] + READ * u['cache_read'] + u['input'] + OUTPUT * u['output']


def model_calls(s):
    return sum(1 for e in s['events'] if e['t'] == 'model')


def tool_chars(s):
    return sum(e['chars'] for e in s['events'] if e['t'] == 'result')


def has(text, item):
    return any(m in text for m in item)


def code_lines(text):
    out = []
    for line in text.split('\n'):
        t = line.strip()
        i = 0
        while i < len(t) and (t[i].isdigit() or t[i] in ' \t:|-→'):
            i += 1
        t = ' '.join(t[i:].split())
        if len(t) >= 20:
            out.append(t)
    return out


def walk(s):
    decisions = []
    asked = ''
    context = ''
    pending = ''
    got = set()
    seen_lines = set()
    fresh = [0, 0]
    for e in s['events']:
        if e['t'] == 'result':
            pending += e['text'].lower()
            if len(got) == len(s['items']):
                lines = code_lines(e['text'])
                fresh[0] += sum(len(t) for t in lines)
                fresh[1] += sum(len(t) for t in lines if t not in seen_lines)
            seen_lines.update(code_lines(e['text']))
            continue
        if pending:
            context += pending
            for i, item in enumerate(s['items']):
                if i not in got and has(context, item):
                    got.add(i)
            decisions.append({'stop': not e['calls'], 'missing': len(s['items']) - len(got)})
            pending = ''
        asked += ' ' + json.dumps([c['input'] for c in e['calls']], ensure_ascii=False).lower()
    answer = s['answer'].lower()
    items = [{'met': has(answer, item), 'seen': has(context, item), 'asked': has(asked, item), 'id': (s['repo'], s['question'], i)} for i, item in enumerate(s['items'])]
    return decisions, items, fresh


def main():
    sessions = load()
    print(f'sessions {len(sessions)}')

    base = [s['cost_usd'] / units(s) * 1e6 for s in sessions]
    print(f'\n1. cost = base x ({WRITE:g} x written + {READ:g} x read + input + {OUTPUT:g} x output): implied base {min(base):.3f} to {max(base):.3f} USD per million over {len(base)} sessions')

    plain = [s for s in sessions if s['arm'] != INSTRUCTED]
    print(f'\n2. fits on the {len(plain)} sessions without an answer instruction')
    X = [[1, model_calls(s)] for s in plain]
    y = [s['usage']['output'] for s in plain]
    c = ols(X, y)
    per_call_output = c[1]
    print(f'   output tokens  = {c[0]:.0f} + {c[1]:.0f} x model calls   R2 {r2(X, y, c):.2f}')
    X = [[s['usage']['output']] for s in plain]
    y = [s['api_ms'] / 1000 for s in plain]
    c = ols(X, y)
    speed = 1 / c[0]
    print(f'   API seconds    = output tokens / {speed:.0f}   R2 {r2(X, y, c):.2f}')
    X = [[1, tool_chars(s), model_calls(s)] for s in plain]
    y = [s['usage']['cache_write'] for s in plain]
    c = ols(X, y)
    print(f'   tokens written = {c[0]:.0f} + {c[1]:.3f} x tool output characters + {c[2]:.0f} x model calls   R2 {r2(X, y, c):.2f}')
    later = [s for s in plain if model_calls(s) > 1]
    prefix = sum(s['usage']['cache_read'] for s in later) / sum(model_calls(s) - 1 for s in later)
    call = OUTPUT * per_call_output + WRITE * c[2] + READ * prefix
    print(f'\n3. one model call = {call:.0f} base tokens = {call * 2 / 1e6:.4f} USD = {per_call_output / speed:.1f} s = {call / (WRITE * c[1]):.0f} characters of tool output')

    stops = stops_full = far = far_stops = goes = goes_full = 0
    asked = [0, 0]
    seen_only = [0, 0]
    by_item = collections.defaultdict(lambda: [[0, 0], [0, 0]])
    fresh = [0, 0]
    for s in plain:
        decisions, items, f = walk(s)
        fresh[0] += f[0]
        fresh[1] += f[1]
        for d in decisions:
            if d['stop']:
                stops += 1
                stops_full += d['missing'] == 0
            else:
                goes += 1
                goes_full += d['missing'] == 0
            if d['missing'] >= 2:
                far += 1
                far_stops += d['stop']
        for it in items:
            if not it['seen']:
                continue
            cell = asked if it['asked'] else seen_only
            cell[0] += it['met']
            cell[1] += 1
            pair = by_item[it['id']][0 if it['asked'] else 1]
            pair[0] += it['met']
            pair[1] += 1
    print(f'\n4. stops with every answer-key item in the context: {stops_full} of {stops}')
    print(f'   stops with two or more items missing: {far_stops} of {far} decisions')
    print(f'   calls made with every item already in the context: {goes_full} of {goes} = {goes_full / goes:.2f}')
    print(f'   code in the replies to those calls that was not seen before: {fresh[1] / max(1, fresh[0]):.2f}')
    print(f'\n5. item reaches the answer when the model named it in a call: {asked[0]} of {asked[1]} = {asked[0] / asked[1]:.3f}')
    print(f'   when it was only present in tool output: {seen_only[0]} of {seen_only[1]} = {seen_only[0] / seen_only[1]:.3f}')
    both = [v for v in by_item.values() if v[0][1] and v[1][1]]
    a = [sum(v[0][0] for v in both), sum(v[0][1] for v in both)]
    b = [sum(v[1][0] for v in both), sum(v[1][1] for v in both)]
    print(f'   same item, both ways: {a[0]} of {a[1]} = {a[0] / a[1]:.3f} against {b[0]} of {b[1]} = {b[0] / b[1]:.3f}')

    print('\n6. arm | sessions | score | tokens | API s | USD | model calls')
    for name, pick in (('nest, typeorm, actual', lambda r: r in FIRST_SET), ('openbot', lambda r: r == 'openbot'), ('all four repositories', lambda r: True)):
        print('  ', name)
        for arm in CURRENT:
            rows = [s for s in sessions if s['arm'] == arm and pick(s['repo'])]
            met = sum(sum(has(s['answer'].lower(), item) for item in s['items']) for s in rows)
            total = sum(len(s['items']) for s in rows)
            mean = lambda f: sum(f(s) for s in rows) / len(rows)
            tokens = mean(lambda s: sum(s['usage'].values()))
            print(f"      {arm:20s} {len(rows):2d} | {met}/{total} = {met / total:.3f} | {tokens / 1000:5.1f}k | {mean(lambda s: s['api_ms'] / 1000):4.1f} | {mean(lambda s: s['cost_usd']):.3f} | {mean(model_calls):.1f}")


main()
