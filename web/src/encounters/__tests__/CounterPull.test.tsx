import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render, act } from '@testing-library/react'
import CounterPull from '../CounterPull'
import type { CounterPullState } from '../types'

const posted: { event: string; data: any }[] = []
vi.mock('../../hooks/useNui', () => ({
  fetchNui: (event: string, data?: unknown) => {
    posted.push({ event, data })
    return Promise.resolve({})
  },
}))

const base = (over: Partial<CounterPullState> = {}): CounterPullState => ({
  phaseId: 1, phase: 'LEFT_RUN', cue: 'LEFT_RUN',
  telegraphIn: 0, windowOpensIn: 800, windowClosesIn: 2000,
  staminaPct: 100, linePct: 100, misses: 0, maxMisses: 5,
  ...over,
})

beforeEach(() => { posted.length = 0; vi.useFakeTimers() })
afterEach(() => { vi.useRealTimers() })

describe('CounterPull', () => {
  it('draws a distinct glyph, text and key for every phase', () => {
    const seen = new Set<string>()
    for (const phase of ['LEFT_RUN', 'RIGHT_RUN', 'DIVE', 'FATIGUED', 'LANDING'] as const) {
      const { unmount } = render(
        <CounterPull state={base({ phase, cue: phase })} outcome={null} />
      )
      const cue = document.querySelector('.enc-cue') as HTMLElement
      expect(cue.className).toContain(phase.toLowerCase())
      const glyph = cue.querySelector('.enc-glyph')!.textContent!
      expect(seen.has(glyph)).toBe(false)   // no two phases share a glyph
      seen.add(glyph)
      expect(cue.querySelector('.enc-cue-text')!.textContent!.length).toBeGreaterThan(0)
      expect(document.querySelector('.keycap')).not.toBeNull()
      unmount()
    }
  })

  it('shows the decoy first and flips to the real cue at switchIn', () => {
    render(
      <CounterPull
        state={base({ phase: 'DIVE', cue: 'LEFT_RUN', nextCue: 'DIVE', switchIn: 600 })}
        outcome={null}
      />
    )
    expect(document.querySelector('.enc-cue')!.className).toContain('left_run')
    act(() => { vi.advanceTimersByTime(650) })
    expect(document.querySelector('.enc-cue')!.className).toContain('dive')
  })

  it('carries the danger treatment when the line is nearly gone', () => {
    const { container, rerender } = render(
      <CounterPull state={base({ linePct: 90 })} outcome={null} />
    )
    expect(container.querySelector('.hud-panel--danger')).toBeNull()
    rerender(<CounterPull state={base({ phaseId: 2, linePct: 30 })} outcome={null} />)
    expect(container.querySelector('.hud-panel--danger')).not.toBeNull()
  })

  it('posts advance exactly once after the window closes', () => {
    render(<CounterPull state={base()} outcome={null} />)
    act(() => { vi.advanceTimersByTime(1500) })
    expect(posted.filter((p) => p.data?.action === 'advance')).toHaveLength(0)
    act(() => { vi.advanceTimersByTime(1500) })
    expect(posted.filter((p) => p.data?.action === 'advance')).toHaveLength(1)
    act(() => { vi.advanceTimersByTime(5000) })
    expect(posted.filter((p) => p.data?.action === 'advance')).toHaveLength(1)
  })

  it('re-arms advance for a repeated phase with identical timings', () => {
    // The case phaseId exists for: same name, same durations, different phase.
    const { rerender } = render(<CounterPull state={base()} outcome={null} />)
    act(() => { vi.advanceTimersByTime(2400) })
    expect(posted.filter((p) => p.data?.action === 'advance')).toHaveLength(1)

    rerender(<CounterPull state={base({ phaseId: 2 })} outcome={null} />)
    act(() => { vi.advanceTimersByTime(2400) })
    expect(posted.filter((p) => p.data?.action === 'advance')).toHaveLength(2)
  })

  it('renders the outcome and closes the presentation', () => {
    render(<CounterPull state={base()} outcome="snap" />)
    expect(document.querySelector('.enc-outcome')!.textContent!.length).toBeGreaterThan(0)
    act(() => { vi.advanceTimersByTime(800) })
    expect(posted.some((p) => p.event === 'encounterClosed')).toBe(true)
    expect(posted.some((p) => p.event === 'encounterDone')).toBe(false)
  })

  it('draws the line bar from linePct and the miss bar from misses', () => {
    // These two used to share one row: a "Mistakes 2/5" caption over a line-health bar.
    render(<CounterPull state={base({ linePct: 40, misses: 2, maxMisses: 4 })} outcome={null} />)
    expect(document.querySelector('.cp-line')!.textContent).toBe('40%')
    expect(document.querySelector('.cp-misses')!.textContent).toBe('2/4')
    const style = (sel: string) => (document.querySelector(sel) as HTMLElement).style.width
    expect(style('.enc-line-fill')).toBe('40%')
    expect(style('.enc-risk-fill')).toBe('50%')
  })

  it('never sends the server a timing value it could trust', () => {
    render(<CounterPull state={base()} outcome={null} />)
    act(() => { vi.advanceTimersByTime(3000) })
    for (const p of posted) {
      const keys = Object.keys(p.data ?? {})
      expect(keys.filter((k) => /At$|In$|ms$|time/i.test(k))).toHaveLength(0)
    }
  })
})
