# zfishing HUD Redesign — "Water HUD"

Date: 2026-08-18
Status: Approved design, ready for implementation planning
Scope: `web/src` NUI layer only. No Lua changes.

---

## 1. Problem

The zfishing NUI currently ships **two conflicting visual languages**:

| Surface | Language | Defined at |
|---|---|---|
| Gameplay panels — CastBar, FishingInfoCard, WaitingHud, TensionMinigame, CatchCard | Opaque dark card: `--bg` ground, 1px hairline border, 2px left accent rail, `box-shadow`, `backdrop-filter: blur(4px)` | `web/src/style.css` `.panel` (L43-52) |
| RigMenu (G menu) + PromptHud | Fully transparent, no box, no border, no shadow; legibility from `text-shadow: 0 1px 3px rgba(0,0,0,.9)` | `.rig-menu` (L223), `.prompt-hud` (L170) |

The transparent language is the newer, deliberate one — it was introduced by the
`fishing-rig-menu-hud-style-fix` spec and is enforced by
`web/src/__tests__/rigMenuHudStyle.exploration.test.tsx:95-102`, which asserts
`.rig-menu` must NOT contain `var(--bg)`, `var(--border)`, `var(--accent)`,
`box-shadow`, or `backdrop-filter`.

Separately, the gameplay panels have almost **no motion**. RigMenu has real
interaction (hover → flyout, click → lock, accordion, `slideFromRight`,
`slideLeft`), while gameplay surfaces have only `pulse` (waiting dot) and
`shake` (bite text).

## 2. Goal

One visual language across every NUI surface, with RigMenu/PromptHud as the
exemplar, plus a reactive motion layer so every meaningful game event produces
visible feedback.

Success criteria:

1. Every gameplay panel renders with no opaque box — no `var(--bg)` ground, no
   box border, no `box-shadow`, no `backdrop-filter`.
2. A single shared signature (the left accent rail) ties every surface together,
   including RigMenu's existing category cards.
3. Every state change in the fishing loop has a motion response.
4. Per-frame engine-driven values have **zero** CSS transitions.
5. `npm run test` green; `npm run build` produces a committed `web/dist`.

## 3. Decisions taken (locked by the user during brainstorming)

- **D1 — Direction of travel.** RigMenu / PromptHud are the exemplar. The five
  gameplay panels move to the transparent language. RigMenu itself is touched
  minimally (token adoption + entrance stagger); its structure is not rebuilt.
- **D2 — Legibility strategy.** `text-shadow` on all text, **plus a localized
  scrim behind bar tracks only**. Rationale: a 1px tension marker on a fully
  translucent track is unreadable over bright daylight water, and misreading it
  costs the player the fish. Bar tracks are the only element in the HUD that
  keeps a ground.
- **D3 — Motion budget.** Reactive: every event gets feedback (enter/exit, cast
  charge, bite, over-tension, in-zone, catch reveal, button press). Hand-rolled
  CSS keyframes — no motion library.
- **D4 — Preservation test.** `bundleRebuildPreservation.test.ts` is pruned down
  to only the selectors and files this redesign does not touch. See §8.

## 4. Visual language

### 4.1 The rail is the signature

`.panel` is replaced by `.hud-panel`:

```
.hud-panel {
  background: transparent;
  border: none;
  border-left: 2px solid var(--rail, var(--accent));
  padding: 1.4vh 1.2vw;
  color: var(--text);
  min-width: 16vw;
}
```

`.hud-panel` is a new selector, so it declares no `box-shadow` and no
`backdrop-filter` at all rather than resetting them to `none` — the §8.2 guard
asserts those declaration names are *absent*, which a `none` reset would defeat.

`--rail` is a per-panel local custom property, set by modifier classes on the
same element (`.hud-panel--warn { --rail: var(--warn) }`,
`.hud-panel--danger { --rail: var(--danger) }`). Unset, it falls back to
`--accent`.

The left rail is retained because RigMenu already uses one — `.rig-category-card`
carries `border-left: 3px solid` and flips it to `var(--accent)` on hover/active
(`style.css:282-299`). Making the rail the sole surviving chrome is what unifies
gameplay panels with the G menu.

The rail is also a **state channel and a motion element**:

| Rail colour | Meaning |
|---|---|
| `--accent` (teal) | Idle / normal |
| `--warn` (amber) | Cast charging, fish biting |
| `--danger` (red) | Over-tension |

The rail is a static `border-left` on `.hud-panel` itself, not a pseudo-element.
Two reasons: it mirrors RigMenu's existing `border-left` idiom exactly, and the
§8.2 guard asserts `.hud-panel` declares `border-left`. Panel entrance is a
single slide+fade on the whole panel (`panelIn`), which carries the rail with
it — a separately animated rail was dropped as unnecessary.

Note: this does not conflict with `rigMenuHudStyle.exploration.test.tsx`. That
test constrains the `.rig-menu` container rule specifically; `.hud-panel` is a
new selector and `.rig-category-card` (which legitimately uses `var(--accent)`)
is unaffected.

### 4.2 Tokens

Added to `:root` in `style.css`:

```
--hud-shadow-text: 0 1px 3px rgba(0, 0, 0, 0.9);
--hud-scrim: rgba(6, 10, 14, 0.55);
--ease-out: cubic-bezier(0.16, 1, 0.3, 1);
--dur-fast: 120ms;
--dur-base: 220ms;
--dur-slow: 380ms;
```

`--hud-shadow-text` hoists the literal `0 1px 3px rgba(0, 0, 0, 0.9)` that is
currently hardcoded in ~15 rig rules. This is pure de-duplication with no visual
change, and it keeps `rigMenuHudStyle.exploration.test.tsx:116-117` passing
(that test asserts the declaration `text-shadow` is present — `text-shadow:
var(--hud-shadow-text)` still satisfies it).

### 4.3 Bar tracks — the one surviving ground (D2)

`.bar-track` keeps a background, now `var(--hud-scrim)` plus a 1px inset
hairline. It is the only opaque element left in the HUD.

`.tension-marker` becomes 2px wide white with a 1px dark outline
(`box-shadow: 0 0 0 1px rgba(0,0,0,.85)`) so it reads against both the scrim and
the teal green-zone fill.

### 4.4 Locked colour constraint (do not "tokenize" these six)

`rigMenuBundleRebuild.exploration.test.ts:106-118` asserts, against the **built**
`web/dist` CSS, that six selectors each contain both `text-shadow` and the
literal substring `#fff`:

`.rig-menu__title`, `.rig-menu__hint`, `.rig-menu__empty`,
`.rig-category-card__title`, `.rig-category-card__status`, `.rig-item-row__label`

The mechanism is load-bearing and invisible in source. `.rig-category-card__status`
is authored as `color: rgba(255, 255, 255, 0.8)` and only passes because the
minifier emits `#fffc`, which *contains* `#fff`. Verified against the current
bundle:

```
.rig-category-card__status{font-size:1.4vh;color:#fffc;text-shadow:0 1px 3px rgba(0,0,0,.9);margin-top:.3vh}
```

Therefore:

- Replacing these selectors' `text-shadow` value with `var(--hud-shadow-text)`
  is **safe** — the assertion matches the declaration name, not the value.
- Changing any of these six `color:` values to a token is **not safe**.
  `--text` is `#e8edf2`. A well-meaning "unify all colours onto tokens" pass is
  exactly how this breaks.

### 4.5 Corners

`* { border-radius: 0 !important }` (`style.css:19`) is an explicit existing
decision. The whole redesign is sharp-cornered, including the keycap chip
(§5), so there is no contradiction to resolve.

## 5. `Keycap` — the shared interaction primitive

A new component `web/src/components/Keycap.tsx` renders a key chip: sharp
rectangle, 1px border, 2px bottom edge line to read as a physical key,
`text-shadow` from the token.

A shared helper exported from `Keycap.tsx` splits a string on `[KEY]` runs and
returns React nodes:

```
renderWithKeycaps(text: string): ReactNode[]
```

It lives in `Keycap.tsx`, not `promptText.ts`, because it emits JSX and
`promptText.ts` is a `.ts` file whose pure string behaviour is locked by
`promptText.test.ts` and `localeTextPreservation.test.ts`. Those two files stay
untouched.

Call sites — three, which is what makes this a unifying idea rather than a
one-off:

1. **PromptHud subtitle.** `equip_hint` is already
   `"[E] เริ่มตกปลา   ·   [X] เก็บเบ็ด   ·   [G] จัดการเบ็ด"` and `cancel_hint`
   is `"[X] เก็บเบ็ด"` — brackets are already the locale convention. No locale
   change needed here.
2. **WaitingHud bite prompt.** `ui_bite_prompt` is currently `"กด SPACE"` /
   `"PRESS SPACE"` with no brackets. Update `locales/th.json` and
   `locales/en.json` to `"กด [SPACE]"` / `"PRESS [SPACE]"`.
3. **TensionMinigame title.** `ui_reel_title` is `"ดึงปลา — กด SPACE ค้าง"` /
   equivalent. Update to `"ดึงปลา — กด [SPACE] ค้าง"`.

Locale-change safety: the surviving preservation assertions cover `equip_hint`
(`[G] จัดการเบ็ด` / `[G] Manage Rod`) and `rig_button_label` only. `ui_*` keys
are not asserted anywhere. `localeTextPreservation.test.ts` covers only
`resolvePromptText` / `rigText` resolution behaviour for prompt and rig keys, not
`ui_*`.

DOM safety for `PromptHud.test.tsx`: that test queries `.prompt-title` and
`.prompt-subtitle` and checks document order. Splitting the subtitle's contents
into child spans keeps both elements and their order intact.

## 6. Motion architecture — two tiers

This is the single most failure-prone part of the design. `TensionMinigame`
drives a `requestAnimationFrame` loop that calls `setState` every frame
(`TensionMinigame.tsx:39-57`). Adding a CSS transition to anything that loop
writes makes the value visibly lag the engine. The existing
`transition: none` on `.energy-fill` and the `60ms linear` on `.bar-fill` are
prior evidence someone already hit this.

### Tier A — engine-driven, per frame, NO transitions

| Property | Element |
|---|---|
| `left` | `.tension-marker` |
| `left`, `width` | `.green-zone` |
| `width` | `.energy-fill` |

These MUST carry `transition: none`. A regression test guards this (§8).

`.cast-fill` keeps `transition: width 60ms linear`. Its power value comes from
the Lua charge loop (`client/casting.lua:67`), not from the RAF engine, and the
existing 60ms smoothing is a proven value — do not change it.

### Tier B — event-driven, keyframes on `transform` / `opacity` only

`.reel-panel.danger` is the seam between the tiers: it flips on a state change,
so it may animate, while the marker sitting inside it may not. Implementers must
not generalize "the reel panel animates" into "the marker animates".

Per surface:

| Surface | Motion |
|---|---|
| **PromptHud** (idle, holding rod) | Retune existing `slideFromBottom` to `--ease-out` / `--dur-base`. Keycap chips carry a slow breathe loop (opacity + 1% scale). |
| **CastBar** | The `state` prop is currently accepted and **never used** (`CastBar.tsx:3`). It takes on the work: `charge` → rail turns `--warn` and a sheen sweeps across the fill (`background-position` keyframe on a repeating gradient); `pct > 90` → fill gains a fast pulse; `release` → fill flash + a `scaleX(1 → 1.02 → 1)` pop. |
| **FishingInfoCard** | Rows enter staggered via per-row `animation-delay` (`translateY` + opacity). |
| **WaitingHud** — `waiting` | Replace the single pulsing dot with an expanding ripple ring (`transform: scale` + fading opacity) on `--dur-slow`, reading as a float bobbing on water. |
| **WaitingHud** — `bite` | Drop the continuous `shake` loop — continuous jitter is fatiguing and reads as cheap. Replace with a sharp entrance (`scale .9 → 1.06 → 1` over 180ms) followed by a two-beat urgency loop. The `[SPACE]` keycap pulses on the same beat. Panel background becomes transparent; the amber survives as rail colour + text glow. |
| **TensionMinigame** | Green zone gains a soft teal glow when the marker is inside it — feedback the player currently has none of. Over-tension shows a red edge vignette pulse (opacity keyframe on a pseudo-element), **not** a shake: shaking a precision bar hurts aim. Energy fill colour deepens as it drains via a static gradient on the track (zero JS). |
| **CatchCard** | The reward beat, ~700ms sequenced by `animation-delay`: rail draws in → fish name rises → weight rises → **stars fill one at a time with a scale pop** → buttons fade in last. Requires replacing `'★'.repeat(q)` (`CatchCard.tsx:5`) with an array of `<span>` so each star can animate independently. |
| **RigMenu** | Minimal: adopt `--hud-shadow-text` and `--ease-out` tokens, add an entrance stagger on `.rig-category-card`. Do not restructure — it is the reference. |

### `inZone` derivation

The green-zone glow is driven by a boolean derived from engine state
(`state.tension` within `[state.greenLo, state.greenHi]`). The class string only
changes when the boolean flips, not every frame, and its CSS transition applies
to `box-shadow`, never to position. This is acceptable; positional properties
stay in Tier A.

## 7. Component / file inventory

| File | Change |
|---|---|
| `web/src/style.css` | Main work: tokens, `.hud-panel`, scrim, keycap styles, all keyframes |
| `web/src/components/Keycap.tsx` | **New** — `Keycap` + `renderWithKeycaps` |
| `web/src/components/PromptHud.tsx` | Render subtitle through `renderWithKeycaps` |
| `web/src/components/CastBar.tsx` | Consume `state`; `.hud-panel` |
| `web/src/components/FishingInfoCard.tsx` | Stagger index on rows; `.hud-panel` |
| `web/src/components/WaitingHud.tsx` | Ripple; bite entrance; keycap; `.hud-panel` |
| `web/src/components/TensionMinigame.tsx` | `inZone` class; `.hud-panel` |
| `web/src/components/CatchCard.tsx` | Star array; `.btn`/`.btn-primary` → `.hud-btn`/`.hud-btn--primary`; `.hud-panel` |
| `web/src/components/RigMenu.tsx` | Stagger index only |
| `locales/th.json`, `locales/en.json` | Bracket `ui_bite_prompt`, `ui_reel_title` |
| `web/src/__tests__/bundleRebuildPreservation.test.ts` + `.snap` | Prune (§8) |
| `web/src/__tests__/hudStyle.test.tsx` | **New** (§8) |

## 8. Testing

Obsolete preservation guards live in **three** files, not one. Each is handled
differently — see 8.1, 8.1a, 8.1b.

### 8.1 Prune `bundleRebuildPreservation.test.ts`

That file was written for the `fishing-nui-bundle-rebuild-fix` bugfix, whose
premise was "this change touches no source". That premise no longer holds. It is
pruned, not re-baselined — re-snapshotting would leave a test that must be
updated on every future CSS edit while catching no real bug.

**Delete:**

- The entire `describe('Preservation: web/src source untouched (Req 3.1)')` block
  (L138-152). It sha256-snapshots every file under `web/src` and asserts
  `style.css`, `App.tsx`, `components/RigMenu.tsx` are present — all of which
  this redesign edits.
- From `OTHER_HUD_BASELINE` (L106-132): `.prompt-hud`, `.prompt-title`,
  `.prompt-subtitle`, `.panel`, `.bar-track`, `.bar-fill`, `.cast-fill`,
  `.energy-fill`, `.bar-caption`, `.catch-card`, `.catch-name`, `.catch-weight`,
  `.catch-stars`, `.catch-actions`.
- The now-dead `web/src` tree entry in
  `web/src/__tests__/__snapshots__/bundleRebuildPreservation.test.ts.snap`.

**Keep:**

- `OTHER_HUD_BASELINE` entries `.admin-overlay` and `.admin-window` — the admin
  panel is out of scope, and these are its guard.
- `describe('Preservation: Lua source + fxmanifest untouched (Req 3.4)')` — the
  Lua hash snapshot. This redesign must not change any `.lua` file, so this
  block is a live, meaningful assertion of that boundary.
- The `ui_page` / `files` manifest assertions.
- The `locales` assertions for `equip_hint` `[G]` and `rig_button_label`.

### 8.1a Prune `rigMenuIconPreservation.test.tsx`

**Delete** the final block, `describe('Preservation: HUD อื่นใน bundle เดียวกัน
ไม่ถูกกระทบ (3.4)')` at L152-176. It asserts `.panel` cssText contains
`var(--bg)` (L158, commented "ยังคงพื้นหลังทึบเดิมของ panel") and that
`.cast-fill`, `.prompt-hud`, `.prompt-title`, `.catch-card`, `.btn` rules exist.
`.panel` and `.btn` cease to exist in this redesign.

**Keep** everything above it, including `describe('Preservation: สไตล์เมนู
.rig-menu โปร่งใส + text-shadow (3.2)')` at L137-150 — both of its assertions
(`.rig-menu` contains `transparent`, `.rig-category-card__title` has
`text-shadow`) remain true after the redesign.

### 8.1b Leave `rigMenuBundleRebuild.exploration.test.ts` untouched

No deletion. Its `.rig-menu` transparency check and its `TEXT_SELECTORS`
`text-shadow`+`#fff` check both stay valid and become the rig-side guard for
§4.4. Its `OLD_HASH_FILES` assertions only check for the absence of two specific
stale bundle hashes (`index-DLW4jjFM.css`, `index-zLgQY8bw.js`), so a rebuild
keeps them passing.

### 8.2 New `web/src/__tests__/hudStyle.test.tsx`

Mirrors the pattern of `rigMenuHudStyle.exploration.test.tsx`: read
`src/style.css`, inject it as a `<style>` element, and inspect
`document.styleSheets` rules directly (jsdom does not resolve `var()` or
`backdrop-filter` in `getComputedStyle`).

Assertions:

1. `.hud-panel` cssText contains none of `var(--bg)`, `box-shadow`,
   `backdrop-filter`.
2. `.hud-panel` declares `border-left` (the rail signature survives).
3. `.bar-track` declares a background (the D2 scrim survives).
4. **Neither `.tension-marker` nor `.energy-fill` declares a *timed* transition**
   — the Tier A regression guard, and the highest-value assertion in the file.

   It must be phrased as the absence of a duration, not the absence of the
   `transition` property. `.energy-fill` is rendered as
   `class="bar-fill energy-fill"` and `.bar-fill` carries
   `transition: width 60ms linear` (`style.css:85`), so `.energy-fill` *must*
   keep `transition: none` as the override that makes Tier A work. Asserting
   "no `transition` declaration" would forbid the exact line the design
   requires. Use:

   ```
   expect(rule!.style.cssText).not.toMatch(/transition:[^;]*\d+\s*m?s/)
   ```

   This passes on `transition: none` and on no declaration at all, and fails the
   moment someone adds `transition: left 80ms` to the marker.

### 8.3 Existing tests that must stay green

`App.test.tsx`, `PromptHud.test.tsx`, `RigMenu.test.tsx`,
`rigMenuHudStyle.exploration.test.tsx`, `rigMenuIconPreservation.test.tsx`
(minus the block deleted in 8.1a), `rigMenuPreservation.test.tsx`,
`rigMenuIconOversize.exploration.test.tsx`,
`rigMenuBundleRebuild.exploration.test.ts`, `localeTextPreservation.test.ts`,
`promptText.test.ts`, `rigRows.test.ts`, `rigText.test.ts`,
`minigameEngine.test.ts`, `equipHintPrompt.exploration.test.ts`.

Baseline measured on `main` at commit `5980544`, before any redesign work:
**15 test files, 55 tests, all passing**, ~28s wall clock. After the redesign the
count changes only by the deletions in 8.1/8.1a and the additions in 8.2.

### 8.4 Build and deploy

`web/dist` is a committed build artifact referenced by `fxmanifest.lua`
(`ui_page 'web/dist/index.html'`). The loop is: edit `web/src` → `npm run build`
→ commit the regenerated `web/dist`. Verification order matters: the pruned
preservation test parses the built CSS, so it must run after the build.

**No deploy step in this plan.** `rigMenuBundleRebuild.exploration.test.ts:31-32`
names a deploy copy at
`c:\Users\GameMaster\Desktop\FiveM Server\txData\QBCore_E66DFA.base\resources\[zlab]\zfishing\web\dist`.
That path was checked and **does not exist**, so the test's deploy-copy
assertion early-returns at L128 and is inert. Copying to a live server is a
separate, manual step outside this change.

## 9. Out of scope

- **Admin panel** (`web/src/admin/*`, `admin.css`). Not touched. Enforced by the
  surviving `.admin-overlay` / `.admin-window` baseline.
- **All Lua.** Every animation is driven by data the client already sends. No new
  NUI message, no new field. Enforced by the surviving Lua hash snapshot.
- **Gameplay behaviour.** Cast power curve, tension physics, energy drain,
  quality rolls — all unchanged. This is a presentation-layer change only.
- **Fish rarity colour tiers on CatchCard.** Stars stay `--warn` amber with a
  per-star pop. Colour-by-rarity would need a rarity field the NUI does not
  currently receive.

## 10. Known pre-existing issues (noted, not fixed)

- `.rig-menu__header` is rendered at `RigMenu.tsx:85` but has no rule in
  `style.css`. Dead class, pre-existing. Per `CLAUDE.md` §3, it is left alone.
