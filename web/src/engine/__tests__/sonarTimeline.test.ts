import { describe, expect, it } from 'vitest'
import fixture from '../__fixtures__/sonarTimeline.json'
import { passProgress, weakAt } from '../sonarTimeline'

describe('sonarTimeline', () => {
  it('matches every Lua-generated fixture sample', () => {
    for (const sample of fixture) {
      expect(weakAt(sample, sample.t)).toBeCloseTo(sample.pos, 6)
    }
  })

  it('crosses the target at the midpoint of every monotone pass', () => {
    for (const sample of fixture) {
      const midpoint = sample.hold + (sample.duration - sample.hold) * 0.5
      expect(weakAt(sample, midpoint)).toBeCloseTo(0.5, 12)
    }
  })

  it('reverses direction while preserving elapsed progress', () => {
    const pass = { duration: 2400, hold: 120, k: -0.4, dir: 1 as const }
    const reversed = { ...pass, dir: -1 as const }
    expect(weakAt(pass, 840) + weakAt(reversed, 840)).toBeCloseTo(1, 12)
    expect(passProgress(pass, -1)).toBe(0)
    expect(passProgress(pass, 99999)).toBe(1)
  })
})
