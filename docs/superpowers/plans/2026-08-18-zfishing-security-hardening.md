# zfishing P0 Security + P1 Correctness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every zfishing reward path server-authoritative and idempotent, bind every session transition to a nonce, gate the progression cheat commands, stop any client from freezing another player's boat, and give the two duplicated gameplay constants a single source of truth.

**Architecture:** `server/session.lua` is the anti-cheat core — a per-player state machine (`waiting → hooking → reeling → nil`) where the server rolls the entire catch at cast time and the client is never told the species until a validated claim. This plan adds a `sessionId` nonce to every transition, inserts a `settling` state that closes the double-claim window, and puts a cheap per-action rate gate in front of the expensive validation path. It does **not** make the tension minigame server-authoritative — that is a fixed-timestep rewrite, deferred to a design doc in Task 10.

**Tech Stack:** Lua 5.4 (FiveM server/client), React 18 + TypeScript (NUI, built by Vite into `web/dist`), vitest + @testing-library/react + fast-check for the NUI suite, and a bespoke wasmoon-based Lua runner (`tests/luarun.mjs`) that mounts the real resource files into a Lua VM so tests exercise shipped code via `dofile`.

**Spec:** `docs/superpowers/specs/2026-08-18-zfishing-security-hardening-design.md`

**Resource root:** `e:\Web\ZCore\zfishing`

## Global Constraints

- **Branch first.** The repo is on its default branch `main`. Create `security-hardening` before Task 0.
- **The Lua sha256 guard.** `web/src/__tests__/bundleRebuildPreservation.test.ts` snapshots the hash of every `.lua` file under `client/ server/ shared/ config/` plus `fxmanifest.lua`. Any Lua edit fails the web suite until the snapshot is regenerated. **Policy: regenerate in the same commit as the Lua change** — `cd web && npx vitest --run -u bundleRebuildPreservation`. Target the file by name; a bare `-u` rewrites every snapshot in the suite including ones catching real regressions. Do not delete the guard.
- **`web/dist` is a committed build artifact.** Tasks 6 and 7 change `web/src` and must run `npm run build` in `web/` and commit `web/dist`.
- **Naming.** The existing `drainRate` in the bite payload is the *reel-quality multiplier*. The constant being made authoritative is the base drain `12`. Call it **`baseDrain`** everywhere. Never reuse `drainRate` for it.
- **Test-first.** Every task writes its failing test before implementation. Lua tests live in `tests/security.test.lua`, run from the resource root with `node tests/luarun.mjs tests/security.test.lua`.
- **Locale keys.** Every new session rejection reason needs a matching `error_<reason>` key in `locales/en.json` and `locales/th.json` (ARCHITECTURE §11).

---

## File Structure

| File | Responsibility | Tasks |
|---|---|---|
| `tests/security.test.lua` | The Lua security suite. Dependency-injected host mocks, real modules via `dofile`. | 0–6 |
| `shared/util.lua` | Shared helpers (`ZUtil`). Gains the reusable rate gate. | 3 |
| `server/session.lua` | Session state machine, cast/hook/claim/cancel callbacks. Core of tasks 1–3 and 6. | 1, 2, 3, 6 |
| `server/rig.lua` | Rig attach/detach/get callbacks. Gains rate gating. | 3 |
| `server/boat_anchor.lua` | Refcounted boat anchor state. Gains ownership validation. | 5 |
| `server/progression.lua`, `server/generator.lua` | Carry the two ungated QA commands. | 4 |
| `config/main.lua` | Static config seed. Gains `Config.Minigame.baseDrain`. | 6 |
| `client/main.lua` | Client lifecycle, cast call site, cancel keybind, boat anchor request. | 1, 6 |
| `client/minigame.lua` | Bite → hook QTE → reel; hook/claim/cancel call sites. | 1, 6, 7 |
| `web/src/engine/minigameEngine.ts` | Pure tension-minigame integrator. Constants become injected. | 6 |
| `web/src/components/TensionMinigame.tsx`, `web/src/App.tsx` | Pass the new engine config through. | 6 |
| `web/src/components/CatchCard.tsx` | Catch result card. Two buttons collapse to one. | 7 |
| `locales/en.json`, `locales/th.json` | UI + error strings. | 1, 3, 7 |
| `README.md`, `docs/ARCHITECTURE.md` | Operator guide and internals reference. | 8, 9 |

---

## Task 0: Repair the Lua test harness

Every task below writes a failing test into `tests/security.test.lua`. That is meaningless while the suite is already red. **It is: 13 of 33 tests fail on a clean checkout.** This task makes the baseline green so that a red test means what it should.

Twelve failures share one root cause. The harness calls `dofile('server/validate.lua')` without first loading `server/config_schema.lua`. `validate.lua:3` guards against a nil `ConfigSchema` by installing a minimal fallback stub carrying only `WATER_TYPES` and a non-clamping `ClampNum` — so every `Validate.Setting/Zone/Fish/Equipment` call hits a nil field, and `Validate.num` returns unclamped values (that is the `A6 ... expected 120, got 500` failure). Same shape for `server/rig.lua`, which needs `shared/rig_rules.lua` for the `RigRules` global.

The thirteenth (D2) is a stale assertion — see Step 5.

**Files:**
- Modify: `tests/security.test.lua:144`, `:416`, `:520-521`, `:638-648`, and the D2 test body

**Interfaces:**
- Consumes: nothing
- Produces: a green 33/33 baseline. Every later task depends on this.

- [ ] **Step 1: Confirm the failing baseline**

Run from the resource root:

```bash
node tests/luarun.mjs tests/security.test.lua 2>&1 | grep -c "^ok -"
node tests/luarun.mjs tests/security.test.lua 2>&1 | grep "^not ok"
```

Expected: `20` passing, and 13 `not ok` lines — ten reading `attempt to call a nil value (field 'Validate...')` or `attempt to index a nil value (global 'RigRules')`, one reading `A6 ... expected 120, got 500`, and `D2 ... expected occupied, got not_carried`.

- [ ] **Step 2: Load `config_schema.lua` before `validate.lua`**

The real load order is declared in `fxmanifest.lua` (ARCHITECTURE §1.2): `server/lib.lua → server/store.lua → server/config_schema.lua → server/validate.lua`. The harness must match it.

Find both places that `dofile('server/validate.lua')` — around line 144 and line 639 — and insert the line above each:

```lua
    dofile('server/config_schema.lua')
    dofile('server/validate.lua')
```

- [ ] **Step 3: Load `rig_rules.lua` before `rig.lua`**

Find every `dofile('server/rig.lua')` — around lines 416, 521 and 645 — and insert above each:

```lua
    dofile('shared/rig_rules.lua')
    dofile('server/rig.lua')
```

The `loadSession` helper (~line 520) already loads `shared/util.lua`; `loadRig` (~line 416) does not. Adding `shared/rig_rules.lua` there is what this step needs; Task 3 adds `shared/util.lua` to `loadRig` for the same reason.

- [ ] **Step 4: Run the suite — expect only D2 failing**

```bash
node tests/luarun.mjs tests/security.test.lua 2>&1 | grep "^not ok"
```

Expected: exactly one line, `not ok - D2 rig:attach validates part, ownership, occupancy and item ... expected occupied, got not_carried`.

- [ ] **Step 5: Fix the stale D2 assertion**

D2's last line asserts that re-attaching to an occupied socket returns `err = 'occupied'`. **The string `occupied` appears nowhere in the Lua source.** `zfishing:rig:attach` (`server/rig.lua:175-218`) deliberately implements *swap*: when a socket is filled it returns the previous part to the player's inventory and fits the new one (`server/rig.lua:196-204`). The only error codes it can return are `bad_part`, `no_rod`, `bad_item`, `not_carried`, `inv_full`, `remove_failed`, `meta_failed`.

`not_carried` is also the *correct* answer for this fixture: the happy-path attach consumed the player's only `reel_basic` via `RemoveItemSlot`, so the second attach finds nothing to fit.

Rewrite the test so it documents the real contract. Replace the whole D2 body with:

```lua
test('D2 rig:attach validates part, ownership, occupancy and item', function()
    local inv = { [5] = {
        [3] = { name = 'fishing_rod_common', count = 1, metadata = { parts = {}, dur = { rod = 20 } } },
        [4] = { name = 'reel_basic', count = 1 },
    } }
    loadRig({ mode = 'enhanced', inv = inv })
    equal(CB['zfishing:rig:attach'](5, 3, 'rocket', 'x').err, 'bad_part')
    equal(CB['zfishing:rig:attach'](5, 99, 'reel', 'reel_basic').err, 'no_rod')
    equal(CB['zfishing:rig:attach'](5, 3, 'reel', 'reel_nonexistent').err, 'bad_item')
    -- happy path: consumes the carried reel
    truthy(CB['zfishing:rig:attach'](5, 3, 'reel', 'reel_basic').ok)
    -- the only carried reel is now fitted, so there is nothing left to attach
    equal(CB['zfishing:rig:attach'](5, 3, 'reel', 'reel_basic').err, 'not_carried')
    -- attaching to a FILLED socket swaps: the fitted part returns to the
    -- inventory and the new one goes on. There is no 'occupied' refusal by
    -- design -- see server/rig.lua:196-204.
    inv[5][4] = { name = 'reel_basic', count = 1 }
    truthy(CB['zfishing:rig:attach'](5, 3, 'reel', 'reel_basic').ok,
        'a filled socket swaps rather than refusing')
end)
```

- [ ] **Step 6: Run all three Lua suites — expect green**

```bash
node tests/luarun.mjs tests/security.test.lua 2>&1 | grep -c "^ok -"
node tests/luarun.mjs tests/security.test.lua 2>&1 | grep "^not ok" || echo "ALL GREEN"
node tests/luarun.mjs tests/water_validation.test.lua 2>&1 | tail -3
node tests/luarun.mjs tests/water_validation_preservation.test.lua 2>&1 | tail -3
```

Expected: `33`, then `ALL GREEN`, then both water suites passing.

- [ ] **Step 7: Commit**

No Lua source changed, so the sha256 snapshot is untouched.

```bash
git add tests/security.test.lua
git commit -m "test: repair the Lua security harness load order

The harness dofile'd server/validate.lua without server/config_schema.lua and
server/rig.lua without shared/rig_rules.lua, so validate.lua's nil-guard
fallback stub installed and every Validate.* call hit a nil field. Twelve of
the thirteen failures came from that single gap.

D2's 'occupied' assertion was stale: rig:attach implements swap-on-occupied by
design and has never returned that code. Rewritten to assert the real contract."
```

---

## Task 1: Session ID / nonce on every transition

`hook`, `claim` and `cancel` identify the session by `source` alone. A stale callback from an already-finished session, or a replayed request, is indistinguishable from a live one. This binds every transition to a per-session random token.

The token is **not** a secret — a modified client can read its own. It buys stale-request rejection, replay rejection, and a correlation id for the claim log. Tasks 2 and 3 are what make the reward path actually safe.

**Files:**
- Modify: `server/session.lua:9` (helpers), `:130-136` (session creation), `:164-166` (cast return), `:169-179` (hook), `:181-183` (claim guard), `:215-217` (cancel)
- Modify: `client/main.lua:128-146` (cleanup), `:226` (cast result), `:244-251` (cancel keybind)
- Modify: `client/minigame.lua:29` (cancel), `:33` (hook), `:72` (claim)
- Modify: `locales/en.json`, `locales/th.json`
- Test: `tests/security.test.lua`

**Interfaces:**
- Consumes: green baseline from Task 0
- Produces:
  - `zfishing:cast(power, rodSlot) → { ok, sessionId, rod, bait }` — `sessionId` is a string
  - `zfishing:hook(sessionId) → { ok, reason? }`
  - `zfishing:claim(sessionId, reelDurationMs, success, reason) → { ok, fish?, reason? }` — **`sessionId` is now the first argument, shifting the other three**
  - `zfishing:cancel(sessionId) → { ok, reason? }`
  - `ZClient.sessionId` — client-side storage, cleared in `cleanup()`
  - New rejection reason string: `invalid_session`

- [ ] **Step 1: Write the failing tests**

Add to the GROUP F section of `tests/security.test.lua`, after the existing F3 test:

```lua
test('F4 claim with a stale or missing sessionId is refused and the session survives', function()
    local _, rewardCalls = loadSession({ requireZone = false })
    local cast = CB['zfishing:cast'](5, 0.5)
    truthy(cast.ok)
    truthy(cast.sessionId, 'cast must return a sessionId')
    TIMERS[1].fn()
    truthy(CB['zfishing:hook'](5, cast.sessionId).ok)
    _G.__NOW = _G.__NOW + 6000

    local bad = CB['zfishing:claim'](5, 'not-the-session', 6000, true, nil)
    falsy(bad.ok)
    equal(bad.reason, 'invalid_session')
    equal(rewardCalls.give, 0, 'a bad token grants nothing')

    local missing = CB['zfishing:claim'](5, nil, 6000, true, nil)
    falsy(missing.ok)
    equal(missing.reason, 'invalid_session')

    local good = CB['zfishing:claim'](5, cast.sessionId, 6000, true, nil)
    truthy(good.ok, 'the live session still settles after bad-token attempts')
    equal(rewardCalls.give, 1)
end)

test('F5 hook and cancel also require the session token', function()
    loadSession({ requireZone = false })
    local cast = CB['zfishing:cast'](5, 0.5)
    TIMERS[1].fn()
    equal(CB['zfishing:hook'](5, 'wrong').reason, 'invalid_session')
    equal(CB['zfishing:cancel'](5, 'wrong').reason, 'invalid_session')
    truthy(CB['zfishing:hook'](5, cast.sessionId).ok, 'the correct token still works')
end)

test('F6 each cast mints a distinct session token', function()
    loadSession({ requireZone = false })
    local first = CB['zfishing:cast'](5, 0.5)
    CB['zfishing:cancel'](5, first.sessionId)
    local second = CB['zfishing:cast'](5, 0.5)
    truthy(first.sessionId ~= second.sessionId, 'a new cast must not reuse the previous token')
end)
```

Then update the harness for the new signatures. `fullCatch` (~line 540) becomes:

```lua
local function fullCatch(src, rodSlot)
    local cast = CB['zfishing:cast'](src, 0.5, rodSlot)
    if not cast.ok then return cast, nil end
    truthy(TIMERS[1], 'cast must schedule the bite timer')
    TIMERS[1].fn()                       -- bite fires -> state 'hooking'
    local hook = CB['zfishing:hook'](src, cast.sessionId)
    truthy(hook.ok, 'hook must succeed inside the window')
    _G.__NOW = _G.__NOW + 6000           -- plenty of reel time
    local claim = CB['zfishing:claim'](src, cast.sessionId, 6000, true, nil)
    return cast, claim
end
```

In F1, F2 and F3 replace each `CB['zfishing:hook'](5)` with `CB['zfishing:hook'](5, cast.sessionId)` and each `CB['zfishing:claim'](5, <ms>, ...)` with `CB['zfishing:claim'](5, cast.sessionId, <ms>, ...)`. F1 already binds `local cast`; add that binding to F2 and F3 if their cast line does not have it.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
node tests/luarun.mjs tests/security.test.lua 2>&1 | grep "^not ok"
```

Expected: F4 fails on `cast must return a sessionId` — `cast.sessionId` is nil.

- [ ] **Step 3: Mint and enforce the token server-side**

In `server/session.lua`, above the `reset` function near line 9:

```lua
local nextSessionSeq = 0

-- Session tokens are correlation + stale-request protection, not secrets: a
-- modified client can always read its own. The sequence guarantees uniqueness
-- even if math.random repeats; the random half stops a client guessing the
-- token of a session it does not own.
local function newSessionId()
    nextSessionSeq = nextSessionSeq + 1
    return ('%d-%d'):format(nextSessionSeq, math.random(100000, 999999))
end

-- Resolves the caller's session only when the token matches. Every transition
-- goes through this -- never read sessions[src] directly in a callback.
local function sessionFor(src, sessionId)
    local s = sessions[src]
    if not s or type(sessionId) ~= 'string' or s.id ~= sessionId then return nil end
    return s
end
```

In the session-creation table at `:130`, add the `id` field as the first entry:

```lua
    sessions[src] = {
        id = newSessionId(),
        state = 'waiting', fish = fish, bait = chosenBait, rod = rod,
```

At the cast return (`:164-166`):

```lua
    local rodCfg = Config.Equipment.rods[rod] or {}
    local baitCfg = Config.Equipment.baits[chosenBait] or {}
    return { ok = true, sessionId = sessions[src].id, rod = rodCfg.label, bait = baitCfg.label }
```

Rewrite the three transition callbacks to take the token first:

```lua
lib.callback.register('zfishing:hook', function(src, sessionId)
    local s = sessionFor(src, sessionId)
    if not s then return { ok = false, reason = 'invalid_session' } end
    if s.state ~= 'hooking' then return { ok = false } end
    if GetGameTimer() > s.hookDeadline then
        reset(src)
        return { ok = false, reason = 'too_slow' }
    end
    s.state = 'reeling'
    s.reelStart = GetGameTimer()
    return { ok = true }
end)
```

```lua
lib.callback.register('zfishing:claim', function(src, sessionId, reelDurationMs, success, reason)
    local s = sessionFor(src, sessionId)
    if not s then return { ok = false, reason = 'invalid_session' } end
    if s.state ~= 'reeling' then return { ok = false } end
    local fish = s.fish
```

The rest of `claim`'s body is unchanged in this task — Task 2 rewrites its success branch.

```lua
lib.callback.register('zfishing:cancel', function(src, sessionId)
    if not sessionFor(src, sessionId) then return { ok = false, reason = 'invalid_session' } end
    reset(src); return { ok = true }
end)
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
node tests/luarun.mjs tests/security.test.lua 2>&1 | grep -c "^ok -"
node tests/luarun.mjs tests/security.test.lua 2>&1 | grep "^not ok" || echo "ALL GREEN"
```

Expected: `36`, then `ALL GREEN`.

- [ ] **Step 5: Thread the token through the client**

In `client/main.lua`, store it on cast (around `:226`):

```lua
    local res = lib.callback.await('zfishing:cast', false, power, ZClient.rodSlot)
    if not res or not res.ok then
        cleanup(res and res.reason and ('error_' .. res.reason) or 'error_busy', 'error')
        return
    end
    ZClient.sessionId = res.sessionId
```

Clear it in `cleanup()` (around `:129`), alongside the other session flags:

```lua
local function cleanup(msgKey, msgType)
    ZClient.active = false
    ZClient.reeling = false
    ZClient.standby = false
    ZClient.sessionId = nil
```

Pass it in the cancel keybind (around `:248`):

```lua
        lib.callback.await('zfishing:cancel', false, ZClient.sessionId)
```

In `client/minigame.lua` — the missed-QTE cancel at `:29`:

```lua
        lib.callback.await('zfishing:cancel', false, ZClient.sessionId)
```

the hook at `:33`:

```lua
    local res = lib.callback.await('zfishing:hook', false, ZClient.sessionId)
```

and the claim at `:72`:

```lua
    local res = lib.callback.await('zfishing:claim', false, ZClient.sessionId, body.durationMs or 0, body.success == true, body.reason)
```

- [ ] **Step 6: Add the locale key**

`locales/en.json`:

```json
  "error_invalid_session": "That fishing session is no longer valid",
```

`locales/th.json`:

```json
  "error_invalid_session": "เซสชันตกปลานี้ใช้ไม่ได้แล้ว",
```

- [ ] **Step 7: Regenerate the Lua hash snapshot and run the web suite**

```bash
cd web && npx vitest --run -u bundleRebuildPreservation && npm test && cd ..
```

Expected: the snapshot updates with new hashes for `server/session.lua`, `client/main.lua` and `client/minigame.lua`; the full web suite passes.

- [ ] **Step 8: Commit**

```bash
git add server/session.lua client/main.lua client/minigame.lua locales/ tests/security.test.lua web/src/__tests__/__snapshots__/
git commit -m "security: bind every session transition to a nonce

cast now mints a random sessionId and returns it. hook, claim and cancel take
it as their first argument and refuse a mismatch with invalid_session before
touching any state, so a stale callback from a finished session or a replayed
request can no longer act on a live one.

The token is correlation and stale-request protection, not a secret."
```

---

## Task 2: Idempotent claim via a `settling` state

`zfishing:claim` validates `s.state == 'reeling'`, calls `Rewards.GiveCatch`, and only clears the session afterwards (`server/session.lua:208-210`). `GiveCatch` runs `Zfishing.AddItem`, `Progression.Save` and a `MySQL.insert` — every one of those can yield. Across any of those yields the session is still `sessions[src]` with `state == 'reeling'`, so a second `claim` passes the same guard and the player is paid twice.

The fix is placement, not vocabulary: `s.state = 'settling'` must be set **before the first yield**, i.e. before `Rewards.GiveCatch` is called.

**Files:**
- Modify: `server/session.lua:208-212`
- Test: `tests/security.test.lua` (GROUP F, plus a `yieldOnGive` option in `loadSession`)

**Interfaces:**
- Consumes: `sessionFor(src, sessionId)` from Task 1
- Produces: the session state machine gains `settling` between `reeling` and `nil`. No signature changes.

- [ ] **Step 1: Add a yielding reward mock to the harness**

`loadSession` mocks `Rewards` wholesale, so `GiveCatch` never reaches MySQL — the yield has to be staged at the `Rewards` seam, not at the sql mock. In `loadSession` (~line 533), replace the `Rewards` line with:

```lua
    local rewardCalls = { give = 0 }
    Rewards = { GiveCatch = function()
        rewardCalls.give = rewardCalls.give + 1
        -- Simulates the real GiveCatch yielding on AddItem / Progression.Save /
        -- MySQL.insert. The test drives the coroutine by hand to open the window.
        if opts.yieldOnGive then coroutine.yield() end
        return opts.giveCatch ~= false
    end }
```

- [ ] **Step 2: Write the failing test**

Add to GROUP F:

```lua
test('F7 a second claim during the reward yield is refused -- no double payout', function()
    local _, rewardCalls = loadSession({ requireZone = false, yieldOnGive = true })
    local cast = CB['zfishing:cast'](5, 0.5)
    truthy(cast.ok)
    TIMERS[1].fn()
    truthy(CB['zfishing:hook'](5, cast.sessionId).ok)
    _G.__NOW = _G.__NOW + 6000

    -- first claim: run it until it parks inside GiveCatch
    local first = coroutine.create(function()
        return CB['zfishing:claim'](5, cast.sessionId, 6000, true, nil)
    end)
    truthy(coroutine.resume(first), 'the first claim must reach the reward call')
    equal(coroutine.status(first), 'suspended', 'the first claim is parked mid-reward')
    equal(rewardCalls.give, 1)

    -- second claim arrives while the first is still settling
    local second = coroutine.create(function()
        return CB['zfishing:claim'](5, cast.sessionId, 6000, true, nil)
    end)
    local ok2, res2 = coroutine.resume(second)
    truthy(ok2)
    equal(coroutine.status(second), 'dead', 'the replay must not reach the reward call')
    falsy(res2.ok, 'the replayed claim is refused')
    equal(rewardCalls.give, 1, 'the reward was handed out exactly once')

    -- let the first finish
    local ok3, res3 = coroutine.resume(first)
    truthy(ok3)
    truthy(res3.ok, 'the original claim still settles successfully')
    equal(rewardCalls.give, 1)
end)
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
node tests/luarun.mjs tests/security.test.lua 2>&1 | grep "^not ok"
```

Expected: F7 fails at `the replay must not reach the reward call` — the second claim's status is `suspended`, not `dead`, because it also entered `GiveCatch`, and `rewardCalls.give` is 2.

- [ ] **Step 4: Set `settling` before the first yield**

In `server/session.lua`, replace the success branch of `claim` (currently `:208-212`):

```lua
    -- Lock the session BEFORE the first yield. GiveCatch does AddItem +
    -- Progression.Save + MySQL.insert, and across any of those yields a second
    -- claim would otherwise still find state == 'reeling' and be paid again.
    s.state = 'settling'

    local given = Rewards.GiveCatch(src, fish, s.zone)

    -- the player may have dropped during the settle; playerDropped clears rate[src]
    if rate[src] then rate[src].count = rate[src].count + 1 end

    print(('[zfishing] claim settled session=%s src=%s species=%s reward=%s')
        :format(s.id, src, fish.species, tostring(given)))

    reset(src)
    if not given then return { ok = false, reason = 'inv_full' } end
    return { ok = true, fish = { label = fish.label, weight = fish.weight, quality = fish.quality, species = fish.species } }
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
node tests/luarun.mjs tests/security.test.lua 2>&1 | grep -c "^ok -"
node tests/luarun.mjs tests/security.test.lua 2>&1 | grep "^not ok" || echo "ALL GREEN"
```

Expected: `37`, then `ALL GREEN`.

- [ ] **Step 6: Regenerate the snapshot, run the web suite, commit**

```bash
cd web && npx vitest --run -u bundleRebuildPreservation && npm test && cd ..
git add server/session.lua tests/security.test.lua web/src/__tests__/__snapshots__/
git commit -m "security: make the claim reward path idempotent

Rewards.GiveCatch yields on AddItem, Progression.Save and MySQL.insert, and
reset(src) only ran after it returned -- so across any of those yields a second
claim still found state == 'reeling' and was paid again.

The session now moves to 'settling' before GiveCatch is called, which is the
only placement that closes the window. Also guards rate[src] against a
disconnect landing mid-settle, and logs one correlated line per settled claim."
```

---

## Task 3: Per-action flood limiter

`Config.RateLimit` is a *catch-rate economy* control: it is only incremented on a successful catch (`server/session.lua:209`). Cast spam costs a cheater nothing while costing the server a `Generator.Roll` plus a full inventory sweep — `resolveRod` iterates every rod calling `HasItem`, `resolveLineRating` every line, `resolveBait` every bait — on every request.

This adds a cheap per-action gate that runs *first*, before session lookup and before any inventory or generator work. `Config.RateLimit` stays exactly as it is; different job.

**Files:**
- Create nothing; Modify: `shared/util.lua` (append the gate factory)
- Modify: `server/session.lua:7` (gate construction), the three callback entry lines, `:229-233` (`playerDropped`)
- Modify: `server/rig.lua` (gate construction + three callback entry lines at `:146`, `:175`, `:221`)
- Modify: `locales/en.json`, `locales/th.json`
- Test: `tests/security.test.lua` (GROUP E, plus `shared/util.lua` added to `loadRig`)

**Interfaces:**
- Consumes: `sessionFor` from Task 1
- Produces: `ZUtil.MakeRateGate(limits) → gate` where `limits` is `{ [action] = { max = N, window = ms } }`. The returned table has `gate.allow(src, action) → boolean` (true = permitted) and `gate.forget(src)` for disconnect cleanup. New rejection reason string: `too_many_requests`.

- [ ] **Step 1: Write the failing tests**

Add to GROUP E in `tests/security.test.lua`:

```lua
test('E2 cast spam is rejected before it reaches the generator', function()
    loadSession({ requireZone = false })
    local rolls = 0
    local realRoll = Generator.Roll
    Generator.Roll = function(...) rolls = rolls + 1; return realRoll(...) end

    local first = CB['zfishing:cast'](5, 0.5)
    truthy(first.ok)
    equal(rolls, 1)
    CB['zfishing:cancel'](5, first.sessionId)   -- free the session so 'busy' cannot mask the gate

    -- hammer it: the gate must refuse before the fish roll runs
    for _ = 1, 20 do CB['zfishing:cast'](5, 0.5) end
    equal(CB['zfishing:cast'](5, 0.5).reason, 'too_many_requests')
    truthy(rolls <= 3, 'a spammed cast must not run the fish roll every time, got ' .. rolls)
end)

test('E3 the rate gate reopens after its window elapses', function()
    loadSession({ requireZone = false })
    local first = CB['zfishing:cast'](5, 0.5)
    CB['zfishing:cancel'](5, first.sessionId)
    for _ = 1, 20 do CB['zfishing:cast'](5, 0.5) end
    equal(CB['zfishing:cast'](5, 0.5).reason, 'too_many_requests')

    _G.__NOW = _G.__NOW + 5000      -- past every ACTION_LIMITS window
    local after = CB['zfishing:cast'](5, 0.5)
    truthy(after.reason ~= 'too_many_requests', 'the gate must reopen once the window passes')
end)
```

Also add `shared/util.lua` to `loadRig` (~line 416) so the gate factory exists for the rig callbacks under test:

```lua
    dofile('shared/util.lua')
    dofile('shared/rig_rules.lua')
    dofile('server/rig.lua')
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
node tests/luarun.mjs tests/security.test.lua 2>&1 | grep "^not ok"
```

Expected: E2 fails at the `too_many_requests` assertion — no gate exists, so the reason is nil (the cast succeeds) or `busy`.

- [ ] **Step 3: Add the gate factory to `shared/util.lua`**

Append to `shared/util.lua`:

```lua
-- Cheap fixed-window request gate. Runs in front of expensive validation so a
-- flood of forged events costs a table lookup, not an inventory sweep or a fish
-- roll. Windows are deliberately generous: network jitter and a double-tapped
-- key must never trip it for an honest player.
function ZUtil.MakeRateGate(limits)
    local hits = {}
    local gate = {}

    function gate.allow(src, action)
        local lim = limits[action]
        if not lim then return true end
        local now = GetGameTimer()
        local bySrc = hits[src]
        if not bySrc then bySrc = {}; hits[src] = bySrc end
        local h = bySrc[action]
        if not h or (now - h.since) >= lim.window then
            bySrc[action] = { n = 1, since = now }
            return true
        end
        h.n = h.n + 1
        return h.n <= lim.max
    end

    function gate.forget(src) hits[src] = nil end
    return gate
end
```

- [ ] **Step 4: Gate the session callbacks**

In `server/session.lua`, below the `rate` table near line 7:

```lua
-- Per-action flood gate. Distinct from Config.RateLimit, which is the catch-rate
-- economy control and only counts SUCCESSFUL catches. This one counts requests.
local gate = ZUtil.MakeRateGate({
    cast  = { max = 3, window = 2000 },
    hook  = { max = 5, window = 2000 },
    claim = { max = 3, window = 3000 },
})
```

Make it the first line of each callback — `cast`:

```lua
lib.callback.register('zfishing:cast', function(src, power, rodSlot)
    if not gate.allow(src, 'cast') then return { ok = false, reason = 'too_many_requests' } end
    if Zfishing.Blocked() then return { ok = false, reason = 'unavailable' } end
```

`hook`:

```lua
lib.callback.register('zfishing:hook', function(src, sessionId)
    if not gate.allow(src, 'hook') then return { ok = false, reason = 'too_many_requests' } end
    local s = sessionFor(src, sessionId)
```

`claim`:

```lua
lib.callback.register('zfishing:claim', function(src, sessionId, reelDurationMs, success, reason)
    if not gate.allow(src, 'claim') then return { ok = false, reason = 'too_many_requests' } end
    local s = sessionFor(src, sessionId)
```

And clear gate state on disconnect (`:229-233`):

```lua
AddEventHandler('playerDropped', function()
    local src = source
    reset(src); rate[src] = nil
    gate.forget(src)
    BoatAnchor.OnDisconnect(src)
end)
```

- [ ] **Step 5: Gate the rig callbacks**

In `server/rig.lua`, after the existing top-of-file locals:

```lua
local gate = ZUtil.MakeRateGate({
    get    = { max = 10, window = 5000 },
    attach = { max = 10, window = 5000 },
    detach = { max = 10, window = 5000 },
})
```

Then as the first line of each of the three callbacks:

```lua
lib.callback.register('zfishing:rig:get', function(src, slot)
    if not gate.allow(src, 'get') then return { ok = false, err = 'too_many_requests' } end
```

```lua
lib.callback.register('zfishing:rig:attach', function(src, slot, partType, itemName, partSlot)
    if not gate.allow(src, 'attach') then return { ok = false, err = 'too_many_requests' } end
```

```lua
lib.callback.register('zfishing:rig:detach', function(src, slot, partType)
    if not gate.allow(src, 'detach') then return { ok = false, err = 'too_many_requests' } end
```

- [ ] **Step 6: Add the locale key**

`locales/en.json`:

```json
  "error_too_many_requests": "Slow down",
```

`locales/th.json`:

```json
  "error_too_many_requests": "ช้าลงหน่อย",
```

- [ ] **Step 7: Run the tests to verify they pass**

```bash
node tests/luarun.mjs tests/security.test.lua 2>&1 | grep -c "^ok -"
node tests/luarun.mjs tests/security.test.lua 2>&1 | grep "^not ok" || echo "ALL GREEN"
```

Expected: `39`, then `ALL GREEN`.

- [ ] **Step 8: Regenerate the snapshot, run the web suite, commit**

```bash
cd web && npx vitest --run -u bundleRebuildPreservation && npm test && cd ..
git add shared/util.lua server/session.lua server/rig.lua locales/ tests/security.test.lua web/src/__tests__/__snapshots__/
git commit -m "security: add a per-action flood gate ahead of validation

Config.RateLimit only counts successful catches, so cast spam was free while
costing the server a fish roll and a full inventory sweep per request. A cheap
fixed-window gate now runs first on cast/hook/claim and the three rig callbacks,
so a forged-event flood costs a table lookup.

Windows are deliberately generous -- network jitter and double-tapped keys must
never trip an honest player."
```

---

## Task 4: Gate the QA commands

`/zfish_xp` grants 50 XP to whoever types it and `/zfish_roll` samples the fish generator. Neither checks permissions, so any player can level themselves to unlock every rod tier. `server/store.lua:141` already shows the established pattern for this codebase.

Do **not** introduce a `Config.Debug` flag. The ACE gate is the mechanism already in use here, and a second mechanism is a second thing to get wrong.

**Files:**
- Modify: `server/progression.lua:47-55`
- Modify: `server/generator.lua:84-94`
- Test: `tests/security.test.lua` (GROUP C — authorization)

**Interfaces:**
- Consumes: nothing from earlier tasks
- Produces: nothing later tasks depend on

- [ ] **Step 1: Write the failing test**

Add to GROUP C in `tests/security.test.lua`. Look at the existing GROUP C test to match how it installs an `IsAdmin`-returning `zcore_lib` export mock, and mirror that setup:

```lua
test('C2 the QA commands refuse a non-admin caller', function()
    local xpAdded = 0
    installHost()
    _G.exports = { zcore_lib = {
        IsAdmin = function(_, _, ace) return false end,
        Notify = function() end,
    } }
    Config = { Progression = { xpCurve = 1.5 } }
    Progression = nil
    dofile('shared/util.lua')
    dofile('server/progression.lua')

    -- shadow AddXP so the test observes the grant without a real store
    local realAddXP = Progression.AddXP
    Progression.AddXP = function(_, amount) xpAdded = xpAdded + amount end
    Progression.Get = function() return { level = 1, xp = 0, identifier = 'license:test' } end
    Progression.Load = function() end
    Progression.Save = function() end

    truthy(CMD['zfish_xp'], 'the command must still be registered')
    CMD['zfish_xp'](5, {})
    equal(xpAdded, 0, 'a non-admin must not be granted XP')
end)
```

If `installHost()`'s exports shape differs from the above, copy the shape used by the existing GROUP C admin test verbatim rather than inventing one — that test already proves the mock works against `server/admin.lua`.

- [ ] **Step 2: Run the test to verify it fails**

```bash
node tests/luarun.mjs tests/security.test.lua 2>&1 | grep "^not ok"
```

Expected: C2 fails at `a non-admin must not be granted XP` — `xpAdded` is 50.

- [ ] **Step 3: Gate both commands**

`server/progression.lua`, replacing the command body at `:47`:

```lua
-- QA helper: grants 50 xp and reports level/xp. Admin-gated -- an ungated
-- version lets any player unlock every rod tier for free.
RegisterCommand('zfish_xp', function(src)
    if src == 0 then return end
    if not exports.zcore_lib:IsAdmin(src, 'zfishing.admin') then return end
    if not Progression.Get(src) then Progression.Load(src) end
    Progression.AddXP(src, 50)
    Progression.Save(src)
    local c = Progression.Get(src)
    exports.zcore_lib:Notify(src, ('Level %d, XP %d'):format(c.level, c.xp), 'inform')
end, false)
```

`server/generator.lua`, replacing the command body at `:85`:

```lua
-- QA helper: /zfish_roll [water] samples one roll. Admin-gated -- it leaks the
-- generator's behaviour and is a QA tool, not a player command.
RegisterCommand('zfish_roll', function(src, args)
    if src == 0 then return end
    if not exports.zcore_lib:IsAdmin(src, 'zfishing.admin') then return end
    local water = args[1] or 'ocean'
    local f = Generator.Roll(src, { water = water, rod='fishing_rod_common', hook='hook_4', bait='worm' })
    if f then
        exports.zcore_lib:Notify(src, ('%s %.2fkg %d* (%s)'):format(f.label, f.weight, f.quality, f.rarity), 'inform')
    else
        exports.zcore_lib:Notify(src, 'No fish for water: '..water, 'error')
    end
end, false)
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
node tests/luarun.mjs tests/security.test.lua 2>&1 | grep -c "^ok -"
node tests/luarun.mjs tests/security.test.lua 2>&1 | grep "^not ok" || echo "ALL GREEN"
```

Expected: `40`, then `ALL GREEN`.

- [ ] **Step 5: Regenerate the snapshot, run the web suite, commit**

```bash
cd web && npx vitest --run -u bundleRebuildPreservation && npm test && cd ..
git add server/progression.lua server/generator.lua tests/security.test.lua web/src/__tests__/__snapshots__/
git commit -m "security: put the QA commands behind the admin ACE

/zfish_xp granted 50 XP to any caller and /zfish_roll exposed the generator,
neither with a permission check -- so any player could level themselves into
every rod tier. Both now use the same zcore_lib:IsAdmin('zfishing.admin') gate
that /zfishreload already uses."
```

---

## Task 5: Boat anchor ownership validation

`zfishing:server:anchorBoat` accepts an arbitrary `netId` and validates only `netId ~= 0` (`server/boat_anchor.lua:4`). The server then broadcasts to `-1`, and every client runs `SetBoatAnchor` + `SetBoatFrozenWhenAnchored` + `SetForcedBoatLocationWhenAnchored` + `SetEntityVelocity(0,0,0)` on that entity (`client/main.lua:117-125`). A modified client can freeze any boat on the server, repeatedly, from anywhere on the map.

**Do not use seat occupancy to fix this.** `getFishingBoat()` (`client/main.lua:102-115`) falls back to `GetClosestVehicle(pos, 3.5, ...)` when the ped is not seated, and `client/main.lua:167` then attaches the ped to the deck — standing on a boat is a fully supported fishing path. `GetVehiclePedIsIn` returns 0 for those players, so a seat check silently refuses honest anglers. The anchor request also fires at `:160`, *before* the attach at `:167`, so there is no attachment state to key off either.

Proximity is the enforceable check, and it covers the seated case too (a seated ped's coords are inside the vehicle). Do not use `IsThisModelABoat` server-side — it is a client native; anchoring a non-boat is already a client-side no-op.

Keep the refcount and the `-1` broadcast. With ownership enforced the broadcast is correct: boat state must agree across all clients (ARCHITECTURE §9).

**Files:**
- Modify: `server/boat_anchor.lua:1-30`
- Test: `tests/security.test.lua` (new GROUP H)

**Interfaces:**
- Consumes: nothing from earlier tasks
- Produces: `BoatAnchor.Add(src, netId)` and `BoatAnchor.Remove(src, netId)` now return `false` without side effects when the player is out of range

- [ ] **Step 1: Write the failing tests**

Add a new GROUP H section to `tests/security.test.lua`. It needs host mocks for the entity natives; place the vehicle at a fixed point and move the player between assertions:

```lua
-- =============================================================== GROUP H
-- Boat anchor ownership (boat_anchor.lua) -- Requirements 6.5, 23.5

local function loadBoatAnchor(pedPos, vehPos)
    installHost()
    local peds, vehs = { [5] = 55 }, { [900] = 99 }
    _G.GetPlayerPed = function(src) return peds[src] or 0 end
    _G.NetworkGetEntityFromNetworkId = function(netId) return vehs[netId] or 0 end
    _G.DoesEntityExist = function(e) return e ~= 0 end
    _G.GetEntityCoords = function(e)
        if e == 55 then return pedPos end
        if e == 99 then return vehPos end
        return { x = 0.0, y = 0.0, z = 0.0 }
    end
    dofile('server/boat_anchor.lua')
end

test('H1 anchoring a boat the player is nowhere near is refused', function()
    loadBoatAnchor({ x = 0.0, y = 0.0, z = 0.0 }, { x = 500.0, y = 500.0, z = 0.0 })
    falsy(BoatAnchor.Add(5, 900), 'a remote netId must not anchor')
    equal(#spy.clientEvents, 0, 'no anchor broadcast may be sent')
end)

test('H2 a player standing on the deck (not seated) still anchors', function()
    -- 4m from the vehicle origin: past the client 3.5m probe, well inside the
    -- server allowance, and exactly the deck-standing case a seat check breaks.
    loadBoatAnchor({ x = 4.0, y = 0.0, z = 1.0 }, { x = 0.0, y = 0.0, z = 0.0 })
    truthy(BoatAnchor.Add(5, 900), 'deck-standing must still anchor')
    equal(#spy.clientEvents, 1, 'the anchor broadcast fires once')
end)

test('H3 a nonexistent entity is refused', function()
    loadBoatAnchor({ x = 0.0, y = 0.0, z = 0.0 }, { x = 0.0, y = 0.0, z = 0.0 })
    falsy(BoatAnchor.Add(5, 12345), 'an unknown netId must not anchor')
    equal(#spy.clientEvents, 0)
end)

test('H4 unanchor is validated the same way', function()
    loadBoatAnchor({ x = 1.0, y = 0.0, z = 0.0 }, { x = 0.0, y = 0.0, z = 0.0 })
    truthy(BoatAnchor.Add(5, 900))
    -- another player, far away, must not be able to release it
    _G.GetPlayerPed = function(src) return src == 5 and 55 or 77 end
    _G.GetEntityCoords = function(e)
        if e == 55 then return { x = 1.0, y = 0.0, z = 0.0 } end
        if e == 77 then return { x = 900.0, y = 0.0, z = 0.0 } end
        return { x = 0.0, y = 0.0, z = 0.0 }
    end
    falsy(BoatAnchor.Remove(6, 900), 'a distant player must not release the anchor')
end)
```

Check `installHost()`'s `spy.clientEvents` recorder shape and adjust the assertions to match how it stores `TriggerClientEvent` calls — the existing session tests already assert against it.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
node tests/luarun.mjs tests/security.test.lua 2>&1 | grep "^not ok"
```

Expected: H1 fails at `a remote netId must not anchor` — `Add` returns true and broadcasts, because there is no proximity check.

- [ ] **Step 3: Add the proximity guard**

Rewrite the top of `server/boat_anchor.lua`:

```lua
BoatAnchor = {}
local boatAnchors = {} -- [netId] = { count = N, players = { [src] = true } }

-- The client probes for a boat within 3.5m (client/main.lua:109) and may then
-- attach the ped to the deck. 15m of server-side allowance covers standing at
-- the bow of the largest boats and any position desync, while still refusing
-- the actual attack: anchoring an arbitrary netId from across the map. Without
-- this, any client can freeze any boat on the server -- the broadcast at the
-- bottom of this file reaches every player.
--
-- Proximity, NOT seat occupancy: GetVehiclePedIsIn returns 0 for a player
-- standing on the deck, which is a supported fishing position, and the anchor
-- request fires before the attach so there is no attachment state to read.
local ANCHOR_RANGE_SQ = 15.0 * 15.0

local function playerNearVehicle(src, netId)
    if not netId or netId == 0 then return false end
    local veh = NetworkGetEntityFromNetworkId(netId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return false end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    local p, v = GetEntityCoords(ped), GetEntityCoords(veh)
    local dx, dy, dz = p.x - v.x, p.y - v.y, p.z - v.z
    return (dx * dx + dy * dy + dz * dz) <= ANCHOR_RANGE_SQ
end

function BoatAnchor.Add(src, netId)
    if not playerNearVehicle(src, netId) then return false end
    boatAnchors[netId] = boatAnchors[netId] or { count = 0, players = {} }
    if not boatAnchors[netId].players[src] then
        boatAnchors[netId].players[src] = true
        boatAnchors[netId].count = boatAnchors[netId].count + 1
        if boatAnchors[netId].count == 1 then
            TriggerClientEvent('zfishing:client:syncBoatAnchor', -1, netId, true)
            return true
        end
    end
    return false
end

function BoatAnchor.Remove(src, netId)
    if not playerNearVehicle(src, netId) then return false end
    if not boatAnchors[netId] then return false end
    if boatAnchors[netId].players[src] then
        boatAnchors[netId].players[src] = nil
        boatAnchors[netId].count = math.max(0, boatAnchors[netId].count - 1)
        if boatAnchors[netId].count <= 0 then
            boatAnchors[netId] = nil
            TriggerClientEvent('zfishing:client:syncBoatAnchor', -1, netId, false)
            return true
        end
    end
    return false
end
```

`BoatAnchor.OnDisconnect` is unchanged — it iterates state the server already owns and needs no proximity check (the player is gone).

- [ ] **Step 4: Run the tests to verify they pass**

```bash
node tests/luarun.mjs tests/security.test.lua 2>&1 | grep -c "^ok -"
node tests/luarun.mjs tests/security.test.lua 2>&1 | grep "^not ok" || echo "ALL GREEN"
```

Expected: `44`, then `ALL GREEN`.

- [ ] **Step 5: Regenerate the snapshot, run the web suite, commit**

```bash
cd web && npx vitest --run -u bundleRebuildPreservation && npm test && cd ..
git add server/boat_anchor.lua tests/security.test.lua web/src/__tests__/__snapshots__/
git commit -m "security: validate boat ownership before anchoring

zfishing:server:anchorBoat accepted any netId and broadcast to -1, so a
modified client could freeze any boat on the server from anywhere on the map.

The server now resolves the entity and requires the requesting player to be
within 15m of it. Proximity rather than seat occupancy: a player standing on
the deck is a supported fishing position and GetVehiclePedIsIn returns 0 for
them, and the anchor request fires before the ped is attached."
```

---

## Task 6: One authoritative `baseDrain` and one authoritative reel timeout

Two gameplay constants are duplicated across the Lua/TypeScript boundary with no type system to catch a drift (ARCHITECTURE §8 invariants 1 and 2):

1. `web/src/engine/minigameEngine.ts:135` drains `12 * drainRate * dt` in the green zone; `server/session.lua:189` independently computes `minMs = (fish.fishEnergy / (12 * drain)) * 1000`. Retuning one silently makes the server reject legitimate catches.
2. The engine hard-codes `elapsedMs >= 28000` as its timeout (`:162`) while the server rejects past `Config.Timings.reelTimeout + 5000`. `reelTimeout` is admin-editable down to 3000ms, so any value below 23000 puts the server's cutoff *under* the engine's — a long-but-legitimate fight gets refused before the NUI gives up.

This task also closes the leniency gap: `session.lua:154` ships `drainRate = s.reelDrain or 1.0` to the NUI but `:188` computes with `s.reelDrain or 1.7`. On the non-assembly path the server's floor is 1.7× too small, and the `* 0.6` slack multiplies it — the effective threshold is roughly 35% of the true minimum reel time.

`minMs` is a hard physical floor: it assumes a perfect green-zone hold for the entire fight, and network latency only *increases* measured elapsed time. `* 0.9` is therefore safe.

This is the "tighten the envelope" half of the authority decision. It does **not** make the minigame server-authoritative — it removes headroom a cheater currently gets for free. Task 10 specs the real fix.

**Files:**
- Modify: `config/main.lua:13-18` (add `Config.Minigame`)
- Modify: `server/session.lua:149-156` (bite payload), `:186-192` (claim timing)
- Modify: `client/minigame.lua:38-43` (reel NUI message)
- Modify: `web/src/engine/minigameEngine.ts:1-9` (`EngineConfig`), `:135`, `:162`
- Modify: `web/src/components/TensionMinigame.tsx:7-16` (`Props`)
- Modify: `web/src/App.tsx:71-83` (pass-through)
- Test: `tests/security.test.lua`, `web/src/engine/__tests__/` (add a case to the existing engine test file)

**Interfaces:**
- Consumes: `sessionFor` (Task 1), `gate` (Task 3)
- Produces:
  - `Config.Minigame = { baseDrain = 12.0 }`
  - `zfishing:bite` payload gains `baseDrain: number` and `reelTimeout: number`
  - NUI `reel` message gains the same two fields
  - `EngineConfig` gains `baseDrain: number` and `reelTimeout: number`

- [ ] **Step 1: Write the failing Lua test**

Add to GROUP F in `tests/security.test.lua`:

```lua
test('F8 the claim floor uses the shipped drain, with no 1.7x hidden slack', function()
    -- fishEnergy 50, no rig (reelDrain nil) -> the NUI is told drainRate 1.0,
    -- so the true floor is 50 / (12 * 1.0) = 4166ms. The old code assumed 1.7
    -- and then multiplied by 0.6, accepting claims from ~1470ms.
    local _, rewardCalls = loadSession({ requireZone = false, mode = 'simple' })
    local cast = CB['zfishing:cast'](5, 0.5)
    truthy(cast.ok)
    TIMERS[1].fn()
    truthy(CB['zfishing:hook'](5, cast.sessionId).ok)

    _G.__NOW = _G.__NOW + 2000           -- under the real floor, over the old one
    local early = CB['zfishing:claim'](5, cast.sessionId, 2000, true, nil)
    falsy(early.ok, 'a 2s claim on a 4.2s floor must be refused')
    equal(early.reason, 'too_fast')
    equal(rewardCalls.give, 0)
end)

test('F9 an honest claim just over the floor is accepted', function()
    local _, rewardCalls = loadSession({ requireZone = false, mode = 'simple' })
    local cast = CB['zfishing:cast'](5, 0.5)
    TIMERS[1].fn()
    truthy(CB['zfishing:hook'](5, cast.sessionId).ok)
    _G.__NOW = _G.__NOW + 4200           -- 50 / 12 = 4166ms floor, 0.9x = 3750ms
    local claim = CB['zfishing:claim'](5, cast.sessionId, 4200, true, nil)
    truthy(claim.ok, 'a claim past the floor must settle')
    equal(rewardCalls.give, 1)
end)
```

If `loadSession`'s `mode = 'simple'` does not produce a nil `reelDrain`, pass the fish fixture explicitly instead and assert against whatever `reelDrain` the session ends up with — the point of the test is the arithmetic, not the fixture.

- [ ] **Step 2: Run the test to verify it fails**

```bash
node tests/luarun.mjs tests/security.test.lua 2>&1 | grep "^not ok"
```

Expected: F8 fails at `a 2s claim on a 4.2s floor must be refused` — the old `1.7` fallback and `0.6` slack accept it.

- [ ] **Step 3: Add the config constant**

In `config/main.lua`, after the `Config.Timings` block (`:13-18`):

```lua
-- Authoritative tension-minigame constants. The NUI receives these in the bite
-- payload rather than hard-coding its own copies -- the server validates claims
-- against the same numbers the client was told to play by.
Config.Minigame = {
    baseDrain = 12.0,   -- energy drained per second while the tension is in the green zone
}
```

- [ ] **Step 4: Ship both constants in the bite payload**

In `server/session.lua`, in the `TriggerClientEvent('zfishing:bite', ...)` table at `:149`:

```lua
        TriggerClientEvent('zfishing:bite', src, {
            behavior = fish.behavior, tensionDiff = fish.tensionDiff,
            fishEnergy = fish.fishEnergy, hookWindow = fish.hookWindow,
            greenZone = rodCfg.greenZone or 0.0,
            snapFactor = snapFactor,
            drainRate = s.reelDrain or 1.0,   -- reel quality = how fast the fish tires
            baseDrain = Config.Minigame.baseDrain,   -- authoritative; the server validates against it
            reelTimeout = Config.Timings.reelTimeout, -- single source of truth for the fight clock
            fishWeight = fish.weight,          -- actual rolled weight for NUI dynamics
        })
```

- [ ] **Step 5: Tighten the claim floor**

In `server/session.lua`, replace the timing block at `:186-192`:

```lua
    -- Minimum plausible reel time. The NUI drains baseDrain * drainRate energy
    -- per second while in the green zone, so a real catch can never finish
    -- faster than this. drainRate defaults to 1.0 to match exactly what the bite
    -- payload told the client -- assuming a faster reel here would hand every
    -- non-assembly player a 1.7x discount on the floor.
    local drain = s.reelDrain or 1.0
    local minMs = (fish.fishEnergy / (Config.Minigame.baseDrain * drain)) * 1000
    local elapsed = GetGameTimer() - s.reelStart
    -- 0.9 rather than a tighter value only to absorb frame quantisation: minMs
    -- assumes a perfect green-zone hold for the whole fight, and network latency
    -- only ever increases the elapsed time the server measures.
    if success and elapsed < minMs * 0.9 then
        reset(src); return { ok = false, reason = 'too_fast' }
    end
```

Leave the `elapsed > Config.Timings.reelTimeout + 5000` line at `:194` exactly as it is. With the engine now honouring `reelTimeout`, the `+ 5000` stops being a competing limit and becomes pure latency grace on top of one authoritative timeout.

- [ ] **Step 6: Forward both to the NUI**

In `client/minigame.lua`, the `reel` message at `:38`:

```lua
    SendNUIMessage({ action = 'reel',
        behavior = data.behavior, tensionDiff = data.tensionDiff,
        fishEnergy = data.fishEnergy, greenZone = data.greenZone,
        snapFactor = data.snapFactor, drainRate = data.drainRate,
        baseDrain = data.baseDrain, reelTimeout = data.reelTimeout,
        fishWeight = data.fishWeight,
        startedAt = GetGameTimer() })
```

- [ ] **Step 7: Write the failing engine test**

Add to the existing engine test file under `web/src/engine/__tests__/`:

```ts
import { describe, it, expect } from 'vitest'
import { MinigameEngine } from '../minigameEngine'

const base = {
  behavior: 'steady_light' as const,
  tensionDiff: 1,
  fishEnergy: 100,
  greenZone: 1,        // widest possible green band, so holding stays in it
  snapFactor: 10,      // effectively no snapping during the test
  drainRate: 1,
  fishWeight: 5,
  baseDrain: 12,
  reelTimeout: 28000,
}

describe('injected minigame constants', () => {
  it('drains faster with a larger baseDrain', () => {
    const slow = new MinigameEngine({ ...base, baseDrain: 12 })
    const fast = new MinigameEngine({ ...base, baseDrain: 24 })
    let t = 0
    for (let i = 0; i < 60; i++) { t += 100; slow.tick(0.1, true, t); fast.tick(0.1, true, t) }
    expect(fast.tick(0, true, t).energy).toBeLessThan(slow.tick(0, true, t).energy)
  })

  it('times out at the configured reelTimeout, not a hard-coded 28s', () => {
    const engine = new MinigameEngine({ ...base, reelTimeout: 10000 })
    const state = engine.tick(0.016, false, 10_050)
    expect(state.isFinished).toBe(true)
    expect(state.finishReason).toBe('timeout')
  })
})
```

- [ ] **Step 8: Run the engine test to verify it fails**

```bash
cd web && npx vitest --run minigameEngine
```

Expected: TypeScript rejects the extra `baseDrain` / `reelTimeout` properties on `EngineConfig`, or the timeout test fails because the engine still finishes at 28000.

- [ ] **Step 9: Inject the constants into the engine**

In `web/src/engine/minigameEngine.ts`, extend `EngineConfig`:

```ts
export type EngineConfig = {
  behavior: 'steady_light' | 'steady_heavy' | 'run_stop' | 'erratic'
  tensionDiff: number
  fishEnergy: number
  greenZone: number
  snapFactor: number
  drainRate: number
  fishWeight: number
  baseDrain: number   // authoritative, from Config.Minigame.baseDrain via the bite payload
  reelTimeout: number // authoritative, from Config.Timings.reelTimeout via the bite payload
}
```

Replace the drain at `:135`:

```ts
      this.energyV -= this.config.baseDrain * (this.config.drainRate || 1) * dt
```

and the timeout at `:162`:

```ts
    } else if (elapsedMs >= this.config.reelTimeout) {
```

- [ ] **Step 10: Pass them through the React layer**

In `web/src/components/TensionMinigame.tsx`, add to `Props`:

```ts
  baseDrain: number // energy drained per second in the green zone (server-authoritative)
  reelTimeout: number // ms before the fight is lost (server-authoritative)
```

In `web/src/App.tsx`, in the `TensionMinigame` element (`:72-83`):

```tsx
              drainRate={data.drainRate ?? 1}
              baseDrain={data.baseDrain ?? 12}
              reelTimeout={data.reelTimeout ?? 28000}
              fishWeight={data.fishWeight ?? 5}
```

The `??` defaults keep the NUI working if it is opened by a server running an older payload; they are fallbacks, not the source of truth.

- [ ] **Step 11: Run everything**

```bash
node tests/luarun.mjs tests/security.test.lua 2>&1 | grep -c "^ok -"
node tests/luarun.mjs tests/security.test.lua 2>&1 | grep "^not ok" || echo "ALL GREEN"
cd web && npm run build && npx vitest --run -u bundleRebuildPreservation && npm test && cd ..
```

Expected: `46` Lua tests then `ALL GREEN`; `tsc` clean; the full web suite green including `rigMenuBundleRebuild.exploration.test.ts` (it asserts six selectors keep the literal `#fff` in the minified CSS — a rebuild must not disturb that).

- [ ] **Step 12: Commit**

```bash
git add config/main.lua server/session.lua client/minigame.lua locales/ tests/security.test.lua
git add web/src web/dist web/src/__tests__/__snapshots__/
git commit -m "fix: single-source the drain constant and the reel timeout

The base drain 12 lived in both minigameEngine.ts and session.lua's claim
validation, and the engine hard-coded a 28s timeout while the server rejected
past Config.Timings.reelTimeout + 5000 -- so an admin lowering reelTimeout
below 23s made the server refuse fights before the NUI gave up.

Both now ship in the bite payload from Config.Minigame.baseDrain and
Config.Timings.reelTimeout. The server's + 5000 stays as latency grace on top
of one authoritative timeout.

Also drops the 1.7 reelDrain fallback in the claim floor: the bite payload
tells the client 1.0, so assuming 1.7 gave every non-assembly player a 1.7x
discount, compounded by the 0.6 slack. Now 1.0 and 0.9."
```

---

## Task 7: Keep / Release becomes Continue

The catch card offers KEEP and RELEASE. Both call `closeCatchCard()` and do exactly the same thing (`client/minigame.lua:92-93`), because the fish was already granted at claim time — before the card ever rendered (ARCHITECTURE §9). The choice is theatre.

A real release belongs with the Phase 2 conservation/achievement work, where it can carry an actual reward trade. Until then the honest UI is one button.

**Blast radius, already checked:** no web test references `ui_keep`, `ui_release` or `CatchCard` by name. `localeTextPreservation.test.ts` covers only the rig keys and `equip_hint`; `App.test.tsx` does not render the caught state. The one thing to re-verify after the rebuild is `rigMenuBundleRebuild.exploration.test.ts`, whose `OTHER_HUD_BASELINE` includes catch-card selectors — both buttons share `.hud-btn`, so removing one should not drop a CSS rule, but confirm rather than assume.

**Files:**
- Modify: `web/src/components/CatchCard.tsx:24-31`
- Modify: `client/minigame.lua:87-93`
- Modify: `locales/en.json:63-64`, `locales/th.json`
- Test: `web/src/__tests__/App.test.tsx`

**Interfaces:**
- Consumes: nothing from earlier tasks
- Produces: the `release` NUI callback no longer exists. New locale key `ui_continue`.

- [ ] **Step 1: Write the failing test**

Add to `web/src/__tests__/App.test.tsx`:

```tsx
it('the catch card offers a single Continue action', async () => {
  render(<App />)
  window.dispatchEvent(new MessageEvent('message', {
    data: { action: 'caught', label: 'Bass', weight: 2.4, quality: 3 },
  }))
  const buttons = await screen.findAllByRole('button')
  expect(buttons).toHaveLength(1)
})
```

Match the existing tests in that file for how they dispatch NUI messages and how `fetchNui` is mocked — copy their setup rather than inventing one.

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd web && npx vitest --run App
```

Expected: `expected length 1, received 2` — Keep and Release both render.

- [ ] **Step 3: Collapse the two buttons**

In `web/src/components/CatchCard.tsx`, replace the `catch-actions` block:

```tsx
      <div className="catch-actions">
        <button className="hud-btn hud-btn--primary" onClick={() => fetchNui('keep')}>
          {t('ui_continue')}
        </button>
      </div>
```

The callback stays `keep` — it is the teardown path the Lua side already implements, and renaming it would churn `client/minigame.lua` for nothing.

- [ ] **Step 4: Drop the dead Lua callback**

In `client/minigame.lua`, replace `:92-93`:

```lua
RegisterNUICallback('keep', function(_, cb) cb({}); closeCatchCard() end)
```

- [ ] **Step 5: Add the locale key**

`locales/en.json` — add alongside the existing `ui_keep` / `ui_release` at `:63-64`, which stay for one release so a server on an older bundle does not show a raw key:

```json
  "ui_continue": "Continue",
```

`locales/th.json`:

```json
  "ui_continue": "ต่อไป",
```

- [ ] **Step 6: Run the test to verify it passes, then rebuild**

```bash
cd web && npx vitest --run App && npm run build && npx vitest --run -u bundleRebuildPreservation && npm test && cd ..
node tests/luarun.mjs tests/security.test.lua 2>&1 | grep "^not ok" || echo "ALL GREEN"
```

Expected: the App test passes; `npm test` green including `rigMenuBundleRebuild.exploration.test.ts`; Lua suite still green.

- [ ] **Step 7: Commit**

```bash
git add web/src web/dist client/minigame.lua locales/ web/src/__tests__/__snapshots__/
git commit -m "fix: replace the fake Keep/Release choice with Continue

The fish is granted at claim time, before the catch card renders, and both
buttons called the same closeCatchCard() teardown -- Release has never released
anything. One honest button until Phase 2 gives release a real reward trade.

ui_keep and ui_release stay in the locales for one release so an older bundle
does not render a raw key."
```

---

## Task 8: Fix the two README drifts

`README.md` documents two things the code does not do. Both are already recorded in ARCHITECTURE §10; this task fixes the source. For a paid resource a documentation bug is a support ticket, and the second one ("tables created automatically") makes a buyer think the script is broken when nothing works on first boot.

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: nothing
- Produces: nothing

- [ ] **Step 1: Confirm both claims are still wrong**

```bash
grep -rn "fishrig\|manageRod\|Manage Rod" README.md client/ server/
grep -n "automatically\|auto-create\|created automatically" README.md
grep -n "RegisterCommand\|RegisterKeyMapping" client/rig.lua
```

Expected: `fishrig` / `Manage Rod` appear in `README.md` and in two comment lines only; there is no `RegisterCommand('fishrig', ...)`. `client/rig.lua:104` registers `zfishing_rig` on the `G` keybind. `README.md` claims tables are created automatically.

- [ ] **Step 2: Correct the rig menu entry point**

Replace the README's rig-menu instructions. The only entry point is the `G` keybind during equip standby — after the line is in the water, `G` does nothing:

```markdown
### Assembling a rod

Equip a fishing rod and press **G** while in equip standby (before you cast) to
open the rig menu. Fit a reel, line, hook and float; a rod must be fully
assembled before it can cast when `Config.RequireAssembly` is on.

The keybind is registered as `zfishing_rig` and can be rebound in
**Settings → Key Bindings → FiveM**. Once the line is in the water the menu is
closed and `G` does nothing.
```

- [ ] **Step 3: Correct the database section**

```markdown
### Database

The resource does **not** create or alter schema. Apply
`migrations/mysql/001_schema.up.sql` with your usual migration tooling before
starting the resource for the first time; `migrations/checks/001_schema.verify.sql`
confirms the result. `migrations/mysql/001_schema.down.sql` reverses it.

On first boot the static files in `config/` are seeded into the database. After
that **the database is the source of truth** — editing `config/fish.lua` and
restarting will not change anything. Use the admin panel, or reseed.
```

- [ ] **Step 4: Verify nothing else in the README contradicts the code**

```bash
grep -n "command\|/zfish\|keybind" README.md
```

Cross-check each command named against the real registrations: `zfishzone` and `zfishadmin` (`server/admin.lua:72`, `:80`), `zfishreload` (`server/store.lua:141`), `zfish_roll` (`server/generator.lua:85`), `zfish_xp` (`server/progression.lua:47`), `zfishing_cancel` (`client/main.lua:244`), `zfishing_rig` (`client/rig.lua:104`), `zfishtip` (`client/anim.lua:20`). If the README lists `zfish_roll` or `zfish_xp` as player commands, mark them admin-only — Task 4 gated them.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs: fix the two README drifts

The rig menu opens on the G keybind during equip standby, not via an
ox_inventory 'Manage Rod' button or a /fishrig command -- neither exists in the
code. And the resource does not create schema: migrations/mysql/ is applied by
an external provisioner before first start.

Both were already recorded in ARCHITECTURE section 10."
```

---

## Task 9: Update the contract documentation

`docs/ARCHITECTURE.md` is the internals reference written so someone with no repository access can write correct code against this resource. Tasks 1–7 changed the network contract, the state machine and two invariants. Left stale, the document actively misleads.

**Note:** `docs/ARCHITECTURE.md` is currently untracked. Commit it unchanged *first* so this task's edits show as a reviewable diff.

**Files:**
- Modify: `docs/ARCHITECTURE.md` §2, §3.1, §3.3, §7.3, §8, §9, §10

**Interfaces:**
- Consumes: the final shipped state of tasks 1–7
- Produces: nothing

- [ ] **Step 1: Commit the file as-is first**

```bash
git add docs/ARCHITECTURE.md
git commit -m "docs: track ARCHITECTURE.md

Committed unchanged so the security-hardening edits land as a reviewable diff."
```

- [ ] **Step 2: Update §2 — the state machine**

Add `settling` between `reeling` and the session being cleared, and say what it is for: the session is locked there before `Rewards.GiveCatch` is called, so a claim replayed during the reward's yields is refused. Note that a session in `settling` accepts no transitions at all.

- [ ] **Step 3: Update §3.1 — server callback signatures**

Three rows change. Write the new signatures exactly:

- `zfishing:cast(power, rodSlot)` → `{ ok, sessionId, rod, bait }`
- `zfishing:hook(sessionId)` → `{ ok, reason? }`
- `zfishing:claim(sessionId, reelDurationMs, success, reason)` → `{ ok, fish?, reason? }`
- `zfishing:cancel(sessionId)` → `{ ok, reason? }`

Add the two new rejection reasons to the reason table: `invalid_session` (token missing or stale) and `too_many_requests` (per-action gate). State plainly that the token is correlation and stale-request protection, not a secret — a modified client can read its own.

- [ ] **Step 4: Update §3.3 — the bite and reel payloads**

`zfishing:bite` now carries `{ behavior, tensionDiff, fishEnergy, hookWindow, greenZone, snapFactor, drainRate, baseDrain, reelTimeout, fishWeight }`. The NUI `reel` message carries the same plus `startedAt`. Spell out the distinction that §8 invariant 6 already warns about: `drainRate` is the reel-quality multiplier, `baseDrain` is the per-second green-zone drain.

- [ ] **Step 5: Update §7.3 — the minigame math**

`energy -= baseDrain * drainRate * dt` and the timeout row becomes `elapsedMs >= reelTimeout`. Both are now injected from the bite payload rather than hard-coded.

- [ ] **Step 6: Rewrite §8 invariants 1 and 2**

Both are resolved. Rewrite them as history plus the new rule — "the drain constant was duplicated in the engine and the claim validator; it is now `Config.Minigame.baseDrain`, shipped in the bite payload. Retuning it is a one-line change in `config/main.lua`."

For invariant 2, **state explicitly that the server's `+ 5000` at `session.lua:194` stays** and is now purely latency grace on top of one authoritative timeout, not a second competing limit. Without that sentence the next reader sees two numbers and "fixes" it.

- [ ] **Step 7: Update §9 and §10**

Remove the "Keep and Release do the same thing" note from §9 — Task 7 removed the choice. Add a line to §9 recording that boat anchoring is now proximity-validated server-side and *why* it is proximity rather than seat occupancy, so nobody "tightens" it into a seat check and breaks deck fishing.

From §10, remove both fixed README drifts and the "No true fish release" gap (reword: release is deferred to Phase 2, and the UI no longer offers a fake choice).

- [ ] **Step 8: Verify the document against the code**

For each contract table row you touched, open the file and confirm the signature matches. Documentation that drifts on the same day it is written is worse than none.

```bash
grep -n "lib.callback.register" server/session.lua server/rig.lua
grep -n "TriggerClientEvent('zfishing:bite'" -A 12 server/session.lua
```

- [ ] **Step 9: Commit**

```bash
git add docs/ARCHITECTURE.md
git commit -m "docs: bring ARCHITECTURE up to the hardened contract

Session tokens on every transition, the settling state, the two new rejection
reasons, baseDrain/reelTimeout in the bite payload, invariants 1 and 2 resolved,
and the boat anchor's proximity rule with the reason it is not a seat check."
```

---

## Task 10: Design doc for the deferred minigame-authority rewrite

Task 6 tightened the plausibility envelope. It did not move authority: the NUI still decides `success` and the server still only checks that the timing was plausible. This task writes the design for the fix, without implementing it.

**Why the obvious approach does not work.** The spec's source document recommended shipping a `fightSeed` from the server and having the client replay a deterministic minigame, sending an input timeline the server re-simulates. `minigameEngine.ts` is a `dt`-integrator — `tick(dt, holding, elapsedMs)` accumulates both energy and tension as `* dt`. Replaying a client-supplied input timeline requires the client's `dt` sequence, so the client still controls the integration result. The `Math.random()` calls in `pullFor` and `centerTargetFor` are the *second* obstacle, not the first. A seed moves the exploit one layer down at high cost.

**Files:**
- Create: `docs/superpowers/specs/2026-08-18-zfishing-minigame-authority-design.md`

**Interfaces:**
- Consumes: the shipped state after Task 6
- Produces: a design document only. No code.

- [ ] **Step 1: Write the design document**

It must cover, concretely:

1. **The fixed-timestep contract.** The server picks a tick interval (e.g. 50ms) and a total tick count derived from `Config.Timings.reelTimeout`, and sends both in the bite payload. The NUI renders at whatever frame rate it likes but samples `holding` at those fixed points, buffering one bit per tick. `claim` sends the buffer. The server integrates with its own `dt` — a constant it chose — and decides `success` / `snap` / `timeout` itself. The client's verdict stops being an input.

2. **Porting the integrator to Lua.** The tension and energy update, the green-band centre easing, `pullFor`, `centerTargetFor`, the snap budget, and the finish-condition ordering all move into a shared module the server owns. Record that the NUI must run the *same* integrator so the player sees what the server scores; the Lua side becomes the reference and TypeScript mirrors it. Note the float-behaviour risk explicitly: Lua 5.4 doubles and JS numbers agree on the arithmetic here, but the transcendental in `centerTargetFor` (`Math.sin` vs `math.sin`) is not bit-guaranteed across implementations, so the design must either avoid it in the scored path or accept a tolerance band.

3. **Eliminating the randomness.** `pullFor`'s `erratic` branch re-rolls `5 + Math.random() * 30` every 700–1500ms and `centerTargetFor`'s re-rolls the band centre. Both must become a seeded PRNG whose seed the server mints at bite time and whose algorithm both sides implement identically — a small explicit LCG or xorshift, never the host's `math.random` / `Math.random`, whose sequences differ.

4. **Payload cost.** One bit per tick; at 50ms over a 30s fight that is 600 bits. Specify the encoding (a run-length list of `holding` transitions is smaller and matches how humans actually play) and a hard server-side cap on buffer length so the buffer itself cannot become a flood vector.

5. **What this does and does not buy.** It makes the *outcome* server-decided. It does not stop a bot from playing perfectly — that is an input-pattern problem, and the design should say so rather than implying the rewrite ends cheating.

6. **Migration.** The bite payload, the `claim` signature, `minigameEngine.ts` and the NUI input loop all change together. Note that `client/minigame.lua`'s `reelInput` message (`:48-58`) currently pushes a message on every `holding` *change*, which is already close to the sampling model the design needs.

- [ ] **Step 2: Verify the document names real code**

Every file path, function name and line reference in the document must exist. Check each one:

```bash
grep -n "pullFor\|centerTargetFor\|Math.random" web/src/engine/minigameEngine.ts
grep -n "reelInput" client/minigame.lua
```

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/specs/2026-08-18-zfishing-minigame-authority-design.md
git commit -m "docs: spec the fixed-timestep minigame authority rewrite

Records why the seed-plus-replay approach does not move authority (the engine
integrates on client-supplied dt, so replay still lets the client pick the
result) and designs the version that does: server-defined tick schedule, client
reports holding bits at those samples, server integrates and scores.

Design only -- no implementation."
```

---

## Final verification

Run before opening the merge. Every number here is checkable; do not report done on any of it without seeing the output.

```bash
# 1. All three Lua suites green
node tests/luarun.mjs tests/security.test.lua 2>&1 | grep -c "^ok -"      # expect 46
node tests/luarun.mjs tests/security.test.lua 2>&1 | grep "^not ok" || echo "SECURITY GREEN"
node tests/luarun.mjs tests/water_validation.test.lua 2>&1 | tail -3
node tests/luarun.mjs tests/water_validation_preservation.test.lua 2>&1 | tail -3

# 2. TypeScript compiles and the bundle rebuilds cleanly
cd web && npm run build

# 3. The whole NUI suite, including the preservation guards
npm test && cd ..

# 4. The committed bundle matches the source it was built from
git status --short web/dist    # expect empty: dist was rebuilt AND committed
```

**Whole-branch gate:** all three Lua suites green, `tsc` clean, the web suite green (was 17 files / 63 tests before this work; Tasks 6 and 7 add cases), `web/dist` rebuilt and committed, and the Lua hash snapshot matching the files on disk.

### Live end-to-end — still unverified, and stays that way unless run

ARCHITECTURE §10 records that this resource has never been verified end-to-end on a live FiveM server. Nothing in this plan changes that: the Lua harness runs in a wasmoon VM with mocked hosts, and the NUI suite runs in jsdom. Neither exercises a real game client, a real inventory resource, or a real database.

On a server with `zcore_lib` + `ox_inventory`, confirm:

1. Cast → hook → reel → catch completes and the card shows **one** Continue button.
2. `/zfish_xp` as a non-admin does nothing; as an admin it still grants 50 XP.
3. A replayed `claim` on an already-settled session is refused (watch for the `claim settled session=` log line appearing exactly once per catch).
4. Anchoring another player's boat from across the map does nothing; fishing from a boat you are standing on still anchors it.
5. Setting `reelTimeout` to 10000 in the admin panel makes the **NUI itself** give up at 10s, rather than the server rejecting a fight the NUI thought was still live.
6. Fishing with a fully assembled rod and with no rig both still work — Task 6 changed the `reelDrain` fallback, which is the non-assembly path.

Report these as verified only after running them.
