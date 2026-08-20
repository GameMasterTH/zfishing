export type EncounterType = 'counter_pull' | 'fish_mindgame' | 'sonar_strike'
export type Outcome = 'success' | 'escape' | 'snap' | 'timeout'

export type CounterPullPhase = 'LEFT_RUN' | 'RIGHT_RUN' | 'DIVE' | 'FATIGUED' | 'LANDING'

// Exactly what server/encounter_counter_pull.lua's M.render(enc, now) returns.
//
// Every time value is a DURATION from the moment the server built this payload, never
// a timestamp: the server's clock and this page's clock share no origin. The component
// anchors them to its own Date.now() once, keyed on phaseId.
//
// Note what is NOT here: the required counter. The player reads it off the cue.
export type CounterPullState = {
  /** increments on every authoritative transition, including a repeat of the same phase */
  phaseId: number
  phase: CounterPullPhase
  cue: CounterPullPhase
  nextCue?: CounterPullPhase
  telegraphIn: number
  windowOpensIn: number
  windowClosesIn: number
  /** present only when the fish is faking */
  switchIn?: number
  staminaPct: number
  linePct: number
  misses: number
  maxMisses: number
  reelsLeft?: number
}

export type EncounterMessage = {
  type: EncounterType
  difficulty: number
  state: CounterPullState
  startedAt: number
}
