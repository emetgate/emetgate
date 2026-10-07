import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'

import type { Done, Running } from '../types'
import { BAD_TICKS, MIN_COLUMNS, MIN_ROWS, OK_TICKS, WORD_COLUMNS, WORD_ROWS, paint, verdictWord, writingWord } from './scene'
import type { Kind } from './scene'

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
const WRITERS = ['try', 'try_batch', 'write_doc', 'rename', 'move', 'move_file']

const running = atom({ plugin: 'emetgate-marks', key: 'running' } as const, null)
const done = atom({ plugin: 'emetgate-marks', key: 'done' } as const, [])
const frame = atom({ plugin: 'emetgate-marks', key: 'frame' } as const, 0)
const verdict = atom({ plugin: 'emetgate-marks', key: 'verdict' } as const, null)
const isHidden = atom({ plugin: 'emetgate-marks', key: 'isHidden' } as const, true)
const isSilent = atom({ plugin: 'emetgate-marks', key: 'isSilent' } as const, false)
const beat = atom({ plugin: 'emetgate-marks', key: 'beat' } as const, 0)

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

    if (at < 0 || isQuiet) {
      return next(e)
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

    const ran = await next(e)

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
    if (await read($, isSilent)) {
      return next(e)
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

    const base = await next(
      word === null
        ? modeWord === null
          ? e
          : { ...e, props: { ...e.props, word: modeWord, message: null } }
        : { ...e, props: { ...e.props, word, message: null } },
    )

    if (e.surface !== 'terminal') {
      return base
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

      return (
        <Box flexDirection="row" gap={1}>
          <Box marginTop={1}>
            <Raster key="letters" columns={WORD_COLUMNS} rows={WORD_ROWS} cells={cells} />
          </Box>
          {base ?? null}
        </Box>
      )
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
      return base
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

    return (
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
    )
  })

  on('ui.render', { component: 'TurnDuration' }, async ($, e, next) => {
    if (await read($, isSilent)) {
      return next(e)
    }

    const known = tallies.get(e.requestId)
    const tally = known ?? { passed: turnPassed, refused: turnRefused }

    if (known === undefined) {
      tallies.set(e.requestId, tally)
    }

    if (tally.passed + tally.refused === 0) {
      return next({ ...e, props: { ...e.props, word: 'Spoke' } })
    }

    const word = tally.refused === 0 ? 'Sealed' : tally.passed === 0 ? 'Turned away' : 'Weighed'
    const base = await next({ ...e, props: { ...e.props, word } })
    const { Box, Text } = $.ui.resolve(e)

    return (
      <Box flexDirection="column">
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
  })

  on('ui.render', { component: 'ToolGroup' }, async ($, e, next) => {
    const base = await next(e)

    if (e.props.isExpanded || (await read($, isSilent))) {
      return base
    }

    const writes = e.props.calls.filter(call => {
      const name = String(call.tool)
      const at = name.lastIndexOf(MARK)

      return at >= 0 && !call.isRunning && WRITERS.includes(name.slice(at + MARK.length))
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
          const isOk = !call.isErrored && !call.isInterrupted
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
  })

  on('ui.render', { component: 'ToolUse' }, async ($, e, next) => {
    const base = await next(e)
    const name = String(e.props.tool)
    const at = name.lastIndexOf(MARK)

    if (at < 0 || e.props.isRunning || !WRITERS.includes(name.slice(at + MARK.length)) || (await read($, isSilent))) {
      return base
    }

    const { Box, Text } = $.ui.resolve(e)
    const isOk = !e.props.isErrored && !e.props.isInterrupted

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
  })
}
