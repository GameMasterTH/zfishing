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

export type FishAction = 'RUN' | 'DIVE' | 'THRASH' | 'JUMP' | 'REST' | 'LANDING'

// Exactly what server/encounter_mindgame.lua's M.render(enc, now) returns. Durations,
// never timestamps, and no field naming the correct response.
//
// `progress`/`reads` is the single progress number: how tired the fish is AND how many
// reads are left. There is deliberately no second stamina figure restating it.
export type MindgameState = {
  phaseId: number
  phase: 'TURN' | 'LANDING'
  cue: FishAction
  nextCue?: FishAction
  telegraphIn: number
  /** answers are refused until this elapses -- the panel has to draw the wait */
  windowOpensIn: number
  windowClosesIn: number
  /** present only when the fish is faking; always earlier than windowOpensIn */
  switchIn?: number
  progress: number
  reads: number
  linePct: number
  pressure: number
  escapeThreshold: number
}

// Discriminated, so `type` and `state` can only ever be narrowed together.
export type EncounterMessage =
  | { type: 'counter_pull';  difficulty: number; state: CounterPullState; startedAt: number }
  | { type: 'fish_mindgame'; difficulty: number; state: MindgameState;    startedAt: number }
