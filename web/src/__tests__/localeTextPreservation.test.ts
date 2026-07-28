import { describe, it, expect, vi } from 'vitest'
import fc from 'fast-check'
import { resolvePromptText } from '../promptText'
import { rigText } from '../rigText'

// dict ที่คุมได้ต่อ iteration — inject ผ่าน mock ของ i18n เพื่อคุมพฤติกรรม tOr
// (dict จริงใน i18n.ts เป็น module-private ไม่มี setter จึงต้อง mock)
// mirror พฤติกรรมจริง: tOr(key, fallback) = dict[key] ?? fallback
let mockDict: Record<string, string> = {}
vi.mock('../i18n', () => ({
  tOr: (key: string, fallback: string) => mockDict[key] ?? fallback,
}))

// ────────────────────────────────────────────────────────────────────────────
// Feature: fishing-rig-menu-hud-style-fix (bugfix)
// Property 3 (Preservation): Input นอกเงื่อนไขบั๊กไม่เปลี่ยนแปลง
//
// For any input ที่ไม่เข้าเงื่อนไขบั๊ก (isBugCondition = false) โค้ดที่แก้แล้ว (F')
// SHALL ให้ผลลัพธ์เหมือนโค้ดเดิม (F) ทุกประการ
//
// การแก้บั๊กแตะเฉพาะค่า equip_hint (locale + FALLBACK) เท่านั้น ดังนั้น prompt key
// อื่น ๆ (equip_title / cancel_title / cancel_hint) และ rig key ทั้งหมด ต้องคง
// พฤติกรรมเดิม — สังเกต baseline บนโค้ด UNFIXED แล้ว encode ไว้ที่นี่
//
// **EXPECTED**: PASS บนโค้ด UNFIXED (ยืนยัน baseline ที่ต้องคงไว้)
//
// Validates: Requirements 3.2, 3.3 (Property 3 ใน design.md)
// ────────────────────────────────────────────────────────────────────────────

// Baseline ที่ observe จากโค้ด unfixed (promptText.ts FALLBACK) — ไม่รวม equip_hint
// ซึ่งเป็น bug condition key ที่การแก้จะเปลี่ยนค่า
const PROMPT_BASELINE_FALLBACK: Record<string, string> = {
  equip_title: 'Fishing',
  cancel_title: 'Reeling',
  cancel_hint: '[X] Pack up rod',
}
const PRESERVED_PROMPT_KEYS = ['equip_title', 'cancel_title', 'cancel_hint'] as const

// Baseline ที่ observe จากโค้ด unfixed (rigText.ts FALLBACK + GENERIC_FALLBACK)
const RIG_BASELINE_FALLBACK: Record<string, string> = {
  rig_title: 'Manage Rod',
  rig_close_hint: 'Press ESC to close',
  rig_empty: 'No rod parts to manage',
  rig_locale_error: 'Language failed to load',
}
const RIG_GENERIC_FALLBACK = 'Manage Rod'
const RIG_KEYS = ['rig_title', 'rig_close_hint', 'rig_empty', 'rig_locale_error'] as const

// ค่าใน dict: ข้อความจริง (ไม่บังเอิญเท่ากับ key), สตริงว่าง, หรือช่องว่างล้วน
const valueArb = fc.oneof(
  fc.string({ maxLength: 20 }),
  fc.constant(''),
  fc.stringOf(fc.constantFrom(' ', '\t', '\n', '\r'), { minLength: 1, maxLength: 10 }),
)

// dict สุ่ม: key สุ่ม (อาจมีหรือไม่มี target key) + ค่าตาม valueArb
const dictArb = fc.dictionary(fc.string({ maxLength: 12 }), valueArb)

// baseline behavior ของ resolvePromptText ที่ observe จากโค้ด unfixed:
//   คืน dict value เมื่อ non-empty หลัง trim มิฉะนั้นคืน baseline fallback
function expectedResolvePrompt(dict: Record<string, string>, key: string): string {
  const raw = dict[key]
  if (typeof raw === 'string' && raw.trim().length > 0) return raw
  return PROMPT_BASELINE_FALLBACK[key]
}

// baseline behavior ของ rigText ที่ observe จากโค้ด unfixed
function expectedRigText(dict: Record<string, string>, key: string): string {
  const raw = dict[key]
  if (typeof raw === 'string' && raw.trim().length > 0) return raw
  return RIG_BASELINE_FALLBACK[key] ?? RIG_GENERIC_FALLBACK
}

describe('Preservation: resolvePromptText (prompt keys นอกเงื่อนไขบั๊ก)', () => {
  const keyArb = fc.constantFrom(...PRESERVED_PROMPT_KEYS)

  it('Property 3: equip_title / cancel_title / cancel_hint คืนค่าเท่ากับ baseline ทุก dict state', () => {
    fc.assert(
      fc.property(dictArb, keyArb, (dict, key) => {
        mockDict = dict
        const resolved = resolvePromptText(key)

        // เท่ากับพฤติกรรมเดิมที่ observe บนโค้ด unfixed ทุกประการ
        expect(resolved).toBe(expectedResolvePrompt(dict, key))
        // ไม่คืน raw key และไม่คืนสตริงว่าง (คงเดิม)
        expect(resolved).not.toBe(key)
        expect(resolved.trim().length).toBeGreaterThan(0)
      }),
      { numRuns: 100 },
    )
  })

  it('Property 3: ค่า fallback คงที่เมื่อ dict ว่าง (baseline snapshot)', () => {
    mockDict = {}
    expect(resolvePromptText('equip_title')).toBe('Fishing')
    expect(resolvePromptText('cancel_title')).toBe('Reeling')
    expect(resolvePromptText('cancel_hint')).toBe('[X] Pack up rod')
  })
})

describe('Preservation: rigText (rig keys ทั้งหมด)', () => {
  const rigKeyArb = fc.constantFrom(...RIG_KEYS)

  it('Property 3: rig key ทั้งหมดคืนค่าเท่ากับ baseline ทุก dict state', () => {
    fc.assert(
      fc.property(dictArb, rigKeyArb, (dict, key) => {
        mockDict = dict
        const resolved = rigText(key)

        expect(resolved).toBe(expectedRigText(dict, key))
        expect(resolved).not.toBe(key)
        expect(resolved.trim().length).toBeGreaterThan(0)
      }),
      { numRuns: 100 },
    )
  })

  it('Property 3: ค่า fallback คงที่เมื่อ dict ว่าง (baseline snapshot)', () => {
    mockDict = {}
    expect(rigText('rig_title')).toBe('Manage Rod')
    expect(rigText('rig_close_hint')).toBe('Press ESC to close')
    expect(rigText('rig_empty')).toBe('No rod parts to manage')
    expect(rigText('rig_locale_error')).toBe('Language failed to load')
  })
})

describe('Preservation: locale fallback ของ key อื่น (ที่ไม่ใช่ equip_hint)', () => {
  // key จาก input space จริง: locale key ที่ระบบใช้จริง (ทั้งที่มีใน FALLBACK และไม่มี)
  // ยกเว้น equip_hint ซึ่งเป็น bug condition key — locale key จริงเป็น identifier
  // [a-z_] เสมอ ไม่มีทางเป็น prototype property เช่น toString/constructor
  const otherKeyArb = fc
    .constantFrom(
      'equip_title',
      'cancel_title',
      'cancel_hint',
      'rig_title',
      'rig_close_hint',
      'rig_empty',
      'rig_locale_error',
      'attached',
      'detached',
      'rig_error',
      'rig_inv_full',
      'unknown_key',
      'foo_bar',
    )
    .filter((k) => k !== 'equip_hint')

  it('Property 3: resolvePromptText/rigText ไม่คืน raw key สำหรับ key อื่น ทุก dict state', () => {
    fc.assert(
      fc.property(dictArb, otherKeyArb, (dict, key) => {
        mockDict = dict

        // resolvePromptText: ถ้า dict มีค่า non-empty -> คืนค่านั้น มิฉะนั้นคืน fallback
        // (fallback ของ key ที่ไม่รู้จัก = '' ตามพฤติกรรมเดิม) แต่ต้องไม่คืน raw key
        const raw = dict[key]
        const hasValue = typeof raw === 'string' && raw.trim().length > 0

        const promptResolved = resolvePromptText(key)
        if (hasValue) {
          expect(promptResolved).toBe(raw)
        }
        expect(promptResolved).not.toBe(key)

        // rigText: ไม่คืน raw key และไม่คืนสตริงว่างเสมอ (คงเดิม)
        const rigResolved = rigText(key)
        if (hasValue) {
          expect(rigResolved).toBe(raw)
        }
        expect(rigResolved).not.toBe(key)
        expect(rigResolved.trim().length).toBeGreaterThan(0)
      }),
      { numRuns: 100 },
    )
  })
})
