export type Kind = 'rest' | 'think' | 'run' | 'ok' | 'bad'

export const OK_TICKS = 44
export const BAD_TICKS = 44
export const RETURN_TICKS = 8
export const MIN_COLUMNS = 18
export const MIN_ROWS = 5
const FULL_ROWS = 9
export const SLEEP_AFTER = 260

const ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
const SKY = 0x010203
const STEP = 17
const DEFAULT_COLOR = 0x01000000

const OUTLINE = 0x303030
const STONE_DARK = 0x585858
const STONE = 0x8a8a8a
const STONE_LIGHT = 0xbcbcbc
const BRICK = 0x5f5f5f
const BRICK_LIGHT = 0x767676
const MORTAR = 0x3a3a3a
const RIM = 0x9e9e9e
const GROUND = 0x262626
const PATH = 0x444444
const PEBBLE = 0x626262
const MOON = 0xe4e4e4
const MOON_SHADE = 0xb2b2b2
const STAR = 0xeeeeee
const STAR_DIM = 0x808080
const HILL = 0x0c0c2c
const WOOD = 0x875f00
const FLAME = 0xffd700
const EMBER = 0xff8700
const PINE = 0x005f00
const GRASS = 0x008700
const CLOUD = 0x3a3a3a
const CLOUD_LIGHT = 0x4e4e4e
const SMOKE = 0x585858
const FIREFLY = 0xd7ff00
const MOUNT = 0x333355
const SNOW = 0xaaaacc
const WATER = 0x001144
const RIPPLE = 0x224488
const GLINT = 0xddddee
const GLINT_DIM = 0x8899bb
const BOLT = 0xffaaaa
const WHITE = 0xffffff
const BLACK = 0x000000

type Tone = { bright: number; mid: number; dark: number }

const MAGENTA: Tone = { bright: 0xffafff, mid: 0xd700d7, dark: 0x5f0087 }
const GREEN: Tone = { bright: 0xafffd7, mid: 0x00d787, dark: 0x005f5f }
const RED: Tone = { bright: 0xffafaf, mid: 0xd70000, dark: 0x5f0000 }
const VEIL: Tone = { bright: 0x7744bb, mid: 0x442288, dark: 0x221155 }
const CYAN: Tone = { bright: 0xafffff, mid: 0x00d7ff, dark: 0x005f87 }

const HEAD = [
  '....ooooooo....',
  '...ohhhhhgdo...',
  '...oeegeegdo...',
  '...ohgggggdo...',
  '...odgggggdo...',
  '..ooooooooooo..',
]

const BODY = [
  'ohgohhhhhgdogdo',
  'ohgohgrrrgdogdo',
  'ohgohgrrrgdogdo',
  'ohgohggggddogdo',
  'odgodgggdddogdo',
  'odgooooooooogdo',
  'ooo.ohgodgo.ooo',
  '....ohgodgo....',
  '....ohgodgo....',
  '...oohgodgoo...',
  '...ooooooooo...',
]

const SMALL = [
  '.ooooo.',
  'ohhhgdo',
  'ohegedo',
  '.ooooo.',
  'ohhrgdo',
  'ohgrgdo',
  '.oh.do.',
  '.oo.oo.',
]

const MIDDLE = [
  '..ooooo..',
  '.ohhhgdo.',
  '.oeegeeo.',
  '.ohgggdo.',
  'ooooooooo',
  'ohohrgodo',
  'ohohrgodo',
  'odohggodo',
  '..ohodo..',
  '..ohodo..',
  '..ooooo..',
]

const isFill = (letter: string): boolean => letter !== '.' && letter !== 'o'

const refine = (line: string): string => {
  const parts: string[] = []

  for (let col = 0; col < line.length; col += 1) {
    const letter = line[col] ?? '.'
    const before = line[col - 1] ?? '.'
    const after = line[col + 1] ?? '.'

    if (letter !== 'o') {
      parts.push(letter, letter)
    } else if (isFill(before) && isFill(after)) {
      parts.push('o', after)
    } else if (isFill(after)) {
      parts.push('o', after)
    } else if (isFill(before)) {
      parts.push(before, 'o')
    } else {
      parts.push('o', 'o')
    }
  }

  return parts.join('').split('eeee').join('Eeee')
}

const HEAD_FINE = HEAD.map(refine)
const BODY_FINE = BODY.map(refine)
const SMALL_FINE = SMALL.map(refine)
const MIDDLE_FINE = MIDDLE.map(refine)

const clamp = (value: number): number => Math.max(0, Math.min(1, value))

const hash = (a: number, b: number): number => {
  const v = Math.sin(a * 12.9898 + b * 78.233) * 43758.5453

  return v - Math.floor(v)
}

const toBase64 = (bytes: Uint8Array): string => {
  const parts: string[] = []

  for (let i = 0; i < bytes.length; i += 3) {
    const a = bytes[i] ?? 0
    const b = bytes[i + 1] ?? 0
    const c = bytes[i + 2] ?? 0
    const left = bytes.length - i
    parts.push(
      (ALPHABET[a >> 2] ?? '') +
        (ALPHABET[((a & 3) << 4) | (b >> 4)] ?? '') +
        (left > 1 ? (ALPHABET[((b & 15) << 2) | (c >> 6)] ?? '') : '=') +
        (left > 2 ? (ALPHABET[c & 63] ?? '') : '='),
    )
  }

  return parts.join('')
}

const snap = (color: number): number => {
  const part = (shift: number): number => Math.round(((color >> shift) & 255) / STEP) * STEP

  return (part(16) << 16) | (part(8) << 8) | part(0)
}

type Shape = { glyph: number; bits: number }
type Mark = { cx: number; cy: number; glyph: number; color: number }

const shapeOf = (glyph: number, isFore: (sx: number, sy: number) => boolean): Shape => {
  let bits = 0

  for (let sy = 0; sy < 4; sy += 1) {
    for (let sx = 0; sx < 4; sx += 1) {
      if (isFore(sx, sy)) {
        bits |= 1 << (sy * 4 + sx)
      }
    }
  }

  return { glyph, bits }
}

const SHAPES: readonly Shape[] = [
  shapeOf(0x2580, (sx, sy) => sy < 2),
  shapeOf(0x258c, sx => sx < 2),
  shapeOf(0x2582, (sx, sy) => sy >= 3),
  shapeOf(0x2586, (sx, sy) => sy >= 1),
  shapeOf(0x258e, sx => sx < 1),
  shapeOf(0x258a, sx => sx < 3),
  shapeOf(0x2598, (sx, sy) => sx < 2 && sy < 2),
  shapeOf(0x259d, (sx, sy) => sx >= 2 && sy < 2),
  shapeOf(0x2596, (sx, sy) => sx < 2 && sy >= 2),
  shapeOf(0x2597, (sx, sy) => sx >= 2 && sy >= 2),
  shapeOf(0x259e, (sx, sy) => sx >= 2 !== sy >= 2),
]

const fit = (px: Int32Array, cols: number, rows: number): Uint32Array => {
  const sw = cols * 4
  const words = new Uint32Array(cols * rows * 3)
  const cell = new Int32Array(16)

  for (let cy = 0; cy < rows; cy += 1) {
    for (let cx = 0; cx < cols; cx += 1) {
      let isFlat = true

      for (let i = 0; i < 16; i += 1) {
        cell[i] = px[(cy * 4 + (i >> 2)) * sw + cx * 4 + (i & 3)] ?? SKY
        isFlat = isFlat && cell[i] === cell[0]
      }

      const at = (cy * cols + cx) * 3

      if (isFlat) {
        words[at] = 0x20
        words[at + 1] = snap(cell[0] ?? SKY)
        words[at + 2] = snap(cell[0] ?? SKY)
        continue
      }

      let best = Infinity
      let glyph = 0x20
      let fore = 0
      let back = 0

      for (const shape of SHAPES) {
        const sum = [0, 0, 0, 0, 0, 0]
        let fn = 0

        for (let i = 0; i < 16; i += 1) {
          const color = cell[i] ?? 0
          const to = (shape.bits >> i) & 1 ? 0 : 3
          fn += (shape.bits >> i) & 1
          sum[to] = (sum[to] ?? 0) + ((color >> 16) & 255)
          sum[to + 1] = (sum[to + 1] ?? 0) + ((color >> 8) & 255)
          sum[to + 2] = (sum[to + 2] ?? 0) + (color & 255)
        }

        const mean = sum.map((value, index) => value / (index < 3 ? fn : 16 - fn))
        let err = 0

        for (let i = 0; i < 16 && err < best; i += 1) {
          const color = cell[i] ?? 0
          const to = (shape.bits >> i) & 1 ? 0 : 3
          const dr = ((color >> 16) & 255) - (mean[to] ?? 0)
          const dg = ((color >> 8) & 255) - (mean[to + 1] ?? 0)
          const db = (color & 255) - (mean[to + 2] ?? 0)
          err += dr * dr + dg * dg + db * db
        }

        if (err < best) {
          const pack = (from: number): number =>
            (Math.round(mean[from] ?? 0) << 16) |
            (Math.round(mean[from + 1] ?? 0) << 8) |
            Math.round(mean[from + 2] ?? 0)
          best = err
          glyph = shape.glyph
          fore = pack(0)
          back = pack(3)
        }
      }

      words[at] = glyph
      words[at + 1] = snap(fore)
      words[at + 2] = snap(back)
    }
  }

  return words
}

export const WORD_COLUMNS = 3
export const WORD_ROWS = 1

const ALEF = 0x5d0
const MEM = 0x5de
const TAV = 0x5ea
const PASSED = 0x00dd88
const REFUSED = 0xdd0000
const ERASED = 0x333333

const CLAY = 0xddbb88
const GATE = [0xffcc33, 0xffdd55] as const
const WRITING = [1, 1, 2, 2, 3, 3, 3, 3] as const

export type Hand = 'write' | 'read' | 'weigh'

export const writingWord = (hand: Hand, beat: number): string => {
  const shown = hand === 'write' ? (WRITING[beat % WRITING.length] ?? 3) : 3
  const ink = hand === 'weigh' ? (GATE[beat % GATE.length] ?? CLAY) : CLAY
  const words = Uint32Array.of(
    ALEF, shown >= 1 ? ink : ERASED, DEFAULT_COLOR,
    MEM, shown >= 2 ? ink : ERASED, DEFAULT_COLOR,
    TAV, shown >= 3 ? ink : ERASED, DEFAULT_COLOR,
  )

  return toBase64(new Uint8Array(words.buffer))
}

export const verdictWord = (isOk: boolean): string => {
  const ink = isOk ? PASSED : REFUSED
  const words = Uint32Array.of(
    ALEF, isOk ? ink : ERASED, DEFAULT_COLOR,
    MEM, ink, DEFAULT_COLOR,
    TAV, ink, DEFAULT_COLOR,
  )

  return toBase64(new Uint8Array(words.buffer))
}

type Source = { x: number; y: number; spread: number; power: number; tint: number[] }

const level = (value: number): number => Math.round(clamp(value) * 5) / 5

const parts = (color: number): number[] => [(color >> 16) & 255, (color >> 8) & 255, color & 255]

const light = (
  px: Int32Array,
  cols: number,
  rows: number,
  sources: readonly Source[],
  horizon: number,
  moonX: number,
  moonY: number,
  haloSpread: number,
  flash: number,
): void => {
  const sw = cols * 4
  const sh = rows * 4
  const glow = new Float32Array(cols * rows * 4)

  for (let cy = 0; cy < rows; cy += 1) {
    for (let cx = 0; cx < cols; cx += 1) {
      const x = cx + 0.5
      const y = cy * 2 + 1
      const at = (cy * cols + cx) * 4

      for (const source of sources) {
        const d = (x - source.x) * (x - source.x) + (y - source.y) * (y - source.y)

        if (d > source.spread * 3) {
          continue
        }

        const gain = level(source.power * Math.exp(-d / source.spread))
        glow[at] = (glow[at] ?? 0) + gain * (source.tint[0] ?? 0)
        glow[at + 1] = (glow[at + 1] ?? 0) + gain * (source.tint[1] ?? 0)
        glow[at + 2] = (glow[at + 2] ?? 0) + gain * (source.tint[2] ?? 0)
      }

      glow[at + 3] = Math.round(8 * Math.exp(-((x - moonX) * (x - moonX) + (y - moonY) * (y - moonY)) / haloSpread)) / 8
    }
  }

  for (let sy = 0; sy < sh; sy += 1) {
    const band = clamp((((sy >> 2) << 2) + 2) / (horizon * 2))

    for (let sx = 0; sx < sw; sx += 1) {
      const at = sy * sw + sx
      const cell = ((sy >> 2) * cols + (sx >> 2)) * 4
      const color = px[at] ?? SKY

      if (color === SKY) {
        const halo = glow[cell + 3] ?? 0
        const r = flash + 60 * band * band * band + 10 * halo
        const g = flash + 26 * band * band + 26 * halo
        const b = flash + 112 * Math.sqrt(band) * band + 60 * halo
        px[at] = (Math.round(r) << 16) | (Math.round(g) << 8) | Math.round(b)
        continue
      }

      const lr = glow[cell] ?? 0
      const lg = glow[cell + 1] ?? 0
      const lb = glow[cell + 2] ?? 0

      if (lr + lg + lb === 0) {
        continue
      }

      const r = (color >> 16) & 255
      const g = (color >> 8) & 255
      const b = color & 255
      px[at] =
        (Math.min(255, Math.round(r + (r * 0.9 + 18) * lr)) << 16) |
        (Math.min(255, Math.round(g + (g * 0.9 + 18) * lg)) << 8) |
        Math.min(255, Math.round(b + (b * 0.9 + 18) * lb))
    }
  }
}

const finish = (px: Int32Array, cols: number, rows: number, marks: readonly Mark[]): string => {
  const words = fit(px, cols, rows)

  for (let at = 0; at < words.length; at += 3) {
    if (words[at + 2] === 0) {
      words[at + 2] = DEFAULT_COLOR
    }

    if (words[at] === 0x20) {
      words[at + 1] = DEFAULT_COLOR
    }
  }

  for (const mark of marks) {
    const at = (mark.cy * cols + mark.cx) * 3

    if (mark.cx >= 0 && mark.cy >= 0 && mark.cx < cols && mark.cy < rows && words[at] === 0x20) {
      words[at] = mark.glyph
      words[at + 1] = mark.color
    }
  }

  return toBase64(new Uint8Array(words.buffer))
}

const paintSmall = (
  cols: number,
  rows: number,
  kind: Kind,
  tick: number,
  phase: number,
  passed: number,
  stride: number,
  isWrite: boolean,
): string => {
  const w = cols
  const h = rows * 2
  const sw = cols * 4
  const sh = rows * 4
  const px = new Int32Array(sw * sh).fill(SKY)
  const marks: Mark[] = []
  const sub = (sx: number, sy: number, color: number): void => {
    if (sx >= 0 && sy >= 0 && sx < sw && sy < sh) {
      px[sy * sw + sx] = color
    }
  }
  const dot = (fx: number, y: number, color: number): void => {
    sub(fx * 2, y * 2, color)
    sub(fx * 2 + 1, y * 2, color)
    sub(fx * 2, y * 2 + 1, color)
    sub(fx * 2 + 1, y * 2 + 1, color)
  }
  const horizon = h - 2
  const isRoomy = h >= 12
  const sprite = isRoomy ? MIDDLE_FINE : SMALL_FINE
  const half = isRoomy ? 3.3 : 2.5
  const gate = w >= 60 ? Math.round(w * 0.7) : w - (isRoomy ? 7 : 6)
  const wallLeft = gate - (isRoomy ? 6 : 5)
  const wallRight = Math.min(w, gate + (isRoomy ? 7 : 6))
  const wallTop = Math.max(1, horizon - (isRoomy ? 9 : 7))
  const spring = horizon - (isRoomy ? 5 : 3)
  const golemX = Math.max(0, wallLeft - (isRoomy ? 11 : 9))
  const stopX = Math.max(2, golemX - 4)
  const hoverY = horizon - 2
  const settle = (kind === 'ok' ? OK_TICKS : BAD_TICKS) - RETURN_TICKS
  const isVerdict = (kind === 'ok' || kind === 'bad') && phase < settle
  const tone = isVerdict ? (kind === 'ok' ? GREEN : RED) : MAGENTA
  const isRising = kind === 'ok' && phase < settle
  const isClosed = kind === 'bad' && phase >= 10 && phase < settle
  const starOf = (i: number): { x: number; y: number } => ({
    x: Math.min(w - 2, 10 + Math.floor(hash(i, 11) * Math.max(1, wallLeft - 14))),
    y: 1 + Math.floor(hash(i, 17) * Math.max(1, horizon - 9)),
  })

  for (let y = 0; y < horizon - 2; y += 1) {
    for (let fx = 0; fx < cols * 2; fx += 1) {
      const n = hash(fx, y)

      if (n > 0.991) {
        dot(fx, y, n > 0.996 && ((tick >> 3) + Math.floor(n * 1000)) % 5 !== 0 ? STAR : STAR_DIM)
      }
    }
  }

  for (let sx = 0; sx < sw; sx += 1) {
    const peak = Math.round(3 + 3 * Math.abs(Math.sin(sx / 61 + 1)) + 2 * Math.abs(Math.sin(sx / 27 + 2)))
    const ridge = Math.max(1, Math.round(3 + 2 * Math.sin(sx / 36) + Math.sin(sx / 16 + 1)))

    for (let sy = horizon * 2 - peak; sy < horizon * 2; sy += 1) {
      sub(sx, sy, sy < horizon * 2 - 6 ? SNOW : MOUNT)
    }

    for (let sy = horizon * 2 - ridge; sy < horizon * 2; sy += 1) {
      sub(sx, sy, HILL)
    }
  }

  for (let i = 0; i < Math.round(w / 10); i += 1) {
    const spot = Math.floor(hash(i, 41) * w)

    if (spot >= wallLeft - 2 && spot <= wallRight + 1) {
      continue
    }

    const tall = 2 + Math.floor(hash(i, 43) * 2)

    for (let r = 0; r < tall * 2; r += 1) {
      for (let sx = spot * 4 - r - 1; sx <= spot * 4 + r + 2; sx += 1) {
        sub(sx, (horizon - tall) * 2 + r, PINE)
      }
    }
  }

  for (let dsy = -5; dsy <= 5; dsy += 1) {
    for (let dsx = -10; dsx <= 10; dsx += 1) {
      const x = (dsx + 0.5) / 4
      const y = (dsy + 0.5) / 2

      if (x * x + y * y <= 4.6 && h >= 12) {
        sub(26 + dsx, 7 + dsy, MOON)
      }
    }
  }

  const stars = Math.max(0, Math.min(20, passed - (isRising ? 1 : 0)))

  for (let i = 0; i < stars; i += 1) {
    const star = starOf(i)
    dot(star.x * 2 - 1, star.y, GREEN.mid)
    dot(star.x * 2 + 2, star.y, GREEN.mid)
    dot(star.x * 2, star.y, WHITE)
    dot(star.x * 2 + 1, star.y, WHITE)
  }

  for (let fx = 0; fx < cols * 2; fx += 1) {
    dot(fx, horizon, PATH)
    dot(fx, horizon + 1, hash(fx, 99) > 0.86 ? PEBBLE : PATH)
  }

  for (let fx = wallLeft * 2; fx < wallRight * 2; fx += 1) {
    const isMerlon = ((fx - wallLeft * 2) >> 1) % 2 === 0

    for (let y = wallTop - (isMerlon ? 1 : 0); y < horizon; y += 1) {
      const row = Math.floor(y / 2)
      const shifted = fx + (row & 1) * 4
      dot(fx, y, y % 2 === 0 && shifted % 8 === 0 ? MORTAR : hash(Math.floor(shifted / 8), row) > 0.7 ? BRICK_LIGHT : BRICK)
    }
  }

  for (let sy = (spring - 5) * 2; sy < horizon * 2; sy += 1) {
    for (let dsx = -18; dsx <= 17; dsx += 1) {
      const x = (dsx + 0.5) / 4
      const yy = (sy + 0.5) / 2
      const y = sy >> 1
      const round = x * x + (yy - spring) * (yy - spring)
      const isInside = Math.abs(x) <= half && (yy >= spring || round <= half * half + 0.3)
      const isRim =
        !isInside && Math.abs(x) <= half + 0.8 && (yy >= spring || round <= (half + 0.8) * (half + 0.8) + 0.3)

      if (isRim) {
        sub(gate * 4 + dsx, sy, RIM)
      }

      if (!isInside) {
        continue
      }

      let color = tone.dark

      if (isClosed) {
        color = ((dsx >> 1) + 8) % 3 === 0 ? STONE : BLACK
      } else if (kind === 'run') {
        color = (y + tick) % 3 === 0 ? tone.mid : tone.dark
      } else if (isVerdict) {
        color = kind === 'ok' && phase < 12 && (y + tick) % 2 === 0 ? tone.bright : tone.mid
      } else {
        color = (y + (tick >> 2)) % 4 === 0 ? tone.mid : tone.dark
      }

      sub(gate * 4 + dsx, sy, color)
    }
  }

  for (const side of [-(isRoomy ? 5 : 4), isRoomy ? 5 : 4]) {
    if (gate + side >= wallLeft && gate + side < wallRight) {
      dot((gate + side) * 2, spring - 1, (tick + side) % 3 === 0 ? EMBER : FLAME)
      dot((gate + side) * 2, spring, WOOD)
    }
  }

  let lamp: { x: number; y: number; tone: Tone } | null = null
  const orb = (x: number, y: number, orbTone: Tone): void => {
    lamp = { x: x + 0.5, y: y + 0.5, tone: orbTone }

    for (let dsy = -3; dsy <= 3; dsy += 1) {
      for (let dsx = -6; dsx <= 7; dsx += 1) {
        const d = Math.hypot((dsx - 0.5) / 4, (dsy + 0.5) / 2)

        if (d <= 1.6) {
          sub(x * 4 + 2 + dsx, y * 2 + 1 + dsy, d < 0.6 ? WHITE : d <= 1.1 ? orbTone.bright : orbTone.mid)
        }
      }
    }
  }

  if (kind === 'ok' && phase < 10) {
    orb(Math.round(stopX + ((gate - stopX) * phase) / 10), hoverY, GREEN)
  }

  const u = ((stride % 96) + 96) % 96
  const sleepAt = SLEEP_AFTER + ((74 - (SLEEP_AFTER % 96) + 96) % 96)
  const isAsleep = kind === 'rest' && stride >= sleepAt
  const reach = u < 30 ? Math.floor(u / 6) : u < 44 ? 5 : u < 74 ? 5 - Math.floor((u - 44) / 6) : 0
  const isMoving = !isAsleep && (u < 30 || (u >= 44 && u < 74))
  const away = isAsleep || kind === 'ok' || kind === 'bad' ? 0 : kind === 'run' ? Math.round(reach * (1 - clamp(phase / 6))) : reach
  const step = (kind === 'rest' || kind === 'think') && isMoving ? (Math.floor(stride / 3) % 2) + 1 : 0
  const isBlink = isAsleep || ((kind === 'think' || kind === 'rest') && tick % 47 < 2)
  const isBlocking = kind === 'bad' && phase < settle
  const top = horizon + (isRoomy ? 2 : 1) - sprite.length - (kind === 'ok' && phase >= 2 && phase < 5 ? 1 : 0)
  const bodyX = (Math.max(0, golemX - away)) * 2
  const rune = isAsleep ? tone.dark : kind === 'run' || isVerdict ? ((tick >> 1) % 2 === 0 ? tone.bright : tone.mid) : tone.mid

  sprite.forEach((line, row) => {
    for (let col = 0; col < line.length; col += 1) {
      const letter = line[col] ?? '.'
      const middle = line.length >> 1
      const isLifted = row >= sprite.length - 3 && row < sprite.length - 1 && ((step === 1 && col < middle) || (step === 2 && col >= middle))

      if (letter === '.') {
        continue
      }

      const shade =
        letter === 'o'
          ? OUTLINE
          : letter === 'h'
            ? STONE_LIGHT
            : letter === 'd'
              ? STONE_DARK
              : letter === 'e'
                ? isBlink
                  ? STONE_DARK
                  : tone.mid
                : letter === 'E'
                  ? isBlink
                    ? STONE_DARK
                    : tone.bright
                  : letter === 'r'
                    ? rune
                    : STONE
      dot(bodyX + col, top + row - (isLifted ? 1 : 0), shade)
    }
  })

  for (let i = 0; isAsleep && i < 2; i += 1) {
    const age = (Math.floor(tick / 3) + i * 3) % 6
    marks.push({ cx: (bodyX >> 1) + 6 + age + i, cy: (top >> 1) - age, glyph: 0x7a, color: STAR })
  }

  for (let fx = bodyX - 8; isBlocking && fx <= bodyX + 1; fx += 1) {
    dot(fx, top + (isRoomy ? 5 : 4), STONE_LIGHT)
    dot(fx, top + (isRoomy ? 6 : 5), OUTLINE)
  }

  if (kind === 'run') {
    orb(Math.round(-2 + (stopX + 2) * (1 - Math.exp(-phase / 6))), hoverY - (isWrite ? 0 : 2), isWrite ? MAGENTA : CYAN)
  } else if (isRising && phase >= 10 && passed > 0) {
    const star = starOf(passed - 1)
    const t = clamp((phase - 10) / (settle - 10))
    const ease = t * t * (3 - 2 * t)
    orb(Math.round(gate + (star.x - gate) * ease), Math.round(spring - 4 + (star.y - spring + 4) * ease), GREEN)
  } else if (kind === 'bad' && phase < 4) {
    orb(stopX + (tick % 2), hoverY, RED)
  } else if (kind === 'bad' && phase < 16) {
    const age = phase - 4

    for (let i = 0; i < 8; i += 1) {
      const fx = Math.round(stopX * 2 + (hash(i, 3) - 0.6) * age * 1.4)
      dot(fx, Math.min(horizon + 1, Math.round(hoverY - hash(i, 5) * age * 0.5 + 0.07 * age * age)), age < 7 ? RED.bright : RED.mid)
    }
  }

  const power = isClosed ? 0 : kind === 'run' ? 0.7 : kind === 'ok' && phase < settle ? 1 : kind === 'bad' ? 0.8 : 0.35
  const sources: Source[] = [
    { x: gate, y: horizon - 1, spread: 22, power, tint: parts(tone.mid).map(v => v / 255) },
  ]

  for (const side of [-(isRoomy ? 5 : 4), isRoomy ? 5 : 4]) {
    if (gate + side >= wallLeft && gate + side < wallRight) {
      sources.push({ x: gate + side + 0.5, y: spring - 1, spread: 12, power: 0.85 + 0.15 * ((tick >> 1) % 2), tint: [1, 0.55, 0.2] })
    }
  }

  const held = lamp as { x: number; y: number; tone: Tone } | null

  if (held !== null) {
    sources.push({ x: held.x, y: held.y, spread: 10, power: 1, tint: parts(held.tone.mid).map(v => v / 255) })
  }

  light(px, cols, rows, sources, horizon, 6.5, 3.5, 22, kind === 'bad' && phase < 2 ? 40 : 0)

  return finish(px, cols, rows, marks)
}

export const paint = (
  cols: number,
  rows: number,
  kind: Kind,
  tick: number,
  phase: number,
  passed: number,
  stride: number,
  refused: number,
  isWrite: boolean,
): string => {
  if (rows < FULL_ROWS) {
    return paintSmall(cols, rows, kind, tick, phase, passed, stride, isWrite)
  }

  const w = cols
  const fw = cols * 2
  const h = rows * 2
  const sw = cols * 4
  const sh = rows * 4
  const px = new Int32Array(sw * sh).fill(SKY)
  const marks: Mark[] = []
  const sub = (sx: number, sy: number, color: number): void => {
    if (sx >= 0 && sy >= 0 && sx < sw && sy < sh) {
      px[sy * sw + sx] = color
    }
  }
  const dot = (fx: number, y: number, color: number): void => {
    sub(fx * 2, y * 2, color)
    sub(fx * 2 + 1, y * 2, color)
    sub(fx * 2, y * 2 + 1, color)
    sub(fx * 2 + 1, y * 2 + 1, color)
  }
  const fine = (fx0: number, y0: number, fx1: number, y1: number, color: number): void => {
    for (let y = y0; y <= y1; y += 1) {
      for (let fx = fx0; fx <= fx1; fx += 1) {
        dot(fx, y, color)
      }
    }
  }
  const set = (x: number, y: number, color: number): void => fine(x * 2, y, x * 2 + 1, y, color)
  const box = (x0: number, y0: number, x1: number, y1: number, color: number): void =>
    fine(x0 * 2, y0, x1 * 2 + 1, y1, color)

  const horizon = h - (h >= 28 ? 8 : h >= 22 ? 5 : 4)
  const moonY = Math.max(6, Math.round(horizon * 0.22))
  const lakeEnd = cols >= 80 ? Math.round(cols * 0.26) : 0
  const pathTop = horizon + 2
  const feet = horizon + 3
  const hasTower = w >= 44 && h >= 30
  const gate = w >= 100 ? Math.round(w * 0.7) : w - (w >= 60 ? 14 : 7)
  const wallRight = Math.min(w, gate + 18)
  const wallLeft = gate - (w >= 44 ? 11 : 7)
  const wallTop = horizon - 14
  const golemX = Math.max(0, wallLeft - 17)
  const stopX = Math.max(3, golemX - 6)
  const hoverY = pathTop - 4 + ((tick >> 2) & 1)
  const settle = (kind === 'ok' ? OK_TICKS : BAD_TICKS) - RETURN_TICKS
  const isVerdict = (kind === 'ok' || kind === 'bad') && phase < settle
  const tone = isVerdict ? (kind === 'ok' ? GREEN : RED) : MAGENTA
  const isRising = kind === 'ok' && phase < settle
  const stars = Math.max(0, Math.min(30, passed - (isRising ? 1 : 0)))
  const starOf = (i: number): { x: number; y: number } => ({
    x: Math.min(w - 3, 16 + Math.floor(hash(i, 11) * Math.max(1, wallLeft - 20))),
    y: Math.max(2, horizon - 40) + Math.floor(hash(i, 17) * Math.max(1, Math.min(18, horizon - 24))),
  })

  for (let y = 0; y < horizon - 4; y += 1) {
    for (let fx = 0; fx < fw; fx += 1) {
      const n = hash(fx, y)

      if (n > 0.991) {
        const isLit = ((tick >> 3) + Math.floor(n * 1000)) % 5 !== 0
        dot(fx, y, n > 0.996 && isLit ? STAR : STAR_DIM)
      }
    }
  }

  const veil = isVerdict ? tone : VEIL
  const skyRows = horizon * 2 - 20

  for (let sx = 0; skyRows >= 12 && sx < sw; sx += 1) {
    for (let k = 0; k < 2; k += 1) {
      if (0.5 + 0.5 * Math.sin(sx / 31 + tick / 23 + k * 4) < 0.55) {
        continue
      }

      const cy = Math.round(
        skyRows * (0.18 + 0.3 * k) +
          2.2 * Math.sin(sx / 46 + tick / 17 + k * 2) +
          1.3 * Math.sin(sx / 19 - tick / 13 + k),
      )
      const shade = isVerdict ? veil.mid : veil.bright

      sub(sx, cy, shade)
      sub(sx, cy + 1, isVerdict ? veil.dark : veil.mid)
      sub(sx, cy + 2, veil.dark)
    }
  }

  const shot = tick % 170

  if (shot < 7) {
    const fx = Math.round(fw * 0.55) - shot * 6
    const y = 2 + shot

    fine(fx, y, fx + 1, y, WHITE)
    fine(fx + 2, y - 1, fx + 4, y - 1, STAR)
    fine(fx + 5, y - 2, fx + 8, y - 2, STAR_DIM)
  }

  for (let sx = 0; sx < sw; sx += 1) {
    const peak = Math.round(
      6 + 5 * Math.abs(Math.sin(sx / 61 + 1)) + 4 * Math.abs(Math.sin(sx / 27 + 2)) + 2 * Math.sin(sx / 9),
    )

    for (let sy = horizon * 2 - peak; sy < horizon * 2; sy += 1) {
      sub(sx, sy, sy < horizon * 2 - 12 ? SNOW : MOUNT)
    }
  }

  for (let sx = 0; sx < sw; sx += 1) {
    const ridge = Math.max(2, Math.round(8 + 5 * Math.sin(sx / 36) + 3 * Math.sin(sx / 16 + 1)))

    for (let sy = horizon * 2 - ridge; sy < horizon * 2; sy += 1) {
      sub(sx, sy, HILL)
    }
  }

  for (let i = 0; i < Math.round(w / 10); i += 1) {
    const spot = Math.floor(hash(i, 41) * w)

    if ((spot >= wallLeft - 3 && spot <= wallRight + 2) || spot < lakeEnd + 2) {
      continue
    }

    const fx = spot * 2
    const tall = 4 + Math.floor(hash(i, 43) * 4)

    for (let r = 0; r < tall * 2; r += 1) {
      for (let sx = fx * 2 - r - 1; sx <= fx * 2 + r + 2; sx += 1) {
        sub(sx, (horizon - tall) * 2 + r, PINE)
      }
    }
  }

  for (let sy = horizon * 2 - 6; sy < horizon * 2; sy += 1) {
    for (let sx = 0; sx < lakeEnd * 4; sx += 1) {
      const isRipple = (Math.floor(sx / 6) + sy * 3 + (tick >> 2)) % 7 === 0
      const isGlint = Math.abs(sx - 38) < 4 + ((sy + (tick >> 1)) % 3) * 2
      const glint = (sy + (tick >> 1)) % 2 === 0 ? GLINT : GLINT_DIM
      sub(sx, sy, isGlint ? glint : isRipple ? RIPPLE : WATER)
    }
  }

  for (let dsy = -10; dsy <= 10; dsy += 1) {
    for (let dsx = -20; dsx <= 20; dsx += 1) {
      const x = (dsx + 0.5) / 4
      const y = (dsy + 0.5) / 2

      if (x * x + y * y <= 17.5) {
        sub(38 + dsx, moonY * 2 + 1 + dsy, MOON)
      }
    }
  }

  for (const [dfx, dy] of [[-4, -1], [-3, -1], [2, 2], [3, 2], [4, -2], [-2, 1], [-1, 2], [5, 0]] as const) {
    dot(18 + dfx, moonY + dy, MOON_SHADE)
  }

  for (let i = 0; i < 3; i += 1) {
    const lap = (tick + i * 9) % 230
    const cx = lap * 2 - 4 - i * 3
    const cy = (moonY >> 1) + 2 + i + Math.round(Math.sin(lap / 4 + i))

    if (cx < cols) {
      marks.push({ cx, cy, glyph: (tick >> 1) % 2 === 0 ? 0x76 : 0x5e, color: STONE })
    }
  }

  for (let i = 0; i < 2; i += 1) {
    const span = fw + 48
    const fx = ((Math.floor(tick / (3 + i * 2)) + i * 74) % span) - 24
    const y = moonY - 2 + i * 6

    fine(fx + 1, y, fx + 19, y, CLOUD)
    fine(fx + 5, y - 1, fx + 14, y - 1, CLOUD_LIGHT)
    fine(fx - 3, y + 1, fx + 23, y + 1, CLOUD)
  }

  for (let i = 0; i < stars; i += 1) {
    const star = starOf(i)
    const arm = ((tick >> 2) + i) % 6 !== 0 ? GREEN.mid : GREEN.dark

    set(star.x, star.y - 1, arm)
    set(star.x, star.y + 1, arm)
    fine(star.x * 2 - 2, star.y, star.x * 2 + 3, star.y, arm)
    set(star.x, star.y, WHITE)
  }

  box(0, horizon, w - 1, h - 1, GROUND)
  box(0, pathTop, w - 1, pathTop + 2, PATH)

  for (let fx = 0; fx < fw; fx += 1) {
    if (hash(fx, 99) > 0.86) {
      dot(fx, pathTop + Math.floor(hash(fx, 7) * 3), PEBBLE)
    }
  }

  for (let i = 0; i < Math.min(16, refused); i += 1) {
    const fx = Math.floor(hash(i, 83) * Math.max(1, stopX * 2 + 8))
    const y = pathTop + Math.floor(hash(i, 89) * 3)

    fine(fx, y, fx + 1, y, RED.dark)
    dot(fx + 1, y - 1, RED.mid)
  }

  for (let fx = 0; fx < fw; fx += 1) {
    if (hash(fx, 61) > 0.7 && fx >= lakeEnd * 2 && (fx < wallLeft * 2 || fx >= wallRight * 2)) {
      const lean = (Math.floor(tick / 6) + fx) % 4 === 0 ? 1 : 0
      dot(fx, horizon, GRASS)
      dot(fx + lean, horizon - 1, GRASS)
    }
  }

  for (let i = 0; i < 4; i += 1) {
    const t = tick / 9 + i * 2.1
    const fx = Math.round(8 + hash(i, 71) * Math.max(1, wallLeft * 2 - 24) + 6 * Math.sin(t))
    const y = Math.round(horizon - 3 - hash(i, 73) * 4 + 1.5 * Math.sin(t * 1.7))

    if ((Math.floor(tick / 4) + i) % 3 !== 0) {
      dot(fx, y, FIREFLY)
    }
  }

  const brick = (fx: number, y: number): number => {
    const row = Math.floor(y / 3)
    const shifted = fx + (row & 1) * 6

    if (y % 3 === 0 || shifted % 12 === 0) {
      return MORTAR
    }

    return hash(Math.floor(shifted / 12), row) > 0.7 ? BRICK_LIGHT : BRICK
  }

  for (let fx = wallLeft * 2; fx < wallRight * 2; fx += 1) {
    const isTower = hasTower && fx < (wallLeft + 6) * 2
    const top = isTower ? wallTop - 4 : wallTop
    const isMerlon = ((fx - wallLeft * 2) >> 2) % 2 === 0

    for (let y = top - (isMerlon ? 2 : 0); y < horizon; y += 1) {
      dot(fx, y, brick(fx, y))
    }
  }

  const pole = (wallLeft + 2) * 2
  const poleTop = wallTop - 13

  if (hasTower) {
    fine(pole, poleTop, pole, wallTop - 7, RIM)
  }

  for (let x = 2; hasTower && x <= 25; x += 1) {
    const wave = Math.round(2 * Math.sin(tick / 3 - x * 0.22))

    for (let r = 0; r < 6; r += 1) {
      sub(pole * 2 + x, poleTop * 2 + wave + r, x % 12 === 0 ? tone.dark : tone.mid)
    }
  }

  const spring = horizon - 7
  const isClosed = kind === 'bad' && phase >= 10 && phase < settle

  for (let sy = (spring - 6) * 2; sy < horizon * 2; sy += 1) {
    for (let dsx = -24; dsx <= 23; dsx += 1) {
      const x = (dsx + 0.5) / 4
      const yy = (sy + 0.5) / 2
      const y = sy >> 1
      const dfx = dsx >> 1
      const round = x * x + (yy - spring) * (yy - spring)
      const isInside = Math.abs(x) <= 4.5 && (yy >= spring || round <= 20)
      const isRim = !isInside && Math.abs(x) <= 5.5 && (yy >= spring || round <= 31)

      if (isRim) {
        sub(gate * 4 + dsx, sy, RIM)
      }

      if (!isInside) {
        continue
      }

      let color = tone.dark

      if (isClosed) {
        color = (dfx + 12) % 4 === 0 || y === spring ? STONE : BLACK
      } else if (kind === 'think' || kind === 'rest') {
        color = (y + (tick >> 2)) % 6 === 0 ? tone.mid : tone.dark
      } else if (kind === 'run') {
        color = (y + tick) % 3 === 0 ? tone.mid : tone.dark
      } else if (kind === 'ok' && phase < settle) {
        color = phase < 12 ? ((y + tick) % 2 === 0 ? tone.bright : tone.mid) : tone.mid
      } else if (kind === 'bad' && phase < 10) {
        color = ((dfx >> 1) + y + tick) % 2 === 0 ? tone.mid : tone.dark
      }

      sub(gate * 4 + dsx, sy, color)
    }
  }

  for (const side of [-8, 8]) {
    const x = gate + side

    if (x < wallLeft || x >= wallRight) {
      continue
    }

    const flick = (tick + side) % 3
    const puff = (tick + side * 3) % 16

    if (puff < 8) {
      dot(x * 2 + (puff > 4 ? 2 : 0), spring - 6 - (puff >> 1), SMOKE)
    }

    box(x, spring - 2, x, spring + 1, WOOD)
    set(x, spring - 3, FLAME)
    set(x, spring - 4, flick === 0 ? FLAME : EMBER)
    dot(x * 2 + flick, spring - 5, EMBER)
  }

  let lamp: { x: number; y: number; tone: Tone } | null = null
  const orb = (x: number, y: number, orbTone: Tone, isWide: boolean): void => {
    const reach = isWide ? 3.1 : 2.4
    lamp = { x: x + 0.5, y: y + 0.5, tone: orbTone }

    for (let dsy = -7; dsy <= 7; dsy += 1) {
      for (let dsx = -14; dsx <= 15; dsx += 1) {
        const d = Math.hypot((dsx - 0.5) / 4, (dsy + 0.5) / 2)

        if (d <= reach) {
          const shade = d < 0.7 ? WHITE : d <= 1.4 ? orbTone.bright : d <= 2.3 ? orbTone.mid : orbTone.dark
          sub(x * 4 + 2 + dsx, y * 2 + 1 + dsy, shade)
        }
      }
    }
  }

  const isWide = (tick >> 1) % 2 === 0

  if (kind === 'ok' && phase < 10) {
    orb(Math.round(stopX + ((gate - stopX) * phase) / 10), hoverY, GREEN, isWide)
  }

  const walk = (t: number): { at: number; isMoving: boolean } => {
    const u = ((t % 96) + 96) % 96

    if (u < 30) {
      return { at: Math.floor(u / 3), isMoving: true }
    }

    if (u < 44) {
      return { at: 10, isMoving: false }
    }

    if (u < 74) {
      return { at: 10 - Math.floor((u - 44) / 3), isMoving: true }
    }

    return { at: 0, isMoving: false }
  }
  const sleepAt = SLEEP_AFTER + ((74 - (SLEEP_AFTER % 96) + 96) % 96)
  const isAsleep = kind === 'rest' && stride >= sleepAt
  const pace = isAsleep ? { at: 0, isMoving: false } : walk(stride)
  const away =
    kind === 'rest' || kind === 'think'
      ? Math.min(pace.at, golemX)
      : kind === 'run'
        ? Math.round(Math.min(pace.at, golemX) * (1 - clamp(phase / 6)))
        : 0
  const isStepping =
    ((kind === 'rest' || kind === 'think') && pace.isMoving) || (kind === 'run' && away > 0)
  const step = isStepping ? (Math.floor((kind === 'run' ? phase : stride) / 3) % 2) + 1 : 0
  const hop = kind === 'ok' && ((phase >= 2 && phase < 5) || (phase >= 8 && phase < 11)) ? 1 : 0
  const bob = isAsleep ? 1 : (tick >> 3) % 2
  const isBlink = isAsleep || ((kind === 'think' || kind === 'rest') && tick % 47 < 2)
  const isBlocking = kind === 'bad' && phase < settle
  const rune = isAsleep
    ? tone.dark
    : kind === 'rest'
      ? tone.mid
      : kind === 'think'
        ? (tick >> 3) % 2 === 0
          ? tone.mid
          : tone.dark
        : (tick >> 1) % 2 === 0
          ? tone.bright
          : tone.mid
  const top = feet - (HEAD.length + BODY.length) + 1 - hop
  const bodyX = (golemX - away) * 2
  const shade = (letter: string): number =>
    letter === 'o'
      ? OUTLINE
      : letter === 'h'
        ? STONE_LIGHT
        : letter === 'd'
          ? STONE_DARK
          : letter === 'e'
            ? isBlink
              ? STONE_DARK
              : tone.mid
            : letter === 'E'
              ? isBlink
                ? STONE_DARK
                : tone.bright
              : letter === 'r'
                ? rune
                : STONE

  HEAD_FINE.forEach((line, row) => {
    for (let col = 0; col < line.length; col += 1) {
      const letter = line[col] ?? '.'

      if (letter !== '.') {
        dot(bodyX + col, top + row + bob, shade(letter))
      }
    }
  })

  BODY_FINE.forEach((line, row) => {
    for (let col = 0; col < line.length; col += 1) {
      const letter = line[col] ?? '.'
      const isLifted = row >= 7 && ((step === 1 && col < 14) || (step === 2 && col > 15))

      if (letter !== '.' && !(isBlocking && col < 8 && row < 7)) {
        dot(bodyX + col, top + HEAD.length + row - (isLifted ? 1 : 0), shade(letter))
      }
    }
  })

  for (let i = 0; isAsleep && i < 3; i += 1) {
    const age = (Math.floor(tick / 3) + i * 3) % 9
    marks.push({
      cx: (bodyX >> 1) + 12 + age + i,
      cy: (top >> 1) - 1 - age,
      glyph: age < 4 ? 0x7a : 0x5a,
      color: age < 6 ? STAR : STAR_DIM,
    })
  }

  if (isBlocking) {
    const y = top + HEAD.length
    fine(bodyX - 14, y, bodyX + 7, y + 3, OUTLINE)
    fine(bodyX - 13, y + 1, bodyX + 7, y + 1, STONE_LIGHT)
    fine(bodyX - 13, y + 2, bodyX + 7, y + 2, STONE)
  }

  if (kind === 'ok' && phase >= settle && phase < settle + 6 && passed > 0) {
    const star = starOf(passed - 1)
    const reach = phase - settle + 2

    for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1], [1, 1], [-1, -1], [1, -1], [-1, 1]] as const) {
      dot((star.x + dx * reach) * 2, star.y + dy * reach, reach < 5 ? GREEN.bright : GREEN.mid)
    }
  }

  if (kind === 'run') {
    const x = Math.round(-3 + (stopX + 3) * (1 - Math.exp(-phase / 6)))
    const runTone = isWrite ? MAGENTA : CYAN
    fine(x * 2 - 12, hoverY, x * 2 - 10, hoverY, runTone.dark)
    fine(x * 2 - 9, hoverY, x * 2 - 7, hoverY, runTone.mid)
    orb(x, hoverY - (isWrite ? 0 : 3), runTone, isWrite && isWide)
  } else if (isRising && phase >= 10) {
    const star = starOf(passed - 1)
    const t = clamp((phase - 10) / (settle - 10))
    const ease = t * t * (3 - 2 * t)
    const fromY = spring - 9
    orb(Math.round(gate + (star.x - gate) * ease), Math.round(fromY + (star.y - fromY) * ease), GREEN, isWide)
  } else if (kind === 'bad' && phase < 4) {
    orb(stopX + (tick % 2), hoverY, RED, true)
  } else if (kind === 'bad' && phase < 20) {
    const age = phase - 4

    for (let i = 0; i < 14; i += 1) {
      const fx = Math.round(stopX * 2 + (hash(i, 3) - 0.6) * age * 1.8)
      const y = Math.min(pathTop + 2, Math.round(hoverY - hash(i, 5) * age * 0.7 + 0.07 * age * age))
      dot(fx, y, age < 8 ? RED.bright : age < 12 ? RED.mid : RED.dark)
    }
  }

  const flicker = 0.85 + 0.15 * ((tick >> 1) % 2)
  const portal = isClosed
    ? 0
    : kind === 'run'
      ? 0.7
      : kind === 'ok'
        ? phase < settle
          ? 1
          : 0.4
        : kind === 'bad'
          ? 0.8
          : kind === 'think'
            ? 0.4
            : 0.3
  const sources: Source[] = [
    { x: gate, y: horizon - 2, spread: 70, power: portal, tint: parts(tone.mid).map(v => v / 255) },
  ]

  for (const side of [-8, 8]) {
    if (gate + side >= wallLeft && gate + side < wallRight) {
      sources.push({ x: gate + side + 0.5, y: spring - 3, spread: 40, power: flicker, tint: [1, 0.55, 0.2] })
    }
  }

  const flash = kind === 'bad' && phase < 2 ? 40 : 0
  const held = lamp as { x: number; y: number; tone: Tone } | null

  if (held !== null) {
    sources.push({ x: held.x, y: held.y, spread: 30, power: 1, tint: parts(held.tone.mid).map(v => v / 255) })
  }

  light(px, cols, rows, sources, horizon, 9.5, moonY + 0.5, 70, flash)

  if (kind === 'bad' && phase < 4) {
    let bx = stopX * 4 + 14

    for (let sy = 0; sy < hoverY * 2; sy += 1) {
      if (sy % 4 === 0) {
        bx += Math.round((hash(sy, tick >> 1) - 0.5) * 8) - 1
      }

      sub(bx - 1, sy, BOLT)
      sub(bx, sy, WHITE)
      sub(bx + 1, sy, WHITE)
      sub(bx + 2, sy, BOLT)
    }
  }

  if (isRising && phase >= 8 && phase < 22) {
    const shade = phase < 15 ? GREEN.bright : GREEN.mid

    for (let sy = 0; sy < (spring - 6) * 2; sy += 1) {
      sub(gate * 4 - 2, sy, GREEN.dark)
      sub(gate * 4 - 1, sy, shade)
      sub(gate * 4, sy, shade)
      sub(gate * 4 + 1, sy, GREEN.dark)
    }
  }

  return finish(px, cols, rows, marks)
}
