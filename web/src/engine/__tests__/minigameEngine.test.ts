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
      baseDrain: 12,
      reelTimeout: 28000,
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
      baseDrain: 12,
      reelTimeout: 28000,
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
      baseDrain: 12,
      reelTimeout: 28000,
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

// Both constants used to live in two places at once: the engine hard-coded the
// base drain (12) and a 28s timeout, while server/session.lua validated claims
// against its own copies. They now arrive through EngineConfig from the bite
// payload, so these assert the engine actually honours what it is handed.
const base = {
  behavior: 'steady_light' as const,
  tensionDiff: 1,
  fishEnergy: 100,
  greenZone: 1,        // widest possible green band, so holding stays in it
  snapFactor: 10,      // effectively no snapping during the test
  drainRate: 1,
  fishWeight: 5,
  baseDrain: 12,
  reelTimeout: 28000,
}

describe('injected minigame constants', () => {
  it('drains faster with a larger baseDrain', () => {
    const slow = new MinigameEngine({ ...base, baseDrain: 12 })
    const fast = new MinigameEngine({ ...base, baseDrain: 24 })
    let t = 0
    for (let i = 0; i < 60; i++) { t += 100; slow.tick(0.1, true, t); fast.tick(0.1, true, t) }
    expect(fast.tick(0, true, t).energy).toBeLessThan(slow.tick(0, true, t).energy)
  })

  it('times out at the configured reelTimeout, not a hard-coded 28s', () => {
    const engine = new MinigameEngine({ ...base, reelTimeout: 10000 })
    const state = engine.tick(0.016, false, 10_050)
    expect(state.isFinished).toBe(true)
    expect(state.finishReason).toBe('timeout')
  })
})
