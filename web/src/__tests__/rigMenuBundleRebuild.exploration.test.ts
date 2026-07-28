import { describe, it, expect } from 'vitest'
import fc from 'fast-check'
import { readFileSync, readdirSync, existsSync } from 'node:fs'
import { resolve, join } from 'node:path'

// ────────────────────────────────────────────────────────────────────────────
// Feature: fishing-nui-bundle-rebuild-fix (bugfix)
// Property 1 (Bug Condition -> Expected Behavior): Rebuilt bundle สะท้อน CSS ที่แก้แล้ว
//
// บั๊กนี้คือ "stale build artifact + deploy" — spec ก่อนหน้าแก้ web/src/style.css
// (พื้นหลังโปร่งใส + text-shadow + สีขาว) แต่ไม่เคยรัน `npm run build` ทำให้ bundle ที่
// FiveM โหลดจริง (web/dist/assets/*.css) ยังเป็นเวอร์ชันเก่า และ deploy copy ก็ถือ
// bundle hash เดิม (index-DLW4jjFM.css / index-zLgQY8bw.js)
//
// test นี้ตรวจ "เนื้อหาไฟล์ bundle ที่ deploy" (content/hash diffing) — ไม่ใช่ render
// ของ component — โดย assert Expected Behavior (Property 1) ตรง ๆ:
//   - .rig-menu = background:transparent, ไม่มี box-shadow/backdrop-filter/var(--bg)
//   - .rig-menu__title/__hint/__empty/.rig-row__label/.rig-row__owned มี text-shadow + #fff
//   - dist/index.html ไม่อ้าง hash เก่า
//   - deploy copy ไม่มีไฟล์ hash เก่าค้างอยู่
//
// **CRITICAL**: test นี้ต้อง FAIL บน artifact เก่า (ยังไม่ rebuild) — การ FAIL ยืนยันว่า
// บั๊กมีอยู่จริง ห้ามแก้ test หรือ code ตอน fail (stale bundle คือตัวบั๊กเอง)
// test นี้ encode Expected Behavior — จะถูกรันซ้ำใน task 3.4 เพื่อ validate หลัง rebuild + deploy
//
// Validates: Requirements 1.1, 1.2, 1.3, 1.4 (Property 1 ใน design.md)
// ────────────────────────────────────────────────────────────────────────────

// vitest cwd = web/
const SOURCE_DIST = resolve(process.cwd(), 'dist')
const DEPLOY_DIST =
  'c:\\Users\\GameMaster\\Desktop\\FiveM Server\\txData\\QBCore_E66DFA.base\\resources\\[zlab]\\zfishing\\web\\dist'

// bundle hash เก่า (stale) ที่ต้องหายไปหลัง rebuild + deploy
const OLD_HASH_FILES = ['index-DLW4jjFM.css', 'index-zLgQY8bw.js']

// Scoped selector set (deterministic) — selector ข้อความที่ยืนยันได้ ต้องมี text-shadow + #fff
const TEXT_SELECTORS = [
  '.rig-menu__title',
  '.rig-menu__hint',
  '.rig-menu__empty',
  '.rig-category-card__title',
  '.rig-category-card__status',
  '.rig-item-row__label',
] as const

// อ่านและ concat ไฟล์ .css ทั้งหมดใน <dist>/assets (hash-independent — ใช้ได้ทั้งก่อน/หลัง rebuild)
function readDistCss(distDir: string): string {
  const assetsDir = join(distDir, 'assets')
  if (!existsSync(assetsDir)) return ''
  return readdirSync(assetsDir)
    .filter((f) => f.endsWith('.css'))
    .map((f) => readFileSync(join(assetsDir, f), 'utf-8'))
    .join('\n')
}

// รายชื่อไฟล์ใน <dist>/assets
function listAssets(distDir: string): string[] {
  const assetsDir = join(distDir, 'assets')
  if (!existsSync(assetsDir)) return []
  return readdirSync(assetsDir)
}

// ดึง declaration block ของ selector จาก minified CSS
// - เคารพ boundary หน้า selector (start / } / , / {) กัน prefix ชนกัน
//   (เช่น .rig-menu ไม่ไปจับ .rig-menu__title)
// - รองรับทั้ง "selector{" และ grouped "selector,"
function extractRuleBody(css: string, selector: string): string | null {
  for (const suffix of ['{', ',', ':']) {
    const needle = selector + suffix
    let idx = css.indexOf(needle)
    while (idx !== -1) {
      const before = idx === 0 ? '' : css[idx - 1]
      if (before === '' || before === '}' || before === ',' || before === '{') {
        const brace = css.indexOf('{', idx)
        const end = css.indexOf('}', brace)
        if (brace !== -1 && end !== -1) return css.slice(brace + 1, end)
      }
      idx = css.indexOf(needle, idx + 1)
    }
  }
  return null
}

const SOURCE_CSS = readDistCss(SOURCE_DIST)
const INDEX_HTML_PATH = join(SOURCE_DIST, 'index.html')
const INDEX_HTML = existsSync(INDEX_HTML_PATH) ? readFileSync(INDEX_HTML_PATH, 'utf-8') : ''

describe('Rig_Menu bundle rebuild (bug condition exploration)', () => {
  it('deployed bundle CSS มีอยู่จริง (มีไฟล์ .css ใน dist/assets)', () => {
    expect(SOURCE_CSS.length).toBeGreaterThan(0)
  })

  it('Property 1: .rig-menu ใน bundle = background:transparent (ไม่มี box-shadow/backdrop-filter/var(--bg))', () => {
    const body = extractRuleBody(SOURCE_CSS, '.rig-menu')
    expect(body).not.toBeNull()

    // Expected Behavior (R2.1): พื้นหลังโปร่งใส
    expect(body!).toContain('background:transparent')
    // ไม่มีกล่องทึบ/เงา/blur ที่บ่งชี้ artifact เก่า
    expect(body!).not.toContain('var(--bg)')
    expect(body!).not.toContain('box-shadow')
    expect(body!).not.toContain('backdrop-filter')
  })

  it('Property 1: title/hint/empty/row labels ใน bundle มี text-shadow + สีขาว (#fff)', () => {
    // Scoped PBT: ยืนยัน property เดียวกันข้าม selector ชุดที่ verify ได้ทั้งหมด
    fc.assert(
      fc.property(fc.constantFrom(...TEXT_SELECTORS), (selector) => {
        const body = extractRuleBody(SOURCE_CSS, selector)
        expect(body, `ไม่พบ rule ${selector} ใน deployed bundle CSS`).not.toBeNull()
        // Expected Behavior (R2.2): ตัวอักษรสีขาว + text-shadow ตรงกับ web/src/style.css
        expect(body!, `${selector} ต้องมี text-shadow`).toContain('text-shadow')
        expect(body!, `${selector} ต้องมีสีขาว #fff`).toContain('#fff')
      }),
      { numRuns: TEXT_SELECTORS.length },
    )
  })

  it('Property 1: web/dist/index.html ไม่อ้าง bundle hash เก่า', () => {
    expect(INDEX_HTML.length).toBeGreaterThan(0)
    for (const oldFile of OLD_HASH_FILES) {
      expect(INDEX_HTML, `index.html ต้องไม่อ้าง ${oldFile}`).not.toContain(oldFile)
    }
  })

  it('Property 1: deploy copy ไม่มีไฟล์ bundle hash เก่าค้างอยู่', () => {
    if (!existsSync(DEPLOY_DIST)) return
    const deployAssets = listAssets(DEPLOY_DIST)
    expect(deployAssets.length, `ไม่พบ deploy copy assets ที่ ${DEPLOY_DIST}`).toBeGreaterThan(0)
    for (const oldFile of OLD_HASH_FILES) {
      expect(deployAssets, `deploy copy ต้องไม่มีไฟล์ hash เก่า ${oldFile}`).not.toContain(oldFile)
    }
  })
})
