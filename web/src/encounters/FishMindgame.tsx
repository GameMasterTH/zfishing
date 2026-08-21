import { useEffect, useMemo, useRef, useState } from 'react'
import { fetchNui } from '../hooks/useNui'
import { t } from '../i18n'
import Keycap from '../components/Keycap'
import type { FishAction, MindgameState, Outcome } from './types'

// What the fish is doing. Shape and text, never colour alone.
const ACTIONS: Record<FishAction, { glyph: string; label: string }> = {
  RUN:     { glyph: '⇥', label: 'enc_mg_run' },
  DIVE:    { glyph: '⤓', label: 'enc_mg_dive' },
  THRASH:  { glyph: '⇋', label: 'enc_mg_thrash' },
  JUMP:    { glyph: '⤒', label: 'enc_mg_jump' },
  REST:    { glyph: '◦', label: 'enc_mg_rest' },
  LANDING: { glyph: '⚓', label: 'enc_mg_landing' },
}

// The four responses, in the order the bridge maps them. Labels carry the meaning; the
// keycaps carry the input. There is no click handler on purpose -- the fight runs without
// NUI focus, so a click could never fire.
const RESPONSES: { key: string; label: string }[] = [
  { key: 'A',     label: 'enc_mg_give_line' },
  { key: 'S',     label: 'enc_mg_brace' },
  { key: 'D',     label: 'enc_mg_hold' },
  { key: 'SPACE', label: 'enc_mg_reel' },
]

export default function FishMindgame(
  { state, outcome }: { state: MindgameState; outcome: Outcome | null }
) {
  // Anchored once per authoritative turn, keyed on phaseId. See CounterPull for why a ref
  // mutated inside an effect is not good enough.
  const timing = useMemo(() => {
    const receivedAt = Date.now()
    return {
      opensAt: receivedAt + state.windowOpensIn,
      closesAt: receivedAt + state.windowClosesIn,
      switchAt: state.switchIn === undefined ? undefined : receivedAt + state.switchIn,
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [state.phaseId])

  const [shown, setShown] = useState<FishAction>(state.cue)
  const [faked, setFaked] = useState(false)
  const [open, setOpen] = useState(state.windowOpensIn <= 0)
  const barRef = useRef<HTMLDivElement | null>(null)

  useEffect(() => {
    setShown(state.cue)
    setFaked(false)
    setOpen(state.windowOpensIn <= 0)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [state.phaseId])

  // The window opens on the server's schedule, and the panel says so before it does.
  useEffect(() => {
    if (open) return
    const id = setTimeout(() => setOpen(true), Math.max(0, timing.opensAt - Date.now()))
    return () => clearTimeout(id)
  }, [timing, open])

  // The only per-frame work, written straight to the DOM node. During the telegraph the
  // bar fills toward the opening; after it, it drains toward the deadline.
  useEffect(() => {
    let raf = 0
    const tick = () => {
      const el = barRef.current
      if (el) {
        const now = Date.now()
        if (now < timing.opensAt) {
          const span = Math.max(1, state.windowOpensIn)
          el.style.width = `${Math.min(100, (1 - (timing.opensAt - now) / span) * 100)}%`
        } else {
          const span = Math.max(1, timing.closesAt - timing.opensAt)
          el.style.width = `${Math.max(0, (timing.closesAt - now) / span) * 100}%`
        }
      }
      raf = requestAnimationFrame(tick)
    }
    raf = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(raf)
  }, [timing, state.windowOpensIn])

  // The fish changes its mind, visibly, and always before the window opens.
  useEffect(() => {
    if (timing.switchAt === undefined || !state.nextCue) return
    const id = setTimeout(() => { setShown(state.nextCue as FishAction); setFaked(true) },
      Math.max(0, timing.switchAt - Date.now()))
    return () => clearTimeout(id)
  }, [timing, state.nextCue])

  // The turn expired and the player chose nothing. The server decides what that means.
  useEffect(() => {
    if (outcome) return
    const id = setTimeout(() => { fetchNui('encounterAction', { action: 'advance' }) },
      Math.max(0, timing.closesAt - Date.now()) + 300)
    return () => clearTimeout(id)
  }, [timing, outcome])

  useEffect(() => {
    if (!outcome) return
    const id = setTimeout(() => fetchNui('encounterClosed', {}), 700)
    return () => clearTimeout(id)
  }, [outcome])

  const cue = ACTIONS[shown]
  const danger = state.linePct <= 33 || state.pressure >= state.escapeThreshold - 1
  const riskPct = Math.min(100, (state.pressure / Math.max(1, state.escapeThreshold)) * 100)
  const readPct = Math.min(100, (state.progress / Math.max(1, state.reads)) * 100)

  return (
    <div className={`hud-panel enc-panel mg-panel${danger ? ' hud-panel--danger' : ''}`}>
      <div className="panel-title">{t('enc_mg_title')}</div>

      <div className={`mg-cue${faked ? ' mg-cue--faked' : ''}`} role="status">
        <span className="enc-glyph" aria-hidden="true">{cue.glyph}</span>
        <span className="enc-cue-text">{t(cue.label)}</span>
      </div>

      <div className={`bar-track enc-window${open ? '' : ' enc-window--shut'}`}>
        <div className="bar-fill enc-window-fill" ref={barRef} />
      </div>

      <div className={`mg-responses${open ? '' : ' mg-responses--shut'}`}>
        {RESPONSES.map((r) => (
          <div className="mg-response" key={r.key}>
            <Keycap label={r.key} />
            <span className="mg-response-text">{t(r.label)}</span>
          </div>
        ))}
      </div>

      <div className="bar-row">
        <div className="bar-label">{t('enc_mg_reads')}</div>
        <div className="bar-caption mg-reads">{state.progress}/{state.reads}</div>
      </div>
      <div className="bar-track"><div className="bar-fill energy-fill" style={{ width: `${readPct}%` }} /></div>

      <div className="bar-row">
        <div className="bar-label">{t('enc_line')}</div>
        <div className="bar-caption">{state.linePct}%</div>
      </div>
      <div className="bar-track"><div className="bar-fill enc-line-fill" style={{ width: `${state.linePct}%` }} /></div>

      <div className="bar-row">
        <div className="bar-label">{t('enc_mg_pressure')}</div>
        <div className="bar-caption mg-risk">{state.pressure}/{state.escapeThreshold}</div>
      </div>
      <div className="bar-track"><div className="bar-fill enc-risk-fill" style={{ width: `${riskPct}%` }} /></div>

      {outcome && <div className="enc-outcome">{t(`enc_outcome_${outcome}`)}</div>}
    </div>
  )
}
