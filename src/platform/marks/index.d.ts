export type Running = {
  verb: string
  target: string
  startedAt: number
  startFrame: number
}

export type Done = {
  verb: string
  target: string
  ms: number
  overheadMs: number
  isOk: boolean
  note: string
}

export type Verdict = { isOk: boolean; startFrame: number }

declare module 'claude-code' {
  interface PluginState {
    'emetgate-marks': {
      running: Running | null
      done: readonly Done[]
      frame: number
      verdict: Verdict | null
      isHidden: boolean
      isSilent: boolean
    }
  }
}
