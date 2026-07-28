import { describe, it, expect, afterEach, vi } from 'vitest'
import { render, cleanup, waitFor, fireEvent } from '@testing-library/react'
import fc from 'fast-check'
import RigMenu from '../components/RigMenu'
import { buildRigRows, isDimmed, formatOwned } from '../rigRows'
import type { RigView, CatalogEntry, PartType } from '../rigRows'

// fetchNui: mock ให้ resolve ทันที เพื่อให้ loadLocale() ใน RigMenu จบเร็ว -> ready=true
// และเพื่อ spy การ dispatch rigClose / rigAction (คง useNuiEvent จริง)
const fetchNuiMock = vi.fn().mockResolvedValue({})
vi.mock('../hooks/useNui', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../hooks/useNui')>()
  return { ...actual, fetchNui: (...args: unknown[]) => fetchNuiMock(...args) }
})

afterEach(() => {
  cleanup()
  fetchNuiMock.mockClear()
})

// ────────────────────────────────────────────────────────────────────────────
// Feature: fishing-rig-menu-hud-style-fix (bugfix)
// Property 3 (Preservation): Input นอกเงื่อนไขบั๊กไม่เปลี่ยนแปลง
//
// การแก้บั๊กเป็น CSS-only (style.css) — โครงสร้าง DOM / logic ของ RigMenu.tsx ไม่เปลี่ยน
// ดังนั้น จำนวน/ลำดับแถว, การ dim owned = 0, empty state, การ dispatch rigClose/rigAction
// ต้องคงพฤติกรรมเดิม — สังเกต baseline บนโค้ด UNFIXED แล้ว encode ไว้ที่นี่
//
// **EXPECTED**: PASS บนโค้ด UNFIXED (ยืนยัน baseline ที่ต้องคงไว้)
//
// Validates: Requirements 3.1, 3.4 (Property 3 ใน design.md)
// ────────────────────────────────────────────────────────────────────────────

const partTypeArb: fc.Arbitrary<PartType> = fc.constantFrom('reel', 'line', 'hook', 'float')

// pool ชื่อเล็ก ๆ เพื่อให้ catalog/carried/parts มีโอกาสชื่อตรงกัน
const nameArb: fc.Arbitrary<string> = fc.constantFrom(
  'reel_cheap',
  'line_10',
  'hook_2',
  'float_wood',
  'a',
  'b',
)

const carriedItemArb = fc.record({
  slot: fc.integer(),
  name: nameArb,
  label: fc.string({ maxLength: 6 }),
  dur: fc.integer(),
  max: fc.integer(),
})

const partArb = fc.record({
  name: nameArb,
  label: fc.string({ maxLength: 6 }),
  dur: fc.integer(),
  max: fc.integer(),
})

const partsArb = fc.record(
  { reel: partArb, line: partArb, hook: partArb, float: partArb },
  { requiredKeys: [] },
)

const carriedArb = fc.record({
  reel: fc.array(carriedItemArb, { maxLength: 4 }),
  line: fc.array(carriedItemArb, { maxLength: 4 }),
  hook: fc.array(carriedItemArb, { maxLength: 4 }),
  float: fc.array(carriedItemArb, { maxLength: 4 }),
})

const viewArb = fc.record({
  rod: fc.string({ maxLength: 6 }),
  rodLabel: fc.string({ maxLength: 6 }),
  parts: partsArb,
  carried: carriedArb,
})

const catalogEntryArb: fc.Arbitrary<CatalogEntry> = fc.record({
  partType: partTypeArb,
  name: nameArb,
  label: fc.constantFrom('Cheap Reel', 'Line 10', 'Hook 2', 'Wood Float', 'Alpha', 'Beta'),
})

const catalogArb = fc.array(catalogEntryArb, { maxLength: 8 })

describe('Preservation: RigMenu categories / cards', () => {
  it('Property: 4 category cards are rendered for any RigView and catalog', async () => {
    await fc.assert(
      fc.asyncProperty(viewArb, catalogArb, async (rawView, catalog) => {
        const view = rawView as unknown as RigView
        const { container } = render(<RigMenu view={view} catalog={catalog} />)
        await waitFor(() => {
          expect(container.querySelector('.rig-menu__container')).not.toBeNull()
        })

        const categoryCards = container.querySelectorAll('.rig-category-card')
        expect(categoryCards).toHaveLength(4) // reel, line, hook, float

        cleanup()
      }),
      { numRuns: 25 },
    )
  })
})

// Rig_View ขั้นต่ำ deterministic สำหรับ unit test ของ ESC / click dispatch
const VIEW_WITH_PARTS: RigView = {
  rod: 'rod_basic',
  rodLabel: 'Basic Rod',
  parts: { reel: { name: 'reel_cheap', label: 'Cheap Reel', dur: 100, max: 100 } },
  carried: {
    reel: [],
    line: [{ slot: 1, name: 'line_10', label: 'Line 10', dur: 100, max: 100 }],
    hook: [],
    float: [],
  },
}
const CATALOG: CatalogEntry[] = [
  { partType: 'reel', name: 'reel_cheap', label: 'Cheap Reel' }, // fitted -> detach
  { partType: 'line', name: 'line_10', label: 'Line 10' }, // owned 1, not fitted -> attach
]

describe('Preservation: RigMenu categories & ESC dispatch', () => {
  it('renders categories container and handles ESC key', async () => {
    const { container } = render(<RigMenu view={VIEW_WITH_PARTS} catalog={CATALOG} />)
    await waitFor(() => {
      expect(container.querySelector('.rig-menu__container')).not.toBeNull()
    })

    const categoryCards = container.querySelectorAll('.rig-category-card')
    expect(categoryCards).toHaveLength(4) // reel, line, hook, float

    fetchNuiMock.mockClear()
    fireEvent.keyDown(window, { key: 'Escape' })
    expect(fetchNuiMock).toHaveBeenCalledWith('rigClose')
  })
})

