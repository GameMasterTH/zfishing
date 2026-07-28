import { describe, it, expect, vi } from 'vitest'
import fc from 'fast-check'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { resolvePromptText } from '../promptText'

// dict ที่คุมได้ต่อ iteration — inject ผ่าน mock ของ i18n เพื่อคุมพฤติกรรม tOr
// (dict จริงใน i18n.ts เป็น module-private ไม่มี setter จึงต้อง mock)
// mirror พฤติกรรมจริง: tOr(key, fallback) = dict[key] ?? fallback
let mockDict: Record<string, string> = {}
vi.mock('../i18n', () => ({
  tOr: (key: string, fallback: string) => mockDict[key] ?? fallback,
}))

// อ่านค่า equip_hint จริงจาก locale JSON (แหล่งเดียวกับที่ getLocale serve ลง dict)
// เพื่อให้ test สะท้อน dict value จริงหลัง getLocale โหลด — ไม่ hard-code
// vitest cwd = web/ ; locale JSON อยู่ที่ ../locales จาก web/
const thLocale = JSON.parse(
  readFileSync(resolve(process.cwd(), '../locales/th.json'), 'utf-8'),
) as Record<string, string>
const enLocale = JSON.parse(
  readFileSync(resolve(process.cwd(), '../locales/en.json'), 'utf-8'),
) as Record<string, string>

// ────────────────────────────────────────────────────────────────────────────
// Feature: fishing-rig-menu-hud-style-fix (bugfix)
// Property 2 (Bug Condition -> Expected Behavior): คำใบ้ปุ่ม G ในช่วง equip standby
//
// For any RenderContext ที่เข้าเงื่อนไขบั๊กด้วย surface = 'prompt_hud' และ
// phase = 'equip_standby' (isBugCondition = true) ค่า resolvePromptText('equip_hint')
// SHALL มีสตริง '[G]' และมีคำว่า 'จัดการเบ็ด' (ไทย) หรือ 'Manage Rod' (อังกฤษ)
// ต่อท้ายคำใบ้ [E] / [X] เดิม
//
// Scoped PBT: scope ไปที่ key = 'equip_hint' (concrete case ที่ fail แน่นอน)
// พร้อมสุ่ม dict states ครอบทั้ง:
//   - dict ว่าง {}                       -> resolvePromptText ใช้ FALLBACK ใน promptText.ts
//   - dict มีค่าไทย (locales/th.json)     -> ใช้ค่าจาก dict
//   - dict มีค่าอังกฤษ (locales/en.json)  -> ใช้ค่าจาก dict
//
// **CRITICAL**: test นี้ต้อง FAIL บนโค้ด UNFIXED (ยืนยันว่าบั๊กมีจริง) — ห้ามแก้ code/test
//
// Validates: Requirements 2.3 (Property 2 ใน design.md)
// ────────────────────────────────────────────────────────────────────────────
describe('resolvePromptText("equip_hint") มีคำใบ้ปุ่ม G (bug condition exploration)', () => {
  // dict states ที่สุ่ม: ว่าง (FALLBACK path) / ค่าไทย / ค่าอังกฤษ (dict value path)
  const dictArb = fc.constantFrom<Record<string, string>>(
    {},
    { equip_hint: thLocale.equip_hint },
    { equip_hint: enLocale.equip_hint },
  )

  it('Property 2: equip_hint มี "[G]" และ "จัดการเบ็ด"/"Manage Rod" ทุก dict state', () => {
    fc.assert(
      fc.property(dictArb, (dict) => {
        mockDict = dict
        const subtitle = resolvePromptText('equip_hint')

        // ต้องมีคำใบ้ปุ่ม G
        expect(subtitle).toContain('[G]')
        // ต้องมีคำว่า จัดการเบ็ด (ไทย) หรือ Manage Rod (อังกฤษ)
        expect(subtitle.includes('จัดการเบ็ด') || subtitle.includes('Manage Rod')).toBe(true)
      }),
      { numRuns: 50 },
    )
  })
})
