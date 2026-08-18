# zfishing — P0 Security + P1 Correctness Hardening

Resource root: `e:\Web\ZCore\zfishing` (branch: `master`, HEAD `d548217`)

---

## Context

The user brought a ChatGPT-authored improvement plan (`zfishing_current_issues_and_improvement_plan_v2.md`) listing 20 issues across P0–P3 plus a Phase 2 feature roadmap. I verified every claim against the shipped code rather than accepting the document.

**What the document actually is.** It is substantially a re-labeling of `docs/ARCHITECTURE.md` §8 (Cross-file invariants), §9 (Behavioral notes that look like bugs but are not) and §10 (Known gaps) — issues 1, 3, 6, 7, 8, 9 and 20 restate those sections nearly verbatim, with priorities attached. That is useful triage, not new discovery. Its P0 security findings are real and confirmed in code.

**Confirmed against code (all real):**

| Claim | Evidence |
|---|---|
| Client decides reel `success` | `server/session.lua:181` — `claim(reelDurationMs, success, reason)`; server only checks elapsed time |
| No `sessionId` / nonce | `hook` / `claim` / `cancel` take no session identifier |
| No idempotent claim lock | `Rewards.GiveCatch` (AddItem → `Progression.Save` → `MySQL.insert`) runs at `session.lua:208` and `reset(src)` only at `:210` — every yield in between leaves `state == 'reeling'` |
| No per-action flood limit | `Config.RateLimit` is incremented only on a *successful catch* (`session.lua:209`); cast spam is free and each cast runs `Generator.Roll` + a full inventory sweep |
| QA commands ungated | `server/progression.lua:47` (`zfish_xp`, +50 XP) and `server/generator.lua:85` (`zfish_roll`) have no `IsAdmin` check — unlike `zfishreload` at `server/store.lua:141`, which does |

**Found during verification, missed by the document (P0):** `zfishing:server:anchorBoat` accepts an arbitrary `netId` and validates only `netId ~= 0` (`server/boat_anchor.lua:4`). The server then broadcasts to `-1`, and every client runs `SetBoatAnchor` + `SetBoatFrozenWhenAnchored` + `SetForcedBoatLocationWhenAnchored` + `SetEntityVelocity(0,0,0)` on that entity (`client/main.lua:117-125`). A modified client can freeze any boat on the server, repeatedly. The document files boat anchoring as a P2 *transport* concern ("migrate to Entity StateBag") — that would not fix this. The defect is missing ownership validation.

**Also found:** the claim-timing check is looser than intended. `session.lua:154` ships `drainRate = s.reelDrain or 1.0` to the NUI, but `:188` computes `minMs` with `s.reelDrain or 1.7`. On the non-assembly path the server's floor is 1.7× too small, and the `* 0.6` slack multiplies that — the effective threshold is ~35% of the true minimum reel time.

**Rejected from the document, with reasons:**

- **Input-timeline replay + `fightSeed` deterministic PRNG (its headline P0 recommendation).** `minigameEngine.ts` is a `dt`-integrator: `tick(dt, holding, elapsedMs)` accumulates both energy and tension as `* dt`. Replaying a client-supplied input timeline requires the client's `dt` sequence, so the client still controls the integration result. `Math.random()` in `pullFor`/`centerTargetFor` is the *second* obstacle, not the first. The seed moves the exploit one layer down at high cost. The design that would actually move authority is a **fixed timestep** — server defines the tick schedule, client reports only `holding` at sample points, server integrates. That is a rewrite of the engine, the NUI loop, and the reel contract, and it is **deferred to a design doc** (see Task 10).
- **StateBag migration for boat anchor.** Wrong lever; see above.
- **P2 refactors** (PART_TYPES catalog, Lua global namespacing, zone `enabled` UI, `web/dist` CI check, test-script split) and **P3 profiling / caching** — out of scope by user decision. The document's own guidance is right that these are profile-driven or cosmetic.
- **Phase 2 feature roadmap** (Fishdex, tournaments, skill tree, economy) — out of scope.

**Decisions taken with the user:** tighten the plausibility envelope now and spec the fixed-timestep rewrite for later; scope = P0 + P1; Keep/Release becomes a single **Continue** button (honest relabel, matching what the code does); final review by Opus.

**Outcome intended:** every reward path is server-authoritative and idempotent, every session transition is bound to a nonce, no ungated progression command ships, no client can freeze another player's boat, and the two duplicated gameplay constants have one source of truth.

---

## Working constraints (read before touching anything)

1. **The Lua sha256 guard.** `web/src/__tests__/bundleRebuildPreservation.test.ts` snapshots the hash of every `.lua` file under `client/ server/ shared/ config/` plus `fxmanifest.lua`. **Policy for this branch: regenerate the snapshot in the same commit as the Lua change** — run `npx vitest --run -u bundleRebuildPreservation` in `web/`, then a plain `npm test`. Target the file by name: a bare `-u` rewrites every snapshot in the suite, including ones that are catching a real regression. Do not delete the guard.
2. **`web/dist` is a committed build artifact.** Tasks 6 and 7 change `web/src`, so they must run `npm run build` in `web/` and commit `web/dist`. After rebuilding, confirm `rigMenuBundleRebuild.exploration.test.ts` still passes — it asserts six selectors keep the literal string `#fff` in the minified CSS (ARCHITECTURE §8 invariant 8).
3. **Naming.** The bite payload's existing `drainRate` is the *reel-quality multiplier* (`reelDrain` renamed once, §8 invariant 6). The constant being made authoritative is the base drain `12`. Name it **`baseDrain`** everywhere — never reuse `drainRate`.
4. **`docs/ARCHITECTURE.md` is currently untracked** (`?? docs/ARCHITECTURE.md`). Commit it as-is first, before Task 9 edits it, so its updates show as a reviewable diff.
5. **Test-first.** `tests/security.test.lua` already covers claim/hook timing, ACE gating and slot ownership with dependency-injected mocks that `dofile` the real modules. Every task below adds its failing test there first. Run: `node tests/luarun.mjs tests/security.test.lua` from the resource root.

---

## Tasks

Each task: write the failing test → implement → verify → regenerate the Lua snapshot → commit.

### P0 — Security

**1. Session ID / nonce on every transition**
`server/session.lua` — generate a random `id` when the session is created (`:130`), return it in the `cast` result (`:166`). `hook`, `claim` and `cancel` take `sessionId` as their first argument and reject a mismatch with `reason = 'invalid_session'` before any other work.
Client call sites to thread it through: `client/main.lua:226` (receives it from `cast`), `client/main.lua:248` and `client/minigame.lua:29` (`cancel`), `:33` (`hook`), `:72` (`claim`). Store it on `ZClient` alongside `rodSlot`; clear it in `cleanup()` at `client/main.lua:128`.
*Test:* a `claim` carrying a stale or absent id is rejected while the live session survives untouched.
*Note:* the token is correlation + stale-request protection, not a secret — a modified client can read its own. That is why tasks 2–4 exist.

**2. Idempotent claim via a `settling` state**
`server/session.lua:181-213` — set `s.state = 'settling'` **before the call to `Rewards.GiveCatch`**, i.e. before the first yield, not merely as a new state in the machine. Any second `claim` then fails the `state ~= 'reeling'` guard. On `AddItem` failure keep the existing `inv_full` return and reset. Log one line per settled claim: session id, player identifier, species, and the AddItem / XP / catch-log outcomes.
*Test:* the harness invokes callbacks synchronously, so the yield has to be staged explicitly — make the `sqlNode` mock in `tests/security.test.lua` call `coroutine.yield()`, wrap each `claim` in `coroutine.create`, resume the first until it parks inside `GiveCatch`, resume the second to completion, then finish the first. Assert exactly one `AddItem`.

**3. Per-action flood limiter**
`server/session.lua` — a small `ACTION_LIMITS` table covering `cast`, `hook`, `claim` and the three rig callbacks (`zfishing:rig:get` `:146`, `zfishing:rig:attach` `:175`, `zfishing:rig:detach` `:221` in `server/rig.lua`), checked **first**, before session lookup and before `Generator.Roll` or any inventory sweep. Keep `Config.RateLimit` as-is: it is the catch-rate economy control and serves a different purpose. Window sizes must tolerate double-input and network jitter — an honest player must never be blocked.
*Test:* N+1 casts inside the window are rejected without reaching `Generator.Roll` (assert via the generator mock's call count).

**4. Gate the QA commands**
`server/progression.lua:47` and `server/generator.lua:85` — wrap both in the existing pattern from `server/store.lua:141`: `if not exports.zcore_lib:IsAdmin(src, 'zfishing.admin') then return end`. Do not introduce a new `Config.Debug` flag; the ACE gate is the established mechanism in this codebase.
*Test:* extend the existing section C (ACE gating) — non-admin `zfish_xp` grants no XP.

**5. Boat anchor ownership validation**
`server/boat_anchor.lua:4` — before accepting, resolve the entity from the netId server-side, confirm it exists, and require the requesting player to be **within roughly 3.5m of it**, matching the client's own `GetClosestVehicle(pos, 3.5, ...)` radius plus slack. Reject silently otherwise. Same check on `unanchorBoat`.

**Do not use seat occupancy.** `getFishingBoat()` at `client/main.lua:102-115` falls back to `GetClosestVehicle` within 3.5m when the ped is not seated, and `client/main.lua:167` then attaches the ped to the deck — standing on a boat is a fully supported fishing path. `GetVehiclePedIsIn` returns 0 for those players, so a seat check silently refuses honest anglers. The anchor request also fires at `:160`, *before* the attach at `:167`, so there is no attachment state to key off either. Proximity covers the seated case too (a seated ped's coords are inside the vehicle). Do not plan on `IsThisModelABoat` server-side — it is a client native; anchoring a non-boat is already a client-side no-op.

Keep the refcount and the `-1` broadcast: with ownership enforced, the broadcast is correct — boat state must agree across all clients (ARCHITECTURE §9).
*Test:* both paths. Reject — `anchorBoat` with a netId far from the player triggers no client event. Accept — a player standing on the deck (not seated, `GetVehiclePedIsIn` = 0) still anchors successfully.

### P1 — Correctness

**6. One authoritative `baseDrain` and one authoritative reel timeout**
- `config/main.lua` — add `Config.Minigame = { baseDrain = 12.0 }`. No admin-panel plumbing: `reelTimeout` is already an editable setting, and `baseDrain` is a balance constant, not an operator knob.
- `server/session.lua:149` — add `baseDrain = Config.Minigame.baseDrain` and `reelTimeout = Config.Timings.reelTimeout` to the `zfishing:bite` payload.
- `client/minigame.lua:38` — forward both into the `reel` NUI message.
- `web/src/engine/minigameEngine.ts` — `EngineConfig` gains `baseDrain` and `reelTimeout`; line 135's literal `12` and line 162's literal `28000` read from config.
- `server/session.lua:188` — use `Config.Minigame.baseDrain`, drop the `or 1.7` fallback in favour of `or 1.0` so the server's assumption matches what `:154` actually shipped to the NUI, and raise the `* 0.6` slack. `minMs` is a hard physical floor (perfect green-zone hold for the entire fight) and network latency only *increases* measured elapsed, so `* 0.9` is safe; the test defines the exact value.

  This is the "tighten the envelope" half of the authority decision. It does not make the minigame server-authoritative — it removes the ~65% of headroom a cheater currently gets for free.
- Then: `npm run build` in `web/`, commit `web/dist`.
*Tests:* Lua side — a claim at `minMs * 0.85` is rejected, one at `minMs * 0.95` accepted. NUI side — an engine constructed with `baseDrain: 20` drains faster than one with `12`, and `reelTimeout: 10000` finishes at 10s not 28s.

**7. Keep / Release → Continue**
`web/src/components/CatchCard.tsx:26-30` — one primary button using a new `ui_continue` locale key; remove the Release button. `client/minigame.lua:93` — delete the `release` NUI callback. Add `ui_continue` to `locales/en.json` and `locales/th.json` (both currently carry `ui_keep` / `ui_release` at `en.json:63-64`); leave the old keys in place for one release. Rebuild `web/dist`.
Rationale: the fish is granted at claim time, before the card renders — Release has never done anything. A real release belongs with the Phase 2 conservation/achievement work.
Blast radius, checked: no web test references `ui_keep`, `ui_release` or `CatchCard` by name — `localeTextPreservation.test.ts` covers only the rig keys and `equip_hint`, and `App.test.tsx` does not render the caught state. The one thing to re-check after the rebuild is `rigMenuBundleRebuild.exploration.test.ts`, whose `OTHER_HUD_BASELINE` includes catch-card selectors; both buttons share `.hud-btn`, so removing one should not drop a CSS rule, but confirm rather than assume.
*Test:* `App.test.tsx` — the catch card renders exactly one action button and firing it calls the `keep` NUI callback.

**8. Fix the two README drifts**
`README.md` — the rig menu opens on the `G` keybind during equip standby (`zfishing_rig`, `client/rig.lua:104`); there is no `/fishrig` command and no ox_inventory "Manage Rod" button. And database tables are **not** created automatically: `migrations/mysql/001_schema.up.sql` is applied by an external provisioner before the resource starts. Both drifts are already recorded in ARCHITECTURE §10.

**9. Update the contract documentation**
`docs/ARCHITECTURE.md` — §3.1 (callback signatures gain `sessionId`), §3.3 (`bite` / `reel` payloads gain `baseDrain`, `reelTimeout`), §2 (add `settling` to the state machine), §7.3 (the two constants are now injected), §8 (invariants 1 and 2 are resolved — rewrite them as "was duplicated, now single-source"; for invariant 2 state explicitly that the server's `+ 5000` at `session.lua:194` **stays** and is now purely latency grace on top of one authoritative timeout, not a second competing limit, or the next reader sees two numbers and "fixes" it), §9 (drop the Keep/Release note), §10 (drop the fixed README drifts).

**10. Design doc for the deferred rewrite**
`docs/superpowers/specs/2026-08-18-zfishing-minigame-authority-design.md` — the fixed-timestep design: server-defined tick schedule and sample count, NUI reports only `holding` bits, server integrates in Lua and decides `success`/`snap`/`timeout`. Must record the two hard problems: porting the integrator to Lua with matching float behaviour, and eliminating or seeding the `Math.random()` calls in `pullFor` / `centerTargetFor`. No implementation.

---

## Suggested model + effort per task

| Task | Model | Effort | Why |
|---|---|---|---|
| 1 Session ID / nonce | Sonnet | medium | Mechanical threading through 5 known call sites |
| 2 Settling lock | **Opus** | high | Yield-ordering correctness; the test needs a yielding SQL mock |
| 3 Flood limiter | Sonnet | medium | Small table + early-return placement |
| 4 Gate QA commands | Sonnet | low | Copy an existing pattern into two files |
| 5 Boat anchor ownership | **Opus** | medium | Server-side entity resolution in FiveM has real footguns |
| 6 baseDrain + reelTimeout | **Opus** | high | Crosses Lua → NUI → engine; touches the timing gate; needs a dist rebuild |
| 7 Continue button | Sonnet | low | One component, one locale key, one callback removed |
| 8 README | Sonnet | low | Prose |
| 9 ARCHITECTURE update | Sonnet | medium | Six sections, must match what actually shipped |
| 10 Authority design doc | **Opus** | high | Design reasoning, not code |

Final review: **Opus**, over the whole branch, with a fix-loop until clean.

---

## Verification

**Per task, before commit:**
```bash
# Lua security suite (from resource root)
node tests/luarun.mjs tests/security.test.lua
node tests/luarun.mjs tests/water_validation.test.lua

# NUI suite + regenerate the Lua hash snapshot in the same commit
# (target the file by name — a bare -u rewrites every snapshot in the suite)
cd web && npx vitest --run -u bundleRebuildPreservation && npm test
```

**After tasks 6 and 7 (the dist rebuild):**
```bash
cd web && npm run build && npm test   # rigMenuBundleRebuild must stay green
git add web/dist
```

**Whole-branch gate before merge:** all three Lua test files green, `web/` suite green (currently 17 files / 63 tests), `web/dist` rebuilt and committed, and the Lua hash snapshot matching the files on disk.

**Live end-to-end (still unverified for this resource — ARCHITECTURE §10, and it stays unverified unless run):** on a FiveM server with `zcore_lib` + `ox_inventory` — cast, hook, reel to a catch, and confirm (a) the card shows one Continue button, (b) `/zfish_xp` as a non-admin does nothing, (c) a second `claim` replayed on the same session is refused, (d) anchoring another player's boat from outside it does nothing, (e) setting `reelTimeout` to 10000 in the admin panel makes the NUI itself give up at 10s. Nothing in this plan proves these; only running them does.
