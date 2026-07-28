import { describe, expect, it } from 'vitest'
import { MinigameEngine } from '../minigameEngine'

describe('MinigameEngine Core Physics', () => {
  it('drains energy when tension is inside green zone', () => {
    const engine = new MinigameEngine({
      behavior: 'steady_light',
      tensionDiff: 1,
      fishEnergy: 100,
      greenZone: 0.5,
      snapFactor: 1,
      drainRate: 1,
      fishWeight: 5,
    })

    const initial = engine.tick(0.01, true, 0)
    // holding = true keeps tension (~70) inside green zone (5..105) and drains energy
    const next = engine.tick(0.5, true, 500)
    expect(next.energy).toBeLessThan(initial.energy)
  })

  it('triggers line snap when tension stays above danger threshold', () => {
    const engine = new MinigameEngine({
      behavior: 'steady_heavy',
      tensionDiff: 2,
      fishEnergy: 100,
      greenZone: 0,
      snapFactor: 0.5,
      drainRate: 1,
      fishWeight: 10,
    })

    let state = engine.tick(0.05, true, 0)
    for (let i = 1; i <= 30; i++) {
      state = engine.tick(0.05, true, i * 50)
      if (state.isFinished) break
    }

    expect(state.isFinished).toBe(true)
    expect(state.finishReason).toBe('snap')
  })

  it('handles escape when damaged fish fully recovers', () => {
    const engine = new MinigameEngine({
      behavior: 'steady_light',
      tensionDiff: 1,
      fishEnergy: 100,
      greenZone: 0.5,
      snapFactor: 1,
      drainRate: 1,
      fishWeight: 5,
    })

    // Drain energy to damage fish (< 98%)
    engine.tick(0.5, true, 500)
    // Force tension below green zone (holding = false) so energy recovers quickly
    let state = engine.tick(0.05, false, 600)
    for (let i = 1; i <= 20; i++) {
      state = engine.tick(0.5, false, 600 + i * 100)
      if (state.isFinished) break
    }

    expect(state.isFinished).toBe(true)
    expect(state.finishReason).toBe('escape')
  })
})
