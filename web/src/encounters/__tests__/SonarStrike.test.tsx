import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { act, render } from '@testing-library/react'
import SonarStrike from '../SonarStrike'

const posted: { event: string; data: any }[] = []
vi.mock('../../hooks/useNui', () => ({
  fetchNui: (event: string, data?: unknown) => {
    posted.push({ event, data })
    return Promise.resolve({})
  },
}))

const base = (over: Record<string, unknown> = {}) => ({
  phaseId: 1, attempt: 1, maxAttempts: 6,
  hits: 0, requiredHits: 5, misses: 0, maxMisses: 2,
  passStartsIn: 700, passEndsIn: 3100, duration: 2400, hold: 0,
  profile: 'GHOST', dir: 1 as const, k: 0, weakHalf: 0.1, perfectHalf: 0.0375,
  target: 0.5, floatTier: 1,
  ...over,
})

beforeEach(() => { posted.length = 0; vi.useFakeTimers() })
afterEach(() => { vi.useRealTimers() })

describe('SonarStrike', () => {
  it('draws the real track, fixed target, safe band and perfect band', () => {
    render(<SonarStrike state={base()} outcome={null} />)
    expect(document.querySelector('.sonar-lane')).not.toBeNull()
    expect(document.querySelector('.sonar-target')).not.toBeNull()
    expect(document.querySelector('.sonar-fish--real')).not.toBeNull()
    expect(document.querySelector('.sonar-band--safe')).not.toBeNull()
    expect(document.querySelector('.sonar-band--perfect')).not.toBeNull()
    expect(document.querySelector('.sonar-line')).toBeNull()
  })

  it('draws a GHOST decoy from its own timeline without a strike band', () => {
    render(<SonarStrike state={base({ decoy: { k: 0.3, dir: -1, hold: 0, duration: 1200, crossAt: 600 } })} outcome={null} />)
    const decoy = document.querySelector('.sonar-fish--decoy')!
    expect(decoy).not.toBeNull()
    expect(decoy.querySelector('.sonar-band')).toBeNull()
  })

  it('uses the float tier only as a clarity class', () => {
    const { container, rerender } = render(<SonarStrike state={base({ floatTier: 1 })} outcome={null} />)
    expect(container.querySelector('.sonar-panel')!.className).toContain('sonar-float--1')
    rerender(<SonarStrike state={base({ phaseId: 2, floatTier: 3 })} outcome={null} />)
    expect(container.querySelector('.sonar-panel')!.className).toContain('sonar-float--3')
  })

  it('uses a device-neutral strike prompt instead of a keyboard keycap', () => {
    render(<SonarStrike state={base()} outcome={null} />)
    expect(document.querySelector('.sonar-prompt')!.textContent!.length).toBeGreaterThan(0)
    expect(document.querySelector('.sonar-prompt .keycap')).toBeNull()
  })

  it('posts one neutral advance only after the current pass has expired', () => {
    const { rerender } = render(<SonarStrike state={base()} outcome={null} />)
    act(() => { vi.advanceTimersByTime(3300) })
    expect(posted.filter((p) => p.data?.action === 'advance')).toHaveLength(0)
    act(() => { vi.advanceTimersByTime(200) })
    expect(posted.filter((p) => p.data?.action === 'advance')).toHaveLength(1)
    rerender(<SonarStrike state={base({ phaseId: 2 })} outcome={null} />)
    act(() => { vi.advanceTimersByTime(3500) })
    expect(posted.filter((p) => p.data?.action === 'advance')).toHaveLength(2)
  })

  it('shows grade and outcome, then only closes presentation', () => {
    render(<SonarStrike state={base({ lastGrade: 'perfect' })} outcome="success" />)
    expect(document.querySelector('.sonar-grade')!.textContent!.length).toBeGreaterThan(0)
    expect(document.querySelector('.enc-outcome')!.textContent!.length).toBeGreaterThan(0)
    act(() => { vi.advanceTimersByTime(800) })
    expect(posted.some((p) => p.event === 'encounterClosed')).toBe(true)
    expect(posted.some((p) => p.event === 'encounterDone')).toBe(false)
  })

  it('never submits a timing, position, grade or reward claim', () => {
    render(<SonarStrike state={base()} outcome={null} />)
    act(() => { vi.advanceTimersByTime(4000) })
    for (const p of posted) {
      const keys = Object.keys(p.data ?? {})
      expect(keys).toEqual(['action'])
      expect(p.data.action).toBe('advance')
    }
  })
})
