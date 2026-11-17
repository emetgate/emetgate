export type Tone = 'read' | 'edit' | 'search' | 'run' | 'quiet' | 'refused'

export type Excerpt = { at: string; text: string; sign: '' | '+' | '−' }

export type Activity = {
  tone: Tone
  dir: string
  name: string
  span: string
  note: string
  total: number | undefined
  from: number | undefined
  to: number | undefined
  marks: readonly number[]
  excerpt: readonly Excerpt[]
  more: number
}

type Args = Record<string, unknown>

const PREVIEW = 4
const WIDTH = 150
const SECRET_NAME = /^(\.env(\..*)?|.+\.env|.+\.(pem|key|p12|pfx|jks|keystore|kdbx|ppk)|id_(rsa|ed25519|ecdsa|dsa)(\.pub)?|\.npmrc|\.pypirc|\.netrc|_netrc|\.git-credentials|\.htpasswd|\.pgpass|credentials(\.json)?)$/i
const PUBLIC_ENV = /^\.env\.(example|sample|template|dist)$/i
const SECRET_DIR = /(^|\/)(\.ssh|\.gnupg|\.aws)\//i
const SECRET_WORD = /secret|credential/i
const DATA_FILE = /^[^.]+$|\.(json|ya?ml|toml|ini|txt|cfg|conf|properties|xml)$/i
const MAX_FILES = 128
const MAX_LINES = 4000
const MAX_TURN_FILES = 200
const READERS = ['read_file', 'read_symbol', 'skeleton', 'symbols', 'list', 'expand', 'explore', 'evidence']
const SEARCHERS = ['search', 'find', 'scan']
const WRITERS = ['change', 'try', 'try_batch', 'edit', 'write', 'write_doc', 'mutate', 'rename', 'move', 'move_file', 'delete']

const str = (args: Args | undefined, key: string): string => (args !== undefined && typeof args[key] === 'string' ? (args[key] as string) : '')

const num = (value: unknown): number | undefined => (typeof value === 'number' && Number.isFinite(value) ? value : undefined)

const clean = (line: string): string => {
  const flat = line.replace(/\r$/, '').replace(/\t/g, '  ').replace(/[\u0000-\u0008\u000b-\u001f\u007f-\u009f\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, '')
  return flat.length > WIDTH ? `${flat.slice(0, WIDTH - 1)}…` : flat
}

const slash = (path: string): string => path.split('\\').join('/')

const split = (path: string): { dir: string; name: string } => {
  const p = slash(path)
  const at = p.lastIndexOf('/')
  return at < 0 ? { dir: '', name: p } : { dir: p.slice(0, at + 1), name: p.slice(at + 1) }
}

const isSecret = (path: string): boolean => {
  const p = slash(path)
  const name = p.slice(p.lastIndexOf('/') + 1)
  if (SECRET_DIR.test(p)) return true
  if (PUBLIC_ENV.test(name)) return false
  if (SECRET_NAME.test(name)) return true
  return SECRET_WORD.test(name) && DATA_FILE.test(name)
}

const parse = (text: string): { head: Args | undefined; body: string[] } => {
  const trimmed = text.trim()
  const lines = text.split('\n')
  const tryJson = (raw: string): Args | undefined => {
    try {
      const value = JSON.parse(raw)
      return value !== null && typeof value === 'object' && !Array.isArray(value) ? (value as Args) : undefined
    } catch {
      return undefined
    }
  }
  const whole = trimmed.startsWith('{') ? tryJson(trimmed) : undefined
  if (whole !== undefined) {
    const inner = str(whole, 'content') || str(whole, 'body') || str(whole, 'output') || str(whole, 'value')
    return { head: whole, body: inner === '' ? [] : inner.split('\n') }
  }
  for (let i = 0; i < Math.min(lines.length, 4); i += 1) {
    const candidate = lines[i].trim()
    if (!candidate.startsWith('{')) continue
    const head = tryJson(candidate)
    if (head !== undefined) return { head, body: lines.slice(i + 1) }
  }
  return { head: undefined, body: lines }
}

const excerptOf = (body: string[], start: number | undefined): { excerpt: Excerpt[]; more: number } => {
  const rows = body
    .map((line, index) => ({ at: start === undefined ? '' : String(start + index), text: clean(line), sign: '' as const }))
    .filter(row => row.text.trim() !== '' && !row.text.startsWith('== ') && !row.text.startsWith('{"file":'))
  return { excerpt: rows.slice(0, PREVIEW), more: Math.max(0, rows.length - PREVIEW) }
}

const empty = { total: undefined, from: undefined, to: undefined, marks: [] as number[], excerpt: [] as Excerpt[], more: 0 }

const filesOf = (args: Args): string[] => {
  const found: string[] = []
  const add = (value: unknown) => {
    if (typeof value === 'string' && value !== '' && !found.includes(value)) found.push(value)
  }
  add(args.file)
  add(args.from)
  if (Array.isArray(args.files)) args.files.forEach(item => add(typeof item === 'string' ? item : (item as Args)?.file))
  if (Array.isArray(args.edits)) args.edits.forEach(item => add((item as Args)?.file))
  return found
}

const place = (files: string[]): { dir: string; name: string } => {
  if (files.length === 0) return { dir: '', name: '' }
  const first = split(files[0])
  return files.length === 1 ? first : { dir: first.dir, name: `${first.name} +${files.length - 1}` }
}

const read = (tool: string, args: Args, text: string): Activity => {
  const files = filesOf(args)
  const where = place(files)
  if (files.some(isSecret)) return { tone: 'read', ...where, span: '', note: 'content hidden', ...empty }
  const { head, body } = parse(text)
  const symbol = str(args, 'symbol') || (Array.isArray(args.symbols) ? (args.symbols as unknown[]).join(', ') : '') || str(head, 'symbol')
  const heading = str(args, 'heading')
  const pointer = str(args, 'pointer')
  const from = num(head?.start_line) ?? num(args.line_start)
  const to = num(head?.end_line) ?? num(args.line_end)
  const total = num(head?.total_lines)
  const label = [symbol, heading === '' ? '' : `§ ${heading}`, pointer].filter(part => part !== '').join(' · ')
  const span = from !== undefined && to !== undefined ? `${from}–${to}${total === undefined ? '' : ` / ${total}`}` : tool === 'skeleton' ? 'outline' : ''
  const shown = excerptOf(body, from)
  const whole = from === undefined && symbol === '' && heading === '' && pointer === '' && tool === 'read_file'
  return { tone: 'read', ...where, span: whole ? 'whole file' : span, note: label, total: whole ? 1 : total, from: whole ? 1 : from, to: whole ? 1 : to, marks: [], ...shown }
}

export type Hit = { file: string; line: number; text: string }

export const hitsOf = (text: string): Hit[] => {
  const legend = new Map<string, string>()
  const hits: Hit[] = []
  let file = ''
  for (const raw of text.split('\n')) {
    const line = raw.replace(/\r$/, '')
    const named = /^\|(\d+) (.*)$/.exec(line)
    if (named) {
      legend.set(named[1], named[2])
      continue
    }
    const own = /^\s*(\d+)\*?([:│|])\s?(.*)$/.exec(line)
    if (own && file !== '') {
      hits.push({ file, line: Number(own[1]), text: own[2] === '|' ? legend.get(own[3].trim()) ?? '' : own[3] })
      continue
    }
    const inline = /^([^\s:][^:]*):(\d+)(?::\d+)?:\s?(.*)$/.exec(line)
    if (inline) {
      hits.push({ file: inline[1], line: Number(inline[2]), text: inline[3] })
      continue
    }
    const t = line.trim()
    if (t !== '' && t === line && !t.startsWith('✓') && !t.startsWith('partial') && !t.endsWith(':') && !/^\d+ hits? in /.test(t)) file = t
  }
  return hits
}

const search = (tool: string, args: Args, text: string): Activity => {
  const query = str(args, 'pattern') || str(args, 'check') || str(args, 'question')
  const files = new Set<string>()
  const rows: Excerpt[] = []
  for (const hit of hitsOf(text)) {
    files.add(hit.file)
    if (isSecret(hit.file)) continue
    rows.push({ at: `${split(hit.file).name}:${hit.line}`, text: clean(hit.text.trim()), sign: '' })
  }
  const none = files.size === 0
  const count = hitsOf(text).length
  const note = none ? 'no match' : `${count} hit${count === 1 ? '' : 's'} in ${files.size} file${files.size === 1 ? '' : 's'}`
  return { tone: 'search', dir: tool === 'search' ? '' : `${tool} `, name: `“${query}”`, span: '', note, ...empty, excerpt: rows.slice(0, PREVIEW), more: Math.max(0, rows.length - PREVIEW) }
}

const diff = (before: string, after: string, start: number | undefined): Excerpt[] => {
  const a = before === '' ? [] : before.split('\n')
  const b = after === '' ? [] : after.split('\n')
  let head = 0
  while (head < a.length && head < b.length && a[head] === b[head]) head += 1
  let tail = 0
  while (tail < a.length - head && tail < b.length - head && a[a.length - 1 - tail] === b[b.length - 1 - tail]) tail += 1
  const at = (i: number) => (start === undefined ? '' : String(start + head + i))
  return [
    ...a.slice(head, a.length - tail).map((line, i) => ({ at: at(i), text: clean(line), sign: '−' as const })),
    ...b.slice(head, b.length - tail).map((line, i) => ({ at: at(i), text: clean(line), sign: '+' as const })),
  ]
}

const edit = (tool: string, args: Args, text: string): Activity => {
  const items: Args[] = Array.isArray(args.edits) ? (args.edits as Args[]) : [args]
  const files = filesOf(args)
  const where = tool === 'move_file' ? { dir: '', name: `${slash(str(args, 'from'))} → ${slash(str(args, 'to'))}` } : place(files)
  const rows: Excerpt[] = []
  let plus = 0
  let minus = 0
  for (const item of items) {
    const changed = diff(str(item, 'old_string'), str(item, 'new_string') || str(item, 'content') || str(item, 'body') || str(item, 'text'), num(item.line_start))
    plus += changed.filter(row => row.sign === '+').length
    minus += changed.filter(row => row.sign === '−').length
    if (!isSecret(str(item, 'file'))) rows.push(...changed)
  }
  const gate = text.split('\n').map(line => line.trim()).find(line => /^emetgate [✓✗]/.test(line))
  const verdict = gate === undefined ? '' : gate.replace(/^emetgate\s*/, '').split('·')[0].trim()
  const symbol = str(args, 'symbol')
  const created = items.length === 1 && str(items[0], 'old_string') === '' && str(items[0], 'content') !== '' && num(items[0].line_start) === undefined
  const note = created ? [`written · ${plus} lines`, verdict].filter(part => part !== '').join(' · ') : [symbol, `+${plus} −${minus}`, verdict].filter(part => part !== '').join(' · ')
  return { tone: 'edit', ...where, span: '', note: files.some(isSecret) ? `${note} · content hidden` : note, ...empty, excerpt: rows.slice(0, PREVIEW), more: Math.max(0, rows.length - PREVIEW) }
}

const run = (args: Args, text: string): Activity => {
  const { head, body } = parse(text)
  const code = num(head?.exit_code)
  const ms = num(head?.duration_ms)
  const note = [code === undefined ? '' : code === 0 ? 'ok' : `exit ${code}`, ms === undefined ? '' : ms >= 1000 ? `${(ms / 1000).toFixed(1)}s` : `${ms}ms`].filter(part => part !== '').join(' · ')
  const shown = excerptOf(body, undefined)
  return { tone: code === undefined || code === 0 ? 'run' : 'refused', dir: '$ ', name: clean(str(args, 'command')), span: '', note, ...empty, ...shown }
}

const other = (tool: string, args: Args, text: string): Activity => {
  const { head, body } = parse(text)
  const name = [tool, str(args, 'sub'), str(args, 'message')].filter(part => part !== '').join(' ')
  const note = ['status', 'commit', 'shortstat', 'branch']
    .map(key => head?.[key])
    .filter((value): value is string => typeof value === 'string')
    .map(value => (value.length === 40 ? value.slice(0, 7) : value))
    .join(' · ')
  return { tone: 'quiet', dir: '', name, span: '', note, ...empty, ...excerptOf(body, undefined) }
}

export const activityOf = (fullName: string, args: Args, text: string, isOk: boolean): Activity => {
  const tool = fullName.slice(fullName.lastIndexOf('emetgate_') + 'emetgate_'.length)
  if (!isOk) {
    const { head } = parse(text)
    const reason = str(head, 'error') || clean(text.split('\n')[0] ?? '')
    const files = filesOf(args)
    const where = files.length > 0 ? place(files) : { dir: '', name: str(args, 'command') || str(args, 'pattern') || tool }
    return { tone: 'refused', ...where, span: '', note: `refused · ${reason}`, ...empty }
  }
  if (READERS.includes(tool)) return read(tool, args, text)
  if (SEARCHERS.includes(tool)) return search(tool, args, text)
  if (WRITERS.includes(tool)) return edit(tool, args, text)
  if (tool === 'run') return run(args, text)
  return other(tool, args, text)
}

export const BAR = 20

export const barOf = (entry: Activity): { before: string; lit: string; after: string } | undefined => {
  if (entry.total === undefined || entry.from === undefined || entry.to === undefined || entry.total <= 0) return undefined
  const a = Math.min(BAR - 1, Math.floor(((entry.from - 1) / entry.total) * BAR))
  const b = Math.max(a + 1, Math.min(BAR, Math.ceil((entry.to / entry.total) * BAR)))
  return { before: '─'.repeat(a), lit: '━'.repeat(b - a), after: '─'.repeat(BAR - b) }
}

export type Strip = { label: string; total: number; seen: readonly (readonly [number, number])[]; now?: readonly [number, number]; edit?: number; edits?: readonly number[]; head?: number; hits: readonly number[]; percent: number; flag: '' | 'seen' | 'unread' }

type Known = { total: number | undefined; seen: [number, number][]; lines: Map<number, string>; symbols: Map<string, [number, number]> }

const known = new Map<string, Known>()

const keyOf = (path: string): string => slash(path).replace(/^\.\//, '').toLowerCase()

const fileOf = (path: string): Known => {
  const key = keyOf(path)
  let entry = known.get(key)
  if (entry === undefined) {
    entry = { total: undefined, seen: [], lines: new Map(), symbols: new Map() }
  } else {
    known.delete(key)
  }
  known.set(key, entry)
  for (const old of known.keys()) {
    if (known.size <= MAX_FILES) break
    known.delete(old)
  }
  return entry
}

const keep = (entry: Known, line: number, text: string): void => {
  entry.lines.delete(line)
  entry.lines.set(line, text.replace(/\r$/, ''))
  for (const old of entry.lines.keys()) {
    if (entry.lines.size <= MAX_LINES) break
    entry.lines.delete(old)
  }
}

const merge = (ranges: [number, number][]): [number, number][] => {
  const sorted = [...ranges].sort((a, b) => a[0] - b[0])
  const out: [number, number][] = []
  for (const [a, b] of sorted) {
    const last = out[out.length - 1]
    if (last !== undefined && a <= last[1] + 1) last[1] = Math.max(last[1], b)
    else out.push([a, b])
  }
  return out
}

const percentOf = (entry: Known): number => {
  if (entry.total === undefined || entry.total <= 0) return 0
  const covered = entry.seen.reduce((sum, [a, b]) => sum + (Math.min(b, entry.total as number) - a + 1), 0)
  return Math.min(100, Math.round((covered / entry.total) * 100))
}

const stripOf = (label: string, entry: Known, extra: Partial<Strip>): Strip | undefined =>
  entry.total === undefined ? undefined : { label, total: entry.total, seen: entry.seen.map(r => [r[0], r[1]] as const), hits: [], percent: percentOf(entry), flag: '', ...extra }

const learn = (path: string, text: string, args: Args): void => {
  const entry = fileOf(path)
  const { head, body } = parse(text)
  const total = num(head?.total_lines)
  if (total !== undefined) entry.total = total
  const sections: { from: number; to: number; lines: string[] }[] = []
  let current: { from: number; to: number; lines: string[] } | undefined
  for (const line of body) {
    if (line.startsWith('== {')) {
      try {
        const meta = JSON.parse(line.slice(3)) as Args
        const a = num(meta.start_line)
        const b = num(meta.end_line)
        current = a !== undefined && b !== undefined ? { from: a, to: b, lines: [] } : undefined
        if (current !== undefined) sections.push(current)
        if (a !== undefined && b !== undefined && str(meta, 'symbol') !== '') entry.symbols.set(str(meta, 'symbol'), [a, b])
      } catch {
        current = undefined
      }
      continue
    }
    current?.lines.push(line)
  }
  if (sections.length > 0) {
    for (const section of sections) {
      entry.seen = merge([...entry.seen, [section.from, section.to]])
      section.lines.forEach((line, index) => keep(entry, section.from + index, line))
    }
    return
  }
  const from = num(head?.start_line) ?? num(head?.requested_start_line)
  const to = num(head?.end_line) ?? num(head?.requested_end_line)
  if (from !== undefined && to !== undefined) {
    entry.seen = merge([...entry.seen, [from, to]])
    body.forEach((line, index) => keep(entry, from + index, line))
    const symbol = str(args, 'symbol') || str(head, 'symbol')
    if (symbol !== '') entry.symbols.set(symbol, [from, to])
    return
  }
  const isWhole = head !== undefined && head.truncated !== true && head.status !== 'partial' && str(args, 'symbol') === '' && str(args, 'heading') === '' && str(args, 'pointer') === '' && body.length > 0
  if (isWhole) {
    const lines = body[body.length - 1] === '' ? body.slice(0, -1) : body
    entry.total = lines.length
    entry.seen = [[1, lines.length]]
    entry.lines = new Map()
    lines.forEach((line, index) => keep(entry, index + 1, line))
  }
}

const locate = (entry: Known, oldText: string): number | undefined => {
  const first = oldText.split('\n').map(line => line.trim()).find(line => line !== '')
  if (first === undefined) return undefined
  for (const [line, text] of entry.lines) if (text.includes(first)) return line
  return undefined
}

export type DiffRow = { n: number | undefined; sign: ' ' | '+' | '−'; text: string }

export type Native = { title: string; arg: string; summary: string; body: readonly string[]; bodyMore: number; diff: readonly DiffRow[]; diffMore: number }

export type Observed = Activity & { strips: readonly Strip[]; native?: Native }

let lastDiff: DiffRow[] | undefined

const DIFF_ROWS = 10
const BODY_ROWS = 4
const CONTEXT = 2

const contextDiff = (entry: Known, at: number, oldText: string, newText: string): DiffRow[] => {
  const a = oldText.split('\n')
  const b = newText.split('\n')
  let head = 0
  while (head < a.length - 1 && head < b.length - 1 && a[head] === b[head]) head += 1
  let tail = 0
  while (tail < a.length - head - 1 && tail < b.length - head - 1 && a[a.length - 1 - tail] === b[b.length - 1 - tail]) tail += 1
  const rows: DiffRow[] = []
  const lead = Math.min(head, CONTEXT)
  for (let n = at - (CONTEXT - lead); n < at; n += 1) {
    const line = entry.lines.get(n)
    if (n >= 1 && line !== undefined) rows.push({ n, sign: ' ', text: clean(line) })
  }
  for (let i = head - lead; i < head; i += 1) rows.push({ n: at + i, sign: ' ', text: clean(a[i]) })
  a.slice(head, a.length - tail).forEach((line, i) => rows.push({ n: at + head + i, sign: '−', text: clean(line) }))
  b.slice(head, b.length - tail).forEach((line, i) => rows.push({ n: at + head + i, sign: '+', text: clean(line) }))
  const shift = b.length - a.length
  const trail = Math.min(tail, CONTEXT)
  for (let i = 0; i < trail; i += 1) rows.push({ n: at + b.length - tail + i, sign: ' ', text: clean(b[b.length - tail + i]) })
  for (let k = 0; k < CONTEXT - trail; k += 1) {
    const n = at + a.length + k
    const line = entry.lines.get(n)
    if (line !== undefined) rows.push({ n: n + shift, sign: ' ', text: clean(line) })
  }
  return rows
}

const plural = (n: number, word: string): string => `${n} ${word}${n === 1 ? '' : 's'}`

const outputLines = (text: string): string[] => parse(text).body.map(line => clean(line)).filter(line => line.trim() !== '' && !/^emetgate [✓✗]/.test(line.trim()))

const nativeOf = (tool: string, base: Activity, args: Args, text: string, diffRows: DiffRow[] | undefined): Native => {
  const files = filesOf(args)
  const path = files.map(slash).join(', ')
  const empty: Native = { title: tool, arg: path, summary: base.note, body: [], bodyMore: 0, diff: [], diffMore: 0 }
  const titleOf = (): string => {
    if (tool === 'read_file' || tool === 'read_symbol' || tool === 'expand') return 'Read'
    if (tool === 'skeleton') return 'Outline'
    if (tool === 'symbols') return 'Symbols'
    if (tool === 'list') return 'List'
    if (tool === 'explore') return 'Explore'
    if (tool === 'evidence') return 'Evidence'
    if (SEARCHERS.includes(tool)) return tool === 'scan' ? 'Scan' : 'Search'
    if (tool === 'rename') return 'Rename'
    if (tool === 'move' || tool === 'move_file') return 'Move'
    if (WRITERS.includes(tool)) return 'Update'
    if (tool === 'run') return 'Bash'
    if (tool === 'git' || tool === 'git_write') return 'Git'
    if (tool === 'commit') return 'Commit'
    return tool
  }
  const title = titleOf()
  if (base.tone === 'refused') {
    return { ...empty, title, arg: path || str(args, 'command') || str(args, 'pattern'), summary: base.note.replace(/^refused · /, 'Refused: ') }
  }
  if (READERS.includes(tool)) {
    if (base.note === 'content hidden') return { ...empty, title, summary: 'Content hidden (secret file)' }
    const symbol = str(args, 'symbol') || (Array.isArray(args.symbols) ? (args.symbols as unknown[]).join(', ') : '')
    const heading = str(args, 'heading')
    const pointer = str(args, 'pointer')
    const part = symbol || (heading !== '' ? `§ ${heading}` : pointer)
    const arg = part === '' ? path : `${path} · ${part}`
    if (tool === 'read_file' || tool === 'read_symbol' || tool === 'expand') {
      const count = base.from !== undefined && base.to !== undefined && base.span !== 'whole file' ? base.to - base.from + 1 : base.total
      const lines = count === undefined ? '' : `Read ${plural(count, 'line')}`
      const range = base.from !== undefined && base.to !== undefined && base.span !== 'whole file' ? ` (${base.from}–${base.to}${base.total !== undefined ? ` of ${base.total}` : ''})` : ''
      return { ...empty, title, arg, summary: lines === '' ? 'Read' : `${lines}${range}` }
    }
    const body = outputLines(text)
    return { ...empty, title, arg: tool === 'list' ? str(args, 'dir') || '.' : tool === 'explore' ? str(args, 'question') : arg, summary: base.note || `${plural(body.length, 'line')}`, body: body.slice(0, BODY_ROWS), bodyMore: Math.max(0, body.length - BODY_ROWS) }
  }
  if (SEARCHERS.includes(tool)) {
    const query = str(args, 'pattern') || str(args, 'check') || str(args, 'question')
    const where = str(args, 'dir') || str(args, 'where')
    const hits = hitsOf(text).filter(hit => !isSecret(hit.file))
    const files2 = new Set(hitsOf(text).map(hit => hit.file))
    const count = hitsOf(text).length
    const summary = count === 0 ? 'No matches' : `Found ${plural(count, 'hit')} in ${plural(files2.size, 'file')}`
    const body = hits.map(hit => `${slash(hit.file)}:${hit.line}  ${clean(hit.text.trim())}`)
    return { ...empty, title, arg: `"${query}"${where === '' ? '' : ` in ${where}`}`, summary, body: body.slice(0, BODY_ROWS), bodyMore: Math.max(0, body.length - BODY_ROWS) }
  }
  if (tool === 'db' || tool === 'db_write') {
    const { head, body } = parse(text)
    const db = str(args, 'db') || str(head, 'db')
    const op = tool === 'db_write' ? 'write' : str(args, 'op') || 'query'
    const sql = clean(str(args, 'sql').replace(/\s+/g, ' ').trim())
    const target = sql || str(args, 'table')
    const arg = [db, target].filter(part => part !== '').join(' · ')
    const list = (value: unknown) => (Array.isArray(value) ? (value as unknown[]).map(String) : [])
    const guarded = [list(head?.hidden).length > 0 ? `hidden: ${list(head?.hidden).join(', ')}` : '', list(head?.masked).length > 0 ? `masked: ${list(head?.masked).join(', ')}` : ''].filter(part => part !== '')
    if (tool === 'db_write') {
      const rows = num(head?.rows_affected)
      const action = str(head, 'action') || 'write'
      const summary = rows === undefined ? 'Done' : `${action[0].toUpperCase()}${action.slice(1)}d ${plural(rows, 'row')}${str(head, 'table') === '' ? '' : ` in ${str(head, 'table')}`}${head?.destructive === true ? ' (destructive)' : ''}`
      return { ...empty, title: 'DB write', arg, summary }
    }
    if (op === 'tables') {
      const tables = list(head?.tables)
      return { ...empty, title: 'DB tables', arg: db, summary: `${plural(tables.length, 'table')}${num(head?.withheld) ? ` · ${num(head?.withheld)} withheld` : ''}`, body: tables.slice(0, BODY_ROWS), bodyMore: Math.max(0, tables.length - BODY_ROWS) }
    }
    const rows = num(head?.row_count)
    const ms = num(head?.ms)
    const summary = [rows === undefined ? '' : `${plural(rows, 'row')}${head?.more === true ? '+' : ''}`, ms === undefined ? '' : `${ms}ms`, ...guarded].filter(part => part !== '').join(' · ') || 'Done'
    const lines = body.map(line => clean(line)).filter(line => line.trim() !== '')
    const title = op === 'query' ? 'Query' : op === 'describe' ? 'DB describe' : op === 'explain' ? 'Explain' : op === 'sample' ? 'DB sample' : op === 'count' ? 'DB count' : 'DB'
    return { ...empty, title, arg, summary, body: lines.slice(0, BODY_ROWS), bodyMore: Math.max(0, lines.length - BODY_ROWS) }
  }
  if (tool === 'delete') {
    const { head } = parse(text)
    const folders = Array.isArray(head?.emptied_folders) ? (head?.emptied_folders as unknown[]).length : 0
    const names = files.map(file => split(file).name)
    const arg = names.length <= 3 ? files.map(slash).join(', ') : `${files.slice(0, 2).map(slash).join(', ')} +${files.length - 2}`
    return { ...empty, title: 'Delete', arg, summary: `Deleted ${plural(files.length, 'file')}${folders > 0 ? ` and ${plural(folders, 'empty folder')}` : ''}` }
  }
  if (WRITERS.includes(tool)) {
    const items: Args[] = Array.isArray(args.edits) ? (args.edits as Args[]) : [args]
    const created = items.length === 1 && str(items[0], 'old_string') === '' && str(items[0], 'content') !== '' && num(items[0].line_start) === undefined
    const gate = /✓ written/.test(base.note) ? '' : ''
    if (tool === 'move_file') return { ...empty, title, arg: `${slash(str(args, 'from'))} → ${slash(str(args, 'to'))}`, summary: 'Moved' }
    if (tool === 'rename') return { ...empty, title, arg: `${path} · ${str(args, 'symbol')} → ${str(args, 'new_name')}`, summary: 'Renamed' }
    if (created) {
      const lines = str(items[0], 'content').split('\n')
      const kept = lines[lines.length - 1] === '' ? lines.slice(0, -1) : lines
      if (isSecret(path)) return { ...empty, title: 'Write', summary: `Wrote ${plural(kept.length, 'line')} to ${split(path).name} (content hidden)` }
      const rows: DiffRow[] = kept.slice(0, BODY_ROWS).map((line, i) => ({ n: i + 1, sign: ' ', text: clean(line) }))
      return { ...empty, title: 'Write', summary: `Wrote ${plural(kept.length, 'line')} to ${split(path).name}${gate}`, diff: rows, diffMore: Math.max(0, kept.length - BODY_ROWS) }
    }
    const m = /\+(\d+) −(\d+)/.exec(base.note)
    const plus = m ? Number(m[1]) : 0
    const minus = m ? Number(m[2]) : 0
    const symbol = str(args, 'symbol')
    const arg = symbol === '' ? path : `${path} · ${symbol}`
    const summary = `Updated ${files.length > 1 ? plural(files.length, 'file') : split(path).name} with ${plural(plus, 'addition')} and ${plural(minus, 'removal')}`
    if (files.some(isSecret)) return { ...empty, title, arg, summary: `${summary} (content hidden)` }
    const rows = diffRows ?? base.excerpt.map(row => ({ n: row.at === '' || !/^\d+$/.test(row.at) ? undefined : Number(row.at), sign: (row.sign === '' ? ' ' : row.sign) as DiffRow['sign'], text: row.text }))
    return { ...empty, title, arg, summary, diff: rows.slice(0, DIFF_ROWS), diffMore: Math.max(0, rows.length - DIFF_ROWS) + (diffRows === undefined ? base.more : 0) }
  }
  if (tool === 'run') {
    const { head } = parse(text)
    const code = num(head?.exit_code)
    const ms = num(head?.duration_ms)
    const parts = [code === undefined ? '' : code === 0 ? 'Done' : `Exit code ${code}`, ms === undefined ? '' : ms >= 1000 ? `${(ms / 1000).toFixed(1)}s` : `${ms}ms`].filter(part => part !== '')
    const body = outputLines(text)
    return { ...empty, title, arg: clean(str(args, 'command')), summary: parts.join(' · ') || 'Done', body: body.slice(0, BODY_ROWS), bodyMore: Math.max(0, body.length - BODY_ROWS) }
  }
  const sub = [str(args, 'sub'), Array.isArray(args.args) ? (args.args as unknown[]).join(' ') : str(args, 'args'), str(args, 'message')].filter(part => part !== '').join(' ')
  const body = outputLines(text)
  return { ...empty, title, arg: sub || path, summary: base.note || 'Done', body: body.slice(0, BODY_ROWS), bodyMore: Math.max(0, body.length - BODY_ROWS) }
}

export const observe = (fullName: string, args: Args, text: string, isOk: boolean): Observed => {
  lastDiff = undefined
  const core = observeCore(fullName, args, text, isOk)
  const tool = fullName.slice(fullName.lastIndexOf('emetgate_') + 'emetgate_'.length)
  try {
    return { ...core, native: nativeOf(tool, core, args, text, lastDiff) }
  } catch {
    return core
  }
}

const observeCore = (fullName: string, args: Args, text: string, isOk: boolean): Observed => {
  const base = activityOf(fullName, args, text, isOk)
  const tool = fullName.slice(fullName.lastIndexOf('emetgate_') + 'emetgate_'.length)
  if (!isOk) return { ...base, strips: [] }
  const files = filesOf(args)
  if (READERS.includes(tool) && files.length === 1) {
    learn(files[0], text, args)
    const entry = fileOf(files[0])
    const now: readonly [number, number] | undefined = base.span === 'whole file' && entry.total !== undefined ? [1, entry.total] : base.from !== undefined && base.to !== undefined ? [base.from, Math.min(base.to, entry.total ?? base.to)] : undefined
    const strip = stripOf('', entry, { now })
    return { ...base, total: entry.total, strips: strip === undefined ? [] : [strip] }
  }
  if (SEARCHERS.includes(tool)) {
    const byFile = new Map<string, number[]>()
    for (const hit of hitsOf(text)) byFile.set(hit.file, [...(byFile.get(hit.file) ?? []), hit.line])
    const strips: Strip[] = []
    for (const [path, hits] of byFile) {
      if (!known.has(keyOf(path))) continue
      const entry = fileOf(path)
      const strip = stripOf(split(path).name, entry, { hits })
      if (strip !== undefined) strips.push(strip)
      if (strips.length === 3) break
    }
    return { ...base, strips }
  }
  if (tool === 'delete') {
    for (const file of files) known.delete(keyOf(file))
    return { ...base, strips: [] }
  }
  if (WRITERS.includes(tool)) {
    const strips: Strip[] = []
    const items: Args[] = Array.isArray(args.edits) ? (args.edits as Args[]) : [args]
    for (const item of items) {
      const path = str(item, 'file') || files[0] || ''
      if (path === '') continue
      const entry = fileOf(path)
      const symbol = str(item, 'symbol')
      const lineStart = num(item.line_start)
      const covered = (line: number) => entry.seen.some(([a, b]) => line >= a && line <= b)
      const whole = entry.total !== undefined && covered(1) && covered(entry.total) && entry.seen.length === 1
      const unknown = str(item, 'heading') !== '' || str(item, 'pointer') !== '' || str(item, 'node') !== '' || Array.isArray(item.nodes)
      const found = symbol !== '' ? entry.symbols.get(symbol)?.[0] : lineStart !== undefined ? (covered(lineStart) ? lineStart : undefined) : locate(entry, str(item, 'old_string'))
      const at = found ?? (lineStart !== undefined ? lineStart : undefined)
      const isWhole = str(item, 'content') !== '' && str(item, 'old_string') === '' && symbol === '' && num(item.line_start) === undefined
      if (isWhole) {
        const lines = str(item, 'content').split('\n')
        const kept = lines[lines.length - 1] === '' ? lines.slice(0, -1) : lines
        entry.total = kept.length
        entry.seen = [[1, kept.length]]
        entry.lines = new Map(kept.map((line, index) => [index + 1, line.replace(/\r$/, '')] as const))
        const strip = stripOf(split(path).name, entry, { now: [1, kept.length], flag: '' })
        if (strip !== undefined) strips.push(strip)
        continue
      }
      const flag: Strip['flag'] = found !== undefined || whole ? 'seen' : unknown ? '' : 'unread'
      const oldLines = str(item, 'old_string').split('\n')
      const newLines = (str(item, 'new_string') || str(item, 'body')).split('\n')
      const strip = entry.total === undefined ? { label: split(path).name, total: 0, seen: [], hits: [], percent: 0, flag } : stripOf(split(path).name, entry, { edit: at, flag })
      if (strip !== undefined) strips.push(strip as Strip)
      if (lastDiff === undefined && found !== undefined && str(item, 'old_string') !== '' && !isSecret(path)) {
        lastDiff = contextDiff(entry, found, str(item, 'old_string'), str(item, 'new_string') || str(item, 'body'))
      }
      if (found !== undefined && str(item, 'old_string') !== '') {
        const delta = newLines.length - oldLines.length
        const moved = new Map<number, string>()
        for (const [line, text] of entry.lines) {
          if (line < found) moved.set(line, text)
          else if (line >= found + oldLines.length) moved.set(line + delta, text)
        }
        newLines.forEach((line, index) => moved.set(found + index, line))
        entry.lines = moved
        if (entry.total !== undefined) entry.total += delta
      }
    }
    return { ...base, strips }
  }
  return { ...base, strips: [] }
}

export const CELLS = 24

export type Cell = { ch: string; tone: 'none' | 'seen' | 'now' | 'edit' | 'hit' | 'head' }

export const cellsOf = (strip: Strip): Cell[] => {
  const cells: Cell[] = []
  for (let i = 0; i < CELLS; i += 1) {
    const lo = Math.floor((i * strip.total) / CELLS) + 1
    const hi = Math.max(lo, Math.floor(((i + 1) * strip.total) / CELLS))
    const overlaps = (a: number, b: number) => a <= hi && b >= lo
    if (strip.head !== undefined && overlaps(strip.head, strip.head)) cells.push({ ch: '▸', tone: 'head' })
    else if ((strip.edit !== undefined && overlaps(strip.edit, strip.edit)) || (strip.edits ?? []).some(at => overlaps(at, at))) cells.push({ ch: '◆', tone: 'edit' })
    else if (strip.hits.some(h => overlaps(h, h))) cells.push({ ch: '▌', tone: 'hit' })
    else if (strip.now !== undefined && overlaps(strip.now[0], strip.now[1])) cells.push({ ch: '█', tone: 'now' })
    else if (strip.seen.some(([a, b]) => overlaps(a, b))) cells.push({ ch: '▒', tone: 'seen' })
    else cells.push({ ch: '░', tone: 'none' })
  }
  return cells
}

type TurnFile = { path: string; edits: number[]; changes: number; blind: boolean; checked: boolean; read: number }

const turn = new Map<string, TurnFile>()

export const beginTurn = (): void => turn.clear()

const touch = (path: string): TurnFile => {
  const key = keyOf(path)
  let entry = turn.get(key)
  if (entry === undefined) {
    entry = { path: slash(path), edits: [], changes: 0, blind: false, checked: false, read: 0 }
    turn.set(key, entry)
    for (const old of turn.keys()) {
      if (turn.size <= MAX_TURN_FILES) break
      turn.delete(old)
    }
  }
  return entry
}

export const note = (fullName: string, args: Args, seen: Observed): void => {
  const tool = fullName.slice(fullName.lastIndexOf('emetgate_') + 'emetgate_'.length)
  const files = filesOf(args)
  if (READERS.includes(tool) && files.length === 1) {
    const strip = seen.strips[0]
    const span = strip?.now === undefined ? 0 : strip.now[1] - strip.now[0] + 1
    touch(files[0]).read += span
    return
  }
  if (tool === 'delete') {
    for (const file of files) touch(file).changes += 1
    return
  }
  if (WRITERS.includes(tool)) {
    const items: Args[] = Array.isArray(args.edits) ? (args.edits as Args[]) : [args]
    let index = 0
    items.forEach(item => {
      const path = str(item, 'file') || files[0] || ''
      if (path === '') return
      const entry = touch(path)
      const strip = seen.strips[index]
      index += 1
      entry.changes += 1
      if (strip?.flag === 'seen') entry.checked = true
      if (strip?.edit !== undefined) entry.edits.push(strip.edit)
      if (strip?.flag === 'unread') entry.blind = true
      if (strip?.now !== undefined && strip.edit === undefined) entry.read = Math.max(entry.read, 0)
    })
  }
}

export type ReceiptRow = { dir: string; name: string; strip: Strip | undefined; flag: Strip['flag']; edits: number }

export type Receipt = { rows: ReceiptRow[]; files: number; lines: number; edits: number; blind: number }

export const receipt = (): Receipt | undefined => {
  if (turn.size === 0) return undefined
  const rows: ReceiptRow[] = []
  let lines = 0
  let edits = 0
  let blind = 0
  for (const item of [...turn.values()].sort((a, b) => a.path.localeCompare(b.path))) {
    const where = split(item.path)
    const entry = fileOf(item.path)
    const flag: Strip['flag'] = item.blind ? 'unread' : item.checked ? 'seen' : ''
    rows.push({ ...where, strip: stripOf(where.name, entry, { edits: item.edits, flag }), flag, edits: item.changes })
    lines += item.read
    edits += item.changes
    blind += item.blind ? 1 : 0
  }
  return { rows, files: rows.length, lines, edits, blind }
}

export type Scan = { path: string; from: number; to: number; started: number }

export const scanOf = (fullName: string, args: Args, started: number): Scan | undefined => {
  const tool = fullName.slice(fullName.lastIndexOf('emetgate_') + 'emetgate_'.length)
  const files = filesOf(args)
  if (files.length !== 1 || !(READERS.includes(tool) || WRITERS.includes(tool))) return undefined
  const entry = fileOf(files[0])
  if (entry.total === undefined) return undefined
  const symbol = str(args, 'symbol')
  const range = symbol !== '' ? entry.symbols.get(symbol) : undefined
  const from = num(args.line_start) ?? range?.[0] ?? 1
  const to = num(args.line_end) ?? range?.[1] ?? entry.total
  return { path: files[0], from, to: Math.min(to, entry.total), started }
}

export const scanStrip = (scan: Scan, now: number): Strip | undefined => {
  const entry = fileOf(scan.path)
  if (entry.total === undefined) return undefined
  const progress = Math.min(1, Math.max(0, (now - scan.started) / 700))
  const head = Math.round(scan.from + (scan.to - scan.from) * progress)
  return stripOf(split(scan.path).name, entry, { now: [scan.from, head], head })
}
