import { describe, it, expect, beforeAll, afterEach, vi } from 'vitest'
import { render, cleanup, waitFor } from '@testing-library/react'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import RigMenu from '../components/RigMenu'
import type { RigView, CatalogEntry } from '../rigRows'

// fetchNui: mock ให้ resolve ทันที เพื่อให้ loadLocale() ใน RigMenu จบเร็ว -> ready=true
// (คง useNuiEvent จริง; ใน jsdom fetch จริงจะพยายามยิงไป https://zfishing/... แล้วค้าง)
vi.mock('../hooks/useNui', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../hooks/useNui')>()
  return { ...actual, fetchNui: vi.fn().mockResolvedValue({}) }
})

// ────────────────────────────────────────────────────────────────────────────
// Feature: fishing-rig-menu-hud-style-fix (bugfix)
// Property 1 (Bug Condition -> Expected Behavior): Rig_Menu โปร่งใส + text-shadow
//
// For any RenderContext ที่เข้าเงื่อนไขบั๊กด้วย surface = 'rig_menu' (isBugCondition = true)
// เมนูที่แก้แล้ว (RigMenu') SHALL เรนเดอร์โดย:
//   - ไม่มีพื้นหลังทึบ (no solid background: var(--bg))
//   - ไม่มีเส้นขอบกล่อง / border-left accent (no box border)
//   - ไม่มี box-shadow
//   - ไม่มี backdrop blur ที่ทำให้เกิดกล่องทึบ
//   - ตัวอักษร (title / row label) มี text-shadow ในสไตล์เดียวกับ HUD ตกปลา
//
// Scoped bug condition: กรณี deterministic ตายตัว (surface = 'rig_menu')
//
// **CRITICAL**: test นี้ต้อง FAIL บนโค้ด UNFIXED (ยืนยันว่าบั๊กมีจริง) — ห้ามแก้ code/test
//
// Validates: Requirements 2.1, 2.2 (Property 1 ใน design.md)
// ────────────────────────────────────────────────────────────────────────────

// อ่าน style.css จริง แล้วฉีดเป็น <style> ให้ jsdom parse เป็น stylesheet
// หมายเหตุ: jsdom getComputedStyle ไม่ resolve var()/backdrop-filter ได้น่าเชื่อถือ
// จึงตรวจ CSS rule ที่ apply กับ .rig-menu โดยตรงจาก document.styleSheets แทน
// (deterministic และสะท้อนสิ่งที่คอมโพเนนต์ใช้จริง)
// vitest cwd = web/ ; style.css อยู่ที่ src/style.css
const CSS_TEXT = readFileSync(resolve(process.cwd(), 'src/style.css'), 'utf-8')

beforeAll(() => {
  const styleEl = document.createElement('style')
  styleEl.textContent = CSS_TEXT
  document.head.appendChild(styleEl)
})

afterEach(() => cleanup())

// หา CSSStyleRule ตาม selectorText ที่ตรงกัน จากทุก stylesheet ในเอกสาร
function findRule(selector: string): CSSStyleRule | null {
  for (const sheet of Array.from(document.styleSheets)) {
    let rules: CSSRuleList
    try {
      rules = sheet.cssRules
    } catch {
      continue
    }
    for (const rule of Array.from(rules)) {
      if ((rule as CSSStyleRule).selectorText === selector) return rule as CSSStyleRule
    }
  }
  return null
}

// Rig_View ขั้นต่ำที่ valid: มีเบ็ด, ยังไม่ประกอบชิ้นส่วน, ไม่มีชิ้นสำรอง
const MINIMAL_VIEW: RigView = {
  rod: 'rod_basic',
  rodLabel: 'Basic Rod',
  parts: {},
  carried: { reel: [], line: [], hook: [], float: [] },
}
const MINIMAL_CATALOG: CatalogEntry[] = [
  { partType: 'reel', name: 'reel_cheap', label: 'Cheap Reel' },
]

describe('Rig_Menu HUD style (bug condition exploration)', () => {
  it('renders RigMenu with the .rig-menu surface', async () => {
    const { container } = render(<RigMenu view={MINIMAL_VIEW} catalog={MINIMAL_CATALOG} />)
    await waitFor(() => {
      expect(container.querySelector('.rig-menu')).not.toBeNull()
    })
  })

  it('Property 1: .rig-menu มีพื้นหลังโปร่งใส — ไม่มี solid bg / box border / box-shadow / backdrop blur', async () => {
    const { container } = render(<RigMenu view={MINIMAL_VIEW} catalog={MINIMAL_CATALOG} />)
    await waitFor(() => {
      expect(container.querySelector('.rig-menu')).not.toBeNull()
    })

    const menu = findRule('.rig-menu')
    expect(menu).not.toBeNull()
    const css = menu!.style.cssText

    // no solid background (ไม่ยึด dark ground เดิม var(--bg))
    expect(css).not.toContain('var(--bg)')
    // no box border / border-left accent
    expect(css).not.toContain('var(--border)')
    expect(css).not.toContain('var(--accent)')
    // no box-shadow
    expect(css).not.toContain('box-shadow')
    // no backdrop blur ที่ทำให้เกิดกล่องทึบ
    expect(css).not.toContain('backdrop-filter')
  })

  it('Property 1: .rig-menu__title และ .rig-row__label มี text-shadow (สไตล์ HUD ตกปลา)', async () => {
    const { container } = render(<RigMenu view={MINIMAL_VIEW} catalog={MINIMAL_CATALOG} />)
    await waitFor(() => {
      expect(container.querySelector('.rig-menu')).not.toBeNull()
    })

    const title = findRule('.rig-menu__title')
    const categoryTitle = findRule('.rig-category-card__title')
    expect(title).not.toBeNull()
    expect(categoryTitle).not.toBeNull()

    expect(title!.style.cssText).toContain('text-shadow')
    expect(categoryTitle!.style.cssText).toContain('text-shadow')
  })
})
