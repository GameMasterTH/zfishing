import { useEffect, useState } from 'react'
import type { ReactNode } from 'react'
import { useNuiEvent } from '../hooks/useNui'
import CounterPull from './CounterPull'
import FishMindgame from './FishMindgame'
import SonarStrike from './SonarStrike'
import type { EncounterMessage, Outcome } from './types'

// Holds one encounter's live state at its own type. The single cast below is at the only
// place a cast belongs -- the NUI message channel, which really is untyped -- and every
// use site downstream is checked.
function Live<S>({ initial, startedAt, children }: {
  initial: S
  startedAt: number
  children: (state: S, outcome: Outcome | null) => ReactNode
}) {
  const [state, setState] = useState<S>(initial)
  const [outcome, setOutcome] = useState<Outcome | null>(null)

  // React state moves on a TRANSITION, never per frame. The per-frame work lives in the
  // child's requestAnimationFrame loop and writes straight to a DOM node.
  useNuiEvent((m) => {
    if (m.action !== 'encounterState') return
    if (m.state) setState(m.state as S)
    if (m.outcome) setOutcome(m.outcome)
  })

  useEffect(() => { setState(initial); setOutcome(null) }, [startedAt])

  return <>{children(state, outcome)}</>
}

// One shell for every encounter, so they read as one product: same panel material, same
// typography, same success/failure language. Only the fight inside differs.
//
// The `key` is what makes switching encounters safe: both branches render the same
// component type, so without it React would reconcile them as one and keep the previous
// encounter's state shape.
//
// It closes reconciliation, not delivery -- each Live attaches its own `message` listener
// and filters on `action` alone, so nothing here would reject another encounter's payload.
// What makes that unreachable is ordering: the bridge always sends `encounter` before any
// `encounterState` for that fight, postMessage preserves order, and React's unmount and
// mount land in one synchronous commit that no event can interleave with. If any of those
// three stops holding, this needs a type field on the message and a check here.
export default function EncounterHost({ msg }: { msg: EncounterMessage }) {
  switch (msg.type) {
    case 'counter_pull':
      return (
        <Live key="counter_pull" initial={msg.state} startedAt={msg.startedAt}>
          {(state, outcome) => <CounterPull state={state} outcome={outcome} />}
        </Live>
      )
    case 'fish_mindgame':
      return (
        <Live key="fish_mindgame" initial={msg.state} startedAt={msg.startedAt}>
          {(state, outcome) => <FishMindgame state={state} outcome={outcome} />}
        </Live>
      )
    case 'sonar_strike':
      return (
        <Live key="sonar_strike" initial={msg.state} startedAt={msg.startedAt}>
          {(state, outcome) => <SonarStrike state={state} outcome={outcome} />}
        </Live>
      )
    default:
      return null
  }
}
