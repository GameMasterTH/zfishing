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

## Why Phase D is split, and what that split is *not*

§9.3 wants `posAt` implemented twice — once in Lua, once in `web/src/engine/sonarTimeline.ts` — with a committed fixture proving they agree. D1 ships the Lua side and the fixture. D2 ships the TypeScript side, `SonarStrike.tsx`, and the bridge key map.

The split is at the fixture because D2's real dependency is D1's *shipped* constants and fixture format, not this plan's description of them. Writing both now would mean guessing the interface between them, which is the failure Phases B and C avoided by writing each plan only after its predecessor's real code existed.

### D1 and D2 are one branch and one merge

**`encounter-sonar` is not merged to `main` until D2 is done.** This is a split in planning and review granularity, not in integration.

An earlier draft of this plan merged D1 on its own and printed a console warning that the encounter had no NUI. That is wrong, and the warning made it worse by dressing up an invalid state as a handled one. After D1, `Encounter.Playable('sonar_strike')` is true, so an admin setting `EncounterMode = forced, ForcedEncounter = sonar_strike` gets a real server-side fight with nothing drawn — an unwinnable, unreadable session on a live server. No log line fixes that.

The alternative — a `clientReady = false` flag in the registry — buys nothing but framework complexity to model a state that only exists between two commits on one branch. Branch discipline is cheaper and leaves no artifact behind.

```
main
 └── encounter-sonar
      ├── D1: contract + module + fixture + docs   (this plan)
      ├── D2: TS posAt + SonarStrike.tsx + bridge  (next plan)
      └── full suite green ──► merge to main
```

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

**`hold` carries a seeded jitter of ±6% of the pass duration**, on every profile including the three whose base `hold` is zero. Without it, the same symmetry that breaks the decoy makes every pass of every zero-hold profile cross the target at exactly `duration / 2` — 1200ms at tier 5 for DART, HEAVY and GHOST alike. Their identities would then rest entirely on how fast the fish looks near the target and how wide the band is, never on *when* the opportunity arrives, and a player could learn one clock and reuse it across three profiles.

Jitter is applied to `hold` rather than added as a separate `crossBias` field because `hold` already shifts the crossing, is already rendered, and already feeds `vTarget` — so the millisecond floor below absorbs it with no extra work. STALKER keeps its much larger base `hold`, so it stays the profile that visibly waits. is implemented as an **opacity oscillation with a floor of 0.35 — the real fish is never invisible.** Hiding a strikeable target is the exact thing §12.11 forbids: a strike scored against a fish the UI was not drawing.

GHOST's difficulty comes from a **decoy** instead, at tier ≥ 4: a second blip carrying no weak band. Striking while only the decoy is over the target is a MISS. The real fish is always on screen, so the player is never guessing blind — they are reading which of two things is real.

**The decoy needs its own crossing time, and this is not optional.** Every curve in the easing family crosses the target at `u = 0.5` — at `c = 0` both the `(1−k)c` and `4kc³` terms vanish, so `f = 0.5` for every `k`, and `1 − f = 0.5` too, so for every `dir` as well:

```
k = -0.40  dir = +1  ->  weakAt(0.5) = 0.500000000000
k = +0.50  dir = -1  ->  weakAt(0.5) = 0.500000000000
k = +0.30  dir = +1  ->  weakAt(0.5) = 0.500000000000        ... and so on, for all k
```

A decoy given only its own `k` and `dir`, sharing the pass's `startAt`, `hold` and `duration`, therefore crosses the target **at the same millisecond as the real fish, always**. `k` changes how it travels, never when it arrives. Under that design the decoy is decoration: there is no moment where striking it is wrong and striking the fish is right, so it cannot create a false opportunity at all.

The decoy carries its own timeline instead:

```lua
decoy = { k, dir, hold = 0, duration = 2 * crossAt, crossAt }
```

`crossAt` is chosen per pass, at least `MIN_DECOY_SEPARATION = 550` ms from the real crossing, on whichever side the seed picks. Setting `hold = 0, duration = 2 * crossAt` makes the decoy's own midpoint land exactly on `crossAt`, which is what puts it over the target then. An early decoy finishes its run and leaves the lane — which is the "fades and returns" the spec asked for, delivered as motion rather than as opacity.

550ms clears the widest SAFE window in the game (±384ms, tier-5 HEAVY) with room left for a player to see the two events as separate. Both sides always have room at the tiers where decoys exist:

| tier | duration | real crossing | early window | late window |
|---|---|---|---|---|
| 4 | 2800 | ~1400 | 200–850 | 1950–2600 |
| 5 | 2400 | ~1200 | 200–650 | 1750–2200 |

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

**`halfWidth / vTarget` is a linear approximation, and the test must not use it.** `vTarget` is the slope *at* the crossing; the curve is a cubic, so the true time to travel from the target out to the band edge differs. For `k > 0` the fish accelerates away from the centre, so the linear figure **overstates** the real window:

| profile | SAFE linear | SAFE actual | PERFECT linear | PERFECT actual |
|---|---|---|---|---|
| `DART` | 240ms | 242.8ms | 90ms | 90.1ms |
| `HEAVY` | 384ms | **353.4ms** | 144ms | 142.0ms |
| `STALKER` | 240ms | 245.6ms | 90ms | 90.3ms |
| `GHOST` | 240ms | 240.0ms | 90ms | 90.0ms |

Every actual window still clears its floor, so the current balance holds. But an assertion written as `weakHalf / vTarget >= 240` proves nothing about the real window — it would stay green while a future change to `k`, a width, or a tier pushed the true window under the floor, and HEAVY already shows a 31ms gap between the two figures.

So the **generator keeps the linear form** — it is a cheap, closed-form input to a balance knob — and the **test measures the curve**, binary-searching for the `t` at which `|weakAt(t) − TARGET|` equals each half-width and asserting the distance from the crossing. That is what makes "every profile keeps PERFECT at or above the floor" a proven claim rather than a restated assumption.

### D.4a Compensation is frozen when the pass is armed

The compensation is fixed **once, when the pass is armed**, and stored on the pass:

```lua
st.compensationMs = ZUtil.clamp(ping * 0.5, 0, MAX_COMPENSATION)   -- at armPass
...
strikeAt = now - st.compensationMs                                  -- at strike
```

Reading the ping at strike time instead would leave a bounded but real lever: a player shaping their connection — a lag switch, a saturated uplink — raises the server-observed ping, and the server then rewinds their strike by up to 200ms. They cannot pick the value, but they can push it, and they can push it *at the moment it pays*.

Freezing removes the timing of that incentive. To move the compensation a player must degrade their connection *before* the pass is armed and hold it there — which also degrades the picture they are trying to read and the input they are trying to land. The lever stops pointing the useful way.

A pass is armed in two places — once in `build`, once per resolved strike in `act` — so the ping has to reach both. `meta.ping` covers `act`; Task 1 adds `ctx.ping` to `build` for the first pass. The module never calls `GetPlayerPing` itself, which keeps it free of FiveM natives and testable without stubbing one.

**State the threat model accurately.** An earlier draft of this plan claimed a modified client "can only ever arrive later, which makes strikes worse". That is too strong. The correct claim is narrower and still worth having:

> A client cannot **choose** its compensation, cannot submit a moment, and cannot select a favourable instant in the past. It can influence the measured ping that feeds the compensation, which is why the value is capped, and why it is sampled before the pass rather than during it.

### D.4b A strike before the pass is not a miss

`INTERVAL = 700` ms sits between passes, and this plan's own description of it is "the fish leaves the lane and is reacquired. Nothing is strikeable here." Scoring a press during that window as a MISS contradicts the constraint at the top of this plan — it scores a strike against something the UI is not showing — in exactly the way Phase C's telegraph did before §12.11 fixed it.

A strike arriving before `passStartAt` is therefore a **no-op**: no hit, no miss, no attempt consumed, and no score recorded. It is not an error either — the dispatcher has already taken the `seq`, and that is fine, because taking a sequence number costs the player nothing.

The mechanism is that `mod.act` returns **no `value`** for that case. `evaluate` in `server/encounter.lua` already guards its accumulator with `if res.value ~= nil`, so a premature strike does not dilute `perfScore` either. The render carries `notReady = true` for that one response so D2 can say "not yet" rather than flash a miss.

This also closes the stale-strike race for free: a strike meant for pass 1 that arrives after pass 2 is armed lands before pass 2's `passStartAt` and is ignored, rather than being graded against a timeline the player never saw.

### D.4c On binding actions to a phase

A reviewer of this plan proposed sending `phaseId` with every action and checking `phaseId == enc.state.phaseId` alongside `seq`, on the grounds that `seq` answers "which action is this?" while `phaseId` answers "which state was this meant for?" — different invariants, and that is correct in general.

The specific race raised was: a strike is accepted, the next pass arms, and the previous pass's NUI timer then fires an `advance` whose `seq` happens to be valid. **That one is already closed**, by the dispatcher's existing guard:

```lua
if action == 'advance' then
    if type(enc.state.deadline) ~= 'number' or now < enc.state.deadline then
        return { ok = false, reason = 'bad_action', seq = enc.seq }
    end
```

A freshly armed pass has a deadline far in the future, so a stale `advance` is rejected. And the stale-*strike* half is closed by D.4b above. Between them, no stale action can score against a phase it was not aimed at.

`phaseId` binding is still the more explicit statement of the invariant — today it is emergent from two separate guards rather than checked once. But it changes the wire signature of `zfishing:encounter:act`, the client bridge, and every encounter test, for hardening with no currently reachable hole behind it. **It is recorded as a cross-encounter task, not folded into D1**, alongside the device-aware keycap from Phase B.

### D.5 Deliberate deviations from §6

| §6 says | this plan does | why |
|---|---|---|
| strike payload carries `passIndex`, rejected as `stale_pass` | omitted; see D.4c | `seq` plus the `advance` deadline guard plus D.4b's not-ready rule leave no reachable stale-action hole. A `phaseId` binding is the cleaner statement of the invariant and is recorded as a cross-encounter task, because it changes the wire signature of all three encounters. |
| `line <= 0 -> snap`, and `lineRating` matters everywhere | sonar uses a subset of the outcome vocabulary, and `lineRating` has no role in it | See the row below. The shared vocabulary is `success / escape / snap / timeout`; a module may use a subset. Not every encounter has to consume every piece of gear — sonar reads the float instead. |
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
- Produces: `mod.act(enc, action, now, meta)` where `meta = { ping = <number> }`; `ctx.ping` in `mod.build`, the same measurement for the first pass; `ctx.gear.float`, a float item id string or `nil`.

A pass is armed in `build` once and in `act` thereafter, and each arming fixes its own latency compensation (D.4a), so the ping has to reach both entry points. Neither value is client-supplied and neither module that exists today reads either.

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
        seen.gear, seen.ctxPing = ctx.gear, ctx.ping
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

test('C14 the first pass gets a ping measurement too, through ctx', function()
    -- A pass fixes its own latency compensation when it is armed, and build arms the
    -- first one. Without this the opening pass of every sonar fight would compensate
    -- nothing while every later pass compensated correctly.
    local seen = {}
    _G.__PING = 84
    startEncounter(5, watch(fakeModule(), seen))
    equal(seen.ctxPing, 84)
end)

test('C15 the fitted float reaches a module through ctx.gear', function()
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

Expected: C12 fails (`seen.meta` is nil), C14 fails (`seen.ctxPing` is nil) and C15 fails (`seen.gear.float` is nil). C13 passes already — that is the point of it.

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

`Encounter.Begin` arms the first pass, so it needs the same measurement. Append `src` to
its signature — nothing else calls it — and put the ping in the build context:

```lua
function Encounter.Begin(s, gear, src)
```

```lua
    local state, estimate = mod.build({
        difficulty = s.encounter.difficulty,
        seed       = math.random(1, 2147483647),
        fish       = s.fish,
        gear       = gear or {},
        now        = now,
        -- The first pass fixes its latency compensation here, exactly as every later one
        -- does from meta.ping. See ARCHITECTURE 12.12.
        ping       = src and GetPlayerPing(src) or 0,
    })
```

and pass it at the one call site, in `server/session.lua`'s `zfishing:hook` handler:

```lua
        challengeId, opening = Encounter.Begin(s, {
            lineRating = s.lineRating,
            reelDrain  = s.reelDrain or 1.0,
            greenZone  = (Config.Equipment.rods[s.rod] or {}).greenZone or 0.0,
            float      = s.float,
        }, src)
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

In `server/session.lua`, the cast handler stores selected stats onto the session record near line 215. Add the float beside `reelDrain`:

```lua
        float = stats and stats.float or nil,
```

The gear table that carries it into `Encounter.Begin` was already updated in Step 3.

Note what is deliberately *not* done here: `src` is not stored on the session record. The comment at the top of that record explains why `identifier` exists — a src can belong to somebody else by the time a stored one is read. The ping is sampled at the two moments a src is known to be live and passed in, rather than kept.

- [ ] **Step 5: Run the suite**

```bash
node tests/luarun.mjs tests/encounter_action.test.lua
```

Expected: all pass, four more than before.

- [ ] **Step 6: Re-run every suite**

```bash
cd tests && npm run test:all
```

Expected: 12 suites, 248 tests, exit 0. `counter_pull` and `fish_mindgame` must be untouched and green — if either moved, the change was not additive.

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
  `{ phaseId, attempt, maxAttempts, hits, requiredHits, misses, maxMisses, passStartsIn, passEndsIn, duration, hold, profile, dir, k, weakHalf, perfectHalf, target, decoy?, floatTier, lastGrade?, notReady? }`,
  where `decoy = { k, dir, hold, duration, crossAt }` and `notReady` appears only on the
  response to a strike the pass had not opened for yet (D.4b).

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
        -- Set before the hook, because a pass fixes its compensation when it is armed.
        _G.__PING = opts.ping or 0
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

-- Acts `offset` ms after the render was taken. `ping` here is the ping AT STRIKE TIME,
-- which must not change the grade -- the compensation was fixed when the pass was armed.
local function act(g, action, offset, ping)
    if ping ~= nil then _G.__PING = ping end
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

-- Settles the catch and returns the score the fight earned. The act callback returns
-- { ok, seq, state, outcome } and no score of its own, so the grade values (PERFECT 1.0,
-- SAFE 0.7, MISS 0) are only observable here -- which is also the only place they matter.
local function scoreOf(g)
    local claim = H.CB['zfishing:claim'](5, g.sid, 0, true)
    truthy(claim.ok, tostring(claim.reason))
    equal(g.calls.give, 1, 'the catch was committed once')
    return g.calls.ctx.perfScore
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
    local sharp = start({ difficulty = 5, seed = 7, ping = 0 })
    local sharpRes = act(sharp, 'strike', perfectOffset(sharp))

    local laggy = start({ difficulty = 5, seed = 7, ping = 180 })
    local laggyRes = act(laggy, 'strike', perfectOffset(laggy) + 90)   -- 180/2 = 90ms back

    equal(sharpRes.state.lastGrade, 'perfect')
    equal(laggyRes.state.lastGrade, 'perfect',
        'a 180ms player striking at the same real moment must be graded the same')
end)

test('S8 compensation is bounded, so a huge ping cannot buy a better grade', function()
    -- 2000ms of ping would be 1000ms of rewind if it were unbounded; the cap is 200.
    local g = start({ difficulty = 5, seed = 7, ping = 2000 })
    local res = act(g, 'strike', perfectOffset(g) + 900)
    equal(res.state.lastGrade, 'miss',
        'MAX_COMPENSATION must cap the rewind, or ping becomes a cheat surface')
end)

test('S8b compensation is fixed when the pass arms, not read when the strike lands', function()
    -- The lever this closes: a player who shapes their connection could otherwise spike
    -- the measured ping at the instant it pays and be handed up to 200ms of rewind.
    local honest = start({ difficulty = 5, seed = 8, ping = 20 })
    local honestRes = act(honest, 'strike', perfectOffset(honest) + 170)

    local spiker = start({ difficulty = 5, seed = 8, ping = 20 })
    local spikerRes = act(spiker, 'strike', perfectOffset(spiker) + 170, 400)  -- spikes on send

    equal(honestRes.state.lastGrade, spikerRes.state.lastGrade,
        'a ping spike at strike time must change nothing at all')
end)

test('S9 a strike is never graded against a client-supplied moment', function()
    -- The action is a bare string. There is no argument the client could put a time in.
    local g = start({ difficulty = 5 })
    local res = act(g, 'strike', perfectOffset(g) + 100000)
    equal(res.state.lastGrade, 'miss', 'and it is graded on arrival, not on intent')
    equal(res.state.clientAtMs, nil, 'no client time is echoed back either')
end)

test('S9b a strike before the fish is on the lane costs nothing at all', function()
    -- INTERVAL is the reacquire gap. Nothing is drawn there, so nothing may be scored
    -- there -- the same rule ARCHITECTURE 12.11 states for the mindgame telegraph.
    local g = start({ difficulty = 5 })
    local before = g.last.attempt
    local res = act(g, 'strike', 10)                 -- well inside the gap
    truthy(res.ok)
    equal(res.state.notReady, true, 'the NUI is told to say "not yet"')
    equal(res.state.hits, 0)
    equal(res.state.misses, 0, 'above all: not a miss')
    equal(res.state.attempt, before, 'and the attempt is not consumed')

    -- The pass is still live and can still be won.
    equal(act(g, 'strike', perfectOffset(g)).state.lastGrade, 'perfect')
end)

test('S9c a premature strike does not dilute the score either', function()
    local g = start({ difficulty = 1 })
    act(g, 'strike', 10)                             -- not ready, returns no value
    local res
    repeat res = act(g, 'strike', perfectOffset(g)) until res.outcome
    equal(res.outcome, 'success')
    equal(scoreOf(g), 1.0, 'a press the game refused is not an action the player took')
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

-- The TRUE half-window, in ms: how long the weak centre actually takes to travel from the
-- target out to `half`, found on the curve rather than from its slope at the crossing.
-- The linear figure halfWidth/vTarget overstates this for k > 0 -- at tier-5 HEAVY by
-- 31ms -- so asserting on it would let a future tuning change slip a real window under
-- the floor while the test stayed green.
local function trueWindowMs(pass, half)
    local travel = pass.duration - pass.hold
    local lo, hi = 0.5, 1.0
    for _ = 1, 60 do
        local mid = (lo + hi) * 0.5
        local c = mid - 0.5
        local f = 0.5 + (1 - pass.k) * c + 4 * pass.k * c * c * c
        if f - 0.5 < half then lo = mid else hi = mid end
    end
    return (lo - 0.5) * travel
end

test('S14 every profile keeps both windows above the millisecond floor, at every tier', function()
    -- The whole point of the per-pass floor: at tier 5 three of four profiles would
    -- otherwise put PERFECT inside the lag error budget -- STALKER at about 36ms.
    for tier = 1, 5 do
        for _, behavior in ipairs({ 'steady_light', 'steady_heavy', 'run_stop', 'erratic' }) do
            local g = start({ difficulty = tier, behavior = behavior })
            local s = g.last
            local pass = { duration = s.duration, hold = s.hold, k = s.k, dir = s.dir }
            local perfectMs = trueWindowMs(pass, s.perfectHalf)
            local weakMs = trueWindowMs(pass, s.weakHalf)
            truthy(perfectMs >= 89.5,
                ('tier %d %s: PERFECT is only %.1fms'):format(tier, behavior, perfectMs))
            truthy(weakMs >= 239.5,
                ('tier %d %s: SAFE is only %.1fms'):format(tier, behavior, weakMs))
            truthy(s.perfectHalf < s.weakHalf)
        end
    end
end)

test('S14b the true window and the linear estimate genuinely differ', function()
    -- Guards the guard: if trueWindowMs ever collapses to the linear form, S14 quietly
    -- stops testing anything the old assertion did not. HEAVY is where they diverge most.
    local g = start({ difficulty = 5, behavior = 'steady_heavy' })
    local s = g.last
    local pass = { duration = s.duration, hold = s.hold, k = s.k, dir = s.dir }
    local linear = s.weakHalf / ((1 - s.k) / (s.duration - s.hold))
    truthy(linear - trueWindowMs(pass, s.weakHalf) > 15,
        'the linear estimate must still be measurably optimistic for k > 0')
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

test('S16 the stalker waits, and waits far longer than jitter alone explains', function()
    for seed = 1, 20 do
        local stalker = start({ difficulty = 5, behavior = 'run_stop', seed = seed }).last
        local dart = start({ difficulty = 5, behavior = 'steady_light', seed = seed }).last
        truthy(stalker.hold > dart.hold + 300,
            ('seed %d: stalker held %dms, dart %dms'):format(seed, stalker.hold, dart.hold))
        truthy(dart.hold <= 0.06 * dart.duration + 1,
            ('a zero-hold profile drifted %dms, past the jitter bound'):format(dart.hold))
    end
end)

test('S16b passes do not all present the opportunity on the same clock', function()
    -- Without the hold jitter every zero-hold profile crosses at exactly duration/2, so
    -- DART, HEAVY and GHOST would share one timing and a player could learn it once.
    local seen = {}
    for seed = 1, 25 do
        local s = start({ difficulty = 5, behavior = 'steady_light', seed = seed }).last
        seen[s.hold + (s.duration - s.hold) * 0.5] = true
    end
    local n = 0
    for _ in pairs(seen) do n = n + 1 end
    truthy(n > 5, ('25 passes produced only %d distinct crossing times'):format(n))
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

test('S18b a decoy crosses the target well away from the real fish, every time', function()
    -- Without this the decoy is decoration. Every curve in the family crosses at the
    -- midpoint of its own travel, so a decoy that shared the pass's timing would be over
    -- the target at the SAME millisecond as the fish no matter what k and dir it got --
    -- there would be no moment at which striking it was the wrong choice.
    local worst = math.huge
    for tier = 4, 5 do
        for seed = 1, 30 do
            local g = start({ difficulty = tier, behavior = 'erratic', seed = seed })
            local s = g.last
            truthy(s.decoy, 'tier 4+ erratic must always carry one')
            local realCross = s.hold + (s.duration - s.hold) * 0.5
            local gap = math.abs(s.decoy.crossAt - realCross)
            if gap < worst then worst = gap end
            truthy(s.decoy.crossAt > 0 and s.decoy.crossAt < s.duration,
                ('tier %d seed %d: the decoy must cross while the pass is running, at %d')
                    :format(tier, seed, s.decoy.crossAt))
        end
    end
    truthy(worst >= 550,
        ('the closest decoy came within %dms of the real crossing'):format(worst))
end)

test('S18c the decoy carries its own timeline, not the pass timing', function()
    local s = start({ difficulty = 5, behavior = 'erratic', seed = 3 }).last
    equal(s.decoy.hold, 0)
    equal(s.decoy.duration, 2 * s.decoy.crossAt,
        'hold 0 with duration 2*crossAt is what puts its midpoint on crossAt')
    -- And the maths agrees: WeakAt over the decoy's own record is on the target then.
    local mid = Sonar.WeakAt({ duration = s.decoy.duration, hold = 0,
                               k = s.decoy.k, dir = s.decoy.dir }, s.decoy.crossAt)
    truthy(math.abs(mid - 0.5) < 1e-9, 'the decoy must actually be over the target at crossAt')
end)

test('S19 the float tier reaches the render and changes nothing on the server', function()
    local plain = start({ difficulty = 5, rig = true, stats = { float = 'float_wood' } })
    local smart = start({ difficulty = 5, rig = true, stats = { float = 'float_smart' } })
    truthy(smart.last.floatTier > plain.last.floatTier, 'the NUI needs to know')
    equal(plain.last.weakHalf, smart.last.weakHalf, 'but the target is exactly as hard')
    equal(plain.last.perfectHalf, smart.last.perfectHalf)
end)

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
-- How far a decoy's crossing must sit from the real one. Every curve in the easing family
-- below crosses the target at the midpoint of its own travel, so a decoy sharing the
-- pass's timing crosses at the SAME millisecond as the fish no matter what k and dir it
-- is given -- decoration, not a false opportunity. This is the separation that makes it
-- one. 550ms clears the widest SAFE window in the game (tier-5 HEAVY, +/-384ms).
local MIN_DECOY_SEPARATION = 550
-- Seeded wobble on `hold`, as a fraction of duration. Without it every zero-hold profile
-- crosses at exactly duration/2, so DART, HEAVY and GHOST would all present their
-- opportunity on the same clock and a player could learn one and reuse it for three.
local HOLD_JITTER = 0.06

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

local function armPass(st, now, ping)
    st.phaseId = st.phaseId + 1
    st.attempt = st.attempt + 1

    local p = st.profileDef
    st.dir = rand(st) < 0.5 and 1 or -1
    st.k = p.k
    -- Jittered so the crossing is not the same clock every pass. See HOLD_JITTER.
    local holdFrac = p.hold + (rand(st) - 0.5) * 2 * HOLD_JITTER
    st.hold = math.floor(st.duration * ZUtil.clamp(holdFrac, 0, 0.5))

    -- Frozen here, not read at strike time. A player who shapes their connection can push
    -- the measured ping, and reading it on arrival would let them push it at exactly the
    -- moment it pays. Sampling it before the pass means they have to hold the degradation
    -- through the part of the fight they are trying to read, which costs them more than it
    -- buys. They still cannot choose the value, and it is still capped.
    st.compensationMs = ZUtil.clamp((ping or 0) * 0.5, 0, MAX_COMPENSATION)

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
        -- Its own crossing time is the whole point -- k and dir alone would put it over
        -- the target at the same instant as the fish. hold = 0 with duration = 2*crossAt
        -- puts the decoy's own midpoint, and therefore the decoy, on the target at
        -- crossAt. An early one finishes and leaves the lane, which is the "fades and
        -- returns" the spec asked for, delivered as motion rather than as opacity.
        local realCross = st.hold + (st.duration - st.hold) * 0.5
        local lo, hi = 200, st.duration - 200
        local early, late = realCross - MIN_DECOY_SEPARATION, realCross + MIN_DECOY_SEPARATION
        local crossAt
        if early > lo and (late > hi or rand(st) < 0.5) then
            crossAt = lo + rand(st) * (early - lo)
        else
            crossAt = late + rand(st) * math.max(0, hi - late)
        end
        crossAt = math.floor(crossAt)
        st.decoy = {
            k = (rand(st) - 0.5) * 0.8,
            dir = rand(st) < 0.5 and 1 or -1,
            hold = 0,
            duration = 2 * crossAt,
            crossAt = crossAt,
        }
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
    armPass(st, ctx.now or 0, ctx.ping)

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

    -- The server decides when the strike happened. `now` is arrival; the rewind was fixed
    -- when this pass was armed. Nothing the client sent contributes to either.
    local strikeAt = now - (st.compensationMs or 0)

    local grade
    if action == 'advance' then
        grade = 'miss'                          -- the pass ran out with no strike
    else
        local t = strikeAt - st.passStartAt
        if t < 0 then
            -- The fish is not on the lane yet: this is the reacquire gap between passes.
            -- Scoring it would be scoring a strike against something the UI is not
            -- showing, which is the rule ARCHITECTURE 12.11 exists to state. So it costs
            -- nothing -- no hit, no miss, no attempt -- and returns no `value`, which is
            -- what keeps it out of perfScore as well.
            --
            -- This is also what makes a stale strike harmless: one aimed at the previous
            -- pass arrives before this pass opens and is ignored rather than graded
            -- against a timeline the player never saw.
            local frame = M.render(enc, now)
            frame.notReady = true
            return { render = frame }
        elseif t > st.duration then
            grade = 'miss'                      -- struck after the fish had gone
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

    armPass(st, now, meta and meta.ping)
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

Expected: thirty `ok -` lines then `30 tests passed`.

If S3 or S11's off-centre offsets land in the wrong band, do not adjust the assertion —
the helper derives the offset from the rendered pass, so a disagreement means the module
and the test disagree about the timeline. Work out which is wrong first.

- [ ] **Step 6: Re-run every suite**

```bash
cd tests && npm run test:all
```

Expected: 13 suites, 278 tests, exit 0.

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

Expected: `32 tests passed`.

Then prove the drift detector actually detects drift, rather than trusting that it would:
temporarily change `4 * pass.k` to `4.1 * pass.k` in `Sonar.WeakAt`, re-run, confirm S22
fails and names a sample, and revert.

- [ ] **Step 5: Re-run every suite and commit**

```bash
cd tests && npm run test:all
```

Expected: 13 suites, 280 tests, exit 0.

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

- [ ] **Step 2: Do not merge — confirm the branch stays open**

D1 makes `Encounter.Playable('sonar_strike')` true, so from this commit an admin setting
`EncounterMode = forced, ForcedEncounter = sonar_strike` gets a real server-side fight with
nothing drawn. That state must never exist on `main`.

There is no code for this step. It exists because the natural next action after a green
suite is to run `finishing-a-development-branch`, and here that is wrong:

```bash
git branch --show-current      # must be encounter-sonar
git log --oneline main..HEAD   # D1's commits, still unmerged
```

Leave the branch as-is and write the D2 plan against it. `encounter-sonar` merges to `main`
once, after D2, with the NUI in the same merge. An earlier draft of this plan merged D1
alone and printed a console warning instead; a log line does not make an unplayable
encounter playable, and the warning would have been a permanent artifact of a state that
lasted two commits.

- [ ] **Step 3: Verify everything**

```bash
cd tests && npm run test:all
```

Expected: 13 suites, 280 tests, exit 0.

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
- `MAX_COMPENSATION = 200` and why it is capped, **and that the compensation is fixed when
  the pass arms rather than read when the strike lands** (D.4a) — with the accurate threat
  model: a client cannot choose its compensation, but it can influence the measured ping,
  which is why the value is both capped and sampled early.
- **The two clocks in one call** (D.6 above), verbatim — the raw clock judges expiry, the
  compensated one judges the grade.
- **A strike before the pass opens is a no-op, not a miss** (D.4b), and that it returns no
  `value` so it cannot dilute `perfScore` either. Name the rule it serves: nothing is
  scored against something the UI is not showing.
- **The `hold` jitter** (D.3) and what it prevents: without it every zero-hold profile
  crosses at exactly `duration / 2`, so three profiles would share one clock.
- `Sonar.WeakAt`, the easing family, and why `k ∈ (−0.5, 1)` is what makes the crossing
  unique.
- The profile table, and **one crossing per pass** with the three costs a second crossing
  would carry.
- **GHOST never hides the real fish** — opacity floor 0.35, difficulty carried by the
  decoy — and that this is §12.11's rule applied to a third encounter.
- **Why the decoy needs its own crossing time**, with the reason stated as a property of
  the easing family rather than as a preference: every curve crosses at `u = 0.5`, so a
  decoy sharing the pass's timing is over the target at the same millisecond as the fish
  for every `k` and every `dir`. Give `MIN_DECOY_SEPARATION = 550` and where 550 comes
  from.
- The millisecond derivation of D.4: the error budget table, the before/after tier-5
  windows, and that the floor is per-pass because the shortfall depends on profile as much
  as tier. Include both tables, **and the linear-versus-actual table** with the note that
  the generator uses the linear form and the test measures the curve.
- `requiredHits` is the tier; SAFE and PERFECT advance identically; PERFECT buys score.
- The deviation table of D.5, with reasons.
- **A module may use a subset of the shared outcome vocabulary.** The vocabulary is
  `success / escape / snap / timeout`; sonar never emits `snap`, because a line pool it
  cannot manage is a failure axis the player has no lever on. Say so in §12 generally, not
  only in §12.12 — it is a framework property, not a sonar quirk.
- **`lineRating` has no effect in sonar**, and that this is fine: encounters read the gear
  their fight is about. Sonar reads the float.
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
git add fxmanifest.lua tests/security.test.lua docs/ARCHITECTURE.md docs/testing/zfishing-live-e2e-checklist.md web/src/__tests__/__snapshots__/bundleRebuildPreservation.test.ts.snap
git commit -m "feat: register sonar strike and document the server half"
```

Do **not** run `finishing-a-development-branch` here. D1 ends on an open branch by design.

---

## Phase D1 completion checklist

```bash
cd tests && npm run test:all
cd web && npm test
```

Expected state at the end of D1:

- 13 suites, 280 Lua tests; 89 web tests; no type errors.
- **`encounter-sonar` is not merged.** `Encounter.Playable('sonar_strike')` is true from
  D1's first commit, so this branch stays open until D2 puts a picture behind it.
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
- The decoy record — `{ k, dir, hold, duration, crossAt }` — which D2 draws with the same
  `posAt` it draws the fish with, on the decoy's own timeline rather than the pass's.
- `notReady`, which D2 must render as "not yet" and never as a miss, and which is the
  reason D2 also has to dim the strike affordance for the whole `INTERVAL` gap.

## Known limitations to carry into the completion report

**Ping compensation is an estimate of a one-way trip.** Half of `GetPlayerPing` is a
reasonable estimate and a bounded one, but a route with a slow uplink and a fast downlink
is under-compensated and the player strikes late. The cap makes the error bounded rather
than absent, and the `MIN_PERFECT_MS` floor is sized to absorb it.

**No fish is configured for sonar, and none will be until Phase F.** The recommended
mapping in spec §7 (swordfish, and optionally shark and golden) is Phase F's work.

**The keycap gap from Phase B still applies** and will apply to sonar's single strike key
in D2. A device-aware `Keycap` remains a cross-encounter task.

**Actions are bound to a phase by two guards rather than one check.** `advance` is bound by
the dispatcher's deadline test and a strike by D.4b's not-ready rule (see D.4c). No stale
action can score against a phase it was not aimed at today, but the invariant is emergent
rather than stated. Sending `phaseId` with every action and checking it alongside `seq`
would make it explicit; it changes the wire signature of all three encounters, so it is a
cross-encounter task next to the keycap one.

**`lineRating` does nothing in a sonar fight.** A player who upgrades their line sees no
change here. That is deliberate — sonar's gear lever is the float — but it is worth saying
out loud, because "better line is always better" is a reasonable thing for a player to
assume and it is not true in this encounter.
