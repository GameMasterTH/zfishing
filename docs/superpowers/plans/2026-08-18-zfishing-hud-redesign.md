# zfishing HUD Redesign ("Water HUD") Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Unify every zfishing NUI surface on the transparent "Water HUD" language that RigMenu and PromptHud already use, and add a reactive motion layer so every meaningful game event produces visible feedback.

**Architecture:** The opaque `.panel` card is replaced by a transparent `.hud-panel` whose only chrome is a 2px left accent rail — the same idiom RigMenu already uses on `.rig-category-card`. Legibility comes from `text-shadow` everywhere plus one localized scrim behind bar tracks. Motion splits into two strict tiers: values written every frame by the minigame RAF loop carry no timed transition, while state-change moments use CSS keyframes on `transform`/`opacity`.

**Tech Stack:** React 18 + TypeScript + Vite, plain CSS (no motion library), vitest + @testing-library/react + fast-check. FiveM NUI (CEF).

**Spec:** `docs/superpowers/specs/2026-08-18-zfishing-hud-redesign-design.md` (commits `5980544`, `b070401`)

**Repo root for all paths:** `e:\Web\ZCore\zfishing`
**All test/build commands run from:** `e:\Web\ZCore\zfishing\web`

---

## Global Constraints

Every task's requirements implicitly include this section.

1. **No Lua changes.** Not one `.lua` file. `bundleRebuildPreservation.test.ts` keeps a sha256 snapshot of every `.lua` file plus `fxmanifest.lua`; it will fail loudly if this is violated. Every animation is driven by data the client already sends.

2. **No admin panel changes.** `web/src/admin/*` and `admin.css` are out of scope. The surviving `.admin-overlay` / `.admin-window` baseline in `bundleRebuildPreservation.test.ts` guards this.

3. **The six `#fff` selectors — do NOT tokenize their `color:` values.** `rigMenuBundleRebuild.exploration.test.ts:106-118` asserts against the **built** `web/dist` CSS that each of these contains both `text-shadow` and the literal substring `#fff`:

   `.rig-menu__title`, `.rig-menu__hint`, `.rig-menu__empty`, `.rig-category-card__title`, `.rig-category-card__status`, `.rig-item-row__label`

   `.rig-category-card__status` is authored `color: rgba(255, 255, 255, 0.8)` and only passes because the minifier emits `#fffc`, which contains `#fff`. Changing any of these six to `var(--text)` (`#e8edf2`) breaks a build-time check with no source-level hint why. Replacing their `text-shadow` **value** with `var(--hud-shadow-text)` is safe — the assertion matches the declaration name.

4. **Never write `transition: all`** in new CSS. Always name the properties. A blanket transition on an element the RAF loop writes to will make the value visibly lag the engine.

5. **`border-radius: 0 !important`** (`style.css:19`) stays. Everything is sharp-cornered, including the keycap chip.

6. **Baseline to preserve:** on `main` before this work, `npm test` reports **15 test files, 55 tests, all passing** (~28s). Task 1 removes 2 tests; Task 2 and Task 3 add tests. Any *unexpected* failure is a real regression, not noise.

7. **`web/dist` is a committed build artifact.** `fxmanifest.lua` declares `ui_page 'web/dist/index.html'`. It is rebuilt and committed once, in Task 11 — not per task.

8. **No deploy step.** The deploy copy named at `rigMenuBundleRebuild.exploration.test.ts:31-32` does not exist on this machine, so that test's deploy assertion early-returns at L128 and is inert.

---

## File Structure

| File | Responsibility |
|---|---|
| `web/src/style.css` | All tokens, surfaces, and keyframes. Single stylesheet, as today. |
| `web/src/components/Keycap.tsx` | **New.** The `Keycap` chip component and the `renderWithKeycaps` text splitter. Owns all `[KEY]` parsing. |
| `web/src/components/CastBar.tsx` | Cast power surface. Consumes the `state` prop it currently ignores. |
| `web/src/components/FishingInfoCard.tsx` | Rod / bait / distance readout. |
| `web/src/components/WaitingHud.tsx` | Two phases: idle ripple, and the bite alert. |
| `web/src/components/TensionMinigame.tsx` | Reel minigame. Owns the RAF loop — the Tier A boundary lives here. |
| `web/src/components/CatchCard.tsx` | Catch result and keep/release actions. |
| `web/src/components/PromptHud.tsx` | Idle prompt shown while holding the rod. |
| `web/src/components/RigMenu.tsx` | G menu. The exemplar — touched minimally. |
| `locales/th.json`, `locales/en.json` | `ui_bite_prompt` and `ui_reel_title` gain `[SPACE]` brackets. |
| `web/src/__tests__/hudStyle.test.tsx` | **New.** Guards the transparent surface and the Tier A no-timed-transition rule. |

---

## Task / Model / Effort

Dispatch guidance for subagent-driven execution.

| Task | Model | Effort | Why |
|---|---|---|---|
| 1. Retire obsolete guards | **opus** | high | Deletion surgery across two files; over-deleting removes live Lua/admin guards, under-deleting blocks every later task |
| 2. Tokens, `.hud-panel`, scrim, guard test | sonnet | medium | Mechanical, but the guard regex is subtle — it is given verbatim below |
| 3. Keycap + locales + PromptHud | sonnet | medium | New component with real parsing logic; tests given |
| 4. Migrate 5 panels to `.hud-panel` | sonnet | low | Pure class rename plus dead-rule removal |
| 5. Motion foundation | sonnet | medium | Keyframe library, no component logic |
| 6. CastBar + FishingInfoCard motion | sonnet | medium | Straightforward; `state` prop wiring is new behaviour |
| 7. WaitingHud ripple + bite beat | sonnet | medium | Replaces two existing keyframes; watch for orphans |
| 8. TensionMinigame in-zone + vignette | **opus** | high | The Tier A/B boundary. Easiest place in the codebase to introduce a lagging marker, and the guard test only covers two selectors |
| 9. CatchCard reveal sequence | sonnet | medium | Longest keyframe sequence; delays must add up |
| 10. RigMenu tokens + stagger | **opus** | medium | Global Constraint 3 lives here — the `#fff` trap is exactly a "tokenize the colours" task |
| 11. Build + full verification | sonnet | low | Build, run suite, commit dist |
| Final branch review | **opus** | — | Chosen by the user during brainstorming |

---

### Task 1: Retire the obsolete preservation guards

These guards encode "the previous bugfix touched no source". That premise no longer holds. They must go **first** — every later task fails against them otherwise.

**Files:**
- Modify: `web/src/__tests__/bundleRebuildPreservation.test.ts`
- Modify: `web/src/__tests__/__snapshots__/bundleRebuildPreservation.test.ts.snap`
- Modify: `web/src/__tests__/rigMenuIconPreservation.test.tsx:152-176`

**Interfaces:**
- Consumes: nothing.
- Produces: a test suite that no longer asserts the existence of `.panel`, `.btn`, `.cast-fill`, `.prompt-*`, `.catch-*`, `.bar-*`, or the sha256 of `web/src`. Later tasks depend on this.

- [ ] **Step 1: Confirm the current baseline is green**

Run: `npm test`
Expected: `Test Files 15 passed (15)`, `Tests 55 passed (55)`. If this is not what you see, stop and report — do not continue.

- [ ] **Step 2: Delete the `web/src` hash-snapshot block**

In `web/src/__tests__/bundleRebuildPreservation.test.ts`, delete this entire block (currently L134-152, including the three comment lines above `describe`):

```typescript
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
```

Replace it with a short note recording why it went:

```typescript
// ── 3.1 (RETIRED) ────────────────────────────────────────────────────────────
// บล็อกนี้เคย hash ทุกไฟล์ใน web/src เพื่อยืนยันว่า bugfix นั้นไม่แตะ source เลย
// spec 2026-08-18-zfishing-hud-redesign แก้ style.css + components โดยเจตนา
// premise ของ guard นี้จึงหมดอายุ — ลบทิ้ง ไม่ใช่ re-snapshot
// guard ที่ยังมีค่า (Lua hash, fxmanifest, admin, locales) ยังอยู่ด้านล่าง
```

- [ ] **Step 3: Delete the retired HUD selectors from `OTHER_HUD_BASELINE`**

In the same file, `OTHER_HUD_BASELINE` (starts L106) must end up containing **only** the two admin entries. Delete the `.prompt-hud`, `.prompt-title`, `.prompt-subtitle`, `.panel`, `.bar-track`, `.bar-fill`, `.cast-fill`, `.energy-fill`, `.bar-caption`, `.catch-card`, `.catch-name`, `.catch-weight`, `.catch-stars`, and `.catch-actions` entries so the constant reads exactly:

```typescript
// ── baseline ของ HUD components อื่น (สังเกตจาก bundle ปัจจุบัน) ────────────────
// เหลือเฉพาะ Admin panel ซึ่งอยู่นอกขอบเขตของ HUD redesign — entry ของ .panel/.bar-*/
// .catch-*/.prompt-* ถูกลบเพราะ redesign เปลี่ยนกฎเหล่านั้นโดยเจตนา
const OTHER_HUD_BASELINE: Record<string, string> = {
  // Admin panel
  '.admin-overlay':
    'position:fixed;top:0;right:0;bottom:0;left:0;display:flex;align-items:center;justify-content:center;background:#04080cb8;font-family:var(--font);color:var(--text)',
  '.admin-window':
    'width:92vw;max-width:1040px;height:84vh;background:#0e141b;border:1px solid var(--border);box-shadow:var(--shadow);display:flex;flex-direction:column;overflow:hidden',
}
```

Leave the two `describe` blocks that consume it (`Req 3.2`) untouched — they iterate `Object.keys(OTHER_HUD_BASELINE)` and now simply cover fewer selectors.

- [ ] **Step 4: Delete the dead snapshot entry**

In `web/src/__tests__/__snapshots__/bundleRebuildPreservation.test.ts.snap`, delete the whole export whose key begins:

```
exports[`Preservation: web/src source untouched (Req 3.1) > Property 2: hash ของทุกไฟล์ source ใน web/src (ยกเว้น tests) ตรงกับ baseline 1`]
```

Keep the `Preservation: Lua source + fxmanifest untouched (Req 3.4)` export exactly as it is — that one is still live and still meaningful.

- [ ] **Step 5: Delete the stale HUD block in `rigMenuIconPreservation.test.tsx`**

Delete L152-176 in `web/src/__tests__/rigMenuIconPreservation.test.tsx` — the entire final block, comment header included:

```typescript
// ─── 3.4: HUD อื่นใน bundle เดียวกันยังคงกฎ CSS เดิม ──────────────────────────
describe('Preservation: HUD อื่นใน bundle เดียวกันไม่ถูกกระทบ (3.4)', () => {
  it('Property 2: กฎ CSS ของ CastBar/panel, PromptHud, catch card, ปุ่ม ยังคงอยู่และคงค่าหลัก', () => {
    // ... asserts panel contains var(--bg), .cast-fill, .prompt-hud, .prompt-title,
    //     .catch-card, .btn all exist
  })
})
```

**Keep** the block immediately above it (L137-150, `Preservation: สไตล์เมนู .rig-menu โปร่งใส + text-shadow (3.2)`). Both of its assertions stay true after the redesign.

- [ ] **Step 6: Run the suite and confirm the expected shrink**

Run: `npm test`
Expected: `Test Files 15 passed (15)`, `Tests 53 passed (53)`. Two tests fewer than baseline — one from Step 2, one from Step 5. Still 15 files, because no file was deleted outright.

- [ ] **Step 7: Commit**

```bash
git add web/src/__tests__/bundleRebuildPreservation.test.ts web/src/__tests__/__snapshots__/bundleRebuildPreservation.test.ts.snap web/src/__tests__/rigMenuIconPreservation.test.tsx
git commit -m "test: retire preservation guards that lock the old HUD design

These blocks encoded 'the previous bugfix touched no source'. The HUD
redesign changes style.css and the components on purpose, so the premise
is gone. Deleted rather than re-baselined: a re-snapshot would need
updating on every future CSS edit while catching no real bug.

Still live: the Lua + fxmanifest hash snapshot, the fxmanifest ui_page
and files assertions, the admin-panel CSS baseline, the locales [G]
assertions, and the .rig-menu transparency block."
```

---

### Task 2: Tokens, `.hud-panel`, the scrim, and the Tier A guard test

**Files:**
- Create: `web/src/__tests__/hudStyle.test.tsx`
- Modify: `web/src/style.css` (`:root` L4-17; `.bar-track` L77-84; `.tension-marker` L136-143)

**Interfaces:**
- Consumes: Task 1's pruned suite.
- Produces: CSS custom properties `--hud-shadow-text`, `--hud-scrim`, `--ease-out`, `--dur-fast`, `--dur-base`, `--dur-slow`; the `.hud-panel` class plus modifiers `.hud-panel--warn` and `.hud-panel--danger`. Tasks 4-10 consume all of these.

- [ ] **Step 1: Write the failing guard test**

Create `web/src/__tests__/hudStyle.test.tsx`:

```tsx
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
```

- [ ] **Step 2: Run it and watch it fail**

Run: `npx vitest --run src/__tests__/hudStyle.test.tsx`
Expected: FAIL. The two `.hud-panel` tests fail on `expect(rule).not.toBeNull()` because `.hud-panel` does not exist yet. The `.bar-track` and Tier A tests already pass against the current CSS — that is fine and expected.

- [ ] **Step 3: Add the tokens**

In `web/src/style.css`, extend the `:root` block (L4-17) by appending these six declarations before the closing brace. Leave every existing token exactly as it is — `--bg` stays even though `.panel` is going away, because removing it is out of scope.

```css
  /* Water HUD: shared surface + motion tokens */
  --hud-shadow-text: 0 1px 3px rgba(0, 0, 0, 0.9);
  --hud-scrim: rgba(6, 10, 14, 0.55);
  --ease-out: cubic-bezier(0.16, 1, 0.3, 1);
  --dur-fast: 120ms;
  --dur-base: 220ms;
  --dur-slow: 380ms;
```

- [ ] **Step 4: Add `.hud-panel` directly below the existing `.panel` rule**

Do **not** delete `.panel` yet — Task 4 does that, once no component references it.

```css
/* ---------------------------------------------------------------- Water HUD
   Transparent surface. The 2px left rail is the only chrome, and its colour
   carries state. No ground, no border box, no shadow, no blur — legibility
   comes from text-shadow, with one scrim on .bar-track (the tension marker is
   the one element where a misread costs the player the fish).

   No `box-shadow: none` / `backdrop-filter: none` resets here: this is a fresh
   class with nothing to reset, and hudStyle.test.tsx asserts those declaration
   names are absent. */
.hud-panel {
  background: transparent;
  border-left: 2px solid var(--rail, var(--accent));
  padding: 1.4vh 1.2vw;
  color: var(--text);
  min-width: 16vw;
  text-shadow: var(--hud-shadow-text);
}

.hud-panel--warn   { --rail: var(--warn); }
.hud-panel--danger { --rail: var(--danger); }
```

- [ ] **Step 5: Swap the bar track ground for the scrim**

Change only the `background` line of `.bar-track` (L77-84). Everything else in the rule stays.

```css
.bar-track {
  position: relative;
  width: 100%;
  height: 1.6vh;
  background: var(--hud-scrim);
  border: 1px solid var(--border);
  overflow: hidden;
}
```

- [ ] **Step 6: Give the tension marker a dark outline**

The marker now sits on the scrim and on the teal green zone, so it needs its own edge. Replace `.tension-marker` (L136-143) with:

```css
.tension-marker {
  position: absolute;
  top: -0.3vh;
  width: 2px;
  height: 2.2vh;
  background: #fff;
  box-shadow: 0 0 0 1px rgba(0, 0, 0, 0.85);
  transform: translateX(-50%);
  transition: none;
}
```

`transition: none` is deliberate and the guard test permits it — the regex only rejects a transition with a duration.

- [ ] **Step 7: Run the guard test and confirm it passes**

Run: `npx vitest --run src/__tests__/hudStyle.test.tsx`
Expected: PASS, 5 tests.

- [ ] **Step 8: Run the full suite**

Run: `npm test`
Expected: `Test Files 16 passed (16)`, `Tests 58 passed (58)`.

- [ ] **Step 9: Commit**

```bash
git add web/src/style.css web/src/__tests__/hudStyle.test.tsx
git commit -m "feat(hud): add Water HUD tokens, .hud-panel surface, and Tier A guard

.hud-panel is the transparent replacement for .panel: no ground, no
border box, no shadow, no blur. Its 2px left rail is the only chrome and
carries state through --rail. .panel itself stays until the components
stop referencing it.

.bar-track swaps its ground for --hud-scrim, the single localized scrim
in the HUD, and .tension-marker gains a 1px dark outline so it reads on
both the scrim and the green zone.

hudStyle.test.tsx guards the surface and, more importantly, asserts that
.tension-marker and .energy-fill never carry a *timed* transition. It has
to be phrased that way: .energy-fill renders as 'bar-fill energy-fill'
and .bar-fill carries 'transition: width 60ms linear', so 'transition:
none' is the override that makes the tier work."
```

---

### Task 3: `Keycap`, `renderWithKeycaps`, locale brackets, and PromptHud

**Files:**
- Create: `web/src/components/Keycap.tsx`
- Create: `web/src/components/__tests__/Keycap.test.tsx`
- Modify: `web/src/components/PromptHud.tsx`
- Modify: `web/src/style.css` (append keycap rules)
- **No locale files** — see Step 6's note.

**Interfaces:**
- Consumes: `--hud-shadow-text`, `--font` from Task 2.
- Produces:
  - `export default function Keycap(props: { label: string; variant?: 'breathe' | 'urgent' }): JSX.Element`
  - `export function renderWithKeycaps(text: string, variant?: 'breathe' | 'urgent'): ReactNode[]`

  Tasks 7 and 8 import `renderWithKeycaps` from `'./Keycap'`.

`renderWithKeycaps` lives in `Keycap.tsx`, not `promptText.ts`, because it emits JSX while `promptText.ts` is a `.ts` file whose pure string behaviour is locked by `promptText.test.ts` and `localeTextPreservation.test.ts`. Do not touch those two files.

- [ ] **Step 1: Write the failing test**

Create `web/src/components/__tests__/Keycap.test.tsx`:

```tsx
import { describe, it, expect, afterEach } from 'vitest'
import { render, cleanup, screen } from '@testing-library/react'
import Keycap, { renderWithKeycaps } from '../Keycap'

afterEach(() => cleanup())

describe('Keycap', () => {
  it('renders the label inside a .keycap element', () => {
    render(<Keycap label="G" />)
    const cap = document.querySelector('.keycap')
    expect(cap).not.toBeNull()
    expect(cap!.textContent).toBe('G')
  })

  it('adds a variant modifier class when asked', () => {
    render(<Keycap label="SPACE" variant="urgent" />)
    expect(document.querySelector('.keycap--urgent')).not.toBeNull()
  })
})

describe('renderWithKeycaps', () => {
  it('turns every [KEY] run into a keycap and drops the brackets', () => {
    render(<div data-testid="host">{renderWithKeycaps('[E] เริ่มตกปลา   ·   [G] จัดการเบ็ด')}</div>)
    const host = screen.getByTestId('host')

    const caps = host.querySelectorAll('.keycap')
    expect(caps.length).toBe(2)
    expect(caps[0].textContent).toBe('E')
    expect(caps[1].textContent).toBe('G')

    // ข้อความรอบ ๆ ต้องคงอยู่ครบ เหลือแค่วงเล็บที่หายไป
    expect(host.textContent).toBe('E เริ่มตกปลา   ·   G จัดการเบ็ด')
  })

  it('passes text through untouched when there is no [KEY]', () => {
    render(<div data-testid="host">{renderWithKeycaps('รอปลากินเบ็ด…')}</div>)
    const host = screen.getByTestId('host')
    expect(host.querySelectorAll('.keycap').length).toBe(0)
    expect(host.textContent).toBe('รอปลากินเบ็ด…')
  })

  it('handles a string that is nothing but a key', () => {
    render(<div data-testid="host">{renderWithKeycaps('[SPACE]')}</div>)
    const host = screen.getByTestId('host')
    expect(host.querySelectorAll('.keycap').length).toBe(1)
    expect(host.textContent).toBe('SPACE')
  })
})
```

- [ ] **Step 2: Run it and watch it fail**

Run: `npx vitest --run src/components/__tests__/Keycap.test.tsx`
Expected: FAIL — `Failed to resolve import "../Keycap"`.

- [ ] **Step 3: Write the component**

Create `web/src/components/Keycap.tsx`:

```tsx
import type { ReactNode } from 'react'

type Variant = 'breathe' | 'urgent'

// ปุ่มคีย์บอร์ดหนึ่งอัน — ใช้ร่วมกันทั้ง PromptHud, bite prompt และหัวข้อ reel
// เพื่อให้ทุกจุดที่บอก "กดปุ่มนี้" หน้าตาและจังหวะเดียวกัน
export default function Keycap({ label, variant }: { label: string; variant?: Variant }) {
  return <kbd className={variant ? `keycap keycap--${variant}` : 'keycap'}>{label}</kbd>
}

// locale เขียนปุ่มไว้ในวงเล็บเหลี่ยม เช่น "[E] เริ่มตกปลา   ·   [G] จัดการเบ็ด"
// ตัวนี้แยกสตริงเป็น text + <Keycap> โดยตัดวงเล็บออก ข้อความอื่นคงเดิมทุกตัวอักษร
export function renderWithKeycaps(text: string, variant?: Variant): ReactNode[] {
  const pattern = /\[([A-Za-z0-9]+)\]/g
  const out: ReactNode[] = []
  let last = 0
  let match: RegExpExecArray | null

  while ((match = pattern.exec(text)) !== null) {
    if (match.index > last) out.push(text.slice(last, match.index))
    out.push(<Keycap key={`${match.index}-${match[1]}`} label={match[1]} variant={variant} />)
    last = match.index + match[0].length
  }
  if (last < text.length) out.push(text.slice(last))

  return out
}
```

The regex literal is created fresh on each call, so there is no `lastIndex` state to leak between calls.

- [ ] **Step 4: Add the keycap styles**

Append to `web/src/style.css`:

```css
/* ---------------------------------------------------------------- keycap
   Sharp rectangle (border-radius is globally 0), 1px border with a heavier
   bottom edge so it reads as a physical key. */
.keycap {
  display: inline-block;
  min-width: 2.4vh;
  padding: 0.15vh 0.5vh;
  margin: 0 0.15vw;
  font-family: var(--font);
  font-size: 0.85em;
  font-weight: 700;
  line-height: 1.5;
  text-align: center;
  color: var(--text);
  background: rgba(255, 255, 255, 0.1);
  border: 1px solid rgba(255, 255, 255, 0.35);
  border-bottom-width: 2px;
  text-shadow: var(--hud-shadow-text);
}

.keycap--breathe { animation: keycapBreathe 2.4s ease-in-out infinite; }
.keycap--urgent  { animation: keycapUrgent 0.9s steps(1, end) infinite; }

@keyframes keycapBreathe {
  0%, 100% { opacity: 0.7; }
  50%      { opacity: 1; }
}

@keyframes keycapUrgent {
  0%, 49% {
    background: rgba(255, 255, 255, 0.1);
    border-color: rgba(255, 255, 255, 0.35);
  }
  50%, 100% {
    background: rgba(217, 160, 63, 0.4);
    border-color: var(--warn);
  }
}
```

`font-family: var(--font)` is required — `<kbd>` defaults to monospace, which has no Thai coverage.

- [ ] **Step 5: Run the Keycap test**

Run: `npx vitest --run src/components/__tests__/Keycap.test.tsx`
Expected: PASS, 5 tests.

- [ ] **Step 6: Wire PromptHud to it**

Replace `web/src/components/PromptHud.tsx` in full:

```tsx
import { resolvePromptText, prepareLines } from '../promptText'
import { renderWithKeycaps } from './Keycap'

type Props = { titleKey: string; subtitleKey: string }

export default function PromptHud({ titleKey, subtitleKey }: Props) {
  const title = resolvePromptText(titleKey)
  const subtitle = resolvePromptText(subtitleKey)
  const [titleLine, subtitleLine] = prepareLines(title, subtitle)

  if (!titleLine && !subtitleLine) return null

  return (
    <div className="prompt-hud">
      {titleLine && <div className="prompt-title">{titleLine}</div>}
      {subtitleLine && (
        <div className="prompt-subtitle">{renderWithKeycaps(subtitleLine, 'breathe')}</div>
      )}
    </div>
  )
}
```

`.prompt-title` and `.prompt-subtitle` both survive as elements in the same document order, so `PromptHud.test.tsx` stays green.

**No locale edits in this task — this is deliberate and load-bearing.** `equip_hint` and `cancel_hint` already use the bracket convention, so PromptHud works the moment Step 6 lands. `ui_bite_prompt` and `ui_reel_title` do *not* have brackets yet, and they must stay that way until the components that render them call `renderWithKeycaps`. Bracketing them here would put a literal `[SPACE]` on the player's screen from Task 3 through Task 8, and no test would catch it. Those two edits ship inside Task 7 and Task 8, alongside the components that consume them.

Also do **not** touch `equip_hint` or `rig_button_label` at any point — `bundleRebuildPreservation.test.ts` still asserts their exact contents.

- [ ] **Step 7: Run the full suite**

Run: `npm test`
Expected: `Test Files 17 passed (17)`, `Tests 63 passed (63)`.

- [ ] **Step 8: Commit**

```bash
git add web/src/components/Keycap.tsx web/src/components/__tests__/Keycap.test.tsx web/src/components/PromptHud.tsx web/src/style.css
git commit -m "feat(hud): add Keycap chip and wire PromptHud to it

One key-chip component, used wherever the HUD says 'press this'. The
locale strings already wrote keys as [E]/[X]/[G]; renderWithKeycaps
splits on that and drops the brackets, leaving surrounding text
byte-identical.

The two ui_* strings that still lack brackets are left alone here.
Bracketing them before their components render through the chip would
show a literal [SPACE] on screen, and no test would catch it — so those
edits ship with the components that consume them.

renderWithKeycaps lives in Keycap.tsx rather than promptText.ts because
it emits JSX and promptText.ts is a .ts file whose string behaviour is
locked by two existing test files."
```

---

### Task 4: Migrate the five gameplay panels to `.hud-panel`

Pure surface swap. No motion yet — that keeps this task's diff reviewable on its own.

**Files:**
- Modify: `web/src/components/CastBar.tsx`, `FishingInfoCard.tsx`, `WaitingHud.tsx`, `TensionMinigame.tsx`, `CatchCard.tsx`
- Modify: `web/src/style.css` (delete `.panel`, `.btn*`; add `.hud-btn*`; adjust `.bite-panel`, `.reel-panel`)

**Interfaces:**
- Consumes: `.hud-panel`, `.hud-panel--warn`, `.hud-panel--danger` from Task 2.
- Produces: no component references `.panel` or `.btn`. Tasks 6-9 layer motion onto these same class names.

- [ ] **Step 1: Swap the class in all five components**

In each file, change the `panel` class token to `hud-panel`, leaving the variant class beside it alone:

| File | Before | After |
|---|---|---|
| `CastBar.tsx:6` | `className="panel cast-panel"` | `className="hud-panel cast-panel"` |
| `FishingInfoCard.tsx:5` | `className="panel info-card"` | `className="hud-panel info-card"` |
| `WaitingHud.tsx:6` | `className="panel bite-panel"` | `className="hud-panel hud-panel--warn bite-panel"` |
| `WaitingHud.tsx:13` | `className="panel waiting-panel"` | `className="hud-panel waiting-panel"` |
| `TensionMinigame.tsx:65` | `` `panel reel-panel${state.overTension ? ' danger' : ''}` `` | `` `hud-panel reel-panel${state.overTension ? ' hud-panel--danger danger' : ''}` `` |
| `CatchCard.tsx:7` | `className="panel catch-card"` | `className="hud-panel catch-card"` |

- [ ] **Step 2: Swap the buttons in `CatchCard.tsx`**

```tsx
<div className="catch-actions">
  <button className="hud-btn hud-btn--primary" onClick={() => fetchNui('keep')}>{t('ui_keep')}</button>
  <button className="hud-btn" onClick={() => fetchNui('release')}>{t('ui_release')}</button>
</div>
```

- [ ] **Step 3: Delete the retired rules from `style.css`**

Delete the `.panel` rule (L43-52), the `.btn` / `.btn:hover` / `.btn-primary` / `.btn-primary:hover` rules (L154-167), and the now-dead `.reel-panel.danger` border rule (L127). Nothing else references them once Steps 1-2 land.

Replace `.bite-panel` (L111) with the transparent form — the amber survives as the rail (already applied via `hud-panel--warn`) plus the text glow added in Task 7:

```css
.bite-panel { text-align: center; }
```

Give `.reel-panel` a positioning context, which Task 8's vignette needs:

```css
.reel-panel { position: relative; min-width: 20vw; }
```

- [ ] **Step 4: Add `.hud-btn`**

```css
/* buttons */
.hud-btn {
  pointer-events: auto;
  padding: 0.9vh 1.6vw;
  font-family: var(--font);
  font-size: 1.4vh;
  font-weight: 700;
  color: var(--text);
  background: rgba(255, 255, 255, 0.07);
  border: 1px solid rgba(255, 255, 255, 0.15);
  cursor: pointer;
  text-shadow: var(--hud-shadow-text);
  transition: background var(--dur-fast) linear, transform var(--dur-fast) var(--ease-out);
}
.hud-btn:hover  { background: rgba(255, 255, 255, 0.16); }
.hud-btn:active { transform: scale(0.97); }

.hud-btn--primary {
  background: var(--accent);
  border-color: var(--accent);
  color: #0c1015;
  text-shadow: none;
}
.hud-btn--primary:hover { background: #55c7b3; }
```

Named properties only, per Global Constraint 4.

- [ ] **Step 5: Confirm nothing still references the deleted classes**

Run: `npx rg -n 'className="panel |className="btn|className="btn btn-primary|"panel ' web/src/components`
Expected: no hits at all.

Do **not** grep for a bare `btn` — it matches the `hud-btn` and `hud-btn--primary` you just wrote and reads as a false failure.

Then check the stylesheet: `npx rg -n '^\.panel \{|^\.btn' web/src/style.css`
Expected: no hits. `.panel-title` survives and is correct — the patterns above require a space or `{` right after `.panel`, and `^\.btn` will not match `.hud-btn`.

Hits inside `web/src/admin/` are expected and must be left alone — the admin panel has its own `admin.css` and is out of scope.

- [ ] **Step 6: Run the full suite**

Run: `npm test`
Expected: `Test Files 17 passed (17)`, `Tests 63 passed (63)` — unchanged from Task 3.

- [ ] **Step 7: Commit**

```bash
git add web/src/components web/src/style.css
git commit -m "refactor(hud): move the five gameplay panels onto .hud-panel

Surface swap only, no motion yet. .panel, .btn, .btn-primary and the
.reel-panel.danger border rule are deleted now that nothing references
them. .bite-panel keeps only its centring — its amber comes from the
--rail modifier instead of an opaque amber box.

.reel-panel gains position: relative for the over-tension vignette that
lands in a later task."
```

---

### Task 5: Motion foundation

One shared keyframe library plus the panel entrance. Every later motion task draws from this.

**Files:**
- Modify: `web/src/style.css`

**Interfaces:**
- Consumes: `--ease-out`, `--dur-base` from Task 2.
- Produces: keyframes `panelIn`, `riseIn`, `rowIn`; `.hud-panel` gains an entrance animation. Tasks 6, 7, 9, 10 reference `riseIn` and `rowIn` by name.

- [ ] **Step 1: Add the shared keyframes**

Append to `web/src/style.css`:

```css
/* ---------------------------------------------------------------- motion
   Tier B only: event-driven moments, on transform/opacity.
   Anything the minigame RAF loop writes every frame (.tension-marker left,
   .green-zone left/width, .energy-fill width) must never get a timed
   transition — hudStyle.test.tsx guards the two most dangerous of those. */
@keyframes panelIn {
  from { opacity: 0; transform: translateX(1.2vw); }
  to   { opacity: 1; transform: translateX(0); }
}

@keyframes riseIn {
  from { opacity: 0; transform: translateY(0.8vh); }
  to   { opacity: 1; transform: translateY(0); }
}

@keyframes rowIn {
  from { opacity: 0; transform: translateX(0.6vw); }
  to   { opacity: 1; transform: translateX(0); }
}
```

- [ ] **Step 2: Give `.hud-panel` its entrance**

Append one declaration to the existing `.hud-panel` rule from Task 2:

```css
  animation: panelIn var(--dur-base) var(--ease-out) both;
```

The panel enters from the right, matching RigMenu's existing `slideFromRight`, and carries its rail with it.

- [ ] **Step 3: Retune the two existing entrances to the shared easing**

`.prompt-hud` (L182) and `.rig-menu` (L231) already animate at `250ms cubic-bezier(0.16, 1, 0.3, 1)` — the same curve, spelled out by hand. Swap both to the tokens so all four entrances stay in sync:

```css
  animation: slideFromBottom var(--dur-base) var(--ease-out);   /* .prompt-hud */
  animation: slideFromRight  var(--dur-base) var(--ease-out);   /* .rig-menu   */
```

Leave `.rig-flyout-panel`'s `slideLeft 200ms ease-out` alone — it is a nested reveal, not a surface entrance, and Task 10 handles the rig menu.

- [ ] **Step 4: Confirm `.rig-menu` still declares `background: transparent` verbatim**

Run: `npx rg -n -A 10 "^\.rig-menu \{" web/src/style.css`
Expected: the rule still contains the literal line `background: transparent;`. You only changed its `animation` line, so this should hold — confirm it anyway.

The reason is a late, expensive failure mode. `rigMenuBundleRebuild.exploration.test.ts:99` asserts the **built** `.rig-menu` rule body contains `background:transparent`, string-scanning minified CSS. That test reads `web/dist`, which is not rebuilt until Task 11 — so tidying this rule away here would not surface for another six tasks.

- [ ] **Step 5: Run the full suite**

Run: `npm test`
Expected: `Test Files 17 passed (17)`, `Tests 63 passed (63)`.

`rigMenuHudStyle.exploration.test.tsx` asserts `.rig-menu` has no `var(--bg)`, `var(--border)`, `var(--accent)`, `box-shadow`, or `backdrop-filter`. `var(--dur-base)` and `var(--ease-out)` are none of those, so it stays green — but re-read the failure output carefully if it does not.

- [ ] **Step 6: Commit**

```bash
git add web/src/style.css
git commit -m "feat(hud): add the shared motion keyframes and panel entrance

panelIn/riseIn/rowIn are the Tier B vocabulary every surface draws from,
all on transform and opacity. .hud-panel enters from the right, matching
RigMenu's slideFromRight, so the gameplay HUD and the G menu now share
one entrance direction.

.prompt-hud and .rig-menu already used this exact curve spelled out by
hand; they now reference the tokens instead."
```

---

### Task 6: CastBar motion and FishingInfoCard stagger

**Files:**
- Modify: `web/src/components/CastBar.tsx`, `web/src/components/FishingInfoCard.tsx`
- Modify: `web/src/style.css`

**Interfaces:**
- Consumes: `riseIn`/`rowIn` (Task 5), `.hud-panel--warn` (Task 2).
- Produces: nothing later tasks depend on.

`CastBar` already receives `state` from `App.tsx:65` and has never used it. `client/casting.lua` sends `'start'` (L43), `'charge'` (L67) and `'release'` (L74).

- [ ] **Step 1: Consume the `state` prop**

Replace `web/src/components/CastBar.tsx` in full:

```tsx
import { t } from '../i18n'

export default function CastBar(props: { power: number; state?: string }) {
  const pct = Math.round(props.power * 100)
  // client/casting.lua ส่ง state = 'start' | 'charge' | 'release'
  const charging = props.state === 'start' || props.state === 'charge'
  const released = props.state === 'release'
  const nearMax = charging && pct > 90

  const panelClass = [
    'hud-panel',
    'cast-panel',
    charging ? 'hud-panel--warn' : '',
    released ? 'cast-panel--released' : '',
  ]
    .filter(Boolean)
    .join(' ')

  const fillClass = [
    'bar-fill',
    'cast-fill',
    charging ? 'cast-fill--charging' : '',
    nearMax ? 'cast-fill--near-max' : '',
  ]
    .filter(Boolean)
    .join(' ')

  return (
    <div className={panelClass}>
      <div className="panel-title">{t('ui_cast_title')}</div>
      <div className="bar-track">
        <div className={fillClass} style={{ width: `${pct}%` }} />
        {[25, 50, 75].map((x) => (
          <div key={x} className="bar-tick" style={{ left: `${x}%` }} />
        ))}
      </div>
      <div className="bar-caption">{pct}%</div>
    </div>
  )
}
```

- [ ] **Step 2: Add the cast motion**

Append to `web/src/style.css`:

```css
/* cast bar */
.cast-fill--charging {
  background-image: linear-gradient(
    100deg,
    transparent 40%,
    rgba(255, 255, 255, 0.35) 50%,
    transparent 60%
  );
  background-size: 200% 100%;
  animation: castSheen 1.1s linear infinite;
}

.cast-fill--near-max {
  animation: castSheen 0.5s linear infinite, castPulse 0.4s ease-in-out infinite;
}

@keyframes castSheen {
  from { background-position: 200% 0; }
  to   { background-position: -100% 0; }
}

@keyframes castPulse {
  0%, 100% { filter: brightness(1); }
  50%      { filter: brightness(1.55); }
}

.cast-panel--released {
  transform-origin: left;
  animation: castRelease var(--dur-base) var(--ease-out);
}

@keyframes castRelease {
  0%   { transform: scaleX(1); }
  40%  { transform: scaleX(1.02); }
  100% { transform: scaleX(1); }
}
```

`.cast-fill` keeps its `transition: width 60ms linear` inherited from `.bar-fill`. That value is driven by the Lua charge loop, not the RAF engine, and the 60ms smoothing is a proven setting — do not change it. The animations above touch `background-position` and `filter` only, never `width`.

`transform-origin: left` anchors the release pop to the rail.

- [ ] **Step 3: Stagger the info rows**

Replace `web/src/components/FishingInfoCard.tsx` in full:

```tsx
import { t } from '../i18n'

export default function FishingInfoCard(props: { rod?: string; bait?: string; distance?: number }) {
  return (
    <div className="hud-panel info-card">
      <div className="panel-title">{t('ui_info_title')}</div>
      <div className="info-row" style={{ animationDelay: '0ms' }}>
        <span>{t('ui_info_rod')}</span><b>{props.rod ?? '-'}</b>
      </div>
      <div className="info-row" style={{ animationDelay: '60ms' }}>
        <span>{t('ui_info_bait')}</span><b>{props.bait ?? '-'}</b>
      </div>
      {props.distance != null && (
        <div className="info-row" style={{ animationDelay: '120ms' }}>
          <span>{t('ui_info_distance')}</span><b>{props.distance.toFixed(1)} m</b>
        </div>
      )}
    </div>
  )
}
```

- [ ] **Step 4: Animate the rows**

Append one declaration to the existing `.info-row` rule (L62-68):

```css
  animation: rowIn var(--dur-base) var(--ease-out) both;
```

`both` is required — without it the rows flash at full opacity before their delay elapses.

- [ ] **Step 5: Run the full suite**

Run: `npm test`
Expected: `Test Files 17 passed (17)`, `Tests 63 passed (63)`.

- [ ] **Step 6: Commit**

```bash
git add web/src/components/CastBar.tsx web/src/components/FishingInfoCard.tsx web/src/style.css
git commit -m "feat(hud): put the cast state prop to work, stagger the info rows

CastBar has accepted a state prop since it was written and never read
it. It now drives the whole surface: charging turns the rail amber and
sweeps a sheen across the fill, past 90% the fill pulses, and release
pops the panel from the rail.

All of it rides on background-position and filter — the fill's own
width keeps the 60ms smoothing it has always had, because that value
comes from the Lua charge loop, not the RAF engine."
```

---

### Task 7: WaitingHud — idle ripple and the bite beat

The bite alert is the highest-stakes moment in the loop. The existing treatment is a continuous `shake` on the text, which is fatiguing and reads as cheap.

**Files:**
- Modify: `web/src/components/WaitingHud.tsx`
- Modify: `web/src/style.css`
- Modify: `locales/th.json`, `locales/en.json` (`ui_bite_prompt` only)

**Interfaces:**
- Consumes: `renderWithKeycaps` from `./Keycap` (Task 3), `.hud-panel--warn` (Task 2).
- Produces: nothing later tasks depend on.

- [ ] **Step 1: Rewrite the component**

Replace `web/src/components/WaitingHud.tsx` in full:

```tsx
import { t } from '../i18n'
import { renderWithKeycaps } from './Keycap'

export default function WaitingHud(props: { phase: 'waiting' | 'bite' }) {
  if (props.phase === 'bite') {
    return (
      <div className="hud-panel hud-panel--warn bite-panel">
        <div className="bite-text">{t('ui_bite')}</div>
        <div className="bite-prompt">{renderWithKeycaps(t('ui_bite_prompt'), 'urgent')}</div>
      </div>
    )
  }
  return (
    <div className="hud-panel waiting-panel">
      <span className="waiting-ripple" />
      <span>{t('ui_waiting')}</span>
    </div>
  )
}
```

- [ ] **Step 2: Replace the waiting dot with a ripple**

Delete the `.waiting-dot` rule (L103-107) and the `@keyframes pulse` rule (L108). They have no other consumer once Step 1 lands. Add:

```css
.waiting-ripple {
  position: relative;
  flex-shrink: 0;
  width: 1.1vh;
  height: 1.1vh;
  background: var(--accent);
}

.waiting-ripple::after {
  content: '';
  position: absolute;
  inset: 0;
  border: 1px solid var(--accent);
  animation: ripple 1.8s ease-out infinite;
}

@keyframes ripple {
  from { transform: scale(1);   opacity: 0.8; }
  to   { transform: scale(2.8); opacity: 0; }
}
```

- [ ] **Step 3: Replace the bite shake with an entrance plus a two-beat**

Delete `@keyframes shake` (L119-123) — `.bite-text` was its only consumer. Replace the `.bite-text` and `.bite-prompt` rules (L112-118) with:

```css
.bite-panel { text-align: center; animation: biteIn 180ms var(--ease-out); }

.bite-text {
  font-size: 2.6vh;
  font-weight: 700;
  color: var(--warn);
  text-shadow: var(--hud-shadow-text), 0 0 12px rgba(217, 160, 63, 0.55);
  animation: biteBeat 0.9s steps(1, end) infinite;
}

.bite-prompt { font-size: 1.6vh; margin-top: 0.6vh; color: var(--text); }

@keyframes biteIn {
  0%   { opacity: 0; transform: scale(0.9); }
  60%  { opacity: 1; transform: scale(1.06); }
  100% { transform: scale(1); }
}

@keyframes biteBeat {
  0%, 49%   { opacity: 1; }
  50%, 100% { opacity: 0.72; }
}
```

`biteBeat` and the `keycap--urgent` animation from Task 3 both run at `0.9s`, so the text and the `[SPACE]` chip pulse on the same beat.

`.bite-panel` sets its own `animation`, which overrides the `panelIn` it inherits from `.hud-panel` — intended: the bite deserves a sharper entrance than a normal panel. That override works purely on source order: `.hud-panel` and `.bite-panel` are both single-class selectors, so specificity ties and the later rule wins. `.hud-panel` sits near L53 (Task 2 placed it just below the old `.panel`) and `.bite-panel` sits near L111. **Keep `.bite-panel` below `.hud-panel` in the file.** Reordering them silently reverts the bite entrance to `panelIn`.

- [ ] **Step 4: Bracket `ui_bite_prompt` now that the component renders it through the chip**

Brackets are the only change; the wording stays exactly as it is today.

`locales/th.json` — from `"กด SPACE"` to:
```json
  "ui_bite_prompt": "กด [SPACE]",
```

`locales/en.json` — from `"PRESS SPACE"` to:
```json
  "ui_bite_prompt": "PRESS [SPACE]",
```

Leave `ui_reel_title` alone — Task 8 owns it. Leave `equip_hint` and `rig_button_label` alone permanently.

- [ ] **Step 5: Verify no orphans remain**

Run: `npx rg -n "waiting-dot|keyframes pulse|keyframes shake" web/src`
Expected: no hits.

- [ ] **Step 6: Run the full suite**

Run: `npm test`
Expected: `Test Files 17 passed (17)`, `Tests 63 passed (63)`.

- [ ] **Step 7: Commit**

```bash
git add web/src/components/WaitingHud.tsx web/src/style.css locales/th.json locales/en.json
git commit -m "feat(hud): ripple while waiting, a real beat when the fish bites

The waiting dot becomes an expanding ripple ring, reading as a float
bobbing on water. The bite alert drops its continuous shake — jitter on
text you are trying to read is fatiguing — for a sharp scale entrance
followed by a two-beat pulse. The [SPACE] keycap runs on the same 0.9s
period, so text and chip pulse together.

Removes @keyframes pulse and @keyframes shake along with .waiting-dot;
this change was their only consumer.

ui_bite_prompt gains its [SPACE] brackets in this commit rather than
with the Keycap component, so the string is never rendered raw."
```

---

### Task 8: TensionMinigame — in-zone feedback and the over-tension vignette

**The Tier A boundary lives in this file.** `TensionMinigame` calls `setState` on every animation frame (`TensionMinigame.tsx:39-57`). Anything given a timed CSS transition here will visibly trail the engine and cost the player fish.

**Files:**
- Modify: `web/src/components/TensionMinigame.tsx`
- Modify: `web/src/style.css`
- Modify: `locales/th.json`, `locales/en.json` (`ui_reel_title` only)

**Interfaces:**
- Consumes: `.hud-panel--danger` (Task 2), `.reel-panel { position: relative }` (Task 4), `renderWithKeycaps` (Task 3).
- Produces: nothing later tasks depend on.

`EngineState` (`web/src/engine/minigameEngine.ts:11-21`) exposes `tension`, `greenLo`, `greenHi`, `overTension`, `energyPct`. Everything below derives from those — no engine change.

- [ ] **Step 1: Derive `inZone` and render the title through keycaps**

In `web/src/components/TensionMinigame.tsx`, add the import:

```tsx
import { renderWithKeycaps } from './Keycap'
```

Then replace the returned JSX (currently L64-88) with:

```tsx
  // อยู่ในโซนเขียวไหม — เป็น boolean ที่ derive จาก state ทำให้ class เปลี่ยนเฉพาะตอน
  // ข้ามขอบเขต ไม่ใช่ทุก frame ส่วนตำแหน่ง (left/width) ยังเป็น inline style ล้วน ๆ
  const inZone = state.tension >= state.greenLo && state.tension <= state.greenHi

  return (
    <div className={`hud-panel reel-panel${state.overTension ? ' hud-panel--danger danger' : ''}`}>
      <div className="panel-title">{renderWithKeycaps(t('ui_reel_title'))}</div>

      <div className="bar-label">{t('ui_reel_tension')}</div>
      <div className="bar-track tension-track">
        <div
          className={`green-zone${inZone ? ' green-zone--hit' : ''}`}
          style={{ left: `${state.greenLo}%`, width: `${state.greenHi - state.greenLo}%` }}
        />
        <div
          className={`tension-marker${state.overTension ? ' danger' : ''}`}
          style={{ left: `${state.tension}%` }}
        />
      </div>

      <div className="bar-row">
        <div className="bar-label">{t('ui_reel_energy')}</div>
        <div className="bar-caption">{Math.round(state.energyPct)}%</div>
      </div>
      <div className="bar-track">
        <div className="bar-fill energy-fill" style={{ width: `${state.energyPct}%` }} />
      </div>
    </div>
  )
```

Note `const inZone` sits inside the component body, immediately before `return` — after the `useEffect`, not inside it.

- [ ] **Step 2: Add the in-zone glow and the vignette**

Replace the `.green-zone` rule (L129-135) with the version below and append the rest. Read the comment before changing any of it.

```css
/* Tier A: ตำแหน่ง (left/width) ของ green zone มาจาก engine ทุก frame — transition
   ด้านล่างระบุเฉพาะ background/box-shadow เท่านั้น ห้ามเปลี่ยนเป็น `all` เด็ดขาด
   ไม่งั้นโซนเขียวจะไถลตามหลัง engine */
.green-zone {
  position: absolute;
  top: 0;
  height: 100%;
  background: var(--accent-dim);
  border-left: 1px solid var(--accent);
  border-right: 1px solid var(--accent);
  transition: background var(--dur-fast) linear, box-shadow var(--dur-fast) linear;
}

.green-zone--hit {
  background: rgba(69, 184, 164, 0.32);
  box-shadow: inset 0 0 10px rgba(69, 184, 164, 0.6);
}

/* over-tension: ขอบแดงเต้น ไม่ใช่ shake — สั่นแถบที่ต้องเล็งทำให้เล็งพลาด */
.reel-panel.danger::after {
  content: '';
  position: absolute;
  inset: 0;
  pointer-events: none;
  box-shadow: inset 0 0 3vh rgba(207, 95, 95, 0.45);
  animation: dangerVignette 0.5s ease-in-out infinite;
}

@keyframes dangerVignette {
  0%, 100% { opacity: 0.35; }
  50%      { opacity: 1; }
}
```

- [ ] **Step 3: Bracket `ui_reel_title` now that the title renders through the chip**

Brackets are the only change; the wording stays exactly as it is today.

`locales/th.json` — from `"ดึงปลา — กด SPACE ค้าง"` to:
```json
  "ui_reel_title": "ดึงปลา — กด [SPACE] ค้าง",
```

`locales/en.json` — from `"Reel — hold SPACE"` to:
```json
  "ui_reel_title": "Reel — hold [SPACE]",
```

This is the last locale edit in the plan. `equip_hint` and `rig_button_label` remain untouched.

- [ ] **Step 4: Confirm the Tier A guard still holds**

Run: `npx vitest --run src/__tests__/hudStyle.test.tsx`
Expected: PASS, 5 tests — in particular `.tension-marker declares no transition duration` and `.energy-fill declares no transition duration`.

`.green-zone` is deliberately **not** in the guard set: it legitimately carries a `120ms` transition on `background`/`box-shadow`, and the guard regex would reject it. Its positional properties are inline styles, which no stylesheet rule can transition.

- [ ] **Step 5: Confirm the marker is genuinely untransitioned**

Run: `npx rg -n "transition" web/src/style.css`
Read every hit. Confirm that neither `.tension-marker`, `.energy-fill`, nor `.bar-fill`-with-a-duration applies to the marker. Expected: `.bar-fill` has `width 60ms linear` (cast bar only, overridden on `.energy-fill`), `.energy-fill` has `none`, `.tension-marker` has `none`, `.green-zone` names only `background` and `box-shadow`, and the rig/button rules are unrelated.

- [ ] **Step 6: Run the full suite**

Run: `npm test`
Expected: `Test Files 17 passed (17)`, `Tests 63 passed (63)`.

- [ ] **Step 7: Commit**

```bash
git add web/src/components/TensionMinigame.tsx web/src/style.css locales/th.json locales/en.json
git commit -m "feat(hud): show the player when they are in the zone

The green zone now glows while the marker is inside it — moment-to-moment
feedback the reel minigame had none of. inZone is a boolean derived from
engine state, so the class only changes when the marker crosses an edge,
and its transition names background and box-shadow explicitly. Position
stays untransitioned inline style.

Over-tension gets a pulsing red edge vignette rather than a shake:
shaking a bar the player is aiming at hurts their aim."
```

---

### Task 9: CatchCard reveal sequence

The reward beat. Longest sequence in the HUD, ~740ms end to end.

**Files:**
- Modify: `web/src/components/CatchCard.tsx`
- Modify: `web/src/style.css`

**Interfaces:**
- Consumes: `riseIn` (Task 5), `.hud-btn` (Task 4).
- Produces: nothing later tasks depend on.

- [ ] **Step 1: Break the star string into elements**

`'★'.repeat(q) + '☆'.repeat(5 - q)` is a single text node, so the stars cannot be animated individually. Replace `web/src/components/CatchCard.tsx` in full:

```tsx
import { fetchNui } from '../hooks/useNui'
import { t } from '../i18n'

export default function CatchCard(props: { label?: string; weight?: number; quality?: number }) {
  const quality = props.quality ?? 0
  // แตกเป็น element ละดวงเพื่อให้หน่วงเวลาเติมทีละดาวได้
  const stars = Array.from({ length: 5 }, (_, i) => i < quality)

  return (
    <div className="hud-panel catch-card">
      <div className="panel-title">{t('ui_catch_title')}</div>
      <div className="catch-name">{props.label ?? '-'}</div>
      <div className="catch-weight">{(props.weight ?? 0).toFixed(2)} kg</div>
      <div className="catch-stars">
        {stars.map((filled, i) => (
          <span
            key={i}
            className={`catch-star${filled ? ' catch-star--filled' : ''}`}
            style={{ animationDelay: `${260 + i * 90}ms` }}
          >
            {filled ? '★' : '☆'}
          </span>
        ))}
      </div>
      <div className="catch-actions">
        <button className="hud-btn hud-btn--primary" onClick={() => fetchNui('keep')}>
          {t('ui_keep')}
        </button>
        <button className="hud-btn" onClick={() => fetchNui('release')}>
          {t('ui_release')}
        </button>
      </div>
    </div>
  )
}
```

- [ ] **Step 2: Sequence the reveal**

Replace the `.catch-name`, `.catch-weight`, `.catch-stars` and `.catch-actions` rules (L150-153) with:

```css
/* catch card — ลำดับเวลา: ชื่อ 60ms, น้ำหนัก 140ms, ดาว 260ms +90ms/ดวง, ปุ่ม 740ms */
.catch-name {
  font-size: 2.4vh;
  font-weight: 700;
  animation: riseIn var(--dur-base) var(--ease-out) 60ms both;
}

.catch-weight {
  font-size: 1.7vh;
  color: var(--muted);
  margin-top: 0.4vh;
  animation: riseIn var(--dur-base) var(--ease-out) 140ms both;
}

.catch-stars {
  font-size: 2vh;
  margin: 0.8vh 0 1.2vh;
  letter-spacing: 0.2em;
  color: var(--muted);
}

.catch-star {
  display: inline-block;
  animation: starPop 260ms var(--ease-out) both;
}

.catch-star--filled { color: var(--warn); }

.catch-actions {
  display: flex;
  gap: 0.6vw;
  justify-content: center;
  animation: riseIn var(--dur-base) var(--ease-out) 740ms both;
}

@keyframes starPop {
  0%   { opacity: 0; transform: scale(0.4); }
  60%  { opacity: 1; transform: scale(1.25); }
  100% { opacity: 1; transform: scale(1); }
}
```

`display: inline-block` on `.catch-star` is required — `transform` has no effect on an inline box. The last star starts at `260 + 4*90 = 620ms` and runs 260ms, so the buttons at `740ms` arrive while it is still settling. That overlap is intended.

`.catch-stars` moves its amber to `.catch-star--filled` so empty stars read as muted rather than dim amber.

- [ ] **Step 3: Run the full suite**

Run: `npm test`
Expected: `Test Files 17 passed (17)`, `Tests 63 passed (63)`.

- [ ] **Step 4: Commit**

```bash
git add web/src/components/CatchCard.tsx web/src/style.css
git commit -m "feat(hud): sequence the catch reveal

Name, then weight, then the stars filling one at a time, then the
buttons — about 740ms end to end. The stars had to stop being a single
'★'.repeat() string before any of them could animate separately; they
are now one element each, and empty stars read muted instead of dim
amber."
```

---

### Task 10: RigMenu — token adoption and entrance stagger

RigMenu is the exemplar. Touch it as little as possible.

**⚠ Global Constraint 3 applies directly to this task.** Do not change the `color:` value of `.rig-menu__title`, `.rig-menu__hint`, `.rig-menu__empty`, `.rig-category-card__title`, `.rig-category-card__status`, or `.rig-item-row__label`. Replacing their `text-shadow` value with the token is fine; replacing their colour is not.

**Files:**
- Modify: `web/src/style.css` (the rig rules, L245-543)
- Modify: `web/src/components/RigMenu.tsx`

**Interfaces:**
- Consumes: `--hud-shadow-text`, `--ease-out` (Task 2), `rowIn` (Task 5).
- Produces: nothing later tasks depend on.

- [ ] **Step 1: Hoist the repeated text-shadow literal onto the token**

Across the rig rules in `style.css`, replace every occurrence of the literal value:

```css
  text-shadow: 0 1px 3px rgba(0, 0, 0, 0.9);
```

with:

```css
  text-shadow: var(--hud-shadow-text);
```

`--hud-shadow-text` is defined as exactly that value, so this is a no-op visually. Change **only** the `text-shadow` declarations. Leave every `color:` untouched.

- [ ] **Step 2: Prove the six locked selectors still satisfy their guard**

Run: `npx rg -n "rig-menu__title|rig-menu__hint|rig-menu__empty|rig-category-card__title|rig-category-card__status|rig-item-row__label" web/src/style.css -A 6`

Read the output and confirm for each of the six: `text-shadow` is present, and its `color` is still `#fff` or `rgba(255, 255, 255, …)`. `rgba(255,255,255,0.8)` minifies to `#fffc`, which contains the `#fff` substring the built-bundle test looks for. Any of these six sitting on `var(--text)` is a defect — revert it.

- [ ] **Step 3: Stagger the category cards**

In `web/src/components/RigMenu.tsx`, pass the index down. Change the `categories.map` call (L92-101) to:

```tsx
            {categories.map((cat, index) => (
              <CategoryCard
                key={cat.partType}
                category={cat}
                index={index}
                isActive={currentCategory?.partType === cat.partType}
                isLocked={lockedCategory === cat.partType}
                onHover={() => handleCategoryHover(cat.partType)}
                onClick={() => handleCategoryClick(cat.partType)}
              />
            ))}
```

Then add `index` to `CategoryCard`'s props (L109-121) and apply it:

```tsx
function CategoryCard({
  category,
  index,
  isActive,
  isLocked,
  onHover,
  onClick,
}: {
  category: CategoryGroup
  index: number
  isActive: boolean
  isLocked: boolean
  onHover: () => void
  onClick: () => void
}) {
```

and on the card's root element (L127-133):

```tsx
    <div
      className={`rig-category-card ${isActive ? 'rig-category-card--active' : ''} ${
        isLocked ? 'rig-category-card--locked' : ''
      }`}
      style={{ animationDelay: `${index * 50}ms` }}
      onMouseEnter={onHover}
      onClick={onClick}
    >
```

- [ ] **Step 4: Animate the cards**

Append one declaration to the existing `.rig-category-card` rule (L282-289):

```css
  animation: rowIn var(--dur-base) var(--ease-out) both;
```

Leave that rule's existing `transition: all 150ms ease` alone. It predates this work and drives the hover state; Global Constraint 4 governs new CSS.

- [ ] **Step 5: Run the rig tests specifically**

Run: `npx vitest --run src/__tests__/rigMenuHudStyle.exploration.test.tsx src/__tests__/rigMenuPreservation.test.tsx src/__tests__/rigMenuIconPreservation.test.tsx src/components/__tests__/RigMenu.test.tsx`
Expected: all PASS. `rigMenuHudStyle` checks `.rig-menu__title` and `.rig-category-card__title` still declare `text-shadow` — `var(--hud-shadow-text)` satisfies it.

One thing the tests cannot see: `animationDelay` is an inline style, so it is re-applied on every React re-render, and `.rig-category-card` re-renders on hover. The delay value does not change between renders, so `rowIn` should not restart — but this is the one surface in the plan where a stagger sits on a frequently re-rendering element. Note it for the manual pass; if hovering visibly re-triggers the entrance, move the delay into `:nth-child()` rules in CSS instead.

- [ ] **Step 6: Run the full suite**

Run: `npm test`
Expected: `Test Files 17 passed (17)`, `Tests 63 passed (63)`.

`rigMenuBundleRebuild.exploration.test.ts` reads the **built** `web/dist` CSS, not source, so it still passes against the pre-redesign bundle at this point. Task 11 is where it is genuinely re-validated.

- [ ] **Step 7: Commit**

```bash
git add web/src/style.css web/src/components/RigMenu.tsx
git commit -m "refactor(hud): put RigMenu on the shared tokens, stagger its cards

The literal '0 1px 3px rgba(0,0,0,.9)' appeared in roughly fifteen rig
rules; it is now --hud-shadow-text. Colours are deliberately untouched:
rigMenuBundleRebuild asserts six rig selectors contain the literal #fff
in the built bundle, and .rig-category-card__status only satisfies that
because rgba(255,255,255,0.8) minifies to #fffc. Tokenizing those
colours would break a build-time check with no source-level hint why.

Category cards enter staggered, matching the gameplay panels."
```

---

### Task 11: Build, full verification, and commit the bundle

`web/dist` is a committed artifact that `fxmanifest.lua` points at. Rebuilding once at the end keeps ten intermediate bundle diffs out of history.

**Files:**
- Modify: `web/dist/**` (generated)

**Interfaces:**
- Consumes: everything.
- Produces: the shipped bundle.

- [ ] **Step 1: Typecheck and build**

Run: `npm run build`
Expected: `tsc` reports no errors, then vite writes `dist/`. If `tsc` fails, fix the type error — do not skip the build.

- [ ] **Step 2: Confirm the built CSS reflects the redesign**

Run: `npx rg -o "\.hud-panel\{[^}]*\}" web/dist/assets/index-*.css`
Expected: one match, containing `background:transparent` and `border-left`, and containing none of `var(--bg)`, `box-shadow`, `backdrop-filter`.

Run: `npx rg -o "\.rig-category-card__status\{[^}]*\}" web/dist/assets/index-*.css`
Expected: the declaration still contains `#fffc` and `text-shadow`. This is the Global Constraint 3 check against the real artifact.

- [ ] **Step 3: Confirm `.panel` is gone from the bundle**

Run: `npx rg -c "\.panel\{" web/dist/assets/index-*.css`
Expected: no match. `.panel-title` still exists and is fine — the pattern above requires the `{` immediately after `.panel`.

- [ ] **Step 4: Run the full suite against the fresh bundle**

Run: `npm test`
Expected: `Test Files 17 passed (17)`, `Tests 63 passed (63)`.

This is the run that matters most: `bundleRebuildPreservation.test.ts` and `rigMenuBundleRebuild.exploration.test.ts` both parse `web/dist`, so only now are they judging the redesigned bundle. Compare against the recorded baseline of 15 files / 55 tests: the delta should be exactly −2 tests from Task 1 and +10 from Tasks 2 and 3.

- [ ] **Step 5: Confirm no Lua file was touched**

Run: `git diff --name-only main -- '*.lua'`
Expected: empty. If anything appears, it violates Global Constraint 1 — revert it.

- [ ] **Step 6: Commit the bundle**

```bash
git add web/dist
git commit -m "build: rebuild the NUI bundle for the Water HUD redesign

web/dist is a committed artifact that fxmanifest.lua serves as ui_page,
and two preservation tests parse it rather than the source, so this is
the commit where those two are genuinely re-validated.

No deploy step: the deploy copy path named in
rigMenuBundleRebuild.exploration.test.ts does not exist on this machine,
so that test's deploy assertion early-returns."
```

- [ ] **Step 7: Final branch review**

Hand the whole branch to an **opus** reviewer (chosen during brainstorming). Ask specifically about:

1. Any timed transition reachable by `.tension-marker`, `.green-zone` position, or `.energy-fill` width.
2. Any of the six Global Constraint 3 selectors whose colour drifted onto a token.
3. Keyframes or classes left orphaned by the migration — `rg` for `.panel`, `.btn`, `waiting-dot`, `keyframes pulse`, `keyframes shake` across `web/src`.
4. Whether every deletion in Task 1 was a retired guard rather than a live one.

---

## Deviations from the spec, recorded

- **Spec §4.1 rail-draw animation.** The spec's first draft described the rail drawing in with its own `scaleY`. Implementing that needs a pseudo-element rail, which would break the §8.2 assertion that `.hud-panel` declares `border-left` and would stop mirroring RigMenu's `border-left` idiom. The rail is a static `border-left` and the entrance is a single `panelIn` slide carrying it. The spec was amended to match before this plan was written.

## Known pre-existing issues (noted, not fixed)

- `.rig-menu__header` is rendered at `RigMenu.tsx:85` but has no rule in `style.css`. Pre-existing dead class; `CLAUDE.md` §3 says leave it.
- `.rig-category-card` carries `transition: all 150ms ease`. Pre-existing; Global Constraint 4 governs new CSS only.
- `--bg`, `--shadow`, and `--accent-dim` remain defined in `:root` after `.panel` is deleted. `--accent-dim` is still used by `.green-zone`; the other two may end up unreferenced outside `admin.css`. Removing them is out of scope.
