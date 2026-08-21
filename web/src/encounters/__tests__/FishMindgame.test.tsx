import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render, act } from '@testing-library/react'
import FishMindgame from '../FishMindgame'
import type { MindgameState } from '../types'

const posted: { event: string; data: any }[] = []
vi.mock('../../hooks/useNui', () => ({
  fetchNui: (event: string, data?: unknown) => {
    posted.push({ event, data })
    return Promise.resolve({})
  },
}))

const base = (over: Partial<MindgameState> = {}): MindgameState => ({
  phaseId: 1, phase: 'TURN', cue: 'DIVE',
  telegraphIn: 0, windowOpensIn: 1150, windowClosesIn: 3150,
  progress: 0, reads: 5, linePct: 100, pressure: 0, escapeThreshold: 3,
  ...over,
})

beforeEach(() => { posted.length = 0; vi.useFakeTimers() })
afterEach(() => { vi.useRealTimers() })

describe('FishMindgame', () => {
  it('gives every fish action its own glyph and text', () => {
    const seen = new Set<string>()
    for (const cue of ['RUN', 'DIVE', 'THRASH', 'JUMP', 'REST', 'LANDING'] as const) {
      const { unmount } = render(<FishMindgame state={base({ cue })} outcome={null} />)
      const glyph = document.querySelector('.mg-cue .enc-glyph')!.textContent!
      expect(seen.has(glyph)).toBe(false)
      seen.add(glyph)
      expect(document.querySelector('.mg-cue .enc-cue-text')!.textContent!.length).toBeGreaterThan(0)
      unmount()
    }
  })

  it('always offers all four responses with their keycaps', () => {
    render(<FishMindgame state={base()} outcome={null} />)
    expect(document.querySelectorAll('.mg-response')).toHaveLength(4)
    expect(document.querySelectorAll('.mg-response .keycap')).toHaveLength(4)
  })

  it('draws the window shut for the whole telegraph, then open', () => {
    render(<FishMindgame state={base()} outcome={null} />)
    expect(document.querySelector('.mg-responses--shut')).not.toBeNull()
    expect(document.querySelector('.enc-window--shut')).not.toBeNull()
    act(() => { vi.advanceTimersByTime(1200) })
    expect(document.querySelector('.mg-responses--shut')).toBeNull()
    expect(document.querySelector('.enc-window--shut')).toBeNull()
  })

  it('reveals the real action before the window opens, never after', () => {
    render(
      <FishMindgame
        state={base({ cue: 'REST', nextCue: 'DIVE', switchIn: 600, windowOpensIn: 1150 })}
        outcome={null}
      />
    )
    const decoy = document.querySelector('.mg-cue .enc-glyph')!.textContent
    act(() => { vi.advanceTimersByTime(650) })
    const real = document.querySelector('.mg-cue .enc-glyph')!.textContent
    expect(real).not.toBe(decoy)
    expect(document.querySelector('.mg-cue--faked')).not.toBeNull()
    // The fairness property: the truth is up while answers are still being refused.
    expect(document.querySelector('.mg-responses--shut')).not.toBeNull()
  })

  it('reads the progress bar from progress and the risk bar from pressure', () => {
    // The two used to be crossed: an "Escape risk 2/3" caption over a line-health bar.
    render(<FishMindgame state={base({ progress: 2, reads: 4, linePct: 60, pressure: 2 })} outcome={null} />)
    expect(document.querySelector('.mg-reads')!.textContent).toBe('2/4')
    expect(document.querySelector('.mg-risk')!.textContent).toBe('2/3')
    const style = (sel: string) => (document.querySelector(sel) as HTMLElement).style.width
    expect(style('.energy-fill')).toBe('50%')
    expect(style('.enc-line-fill')).toBe('60%')
    expect(parseFloat(style('.enc-risk-fill'))).toBeCloseTo(66.6, 0)
  })

  it('carries the danger treatment as escape risk approaches the threshold', () => {
    const { container, rerender } = render(
      <FishMindgame state={base({ pressure: 0 })} outcome={null} />
    )
    expect(container.querySelector('.hud-panel--danger')).toBeNull()
    rerender(<FishMindgame state={base({ phaseId: 2, pressure: 2 })} outcome={null} />)
    expect(container.querySelector('.hud-panel--danger')).not.toBeNull()
  })

  it('posts advance once per turn, and re-arms for the next one', () => {
    const { rerender } = render(<FishMindgame state={base()} outcome={null} />)
    act(() => { vi.advanceTimersByTime(3000) })
    expect(posted.filter((p) => p.data?.action === 'advance')).toHaveLength(0)
    act(() => { vi.advanceTimersByTime(1000) })
    expect(posted.filter((p) => p.data?.action === 'advance')).toHaveLength(1)

    // Same phase name, same durations, different turn: phaseId is the only difference.
    rerender(<FishMindgame state={base({ phaseId: 2 })} outcome={null} />)
    act(() => { vi.advanceTimersByTime(4000) })
    expect(posted.filter((p) => p.data?.action === 'advance')).toHaveLength(2)
  })

  it('opens the landing turn with no shut phase at all', () => {
    render(
      <FishMindgame
        state={base({ phase: 'LANDING', cue: 'LANDING', windowOpensIn: 0, windowClosesIn: 2400 })}
        outcome={null}
      />
    )
    expect(document.querySelector('.mg-responses--shut')).toBeNull()
  })

  it('renders the outcome and closes the presentation', () => {
    render(<FishMindgame state={base()} outcome="escape" />)
    expect(document.querySelector('.enc-outcome')!.textContent!.length).toBeGreaterThan(0)
    act(() => { vi.advanceTimersByTime(800) })
    expect(posted.some((p) => p.event === 'encounterClosed')).toBe(true)
  })

  it('never sends the server a timing value it could trust', () => {
    render(<FishMindgame state={base()} outcome={null} />)
    act(() => { vi.advanceTimersByTime(5000) })
    for (const p of posted) {
      const keys = Object.keys(p.data ?? {})
      expect(keys.filter((k) => /At$|In$|ms$|time/i.test(k))).toHaveLength(0)
    }
  })
})
