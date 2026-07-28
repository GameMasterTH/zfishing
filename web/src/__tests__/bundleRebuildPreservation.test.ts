import { describe, it, expect } from 'vitest'
import fc from 'fast-check'
import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { join, resolve, relative, sep } from 'node:path'

// ────────────────────────────────────────────────────────────────────────────
// Feature: fishing-nui-bundle-rebuild-fix (bugfix)
// Property 2 (Preservation): Source, Other HUD, and fxmanifest Unchanged
//
// การแก้บั๊กนี้เป็น build + deploy เท่านั้น (rebuild web/dist จาก source + deploy
// ทับสำเนา) — ไม่แตะ source code ใด ๆ ดังนั้นทุกสิ่งที่ bug condition ไม่ครอบคลุม
// ต้องคงเดิม: web/src/*, Lua, fxmanifest, HUD components อื่นใน bundle เดียวกัน
// (CastBar/PromptHud/Admin/catch card) และ prompt [G] จัดการเบ็ด ที่โหลดจาก
// locales/*.json โดยตรง
//
// Observation-first: สังเกต baseline บน artifact/source เดิมก่อน แล้ว encode ที่นี่
//   - source/Lua/fxmanifest: hash snapshot (สร้างครั้งแรกตอน task 2, เทียบซ้ำตอน task 3.5)
//   - other HUD selectors: baseline declaration ถอดจาก bundle ปัจจุบันตรง ๆ (hardcoded)
//
// **EXPECTED**: PASS บน artifact/code ปัจจุบัน (unfixed) — ยืนยัน baseline ที่ต้องคงไว้
//
// Validates: Requirements 3.1, 3.2, 3.3, 3.4 (Property 2 ใน design.md)
// ────────────────────────────────────────────────────────────────────────────

// resolve web/ root จาก cwd (npm run test รันจาก web/); เผื่อกรณีรันจาก repo root
function findWeb(): string {
  const cwd = process.cwd()
  if (existsSync(join(cwd, 'src', 'style.css')) && existsSync(join(cwd, 'dist'))) return cwd
  if (existsSync(join(cwd, 'web', 'src', 'style.css'))) return join(cwd, 'web')
  return cwd
}
const WEB = findWeb() // .../web
const REPO = resolve(WEB, '..') // .../zfishing
const SRC = join(WEB, 'src')
const DIST_ASSETS = join(WEB, 'dist', 'assets')

// ── helpers ─────────────────────────────────────────────────────────────────

function sha256(buf: Buffer): string {
  return createHash('sha256').update(buf).digest('hex')
}

// เดินทุกไฟล์ใน dir แบบ recursive, ข้ามโฟลเดอร์ test/snapshot
function walkFiles(dir: string, skip: (p: string) => boolean): string[] {
  const out: string[] = []
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry)
    if (skip(full)) continue
    const st = statSync(full)
    if (st.isDirectory()) out.push(...walkFiles(full, skip))
    else out.push(full)
  }
  return out
}

// map: relative path (posix) -> sha256 ของทุกไฟล์ (deterministic order)
function hashTree(root: string, files: string[]): Record<string, string> {
  const map: Record<string, string> = {}
  for (const f of files.sort()) {
    const rel = relative(root, f).split(sep).join('/')
    map[rel] = sha256(readFileSync(f))
  }
  return map
}

const isTestPath = (p: string) => p.includes('__tests__') || p.includes('__snapshots__')

// parse minified CSS -> map ของ top-level rule prelude -> declaration body (trimmed)
// รองรับ nested braces (@keyframes) โดยข้าม at-rule
function parseRules(css: string): Record<string, string> {
  const rules: Record<string, string> = {}
  const n = css.length
  let i = 0
  let selStart = 0
  while (i < n) {
    if (css[i] === '{') {
      const prelude = css.slice(selStart, i).trim()
      let depth = 1
      let j = i + 1
      while (j < n && depth > 0) {
        if (css[j] === '{') depth++
        else if (css[j] === '}') depth--
        j++
      }
      const body = css.slice(i + 1, j - 1).trim()
      if (!prelude.startsWith('@')) rules[prelude] = body
      i = j
      selStart = i
    } else {
      i++
    }
  }
  return rules
}

function readDistCss(): string {
  const cssFiles = readdirSync(DIST_ASSETS).filter((f) => /^index-.*\.css$/.test(f))
  expect(cssFiles.length).toBe(1) // ควรมี bundle CSS เดียว
  return readFileSync(join(DIST_ASSETS, cssFiles[0]), 'utf8')
}

// ── baseline ของ HUD components อื่น (สังเกตจาก bundle ปัจจุบัน) ────────────────
// selector เหล่านี้ไม่ได้ถูกแตะโดย spec ก่อนหน้า (แก้เฉพาะ .rig-menu*) จึงต้องคงเดิม
// ทั้งก่อนและหลัง rebuild — declaration ต่อไปนี้ถอดตรงจาก web/dist/assets/index-*.css
const OTHER_HUD_BASELINE: Record<string, string> = {
  // Prompt_HUD
  '.prompt-hud':
    'position:fixed;left:50%;bottom:7vh;transform:translate(-50%);max-width:40vw;text-align:center;pointer-events:none;display:flex;flex-direction:column;align-items:center;gap:.6vh;animation:slideFromBottom .25s cubic-bezier(.16,1,.3,1)',
  '.prompt-title': 'font-size:3vh;font-weight:700;color:var(--text)',
  '.prompt-subtitle': 'font-size:1.8vh;color:var(--muted)',
  // CastBar / bars / panel
  '.panel':
    'background:var(--bg);border:1px solid var(--border);border-left:2px solid var(--accent);box-shadow:var(--shadow);padding:1.4vh 1.2vw;color:var(--text);min-width:16vw;-webkit-backdrop-filter:blur(4px);backdrop-filter:blur(4px)',
  '.bar-track':
    'position:relative;width:100%;height:1.6vh;background:#ffffff12;border:1px solid var(--border);overflow:hidden',
  '.bar-fill': 'height:100%;transition:width 60ms linear',
  '.cast-fill': 'background:var(--warn)',
  '.energy-fill': 'background:var(--accent);transition:none',
  '.bar-caption': 'font-size:1.4vh;text-align:right;margin-top:.4vh;color:var(--muted)',
  // catch card
  '.catch-card': 'text-align:center;pointer-events:auto',
  '.catch-name': 'font-size:2.4vh;font-weight:700',
  '.catch-weight': 'font-size:1.7vh;color:var(--muted);margin-top:.4vh',
  '.catch-stars': 'font-size:2vh;color:var(--warn);margin:.8vh 0 1.2vh;letter-spacing:.2em',
  '.catch-actions': 'display:flex;gap:.6vw;justify-content:center',
  // Admin panel
  '.admin-overlay':
    'position:fixed;top:0;right:0;bottom:0;left:0;display:flex;align-items:center;justify-content:center;background:#04080cb8;font-family:var(--font);color:var(--text)',
  '.admin-window':
    'width:92vw;max-width:1040px;height:84vh;background:#0e141b;border:1px solid var(--border);box-shadow:var(--shadow);display:flex;flex-direction:column;overflow:hidden',
}

// ── 3.1: web/src/* source ไม่ถูกแก้ (source of truth) ─────────────────────────
// NOTE: baseline snapshot ของ style.css ถูกอัปเดต (83d0c945… -> 585f9824…) เพราะ spec
// `rig-menu-icon-oversize-fix` แก้ web/src/style.css โดยเจตนา (เพิ่มกฎ .rig-row__icon img
// + overflow:hidden) — เป็นการแก้ที่ตั้งใจ ไม่ใช่ regression ต่อ spec นี้
describe('Preservation: web/src source untouched (Req 3.1)', () => {
  it('Property 2: hash ของทุกไฟล์ source ใน web/src (ยกเว้น tests) ตรงกับ baseline', () => {
    const files = walkFiles(SRC, isTestPath)
    // sanity: source of truth หลัก ๆ ต้องมีอยู่จริง
    const rels = files.map((f) => relative(SRC, f).split(sep).join('/'))
    expect(rels).toContain('style.css')
    expect(rels).toContain('App.tsx')
    expect(rels).toContain('components/RigMenu.tsx')
    expect(rels).toContain('hooks/useNui.ts')

    const tree = hashTree(SRC, files)
    // snapshot: สร้าง baseline ครั้งแรก (task 2) แล้วเทียบซ้ำหลัง rebuild+deploy (task 3.5)
    expect(tree).toMatchSnapshot()
  })
})

// ── 3.4: Lua + fxmanifest ไม่ถูกแก้ ───────────────────────────────────────────
describe('Preservation: Lua source + fxmanifest untouched (Req 3.4)', () => {
  it('Property 2: hash ของทุกไฟล์ .lua + fxmanifest.lua ตรงกับ baseline', () => {
    const luaRoots = ['client', 'server', 'shared', 'config'].map((d) => join(REPO, d))
    const luaFiles: string[] = []
    for (const root of luaRoots) {
      if (existsSync(root)) luaFiles.push(...walkFiles(root, isTestPath).filter((f) => f.endsWith('.lua')))
    }
    luaFiles.push(join(REPO, 'fxmanifest.lua'))

    expect(luaFiles.length).toBeGreaterThan(0)
    const tree = hashTree(REPO, luaFiles)
    expect(tree).toMatchSnapshot()
  })
})

// ── 3.4: fxmanifest ui_page/files ยังชี้ web/dist/ (ประกาศไม่เปลี่ยน) ───────────
describe('Preservation: fxmanifest ui_page / files unchanged (Req 3.4)', () => {
  const manifest = readFileSync(join(REPO, 'fxmanifest.lua'), 'utf8')

  it('Property 2: ui_page ยังชี้ web/dist/index.html', () => {
    expect(manifest).toMatch(/ui_page\s+'web\/dist\/index\.html'/)
  })

  it('Property 2: files ประกาศ bundle จาก web/dist/ ครบ (index.html + assets)', () => {
    const filesBlock = manifest.slice(manifest.indexOf('files'))
    expect(filesBlock).toContain("'web/dist/index.html'")
    expect(filesBlock).toContain("'web/dist/assets/*.js'")
    expect(filesBlock).toContain("'web/dist/assets/*.css'")
    expect(filesBlock).toContain("'web/dist/assets/*.woff2'")
    expect(filesBlock).toContain("'web/dist/assets/*.woff'")
    expect(filesBlock).toContain("'locales/*.json'")
  })
})

// ── 3.2: HUD components อื่นใน bundle เดียวกันไม่เปลี่ยนเชิงพฤติกรรม (PBT) ───────
describe('Preservation: other HUD components in bundle unchanged (Req 3.2)', () => {
  it('Property 2: ทุก selector ของ CastBar/PromptHud/Admin/catch card ตรง baseline', () => {
    const rules = parseRules(readDistCss())
    const selectors = Object.keys(OTHER_HUD_BASELINE)

    fc.assert(
      fc.property(fc.constantFrom(...selectors), (selector) => {
        // declaration ใน bundle ปัจจุบัน (และหลัง rebuild) ต้องตรงกับ baseline ที่สังเกตไว้
        expect(rules[selector]).toBe(OTHER_HUD_BASELINE[selector])
      }),
      { numRuns: 60 },
    )
  })

  it('Property 2: bundle ยังมี selector ครบทุกตัว (ไม่มีตัวใดหาย)', () => {
    const rules = parseRules(readDistCss())
    for (const selector of Object.keys(OTHER_HUD_BASELINE)) {
      expect(rules).toHaveProperty([selector])
    }
  })
})

// ── 3.3: prompt [G] จัดการเบ็ด โหลดจาก locales/*.json โดยตรง (ไม่เกี่ยวกับ bundle) ─
describe('Preservation: prompt from locales/*.json (Req 3.3)', () => {
  const th = JSON.parse(readFileSync(join(REPO, 'locales', 'th.json'), 'utf8'))
  const en = JSON.parse(readFileSync(join(REPO, 'locales', 'en.json'), 'utf8'))

  it('Property 2: th.json equip_hint มี [G] จัดการเบ็ด', () => {
    expect(th.equip_hint).toContain('[G] จัดการเบ็ด')
  })

  it('Property 2: en.json equip_hint มี [G] Manage Rod', () => {
    expect(en.equip_hint).toContain('[G] Manage Rod')
  })

  it('Property 2: rig_button_label คงเดิมในทั้งสองภาษา', () => {
    expect(th.rig_button_label).toBe('จัดการเบ็ด')
    expect(en.rig_button_label).toBe('Manage Rod')
  })
})
