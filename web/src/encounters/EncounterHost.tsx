import { useEffect, useState } from 'react'
import { useNuiEvent } from '../hooks/useNui'
import CounterPull from './CounterPull'
import type { CounterPullState, EncounterMessage, Outcome } from './types'

// One shell for every encounter, so the three of them read as one product: same panel
// material, same typography, same success/failure language. Only the fight differs.
export default function EncounterHost({ msg }: { msg: EncounterMessage }) {
  const [state, setState] = useState<CounterPullState>(msg.state)
  const [outcome, setOutcome] = useState<Outcome | null>(null)

  // React state moves on a TRANSITION, never per frame. The per-frame work lives in
  // the child's requestAnimationFrame loop and writes straight to a DOM node.
  useNuiEvent((m) => {
    if (m.action !== 'encounterState') return
    if (m.state) setState(m.state)
    if (m.outcome) setOutcome(m.outcome)
  })

  useEffect(() => { setState(msg.state); setOutcome(null) }, [msg.startedAt])

  if (msg.type === 'counter_pull') {
    return <CounterPull state={state} outcome={outcome} />
  }
  return null
}
