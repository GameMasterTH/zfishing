import type { CSSProperties } from 'react'
import { useEffect, useMemo, useRef, useState } from 'react'
import { fetchNui } from '../hooks/useNui'
import { t } from '../i18n'
import Keycap from '../components/Keycap'
import type { CounterPullPhase, CounterPullState, Outcome } from './types'

// Direction, glyph and key per phase. Every cue is carried by shape, motion and text as
// well as position -- never by colour alone.
const CUES: Record<CounterPullPhase, { glyph: string; key: string; label: string; dir: -1 | 0 | 1 }> = {
  LEFT_RUN:  { glyph: '◀', key: 'D',     label: 'enc_cp_left',  dir: -1 },
  RIGHT_RUN: { glyph: '▶', key: 'A',     label: 'enc_cp_right', dir: 1 },
  DIVE:      { glyph: '▼', key: 'S',     label: 'enc_cp_dive',  dir: 0 },
  FATIGUED:  { glyph: '⟳', key: 'SPACE', label: 'enc_cp_reel',  dir: 0 },
  LANDING:   { glyph: '⤒', key: 'SPACE', label: 'enc_cp_land',  dir: 0 },
}

export default function CounterPull(
  { state, outcome }: { state: CounterPullState; outcome: Outcome | null }
) {
  // One deterministic anchoring per authoritative phase, keyed on phaseId -- a phase can
  // repeat with an identical name and identical durations, and a ref mutated inside an
  // effect would leave the other effects reading the previous anchor.
  const timing = useMemo(() => {
    const receivedAt = Date.now()
    return {
      opensAt: receivedAt + state.windowOpensIn,
      closesAt: receivedAt + state.windowClosesIn,
      switchAt: state.switchIn === undefined ? undefined : receivedAt + state.switchIn,
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [state.phaseId])

  const [shown, setShown] = useState<CounterPullPhase>(state.cue)
  const barRef = useRef<HTMLDivElement | null>(null)

  useEffect(() => { setShown(state.cue) }, [state.phaseId, state.cue])

  // The only per-frame work, and it writes straight to the DOM node. Going through
  // React here would re-render the whole panel sixty times a second to move one bar.
  useEffect(() => {
    let raf = 0
    const tick = () => {
      const el = barRef.current
      if (el) {
        const span = Math.max(1, timing.closesAt - timing.opensAt)
        const p = Math.min(1, Math.max(0, (Date.now() - timing.opensAt) / span))
        el.style.width = `${(1 - p) * 100}%`
      }
      raf = requestAnimationFrame(tick)
    }
    raf = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(raf)
  }, [timing])

  // The fish visibly changes its mind. A state change, not a frame update.
  useEffect(() => {
    if (timing.switchAt === undefined || !state.nextCue) return
    const id = setTimeout(() => setShown(state.nextCue as CounterPullPhase),
      Math.max(0, timing.switchAt - Date.now()))
    return () => clearTimeout(id)
  }, [timing, state.nextCue])

  // Our window expired and the player did nothing. Tell the server once per phase; it
  // decides what that means, and refuses this outright if its own deadline has not
  // passed. Re-armed by phaseId, so a repeated phase advances too.
  useEffect(() => {
    if (outcome) return
    const id = setTimeout(() => {
      fetchNui('encounterAction', { action: 'advance' })
    }, Math.max(0, timing.closesAt - Date.now()) + 300)
    return () => clearTimeout(id)
  }, [timing, outcome])

  // Presentation close only. The client already settled the catch; this just reports
  // that the ending has played.
  useEffect(() => {
    if (!outcome) return
    const id = setTimeout(() => fetchNui('encounterClosed', {}), 700)
    return () => clearTimeout(id)
  }, [outcome])

  const cue = CUES[shown]
  const danger = state.linePct <= 33 || state.misses >= state.maxMisses - 1

  return (
    <div className={`hud-panel enc-panel${danger ? ' hud-panel--danger' : ''}`}>
      <div className="panel-title">{t('enc_cp_title')}</div>

      <div className="enc-stage" style={{ '--lean': String(cue.dir) } as CSSProperties}>
        <div className={`enc-cue enc-cue--${shown.toLowerCase()}`} role="status">
          <span className="enc-glyph" aria-hidden="true">{cue.glyph}</span>
          <span className="enc-cue-text">{t(cue.label)}</span>
        </div>
        <div className="enc-key"><Keycap label={cue.key} variant="urgent" /></div>
      </div>

      <div className="bar-track enc-window"><div className="bar-fill enc-window-fill" ref={barRef} /></div>

      <div className="bar-row">
        <div className="bar-label">{t('enc_stamina')}</div>
        <div className="bar-caption">{state.staminaPct}%</div>
      </div>
      <div className="bar-track"><div className="bar-fill energy-fill" style={{ width: `${state.staminaPct}%` }} /></div>

      <div className="bar-row">
        <div className="bar-label">{t('enc_line')}</div>
        <div className="bar-caption">{state.misses}/{state.maxMisses}</div>
      </div>
      <div className="bar-track"><div className="bar-fill enc-line-fill" style={{ width: `${state.linePct}%` }} /></div>

      {outcome && <div className="enc-outcome">{t(`enc_outcome_${outcome}`)}</div>}
    </div>
  )
}
