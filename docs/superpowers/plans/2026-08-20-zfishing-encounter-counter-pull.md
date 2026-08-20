# Counter-Pull Fight (Phase B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `counter_pull` — the first real encounter — end to end: a server-owned state machine, a client bridge that orchestrates the fight, a NUI panel that presents it, and the tests that hold all three honest.

**Architecture:** `server/encounter_counter_pull.lua` implements the module contract Phase A defined and registers itself. The server owns the fish's direction, the counter window, stamina, line health and the phase clock, and it is the only place absolute time exists — every render payload leaves the server as **relative durations**. `client/encounter.lua` orchestrates: it routes the bite, polls input, serializes one action at a time, and drives settlement. The NUI presents and nothing else.

**Tech Stack:** Lua 5.4 (FiveM `cerulean`), ox_lib callbacks, wasmoon test harness, React 18 + Vitest.

**Spec:** `docs/superpowers/specs/2026-08-20-zfishing-encounter-system-design.md`, plus `docs/ARCHITECTURE.md` §12.

**Prerequisite — verify before starting:** Phase A must be present on the working tree.

```bash
grep -c "Encounter.Register" server/encounter.lua && grep -c "Encounters.FALLBACK" server/session.lua
```

Both must be non-zero. Phase A merged to `main` at `245fabd`; this plan's branch is `encounter-counter-pull`, cut from that merge, where 198 Lua tests and 71 web tests pass. **Do not implement Phase B on a tree without the Phase A encounter contract.**

## Global Constraints

- **The module contract is fixed by Phase A.** Task 1 makes additive refinements to it and nothing else. Do not redesign it.
- **Absolute time never leaves the server.** `M.render` emits durations relative to the server's own `now`. Internal state (`windowOpensAt`, `deadline`, …) stays absolute — that is what the server compares an incoming action against. Server `GetGameTimer()` and client `GetGameTimer()` are unrelated clock domains; subtracting one from the other, in either direction and on either side, produces a number that means nothing.
- **Every authoritative transition carries a `phaseId`.** Phase name plus timings can repeat exactly; an id cannot. React re-anchors on it.
- **The server owns every fight decision.** No action payload carries a timing value the server trusts, and no render payload contains `required`.
- **Responsibility boundary:** server = gameplay authority; client = orchestration, including settlement; NUI = presentation.
- **Lua files stay flat** in `client/`, `server/`, `shared/`, `tests/` — `tests/luarun.mjs` mounts those non-recursively.
- **`legacy_tension` stays untouched.** `client/minigame.lua` keeps its existing bite/reel path; the bridge runs only when the bite payload names a non-legacy encounter.
- **No per-frame traffic.** No Lua→NUI message per frame, no client→server event per frame, no React state update per frame.
- **Every cue carries more than colour** — direction, glyph shape, motion and text.
- **No probabilistic assertions.** Behaviour tests pin the seed and compare deterministic outputs.
- **Baseline to preserve:** `cd tests && npm run test:all` reports 9 suites totalling 198 tests; `npm --prefix web test` reports 71. Both must still pass at the end of every task.
- Stable ids verbatim: encounter `counter_pull`; actions `left`, `right`, `brace`, `reel`, plus the universal `advance`; phases `LEFT_RUN`, `RIGHT_RUN`, `DIVE`, `FATIGUED`, `LANDING`.

---

## Deferred, explicitly

**Directional world feedback — rod lean, bobber displacement and splash driven by the authoritative phase — is NOT part of Phase B.** The spec describes it (§4.7) and it is the difference between a fight that reads as part of the world and a panel that reads as a menu, but it needs work in `client/casting.lua` and the anim layer that has nothing to do with the state machine, and half of it shipped is worse than none.

Phase B delivers directional glyphs, motion, text, keycaps and the existing fight sound and animation. Phase G picks up world feedback as a visual-only layer: no world visual may ever influence gameplay authority.

---

## File Structure

| File | Responsibility | Task |
| --- | --- | --- |
| `server/encounter.lua` | **Modify.** Contract refinements: `ctx.now` into `build`, `mod.render(enc, now)`, `Begin` returns the opening render. | 1 |
| `server/session.lua` | **Modify.** `zfishing:hook` returns the opening render with the challenge id. | 1 |
| `tests/harness.lua` | **Modify.** `H.withSeed` so a fight's RNG stream is pinnable. | 1 |
| `server/encounter_counter_pull.lua` | **Create.** Tier table, phase machine with `phaseId` and `countersSinceFatigue`, action scoring, relative render. | 2 |
| `tests/encounter_counter_pull.test.lua` | **Create.** The fight itself, deterministic throughout. | 2 |
| `client/encounter.lua` | **Create.** Bite routing, serialized action dispatch, settlement orchestration, teardown. | 3 |
| `client/minigame.lua` | **Modify.** Bail out of the legacy path when the session is an encounter. | 3 |
| `tests/client_encounter.test.lua` | **Create.** Bridge lifecycle coverage. | 3 |
| `web/src/encounters/types.ts` | **Create.** Payload types — durations, not timestamps. | 4 |
| `web/src/encounters/EncounterHost.tsx` | **Create.** Shared shell, dispatch by encounter type. | 4 |
| `web/src/encounters/CounterPull.tsx` | **Create.** The directional fight UI. | 4 |
| `web/src/App.tsx` | **Modify.** Route the `encounter` view. | 4 |
| `web/src/style.css` | **Modify.** Encounter classes in the existing HUD language. | 4 |
| `web/src/encounters/__tests__/CounterPull.test.tsx` | **Create.** State-transition coverage. | 5 |
| `locales/en.json`, `locales/th.json` | **Modify.** Encounter UI strings. | 5 |
| `fxmanifest.lua`, `web/dist`, `docs/*` | **Modify / rebuild.** | 6 |

---

## Task 1: Contract corrections

Three additive changes to the Phase A contract, isolated in their own task because they touch shipped, merged code and deserve their own review gate. No encounter behaviour changes here.

**Files:**
- Modify: `server/encounter.lua` (`Encounter.Begin`)
- Modify: `server/session.lua` (the `zfishing:hook` tail)
- Modify: `tests/harness.lua`

**Interfaces:**
- Produces, for Task 2 onward:
  - `mod.build(ctx) -> state, estimatedFightMs` where `ctx = { difficulty, seed, fish, gear, now }`.
  - `mod.render(enc, now) -> table` — **relative durations only**, plus `phaseId`.
  - `Encounter.Begin(s, gear) -> challengeId, openingRender`.
  - `zfishing:hook` answers `{ ok = true, challengeId = <string>, encounter = <render> }`.
  - `H.withSeed(seed, fn)` — pins `math.random(a, b)` so a challenge seed is reproducible.

- [ ] **Step 1: Give `build` the clock and `Begin` an opening frame**

In `server/encounter.lua`, `Encounter.Begin` currently reads the clock after building. Move the read above, pass it in:

```lua
function Encounter.Begin(s, gear)
    local mod = Encounter.MODULES[s.encounter.type]
    if not mod then return nil end

    -- `now` is read before build so a module arms its first phase against the same
    -- clock the expiry timer below is set from.
    local now = GetGameTimer()
    local state, estimate = mod.build({
        difficulty = s.encounter.difficulty,
        seed       = math.random(1, 2147483647),
        fish       = s.fish,
        gear       = gear or {},
        now        = now,
    })
```

Delete the later `local now = GetGameTimer()` line, and change the return:

```lua
    -- The opening frame. Without it the NUI has nothing to draw until the player's
    -- first action -- the one moment they cannot act without seeing something.
    --
    -- render() takes `now` because every duration it emits is relative to it. Absolute
    -- server timestamps must never reach a client: the server's GetGameTimer() and the
    -- client's are unrelated clocks with unrelated origins, and arithmetic between them
    -- is meaningless no matter which side performs it.
    return s.encounter.challengeId, mod.render and mod.render(s.encounter, now) or nil
end
```

- [ ] **Step 2: Return the opening frame from the hook**

In `server/session.lua`, the `zfishing:hook` tail becomes:

```lua
    local challengeId, opening
    if s.encounter and s.encounter.type ~= Encounters.FALLBACK then
        challengeId, opening = Encounter.Begin(s, {
            lineRating = s.lineRating,
            reelDrain  = s.reelDrain or 1.0,
            greenZone  = (Config.Equipment.rods[s.rod] or {}).greenZone or 0.0,
        })
    end
    return { ok = true, challengeId = challengeId, encounter = opening }
```

- [ ] **Step 3: Add a seed pin to the harness**

Append to `tests/harness.lua`, immediately before `function H.run()`:

```lua
-- Pins math.random(a, b) -- the form Encounter.Begin uses to mint a challenge seed --
-- so a fight's whole RNG stream is reproducible. Without it a behaviour test can only
-- assert a distribution, and a distribution assertion is a flaky test wearing a
-- statistics costume.
function H.withSeed(seed, fn)
    local real = math.random
    math.random = function(a, b)
        if a == nil then return real() end
        if b == nil then return math.min(seed, a) end
        return math.max(a, math.min(b, seed))
    end
    local ok, err = pcall(fn)
    math.random = real
    if not ok then error(err, 0) end
end
```

- [ ] **Step 4: Verify the contract change broke nothing**

```bash
cd tests && npm run test:all
```

Expected: 9 suites, 198 tests, exit 0. No module implements `render` yet, so `Begin` returns `nil` for it and `hook` answers `encounter = nil` — the fake modules in `tests/encounter_action.test.lua` define no `render`, which is exactly the path the `mod.render and` guard covers.

- [ ] **Step 5: Commit**

```bash
git add server/encounter.lua server/session.lua tests/harness.lua
git commit -m "feat: emit encounter render payloads as relative durations"
```

---

## Task 2: The counter-pull module

**Files:**
- Create: `server/encounter_counter_pull.lua`
- Create: `tests/encounter_counter_pull.test.lua`
- Modify: `tests/package.json`

**Interfaces:**
- Consumes: `Encounter.Register(id, mod)`; `ctx = { difficulty, seed, fish, gear, now }`; `Encounters.LineMult(rating)`; `ZUtil.clamp`.
- Produces: `mod.actions`, `mod.build`, `mod.render(enc, now)`, `mod.act(enc, action, now)`.
  `act` returns `{ render, outcome, value }`; the module writes `enc.state.deadline` in **absolute** server time for the dispatcher's `advance` check.

**Performance contract.** Phase A's `Encounter.PerfScore` is `sum(value) / count(value)` over every action that reached the module, so for counter-pull:

| event | counted? | value |
| --- | --- | --- |
| correct counter / brace / fatigue reel / landing reel | yes | 1 |
| wrong key, or the right key outside the window | yes | 0 |
| `advance` after a missed deadline | yes | 0 — a missed window is a gameplay miss |
| `bad_seq`, `bad_action`, `stale_challenge`, `too_many_requests` | **no** — rejected before the module runs | — |

A flawless fight is therefore exactly `1.0`, and a protocol error never dents a player's score.

- [ ] **Step 1: Write the failing module tests**

Create `tests/encounter_counter_pull.test.lua`:

```lua
-- Counter-Pull Fight. Run from the resource root:
--   node tests/luarun.mjs tests/encounter_counter_pull.test.lua
--
-- Sequencing, replay, stale challenge, wrong session and disconnect are covered once
-- for every encounter in tests/encounter_action.test.lua. This suite is about the
-- fight itself.
--
-- Every test here is deterministic. Render payloads carry DURATIONS, so a test tracks
-- absolute time itself: it knows the clock an action was sent at, and the reply says
-- how far from that instant each edge is.

dofile('tests/harness.lua')
local test, equal, truthy, falsy = H.test, H.equal, H.truthy, H.falsy

local FISH = { species = 'pike', label = 'Pike', weight = 6.0, quality = 3, rarity = 'uncommon',
    behavior = 'erratic', biteDelay = 100, hookWindow = 1500, tensionDiff = 1.15,
    fishEnergy = 50, xp = 24, price = 18, difficulty = 2 }

local COUNTER = { LEFT_RUN = 'right', RIGHT_RUN = 'left', DIVE = 'brace' }

-- cast -> bite -> hook, leaving an armed counter-pull challenge. `g.at` is the clock
-- the current render was built against; every duration in `g.last` measures from it.
local function start(opts)
    opts = opts or {}
    local fish = H.deepcopy(FISH)
    if opts.difficulty then fish.difficulty = opts.difficulty end
    if opts.behavior then fish.behavior = opts.behavior end

    local g = {}
    local run = function()
        g.calls = H.loadSession({ fish = fish, encounterMode = 'forced',
                                  forcedEncounter = 'counter_pull', rig = opts.rig })
        dofile('server/encounter_counter_pull.lua')
        local cast = H.CB['zfishing:cast'](5, 0.5, opts.rig and 1 or nil)
        truthy(cast.ok, tostring(cast.reason))
        H.fireLatestTimer()
        local hook = H.CB['zfishing:hook'](5, cast.sessionId)
        truthy(hook.ok); truthy(hook.challengeId); truthy(hook.encounter)
        g.sid, g.cid, g.last, g.at, g.seq = cast.sessionId, hook.challengeId, hook.encounter, _G.__NOW, 0
    end
    if opts.seed then H.withSeed(opts.seed, run) else run() end
    return g
end

-- Sends `action` at `offset` ms past the moment the current render was built.
local function act(g, action, offset)
    _G.__NOW = g.at + offset
    g.seq = g.seq + 1
    local res = H.CB['zfishing:encounter:act'](5, g.sid, g.cid, g.seq, action)
    if res.ok and res.state then g.last, g.at = res.state, _G.__NOW end
    return res
end

local function correctFor(render)
    if render.phase == 'FATIGUED' or render.phase == 'LANDING' then return 'reel' end
    return COUNTER[render.phase]
end

-- Answers whatever the server just asked for, just inside the window.
local function answer(g)
    return act(g, correctFor(g.last), g.last.windowOpensIn + 50)
end

test('P1 the hook answer opens the fight with a renderable phase', function()
    local g = start()
    truthy(COUNTER[g.last.phase], 'the opening phase is one of the three run states')
    equal(g.last.required, nil, 'the render payload must never carry the answer')
    truthy(g.last.phaseId, 'every authoritative transition is identifiable')
    truthy(g.last.windowOpensIn > g.last.telegraphIn, 'the telegraph precedes the window')
    truthy(g.last.windowClosesIn > g.last.windowOpensIn)
    equal(g.last.windowOpensAt, nil, 'absolute server time must never reach a client')
    equal(g.last.staminaPct, 100); equal(g.last.linePct, 100)
end)

test('P2 a correct counter drains stamina and arms a NEW phase', function()
    local g = start()
    local firstId = g.last.phaseId
    local res = answer(g)
    truthy(res.ok); equal(res.outcome, nil)
    truthy(res.state.staminaPct < 100, 'a correct counter must cost the fish stamina')
    equal(res.state.linePct, 100, 'and must not damage the line')
    equal(res.state.misses, 0)
    truthy(res.state.phaseId > firstId, 'the phase id must advance even when the phase repeats')
end)

test('P3 a wrong counter damages the line and counts a miss', function()
    local g = start()
    local wrong = g.last.phase == 'DIVE' and 'left' or 'brace'
    local res = act(g, wrong, g.last.windowOpensIn + 50)
    truthy(res.ok, 'a wrong answer is a legal action, not a protocol error')
    equal(res.state.misses, 1)
    truthy(res.state.linePct < 100)
end)

test('P4 the right key at the wrong moment is still a miss', function()
    local g = start()
    equal(act(g, correctFor(g.last), 0).state.misses, 1,
        'countering before the fish commits is a miss')

    local g2 = start()
    equal(act(g2, correctFor(g2.last), g2.last.windowClosesIn + 2000).state.misses, 1,
        'countering after the window is a miss')
end)

test('P5 reeling during a run is a miss; reeling during fatigue is the point', function()
    local g = start()
    equal(act(g, 'reel', g.last.windowOpensIn + 50).state.misses, 1,
        'you cannot reel a fish that is running')

    local g2 = start({ difficulty = 1 })
    local fatigued
    for _ = 1, 12 do
        if g2.last.phase == 'FATIGUED' then fatigued = g2.last break end
        answer(g2)
    end
    truthy(fatigued, 'enough correct counters must tire the fish out')
    truthy((fatigued.reelsLeft or 0) > 0)
    local before = fatigued.staminaPct
    local r = answer(g2)
    truthy(r.ok)
    truthy(r.state.staminaPct < before, 'reeling a fatigued fish takes a bigger bite')
end)

test('P6 advance after the window expires is scored as a miss by the SERVER', function()
    local g = start()
    local res = act(g, 'advance', g.last.windowClosesIn + 400)
    truthy(res.ok)
    equal(res.state.misses, 1)
    truthy(res.state.phase, 'the fight moves on rather than stalling')
end)

test('P7 line damage ends the fight as a snap, before the miss budget runs out', function()
    -- tier 5 on a 10lb line: 80 line, 30 damage per mistake, maxMisses 4.
    -- Three mistakes deal 90 -- the line goes first, deterministically.
    local g = start({ difficulty = 5 })
    local outcome
    for _ = 1, 4 do
        local res = act(g, 'advance', g.last.windowClosesIn + 400)
        outcome = res.outcome
        if outcome then break end
    end
    equal(outcome, 'snap')
    equal(g.calls.give, 0, 'a lost fight settles nothing')
end)

test('P8 a clean fight lands the fish and scores a perfect performance', function()
    local g = start({ difficulty = 1 })
    local outcome
    for _ = 1, 60 do
        local res = answer(g)
        outcome = res.outcome
        if outcome then break end
    end
    equal(outcome, 'success', 'answering every phase correctly must land the fish')
    truthy(H.CB['zfishing:claim'](5, g.sid, 0, false, nil).fish, 'and the claim pays')
    equal(g.calls.ctx.perfScore, 1, 'no miss means a perfect score')
end)

test('P9 a rejected action leaves the phase and the clock untouched', function()
    local g = start()
    local before = H.deepcopy(g.last)
    _G.__NOW = g.at + before.windowOpensIn + 50
    equal(H.CB['zfishing:encounter:act'](5, g.sid, g.cid, 9, 'left').reason, 'bad_seq')
    equal(H.CB['zfishing:encounter:act'](5, g.sid, g.cid, 1, 'teleport').reason, 'bad_action')
    local ok = H.CB['zfishing:encounter:act'](5, g.sid, g.cid, 1, correctFor(before))
    truthy(ok.ok, 'seq 1 was never consumed')
    equal(ok.state.misses, 0, 'and neither rejection was scored')
    equal(ok.state.phaseId, before.phaseId + 1, 'exactly one transition happened')
end)

test('P10 a harder tier shortens both the telegraph and the counter window', function()
    local easy = start({ difficulty = 1 }).last
    local hard = start({ difficulty = 5 }).last
    -- Durations, not timestamps: the render carries offsets from its own build moment,
    -- so these are the real telegraph and window lengths.
    truthy(hard.windowOpensIn < easy.windowOpensIn, 'shorter telegraph')
    truthy((hard.windowClosesIn - hard.windowOpensIn) < (easy.windowClosesIn - easy.windowOpensIn),
        'shorter counter window')
    truthy(hard.maxMisses <= easy.maxMisses, 'and no more room for mistakes')
end)

test('P11 behavior changes which phases the fish picks, on an identical RNG stream', function()
    -- Same seed for both fish, so the LCG produces the same numbers and the ONLY
    -- difference is the weight table. No probability, no flake.
    local function phaseRun(behavior)
        local g = start({ behavior = behavior, difficulty = 1, seed = 20260821 })
        local seen, dives = {}, 0
        for _ = 1, 12 do
            seen[#seen + 1] = g.last.phase
            if g.last.phase == 'DIVE' then dives = dives + 1 end
            if act(g, 'advance', g.last.windowClosesIn + 400).outcome then break end
        end
        return seen, dives
    end
    local heavySeq, heavyDives = phaseRun('steady_heavy')
    local lightSeq, lightDives = phaseRun('steady_light')
    truthy(heavyDives > lightDives,
        ('a heavy fish must dive more than a light one on the same stream: %d vs %d')
            :format(heavyDives, lightDives))
    truthy(#heavySeq > 0 and #lightSeq > 0)
end)

test('P12 better gear widens the window and deepens the line, without touching the tier', function()
    local plain = start({ difficulty = 3 }).last
    local geared = start({ difficulty = 3, rig = true }).last
    equal(plain.maxMisses, geared.maxMisses, 'gear must not change the tier')
    truthy((geared.windowClosesIn - geared.windowOpensIn)
           >= (plain.windowClosesIn - plain.windowOpensIn))
end)

test('P13 a missed landing gives the fish a second wind, not another fatigue break', function()
    local g = start({ difficulty = 1 })
    local landing
    for _ = 1, 60 do
        if g.last.phase == 'LANDING' then landing = g.last break end
        if answer(g).outcome then break end
    end
    truthy(landing, 'a clean fight must reach the landing turn')
    local res = act(g, 'advance', g.last.windowClosesIn + 400)   -- fumble it
    truthy(res.ok)
    equal(res.outcome, nil, 'a fumbled landing is not a loss')
    truthy(res.state.staminaPct > 0, 'the fish recovers')
    falsy(res.state.phase == 'FATIGUED',
        'the fight resumes normally -- the fatigue counter reset when the break was taken')
end)

H.run()
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
node tests/luarun.mjs tests/encounter_counter_pull.test.lua
```

Expected: `RUNNER ERROR` naming `server/encounter_counter_pull.lua` — the file does not exist.

- [ ] **Step 3: Write the module**

Create `server/encounter_counter_pull.lua`:

```lua
-- Counter-Pull Fight.
--
-- The fish telegraphs a direction; the player counters it. The server owns which
-- direction it is, when the window opens and closes, and what every action cost --
-- the client is told what to draw and nothing more. In particular the render payload
-- never carries `required`: a player derives the counter from the cue, which is the
-- game, but handing an auto-counter bot the answer costs an honest client nothing.
--
-- Two things about time in here. State is ABSOLUTE server milliseconds, because that
-- is what an incoming action is judged against. Renders are RELATIVE durations,
-- because the client's GetGameTimer() is a different clock entirely and no arithmetic
-- between the two means anything.

local M = {}

-- Difficulty tiers. Times in ms; stamina and line are pools.
local TIERS = {
    [1] = { telegraph = 900, window = 1400, perFatigue = 3, reels = 2, stamina = 100, line = 100, mistake = 20, maxMisses = 6, fake = 0.00 },
    [2] = { telegraph = 800, window = 1200, perFatigue = 3, reels = 2, stamina = 120, line = 100, mistake = 22, maxMisses = 5, fake = 0.00 },
    [3] = { telegraph = 650, window = 1000, perFatigue = 4, reels = 3, stamina = 150, line = 90,  mistake = 25, maxMisses = 5, fake = 0.10 },
    [4] = { telegraph = 520, window = 850,  perFatigue = 4, reels = 3, stamina = 180, line = 85,  mistake = 28, maxMisses = 4, fake = 0.18 },
    [5] = { telegraph = 420, window = 700,  perFatigue = 5, reels = 3, stamina = 220, line = 80,  mistake = 30, maxMisses = 4, fake = 0.25 },
}

-- Both window edges are forgiving by this much. Network jitter must never turn an
-- honest counter into a miss -- the same reason Config.Timings.hookLatency exists.
local GRACE = 250
local FATIGUE_WINDOW = 2500
local LANDING_MULT = 1.5
local STAMINA_PER_COUNTER = 8
local STAMINA_PER_REEL = 12
local MISS_RECOVERY = 3
local LANDING_RECOVERY = 25
-- A fake must flip at least this long before the window shuts, so the switch is always
-- something a watching player can react to rather than unavoidable RNG.
local FAKE_LEAD = 400

local COUNTER = { LEFT_RUN = 'right', RIGHT_RUN = 'left', DIVE = 'brace' }
local RUNS = { 'LEFT_RUN', 'RIGHT_RUN', 'DIVE' }

-- Keyed on the four behavior names that actually exist in config/fish.lua.
local BEHAVIOR = {
    steady_light = { LEFT_RUN = 5, RIGHT_RUN = 5, DIVE = 1 },
    steady_heavy = { LEFT_RUN = 2, RIGHT_RUN = 2, DIVE = 7 },
    run_stop     = { LEFT_RUN = 4, RIGHT_RUN = 4, DIVE = 2 },
    erratic      = { LEFT_RUN = 3, RIGHT_RUN = 3, DIVE = 3 },
}

-- Seeded LCG rather than math.random: the fight has to be reproducible from the
-- challenge seed alone, so a test can pin one and a desync can be investigated.
local function rand(st)
    st.rng = (1103515245 * st.rng + 12345) % 2147483648
    return st.rng / 2147483648
end

local function pickRun(st)
    local w = BEHAVIOR[st.behavior] or BEHAVIOR.steady_light
    local total = 0
    for _, name in ipairs(RUNS) do total = total + (w[name] or 1) end
    local r = rand(st) * total
    for _, name in ipairs(RUNS) do
        r = r - (w[name] or 1)
        if r <= 0 then return name end
    end
    return RUNS[#RUNS]
end

-- Every arm* below bumps phaseId. Phase name and window lengths repeat exactly -- an
-- id does not, and the NUI re-anchors its clock on it. Without this, two consecutive
-- identical LEFT_RUN phases leave React's effects thinking nothing happened, so the
-- window bar never restarts and the no-input `advance` never re-arms.
local function bump(st)
    st.phaseId = (st.phaseId or 0) + 1
end

local function armRun(st, now)
    bump(st)
    st.phase = pickRun(st)
    st.required = COUNTER[st.phase]
    st.telegraphAt = now
    st.windowOpensAt = now + st.tier.telegraph
    st.windowClosesAt = st.windowOpensAt + st.window
    st.deadline = st.windowClosesAt + GRACE
    st.reelsLeft = nil
    st.cue, st.switchAt, st.nextCue = st.phase, nil, nil

    if st.tier.fake > 0 and rand(st) < st.tier.fake then
        -- Show a different direction first, then visibly flip to the real one.
        local decoy = pickRun(st)
        if decoy ~= st.phase then
            st.cue = decoy
            st.nextCue = st.phase
            st.switchAt = st.windowClosesAt - math.max(FAKE_LEAD, math.floor(st.window * 0.5))
        end
    end
end

local function armFatigue(st, now, reelsLeft)
    bump(st)
    st.phase = 'FATIGUED'
    st.required = 'reel'
    -- The break the fish just took resets the count toward the next one. Tracking
    -- "counters since the last break" rather than "counters % perFatigue" is what stops
    -- a fumbled landing from dropping straight back into another break: with a modulo
    -- the total is still divisible, so the fight would stall instead of resuming.
    st.countersSinceFatigue = 0
    st.telegraphAt = now
    st.windowOpensAt = now
    st.windowClosesAt = now + FATIGUE_WINDOW
    st.deadline = st.windowClosesAt + GRACE
    st.reelsLeft = reelsLeft or st.tier.reels
    st.cue, st.switchAt, st.nextCue = 'FATIGUED', nil, nil
end

local function armLanding(st, now)
    bump(st)
    st.phase = 'LANDING'
    st.required = 'reel'
    st.telegraphAt = now
    st.windowOpensAt = now
    st.windowClosesAt = now + math.floor(st.window * LANDING_MULT)
    st.deadline = st.windowClosesAt + GRACE
    st.reelsLeft = nil
    st.cue, st.switchAt, st.nextCue = 'LANDING', nil, nil
end

M.actions = { left = true, right = true, brace = true, reel = true }

function M.build(ctx)
    local tier = TIERS[ZUtil.clamp(math.floor(ctx.difficulty or 1), 1, 5)]
    local gear = ctx.gear or {}
    local drain = gear.reelDrain or 1.0
    local window = math.floor(tier.window * (1 + (gear.greenZone or 0)))

    local st = {
        rng = (ctx.seed or 1) % 2147483648,
        tier = tier,
        window = window,
        behavior = (ctx.fish or {}).behavior or 'steady_light',
        maxStamina = tier.stamina,
        stamina = tier.stamina,
        maxLine = math.floor(tier.line * Encounters.LineMult(gear.lineRating or 10)),
        perCounter = STAMINA_PER_COUNTER * drain,
        perReel = STAMINA_PER_REEL * drain,
        counters = 0, countersSinceFatigue = 0, misses = 0, phaseId = 0,
    }
    st.line = st.maxLine
    armRun(st, ctx.now or 0)

    -- Worst honest fight: every counter landed, plus a full miss budget, plus one
    -- fatigue break per `perFatigue` counters, plus the landing window. Computed at
    -- drainRate 1.0 so a cheap reel still fits inside the deadline.
    local counters = math.ceil(tier.stamina / STAMINA_PER_COUNTER)
    local estimate = (counters + tier.maxMisses) * (tier.telegraph + window)
        + math.ceil(counters / tier.perFatigue) * FATIGUE_WINDOW
        + math.floor(window * LANDING_MULT)

    return st, estimate
end

-- Durations, never timestamps. See the header.
function M.render(enc, now)
    local st = enc.state
    return {
        phaseId = st.phaseId,
        phase = st.phase,
        cue = st.cue, nextCue = st.nextCue,
        telegraphIn = st.telegraphAt - now,
        windowOpensIn = st.windowOpensAt - now,
        windowClosesIn = st.windowClosesAt - now,
        switchIn = st.switchAt and (st.switchAt - now) or nil,
        staminaPct = math.max(0, math.floor(st.stamina / st.maxStamina * 100)),
        linePct = math.max(0, math.floor(st.line / st.maxLine * 100)),
        misses = st.misses, maxMisses = st.tier.maxMisses,
        reelsLeft = st.reelsLeft,
        -- `required` is deliberately absent. See the header.
    }
end

function M.act(enc, action, now)
    local st = enc.state

    -- `advance` means the player's window expired. Everything else is judged on both
    -- WHAT was pressed and WHEN -- the right key outside the window is still a miss.
    local hit
    if action == 'advance' then
        hit = false
    elseif now < st.windowOpensAt - GRACE or now > st.windowClosesAt + GRACE then
        hit = false
    else
        hit = (action == st.required)
    end

    if hit then
        if st.phase == 'LANDING' then
            st.stamina = 0
            return { render = M.render(enc, now), outcome = 'success', value = 1 }
        elseif st.phase == 'FATIGUED' then
            st.stamina = st.stamina - st.perReel
            st.reelsLeft = (st.reelsLeft or 1) - 1
        else
            st.stamina = st.stamina - st.perCounter
            st.counters = st.counters + 1
            st.countersSinceFatigue = st.countersSinceFatigue + 1
        end
    else
        st.misses = st.misses + 1
        st.line = st.line - st.tier.mistake
        if st.phase == 'LANDING' then
            -- A second wind, and a clean slate toward the next break: the fish just had
            -- one, so dropping straight back into another reads as the fight stalling.
            st.stamina = LANDING_RECOVERY
            st.countersSinceFatigue = 0
        else
            st.stamina = math.min(st.maxStamina, st.stamina + MISS_RECOVERY)
        end
    end

    if st.line <= 0 then
        return { render = M.render(enc, now), outcome = 'snap', value = hit and 1 or 0 }
    end
    if st.misses >= st.tier.maxMisses then
        return { render = M.render(enc, now), outcome = 'escape', value = hit and 1 or 0 }
    end

    if st.stamina <= 0 then
        armLanding(st, now)
    elseif st.phase == 'FATIGUED' and (st.reelsLeft or 0) > 0 then
        armFatigue(st, now, st.reelsLeft)      -- same break, fresh window
    elseif st.phase ~= 'FATIGUED' and st.countersSinceFatigue >= st.tier.perFatigue then
        armFatigue(st, now)
    else
        armRun(st, now)
    end

    return { render = M.render(enc, now), outcome = nil, value = hit and 1 or 0 }
end

Encounter.Register('counter_pull', M)
```

- [ ] **Step 4: Add the npm script**

In `tests/package.json`, add to `scripts`:

```json
    "test:encounter-counter-pull": "node luarun.mjs tests/encounter_counter_pull.test.lua",
```

and append ` && npm run test:encounter-counter-pull` to `test:all`.

- [ ] **Step 5: Run the tests to verify they pass**

```bash
node tests/luarun.mjs tests/encounter_counter_pull.test.lua
```

Expected: thirteen `ok -` lines then `13 tests passed`.

If P11 fails, the two weight tables produced the same picks on that seed — try another seed before touching the weights, and only widen `steady_heavy`'s DIVE weight if several seeds agree. If P7 or P8 hit their loop ceilings, print the final render and re-derive the tier arithmetic rather than raising the ceiling.

- [ ] **Step 6: Re-run every suite**

```bash
cd tests && npm run test:all
```

Expected: 10 suites, 198 + 13 = 211 tests, exit 0.

- [ ] **Step 7: Commit**

```bash
git add server/encounter_counter_pull.lua tests/encounter_counter_pull.test.lua tests/package.json
git commit -m "feat: add the counter-pull fight state machine"
```

---

## Task 3: The client bridge

**Files:**
- Create: `client/encounter.lua`
- Modify: `client/minigame.lua`
- Create: `tests/client_encounter.test.lua`
- Modify: `tests/package.json`

**Interfaces:**
- Consumes: the `zfishing:bite` payload's `encounter` and `difficulty`; `zfishing:hook`'s `{ ok, challengeId, encounter }`; `zfishing:encounter:act`'s `{ ok, seq, state, outcome }`.
- Produces: NUI messages `{ action = 'encounter', type, difficulty, state, startedAt }` and `{ action = 'encounterState', state, outcome }`; NUI callbacks `encounterAction` (`{ action }`) and `encounterClosed` (presentation-only).

**Settlement is the client's job, not the NUI's.** The moment the server reports a terminal outcome the bridge knows the fight is over and calls `zfishing:claim` itself. The NUI is told to play its ending; if it never answers, the catch still settles.

- [ ] **Step 1: Keep the legacy handler off the encounter path**

In `client/minigame.lua`, at the top of the `zfishing:bite` handler:

```lua
RegisterNetEvent('zfishing:bite', function(data)
    if not ZClient.active then return end
    -- An encounter session is driven by client/encounter.lua. This handler is the
    -- LEGACY tension fight and must not also run, or both would race the same hook.
    if data.encounter and data.encounter ~= 'legacy_tension' then return end
```

- [ ] **Step 2: Write the bridge**

Create `client/encounter.lua`:

```lua
-- Encounter bridge and orchestrator.
--
-- Routes an encounter bite to the NUI, polls input, forwards one discrete action at a
-- time, and drives settlement when the server says the fight is over.
--
-- It simulates NOTHING: no stamina, no timer that decides anything, no notion of
-- whether an action was correct. The server answers all three. Its own state is the
-- sequence number, the in-flight lock and the last authoritative payload.

local ENC = { active = false, seq = 0, inFlight = false,
              challengeId = nil, sessionId = nil, type = nil }

-- action -> control. All four are analog on a gamepad already, so controller support
-- needs no separate mapping and no button mashing.
local KEYS = {
    { action = 'left',  control = 34 },   -- INPUT_MOVE_LEFT_ONLY   (A / stick left)
    { action = 'right', control = 35 },   -- INPUT_MOVE_RIGHT_ONLY  (D / stick right)
    { action = 'brace', control = 33 },   -- INPUT_MOVE_DOWN_ONLY   (S / stick down)
    { action = 'reel',  control = 22 },   -- the key the legacy fight already uses
}

local function reset()
    ENC.active, ENC.inFlight = false, false
    ENC.challengeId, ENC.sessionId, ENC.type = nil, nil, nil
    ENC.seq = 0
end

-- Settlement. Runs once, from here, the moment the server reports a terminal outcome.
-- The NUI is a spectator to this: if it never posts encounterClosed the catch still
-- settles, and if it posts twice the session is already gone.
local function settle(outcome)
    local sessionId = ENC.sessionId
    reset()
    ZClient.reeling = false
    if not sessionId then return end

    Wait(700)   -- let the ending render before the catch card replaces it

    -- The same door as always. `success` is ignored for an encounter session -- the
    -- server reads its own outcome -- but the argument list is unchanged, so there is
    -- still exactly one settlement path in the resource.
    local res = lib.callback.await('zfishing:claim', false, sessionId, 0, false, nil)
    if res and res.ok and res.fish then
        SendNUIMessage({ action = 'caught',
            label = res.fish.label, weight = res.fish.weight, quality = res.fish.quality })
        Casting.StartDrift()
        SetNuiFocus(true, true)
        PlaySoundFrontend(-1, 'CHECKPOINT_PERFECT', 'HUD_MINI_GAME_SOUNDSET', true)
    elseif res and res.ok then
        TriggerEvent('zfishing:client:end',
            (res.outcome or outcome) == 'snap' and 'line_broke' or 'fish_escaped', 'error')
    else
        TriggerEvent('zfishing:client:end', 'error_claim_failed', 'error')
    end
end

-- One request in flight at a time. Input polling and the NUI's deadline `advance` are
-- two independent senders, and near a window edge both would claim the same seq -- the
-- server rejects the loser as bad_seq, which is safe but costs an honest player the
-- input they actually made. Counter-pull is discrete and human-paced, so a lock is
-- enough; do not add a queue without evidence that one is needed.
local function send(action)
    if not ENC.active or ENC.inFlight then return end
    ENC.inFlight = true

    local res = lib.callback.await('zfishing:encounter:act', false,
        ENC.sessionId, ENC.challengeId, ENC.seq + 1, action)

    ENC.inFlight = false
    if not res then return end
    if res.seq then ENC.seq = res.seq end

    if res.ok then
        SendNUIMessage({ action = 'encounterState', state = res.state, outcome = res.outcome })
        if res.outcome then settle(res.outcome) end
        return
    end

    -- A rejection that ends the fight has to end it here too, or the player sits in a
    -- UI nothing will ever update again.
    if res.reason == 'encounter_over' then
        SendNUIMessage({ action = 'encounterState', state = nil, outcome = res.outcome or 'timeout' })
        settle(res.outcome or 'timeout')
    end
end

RegisterNetEvent('zfishing:bite', function(data)
    if not ZClient.active then return end
    if not data.encounter or data.encounter == 'legacy_tension' then return end

    Casting.diving = true
    PlaySoundFrontend(-1, 'TIMER_STOP', 'HUD_MINI_GAME_SOUNDSET', true)
    SetPadShake(0, 300, 150)
    SendNUIMessage({ action = 'waiting', phase = 'bite',
        rod = ZClient.hud.rod, bait = ZClient.hud.bait, distance = ZClient.hud.distance })

    -- The hook QTE is unchanged: SPACE inside the window, exactly as the legacy path.
    local deadline = GetGameTimer() + (data.hookWindow or 1500)
    local hooked = false
    while ZClient.active and GetGameTimer() < deadline do
        if IsDisabledControlJustPressed(0, 22) then hooked = true break end
        Wait(0)
    end
    if not ZClient.active then return end
    if not hooked then
        lib.callback.await('zfishing:cancel', false, ZClient.sessionId)
        return TriggerEvent('zfishing:client:end', 'fish_escaped', 'error')
    end

    local res = lib.callback.await('zfishing:hook', false, ZClient.sessionId)
    if not res or not res.ok or not res.challengeId then
        return TriggerEvent('zfishing:client:end', 'fish_escaped', 'error')
    end

    ENC.active, ENC.inFlight, ENC.seq = true, false, 0
    ENC.sessionId, ENC.challengeId, ENC.type = ZClient.sessionId, res.challengeId, data.encounter
    ZClient.reeling = true

    SendNUIMessage({ action = 'encounter', type = data.encounter,
        difficulty = data.difficulty, state = res.encounter,
        startedAt = GetGameTimer() })
    Casting.StartFight()
    Anim.PlayClip('idle_c')

    -- Input polling. One event per PRESS, never per frame -- the loop runs at frame
    -- rate because that is how FiveM reads a key, but it only talks to the server on an
    -- edge, and only when no request is already out.
    CreateThread(function()
        while ENC.active and ZClient.active do
            if not ENC.inFlight then
                for _, k in ipairs(KEYS) do
                    if IsDisabledControlJustPressed(0, k.control) then
                        send(k.action)
                        break
                    end
                end
            end
            Wait(0)
        end
    end)
end)

-- The NUI's local window expired. The server decides what that means, and refuses an
-- `advance` that arrives before the deadline it set.
RegisterNUICallback('encounterAction', function(body, cb)
    cb({})
    if type(body) == 'table' and type(body.action) == 'string' then send(body.action) end
end)

-- Presentation close only. Settlement already happened in settle(); this exists so the
-- NUI can say its ending animation is done. It grants no permission.
RegisterNUICallback('encounterClosed', function(_, cb) cb({}) end)

AddEventHandler('zfishing:client:end', function() reset() end)
```

- [ ] **Step 3: Write the bridge tests**

Create `tests/client_encounter.test.lua`:

```lua
-- The client encounter bridge. Run from the resource root:
--   node tests/luarun.mjs tests/client_encounter.test.lua
--
-- Drives client/encounter.lua against stubbed FiveM natives and a scripted server, so
-- the lifecycle it owns -- routing, sequencing, the in-flight lock, settlement -- is
-- tested directly rather than inferred from a server suite.

dofile('tests/harness.lua')
local test, equal, truthy, falsy = H.test, H.equal, H.truthy, H.falsy

local sent, nui, ended

-- Installs the client-side host: control stubs, a scripted callback server, and the
-- recorders the assertions read.
local function loadBridge(script)
    H.installHost()
    sent, nui, ended = {}, {}, {}

    local pressed = {}
    _G.__PRESS = function(control) pressed[control] = true end
    _G.IsDisabledControlJustPressed = function(_, control)
        if pressed[control] then pressed[control] = nil; return true end
        return false
    end
    _G.IsDisabledControlPressed = function() return false end
    _G.PlaySoundFrontend = function() end
    _G.SetPadShake = function() end
    _G.SetNuiFocus = function() end
    _G.SendNUIMessage = function(msg) nui[#nui + 1] = msg end
    _G.RegisterNUICallback = function(name, fn) H.CB['nui:' .. name] = fn end
    _G.TriggerEvent = function(name, key) ended[#ended + 1] = { name = name, key = key } end

    _G.lib = { callback = { await = function(name, _, ...)
        sent[#sent + 1] = { name = name, args = { ... } }
        return script(name, ...)
    end } }

    _G.ZClient = { active = true, reeling = false, sessionId = 'sess-1', hud = {} }
    _G.Casting = { diving = false, StartFight = function() end, StartDrift = function() end }
    _G.Anim = { PlayClip = function() end }

    dofile('client/minigame.lua')
    dofile('client/encounter.lua')
end

local OPENING = { phaseId = 1, phase = 'LEFT_RUN', cue = 'LEFT_RUN',
    telegraphIn = 0, windowOpensIn = 800, windowClosesIn = 2000,
    staminaPct = 100, linePct = 100, misses = 0, maxMisses = 5 }

-- A server that hooks successfully and accepts every action.
local function happyServer(extra)
    local seq = 0
    return function(name)
        if name == 'zfishing:hook' then
            return { ok = true, challengeId = 'sess-1#42', encounter = OPENING }
        elseif name == 'zfishing:encounter:act' then
            seq = seq + 1
            if extra and extra.outcomeAt == seq then
                return { ok = true, seq = seq, state = OPENING, outcome = extra.outcome }
            end
            return { ok = true, seq = seq, state = OPENING }
        elseif name == 'zfishing:claim' then
            return { ok = true, fish = { label = 'Pike', weight = 6.0, quality = 3 } }
        end
        return { ok = true }
    end
end

local function biteAndHook(encounter)
    -- The bite handler blocks on the hook QTE; arm SPACE before dispatching it.
    _G.__PRESS(22)
    H.NETEVENTS['zfishing:bite']({ encounter = encounter, difficulty = 2, hookWindow = 1500 })
end

local function actCalls()
    local n = 0
    for _, s in ipairs(sent) do if s.name == 'zfishing:encounter:act' then n = n + 1 end end
    return n
end

local function nuiWith(action)
    for _, m in ipairs(nui) do if m.action == action then return m end end
    return nil
end

test('B1 an encounter bite never enters the legacy minigame', function()
    loadBridge(happyServer())
    biteAndHook('counter_pull')
    falsy(nuiWith('reel'), 'the legacy reel view must not open for an encounter session')
    truthy(nuiWith('encounter'))
end)

test('B2 a legacy bite never enters the encounter bridge', function()
    loadBridge(happyServer())
    biteAndHook('legacy_tension')
    falsy(nuiWith('encounter'), 'the encounter view must not open for a legacy session')
end)

test('B3 the hook answer opens the authoritative encounter view', function()
    loadBridge(happyServer())
    biteAndHook('counter_pull')
    local msg = nuiWith('encounter')
    truthy(msg)
    equal(msg.type, 'counter_pull')
    equal(msg.state.phaseId, 1)
    equal(msg.state.windowOpensIn, 800, 'durations pass through untouched')
end)

test('B4 the first accepted input submits seq 1, the next submits seq 2', function()
    loadBridge(happyServer())
    biteAndHook('counter_pull')
    H.CB['nui:encounterAction']({ action = 'advance' })
    H.CB['nui:encounterAction']({ action = 'advance' })
    local seqs = {}
    for _, s in ipairs(sent) do
        if s.name == 'zfishing:encounter:act' then seqs[#seqs + 1] = s.args[3] end
    end
    equal(seqs[1], 1); equal(seqs[2], 2)
end)

test('B5 no action payload carries a timing value or an encounter type', function()
    loadBridge(happyServer())
    biteAndHook('counter_pull')
    H.CB['nui:encounterAction']({ action = 'advance', atMs = 1234, type = 'sonar_strike' })
    for _, s in ipairs(sent) do
        if s.name == 'zfishing:encounter:act' then
            equal(#s.args, 4, 'sessionId, challengeId, seq, action -- and nothing else')
            equal(s.args[4], 'advance')
        end
    end
end)

test('B6 a terminal outcome stops input polling and settles once', function()
    loadBridge(happyServer({ outcomeAt = 1, outcome = 'success' }))
    biteAndHook('counter_pull')
    H.CB['nui:encounterAction']({ action = 'advance' })

    local claims = 0
    for _, s in ipairs(sent) do if s.name == 'zfishing:claim' then claims = claims + 1 end end
    equal(claims, 1, 'the client settles exactly once, without waiting on the NUI')

    local before = actCalls()
    H.CB['nui:encounterAction']({ action = 'advance' })
    equal(actCalls(), before, 'no further action is accepted after the fight ends')
end)

test('B7 settlement does not need the NUI to ask for it', function()
    loadBridge(happyServer({ outcomeAt = 1, outcome = 'snap' }))
    biteAndHook('counter_pull')
    H.CB['nui:encounterAction']({ action = 'advance' })
    local claimed = false
    for _, s in ipairs(sent) do if s.name == 'zfishing:claim' then claimed = true end end
    truthy(claimed, 'encounterClosed was never called and the catch still settled')
    truthy(H.CB['nui:encounterClosed'], 'the presentation-close callback still exists')
end)

test('B8 a lost fight reports the SERVER outcome to the player', function()
    loadBridge(function(name)
        if name == 'zfishing:hook' then
            return { ok = true, challengeId = 'sess-1#42', encounter = OPENING }
        elseif name == 'zfishing:encounter:act' then
            return { ok = true, seq = 1, state = OPENING, outcome = 'snap' }
        elseif name == 'zfishing:claim' then
            return { ok = true, fish = nil, outcome = 'snap' }
        end
        return { ok = true }
    end)
    biteAndHook('counter_pull')
    H.CB['nui:encounterAction']({ action = 'advance' })
    local last = ended[#ended]
    truthy(last)
    equal(last.key, 'line_broke', 'a server-decided snap must read as a snapped line')
end)

test('B9 teardown resets the bridge so a stale action goes nowhere', function()
    loadBridge(happyServer())
    biteAndHook('counter_pull')
    H.EVENTS['zfishing:client:end']()
    local before = actCalls()
    H.CB['nui:encounterAction']({ action = 'advance' })
    equal(actCalls(), before, 'a torn-down bridge sends nothing')
end)

test('B10 a hook the server refuses ends the session cleanly', function()
    loadBridge(function(name)
        if name == 'zfishing:hook' then return { ok = false, reason = 'too_slow' } end
        return { ok = true }
    end)
    biteAndHook('counter_pull')
    equal(actCalls(), 0)
    truthy(#ended > 0, 'the player is told the fish got away')
end)

H.run()
```

Add the script to `tests/package.json`:

```json
    "test:client-encounter": "node luarun.mjs tests/client_encounter.test.lua",
```

and append ` && npm run test:client-encounter` to `test:all`.

- [ ] **Step 4: Run the bridge tests**

```bash
node tests/luarun.mjs tests/client_encounter.test.lua
```

Expected: ten `ok -` lines then `10 tests passed`.

`settle()` calls `Wait(700)`; `H.installHost` stubs `Wait` as a no-op, so the tests run synchronously. If B6 or B7 report zero claims, check that the stub is in place before `client/encounter.lua` is loaded.

- [ ] **Step 5: Re-run every suite**

```bash
cd tests && npm run test:all
```

Expected: 11 suites, 221 tests, exit 0.

- [ ] **Step 6: Commit**

```bash
git add client/encounter.lua client/minigame.lua tests/client_encounter.test.lua tests/package.json
git commit -m "feat: orchestrate the counter-pull fight from the client bridge"
```

---

## Task 4: The NUI

**Files:**
- Create: `web/src/encounters/types.ts`
- Create: `web/src/encounters/EncounterHost.tsx`
- Create: `web/src/encounters/CounterPull.tsx`
- Modify: `web/src/App.tsx`
- Modify: `web/src/style.css`

- [ ] **Step 1: Define the payload types**

Create `web/src/encounters/types.ts`:

```typescript
export type EncounterType = 'counter_pull' | 'fish_mindgame' | 'sonar_strike'
export type Outcome = 'success' | 'escape' | 'snap' | 'timeout'

export type CounterPullPhase = 'LEFT_RUN' | 'RIGHT_RUN' | 'DIVE' | 'FATIGUED' | 'LANDING'

// Exactly what server/encounter_counter_pull.lua's M.render(enc, now) returns.
//
// Every time value is a DURATION from the moment the server built this payload, never
// a timestamp: the server's clock and this page's clock share no origin. The component
// anchors them to its own Date.now() once, keyed on phaseId.
//
// Note what is NOT here: the required counter. The player reads it off the cue.
export type CounterPullState = {
  /** increments on every authoritative transition, including a repeat of the same phase */
  phaseId: number
  phase: CounterPullPhase
  cue: CounterPullPhase
  nextCue?: CounterPullPhase
  telegraphIn: number
  windowOpensIn: number
  windowClosesIn: number
  /** present only when the fish is faking */
  switchIn?: number
  staminaPct: number
  linePct: number
  misses: number
  maxMisses: number
  reelsLeft?: number
}

export type EncounterMessage = {
  type: EncounterType
  difficulty: number
  state: CounterPullState
  startedAt: number
}
```

- [ ] **Step 2: Write the shared host**

Create `web/src/encounters/EncounterHost.tsx`:

```tsx
import { useEffect, useState } from 'react'
import { useNuiEvent } from '../hooks/useNui'
import CounterPull from './CounterPull'
import type { CounterPullState, EncounterMessage, Outcome } from './types'

// One shell for every encounter, so the three of them read as one product: same panel
// material, same typography, same success/failure language. Only the fight differs.
export default function EncounterHost({ msg }: { msg: EncounterMessage }) {
  const [state, setState] = useState<CounterPullState>(msg.state)
  const [outcome, setOutcome] = useState<Outcome | null>(null)

  // React state moves on a TRANSITION, never per frame. The per-frame work lives in
  // the child's requestAnimationFrame loop and writes straight to a DOM node.
  useNuiEvent((m) => {
    if (m.action !== 'encounterState') return
    if (m.state) setState(m.state)
    if (m.outcome) setOutcome(m.outcome)
  })

  useEffect(() => { setState(msg.state); setOutcome(null) }, [msg.startedAt])

  if (msg.type === 'counter_pull') {
    return <CounterPull state={state} outcome={outcome} />
  }
  return null
}
```

- [ ] **Step 3: Write the counter-pull UI**

Create `web/src/encounters/CounterPull.tsx`:

```tsx
import type { CSSProperties } from 'react'
import { useEffect, useMemo, useRef, useState } from 'react'
import { fetchNui } from '../hooks/useNui'
import { t } from '../i18n'
import Keycap from '../components/Keycap'
import type { CounterPullPhase, CounterPullState, Outcome } from './types'

// Direction, glyph and key per phase. Every cue is carried by shape, motion and text as
// well as position -- never by colour alone.
const CUES: Record<CounterPullPhase, { glyph: string; key: string; label: string; dir: -1 | 0 | 1 }> = {
  LEFT_RUN:  { glyph: '◀', key: 'D',     label: 'enc_cp_left',  dir: -1 },
  RIGHT_RUN: { glyph: '▶', key: 'A',     label: 'enc_cp_right', dir: 1 },
  DIVE:      { glyph: '▼', key: 'S',     label: 'enc_cp_dive',  dir: 0 },
  FATIGUED:  { glyph: '⟳', key: 'SPACE', label: 'enc_cp_reel',  dir: 0 },
  LANDING:   { glyph: '⤒', key: 'SPACE', label: 'enc_cp_land',  dir: 0 },
}

export default function CounterPull(
  { state, outcome }: { state: CounterPullState; outcome: Outcome | null }
) {
  // One deterministic anchoring per authoritative phase, keyed on phaseId -- a phase can
  // repeat with an identical name and identical durations, and a ref mutated inside an
  // effect would leave the other effects reading the previous anchor.
  const timing = useMemo(() => {
    const receivedAt = Date.now()
    return {
      opensAt: receivedAt + state.windowOpensIn,
      closesAt: receivedAt + state.windowClosesIn,
      switchAt: state.switchIn === undefined ? undefined : receivedAt + state.switchIn,
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [state.phaseId])

  const [shown, setShown] = useState<CounterPullPhase>(state.cue)
  const barRef = useRef<HTMLDivElement | null>(null)

  useEffect(() => { setShown(state.cue) }, [state.phaseId, state.cue])

  // The only per-frame work, and it writes straight to the DOM node. Going through
  // React here would re-render the whole panel sixty times a second to move one bar.
  useEffect(() => {
    let raf = 0
    const tick = () => {
      const el = barRef.current
      if (el) {
        const span = Math.max(1, timing.closesAt - timing.opensAt)
        const p = Math.min(1, Math.max(0, (Date.now() - timing.opensAt) / span))
        el.style.width = `${(1 - p) * 100}%`
      }
      raf = requestAnimationFrame(tick)
    }
    raf = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(raf)
  }, [timing])

  // The fish visibly changes its mind. A state change, not a frame update.
  useEffect(() => {
    if (timing.switchAt === undefined || !state.nextCue) return
    const id = setTimeout(() => setShown(state.nextCue as CounterPullPhase),
      Math.max(0, timing.switchAt - Date.now()))
    return () => clearTimeout(id)
  }, [timing, state.nextCue])

  // Our window expired and the player did nothing. Tell the server once per phase; it
  // decides what that means, and refuses this outright if its own deadline has not
  // passed. Re-armed by phaseId, so a repeated phase advances too.
  useEffect(() => {
    if (outcome) return
    const id = setTimeout(() => {
      fetchNui('encounterAction', { action: 'advance' })
    }, Math.max(0, timing.closesAt - Date.now()) + 300)
    return () => clearTimeout(id)
  }, [timing, outcome])

  // Presentation close only. The client already settled the catch; this just reports
  // that the ending has played.
  useEffect(() => {
    if (!outcome) return
    const id = setTimeout(() => fetchNui('encounterClosed', {}), 700)
    return () => clearTimeout(id)
  }, [outcome])

  const cue = CUES[shown]
  const danger = state.linePct <= 33 || state.misses >= state.maxMisses - 1

  return (
    <div className={`hud-panel enc-panel${danger ? ' hud-panel--danger' : ''}`}>
      <div className="panel-title">{t('enc_cp_title')}</div>

      <div className="enc-stage" style={{ '--lean': String(cue.dir) } as CSSProperties}>
        <div className={`enc-cue enc-cue--${shown.toLowerCase()}`} role="status">
          <span className="enc-glyph" aria-hidden="true">{cue.glyph}</span>
          <span className="enc-cue-text">{t(cue.label)}</span>
        </div>
        <div className="enc-key"><Keycap label={cue.key} variant="urgent" /></div>
      </div>

      <div className="bar-track enc-window"><div className="bar-fill enc-window-fill" ref={barRef} /></div>

      <div className="bar-row">
        <div className="bar-label">{t('enc_stamina')}</div>
        <div className="bar-caption">{state.staminaPct}%</div>
      </div>
      <div className="bar-track"><div className="bar-fill energy-fill" style={{ width: `${state.staminaPct}%` }} /></div>

      <div className="bar-row">
        <div className="bar-label">{t('enc_line')}</div>
        <div className="bar-caption">{state.misses}/{state.maxMisses}</div>
      </div>
      <div className="bar-track"><div className="bar-fill enc-line-fill" style={{ width: `${state.linePct}%` }} /></div>

      {outcome && <div className="enc-outcome">{t(`enc_outcome_${outcome}`)}</div>}
    </div>
  )
}
```

- [ ] **Step 4: Route the view**

In `web/src/App.tsx`, add `'encounter'` to the `View` union, import `EncounterHost`, add the message cases:

```tsx
      case 'encounter':
        setView('encounter'); setData(msg); break
      case 'encounterState':
        break   // EncounterHost subscribes to this itself
```

and the render branch:

```tsx
          {view === 'encounter' && (
            <EncounterHost key={data.startedAt ?? 'enc'} msg={data} />
          )}
```

- [ ] **Step 5: Add the styles**

In `web/src/style.css`, next to the existing `.reel-panel` rules, append:

```css
/* Encounter shell. Inherits the panel material, rail colour and radius from .hud-panel
   so the encounters read as one product with the rest of the HUD. */
.enc-panel { min-width: 22vw; }

/* The cue leans along X by its own direction, so LEFT/RIGHT/DIVE are distinguishable
   from motion and glyph alone -- never from colour. */
.enc-stage {
  position: relative;
  display: flex; flex-direction: column; align-items: center; gap: 0.4vh;
  padding: 0.6vh 0 0.9vh;
}
.enc-cue {
  display: flex; align-items: center; gap: 0.6vw;
  transform: translateX(calc(var(--lean) * 2.4vw));
  transition: transform 140ms cubic-bezier(.2,.8,.2,1);
}
.enc-glyph { font-size: 2.6vh; line-height: 1; }
.enc-cue-text { font-size: 1.35vh; letter-spacing: .04em; text-transform: uppercase; }
.enc-key { margin-top: 0.2vh; }

/* Shrinks to nothing as the counter window closes. Width is written by the component's
   rAF loop straight to this node -- no React render is involved. */
.enc-window { height: 0.5vh; }
.enc-window-fill { background: var(--rail); width: 100%; transition: none; }

.enc-line-fill { background: var(--warn); }

.enc-outcome {
  margin-top: 0.7vh; text-align: center;
  font-size: 1.5vh; letter-spacing: .06em; text-transform: uppercase;
}

.enc-cue--left_run .enc-glyph,
.enc-cue--right_run .enc-glyph { animation: enc-nudge 520ms ease-in-out infinite; }
.enc-cue--dive .enc-glyph { animation: enc-sink 620ms ease-in-out infinite; }
@keyframes enc-nudge { 0%,100% { transform: translateX(0); } 50% { transform: translateX(0.5vw); } }
@keyframes enc-sink  { 0%,100% { transform: translateY(0); } 50% { transform: translateY(0.5vh); } }

@media (prefers-reduced-motion: reduce) {
  .enc-cue { transition: none; }
  .enc-cue .enc-glyph { animation: none; }
}
```

- [ ] **Step 6: Type-check**

```bash
cd web && npx tsc --noEmit
```

Expected: no errors.

- [ ] **Step 7: Commit**

```bash
git add web/src/encounters web/src/App.tsx web/src/style.css
git commit -m "feat: render the counter-pull fight in the NUI"
```

---

## Task 5: Web tests and locale strings

**Files:**
- Create: `web/src/encounters/__tests__/CounterPull.test.tsx`
- Modify: `locales/en.json`, `locales/th.json`

- [ ] **Step 1: Add the strings**

Add to **both** locale files:

| key | en | th |
| --- | --- | --- |
| `enc_cp_title` | `Counter the fish` | `สู้กับปลา` |
| `enc_cp_left` | `Running left — pull right` | `ปลาวิ่งซ้าย — ดึงขวา` |
| `enc_cp_right` | `Running right — pull left` | `ปลาวิ่งขวา — ดึงซ้าย` |
| `enc_cp_dive` | `Diving — brace` | `ปลาดำ — ยันไว้` |
| `enc_cp_reel` | `Tired — reel!` | `ปลาหมดแรง — รีล!` |
| `enc_cp_land` | `Land it!` | `ดึงขึ้นเลย!` |
| `enc_stamina` | `Fish stamina` | `แรงปลา` |
| `enc_line` | `Mistakes` | `พลาด` |
| `enc_outcome_success` | `Landed!` | `ได้ปลาแล้ว!` |
| `enc_outcome_escape` | `It got away` | `ปลาหลุด` |
| `enc_outcome_snap` | `Your line snapped` | `สายขาด` |
| `enc_outcome_timeout` | `Out of time` | `หมดเวลา` |

- [ ] **Step 2: Write the component tests**

Create `web/src/encounters/__tests__/CounterPull.test.tsx`:

```tsx
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render, act } from '@testing-library/react'
import CounterPull from '../CounterPull'
import type { CounterPullState } from '../types'

const posted: { event: string; data: any }[] = []
vi.mock('../../hooks/useNui', () => ({
  fetchNui: (event: string, data?: unknown) => {
    posted.push({ event, data })
    return Promise.resolve({})
  },
}))

const base = (over: Partial<CounterPullState> = {}): CounterPullState => ({
  phaseId: 1, phase: 'LEFT_RUN', cue: 'LEFT_RUN',
  telegraphIn: 0, windowOpensIn: 800, windowClosesIn: 2000,
  staminaPct: 100, linePct: 100, misses: 0, maxMisses: 5,
  ...over,
})

beforeEach(() => { posted.length = 0; vi.useFakeTimers() })
afterEach(() => { vi.useRealTimers() })

describe('CounterPull', () => {
  it('draws a distinct glyph, text and key for every phase', () => {
    const seen = new Set<string>()
    for (const phase of ['LEFT_RUN', 'RIGHT_RUN', 'DIVE', 'FATIGUED', 'LANDING'] as const) {
      const { unmount } = render(
        <CounterPull state={base({ phase, cue: phase })} outcome={null} />
      )
      const cue = document.querySelector('.enc-cue') as HTMLElement
      expect(cue.className).toContain(phase.toLowerCase())
      const glyph = cue.querySelector('.enc-glyph')!.textContent!
      expect(seen.has(glyph)).toBe(false)   // no two phases share a glyph
      seen.add(glyph)
      expect(cue.querySelector('.enc-cue-text')!.textContent!.length).toBeGreaterThan(0)
      expect(document.querySelector('.keycap')).not.toBeNull()
      unmount()
    }
  })

  it('shows the decoy first and flips to the real cue at switchIn', () => {
    render(
      <CounterPull
        state={base({ phase: 'DIVE', cue: 'LEFT_RUN', nextCue: 'DIVE', switchIn: 600 })}
        outcome={null}
      />
    )
    expect(document.querySelector('.enc-cue')!.className).toContain('left_run')
    act(() => { vi.advanceTimersByTime(650) })
    expect(document.querySelector('.enc-cue')!.className).toContain('dive')
  })

  it('carries the danger treatment when the line is nearly gone', () => {
    const { container, rerender } = render(
      <CounterPull state={base({ linePct: 90 })} outcome={null} />
    )
    expect(container.querySelector('.hud-panel--danger')).toBeNull()
    rerender(<CounterPull state={base({ phaseId: 2, linePct: 30 })} outcome={null} />)
    expect(container.querySelector('.hud-panel--danger')).not.toBeNull()
  })

  it('posts advance exactly once after the window closes', () => {
    render(<CounterPull state={base()} outcome={null} />)
    act(() => { vi.advanceTimersByTime(1500) })
    expect(posted.filter((p) => p.data?.action === 'advance')).toHaveLength(0)
    act(() => { vi.advanceTimersByTime(1500) })
    expect(posted.filter((p) => p.data?.action === 'advance')).toHaveLength(1)
    act(() => { vi.advanceTimersByTime(5000) })
    expect(posted.filter((p) => p.data?.action === 'advance')).toHaveLength(1)
  })

  it('re-arms advance for a repeated phase with identical timings', () => {
    // The case phaseId exists for: same name, same durations, different phase.
    const { rerender } = render(<CounterPull state={base()} outcome={null} />)
    act(() => { vi.advanceTimersByTime(2400) })
    expect(posted.filter((p) => p.data?.action === 'advance')).toHaveLength(1)

    rerender(<CounterPull state={base({ phaseId: 2 })} outcome={null} />)
    act(() => { vi.advanceTimersByTime(2400) })
    expect(posted.filter((p) => p.data?.action === 'advance')).toHaveLength(2)
  })

  it('renders the outcome and closes the presentation', () => {
    render(<CounterPull state={base()} outcome="snap" />)
    expect(document.querySelector('.enc-outcome')!.textContent!.length).toBeGreaterThan(0)
    act(() => { vi.advanceTimersByTime(800) })
    expect(posted.some((p) => p.event === 'encounterClosed')).toBe(true)
    expect(posted.some((p) => p.event === 'encounterDone')).toBe(false)
  })

  it('never sends the server a timing value it could trust', () => {
    render(<CounterPull state={base()} outcome={null} />)
    act(() => { vi.advanceTimersByTime(3000) })
    for (const p of posted) {
      const keys = Object.keys(p.data ?? {})
      expect(keys.filter((k) => /At$|In$|ms$|time/i.test(k))).toHaveLength(0)
    }
  })
})
```

- [ ] **Step 3: Run the web suite**

```bash
cd web && npm test
```

Expected: 71 existing plus 7 new, all passing.

- [ ] **Step 4: Commit**

```bash
git add web/src/encounters/__tests__ locales/en.json locales/th.json
git commit -m "test: cover the counter-pull UI state transitions"
```

---

## Task 6: Wire, build and document

**Files:**
- Modify: `fxmanifest.lua`
- Rebuild and commit: `web/dist`
- Modify: `docs/ARCHITECTURE.md`, `docs/testing/zfishing-live-e2e-checklist.md`

- [ ] **Step 1: Load the new files**

In `fxmanifest.lua`, add `'server/encounter_counter_pull.lua',` to `server_scripts` immediately after `'server/encounter.lua',`, and `'client/encounter.lua',` to `client_scripts` immediately after `'client/minigame.lua',`.

- [ ] **Step 2: Rebuild the NUI bundle**

```bash
cd web && npm run build
```

`web/dist` is committed to this repository. Without this the running resource has the new Lua and none of the UI, and a forced counter-pull leaves the player staring at nothing.

- [ ] **Step 3: Re-run everything**

```bash
cd tests && npm run test:all
```

Expected: 11 suites, 221 tests, exit 0.

```bash
cd web && npm test
```

The Lua hash-tree snapshot in `bundleRebuildPreservation.test.ts` will fail — Lua changed deliberately. Re-record it, which is what every Lua-touching commit in this repo has done:

```bash
cd web && npx vitest --run -u src/__tests__/bundleRebuildPreservation.test.ts
```

Then re-run `npm test` and expect everything green.

- [ ] **Step 4: Document**

Add `### 12.10 Counter-Pull Fight` to `docs/ARCHITECTURE.md`: the five phases and their counters; the 250ms grace and why; the tier table; `phaseId` and what breaks without it; `countersSinceFatigue` and the fumbled-landing case it fixes; the two failure clocks (line damage, miss count) and why both exist; the relative-duration render contract and the clock-domain reason behind it; the client-orchestrates-settlement boundary; and the statement that the render payload never carries `required`.

Add a change-history entry under `## 13` recording what Phase B did **not** ship: directional world feedback, deferred to Phase G.

Add an "Encounter system" section to `docs/testing/zfishing-live-e2e-checklist.md` covering: FORCED counter-pull at tier 1 and tier 5; each of the four counters and the fatigue reel; a fake telegraph at tier 3+; a deliberate line snap; a deliberate walk-away timeout; a fumbled landing followed by a normally resumed fight; an admin changing the mode mid-fight and the fight not changing; two players in counter-pull simultaneously; and resmon at idle, one fight, and several. Leave every box unticked — nobody has run them.

- [ ] **Step 5: Commit**

```bash
git add fxmanifest.lua web/dist docs/ARCHITECTURE.md docs/testing/zfishing-live-e2e-checklist.md web/src/__tests__/__snapshots__/bundleRebuildPreservation.test.ts.snap
git commit -m "feat: ship the counter-pull encounter end to end"
```

---

## Phase B completion checklist

```bash
cd tests && npm run test:all
cd web && npm test && npx tsc --noEmit
```

Expected state at the end of Phase B:

- `Encounter.Playable('counter_pull')` is true, so an admin setting FORCED to counter-pull gets the real fight rather than a downgrade to legacy.
- No fish resolves to counter-pull on its own — no `encounter` field ships until Phase F, so DEFAULT still means the legacy fight for everyone.
- `fish_mindgame` and `sonar_strike` still downgrade to legacy.
- Live behaviour is **unverified**: nothing in this phase has been run inside FiveM.

## Known limitations to carry into the completion report

**Fake telegraphs are advisory against a modified client.** `nextCue` ships in the same payload as `cue`, because the NUI has to draw the flip and a round trip at that moment would cost exactly the reaction time the mechanic tests. A modified client can read the real direction up front and ignore fakes. It gains immunity to a tier-3+ flourish, not free wins: the counter still has to be the right key inside a server-owned window.

**Directional world feedback is not implemented.** Rod lean, bobber displacement and splash by fish direction are deferred to Phase G, as stated at the top of this plan. Phase B's fight reads through the panel, sound and the existing fishing animation only.
