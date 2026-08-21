import { useEffect, useMemo, useRef } from 'react'
import { fetchNui } from '../hooks/useNui'
import { t } from '../i18n'
import { weakAt } from '../engine/sonarTimeline'
import type { Outcome, SonarDecoy, SonarState } from './types'

const pct = (value: number) => `${Math.max(0, Math.min(100, value * 100))}%`

function blipTransform(pass: { duration: number; hold: number; k: number; dir: 1 | -1 }, elapsed: number) {
  return `translateX(${pct(weakAt(pass, elapsed))}) translateX(-50%)`
}

export default function SonarStrike({ state, outcome }: { state: SonarState; outcome: Outcome | null }) {
  // Browser time only animates the already-public picture. A phase id re-anchors all
  // local timers so an identical-looking next pass cannot inherit the prior pass clock.
  const timing = useMemo(() => {
    const receivedAt = Date.now()
    return {
      startsAt: receivedAt + state.passStartsIn,
      endsAt: receivedAt + state.passEndsIn,
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [state.phaseId])
  const realRef = useRef<HTMLDivElement | null>(null)
  const decoyRef = useRef<HTMLDivElement | null>(null)

  useEffect(() => {
    const pass = { duration: state.duration, hold: state.hold, k: state.k, dir: state.dir }
    const decoy: SonarDecoy | undefined = state.decoy
    let raf = 0
    const tick = () => {
      const elapsed = Date.now() - timing.startsAt
      if (realRef.current) realRef.current.style.transform = blipTransform(pass, elapsed)
      if (decoyRef.current && decoy) decoyRef.current.style.transform = blipTransform(decoy, elapsed)
      raf = requestAnimationFrame(tick)
    }
    raf = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(raf)
  }, [state.phaseId, state.duration, state.hold, state.k, state.dir, state.decoy, timing])

  useEffect(() => {
    if (outcome) return
    const id = setTimeout(() => fetchNui('encounterAction', { action: 'advance' }),
      Math.max(0, timing.endsAt - Date.now()) + 300)
    return () => clearTimeout(id)
  }, [timing, outcome])

  useEffect(() => {
    if (!outcome) return
    const id = setTimeout(() => fetchNui('encounterClosed', {}), 700)
    return () => clearTimeout(id)
  }, [outcome])

  const safeWidth = pct(state.weakHalf * 2)
  const perfectWidth = pct(state.perfectHalf * 2)
  const grade = state.lastGrade && t(`enc_ss_${state.lastGrade}`)
  const danger = state.misses >= state.maxMisses - 1
  const status = state.notReady ? t('enc_ss_reacquire') : t(`enc_ss_${state.profile.toLowerCase()}`)

  return (
    <div className={`hud-panel enc-panel sonar-panel sonar-float--${state.floatTier}${danger ? ' hud-panel--danger' : ''}`}>
      <div className="panel-title">{t('enc_ss_title')}</div>
      <div className="sonar-status" role="status">{status}</div>
      <div className="sonar-prompt">◉ {t('enc_ss_strike')}</div>

      <div className="sonar-lane" aria-label={t('enc_ss_lane')}>
        <div className="sonar-target" aria-hidden="true" />
        <div className="sonar-fish sonar-fish--real" ref={realRef}>
          <div className="sonar-band sonar-band--safe" style={{ width: safeWidth }} />
          <div className="sonar-band sonar-band--perfect" style={{ width: perfectWidth }} />
          <span className="sonar-blip" aria-hidden="true">◉</span>
        </div>
        {state.decoy && (
          <div className="sonar-fish sonar-fish--decoy" ref={decoyRef}>
            <span className="sonar-blip" aria-hidden="true">○</span>
          </div>
        )}
      </div>

      <div className="bar-row"><div className="bar-label">{t('enc_ss_hits')}</div><div className="bar-caption">{state.hits}/{state.requiredHits}</div></div>
      <div className="bar-track"><div className="bar-fill energy-fill" style={{ width: pct(state.hits / Math.max(1, state.requiredHits)) }} /></div>
      <div className="bar-row"><div className="bar-label">{t('enc_ss_misses')}</div><div className="bar-caption">{state.misses}/{state.maxMisses}</div></div>
      <div className="bar-track"><div className="bar-fill enc-risk-fill" style={{ width: pct(state.misses / Math.max(1, state.maxMisses)) }} /></div>
      {grade && <div className={`sonar-grade sonar-grade--${state.lastGrade}`}>{grade}</div>}
      {outcome && <div className="enc-outcome">{t(`enc_outcome_${outcome}`)}</div>}
    </div>
  )
}
