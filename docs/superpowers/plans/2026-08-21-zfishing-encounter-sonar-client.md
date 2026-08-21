# Sonar Strike client half (Phase D2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete `sonar_strike` with its TypeScript timeline, NUI panel, client input bridge, tests and the single D1+D2 merge.

**Architecture:** The browser mirrors the already-committed Lua timeline from its 504-point fixture and animates locally with `requestAnimationFrame`. It posts only `{ action: 'strike' }` or the neutral `{ action: 'advance' }`; the server continues to decide the arrival time, grade, result and settlement.

**Tech Stack:** React, TypeScript, Vitest, FiveM NUI, Lua test harness.

## Global Constraints

- Work only on `encounter-sonar`; D1 and D2 merge together, never separately.
- `clientAtMs`, cursor position, target position, grade and reward never cross the NUI/client/server boundary.
- Server timestamps remain server-only; every NUI field is an `...In` duration anchored by the browser on `phaseId`.
- The real GHOST fish stays visible; its decoy has no weak band and its independent timeline is presentation only.
- One press produces one callback. No per-frame Lua/NUI/server traffic.
- Sonar uses `success`, `escape`, `timeout`; it intentionally never uses a line/snap bar.
- Re-record the Lua hash snapshot after Lua/manifest changes only; keep test cache files out of commits.

---

## Task 1: Typed sonar timeline and fixture parity

**Files:** Create `web/src/engine/sonarTimeline.ts`, `web/src/engine/__tests__/sonarTimeline.test.ts`.

- [ ] **Step 1: Write failing parity/profile tests.** Import the committed JSON fixture, call `weakAt(sample, sample.t)` for all 504 rows, assert a delta below `1e-6`; separately assert `weakAt` returns `0.5` at each record midpoint and is reversed by `dir=-1`.
- [ ] **Step 2: Run `cd web && npx vitest --run src/engine/__tests__/sonarTimeline.test.ts`.** Expect module-not-found RED.
- [ ] **Step 3: Implement `SonarPass`, `weakAt(pass, elapsed)`, and `passProgress(pass, elapsed)` in `web/src/engine/sonarTimeline.ts`.** Use the identical clamped cubic formula: `u=(elapsed-hold)/(duration-hold)`, `f=.5+(1-k)c+4kc³`, reverse when `dir < 0`.
- [ ] **Step 4: Re-run the focused suite.** Expect fixture and direction tests green.
- [ ] **Step 5: Commit** `test: mirror the sonar timeline in TypeScript`.

## Task 2: Sonar NUI and typed host route

**Files:** Create `web/src/encounters/SonarStrike.tsx`, `web/src/encounters/__tests__/SonarStrike.test.tsx`; modify `web/src/encounters/types.ts`, `web/src/encounters/EncounterHost.tsx`, `web/src/style.css`, `locales/en.json`, `locales/th.json`.

- [ ] **Step 1: Write failing component tests** for real pass rendering, a visible target/weak band, GHOST decoy separated from the real track, float-tier clarity class, `advance` once after deadline, outcome close, and no timing fields in posted payloads.
- [ ] **Step 2: Run `cd web && npx vitest --run src/encounters/__tests__/SonarStrike.test.tsx`.** Expect module-not-found RED.
- [ ] **Step 3: Extend types.** Add `SonarDecoy`, `SonarState`, and the `sonar_strike` member of `EncounterMessage`, matching `server/encounter_sonar.lua` render fields exactly.
- [ ] **Step 4: Implement `SonarStrike`.** Anchor `passStartsIn`/`passEndsIn` once per `phaseId`; animate real/decoy lane transforms through refs and `requestAnimationFrame`; expose target shape/border and textual status; render `hits/requiredHits`, `misses/maxMisses`, last grade and no line bar. Post one neutral `advance` at `passEndsIn + 300ms`, then `encounterClosed` after terminal feedback.
- [ ] **Step 5: Route it through `EncounterHost` and add compact shared-language CSS/locales.** Do not use `any` for the component state and do not add click-to-strike: NUI has no focus during encounters.
- [ ] **Step 6: Re-run focused web tests and `npm test`.** Expect all current tests plus new Sonar tests green.
- [ ] **Step 7: Commit** `feat: render the sonar strike encounter`.

## Task 3: Client bridge input and end-to-end contract tests

**Files:** Modify `client/encounter.lua`, `tests/client_encounter.test.lua`.

- [ ] **Step 1: Add a failing B14 test.** Hook `sonar_strike`, press control 22, assert exactly one action `strike`; assert controls 33–35 do not submit a different action.
- [ ] **Step 2: Run `node tests/luarun.mjs tests/client_encounter.test.lua`.** Expect B14 RED because no Sonar key map exists.
- [ ] **Step 3: Add only `sonar_strike = { { action = 'strike', control = 22 } }` to `KEYMAPS`.** The existing in-flight lock remains the action flood guard; do not create an event or add a timestamp.
- [ ] **Step 4: Re-run focused Lua bridge suite and `cd tests && npm run test:all`.** Expect 14 bridge tests and all suites green.
- [ ] **Step 5: Commit** `feat: wire sonar strike input through the encounter bridge`.

## Task 4: Documentation, regression verification, and atomic merge

**Files:** Modify `docs/ARCHITECTURE.md`, `docs/testing/zfishing-live-e2e-checklist.md`; merge `encounter-sonar` into `main`.

- [ ] **Step 1: Update §12.12** from “D1 server-only” to the shipped NUI model: real/decoy visibility, float clarity, no client time authority, and rAF-only motion.
- [ ] **Step 2: Update checklist N** so D2 is a prerequisite no longer; retain every box unticked and live verification unclaimed.
- [ ] **Step 3: Run fresh full verification:** `cd tests && npm run test:all`; `cd web && npm test`; `git diff --check`.
- [ ] **Step 4: Commit docs** as `docs: complete the sonar strike Phase D notes`.
- [ ] **Step 5: Merge atomically:** checkout `main`, merge `encounter-sonar` with a merge commit, rerun the same full verification on `main`, then delete `encounter-sonar`. Do not push.
