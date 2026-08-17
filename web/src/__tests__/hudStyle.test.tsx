import { describe, it, expect, beforeAll } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

// อ่าน style.css จริงแล้วฉีดเป็น <style> ให้ jsdom parse — รูปแบบเดียวกับ
// rigMenuHudStyle.exploration.test.tsx (jsdom getComputedStyle resolve var() ไม่ได้
// จึงตรวจ CSSStyleRule จาก document.styleSheets ตรง ๆ)
// vitest cwd = web/
const CSS_TEXT = readFileSync(resolve(process.cwd(), 'src/style.css'), 'utf-8')

beforeAll(() => {
  const styleEl = document.createElement('style')
  styleEl.textContent = CSS_TEXT
  document.head.appendChild(styleEl)
})

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

describe('Water HUD surface', () => {
  it('.hud-panel is transparent — no dark ground, no box shadow, no backdrop blur', () => {
    const rule = findRule('.hud-panel')
    expect(rule).not.toBeNull()
    const css = rule!.style.cssText
    expect(css).not.toContain('var(--bg)')
    expect(css).not.toContain('box-shadow')
    expect(css).not.toContain('backdrop-filter')
  })

  it('.hud-panel keeps the left accent rail — the shared signature', () => {
    const rule = findRule('.hud-panel')
    expect(rule).not.toBeNull()
    expect(rule!.style.cssText).toContain('border-left')
  })

  it('.bar-track keeps a background — the one localized scrim', () => {
    const rule = findRule('.bar-track')
    expect(rule).not.toBeNull()
    expect(rule!.style.cssText).toContain('background')
  })
})

// Tier A guard: ค่าที่ MinigameEngine เขียนทุก frame ผ่าน RAF ห้ามมี transition ที่มี
// ระยะเวลา มิฉะนั้น marker จะตามหลัง engine จนเล็งพลาด
//
// ต้องเช็ค "ไม่มี duration" ไม่ใช่ "ไม่มี property transition" เพราะ .energy-fill
// เรนเดอร์เป็น class="bar-fill energy-fill" และ .bar-fill มี
// transition: width 60ms linear — .energy-fill จึง *ต้อง* ประกาศ transition: none
// เพื่อ override
describe('Tier A: engine-driven values carry no timed transition', () => {
  const TIER_A_SELECTORS = ['.tension-marker', '.energy-fill'] as const

  for (const selector of TIER_A_SELECTORS) {
    it(`${selector} declares no transition duration`, () => {
      const rule = findRule(selector)
      expect(rule, `ไม่พบ rule ${selector}`).not.toBeNull()
      expect(rule!.style.cssText).not.toMatch(/transition:[^;]*\d+\s*m?s/)
    })
  }
})
