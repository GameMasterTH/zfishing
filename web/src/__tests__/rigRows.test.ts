import { describe, it, expect } from 'vitest'
import fc from 'fast-check'
import {
  buildRigRows,
  groupRigCategories,
  formatOwned,
  isDimmed,
  resolveRigAction,
  resolveNotifyKey,
  PART_ORDER,
  type PartType,
  type CatalogEntry,
  type RigView,
  type RigRow,
} from '../rigRows'

// generators ที่ใช้ร่วมกันหลาย property
const partTypeArb: fc.Arbitrary<PartType> = fc.constantFrom('reel', 'line', 'hook', 'float')

// pool ชื่อเล็ก ๆ เพื่อให้ catalog/carried/parts มีโอกาสชื่อตรงกัน + ปน string อิสระ (รวมค่าว่าง)
const nameArb: fc.Arbitrary<string> = fc.oneof(
  fc.constantFrom('reel_cheap', 'line_10', 'hook_2', 'float_wood', 'a', 'b', ''),
  fc.string({ maxLength: 6 }),
)

// ค่า owned ครอบคลุม input space: จำนวนเต็ม, ทศนิยม, ค่าลบ, ศูนย์
const ownedArb: fc.Arbitrary<number> = fc.oneof(
  fc.integer({ min: -50, max: 50 }),
  fc.double({ min: -50, max: 50, noNaN: true }),
  fc.constant(0),
)

// Feature: fishing-rig-menu-nui, Property 1: การประกอบแถวถูกต้องและ deterministic
//
// For any Rig_View และ catalog ใด ๆ (มี item ซ้ำ/ขาด/ว่าง), ผลจาก buildRigRows จะต้อง:
//   (ก) จำนวนแถว = จำนวน entry ใน catalog (หนึ่งต่อหนึ่ง)
//   (ข) เรียงตาม PART_ORDER แล้วภายใน partType เรียงชื่อ ascending และคงที่/deterministic
//   (ค) owned >= 0 และเท่ากับจำนวน entry ใน carried[partType] ที่ชื่อตรงกัน
//   (ง) fitted เป็น true ก็ต่อเมื่อ parts[partType].name === row.name
//
// Validates: Requirements 2.2
describe('buildRigRows', () => {
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

  // parts/carried เป็น partial (บาง partType อาจขาด) เพื่อทดสอบกรณี missing
  const partsArb = fc.record(
    { reel: partArb, line: partArb, hook: partArb, float: partArb },
    { requiredKeys: [] },
  )

  const carriedArb = fc.record(
    {
      reel: fc.array(carriedItemArb, { maxLength: 5 }),
      line: fc.array(carriedItemArb, { maxLength: 5 }),
      hook: fc.array(carriedItemArb, { maxLength: 5 }),
      float: fc.array(carriedItemArb, { maxLength: 5 }),
    },
    { requiredKeys: [] },
  )

  const viewArb = fc.record({
    rod: fc.string({ maxLength: 6 }),
    rodLabel: fc.string({ maxLength: 6 }),
    parts: partsArb,
    carried: carriedArb,
  })

  const catalogEntryArb: fc.Arbitrary<CatalogEntry> = fc.record({
    partType: partTypeArb,
    name: nameArb,
    label: fc.string({ maxLength: 6 }),
  })

  const catalogArb = fc.array(catalogEntryArb, { maxLength: 20 })

  it('Property 1: row count, ordering, owned, fitted ถูกต้องและ deterministic', () => {
    fc.assert(
      fc.property(viewArb, catalogArb, (rawView, catalog) => {
        const view = rawView as unknown as RigView
        const rows = buildRigRows(view, catalog)

        // (ก) หนึ่งแถวต่อหนึ่ง entry ใน catalog
        expect(rows).toHaveLength(catalog.length)

        // (ข) ลำดับ: PART_ORDER ก่อน แล้วชื่อ ascending
        for (let i = 1; i < rows.length; i++) {
          const prev = rows[i - 1]
          const cur = rows[i]
          const orderDiff = PART_ORDER.indexOf(prev.partType) - PART_ORDER.indexOf(cur.partType)
          if (orderDiff === 0) {
            // partType เดียวกัน -> ชื่อ ascending (localeCompare <= 0)
            expect(prev.name.localeCompare(cur.name)).toBeLessThanOrEqual(0)
          } else {
            expect(orderDiff).toBeLessThan(0)
          }
        }

        // (ข) deterministic: เรียกซ้ำด้วย input เดิมได้ผลเหมือนกันทุกประการ
        expect(buildRigRows(view, catalog)).toEqual(rows)

        // (ค)(ง) ตรวจ owned/fitted รายแถว
        for (const row of rows) {
          const carried = view.carried?.[row.partType] ?? []
          const expectedOwned = carried.filter((it) => it.name === row.name).length
          expect(row.owned).toBe(expectedOwned)
          expect(row.owned).toBeGreaterThanOrEqual(0)

          const expectedFitted = view.parts?.[row.partType]?.name === row.name
          expect(row.fitted).toBe(expectedFitted)
        }
      }),
      { numRuns: 100 },
    )
  })
})

// Feature: fishing-rig-menu-nui, Property 2: การจัดรูปแบบจำนวนที่ถือ
//
// For any จำนวน n (จำนวนเต็ม, ทศนิยม, ค่าลบ, ค่ามากกว่า 9999, รวมถึง NaN/Infinity),
// ผลจาก formatOwned(n) ต้องอยู่ในรูปแบบ `Nx` โดย N เป็นจำนวนเต็ม clamp 0..9999
// (ค่าลบ/NaN → 0, ค่ามากกว่า 9999 → 9999)
//
// Validates: Requirements 2.3
describe('formatOwned', () => {
  const nArb = fc.oneof(
    fc.integer(),
    fc.double(), // รวม NaN / ±Infinity ตาม default ของ fast-check
    fc.integer({ min: -1_000_000, max: -1 }), // ค่าลบ
    fc.integer({ min: 10_000, max: 1_000_000 }), // > 9999
    fc.double({ min: 10_000, max: 1e9, noNaN: true }), // ทศนิยม > 9999
  )

  it('Property 2: รูปแบบ Nx โดย N เป็นจำนวนเต็ม clamp 0..9999', () => {
    fc.assert(
      fc.property(nArb, (n) => {
        const result = formatOwned(n)

        // จัดการ NaN เหมือน module (NaN → 0) แล้ว clamp + floor
        const safe = Number.isNaN(n) ? 0 : n
        const expectedN = Math.floor(Math.min(9999, Math.max(0, safe)))
        expect(result).toBe(`${expectedN}x`)

        // ตรวจซ้ำเชิงโครงสร้าง: รูปแบบ `<int>x` และ N อยู่ในช่วง 0..9999
        const match = /^(\d+)x$/.exec(result)
        expect(match).not.toBeNull()
        const parsed = Number(match![1])
        expect(parsed).toBeGreaterThanOrEqual(0)
        expect(parsed).toBeLessThanOrEqual(9999)
      }),
      { numRuns: 100 },
    )
  })
})

// Feature: fishing-rig-menu-nui, Property 3: การจางของแถวสัมพันธ์กับจำนวนที่ถือ
//
// For any owned ใด ๆ, isDimmed(owned) เป็น true ก็ต่อเมื่อ owned === 0 และ
// opacity ที่ derive (isDimmed ? 0.5 : 1) ต้อง ≤ 0.5 เมื่อ dimmed และ = 1.0 เมื่อไม่ dimmed
//
// Validates: Requirements 2.5, 2.6
describe('isDimmed', () => {
  it('Property 3: dim ก็ต่อเมื่อ owned === 0 และ opacity สอดคล้อง', () => {
    fc.assert(
      fc.property(ownedArb, (owned) => {
        const dimmed = isDimmed(owned)
        expect(dimmed).toBe(owned === 0)

        // derive opacity เหมือนที่ component ทำ
        const opacity = dimmed ? 0.5 : 1
        if (dimmed) {
          expect(opacity).toBeLessThanOrEqual(0.5)
        } else {
          expect(opacity).toBe(1.0)
        }
      }),
      { numRuns: 100 },
    )
  })
})

// Feature: fishing-rig-menu-nui, Property 4: การตัดสิน action จากแถว
//
// For any RigRow ใด ๆ, resolveRigAction(row) ต้องเป็น:
//   detach เมื่อ fitted; attach (partType+itemName) เมื่อไม่ fitted และ owned > 0;
//   blocked เมื่อไม่ fitted และ owned === 0 (หรือ <= 0)
//
// Validates: Requirements 4.1, 4.2, 4.3
describe('resolveRigAction', () => {
  const rigRowArb: fc.Arbitrary<RigRow> = fc.record({
    partType: partTypeArb,
    name: nameArb,
    label: fc.string({ maxLength: 6 }),
    owned: ownedArb,
    fitted: fc.boolean(),
  })

  it('Property 4: detach/attach/blocked ตามสถานะ fitted และ owned', () => {
    fc.assert(
      fc.property(rigRowArb, (row) => {
        const action = resolveRigAction(row)

        if (row.fitted) {
          expect(action).toEqual({ kind: 'detach', partType: row.partType })
        } else if (row.owned > 0) {
          expect(action).toEqual({ kind: 'attach', partType: row.partType, itemName: row.name })
        } else {
          expect(action).toEqual({ kind: 'blocked' })
        }
      }),
      { numRuns: 100 },
    )
  })
})

// Feature: fishing-rig-menu-nui, Property 5: การ map ผลลัพธ์ callback เป็น locale key
//
// For any ผลลัพธ์ callback ({ok:true}, {ok:false, err:'inv_full'}, {ok:false, err:<อื่น>}, 'timeout')
// × kind (attach/detach), ค่า key ต้องเป็น:
//   attached/detached เมื่อ ok (ตาม kind); rig_inv_full เมื่อ err==='inv_full';
//   rig_error สำหรับ err อื่น ๆ และ timeout
//
// Validates: Requirements 4.5, 4.6, 4.7, 4.8
describe('resolveNotifyKey', () => {
  const kindArb: fc.Arbitrary<'attach' | 'detach'> = fc.constantFrom('attach', 'detach')

  const resultArb: fc.Arbitrary<{ ok: boolean; err?: string } | 'timeout'> = fc.oneof(
    fc.constant('timeout' as const),
    fc.constant({ ok: true }),
    fc.record({ ok: fc.constant(false), err: fc.constant('inv_full') }),
    fc.record({
      ok: fc.constant(false),
      err: fc.oneof(
        fc.string().filter((s) => s !== 'inv_full'),
        fc.constant(undefined),
      ),
    }),
  )

  it('Property 5: attached/detached, rig_inv_full, rig_error ตาม branch', () => {
    fc.assert(
      fc.property(kindArb, resultArb, (kind, result) => {
        const key = resolveNotifyKey(kind, result)

        let expected: string
        if (result === 'timeout') {
          expected = 'rig_error'
        } else if (result.ok) {
          expected = kind === 'attach' ? 'attached' : 'detached'
        } else if (result.err === 'inv_full') {
          expected = 'rig_inv_full'
        } else {
          expected = 'rig_error'
        }

        expect(key).toBe(expected)
      }),
      { numRuns: 100 },
    )
  })
})

describe('groupRigCategories', () => {
  it('groups items into 4 categories and aggregates carried instances with durability', () => {
    const view: RigView = {
      rod: 'fishing_rod_common',
      rodLabel: 'Bamboo Rod',
      parts: {
        reel: { name: 'reel_carbon', label: 'Carbon Reel', dur: 100, max: 100 },
      },
      carried: {
        reel: [],
        line: [],
        hook: [],
        float: [
          { slot: 10, name: 'float_wood', label: 'Wood Float', dur: 50, max: 50 },
          { slot: 12, name: 'float_wood', label: 'Wood Float', dur: 45, max: 50 },
        ],
      },
    }

    const catalog: CatalogEntry[] = [
      { partType: 'reel', name: 'reel_carbon', label: 'Carbon Reel' },
      { partType: 'float', name: 'float_wood', label: 'Wood Float' },
    ]

    const categories = groupRigCategories(view, catalog)
    expect(categories).toHaveLength(4)

    const floatCat = categories.find((c) => c.partType === 'float')
    expect(floatCat).toBeDefined()
    expect(floatCat?.items).toHaveLength(1)

    const woodFloatGroup = floatCat?.items[0]
    expect(woodFloatGroup?.name).toBe('float_wood')
    expect(woodFloatGroup?.totalOwned).toBe(2)
    expect(woodFloatGroup?.instances).toHaveLength(2)
    expect(woodFloatGroup?.instances[0].dur).toBe(50)
    expect(woodFloatGroup?.instances[1].dur).toBe(45)
  })
})

