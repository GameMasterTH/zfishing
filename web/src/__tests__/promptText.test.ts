import { describe, it, expect, vi } from 'vitest'
import fc from 'fast-check'
import { prepareLines, MAX_LINE, resolvePromptText } from '../promptText'

// dict ที่คุมได้ต่อ iteration — inject ผ่าน mock ของ i18n เพื่อคุมพฤติกรรม tOr
// (dict จริงใน i18n.ts เป็น module-private ไม่มี setter จึงต้อง mock)
let mockDict: Record<string, string> = {}
vi.mock('../i18n', () => ({
  // mirror พฤติกรรมจริง: คืน dict[key] ถ้ามี มิฉะนั้นคืน fallback
  tOr: (key: string, fallback: string) => mockDict[key] ?? fallback,
}))

// Feature: fishing-prompt-hud, Property 1: การเตรียมบรรทัด prompt กรองบรรทัดว่างและตัดความยาว
//
// For any คู่ค่า title และ subtitle (string ใด ๆ รวมถึงสตริงว่าง, ช่องว่างล้วน,
// null, หรือข้อความยาวเกิน 120 ตัวอักษร) ผลลัพธ์จาก prepareLines จะต้อง:
//   - ไม่มีบรรทัดว่าง/ช่องว่างล้วน/null-source หลงเหลือ (ถูกแทนด้วย null)
//   - ทุกบรรทัดที่ไม่ใช่ null ยาว ≤ MAX_LINE (120)
//   - บรรทัดที่ source มีข้อความจริง ต้องคงไว้ (ไม่ถูกทำเป็น null)
//
// Validates: Requirements 1.7, 1.8
describe('prepareLines', () => {
  // generator ครอบคลุม input space: string ทั่วไป, ว่าง, whitespace ล้วน, null, ยาวเกิน 120
  const lineSource = fc.oneof(
    fc.string(),
    fc.constant(''),
    fc.stringOf(fc.constantFrom(' ', '\t', '\n', '\r'), { minLength: 1, maxLength: 10 }),
    fc.constant(null),
    fc.string({ minLength: 121, maxLength: 300 }),
  )

  it('Property 1: กรองบรรทัดว่าง/null และตัดความยาวไม่เกิน MAX_LINE', () => {
    fc.assert(
      fc.property(lineSource, lineSource, (title, subtitle) => {
        const result = prepareLines(title, subtitle)

        // ผลลัพธ์ต้องเป็น tuple 2 ช่องเสมอ
        expect(result).toHaveLength(2)

        const sources = [title, subtitle]
        result.forEach((line, i) => {
          const src = sources[i]

          if (line === null) {
            // ถ้าผลเป็น null แสดงว่า source ต้องเป็น null/ว่าง/ช่องว่างล้วน
            expect(src == null || src.trim().length === 0).toBe(true)
          } else {
            // บรรทัดที่ไม่ใช่ null: ต้องไม่ว่างหลัง trim และยาว ≤ MAX_LINE
            expect(line.trim().length).toBeGreaterThan(0)
            expect(line.length).toBeLessThanOrEqual(MAX_LINE)
            // source ที่มีข้อความจริงต้องถูกคงไว้ (ไม่กลายเป็น null)
            expect(src != null && src.trim().length > 0).toBe(true)
          }
        })
      }),
      { numRuns: 100 },
    )
  })
})

// Feature: fishing-prompt-hud, Property 2: การ resolve ข้อความ prompt มี fallback เสมอ
//
// For any locale dictionary ใด ๆ (มีหรือไม่มี key, ค่าเป็นข้อความจริง/ว่าง/ช่องว่างล้วน)
// และ key ของ prompt (equip_title/equip_hint/cancel_title/cancel_hint) ผลลัพธ์จาก
// resolvePromptText จะต้อง:
//   - คืนค่าจาก dictionary เมื่อค่านั้นเป็นข้อความที่ไม่ว่าง (หลัง trim)
//   - มิฉะนั้นคืนค่า fallback ที่กำหนดไว้ล่วงหน้า
//   - ไม่คืน raw key และไม่คืนสตริงว่าง
//
// Validates: Requirements 2.7, 4.4
describe('resolvePromptText', () => {
  const PROMPT_KEYS = ['equip_title', 'equip_hint', 'cancel_title', 'cancel_hint'] as const

  // fallback ที่คาดหวัง (ตรงกับตาราง FALLBACK ใน promptText.ts)
  const FALLBACK: Record<string, string> = {
    equip_title: 'Fishing',
    equip_hint: '[E] Start fishing   ·   [X] Pack up rod   ·   [G] Manage Rod',
    cancel_title: 'Reeling',
    cancel_hint: '[X] Pack up rod',
  }

  const keyArb = fc.constantFrom(...PROMPT_KEYS)

  // ค่าใน dict: ข้อความจริง (ไม่เท่ากับ prompt key เพื่อไม่ให้ค่าจริงบังเอิญเท่ากับ raw key),
  // สตริงว่าง, หรือช่องว่างล้วน
  const valueArb = fc.oneof(
    fc.string().filter((s) => !(PROMPT_KEYS as readonly string[]).includes(s)),
    fc.constant(''),
    fc.stringOf(fc.constantFrom(' ', '\t', '\n', '\r'), { minLength: 1, maxLength: 10 }),
  )

  // dict สุ่ม: key สุ่ม (อาจมีหรือไม่มี prompt key) + ค่าตาม valueArb
  const dictArb = fc.dictionary(fc.string(), valueArb)

  it('Property 2: คืน dict value เมื่อไม่ว่าง มิฉะนั้นคืน fallback, ไม่เท่ากับ raw key และไม่ว่าง', () => {
    fc.assert(
      fc.property(dictArb, keyArb, (dict, key) => {
        mockDict = dict
        const resolved = resolvePromptText(key)

        const raw = dict[key]
        const hasValue = typeof raw === 'string' && raw.trim().length > 0

        if (hasValue) {
          // มีค่าจริงใน dict -> คืนค่านั้น
          expect(resolved).toBe(raw)
        } else {
          // ไม่มี key / ว่าง / ช่องว่างล้วน -> คืน fallback ที่กำหนดไว้ล่วงหน้า
          expect(resolved).toBe(FALLBACK[key])
        }

        // ไม่คืน raw key และไม่คืนสตริงว่าง เสมอ
        expect(resolved).not.toBe(key)
        expect(resolved.trim().length).toBeGreaterThan(0)
      }),
      { numRuns: 100 },
    )
  })
})
