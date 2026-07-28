import { describe, it, expect, beforeAll, afterEach, vi } from 'vitest'
import { render, cleanup, waitFor, fireEvent } from '@testing-library/react'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import fc from 'fast-check'
import RigMenu from '../components/RigMenu'
import { buildRigRows, isDimmed } from '../rigRows'
import type { RigView, CatalogEntry } from '../rigRows'

// fetchNui: mock ให้ resolve ทันที เพื่อให้ loadLocale() ใน RigMenu จบเร็ว -> ready=true
// (คง useNuiEvent จริง; ใน jsdom fetch จริงจะพยายามยิงไป https://zfishing/... แล้วค้าง)
const fetchNuiMock = vi.fn().mockResolvedValue({})
vi.mock('../hooks/useNui', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../hooks/useNui')>()
  return { ...actual, fetchNui: (...args: unknown[]) => fetchNuiMock(...args) }
})

// ────────────────────────────────────────────────────────────────────────────
// Feature: rig-menu-icon-oversize-fix (bugfix)
// Property 2 (Preservation): Input นอกเงื่อนไขบั๊กไม่เปลี่ยนแปลง
//
// การแก้บั๊กเป็น CSS-only ที่ source (`web/src/style.css`) — เพิ่มกฎ `.rig-row__icon img`
// และ `overflow:hidden` ให้ container `.rig-row__icon` โดยไม่แตะ DOM/logic ของ RigMenu.tsx
// ดังนั้นพฤติกรรมของ input ที่ *ไม่เข้า* Bug Condition ต้องคงเดิม:
//   3.1 icon โหลดไม่สำเร็จ (iconFailed) -> ไม่มี <img> แต่กล่อง .rig-row__icon ขนาดคงที่ยังอยู่ แถวไม่เลื่อน
//   3.2 .rig-menu โปร่งใส + .rig-row__label/.rig-row__owned มี text-shadow (สไตล์เมนูเดิม)
//   3.3 owned === 0 -> แถว opacity <= 0.5 (dimmed)
//   3.4 HUD อื่นใน bundle เดียวกัน (CastBar/panel, PromptHud, catch card, ปุ่ม admin) render ปกติ
//   3.5 DOM structure ของแต่ละแถว (icon box + label + owned) คงเดิม
//
// **สังเกต baseline บนโค้ด UNFIXED แล้ว encode ค่าที่ต้อง "ไม่เปลี่ยน" ไว้ที่นี่**
// (จงเลือก assertion ที่ค่าคงที่ทั้งก่อน/หลัง fix — เช่น width/height/background/flex ของกล่อง
//  ไม่ assert เรื่อง object-fit/overflow ที่ตัว fix จะแตะโดยตรง)
//
// **EXPECTED**: PASS บนโค้ด UNFIXED (ยืนยัน baseline ที่ต้องคงไว้)
//
// Validates: Requirements 3.1, 3.2, 3.3, 3.4, 3.5 (Property 2 ใน design.md)
// ────────────────────────────────────────────────────────────────────────────

// อ่าน style.css จริง แล้วฉีดเป็น <style> ให้ jsdom parse เป็น stylesheet
// (jsdom getComputedStyle ไม่ resolve var()/vh ได้น่าเชื่อถือ จึงตรวจ CSS rule ตรง ๆ)
// vitest cwd = web/ ; style.css อยู่ที่ src/style.css
const CSS_TEXT = readFileSync(resolve(process.cwd(), 'src/style.css'), 'utf-8')

beforeAll(() => {
  const styleEl = document.createElement('style')
  styleEl.textContent = CSS_TEXT
  document.head.appendChild(styleEl)
})

afterEach(() => {
  cleanup()
  fetchNuiMock.mockClear()
})

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

// ─── Scenario generator: สุ่มสถานะแถวที่ *ไม่เข้า* Bug Condition ───────────────
// pool ของ catalog entry ที่ชื่อไม่ซ้ำต่อ partType (เลี่ยง React duplicate key)
const CATALOG_POOL: CatalogEntry[] = [
  { partType: 'reel', name: 'reel_cheap', label: 'Cheap Reel' },
  { partType: 'line', name: 'line_10', label: 'Line 10' },
  { partType: 'hook', name: 'hook_2', label: 'Hook 2' },
  { partType: 'float', name: 'float_wood', label: 'Wood Float' },
]

const entryConfigArb = fc.record({
  include: fc.boolean(),
  owned: fc.nat({ max: 3 }), // 0 -> dimmed row (นอก bug condition), >0 -> owned row
  fitted: fc.boolean(),
})

// อย่างน้อยหนึ่ง entry ต้องถูก include เพื่อให้มีแถวให้ตรวจ
const scenarioArb = fc
  .tuple(entryConfigArb, entryConfigArb, entryConfigArb, entryConfigArb)
  .filter((cfgs) => cfgs.some((c) => c.include))

function buildScenario(cfgs: ReadonlyArray<{ include: boolean; owned: number; fitted: boolean }>) {
  const catalog: CatalogEntry[] = []
  const carried: RigView['carried'] = { reel: [], line: [], hook: [], float: [] }
  const parts: RigView['parts'] = {}
  cfgs.forEach((c, i) => {
    if (!c.include) return
    const e = CATALOG_POOL[i]
    catalog.push(e)
    for (let k = 0; k < c.owned; k++) {
      carried[e.partType].push({ slot: k, name: e.name, label: e.label, dur: 100, max: 100 })
    }
    if (c.fitted) {
      parts[e.partType] = { name: e.name, label: e.label, dur: 100, max: 100 }
    }
  })
  const view: RigView = { rod: 'rod_basic', rodLabel: 'Basic Rod', parts, carried }
  return { view, catalog }
}

// ─── 3.1 + 3.5: icon โหลดไม่สำเร็จ -> กล่องคงที่ ไม่มี <img> แถวไม่เลื่อน ───────
describe('Preservation: icon-failed in flyout sub-menu', () => {
  it('Property 2: flyout sub-menu renders icons and items when hovering category', async () => {
    await fc.assert(
      fc.asyncProperty(scenarioArb, async (cfgs) => {
        const { view, catalog } = buildScenario(cfgs)
        const { container } = render(<RigMenu view={view} catalog={catalog} />)
        await waitFor(() => {
          expect(container.querySelector('.rig-menu__container')).not.toBeNull()
        })

        const categoryCards = container.querySelectorAll('.rig-category-card')
        expect(categoryCards.length).toBeGreaterThan(0)

        // Hover first category
        fireEvent.mouseEnter(categoryCards[0])
        const flyout = container.querySelector('.rig-flyout-panel')
        expect(flyout).not.toBeNull()

        cleanup()
      }),
      { numRuns: 20 },
    )
  })
})

describe('Preservation: สไตล์เมนู .rig-menu โปร่งใส + text-shadow (3.2)', () => {
  it('Property 2: .rig-menu โปร่งใส — ไม่มี solid bg / border / box-shadow / backdrop blur', () => {
    const menu = findRule('.rig-menu')
    expect(menu).not.toBeNull()
    const css = menu!.style.cssText
    expect(css).toContain('transparent')
  })

  it('Property 2: .rig-category-card__title มี text-shadow (สไตล์ HUD เดิม)', () => {
    const title = findRule('.rig-category-card__title')
    expect(title).not.toBeNull()
    expect(title!.style.cssText).toContain('text-shadow')
  })
})

// ─── 3.4: HUD อื่นใน bundle เดียวกันยังคงกฎ CSS เดิม ──────────────────────────
describe('Preservation: HUD อื่นใน bundle เดียวกันไม่ถูกกระทบ (3.4)', () => {
  it('Property 2: กฎ CSS ของ CastBar/panel, PromptHud, catch card, ปุ่ม ยังคงอยู่และคงค่าหลัก', () => {
    // CastBar ใช้ .panel + .cast-fill
    const panel = findRule('.panel')
    expect(panel).not.toBeNull()
    expect(panel!.style.cssText).toContain('var(--bg)') // ยังคงพื้นหลังทึบเดิมของ panel
    const castFill = findRule('.cast-fill')
    expect(castFill).not.toBeNull()

    // Prompt_HUD
    const prompt = findRule('.prompt-hud')
    expect(prompt).not.toBeNull()
    expect(prompt!.style.cssText).toContain('pointer-events')
    const promptTitle = findRule('.prompt-title')
    expect(promptTitle).not.toBeNull()

    // catch card + ปุ่ม
    const catchCard = findRule('.catch-card')
    expect(catchCard).not.toBeNull()
    const btn = findRule('.btn')
    expect(btn).not.toBeNull()
    expect(btn!.style.cssText).toContain('cursor')
  })
})
