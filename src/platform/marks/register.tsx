import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'

import type { Done, Running } from '../types'
import { BAD_TICKS, MIN_COLUMNS, MIN_ROWS, OK_TICKS, WORD_COLUMNS, WORD_ROWS, paint, verdictWord, writingWord } from './scene'
import type { Kind } from './scene'
import { CELLS, beginTurn, cellsOf, note, observe, receipt, scanOf, scanStrip } from './activity'
import type { Observed, Receipt, Scan, Strip } from './activity'

const MARK = 'emetgate_'
const COMMAND = 'golem'
const STORE_KEY = 'scene'
const SIZE_KEY = 'big'
const QUIET_KEY = 'quiet'
const KEPT = 3
const TICK_MS = 90
const TEXT_ROWS = 1
const IDLE_EVERY = 3
const MAX_COLUMNS = 200
const BIG_ROWS = 12
const BIG_SHARE = 0.22
const SMALL_ROWS = 7
const SMALL_SHARE = 0.13
const MODE_WORDS = {
  requesting: 'Awaiting the word',
  thinking: 'Pondering the letters',
  responding: 'Speaking',
  'tool-input': 'Shaping the clay',
  'tool-use': 'Working the clay',
} as const
const BEAT_TICKS = 3
const WRITERS = ['try', 'try_batch', 'write_doc', 'rename', 'move', 'move_file', 'delete']

const running = atom({ plugin: 'emetgate-marks', key: 'running' } as const, null)
const done = atom({ plugin: 'emetgate-marks', key: 'done' } as const, [])
const frame = atom({ plugin: 'emetgate-marks', key: 'frame' } as const, 0)
const verdict = atom({ plugin: 'emetgate-marks', key: 'verdict' } as const, null)
const isHidden = atom({ plugin: 'emetgate-marks', key: 'isHidden' } as const, true)
const isSilent = atom({ plugin: 'emetgate-marks', key: 'isSilent' } as const, false)
const beat = atom({ plugin: 'emetgate-marks', key: 'beat' } as const, 0)
const verdicts = atom({ plugin: 'emetgate-marks', key: 'verdicts' } as const, {})
const activities = atom({ plugin: 'emetgate-marks', key: 'activities' } as const, {})
const KEPT_ACTIVITIES = 400
const KEPT_TURNS = 200
const TONES: Readonly<Record<string, string>> = { read: 'cyan', edit: 'yellow', search: 'magenta', run: 'green', quiet: 'gray', refused: 'red' }
const GLYPHS: Readonly<Record<string, string>> = { read: '◇', edit: '◆', search: '⌕', run: '›', quiet: '·', refused: '✕' }

const tail = (path: string): string =>
  path.split('\\').join('/').split('/').slice(-2).join('/')

const targetOf = (args: Record<string, unknown>): string => {
  const pick = (key: string): string =>
    typeof args[key] === 'string' ? (args[key] as string) : ''
  const file = pick('file')

  if (file !== '') {
    const symbol = pick('symbol')

    return symbol === '' ? tail(file) : `${tail(file)}#${symbol}`
  }

  const text = pick('pattern') || pick('question') || pick('sub') || pick('dir')

  return text.length > 48 ? `${text.slice(0, 47)}…` : text
}

const noteOf = (text: string): string => {
  if (!text.startsWith('{')) {
    return ''
  }

  try {
    const body = JSON.parse(text) as Record<string, unknown>
    const parts = ['status', 'reason', 'error', 'commit']
      .map(key => body[key])
      .filter((value): value is string => typeof value === 'string')
      .map(value => (value.length === 40 ? value.slice(0, 7) : value))

    return parts.join(' ')
  } catch {
    return ''
  }
}

type Row = { tool_use_id?: string; isRunning: boolean; isErrored: boolean; isInterrupted: boolean; output?: unknown }

const recorded = (known: Readonly<Record<string, boolean>>, row: Row): boolean | undefined =>
  row.tool_use_id === undefined ? undefined : known[row.tool_use_id]

const isDecided = (known: Readonly<Record<string, boolean>>, row: Row): boolean =>
  recorded(known, row) !== undefined || (!row.isRunning && (row.output !== undefined || row.isErrored || row.isInterrupted))

const passedOf = (known: Readonly<Record<string, boolean>>, row: Row): boolean =>
  recorded(known, row) ?? (!row.isErrored && !row.isInterrupted)

const argsOf = (e: unknown): Record<string, unknown> => {
  const event = (e ?? {}) as Record<string, unknown>
  const input = event.input ?? event.args ?? event.arguments
  return input !== null && typeof input === 'object' ? (input as Record<string, unknown>) : event
}

const keepLast = <V,>(map: Map<string, V>, key: string, value: V): void => {
  map.delete(key)
  map.set(key, value)
  for (const old of map.keys()) {
    if (map.size <= KEPT_TURNS) break
    map.delete(old)
  }
}

const remember = async ($: any, e: any, ran: any): Promise<void> => {
  try {
    const id = String(e?.tool_use_id ?? '')
    if (id === '') return
    const isOk = ran?.deny === undefined && ran?.isError !== true
    const blocks = Array.isArray(ran?.content) ? ran.content : Array.isArray(ran?.output) ? ran.output : []
    const joined = blocks.map((block: any) => (typeof block === 'string' ? block : typeof block?.text === 'string' ? block.text : '')).join('\n')
    const text = typeof ran?.text === 'string' && ran.text !== '' ? ran.text : joined !== '' ? joined : typeof ran?.output === 'string' ? ran.output : ran?.deny !== undefined ? String(ran.deny) : ''
    const entry = observe(String(e.tool), argsOf(e), text, isOk)
    note(String(e.tool), argsOf(e), entry)
    await update($, activities, known => {
      const next: Record<string, unknown> = { ...known, [id]: entry }
      const keys = Object.keys(next)
      for (const key of keys.slice(0, Math.max(0, keys.length - KEPT_ACTIVITIES))) delete next[key]
      return next
    })
  } catch {
    return
  }
}

const SHADES: Readonly<Record<string, { ch: string; color?: string; dim: boolean }>> = {
  none: { ch: '─', dim: true },
  seen: { ch: '━', color: 'gray', dim: false },
  now: { ch: '━', color: 'cyan', dim: false },
  edit: { ch: '●', color: 'yellow', dim: false },
  hit: { ch: '┃', color: 'magenta', dim: false },
  head: { ch: '╸', color: 'cyanBright', dim: false },
}

const cellsView = (ui: any, strip: Strip, key: string) => {
  const { Text } = ui
  if (strip.total <= 0) return null
  const runs: { tone: string; text: string }[] = []
  for (const cell of cellsOf(strip)) {
    const ch = SHADES[cell.tone].ch
    const last = runs[runs.length - 1]
    if (last !== undefined && last.tone === cell.tone) last.text += ch
    else runs.push({ tone: cell.tone, text: ch })
  }
  return (
    <Text key={key}>
      {runs.map((run, index) => (
        <Text key={`${key}-${index}`} color={SHADES[run.tone].color} dimColor={SHADES[run.tone].dim}>
          {run.text}
        </Text>
      ))}
    </Text>
  )
}

const flagView = (ui: any, flag: Strip['flag']) => {
  const { Text } = ui
  if (flag === 'seen') return <Text color="green">{'  read first'}</Text>
  if (flag === 'unread') return <Text color="yellow">{'  edited without reading'}</Text>
  return null
}

const activityView = (ui: any, entry: Observed, key: string, pad: number) => {
  const { Box, Text } = ui
  const strips = entry.strips ?? []
  const inline = strips.length === 1 && entry.tone !== 'search' ? strips[0] : undefined
  const rows = entry.tone === 'search' ? strips : []
  const rowPad = Math.max(0, ...rows.map(s => s.label.length))
  const diff = entry.tone === 'edit' ? entry.excerpt.slice(0, 3) : []
  const hidden = entry.tone === 'edit' ? entry.excerpt.length - diff.length + entry.more : 0
  const label = `${entry.dir}${entry.name}`
  const span = inline !== undefined && inline.total > 0 && entry.span === 'whole file' ? '' : entry.span
  return (
    <Box key={key} flexDirection="column" paddingLeft={2}>
      <Text wrap="truncate-end">
        <Text color={entry.tone === 'refused' ? 'red' : undefined} dimColor={entry.tone !== 'refused'}>
          {`${GLYPHS[entry.tone]} `}
        </Text>
        {entry.dir === '' ? null : <Text dimColor>{entry.dir}</Text>}
        <Text>{entry.name}</Text>
        <Text>{' '.repeat(Math.max(1, pad - label.length + 2))}</Text>
        {inline === undefined ? null : cellsView(ui, inline, `${key}-i`)}
        {span === '' ? null : <Text dimColor>{`  ${span}`}</Text>}
        {entry.note === '' ? null : (
          <Text color={entry.tone === 'refused' ? 'red' : undefined} dimColor={entry.tone !== 'refused'}>
            {`  ${entry.note}`}
          </Text>
        )}
        {inline === undefined ? null : flagView(ui, inline.flag)}
      </Text>
      {rows.map((strip, index) => (
        <Text key={`${key}-r${index}`} wrap="truncate-end">
          <Text dimColor>{`    ${strip.label.padEnd(rowPad)}  `}</Text>
          {cellsView(ui, strip, `${key}-r${index}c`)}
          <Text dimColor>{`  ${strip.hits.join(', ')}`}</Text>
        </Text>
      ))}
      {diff.map((row, index) => (
        <Text key={`${key}-${index}`} wrap="truncate-end">
          <Text dimColor>{'    '}</Text>
          <Text color={row.sign === '+' ? 'green' : row.sign === '−' ? 'red' : undefined} dimColor>
            {`${row.sign === '' ? ' ' : row.sign} ${row.text}`}
          </Text>
        </Text>
      ))}
      {hidden > 0 ? <Text dimColor>{`    ⋯ ${hidden} more`}</Text> : null}
    </Box>
  )
}

const receiptView = (ui: any, card: Receipt) => {
  const { Box, Text } = ui
  const pad = Math.max(0, ...card.rows.map(row => row.dir.length + row.name.length))
  const parts = [`${card.files} file${card.files === 1 ? '' : 's'}`, `${card.lines} lines read`, `${card.edits} edit${card.edits === 1 ? '' : 's'}`]
  return (
    <Box flexDirection="column" marginTop={1} paddingLeft={2}>
      <Text dimColor>{`This turn · ${parts.join(' · ')}`}</Text>
      {card.rows.map((row, index) => (
        <Text key={`r${index}`} wrap="truncate-end">
          <Text dimColor>{row.dir}</Text>
          <Text>{row.name}</Text>
          <Text>{' '.repeat(pad - row.dir.length - row.name.length + 2)}</Text>
          {row.strip === undefined || row.strip.total <= 0 ? <Text dimColor>{'─'.repeat(CELLS)}</Text> : cellsView(ui, row.strip, `c${index}`)}
          <Text dimColor>{row.strip === undefined || row.strip.total <= 0 ? '      ' : `  ${String(row.strip.percent).padStart(3)}%`}</Text>
          {flagView(ui, row.flag)}
        </Text>
      ))}
      {card.blind > 0 ? <Text color="yellow">{`${card.blind} file${card.blind === 1 ? '' : 's'} edited without reading the changed part first`}</Text> : null}
    </Box>
  )
}

const DIFF_ADD_BG = '#1f4d2a'
const DIFF_DEL_BG = '#5c2330'

const groupSummary = (entries: readonly Observed[]): string => {
  const reads = new Set<string>()
  const edits = new Set<string>()
  let searches = 0
  let commands = 0
  let other = 0
  for (const entry of entries) {
    const title = entry.native?.title ?? ''
    const file = `${entry.dir}${entry.name}`
    if (title === 'Read' || title === 'Outline' || title === 'Symbols') reads.add(file)
    else if (title === 'Search' || title === 'Scan') searches += 1
    else if (title === 'Update' || title === 'Write' || title === 'Rename' || title === 'Move' || title === 'Delete') edits.add(file)
    else if (title === 'Bash') commands += 1
    else other += 1
  }
  const n = (count: number, word: string) => `${count} ${word}${count === 1 ? '' : 's'}`
  const parts = [
    reads.size > 0 ? `read ${n(reads.size, 'file')}` : '',
    searches > 0 ? `searched for ${n(searches, 'pattern')}` : '',
    edits.size > 0 ? `edited ${n(edits.size, 'file')}` : '',
    commands > 0 ? `ran ${n(commands, 'command')}` : '',
    other > 0 ? n(other, 'other call') : '',
  ].filter(part => part !== '')
  const text = parts.join(', ')
  return text === '' ? 'Done' : `${text[0].toUpperCase()}${text.slice(1)}`
}

const nativeView = (ui: any, entry: Observed, key: string) => {
  const { Box, Text } = ui
  const native = entry.native as NonNullable<Observed['native']>
  const strips = entry.strips ?? []
  const inline = strips.length === 1 && entry.tone !== 'search' ? strips[0] : undefined
  const width = Math.max(1, ...native.diff.map(row => String(row.n ?? '').length))
  const isOk = entry.tone !== 'refused'
  return (
    <Box key={key} flexDirection="column">
      <Text wrap="truncate-end">
        <Text color={isOk ? 'green' : 'red'}>{'● '}</Text>
        <Text bold>{native.title}</Text>
        {native.arg === '' ? null : <Text>{`(${native.arg})`}</Text>}
      </Text>
      <Text wrap="truncate-end">
        <Text dimColor>{'  ⎿  '}</Text>
        <Text color={isOk ? undefined : 'red'} dimColor={isOk}>
          {native.summary}
        </Text>
        {inline === undefined || inline.total <= 0 ? null : <Text>{'  '}</Text>}
        {inline === undefined ? null : cellsView(ui, inline, `${key}-i`)}
        {inline === undefined || inline.total <= 0 ? null : <Text dimColor>{`  ${inline.percent}% seen`}</Text>}
        {inline === undefined ? null : flagView(ui, inline.flag)}
      </Text>
      {native.body.map((line, index) => (
        <Text key={`${key}-b${index}`} wrap="truncate-end" dimColor>
          {`     ${line}`}
        </Text>
      ))}
      {native.bodyMore > 0 ? <Text dimColor>{`     … +${native.bodyMore} lines (ctrl+o to expand)`}</Text> : null}
      {native.diff.map((row, index) => (
        <Text key={`${key}-d${index}`} wrap="truncate-end">
          <Text dimColor>{`     ${String(row.n ?? '').padStart(width)} `}</Text>
          {row.sign === ' ' ? (
            <Text>{`  ${row.text}`}</Text>
          ) : (
            <Text backgroundColor={row.sign === '+' ? DIFF_ADD_BG : DIFF_DEL_BG} color="white">{`${row.sign === '+' ? '+' : '-'} ${row.text}`}</Text>
          )}
        </Text>
      ))}
      {native.diffMore > 0 ? <Text dimColor>{`     … +${native.diffMore} lines (ctrl+o to expand)`}</Text> : null}
      {strips.length > 1 || entry.tone === 'search'
        ? strips.map((strip, index) => (
            <Text key={`${key}-s${index}`} wrap="truncate-end">
              <Text dimColor>{`     ${strip.label}  `}</Text>
              {cellsView(ui, strip, `${key}-s${index}c`)}
              <Text dimColor>{strip.hits.length > 0 ? `  ${strip.hits.join(', ')}` : ''}</Text>
              {flagView(ui, strip.flag)}
            </Text>
          ))
        : null}
    </Box>
  )
}

const withScan = (ui: any, strip: Strip | undefined, scan: Scan | undefined, inner: any) => {
  if (strip === undefined || scan === undefined) return inner
  return (
    <ui.Box flexDirection="column">
      <ui.Text wrap="truncate-end">
        <ui.Text dimColor>{'◇ '}</ui.Text>
        <ui.Text>{strip.label}</ui.Text>
        <ui.Text>{'  '}</ui.Text>
        {cellsView(ui, strip, 'scan')}
        <ui.Text dimColor>{`  ${scan.from}–${strip.head ?? scan.to}`}</ui.Text>
      </ui.Text>
      {inner ?? null}
    </ui.Box>
  )
}

export const register: Register = on => {
  let isOff = true
  let isBig = true
  let isQuiet = false
  let isTurn = false
  let isRunning = false
  let verdictTicks = -1
  let verdictLimit = OK_TICKS
  let passed = 0
  let refused = 0
  let anchor = 0
  let turnPassed = 0
  let turnRefused = 0
  let ticks = 0
  const tallies = new Map<string, { passed: number; refused: number }>()
  const receipts = new Map<string, Receipt | null>()
  let scanning: Scan | undefined

  on('session.start', async ($, e, next) => {
    try {
      await $.command.register({
        name: COMMAND,
        description: 'emetgate marks in the transcript: on, off, or scene for the large view while Claude works',
      })
      isOff = (await $.store.get(STORE_KEY)) !== true
      isBig = (await $.store.get(SIZE_KEY)) !== false
      isQuiet = (await $.store.get(QUIET_KEY)) === true
      await update($, isHidden, () => isOff)
      await update($, isSilent, () => isQuiet)
    } catch {
      isOff = true
    }

    $.clock.every(TICK_MS, async () => {
      if (!(isTurn || isRunning || verdictTicks >= 0)) {
        return
      }

      try {
        ticks += 1

        if (!isOff) {
          await update($, frame, n => n + 1)
        } else if (!isQuiet && ticks % BEAT_TICKS === 0) {
          await update($, beat, n => n + 1)
        }

        if (verdictTicks < 0) {
          return
        }

        verdictTicks += 1

        if (verdictTicks > verdictLimit) {
          verdictTicks = -1
          anchor = await read($, frame)
          await update($, verdict, () => null)
        }
      } catch {
        verdictTicks = -1
      }
    })

    return next(e)
  })

  on('command.run', { command: COMMAND }, async ($, e) => {
    const word = e.args.trim().toLowerCase()

    if (word === 'scene' || word === 'big' || word === 'small') {
      isBig = word !== 'small'
      isOff = false
      isQuiet = false
      await $.store.set(SIZE_KEY, isBig)
    } else {
      isOff = true
      isQuiet = word === 'off'
    }

    await $.store.set(STORE_KEY, !isOff)
    await $.store.set(QUIET_KEY, isQuiet)
    await update($, frame, n => n + 1)
    await update($, isHidden, () => isOff)
    await update($, isSilent, () => isQuiet)

    return { text: isQuiet ? 'golem off' : isOff ? 'golem on' : isBig ? 'golem scene big' : 'golem scene small' }
  })

  on('prompt.submit', async ($, e, next) => {
    beginTurn()
    isTurn = true
    turnPassed = 0
    turnRefused = 0

    try {
      anchor = await read($, frame)
    } catch {
      anchor = 0
    }

    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    isTurn = false

    try {
      await update($, frame, n => n + 1)
    } catch {
      isTurn = false
    }

    return next(e)
  })

  on('tool.call', async ($, e, next) => {
    const name = String(e.tool)
    const at = name.lastIndexOf(MARK)

    if (at < 0) {
      return next(e)
    }

    try {
      scanning = scanOf(name, argsOf(e), await $.clock.now())
    } catch {
      scanning = undefined
    }

    if (isQuiet) {
      let quiet
      try {
        quiet = await next(e)
      } finally {
        scanning = undefined
      }
      await remember($, e, quiet)
      return quiet
    }

    const verb = name.slice(at + MARK.length)
    const target = targetOf(e as unknown as Record<string, unknown>)
    let entered = 0
    let before = 0

    try {
      entered = await $.clock.now()
      const startFrame = await read($, frame)
      const now: Running = { verb, target, startedAt: entered, startFrame }
      verdictTicks = -1
      await update($, verdict, () => null)
      await update($, running, () => now)
      isRunning = true
      before = await $.clock.now()
    } catch {
      before = 0
    }

    let ran
    try {
      ran = await next(e)
    } finally {
      scanning = undefined
    }
    await remember($, e, ran)

    try {
      const after = await $.clock.now()
      const isOk = ran.deny === undefined && ran.isError !== true
      isRunning = false
      anchor = await read($, frame)
      await update($, running, () => null)

      if (WRITERS.includes(verb)) {
        const startFrame = await read($, frame)
        passed += isOk ? 1 : 0
        refused += isOk ? 0 : 1
        turnPassed += isOk ? 1 : 0
        turnRefused += isOk ? 0 : 1
        await update($, verdict, () => ({ isOk, startFrame }))
        await update($, verdicts, known => ({ ...known, [e.tool_use_id]: isOk }))
        verdictLimit = isOk ? OK_TICKS : BAD_TICKS
        verdictTicks = 0
      }

      const left = await $.clock.now()
      const entry: Done = {
        verb,
        target,
        ms: Math.round(after - before),
        overheadMs: Math.round(before - entered + (left - after)),
        isOk,
        note: ran.deny === undefined ? noteOf(ran.text ?? '') : 'denied',
      }
      await update($, done, list => [entry, ...list].slice(0, KEPT))
    } catch {
      isRunning = false
    }

    return ran
  })

  on('ui.render', { component: 'Spinner' }, async ($, e, next) => {
    let base: any
    let isCalled = false
    try {
      const scan = scanning
      let strip: Strip | undefined
      if (scan !== undefined && e.surface === 'terminal') {
        try {
          strip = scanStrip(scan, await $.clock.now())
        } catch {
          strip = undefined
        }
      }
      const ui = $.ui.resolve(e)
      if (await read($, isSilent)) {
        isCalled = true
        base = await next(e)
        return withScan(ui, strip, scan, base)
      }

      const now = await read($, running)
      const seen = await read($, verdict)
      const word =
        now !== null
          ? WRITERS.includes(now.verb)
            ? 'Weighing at the gate'
            : 'Reading the clay'
          : seen !== null
            ? seen.isOk
              ? 'Sealed'
              : 'Turned away'
            : null
      const modeWord = MODE_WORDS[e.props.mode] ?? null

      isCalled = true
      base = await next(
        word === null
          ? modeWord === null
            ? e
            : { ...e, props: { ...e.props, word: modeWord, message: null } }
          : { ...e, props: { ...e.props, word, message: null } },
      )

      if (e.surface !== 'terminal') {
        return withScan(ui, strip, scan, base)
      }

      if (await read($, isHidden)) {
        const pulse = await read($, beat)
        const { Box, Raster } = $.ui.resolve(e)
        const cells =
          now !== null
            ? writingWord(WRITERS.includes(now.verb) ? 'weigh' : 'read', pulse)
            : seen !== null
              ? verdictWord(seen.isOk)
              : writingWord('write', pulse)

        return withScan(ui, strip, scan, (
          <Box flexDirection="row" gap={1}>
            <Box marginTop={1}>
              <Raster key="letters" columns={WORD_COLUMNS} rows={WORD_ROWS} cells={cells} />
            </Box>
            {base ?? null}
          </Box>
        ))
      }

      const tick = await read($, frame)
      const kind: Kind = now !== null ? 'run' : seen !== null ? (seen.isOk ? 'ok' : 'bad') : 'think'
      const cols = Math.min(MAX_COLUMNS, (e.viewport?.columns ?? 80) - 4)
      const tall = e.viewport?.rows ?? 40
      const rows = Math.min(
        isBig ? BIG_ROWS : SMALL_ROWS,
        Math.max(MIN_ROWS, Math.round(tall * (isBig ? BIG_SHARE : SMALL_SHARE))),
      )

      if (cols < MIN_COLUMNS) {
        return withScan(ui, strip, scan, base)
      }

      const { Box, Raster, Text } = $.ui.resolve(e)
      const stride = now !== null ? now.startFrame - anchor : tick - anchor
      const phase =
        now !== null ? tick - now.startFrame : seen !== null ? tick - seen.startFrame : tick
      const cells = paint(
        cols,
        rows,
        kind,
        tick,
        phase,
        passed,
        stride,
        refused,
        now === null || WRITERS.includes(now.verb),
      )

      return withScan(ui, strip, scan, (
        <Box flexDirection="column">
          <Raster key="world" columns={cols} rows={rows} cells={cells} />
          <Box flexDirection="row" gap={2}>
            {now !== null ? (
              <Text color="magenta" bold wrap="truncate-end">
                {now.verb} {now.target}
              </Text>
            ) : kind === 'ok' || kind === 'bad' ? (
              <Raster key="verdict" columns={WORD_COLUMNS} rows={WORD_ROWS} cells={verdictWord(kind === 'ok')} />
            ) : null}
            <Text dimColor>
              {passed} passed {refused} refused
            </Text>
          </Box>
          {base ?? null}
        </Box>
      ))
    } catch {
      return isCalled ? base : next(e)
    }
  })

  on('ui.render', { component: 'TurnDuration' }, async ($, e, next) => {
    let base: any
    let isCalled = false
    try {
      if (await read($, isSilent)) {
        isCalled = true
        return await next(e)
      }

      if (!receipts.has(e.requestId)) {
        keepLast(receipts, e.requestId, receipt() ?? null)
      }
      const card = receipts.get(e.requestId) ?? null
      const known = tallies.get(e.requestId)
      const tally = known ?? { passed: turnPassed, refused: turnRefused }

      if (known === undefined) {
        keepLast(tallies, e.requestId, tally)
      }

      if (tally.passed + tally.refused === 0) {
        isCalled = true
        const spoke = await next({ ...e, props: { ...e.props, word: 'Spoke' } })
        base = spoke
        if (card === null) {
          return spoke
        }
        const ui = $.ui.resolve(e)
        return (
          <ui.Box flexDirection="column">
            {receiptView(ui, card)}
            {spoke ?? null}
          </ui.Box>
        )
      }

      const word = tally.refused === 0 ? 'Sealed' : tally.passed === 0 ? 'Turned away' : 'Weighed'
      isCalled = true
      base = await next({ ...e, props: { ...e.props, word } })
      const { Box, Text } = $.ui.resolve(e)

      return (
        <Box flexDirection="column">
          {card === null ? null : receiptView($.ui.resolve(e), card)}
          {base ?? null}
          <Text>
            {'  '}
            <Text color="green" bold>
              {tally.passed} passed
            </Text>
            {'  '}
            <Text color="red" bold={tally.refused > 0} dimColor={tally.refused === 0}>
              {tally.refused} refused
            </Text>
          </Text>
        </Box>
      )
    } catch {
      return isCalled ? base : next(e)
    }
  })

  on('ui.render', { component: 'ToolGroup' }, async ($, e, next) => {
    const base = await next(e)
    try {

      if (e.props.isExpanded) {
        return base
      }

      const seen = (await read($, activities)) as Readonly<Record<string, Observed>>
      const shown = e.props.calls
        .map(call => (call.tool_use_id === undefined ? undefined : seen[call.tool_use_id]))
        .filter((entry): entry is Observed => entry !== undefined)

      if (shown.length > 0) {
        const ui = $.ui.resolve(e)
        return (
          <ui.Box flexDirection="column">
            <ui.Text dimColor>{`${groupSummary(shown)} (ctrl+o to expand)`}</ui.Text>
            {shown.map((entry, index) => (entry.native === undefined ? activityView(ui, entry, `a${index}`, Math.max(...shown.map(item => item.dir.length + item.name.length))) : nativeView(ui, entry, `n${index}`)))}
          </ui.Box>
        )
      }

      if (await read($, isSilent)) {
        return base
      }

      const known = await read($, verdicts)
      const writes = e.props.calls.filter(call => {
        const name = String(call.tool)
        const at = name.lastIndexOf(MARK)

        return at >= 0 && WRITERS.includes(name.slice(at + MARK.length)) && isDecided(known, call)
      })

      if (writes.length === 0) {
        return base
      }

      const { Box, Text } = $.ui.resolve(e)
      const isTerminal = e.surface === 'terminal'

      return (
        <Box flexDirection="column">
          {base ?? null}
          {writes.map((call, index) => {
            const isOk = passedOf(known, call)
            const target = targetOf((call.input ?? {}) as Record<string, unknown>)
            if (!isTerminal) {
              return (
                <Text wrap="truncate-end">
                  <Text color={isOk ? 'green' : 'red'} bold>
                    {isOk ? 'emet' : 'met'}
                  </Text>
                  <Text dimColor> {target}</Text>
                </Text>
              )
            }

            const { Raster } = $.ui.resolve(e)

            return (
              <Box flexDirection="row" gap={1} paddingLeft={2}>
                <Raster key={`word${index}`} columns={WORD_COLUMNS} rows={WORD_ROWS} cells={verdictWord(isOk)} />
                <Text dimColor wrap="truncate-end">
                  {target}
                </Text>
              </Box>
            )
          })}
        </Box>
      )
    } catch {
      return base
    }
  })

  on('ui.render', { component: 'ToolUse' }, async ($, e, next) => {
    const base = await next(e)
    try {
      const name = String(e.props.tool)
      const at = name.lastIndexOf(MARK)
      const props = e.props as { tool_use_id?: string; isExpanded?: boolean }
      const seen = at >= 0 && props.tool_use_id !== undefined ? ((await read($, activities)) as Readonly<Record<string, Observed>>)[props.tool_use_id] : undefined

      if (seen !== undefined && props.isExpanded !== true) {
        const ui = $.ui.resolve(e)
        return (
          <ui.Box flexDirection="column">
            {seen.native === undefined ? base ?? null : null}
            {seen.native === undefined ? activityView(ui, seen, 'single', seen.dir.length + seen.name.length) : nativeView(ui, seen, 'single')}
          </ui.Box>
        )
      }

      if (at < 0 || !WRITERS.includes(name.slice(at + MARK.length)) || (await read($, isSilent))) {
        return base
      }

      const known = await read($, verdicts)

      if (!isDecided(known, e.props)) {
        return base
      }

      const { Box, Text } = $.ui.resolve(e)
      const isOk = passedOf(known, e.props)

      const words = (
        <Text color={isOk ? 'green' : 'red'} bold>
          {isOk ? 'emet' : 'met'}
        </Text>
      )

      if (e.surface !== 'terminal') {
        return (
          <Box flexDirection="column">
            {base ?? null}
            {words}
          </Box>
        )
      }

      const { Raster } = $.ui.resolve(e)

      return (
        <Box flexDirection="column">
          {base ?? null}
          <Box paddingLeft={2}>
            <Raster key="word" columns={WORD_COLUMNS} rows={WORD_ROWS} cells={verdictWord(isOk)} />
          </Box>
        </Box>
      )
    } catch {
      return base
    }
  })
}
