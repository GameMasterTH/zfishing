import { describe, it, expect, vi } from 'vitest'
import fc from 'fast-check'
import { rigText } from '../rigText'

// dict ที่คุมได้ต่อ iteration — inject ผ่าน mock ของ i18n เพื่อคุมพฤติกรรม tOr
// (dict จริงใน i18n.ts เป็น module-private ไม่มี setter จึงต้อง mock)
// mirror พฤติกรรมจริง: tOr(key, fallback) = dict[key] ?? fallback
let mockDict: Record<string, string> = {}
vi.mock('../i18n', () => ({
  tOr: (key: string, fallback: string) => mockDict[key] ?? fallback,
}))

// Feature: fishing-rig-menu-nui, Property 6: การ resolve ข้อความ locale มี fallback เสมอ
//
// For any locale dictionary ใด ๆ (มีหรือไม่มี key, ค่าเป็นข้อความจริง/ว่าง/ช่องว่างล้วน)
// และ key ของ Rig_Menu (รวม key ที่ไม่รู้จัก) ผลลัพธ์จาก rigText จะต้อง:
//   - คืนค่าจาก dictionary เมื่อค่านั้นเป็นข้อความที่ไม่ว่าง (หลัง trim)
//   - มิฉะนั้นคืนค่า fallback ที่กำหนดไว้ล่วงหน้าในโค้ด
//   - ไม่คืน raw key และไม่คืนสตริงว่างในทุกกรณี
//
// Validates: Requirements 6.3, 6.4
describe('rigText', () => {
  // key ที่มี fallback เฉพาะใน FALLBACK ของ rigText.ts
  const RIG_KEYS = ['rig_title', 'rig_close_hint', 'rig_empty', 'rig_locale_error'] as const
  // key ที่ไม่รู้จัก -> ต้องตกไปที่ GENERIC_FALLBACK
  const UNKNOWN_KEYS = ['rig_unknown', 'totally_missing', 'xyz'] as const
  const ALL_KEYS = [...RIG_KEYS, ...UNKNOWN_KEYS] as const

  // fallback ที่คาดหวัง (ตรงกับตาราง FALLBACK + GENERIC_FALLBACK ใน rigText.ts)
  const FALLBACK: Record<string, string> = {
    rig_title: 'Manage Rod',
    rig_close_hint: 'Press ESC to close',
    rig_empty: 'No rod parts to manage',
    rig_locale_error: 'Language failed to load',
  }
  const GENERIC_FALLBACK = 'Manage Rod'
  const expectedFallback = (key: string) => FALLBACK[key] ?? GENERIC_FALLBACK

  const keyArb = fc.constantFrom(...ALL_KEYS)

  // ค่าใน dict: ข้อความจริง (ไม่เท่ากับ key ใด ๆ เพื่อไม่ให้ค่าจริงบังเอิญเท่ากับ raw key),
  // สตริงว่าง, หรือช่องว่างล้วน
  const valueArb = fc.oneof(
    fc.string().filter((s) => !(ALL_KEYS as readonly string[]).includes(s)),
    fc.constant(''),
    fc.stringOf(fc.constantFrom(' ', '\t', '\n', '\r'), { minLength: 1, maxLength: 10 }),
  )

  // dict สุ่ม: key จาก ALL_KEYS (บาง key อาจหายไป = missing) + ค่าตาม valueArb
  const dictArb = fc.dictionary(fc.constantFrom(...ALL_KEYS), valueArb)

  it('Property 6: คืน dict value เมื่อไม่ว่าง มิฉะนั้นคืน fallback, ไม่เท่ากับ raw key และไม่ว่าง', () => {
    fc.assert(
      fc.property(dictArb, keyArb, (dict, key) => {
        mockDict = dict
        const resolved = rigText(key)

        const raw = dict[key]
        const hasValue = typeof raw === 'string' && raw.trim().length > 0

        if (hasValue) {
          // มีค่าจริงใน dict -> คืนค่านั้น
          expect(resolved).toBe(raw)
        } else {
          // ไม่มี key / ว่าง / ช่องว่างล้วน -> คืน fallback ที่กำหนดไว้ล่วงหน้า
          expect(resolved).toBe(expectedFallback(key))
        }

        // ในทุกกรณี: ไม่คืน raw key และไม่คืนสตริงว่าง
        expect(resolved).not.toBe(key)
        expect(resolved.trim().length).toBeGreaterThan(0)
      }),
      { numRuns: 100 },
    )
  })
})
