# Sonar Strike, server side (Phase D1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the server half of `sonar_strike` — a deterministic pass timeline, server-derived strike timing, and a committed fixture the TypeScript half will later be pinned against.

**Architecture:** `server/encounter_sonar.lua` implements the same module contract the other two use, plus one additive contract refinement: `mod.act` gains a fourth `meta` argument carrying the striking player's ping, because this is the first encounter whose scoring depends on *when* an action arrived rather than only on what it was. The pass timeline is closed-form mathematics over a seeded record, so the same seed always produces the same fight.

**Tech Stack:** Lua 5.4 (FiveM `cerulean`), ox_lib callbacks, wasmoon test harness, Node for fixture generation.

**Spec:** `docs/superpowers/specs/2026-08-20-zfishing-encounter-system-design.md` §6, plus `docs/ARCHITECTURE.md` §12.

**Prerequisite — verify before starting:**

```bash
grep -c "Encounter.Register" server/encounter_mindgame.lua && grep -c "fish_mindgame" fxmanifest.lua
```

Both must be non-zero. Phase C merged to `main` at `604b9d8`, where 244 Lua tests and 89 web tests pass. This plan's branch is `encounter-sonar`, cut from that merge.

---

## Why Phase D is split, and what D2 gets

§9.3 wants `posAt` implemented twice — once in Lua, once in `web/src/engine/sonarTimeline.ts` — with a committed fixture proving they agree. D1 ships the Lua side and the fixture. D2 ships the TypeScript side, `SonarStrike.tsx`, and the bridge key map.

The split is at the fixture because D2's real dependency is D1's *shipped* constants and fixture format, not this plan's description of them. Writing both now would mean guessing the interface between them, which is the failure Phases B and C avoided by writing each plan only after its predecessor's real code existed.

At the end of D1, `sonar_strike` is registered, playable by the resolver, and **has no UI**. That is the same state `counter_pull` sat in after Phase A: reachable, tested, undrawn. `Encounter.Playable` will report it true, so **D1 must not be merged and left indefinitely** — an admin forcing `sonar_strike` between D1 and D2 gets a fight with no picture. Task 4 Step 2 adds a console warning covering exactly that gap.

## Global Constraints

- **The module contract changes once, additively.** `mod.act(enc, action, now, meta)` gains `meta`; `counter_pull` and `fish_mindgame` ignore the new argument and neither file is edited. Everything else — `build(ctx) -> state, estimate`, `render(enc, now)`, `state.deadline` absolute, `Encounter.Register(id, mod)` — is unchanged.
- **Absolute time never leaves the server.** `render` emits `...In` durations only.
- **Every authoritative transition carries `phaseId`.**
- **The client never tells the server when it struck.** It reports *that* it struck; the server derives the moment from arrival time minus a bounded ping compensation. No client-supplied time may appear in any expression deciding a hit, a grade, or a reward.
- **A strike is never scored against something the UI was not showing.** The Phase C rule (§12.11) applies here too — it is what forbids GHOST from ever hiding the real fish.
- **`requiredHits` is the tier.** A PERFECT and a SAFE advance the fight by exactly one hit. PERFECT buys score only. Nothing — profile, float, rod, ping — changes how many hits a fight costs.
- **Lua files stay flat.** `tests/luarun.mjs` mounts `client/`, `server/`, `shared/`, `tests/` non-recursively **and only `.lua` files**. A fixture under `tests/fixtures/` or in `.json` form is invisible to the Lua VM; see Task 4.
- **`legacy_tension`, `counter_pull` and `fish_mindgame` are untouched.** All 244 existing Lua tests and 89 web tests must stay green.
- **Baseline to preserve:** `cd tests && npm run test:all` reports 12 suites / 244 tests; `npm --prefix web test` reports 89.
- Stable ids verbatim: encounter `sonar_strike`; player action `strike`, plus the universal `advance`; grades `perfect`, `safe`, `miss`; profiles `DART`, `HEAVY`, `STALKER`, `GHOST`.

---

## The design, derived

The spec leaves three things open and explicitly instructs that a fourth be re-derived. All four are settled here, before any code, because the tier table is an *output* of these decisions rather than an input.

### D.1 `posAt` was never defined — here it is

§6.1 lists `pass = { ..., profile, speed, dir, weakOffset, weakHalf, ... }` and calls `posAt(t)` "pure mathematics over this record" without giving the function. Two of those fields over-determine the motion (`duration` and `speed` both set the pace) and one adds no gameplay (`weakOffset` shifts where on the fish the weak spot sits, which is indistinguishable from shifting the fish). Both are dropped. The record becomes:

```lua
pass = { index, startAt, duration, hold, profile, dir, k, weakHalf, perfectHalf, decoy }
```

The lane is normalized `[0, 1]` with a fixed target marker at `TARGET = 0.5`. The fish's **weak centre** travels across the lane exactly once per pass:

```
u  = clamp((t - hold) / (duration - hold), 0, 1)     -- 0..1 over the moving part
c  = u - 0.5
f  = 0.5 + (1 - k) * c + 4 * k * c^3                 -- monotone for k in (-0.5, 1)
weakAt(t) = dir > 0 and f or (1 - f)
```

`f` is a one-parameter cubic easing. `k = 0` is linear. `k > 0` is slow at the centre and fast at the edges; `k < 0` is the reverse. `f'(u) = (1 - k) + 12k·c²`, so the minimum slope is `1 - k` at the centre and `1 + 2k` at the edges — both positive across `k ∈ (-0.5, 1)`, which is what makes `f` monotone and the crossing unique.

`hold` is a dead time at the start of the pass during which the fish sits still.

### D.2 One crossing per pass, and why

The weak centre passes the target **exactly once**. STALKER's specced "forward, pause, reverse, accelerate" is delivered as **pause, then accelerate through** — the reverse is dropped.

A second crossing would cost three things that buy nothing: `vTarget` stops being a single number (so the millisecond floor of D.4 has no value to evaluate at), a strike between crossings needs its own rule, and the NUI must show whether a pass is still live after a strike. One crossing makes "one strike per pass" the whole rule.

### D.3 Profiles, and the rule GHOST must not break

| behavior | profile | `k` | `hold` | reads as |
|---|---|---|---|---|
| `steady_light` | `DART` | −0.40 | 0 | crawls in, whips through the target |
| `steady_heavy` | `HEAVY` | +0.50 | 0 | arrives fast, labours across the target |
| `run_stop` | `STALKER` | −0.30 | 0.35 × duration | sits still, then breaks |
| `erratic` | `GHOST` | 0.00 | 0 | steady, but the picture lies |

GHOST's specced "signal fades and returns" is implemented as an **opacity oscillation with a floor of 0.35 — the real fish is never invisible.** Hiding a strikeable target is the exact thing §12.11 forbids: a strike scored against a fish the UI was not drawing.

GHOST's difficulty comes from a **decoy** instead, at tier ≥ 4: a second blip on its own `k`/`dir`, carrying no weak band. Striking while only the decoy is near the target is a MISS. The real fish is always on screen, so the player is never guessing blind — they are reading which of two things is real.

### D.4 The widths, re-derived in milliseconds

§6.4 states the normalized table is "a starting point, not a tuned table", and requires the implementation plan to convert every width to milliseconds of travel and widen what is too tight. Doing that.

**Error budget.** The gap between the instant a player perceives the fish over the target and the `strikeAt` the server computes:

| source | magnitude | direction |
|---|---|---|
| client frame + input poll | ~25ms at 40fps | always late |
| ping jitter over a pass | ±25ms | either |
| compensation residual (asymmetric route, ping granularity) | ±20ms | either |

Root-sum-square ≈ 41ms, linear worst case ≈ 70ms. **`MIN_PERFECT_MS = 90`** and **`MIN_WEAK_MS = 240`** — SAFE gets the wider floor because it is the difference between progress and damage, which must not turn on connection quality at all.

These are an estimate, not a measurement. Task 5 puts a checklist row on measuring the real tier-5 PERFECT rate across three ping bands, so the live pass can falsify the number.

**Conversion.** The crossing happens where `weakAt(t) = TARGET`, which for this family is the midpoint of the moving part, so:

```
vTarget = (1 - k) / (duration - hold)          -- lane per ms
window(halfWidth) = halfWidth / vTarget         -- ms, half-width
```

At tier 5 (`duration = 2400`, `weakHalf = 0.08`, `perfectHalf = 0.03`), before any floor:

| profile | `vTarget` (lane/ms) | PERFECT window | SAFE window | verdict |
|---|---|---|---|---|
| `DART` | 5.83e−4 | **±51ms** | ±137ms | both too tight |
| `HEAVY` | 2.08e−4 | ±144ms | ±384ms | fine |
| `STALKER` | 8.33e−4 | **±36ms** | ±96ms | both far too tight |
| `GHOST` | 4.17e−4 | **±72ms** | ±192ms | both too tight |

Three of four profiles put PERFECT inside the error budget at tier 5 — it would have been partly a lottery on connection quality, exactly as §6.4 warned.

**The fix is a per-pass floor, not a per-tier one**, because the shortfall depends on the profile as much as the tier:

```lua
weakHalf    = math.max(tier.weakHalf * (1 + greenZone), MIN_WEAK_MS * vTarget)
perfectHalf = math.max(tier.perfectHalf,                MIN_PERFECT_MS * vTarget)
perfectHalf = math.min(perfectHalf, weakHalf * 0.8)     -- PERFECT stays strictly inside SAFE
```

Resulting tier-5 half-widths (no rod bonus):

| profile | `weakHalf` | SAFE window | `perfectHalf` | PERFECT window |
|---|---|---|---|---|
| `DART` | 0.140 | ±240ms | 0.0525 | ±90ms |
| `HEAVY` | 0.080 | ±384ms | 0.0300 | ±144ms |
| `STALKER` | 0.200 | ±240ms | 0.0750 | ±90ms |
| `GHOST` | 0.100 | ±240ms | 0.0375 | ±90ms |

Every window is now at or above the floor, and HEAVY keeps its specced identity: the narrowest *band* on screen, and still the most forgiving *timing*, because it is the slowest thing crossing the target.

### D.5 Deliberate deviations from §6

| §6 says | this plan does | why |
|---|---|---|
| strike payload carries `passIndex`, rejected as `stale_pass` | omitted; `seq` is the staleness axis | `seq != enc.seq + 1` already rejects every stale, replayed and fabricated action. A second staleness axis is a second source of truth with no extra security. |
| client may send `clientAtMs` for telemetry | omitted | Nothing consumes it. A field that is written and never read is not telemetry, it is a field a future reader has to prove is unused. |
| `line <= 0 -> snap` is a sonar outcome | sonar has one failure axis: `misses` | With `maxMisses` 2–3 and any sane line pool, escape always fires first — `snap` is unreachable. Inventing damage numbers to make it reachable adds an axis the player cannot manage: there is nothing to give in sonar. Sonar's outcomes are `success`, `escape`, `timeout`. |
| `pass.speed`, `pass.weakOffset` | dropped | `speed` over-determines the pace `duration` already sets; `weakOffset` is indistinguishable from moving the fish. |

### D.6 Two clocks in one call, on purpose

The dispatcher checks `enc.expiresAt` and `state.deadline` against the raw `GetGameTimer()`, while the sonar module grades against `now - compensation`. That is intentional: the expiry backstop is about wall-clock abandonment and should not be movable by a client's reported ping, whereas the grade is about a human's timing and should be. The gap is bounded by `MAX_COMPENSATION = 200`.

This is worth writing down in §12.12, because a reader who finds two different "now" values in one code path will otherwise assume one of them is a bug.

---

## File Structure

| File | Responsibility | Task |
| --- | --- | --- |
| `server/encounter.lua` | **Modify.** Pass `meta = { ping }` into `mod.act`. | 1 |
| `shared/rig_rules.lua` | **Modify.** Surface the fitted float item, as `hook` already is. | 1 |
| `server/session.lua` | **Modify.** Carry the float through cast into the encounter gear table. | 1 |
| `tests/encounter_action.test.lua` | **Modify.** Cover the new `meta` argument. | 1 |
| `server/encounter_sonar.lua` | **Create.** Timeline, pass generation, strike evaluation. | 2 |
| `tests/encounter_sonar.test.lua` | **Create.** The fight, deterministic throughout. | 2 |
| `tests/sonar_fixture.lua` | **Create (generated).** Sampled timeline, committed. | 3 |
| `web/src/engine/__fixtures__/sonarTimeline.json` | **Create (generated).** The same samples, for D2. | 3 |
| `tests/gen_sonar_fixture.mjs` | **Create.** Emits both, from the Lua implementation. | 3 |
| `tests/package.json` | **Modify.** Suite script, `test:all`, fixture script. | 2, 3 |
| `fxmanifest.lua`, `docs/*` | **Modify.** | 4 |

---

## Task 1: The `meta` argument, and the float

Two small edits to shared files, done together because neither is worth its own test cycle and both are prerequisites for Task 2.

**Files:**
- Modify: `server/encounter.lua`
- Modify: `shared/rig_rules.lua`
- Modify: `server/session.lua`
- Modify: `tests/encounter_action.test.lua`

**Interfaces:**
- Produces: `mod.act(enc, action, now, meta)` where `meta = { ping = <number> }`; `ctx.gear.float` in `mod.build`, a float item id string or `nil`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/encounter_action.test.lua`, before `H.run()`:

The suite's existing helpers are `fakeModule()` and `startEncounter(src, mod)`, the latter
returning `sessionId, challengeId, calls`. Wrap them rather than building a parallel spy —
the point is that the *existing* module shape keeps working.

```lua
-- ------------------------------------------------------------------ act meta

-- Wraps fakeModule so a test can see exactly what the dispatcher handed it, without
-- changing how the module behaves.
local function watch(mod, seen)
    local realAct, realBuild = mod.act, mod.build
    mod.act = function(enc, action, now, meta)
        seen.action, seen.now, seen.meta = action, now, meta
        return realAct(enc, action, now)
    end
    mod.build = function(ctx)
        seen.gear = ctx.gear
        return realBuild(ctx)
    end
    return mod
end

test('C12 the dispatcher hands the module the acting player ping', function()
    local seen = {}
    local sid, cid = startEncounter(5, watch(fakeModule(), seen))
    _G.__PING = 137
    local r = H.CB['zfishing:encounter:act'](5, sid, cid, 1, 'good')
    truthy(r.ok, tostring(r.reason))
    equal(type(seen.meta), 'table', 'act must receive a meta table')
    equal(seen.meta.ping, 137, 'and the ping must be the one the server measured')
end)

test('C13 meta is additive -- the three-parameter modules still work untouched', function()
    -- fakeModule's own act takes three parameters, exactly as counter_pull and
    -- fish_mindgame do. Lua drops the extra argument silently; this pins that the
    -- dispatcher depends on nothing the older signature cannot provide.
    local seen = {}
    local sid, cid = startEncounter(5, watch(fakeModule(), seen))
    local r = H.CB['zfishing:encounter:act'](5, sid, cid, 1, 'good')
    truthy(r.ok)
    equal(r.seq, 1)
    equal(seen.action, 'good')
    equal(type(seen.now), 'number', 'the raw server clock is still the third argument')
end)

test('C14 the fitted float reaches a module through ctx.gear', function()
    -- startEncounter hardcodes a bare session, so boot this one directly to fit a rod.
    local seen = {}
    H.loadSession({ encounterMode = 'forced', forcedEncounter = 'counter_pull',
                    rig = true, stats = { float = 'float_smart' } })
    Encounter.Register('counter_pull', watch(fakeModule(), seen))
    local cast = H.CB['zfishing:cast'](5, 0.5, 1)
    truthy(cast.ok, tostring(cast.reason))
    H.fireLatestTimer()
    truthy(H.CB['zfishing:hook'](5, cast.sessionId).ok)
    equal(seen.gear.float, 'float_smart',
        'the float tier changes what the sonar NUI can draw, so a module must see it')
end)
```

- [ ] **Step 2: Run them to verify they fail**

```bash
node tests/luarun.mjs tests/encounter_action.test.lua
```

Expected: C12 fails (`seen.meta` is nil) and C14 fails (`seen.gear.float` is nil). C13 passes already — that is the point of it.

- [ ] **Step 3: Pass the ping into the module**

In `server/encounter.lua`, `evaluate` currently reads:

```lua
local function evaluate(s, action, now)
    local enc = s.encounter
    local mod = Encounter.MODULES[enc.type]
    local res = mod.act(enc, action, now) or {}
```

Give it the meta table:

```lua
-- `meta` carries per-action facts a module may need that are not encounter state. Today
-- that is the striking player's ping, for `sonar_strike`: it is the first encounter whose
-- score depends on WHEN an action arrived, so it compensates arrival time rather than
-- trusting a client-reported moment.
--
-- Note the two clocks this creates in one call, deliberately. `now` here is the raw
-- server clock, and it is what expiresAt and state.deadline are judged against, because
-- the expiry backstop is about abandonment and must not be movable by a reported ping.
-- A module that grades timing subtracts its own bounded compensation from `now`.
local function evaluate(s, action, now, meta)
    local enc = s.encounter
    local mod = Encounter.MODULES[enc.type]
    local res = mod.act(enc, action, now, meta) or {}
```

and at its one call site inside the `zfishing:encounter:act` callback:

```lua
    local res = evaluate(s, action, now, { ping = GetPlayerPing(src) or 0 })
```

- [ ] **Step 4: Surface the fitted float**

In `shared/rig_rules.lua`, `ExtractStats` already returns the hook item id verbatim. Add the float the same way — the float's *tier* changes what the sonar NUI may draw, and `biteSpeed` alone cannot identify it:

```lua
    return {
        reelDrain      = reel.drainRate or 1.0,
        lineRating     = line.rating or 10,
        hook           = hook,
        float          = p.float,
        floatBiteSpeed = float.biteSpeed or 1.0,
    }
```

In `server/session.lua`, the cast handler stores selected stats onto the session near line 215. Add the float beside `reelDrain`:

```lua
        float = stats and stats.float or nil,
```

and in the `zfishing:hook` handler's `Encounter.Begin` gear table near line 275:

```lua
            float      = s.float,
```

- [ ] **Step 5: Run the suite**

```bash
node tests/luarun.mjs tests/encounter_action.test.lua
```

Expected: all pass, three more than before.

- [ ] **Step 6: Re-run every suite**

```bash
cd tests && npm run test:all
```

Expected: 12 suites, 247 tests, exit 0. `counter_pull` and `fish_mindgame` must be untouched and green — if either moved, the change was not additive.

- [ ] **Step 7: Commit**

```bash
git add server/encounter.lua shared/rig_rules.lua server/session.lua tests/encounter_action.test.lua
git commit -m "feat: hand encounter modules the acting player's ping and fitted float"
```

---

## Task 2: The sonar module

**Files:**
- Create: `server/encounter_sonar.lua`
- Create: `tests/encounter_sonar.test.lua`
- Modify: `tests/package.json`

**Interfaces:**
- Consumes: `Encounter.Register`, `ctx = { difficulty, seed, fish, gear, now }`, `meta = { ping }`, `ZUtil.clamp`.
- Produces: `mod.actions = { strike = true }`; `Sonar.WeakAt(pass, t)` exported on a module-level `Sonar` table so Task 3's generator can sample it; render payload
  `{ phaseId, attempt, maxAttempts, hits, requiredHits, misses, maxMisses, passStartsIn, passEndsIn, duration, hold, profile, dir, k, weakHalf, perfectHalf, target, decoy?, floatTier, lastGrade? }`.

**Note on what the render may carry.** Unlike `counter_pull`'s `required` and `fish_mindgame`'s answer, the sonar timeline is *not* a secret — the NUI cannot draw the fight without it. What the player is being tested on is the moment they press, and that moment is measured on arrival. So the payload carries the whole pass record and hides nothing.

- [ ] **Step 1: Write the failing module tests**

Create `tests/encounter_sonar.test.lua`:

```lua
-- Sonar Strike. Run from the resource root:
--   node tests/luarun.mjs tests/encounter_sonar.test.lua
--
-- Sequencing, replay, stale challenge, wrong session and disconnect are covered once for
-- every encounter in tests/encounter_action.test.lua. This suite is the fight, plus the
-- timeline mathematics the NUI will later mirror.

dofile('tests/harness.lua')
local test, equal, truthy = H.test, H.equal, H.truthy

local FISH = { species = 'swordfish', label = 'Swordfish', weight = 90.0, quality = 4,
    rarity = 'epic', behavior = 'steady_light', biteDelay = 100, hookWindow = 1500,
    tensionDiff = 1.4, fishEnergy = 80, xp = 60, price = 120, difficulty = 4 }

local TIER_HITS   = { 2, 3, 3, 4, 5 }
local TIER_MISSES = { 3, 3, 2, 2, 2 }

local function start(opts)
    opts = opts or {}
    local fish = H.deepcopy(FISH)
    if opts.difficulty then fish.difficulty = opts.difficulty end
    if opts.behavior then fish.behavior = opts.behavior end

    local g = {}
    local run = function()
        g.calls = H.loadSession({ fish = fish, encounterMode = 'forced',
                                  forcedEncounter = 'sonar_strike',
                                  rig = opts.rig, stats = opts.stats })
        dofile('server/encounter_sonar.lua')
        local cast = H.CB['zfishing:cast'](5, 0.5, opts.rig and 1 or nil)
        truthy(cast.ok, tostring(cast.reason))
        H.fireLatestTimer()
        local hook = H.CB['zfishing:hook'](5, cast.sessionId)
        truthy(hook.ok); truthy(hook.encounter)
        g.expiryMs = H.TIMERS[#H.TIMERS].ms
        g.sid, g.cid = cast.sessionId, hook.challengeId
        g.last, g.at, g.seq = hook.encounter, _G.__NOW, 0
    end
    if opts.seed then H.withSeed(opts.seed, run) else run() end
    return g
end

-- Acts `offset` ms after the render was taken, at the given ping.
local function act(g, action, offset, ping)
    _G.__PING = ping or 0
    _G.__NOW = g.at + (offset or 0)
    g.seq = g.seq + 1
    local res = H.CB['zfishing:encounter:act'](5, g.sid, g.cid, g.seq, action)
    if res.ok and res.state then g.last, g.at = res.state, _G.__NOW end
    return res
end

-- The offset at which the weak centre sits exactly on the target. Derived from the
-- rendered pass the same way the NUI will have to derive it, which is the point: if this
-- helper and the module disagree, one of them is wrong about the timeline.
local function perfectOffset(g)
    local s = g.last
    return s.passStartsIn + s.hold + (s.duration - s.hold) * 0.5
end

-- An offset that lands squarely between the two bands: a hit, but not a perfect one.
-- Near the crossing the weak centre moves at (1 - k) / travel lane per ms, so a lane
-- distance d is d * travel / (1 - k) milliseconds away from the centre. The cubic term
-- is negligible at these distances -- at the widest band in the game it shifts the
-- landing point by under 0.001 lane.
local function safeOffset(g)
    local s = g.last
    local d = (s.perfectHalf + s.weakHalf) * 0.5
    return perfectOffset(g) + d * (s.duration - s.hold) / (1 - s.k)
end

test('S1 the hook answer opens pass 1 with a full timeline and no hits', function()
    local g = start({ difficulty = 5 })
    equal(g.last.attempt, 1)
    equal(g.last.hits, 0); equal(g.last.misses, 0)
    equal(g.last.requiredHits, TIER_HITS[5]); equal(g.last.maxMisses, TIER_MISSES[5])
    equal(g.last.maxAttempts, TIER_HITS[5] + TIER_MISSES[5] - 1)
    equal(g.last.target, 0.5)
    truthy(g.last.duration > 0 and g.last.passEndsIn > 0)
    truthy(g.last.perfectHalf < g.last.weakHalf, 'PERFECT must sit strictly inside SAFE')
    equal(g.last.passStartAt, nil, 'absolute server time must never reach a client')
    equal(g.last.weakCenterAt, nil, 'nor may the answer be spelled out as a timestamp')
end)

-- The dispatcher returns { ok, seq, state, outcome } and no score, so the grade values
-- themselves are pinned end to end through perfScore in S20a/S20b, not asserted here.

test('S2 a strike at the crossing is PERFECT, and one hit', function()
    local g = start({ difficulty = 5 })
    local res = act(g, 'strike', perfectOffset(g))
    equal(res.state.lastGrade, 'perfect')
    equal(res.state.hits, 1); equal(res.state.misses, 0)
end)

test('S3 a strike inside the weak band but off centre is SAFE, and also one hit', function()
    local g = start({ difficulty = 5 })
    local res = act(g, 'strike', safeOffset(g))
    equal(res.state.lastGrade, 'safe')
    equal(res.state.hits, 1, 'SAFE and PERFECT advance the fight by exactly the same amount')
    equal(res.state.misses, 0)
end)

test('S4 a strike outside the weak band is a MISS', function()
    local g = start({ difficulty = 5 })
    local res = act(g, 'strike', g.last.passStartsIn + 1)   -- at the very start of the pass
    equal(res.state.lastGrade, 'miss')
    equal(res.state.hits, 0); equal(res.state.misses, 1)
end)

test('S5 a strike after the pass has ended is a MISS, not an error', function()
    local g = start({ difficulty = 5 })
    local res = act(g, 'strike', g.last.passEndsIn + 500)
    truthy(res.ok)
    equal(res.state.misses, 1)
end)

test('S6 advance on an expired pass is a MISS and arms the next one', function()
    local g = start({ difficulty = 5 })
    local before = g.last.phaseId
    local res = act(g, 'advance', g.last.passEndsIn + 400)
    truthy(res.ok)
    equal(res.state.misses, 1)
    equal(res.state.attempt, 2)
    truthy(res.state.phaseId > before)
end)

test('S7 ping compensation moves a late strike back onto the target', function()
    -- The same real-world timing, sent by two players on different connections. The
    -- laggy one arrives later in server time; compensation is what makes them equal.
    local sharp = start({ difficulty = 5, seed = 7 })
    local sharpRes = act(sharp, 'strike', perfectOffset(sharp), 0)

    local laggy = start({ difficulty = 5, seed = 7 })
    local laggyRes = act(laggy, 'strike', perfectOffset(laggy) + 90, 180)   -- 180/2 = 90ms back

    equal(sharpRes.state.lastGrade, 'perfect')
    equal(laggyRes.state.lastGrade, 'perfect',
        'a 180ms player striking at the same real moment must be graded the same')
end)

test('S8 compensation is bounded, so a huge reported ping cannot buy a better grade', function()
    local g = start({ difficulty = 5, seed = 7 })
    -- 2000ms of ping would be 1000ms of compensation if it were unbounded; the cap is 200.
    local res = act(g, 'strike', perfectOffset(g) + 900, 2000)
    equal(res.state.lastGrade, 'miss',
        'MAX_COMPENSATION must cap the rewind, or ping becomes a cheat surface')
end)

test('S9 a strike is never graded against a client-supplied moment', function()
    -- The action is a bare string. There is no argument the client could put a time in.
    local g = start({ difficulty = 5 })
    local res = act(g, 'strike', g.last.passStartsIn + 1)
    equal(res.state.lastGrade, 'miss', 'and it is graded on arrival, not on intent')
    equal(res.state.clientAtMs, nil, 'no client time is echoed back either')
end)

test('S10 reaching requiredHits wins, and never needs more than the tier says', function()
    for tier = 1, 5 do
        local g = start({ difficulty = tier })
        local res
        for _ = 1, TIER_HITS[tier] do
            res = act(g, 'strike', perfectOffset(g))
        end
        equal(res.outcome, 'success',
            ('tier %d must land in exactly %d hits'):format(tier, TIER_HITS[tier]))
        equal(res.state.hits, TIER_HITS[tier])
    end
end)

test('S11 PERFECT buys score, never a shorter fight', function()
    local perfect = start({ difficulty = 5, seed = 11 })
    local n = 0
    local res
    repeat
        res = act(perfect, 'strike', perfectOffset(perfect)); n = n + 1
    until res.outcome
    equal(n, TIER_HITS[5])

    -- All SAFE, no PERFECT: the same number of strikes.
    local safe = start({ difficulty = 5, seed = 11 })
    local m = 0
    repeat
        res = act(safe, 'strike', safeOffset(safe)); m = m + 1
        equal(res.state.lastGrade, 'safe', 'this fight must not land a perfect by accident')
    until res.outcome
    equal(res.outcome, 'success')
    equal(m, TIER_HITS[5], 'a fight won entirely on SAFE takes exactly as many strikes')
end)

test('S12 reaching maxMisses loses the fish', function()
    local g = start({ difficulty = 5 })
    local res
    for _ = 1, TIER_MISSES[5] do
        res = act(g, 'strike', g.last.passStartsIn + 1)
    end
    equal(res.outcome, 'escape')
    equal(res.state.misses, TIER_MISSES[5])
end)

test('S13 sonar never snaps a line -- misses are its only failure axis', function()
    local g = start({ difficulty = 5 })
    local res
    for _ = 1, TIER_MISSES[5] do
        res = act(g, 'strike', g.last.passStartsIn + 1)
    end
    equal(res.outcome, 'escape', 'not snap')
    equal(res.state.linePct, nil, 'and sonar does not draw a line bar at all')
end)

test('S14 every profile keeps PERFECT at or above the millisecond floor, at every tier', function()
    -- The whole point of the per-pass floor: at tier 5 three of four profiles would
    -- otherwise put PERFECT inside the lag error budget.
    for tier = 1, 5 do
        for _, behavior in ipairs({ 'steady_light', 'steady_heavy', 'run_stop', 'erratic' }) do
            local g = start({ difficulty = tier, behavior = behavior })
            local s = g.last
            local vTarget = (1 - s.k) / (s.duration - s.hold)
            local perfectMs = s.perfectHalf / vTarget
            local weakMs = s.weakHalf / vTarget
            truthy(perfectMs >= 89.5,
                ('tier %d %s: PERFECT is only %dms'):format(tier, behavior, perfectMs))
            truthy(weakMs >= 239.5,
                ('tier %d %s: SAFE is only %dms'):format(tier, behavior, weakMs))
            truthy(s.perfectHalf < s.weakHalf)
        end
    end
end)

test('S15 each behaviour picks its own profile', function()
    local function profileOf(behavior)
        return start({ difficulty = 5, behavior = behavior }).last.profile
    end
    equal(profileOf('steady_light'), 'DART')
    equal(profileOf('steady_heavy'), 'HEAVY')
    equal(profileOf('run_stop'), 'STALKER')
    equal(profileOf('erratic'), 'GHOST')
end)

test('S16 the stalker holds still before it breaks, and nobody else does', function()
    truthy(start({ difficulty = 5, behavior = 'run_stop' }).last.hold > 0)
    equal(start({ difficulty = 5, behavior = 'steady_light' }).last.hold, 0)
end)

test('S17 the weak centre crosses the target exactly once per pass', function()
    -- Sampled densely. A second crossing would break the millisecond floor of S14, which
    -- has only one vTarget to be evaluated at.
    for _, behavior in ipairs({ 'steady_light', 'steady_heavy', 'run_stop', 'erratic' }) do
        local g = start({ difficulty = 3, behavior = behavior })
        local s = g.last
        local pass = { duration = s.duration, hold = s.hold, k = s.k, dir = s.dir }
        local crossings, prev = 0, nil
        for i = 0, 1000 do
            local side = Sonar.WeakAt(pass, s.duration * i / 1000) >= 0.5
            if prev ~= nil and side ~= prev then crossings = crossings + 1 end
            prev = side
        end
        equal(crossings, 1, ('%s crossed the target %d times'):format(behavior, crossings))
    end
end)

test('S18 a decoy appears only at tier 4+ on an erratic fish, and carries no weak band', function()
    equal(start({ difficulty = 3, behavior = 'erratic' }).last.decoy, nil)
    equal(start({ difficulty = 5, behavior = 'steady_light' }).last.decoy, nil)
    local d = start({ difficulty = 5, behavior = 'erratic' }).last.decoy
    equal(type(d), 'table', 'tier 5 erratic must telegraph a false echo')
    equal(d.weakHalf, nil, 'a decoy is not strikeable -- it has no band at all')
    truthy(d.k ~= nil and d.dir ~= nil, 'but the NUI still needs enough to draw it')
end)

test('S19 the float tier reaches the render and changes nothing on the server', function()
    local plain = start({ difficulty = 5, rig = true, stats = { float = 'float_wood' } })
    local smart = start({ difficulty = 5, rig = true, stats = { float = 'float_smart' } })
    truthy(smart.last.floatTier > plain.last.floatTier, 'the NUI needs to know')
    equal(plain.last.weakHalf, smart.last.weakHalf, 'but the target is exactly as hard')
    equal(plain.last.perfectHalf, smart.last.perfectHalf)
end)

-- The three score tests below are the only place the grade values (PERFECT 1.0, SAFE 0.7,
-- MISS 0) are pinned, because the act callback returns no score of its own -- it comes out
-- at settlement, through Encounter.PerfScore, which is where it actually matters.
local function scoreOf(g)
    local claim = H.CB['zfishing:claim'](5, g.sid, 0, true)
    truthy(claim.ok, tostring(claim.reason))
    equal(g.calls.give, 1, 'the catch was committed once')
    return g.calls.ctx.perfScore
end

test('S20 a flawless fight scores exactly one', function()
    local g = start({ difficulty = 1 })
    local res
    repeat res = act(g, 'strike', perfectOffset(g)) until res.outcome
    equal(res.outcome, 'success')
    equal(scoreOf(g), 1.0)
end)

test('S20a a fight won entirely on SAFE scores exactly the SAFE value', function()
    local g = start({ difficulty = 1 })
    local res
    repeat res = act(g, 'strike', safeOffset(g)) until res.outcome
    equal(res.outcome, 'success')
    equal(scoreOf(g), 0.7, 'SAFE is worth 0.7 -- a hit, but not a clean one')
end)

test('S20b a mixed fight scores strictly between zero and one', function()
    local g = start({ difficulty = 1 })
    act(g, 'strike', g.last.passStartsIn + 1)          -- MISS
    local res
    repeat res = act(g, 'strike', perfectOffset(g)) until res.outcome
    equal(res.outcome, 'success')

    local score = scoreOf(g)
    truthy(math.abs(score - 2 / 3) < 1e-9,
        ('one miss and two perfects average to 2/3, got %s'):format(tostring(score)))
end)

test('S21 the derived estimate fits inside the framework deadline, unclamped', function()
    for tier = 1, 5 do
        local g = start({ difficulty = tier })
        truthy(g.expiryMs < 120500, ('tier %d wants %dms'):format(tier, g.expiryMs))
        truthy(g.expiryMs > 15500, ('tier %d must not be floored'):format(tier))
    end
end)

H.run()
```

- [ ] **Step 2: Run them to verify they fail**

```bash
node tests/luarun.mjs tests/encounter_sonar.test.lua
```

Expected: the run aborts — `server/encounter_sonar.lua` does not exist.

- [ ] **Step 3: Write the module**

Create `server/encounter_sonar.lua`:

```lua
-- Sonar Strike.
--
-- The player watches the fish cross a sonar lane and strikes when its weak zone is over
-- the target. Not a shrinking circle, and not a green bar.
--
-- The one thing that makes this encounter different from the other two: it is scored on
-- WHEN an action arrived, not only on what it was. So the client never reports a moment.
-- It reports that it struck; the server takes the arrival time and rewinds it by a
-- bounded ping compensation. A modified client can only ever arrive LATER than a human
-- would, which makes strikes worse -- there is no way to select a favourable past
-- instant, which is exactly what a client-supplied `atMs` would have handed it.
--
-- The timeline itself is not a secret. The NUI cannot draw the fight without it, so the
-- render carries the whole pass record. What is being tested is the press, and the press
-- is measured on arrival.
--
-- Same time discipline as the others: state absolute, renders relative.

local M = {}
Sonar = Sonar or {}          -- the timeline maths, exported for the fixture generator

local TIERS = {
    [1] = { requiredHits = 2, maxMisses = 3, duration = 4000, weakHalf = 0.18, perfectHalf = 0.07 },
    [2] = { requiredHits = 3, maxMisses = 3, duration = 3600, weakHalf = 0.15, perfectHalf = 0.06 },
    [3] = { requiredHits = 3, maxMisses = 2, duration = 3200, weakHalf = 0.12, perfectHalf = 0.05 },
    [4] = { requiredHits = 4, maxMisses = 2, duration = 2800, weakHalf = 0.10, perfectHalf = 0.04 },
    [5] = { requiredHits = 5, maxMisses = 2, duration = 2400, weakHalf = 0.08, perfectHalf = 0.03 },
}

local TARGET = 0.5
-- Between passes: the fish leaves the lane and is reacquired. Nothing is strikeable here.
local INTERVAL = 700
-- Only the `advance` deadline is forgiving by this; a strike's own tolerance is weakHalf.
-- Same reason as the other two modules: jitter must not turn an honest action into a miss.
local GRACE = 250
-- Half a round trip, capped. Uncapped, a client that reports a huge ping would be handed
-- a huge rewind, and the rewind is the only thing in this encounter a client could aim.
local MAX_COMPENSATION = 200
-- The lag error budget, in milliseconds, and the reason it is 90: one frame of client
-- input delay at 40fps (~25ms), ping jitter across a pass (+/-25ms), and compensation
-- residual from route asymmetry and ping granularity (+/-20ms). Root-sum-square ~41ms,
-- linear worst case ~70ms. SAFE gets the wider floor because it is the difference between
-- progress and damage, which must not turn on connection quality at all.
--
-- These are an estimate. Section N of the live checklist measures the real tier-5 PERFECT
-- rate across three ping bands, which is what can falsify them.
local MIN_PERFECT_MS = 90
local MIN_WEAK_MS = 240

-- Movement profiles. `k` shapes the speed curve: k > 0 is slow across the target and fast
-- at the edges, k < 0 the reverse, and the family is monotone across (-0.5, 1) so the
-- weak centre crosses the target exactly once. `hold` is dead time at the start.
local PROFILES = {
    steady_light = { name = 'DART',    k = -0.40, hold = 0.00 },
    steady_heavy = { name = 'HEAVY',   k =  0.50, hold = 0.00 },
    run_stop     = { name = 'STALKER', k = -0.30, hold = 0.35 },
    erratic      = { name = 'GHOST',   k =  0.00, hold = 0.00 },
}

local FLOAT_TIER = { float_wood = 1, float_foam = 2, float_smart = 3 }

local function rand(st)
    st.rng = (1103515245 * st.rng + 12345) % 2147483648
    return st.rng / 2147483648
end

-- Where the fish's weak centre is, 0..1 across the lane, `t` ms into the pass.
-- Implemented a second time in web/src/engine/sonarTimeline.ts; tests/sonar_fixture.lua
-- and web/src/engine/__fixtures__/sonarTimeline.json exist so the two cannot drift.
function Sonar.WeakAt(pass, t)
    local travel = pass.duration - pass.hold
    local u = (t - pass.hold) / travel
    if u < 0 then u = 0 elseif u > 1 then u = 1 end
    local c = u - 0.5
    local f = 0.5 + (1 - pass.k) * c + 4 * pass.k * c * c * c
    return pass.dir > 0 and f or (1 - f)
end

-- Lane units per millisecond at the moment of the crossing. The crossing is the midpoint
-- of the moving part for this easing family, so this is a closed form rather than a
-- search -- which is what lets the millisecond floor below be applied at generation time.
function Sonar.TargetSpeed(pass)
    return (1 - pass.k) / (pass.duration - pass.hold)
end

local function armPass(st, now)
    st.phaseId = st.phaseId + 1
    st.attempt = st.attempt + 1

    local p = st.profileDef
    st.dir = rand(st) < 0.5 and 1 or -1
    st.k = p.k
    st.hold = math.floor(st.duration * p.hold)

    -- The floor, applied per pass rather than per tier, because how tight a band is in
    -- milliseconds depends on the profile as much as on the tier: at tier 5, DART,
    -- STALKER and GHOST all put PERFECT inside the error budget on the raw numbers, and
    -- HEAVY does not.
    local v = Sonar.TargetSpeed(st)
    st.weakHalf = math.max(st.tier.weakHalf * (1 + st.greenZone), MIN_WEAK_MS * v)
    st.perfectHalf = math.max(st.tier.perfectHalf, MIN_PERFECT_MS * v)
    -- Keeps PERFECT strictly inside SAFE. Inert as long as MIN_WEAK_MS > 1.25 x
    -- MIN_PERFECT_MS, which it is by a wide margin -- if anyone narrows MIN_WEAK_MS toward
    -- MIN_PERFECT_MS this clamp starts firing and silently eats the PERFECT floor above.
    st.perfectHalf = math.min(st.perfectHalf, st.weakHalf * 0.8)

    -- A false echo, drawn but never strikeable. This is where GHOST's difficulty lives:
    -- the real fish is always visible (its opacity floor is in the NUI), because a strike
    -- graded against a fish the UI was not drawing is the thing ARCHITECTURE 12.11
    -- forbids. Reading which of two blips is real is fair; guessing blind is not.
    st.decoy = nil
    if st.canDecoy and p.name == 'GHOST' then
        st.decoy = { k = (rand(st) - 0.5) * 0.8, dir = rand(st) < 0.5 and 1 or -1 }
    end

    st.passStartAt = now + INTERVAL
    st.passEndAt = st.passStartAt + st.duration
    st.deadline = st.passEndAt + GRACE
end

M.actions = { strike = true }

function M.build(ctx)
    local tierIndex = ZUtil.clamp(math.floor(ctx.difficulty or 1), 1, 5)
    local tier = TIERS[tierIndex]
    local gear = ctx.gear or {}
    local behavior = (ctx.fish or {}).behavior or 'steady_light'

    local st = {
        rng = (ctx.seed or 1) % 2147483648,
        tier = tier,
        tierIndex = tierIndex,
        profileDef = PROFILES[behavior] or PROFILES.steady_light,
        duration = tier.duration,
        greenZone = gear.greenZone or 0.0,
        floatTier = FLOAT_TIER[gear.float] or 1,
        hits = 0, misses = 0, attempt = 0, phaseId = 0,
        lastGrade = nil,
    }
    st.profile = st.profileDef.name
    -- A decoy is a tier-4+ affordance, and only on the profile whose identity is that the
    -- picture lies. armPass checks the profile as well, so this alone does not enable it.
    st.canDecoy = tierIndex >= 4
    st.maxAttempts = tier.requiredHits + tier.maxMisses - 1
    armPass(st, ctx.now or 0)

    -- The longest possible fight is exactly maxAttempts passes: every attempt either
    -- banks a hit or spends a miss, and one of the two counters reaches its limit. There
    -- is no third outcome and no way to take a turn that does neither.
    local estimate = st.maxAttempts * (INTERVAL + tier.duration)

    return st, estimate
end

function M.render(enc, now)
    local st = enc.state
    return {
        phaseId = st.phaseId,
        attempt = st.attempt, maxAttempts = st.maxAttempts,
        hits = st.hits, requiredHits = st.tier.requiredHits,
        misses = st.misses, maxMisses = st.tier.maxMisses,
        passStartsIn = st.passStartAt - now,
        passEndsIn = st.passEndAt - now,
        duration = st.duration, hold = st.hold,
        profile = st.profile, dir = st.dir, k = st.k,
        weakHalf = st.weakHalf, perfectHalf = st.perfectHalf,
        target = TARGET,
        decoy = st.decoy,
        floatTier = st.floatTier,
        lastGrade = st.lastGrade,
    }
end

function M.act(enc, action, now, meta)
    local st = enc.state

    -- The server decides when the strike happened. `now` is arrival; the rewind is half a
    -- round trip, capped. Nothing the client sent contributes to this.
    local ping = (meta and meta.ping) or 0
    local strikeAt = now - ZUtil.clamp(ping * 0.5, 0, MAX_COMPENSATION)

    local grade
    if action == 'advance' then
        grade = 'miss'                          -- the pass ran out with no strike
    else
        local t = strikeAt - st.passStartAt
        if t < 0 or t > st.duration then
            grade = 'miss'                      -- struck outside the pass entirely
        else
            local d = math.abs(Sonar.WeakAt(st, t) - TARGET)
            if d <= st.perfectHalf then grade = 'perfect'
            elseif d <= st.weakHalf then grade = 'safe'
            else grade = 'miss' end
        end
    end

    st.lastGrade = grade
    local value
    if grade == 'miss' then
        st.misses = st.misses + 1
        value = 0
    else
        -- SAFE and PERFECT advance the fight by exactly the same amount. Letting PERFECT
        -- shorten it would make the required hit count vary with skill, which is the tier
        -- invariant every encounter here is built to preserve.
        st.hits = st.hits + 1
        value = grade == 'perfect' and 1.0 or 0.7
    end

    if st.hits >= st.tier.requiredHits then
        return { render = M.render(enc, now), outcome = 'success', value = value }
    end
    if st.misses >= st.tier.maxMisses then
        return { render = M.render(enc, now), outcome = 'escape', value = value }
    end

    armPass(st, now)
    return { render = M.render(enc, now), outcome = nil, value = value }
end

Encounter.Register('sonar_strike', M)
```

- [ ] **Step 4: Add the npm script**

In `tests/package.json`, add `"test:encounter-sonar": "node luarun.mjs tests/encounter_sonar.test.lua"`
after the mindgame entry, and add it to `test:all` in the same position.

- [ ] **Step 5: Run the tests to verify they pass**

```bash
node tests/luarun.mjs tests/encounter_sonar.test.lua
```

Expected: twenty-three `ok -` lines then `23 tests passed`.

If S3 or S11's off-centre offsets land in the wrong band, do not adjust the assertion —
the helper derives the offset from the rendered pass, so a disagreement means the module
and the test disagree about the timeline. Work out which is wrong first.

- [ ] **Step 6: Re-run every suite**

```bash
cd tests && npm run test:all
```

Expected: 13 suites, 270 tests, exit 0.

- [ ] **Step 7: Commit**

```bash
git add server/encounter_sonar.lua tests/encounter_sonar.test.lua tests/package.json
git commit -m "feat: add the sonar strike encounter module"
```

---

## Task 3: The parity fixture

**Files:**
- Create: `tests/gen_sonar_fixture.mjs`
- Create: `tests/sonar_fixture.lua` (generated, committed)
- Create: `web/src/engine/__fixtures__/sonarTimeline.json` (generated, committed)
- Modify: `tests/encounter_sonar.test.lua`
- Modify: `tests/package.json`

**What this fixture proves, and what it does not.** It is generated *from the Lua
implementation*. So it pins the TypeScript side to the Lua side and catches drift between
them — which is its whole job. It does **not** validate that `Sonar.WeakAt` is correct.
The behavioural tests in Task 2 do that. Write this down in the generator header, because
a green fixture test reads like a proof of correctness and is not one.

**Why two files instead of one JSON.** `tests/luarun.mjs` mounts only `.lua` files, from
`client/`, `server/`, `shared/` and `tests/`, non-recursively — a `.json` anywhere, or
anything under `tests/fixtures/`, is invisible to the Lua VM. And the harness's `json` is
a stub whose `encode` returns a wrapper table rather than a string, so Lua cannot parse
real JSON here either. One generator therefore emits the same samples twice: a Lua table
at `tests/sonar_fixture.lua`, and JSON where Vitest will look for it in D2.

- [ ] **Step 1: Write the generator**

Create `tests/gen_sonar_fixture.mjs`. Read `tests/luarun.mjs` first and reuse its wasmoon
setup verbatim — the mount list, the factory creation, the engine teardown. This script
differs only in what it does once the VM is up: instead of running a test file, it loads
`shared/util.lua` and `server/encounter_sonar.lua`, then samples `Sonar.WeakAt`.

Sample every combination that matters, so a TS bug in any branch is caught:

```
profiles : DART (k -0.40, hold 0.00), HEAVY (k 0.50, hold 0.00),
           STALKER (k -0.30, hold 0.35), GHOST (k 0.00, hold 0.00)
dirs     : +1, -1
durations: 4000, 3200, 2400        (tier 1, 3 and 5)
t        : 21 samples, 0 .. duration inclusive
```

That is 4 x 2 x 3 x 21 = 504 samples. Emit each as `{ duration, hold, k, dir, t, pos }`
with `pos` rounded to 6 decimal places — enough to catch a real formula difference, loose
enough that IEEE754 rounding between Lua and JS never fails the test.

`Encounter.Register` is called at the bottom of the module, so the generator must define a
stub `Encounter = { Register = function() end }` and a `ZUtil` with `clamp` before the
`dofile`, exactly as the harness does.

The Lua output must be a plain returnable table:

```lua
-- GENERATED by tests/gen_sonar_fixture.mjs -- do not edit by hand.
-- Regenerate with: node tests/gen_sonar_fixture.mjs
--
-- Sampled from server/encounter_sonar.lua's Sonar.WeakAt. This pins the TypeScript
-- implementation in web/src/engine/sonarTimeline.ts to the Lua one and detects drift
-- between them. It does NOT prove either is correct -- tests/encounter_sonar.test.lua
-- does that.
SONAR_FIXTURE = {
    { duration = 4000, hold = 0, k = -0.4, dir = 1, t = 0, pos = 0.0 },
    ...
}
```

- [ ] **Step 2: Add the script and generate**

In `tests/package.json`, add `"gen:sonar-fixture": "node gen_sonar_fixture.mjs"`.

```bash
cd tests && npm run gen:sonar-fixture
```

Expected: `tests/sonar_fixture.lua` and `web/src/engine/__fixtures__/sonarTimeline.json`
both written, 504 samples each.

- [ ] **Step 3: Assert the live implementation against the fixture**

Append to `tests/encounter_sonar.test.lua`, before `H.run()`:

```lua
-- --------------------------------------------------------------- parity fixture

test('S22 the live timeline still matches the committed fixture', function()
    dofile('tests/sonar_fixture.lua')
    truthy(SONAR_FIXTURE and #SONAR_FIXTURE > 0, 'the fixture must be generated and committed')

    local worst, worstAt = 0, nil
    for _, s in ipairs(SONAR_FIXTURE) do
        local got = Sonar.WeakAt({ duration = s.duration, hold = s.hold, k = s.k, dir = s.dir }, s.t)
        local delta = math.abs(got - s.pos)
        if delta > worst then worst, worstAt = delta, s end
    end
    truthy(worst < 1e-6, worstAt and
        ('drifted at duration=%d k=%s dir=%d t=%d: fixture %s, live %s')
            :format(worstAt.duration, tostring(worstAt.k), worstAt.dir, worstAt.t,
                    tostring(worstAt.pos),
                    tostring(Sonar.WeakAt(worstAt, worstAt.t)))
        or 'fixture drift')
end)

test('S23 the fixture covers every profile and both directions', function()
    dofile('tests/sonar_fixture.lua')
    local ks, dirs = {}, {}
    for _, s in ipairs(SONAR_FIXTURE) do ks[s.k] = true; dirs[s.dir] = true end
    local n = 0
    for _ in pairs(ks) do n = n + 1 end
    equal(n, 4, 'all four profile curves must be sampled, or a TS bug can hide in one')
    truthy(dirs[1] and dirs[-1], 'and both directions')
end)
```

- [ ] **Step 4: Run the suite**

```bash
node tests/luarun.mjs tests/encounter_sonar.test.lua
```

Expected: `25 tests passed`.

Then prove the drift detector actually detects drift, rather than trusting that it would:
temporarily change `4 * pass.k` to `4.1 * pass.k` in `Sonar.WeakAt`, re-run, confirm S22
fails and names a sample, and revert.

- [ ] **Step 5: Re-run every suite and commit**

```bash
cd tests && npm run test:all
```

Expected: 13 suites, 272 tests, exit 0.

```bash
git add tests/gen_sonar_fixture.mjs tests/sonar_fixture.lua tests/encounter_sonar.test.lua tests/package.json web/src/engine/__fixtures__/sonarTimeline.json
git commit -m "test: pin the sonar timeline with a cross-language fixture"
```

---

## Task 4: Wire and document

**Files:**
- Modify: `fxmanifest.lua`
- Modify: `tests/security.test.lua`
- Modify: `docs/ARCHITECTURE.md`, `docs/testing/zfishing-live-e2e-checklist.md`

- [ ] **Step 1: Load the module, in order**

In `fxmanifest.lua`, add `'server/encounter_sonar.lua',` to `server_scripts` immediately
after `'server/encounter_mindgame.lua',`.

Then add it to `loadAllServerModulesAtBoot` in `tests/security.test.lua`, after the
mindgame line — the guard added in Phase C exists precisely so a misordered manifest entry
fails a test instead of crashing at boot:

```lua
    dofile('server/encounter_sonar.lua')
```

- [ ] **Step 2: Warn that the fight has no picture yet**

D1 makes `Encounter.Playable('sonar_strike')` true, so an admin can force an encounter the
NUI cannot draw. Until D2 ships, say so where they would find out. In
`server/encounter_sonar.lua`, immediately before `Encounter.Register`:

```lua
-- D2 ships the NUI. Until then this encounter is reachable and unrendered, so an admin
-- forcing it gets a fight they cannot see. Remove this warning in the same commit that
-- adds web/src/encounters/SonarStrike.tsx.
print('[zfishing] sonar_strike is registered but has no NUI yet (Phase D1) -- '
    .. 'forcing it will produce an invisible fight')
```

- [ ] **Step 3: Verify everything**

```bash
cd tests && npm run test:all
```

Expected: 13 suites, 272 tests, exit 0.

```bash
cd web && npm test
```

Expected: the Lua hash snapshot fails, because Lua changed. Re-record and re-run:

```bash
cd web && npx vitest --run -u src/__tests__/bundleRebuildPreservation.test.ts && npm test
```

Expected then: 89 tests, all passing. No bundle rebuild is needed in D1 — no `web/src`
component changed, and the new JSON fixture is not imported by anything yet.

- [ ] **Step 4: Document**

Add `### 12.12 Sonar Strike (sonar_strike)` to `docs/ARCHITECTURE.md`, covering:

- The identity, and that D1 is server-only — the encounter is registered, playable and
  undrawn until D2.
- **Why the client never sends a moment**, with the concrete attack the earlier design
  allowed: a modified client that knows the timeline waits until `now = startAt + 2400`
  and submits `atMs = 1840` because 1840 is the perfect centre; the arrival check passes.
  Then the fix: arrival minus a bounded rewind, so delay is the only lever and delay only
  makes strikes worse.
- `MAX_COMPENSATION = 200` and why it is capped.
- **The two clocks in one call** (D.6 above), verbatim — the raw clock judges expiry, the
  compensated one judges the grade.
- `Sonar.WeakAt`, the easing family, and why `k ∈ (−0.5, 1)` is what makes the crossing
  unique.
- The profile table, and **one crossing per pass** with the three costs a second crossing
  would carry.
- **GHOST never hides the real fish** — opacity floor 0.35, difficulty carried by the
  decoy — and that this is §12.11's rule applied to a third encounter.
- The millisecond derivation of D.4: the error budget table, the before/after tier-5
  windows, and that the floor is per-pass because the shortfall depends on profile as much
  as tier. Include both tables.
- `requiredHits` is the tier; SAFE and PERFECT advance identically; PERFECT buys score.
- The deviation table of D.5, with reasons.
- That the fixture pins TS to Lua and does not validate the maths.

Add a change-history entry under `## 13` stating that this is the server half only, that
no fish is configured for sonar, and that nothing was run in FiveM.

Extend `docs/testing/zfishing-live-e2e-checklist.md` with a section N covering: FORCED
sonar at tiers 1 and 5; each of the four profiles observed and identified; a PERFECT and a
SAFE both advancing the count by one; running out of passes; a decoy at tier 5 on an
erratic fish; the GHOST fade never fully hiding the fish; a float upgrade changing the
picture but not the hit rate; and — the row that can falsify `MIN_PERFECT_MS` — **the
tier-5 PERFECT rate over 20 strikes at each of three ping bands (<60ms, ~120ms, >200ms),
recorded as three numbers**. Note at the top of the section that D1 has no NUI, so every
row needs D2 before it can be run. Leave every box unticked.

- [ ] **Step 5: Commit**

```bash
git add fxmanifest.lua tests/security.test.lua server/encounter_sonar.lua docs/ARCHITECTURE.md docs/testing/zfishing-live-e2e-checklist.md web/src/__tests__/__snapshots__/bundleRebuildPreservation.test.ts.snap
git commit -m "feat: register sonar strike and document the server half"
```

---

## Phase D1 completion checklist

```bash
cd tests && npm run test:all
cd web && npm test
```

Expected state at the end of D1:

- 13 suites, 272 Lua tests; 89 web tests; no type errors.
- `Encounter.Playable('sonar_strike')` is true, and forcing it prints a warning that there
  is no NUI.
- No fish resolves to any new encounter on its own — DEFAULT is still the legacy fight for
  everyone until Phase F.
- `tests/sonar_fixture.lua` and `web/src/engine/__fixtures__/sonarTimeline.json` are
  committed and agree with the live Lua implementation.
- Live behaviour is **unverified**: nothing in this phase has been run inside FiveM, and
  section N cannot be run at all until D2.

## What D2 will need from D1

Listed so the D2 plan can be written against real code rather than guesses:

- `Sonar.WeakAt(pass, t)` and the exact easing constants.
- The render payload field names from Task 2's Interfaces block.
- `web/src/engine/__fixtures__/sonarTimeline.json`'s shape.
- `floatTier` 1/2/3 and what each is allowed to change — silhouette clarity, and a
  weak-zone indicator band at tier 3 only.
- The GHOST opacity floor of 0.35, which is a NUI obligation D1 states and D2 implements.

## Known limitations to carry into the completion report

**Ping compensation is an estimate of a one-way trip.** Half of `GetPlayerPing` is a
reasonable estimate and a bounded one, but a route with a slow uplink and a fast downlink
is under-compensated and the player strikes late. The cap makes the error bounded rather
than absent, and the `MIN_PERFECT_MS` floor is sized to absorb it.

**No fish is configured for sonar, and none will be until Phase F.** The recommended
mapping in spec §7 (swordfish, and optionally shark and golden) is Phase F's work.

**The keycap gap from Phase B still applies** and will apply to sonar's single strike key
in D2. A device-aware `Keycap` remains a cross-encounter task.
