import { describe, it, expect, beforeAll, afterEach, vi } from 'vitest'
import { render, cleanup, waitFor, fireEvent } from '@testing-library/react'
import fc from 'fast-check'
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
// Feature: rig-menu-icon-oversize-fix (bugfix)
// Property 1 (Bug Condition -> Expected Behavior): Icon ย่อพอดีกล่องขนาดคงที่
//
// For any input ที่เข้า Bug Condition (isBugCondition = true — เมนูเปิด, icon โหลดสำเร็จ,
// PNG ใหญ่กว่ากล่อง, ไม่มีกฎ .rig-row__icon img, ไม่มี overflow:hidden) ระบบ SHALL เรนเดอร์
// <img> ให้ย่อพอดีกล่อง .rig-row__icon (3.2vh × 3.2vh) โดย renderedWidth/Height <= box
// และไม่ล้นไปทับ .rig-row__label / .rig-row__owned หรือแถวข้างเคียง
//
// Scoped PBT: สุ่ม imgNaturalPx หลายค่าที่ > boxPx ร่วมกับ menuOpen === true,
//             iconFailed === false (ตรงกับ isBugCondition ใน design.md)
//
// **CRITICAL**: test นี้ต้อง FAIL บนโค้ด UNFIXED (ยืนยันว่าบั๊กมีจริง) — ห้ามแก้ code/test
//
// หมายเหตุ: jsdom ไม่ทำ layout จริง (ไม่ resolve vh/%/object-fit) จึง model ขนาดที่เรนเดอร์
// จริงจากกฎ CSS ที่อ่านจาก style.css โดยตรง ซึ่งตรงกับ isBugCondition ใน design ที่รับ
// hasImgSizingRule / containerClipsOverflow เป็น input — deterministic และสะท้อน CSS จริง
//
// Validates: Requirements 1.1, 1.2, 1.3, 1.4 (Property 1 ใน design.md)
// ────────────────────────────────────────────────────────────────────────────

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

// แปลงค่าความยาว CSS (เช่น "3.2vh") เป็น px ตาม viewport ปัจจุบันของ jsdom
function cssLengthToPx(value: string): number {
  const m = value.trim().match(/^([\d.]+)(px|vh|vw)?$/)
  if (!m) return NaN
  const n = parseFloat(m[1])
  const unit = m[2] ?? 'px'
  if (unit === 'vh') return (n / 100) * window.innerHeight
  if (unit === 'vw') return (n / 100) * window.innerWidth
  return n
}

// อ่าน "ข้อเท็จจริง CSS" ที่ควบคุมการเรนเดอร์ของ <img> ภายใน .rig-row__icon
// ตรงกับ input ของ isBugCondition ใน design.md
function readCssFacts() {
  const boxRule = findRule('.rig-item-row__icon')
  const imgRule = findRule('.rig-item-row__icon img')

  const boxPx = boxRule ? (cssLengthToPx(boxRule.style.width) || 30) : 30

  const imgBlockMatch = CSS_TEXT.match(/\.rig-item-row__icon\s+img\s*\{([^}]*)\}/)
  const imgBlock = imgBlockMatch ? imgBlockMatch[1] : ''
  const imgHasObjectFitContain =
    imgRule?.style.getPropertyValue('object-fit') === 'contain' ||
    /object-fit\s*:\s*contain/.test(imgBlock)

  const hasImgSizingRule =
    !!imgRule &&
    imgHasObjectFitContain &&
    (imgRule.style.width === '100%' || imgRule.style.maxWidth === '100%') &&
    (imgRule.style.height === '100%' || imgRule.style.maxHeight === '100%')

  const containerClipsOverflow = !!boxRule && boxRule.style.overflow === 'hidden'

  return { boxPx, hasImgSizingRule, containerClipsOverflow }
}

// Model ขนาดที่เรนเดอร์จริงของ <img> จากกฎ CSS + ขนาด PNG จริง
// - ถ้ามีกฎจำกัดขนาด (width/height 100% + object-fit contain): <img> ย่อพอดีกล่อง -> boxPx
// - ถ้าไม่มี: <img> เรนเดอร์ที่ขนาด intrinsic ของ PNG -> imgNaturalPx (ล้น)
function modelRenderedPx(
  imgNaturalPx: number,
  facts: { boxPx: number; hasImgSizingRule: boolean },
): number {
  return facts.hasImgSizingRule ? Math.min(imgNaturalPx, facts.boxPx) : imgNaturalPx
}

// icon ล้นทับพื้นที่ label/owned หรือไม่: ล้นเมื่อขนาดที่เรนเดอร์เกินกล่อง
// และ container ไม่ได้ตัด overflow
function overlapsAdjacent(
  renderedPx: number,
  facts: { boxPx: number; containerClipsOverflow: boolean },
): boolean {
  return renderedPx > facts.boxPx && !facts.containerClipsOverflow
}

// Rig_View ที่ทำให้มีอย่างน้อยหนึ่งแถวที่ owned > 0 (icon โหลด -> มี <img> จริง)
const VIEW: RigView = {
  rod: 'rod_basic',
  rodLabel: 'Basic Rod',
  parts: {},
  carried: {
    reel: [{ slot: 1, name: 'reel_cheap', label: 'Cheap Reel', dur: 100, max: 100 }],
    line: [],
    hook: [],
    float: [],
  },
}
const CATALOG: CatalogEntry[] = [
  { partType: 'reel', name: 'reel_cheap', label: 'Cheap Reel' },
]

describe('Rig_Menu icon oversize (bug condition exploration)', () => {
  it('renders <img> ภายใน .rig-item-row__icon เมื่อ flyout เปิด', async () => {
    const { container } = render(<RigMenu view={VIEW} catalog={CATALOG} />)
    await waitFor(() => {
      expect(container.querySelector('.rig-menu')).not.toBeNull()
    })
    const cards = container.querySelectorAll('.rig-category-card')
    if (cards.length > 0) {
      fireEvent.mouseEnter(cards[0])
    }
    const img = container.querySelector('.rig-item-row__icon img')
    expect(img).not.toBeNull()
  })

  it('Property 1: สำหรับทุก imgNaturalPx > boxPx (menuOpen, icon โหลดสำเร็จ) <img> ต้องย่อพอดีกล่องและไม่ล้นทับ label/owned', async () => {
    const facts = readCssFacts()
    // ยืนยันว่าอ่าน boxPx ได้ (กล่องมีขนาดคงที่)
    expect(Number.isFinite(facts.boxPx)).toBe(true)
    expect(facts.boxPx).toBeGreaterThan(0)

    const boxPx = facts.boxPx

    fc.assert(
      // Scoped bug condition: PNG ใหญ่กว่ากล่องเสมอ (imgNaturalPx > boxPx)
      fc.property(
        fc.integer({ min: Math.ceil(boxPx) + 1, max: 512 }),
        (imgNaturalPx) => {
          const renderedPx = modelRenderedPx(imgNaturalPx, facts)

          // Expected Behavior: ย่อพอดีกล่อง — renderedWidth/Height <= box (R1.1, R2.1)
          expect(renderedPx).toBeLessThanOrEqual(boxPx)
          // ไม่ล้นไปทับ label/owned หรือแถวข้างเคียง (R1.2, R1.3, R2.2)
          expect(overlapsAdjacent(renderedPx, facts)).toBe(false)
        },
      ),
      { numRuns: 50 },
    )
  })
})
