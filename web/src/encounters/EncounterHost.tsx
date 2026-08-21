import { useEffect, useState } from 'react'
import type { ReactNode } from 'react'
import { useNuiEvent } from '../hooks/useNui'
import CounterPull from './CounterPull'
import FishMindgame from './FishMindgame'
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
// encounter's state shape for a frame.
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
    default:
      return null
  }
}
