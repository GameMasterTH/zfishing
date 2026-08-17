import { useEffect, useRef, useState } from 'react'
import { fetchNui } from '../hooks/useNui'
import { t } from '../i18n'
import { MinigameEngine } from '../engine/minigameEngine'
import { renderWithKeycaps } from './Keycap'

type Props = {
  behavior: 'steady_light' | 'steady_heavy' | 'run_stop' | 'erratic'
  tensionDiff: number
  fishEnergy: number
  greenZone: number
  snapFactor: number
  drainRate: number // reel quality: multiplies how fast the fish tires (1 = base)
  fishWeight: number // actual rolled weight in kg — drives green zone amplitude & speed
  holding: boolean
}

export default function TensionMinigame(props: Props) {
  const engineRef = useRef<MinigameEngine | null>(null)
  if (!engineRef.current) {
    engineRef.current = new MinigameEngine(props)
  }

  const [state, setState] = useState(() => engineRef.current!.tick(0, props.holding, 0))
  const holdingRef = useRef(props.holding)
  holdingRef.current = props.holding
  const doneRef = useRef(false)

  useEffect(() => {
    let raf = 0
    let last = performance.now()
    const start = last

    const finish = (success: boolean, reason?: 'snap' | 'timeout' | 'escape') => {
      if (doneRef.current) return
      doneRef.current = true
      fetchNui('reelResult', { success, reason, durationMs: Math.round(performance.now() - start) })
    }

    const tick = (now: number) => {
      const dt = Math.min(0.05, (now - last) / 1000)
      last = now
      const elapsed = now - start

      const currentState = engineRef.current!.tick(dt, holdingRef.current, elapsed)
      setState(currentState)

      if (currentState.shouldStreamEnergy) {
        fetchNui('reelEnergy', { pct: currentState.energy / props.fishEnergy })
      }

      if (currentState.isFinished) {
        const isSuccess = currentState.finishReason === 'success'
        return finish(isSuccess, currentState.finishReason === 'success' ? undefined : currentState.finishReason)
      }

      raf = requestAnimationFrame(tick)
    }

    raf = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(raf)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  // อยู่ในโซนเขียวไหม — เป็น boolean ที่ derive จาก state ทำให้ class เปลี่ยนเฉพาะตอน
  // ข้ามขอบเขต ไม่ใช่ทุก frame ส่วนตำแหน่ง (left/width) ยังเป็น inline style ล้วน ๆ
  const inZone = state.tension >= state.greenLo && state.tension <= state.greenHi

  return (
    <div className={`hud-panel reel-panel${state.overTension ? ' hud-panel--danger danger' : ''}`}>
      <div className="panel-title">{renderWithKeycaps(t('ui_reel_title'))}</div>

      <div className="bar-label">{t('ui_reel_tension')}</div>
      <div className="bar-track tension-track">
        <div
          className={`green-zone${inZone ? ' green-zone--hit' : ''}`}
          style={{ left: `${state.greenLo}%`, width: `${state.greenHi - state.greenLo}%` }}
        />
        <div
          className={`tension-marker${state.overTension ? ' danger' : ''}`}
          style={{ left: `${state.tension}%` }}
        />
      </div>

      <div className="bar-row">
        <div className="bar-label">{t('ui_reel_energy')}</div>
        <div className="bar-caption">{Math.round(state.energyPct)}%</div>
      </div>
      <div className="bar-track">
        <div className="bar-fill energy-fill" style={{ width: `${state.energyPct}%` }} />
      </div>
    </div>
  )
}
