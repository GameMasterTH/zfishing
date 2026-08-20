# Counter-Pull Fight (Phase B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `counter_pull` — the first real encounter — end to end: a server-owned state machine, a client bridge, a NUI that reads as part of the world rather than a wall of text, and the tests that hold all three honest.

**Architecture:** `server/encounter_counter_pull.lua` implements the module contract Phase A defined and registers itself. The server owns the fish's direction, the counter window, stamina, line health and the phase clock; the client sends one discrete action per counter and renders whatever authoritative state comes back. `client/encounter.lua` is a bridge with an input-polling thread and nothing else — no simulation. Rendering animates inside `requestAnimationFrame`; React state changes only on a phase transition.

**Tech Stack:** Lua 5.4 (FiveM `cerulean`), ox_lib callbacks, wasmoon test harness, React 18 + Vitest.

**Spec:** `docs/superpowers/specs/2026-08-20-zfishing-encounter-system-design.md` (sections 4 and 12 of `docs/ARCHITECTURE.md`)

**Prerequisite:** Phase A, merged to `main` at `245fabd`. 198 Lua tests and 71 web tests pass on that tree.

## Global Constraints

- **The module contract is fixed by Phase A** and is quoted verbatim in Task 1. Do not redesign it.
- **The server owns every fight decision.** The action payload never carries a timing value the server trusts, and no render payload ever contains `required`.
- **Lua files stay flat** in `client/`, `server/`, `shared/`, `tests/` — `tests/luarun.mjs` mounts those non-recursively.
- **`legacy_tension` stays untouched.** `client/minigame.lua` keeps its existing bite/reel path; the new bridge runs only when `data.encounter ~= 'legacy_tension'`.
- **No per-frame traffic.** No Lua→NUI message per frame, no client→server event per frame, no React state update per frame.
- **Every cue carries more than colour** — direction, icon shape, motion and text.
- **Baseline to preserve:** `cd tests && npm run test:all` reports 9 suites totalling 198 tests; `npm --prefix web test` reports 71. Both must still pass at the end of every task.
- Stable ids verbatim: encounter `counter_pull`; actions `left`, `right`, `brace`, `reel`, plus the universal `advance`; phases `LEFT_RUN`, `RIGHT_RUN`, `DIVE`, `FATIGUED`, `LANDING`.

---

## File Structure

| File | Responsibility | Task |
| --- | --- | --- |
| `server/encounter_counter_pull.lua` | **Create.** Tier table, phase machine, action scoring, render payload. Registers itself. | 1 |
| `server/encounter.lua` | **Modify.** Two contract refinements: `ctx.now` for `build`, and `Begin` returning the initial render payload. | 1 |
| `server/session.lua` | **Modify.** `zfishing:hook` returns the initial encounter render alongside the challenge id. | 1 |
| `tests/encounter_counter_pull.test.lua` | **Create.** The PART 26 list, minus what the contract suite already covers. | 1 |
| `client/encounter.lua` | **Create.** Bite routing, input polling, action dispatch, teardown. Bridge only. | 2 |
| `client/minigame.lua` | **Modify.** Bail out of the legacy path when the session is an encounter. | 2 |
| `web/src/encounters/types.ts` | **Create.** Shared payload types. | 3 |
| `web/src/encounters/EncounterHost.tsx` | **Create.** Shared shell, dispatch by encounter type. | 3 |
| `web/src/encounters/CounterPull.tsx` | **Create.** The directional fight UI. | 3 |
| `web/src/App.tsx` | **Modify.** Route the `encounter` view. | 3 |
| `web/src/style.css` | **Modify.** Encounter classes, reusing the existing HUD language. | 3 |
| `web/src/encounters/__tests__/CounterPull.test.tsx` | **Create.** State-transition coverage. | 4 |
| `locales/en.json`, `locales/th.json` | **Modify.** Encounter UI strings. | 4 |
| `fxmanifest.lua` | **Modify.** Load the module and the bridge. | 5 |
| `web/dist` | **Rebuild and commit.** Without it the running resource has no encounter UI. | 5 |
| `docs/ARCHITECTURE.md` | **Modify.** Counter-pull subsection and a change-history entry. | 5 |

---

## Task 1: The counter-pull module

**Files:**
- Create: `server/encounter_counter_pull.lua`
- Modify: `server/encounter.lua` (the `Encounter.Begin` body)
- Modify: `server/session.lua` (the `zfishing:hook` tail)
- Create: `tests/encounter_counter_pull.test.lua`
- Modify: `tests/package.json`

**Interfaces:**
- Consumes, verbatim from Phase A (`server/encounter.lua`):
  - `Encounter.Register(id, mod)` — errors on an id outside `Encounters.IDS`.
  - `mod.actions` — set of valid action names. `advance` is handled by the dispatcher and must NOT appear here.
  - `mod.build(ctx) -> state, estimatedFightMs` where `ctx = { difficulty, seed, fish, gear, now }`. `gear = { lineRating, reelDrain, greenZone }`.
  - `mod.act(enc, action, now) -> { render, outcome, value }`. The module writes `enc.state.deadline`; the dispatcher reads it to validate `advance`. `outcome` must be `nil` or one of `success` / `escape` / `snap` / `timeout`. `value` is 0..1 and feeds `Encounter.PerfScore`.
  - `Encounters.LineMult(rating)`, `Encounters.TierFor`, `ZUtil.clamp`.
- Produces: `mod.render(enc) -> table`, called by `Encounter.Begin` for the opening frame and by `act` for every later one. `zfishing:hook` answers `{ ok = true, challengeId = <string>, encounter = <render> }`.

- [ ] **Step 1: Write the failing module tests**

Create `tests/encounter_counter_pull.test.lua`:

```lua
-- Counter-Pull Fight. Run from the resource root:
--   node tests/luarun.mjs tests/encounter_counter_pull.test.lua
--
-- Sequencing, replay, stale challenge, wrong session and disconnect are covered once
-- for every encounter in tests/encounter_action.test.lua -- this suite is about the
-- fight itself, plus the two places where a rejected action must leave the phase alone.

dofile('tests/harness.lua')
local test, equal, truthy, falsy = H.test, H.equal, H.truthy, H.falsy

local FISH = { species = 'pike', label = 'Pike', weight = 6.0, quality = 3, rarity = 'uncommon',
    behavior = 'erratic', biteDelay = 100, hookWindow = 1500, tensionDiff = 1.15,
    fishEnergy = 50, xp = 24, price = 18, difficulty = 2 }

-- cast -> bite -> hook, leaving an armed counter-pull challenge.
local function start(opts)
    opts = opts or {}
    local fish = H.deepcopy(FISH)
    if opts.difficulty then fish.difficulty = opts.difficulty end
    if opts.behavior then fish.behavior = opts.behavior end
    local calls = H.loadSession({ fish = fish, encounterMode = 'forced',
                                  forcedEncounter = 'counter_pull', rig = opts.rig })
    dofile('server/encounter_counter_pull.lua')
    local cast = H.CB['zfishing:cast'](5, 0.5, opts.rig and 1 or nil)
    truthy(cast.ok, tostring(cast.reason))
    H.fireLatestTimer()
    local hook = H.CB['zfishing:hook'](5, cast.sessionId)
    truthy(hook.ok)
    truthy(hook.challengeId)
    return { sid = cast.sessionId, cid = hook.challengeId, open = hook.encounter, calls = calls }
end

local COUNTER = { LEFT_RUN = 'right', RIGHT_RUN = 'left', DIVE = 'brace' }

-- Plays the correct answer for whatever the server just told us, at a moment inside
-- the counter window. Returns the server's reply.
local function answerCorrectly(g, seq, render)
    local r = render or g.last
    _G.__NOW = r.windowOpensAt + 50
    local action = r.phase == 'FATIGUED' and 'reel'
        or r.phase == 'LANDING' and 'reel'
        or COUNTER[r.phase]
    local res = H.CB['zfishing:encounter:act'](5, g.sid, g.cid, seq, action)
    g.last = res.state or r
    return res
end

test('P1 the hook answer opens the fight with a renderable phase', function()
    local g = start()
    truthy(g.open, 'the client has to be given something to draw before the first action')
    truthy(COUNTER[g.open.phase], 'the opening phase is one of the three run states')
    truthy(g.open.windowOpensAt > g.open.telegraphAt, 'the telegraph precedes the window')
    equal(g.open.required, nil, 'the render payload must never carry the answer')
    truthy(g.open.staminaPct); truthy(g.open.linePct)
end)

test('P2 a correct counter drains stamina and arms the next phase', function()
    local g = start()
    g.last = g.open
    local before = g.open.staminaPct
    local res = answerCorrectly(g, 1)
    truthy(res.ok)
    equal(res.outcome, nil)
    truthy(res.state.staminaPct < before, 'a correct counter must cost the fish stamina')
    equal(res.state.linePct, g.open.linePct, 'and must not damage the line')
    equal(res.state.misses, 0)
end)

test('P3 a wrong counter damages the line and counts a miss', function()
    local g = start()
    local wrong = g.open.phase == 'DIVE' and 'left' or 'brace'
    _G.__NOW = g.open.windowOpensAt + 50
    local res = H.CB['zfishing:encounter:act'](5, g.sid, g.cid, 1, wrong)
    truthy(res.ok, 'a wrong answer is a legal action, not a protocol error')
    equal(res.state.misses, 1)
    truthy(res.state.linePct < g.open.linePct)
end)

test('P4 the right key at the wrong moment is still a miss', function()
    local g = start()
    local right = COUNTER[g.open.phase]
    _G.__NOW = g.open.telegraphAt          -- window has not opened yet
    local early = H.CB['zfishing:encounter:act'](5, g.sid, g.cid, 1, right)
    equal(early.state.misses, 1, 'countering before the fish commits is a miss')

    local g2 = start()
    local right2 = COUNTER[g2.open.phase]
    _G.__NOW = g2.open.windowClosesAt + 5000
    local late = H.CB['zfishing:encounter:act'](5, g2.sid, g2.cid, 1, right2)
    equal(late.state.misses, 1, 'countering after the window is a miss')
end)

test('P5 reeling during a run is a miss; reeling during fatigue is the point', function()
    local g = start()
    _G.__NOW = g.open.windowOpensAt + 50
    equal(H.CB['zfishing:encounter:act'](5, g.sid, g.cid, 1, 'reel').state.misses, 1,
        'you cannot reel a fish that is running')

    -- drive correct counters until the fish tires
    local g2 = start()
    g2.last = g2.open
    local seq, fatigued = 1, nil
    while seq <= 12 and not fatigued do
        local res = answerCorrectly(g2, seq)
        seq = seq + 1
        if res.state and res.state.phase == 'FATIGUED' then fatigued = res.state end
    end
    truthy(fatigued, 'enough correct counters must tire the fish out')
    truthy(fatigued.reelsLeft and fatigued.reelsLeft > 0)
    local before = fatigued.staminaPct
    _G.__NOW = fatigued.windowOpensAt + 50
    local r = H.CB['zfishing:encounter:act'](5, g2.sid, g2.cid, seq, 'reel')
    truthy(r.ok)
    truthy(r.state.staminaPct < before, 'reeling a fatigued fish takes a bigger bite of its stamina')
end)

test('P6 advance after the window expires is scored as a miss by the SERVER', function()
    local g = start()
    _G.__NOW = g.open.windowClosesAt + 1000
    local res = H.CB['zfishing:encounter:act'](5, g.sid, g.cid, 1, 'advance')
    truthy(res.ok)
    equal(res.state.misses, 1)
    truthy(res.state.phase, 'the fight moves on rather than stalling')
end)

test('P7 line damage ends the fight as a snap', function()
    local g = start({ difficulty = 5 })
    local seq, outcome = 1, nil
    while seq <= 40 and not outcome do
        _G.__NOW = _G.__NOW + 60000        -- never answer; every window expires
        local res = H.CB['zfishing:encounter:act'](5, g.sid, g.cid, seq, 'advance')
        outcome = res.outcome
        seq = seq + 1
        if not res.ok and res.reason == 'encounter_over' then outcome = res.outcome end
    end
    truthy(outcome == 'snap' or outcome == 'escape' or outcome == 'timeout',
        'a fight nobody plays must end in a normalized failure, got ' .. tostring(outcome))
end)

test('P8 a clean fight lands the fish and scores a perfect performance', function()
    local g = start({ difficulty = 1 })
    g.last = g.open
    local seq, outcome = 1, nil
    while seq <= 60 and not outcome do
        local res = answerCorrectly(g, seq)
        outcome = res.outcome
        seq = seq + 1
    end
    equal(outcome, 'success', 'answering every phase correctly must land the fish')
    truthy(H.CB['zfishing:claim'](5, g.sid, 0, false, nil).fish, 'and the claim pays')
    equal(g.calls.ctx.perfScore, 1, 'no miss means a perfect score')
end)

test('P9 a rejected action leaves the phase and the clock untouched', function()
    local g = start()
    local before = H.deepcopy(g.open)
    equal(H.CB['zfishing:encounter:act'](5, g.sid, g.cid, 9, 'left').reason, 'bad_seq')
    equal(H.CB['zfishing:encounter:act'](5, g.sid, g.cid, 1, 'teleport').reason, 'bad_action')
    _G.__NOW = before.windowOpensAt + 50
    local ok = H.CB['zfishing:encounter:act'](5, g.sid, g.cid, 1, COUNTER[before.phase])
    truthy(ok.ok, 'seq 1 was never consumed')
    equal(ok.state.misses, 0, 'and neither rejection was scored')
end)

test('P10 tier drives the difficulty knobs in the right direction', function()
    local easy = start({ difficulty = 1 }).open
    local hard = start({ difficulty = 5 }).open
    truthy(hard.windowClosesAt - hard.windowOpensAt < easy.windowClosesAt - easy.windowOpensAt,
        'a harder fish gives a shorter counter window')
    truthy(hard.telegraphAt + (hard.windowOpensAt - hard.telegraphAt)
           < easy.telegraphAt + (easy.windowOpensAt - easy.telegraphAt) + 1,
        'and a shorter telegraph')
    equal(hard.maxMisses <= easy.maxMisses, true)
end)

test('P11 behavior shapes which phases the fish picks', function()
    -- steady_heavy dives far more than it runs; over many phases that has to show.
    local dives, runs = 0, 0
    for i = 1, 30 do
        local g = start({ behavior = 'steady_heavy', difficulty = 1 })
        if g.open.phase == 'DIVE' then dives = dives + 1 else runs = runs + 1 end
    end
    truthy(dives > runs, 'a heavy fish must favour DIVE, got ' .. dives .. ' dives / ' .. runs .. ' runs')
end)

test('P12 better gear widens the window and deepens the line, without touching the tier', function()
    local plain = start({ difficulty = 3 }).open
    local geared = start({ difficulty = 3, rig = true }).open
    equal(plain.maxMisses, geared.maxMisses, 'gear must not change the tier')
    truthy(geared.windowClosesAt - geared.windowOpensAt >= plain.windowClosesAt - plain.windowOpensAt)
end)

H.run()
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
node tests/luarun.mjs tests/encounter_counter_pull.test.lua
```

Expected: `RUNNER ERROR` naming `server/encounter_counter_pull.lua` — the file does not exist.

- [ ] **Step 3: Give `build` the clock and let `Begin` return the opening frame**

Two small contract refinements. `mod.build` needs `now` to arm its first phase, and the client needs something to draw before its first action.

In `server/encounter.lua`, inside `Encounter.Begin`, move the clock read above the build call and pass it in:

```lua
function Encounter.Begin(s, gear)
    local mod = Encounter.MODULES[s.encounter.type]
    if not mod then return nil end

    -- `now` is read before build so a module can arm its first phase against the same
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

and delete the later `local now = GetGameTimer()` line. Then change the return:

```lua
    -- The opening frame. Without it the NUI has nothing to draw until the player's
    -- first action, which is the one moment they cannot act without seeing something.
    return s.encounter.challengeId, mod.render and mod.render(s.encounter) or nil
end
```

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

- [ ] **Step 4: Write the module**

Create `server/encounter_counter_pull.lua`:

```lua
-- Counter-Pull Fight.
--
-- The fish telegraphs a direction; the player counters it. The server owns which
-- direction it is, when the window opens and closes, and what every action cost --
-- the client is told what to draw and nothing more. In particular the render payload
-- never carries `required`: a player derives the counter from the cue, which is the
-- game, but handing an auto-counter bot the answer costs an honest client nothing.

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
-- A fake must flip at least this long before the window shuts, so the switch is
-- always something a watching player can react to rather than unavoidable RNG.
local FAKE_LEAD = 400

local COUNTER = { LEFT_RUN = 'right', RIGHT_RUN = 'left', DIVE = 'brace' }
local RUNS = { 'LEFT_RUN', 'RIGHT_RUN', 'DIVE' }

-- Keyed on the four behavior names that actually exist in config/fish.lua.
local BEHAVIOR = {
    steady_light = { LEFT_RUN = 4, RIGHT_RUN = 4, DIVE = 1 },
    steady_heavy = { LEFT_RUN = 2, RIGHT_RUN = 2, DIVE = 6 },
    run_stop     = { LEFT_RUN = 4, RIGHT_RUN = 4, DIVE = 2 },
    erratic      = { LEFT_RUN = 3, RIGHT_RUN = 3, DIVE = 3 },
}

-- Seeded LCG rather than math.random: the fight has to be reproducible from the
-- challenge seed alone, so a test can replay one and a desync can be investigated.
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

local function armRun(st, now)
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
    st.phase = 'FATIGUED'
    st.required = 'reel'
    st.telegraphAt = now
    st.windowOpensAt = now
    st.windowClosesAt = now + FATIGUE_WINDOW
    st.deadline = st.windowClosesAt + GRACE
    st.reelsLeft = reelsLeft or st.tier.reels
    st.cue, st.switchAt, st.nextCue = 'FATIGUED', nil, nil
end

local function armLanding(st, now)
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
        counters = 0, misses = 0,
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

function M.render(enc)
    local st = enc.state
    return {
        phase = st.phase,
        cue = st.cue, switchAt = st.switchAt, nextCue = st.nextCue,
        telegraphAt = st.telegraphAt,
        windowOpensAt = st.windowOpensAt, windowClosesAt = st.windowClosesAt,
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
            return { render = M.render(enc), outcome = 'success', value = 1 }
        elseif st.phase == 'FATIGUED' then
            st.stamina = st.stamina - st.perReel
            st.reelsLeft = (st.reelsLeft or 1) - 1
        else
            st.stamina = st.stamina - st.perCounter
            st.counters = st.counters + 1
        end
    else
        st.misses = st.misses + 1
        st.line = st.line - st.tier.mistake
        if st.phase == 'LANDING' then
            st.stamina = LANDING_RECOVERY      -- the fish finds a second wind
        else
            st.stamina = math.min(st.maxStamina, st.stamina + MISS_RECOVERY)
        end
    end

    if st.line <= 0 then
        return { render = M.render(enc), outcome = 'snap', value = hit and 1 or 0 }
    end
    if st.misses >= st.tier.maxMisses then
        return { render = M.render(enc), outcome = 'escape', value = hit and 1 or 0 }
    end

    if st.stamina <= 0 then
        armLanding(st, now)
    elseif st.phase == 'FATIGUED' and (st.reelsLeft or 0) > 0 then
        armFatigue(st, now, st.reelsLeft)      -- same break, fresh window
    elseif st.phase ~= 'FATIGUED' and st.counters > 0 and st.counters % st.tier.perFatigue == 0 then
        armFatigue(st, now)
    else
        armRun(st, now)
    end

    return { render = M.render(enc), outcome = nil, value = hit and 1 or 0 }
end

Encounter.Register('counter_pull', M)
```

- [ ] **Step 5: Load the module in the test harness path**

The suite `dofile`s the module directly (see `start()` in Step 1), so no harness change is needed. Add the npm script now — in `tests/package.json`, add to `scripts`:

```json
    "test:encounter-counter-pull": "node luarun.mjs tests/encounter_counter_pull.test.lua",
```

and append ` && npm run test:encounter-counter-pull` to `test:all`.

- [ ] **Step 6: Run the tests to verify they pass**

```bash
node tests/luarun.mjs tests/encounter_counter_pull.test.lua
```

Expected: twelve `ok -` lines then `12 tests passed`.

If P11 is flaky, the behavior weights are too close — widen `steady_heavy`'s DIVE weight rather than loosening the assertion. If P7 or P8 hit their loop ceilings, the fight is longer than the plan assumed; print the final render and re-derive the tier arithmetic before touching the test bounds.

- [ ] **Step 7: Re-run every suite**

```bash
cd tests && npm run test:all
```

Expected: 10 suites, 198 + 12 = 210 tests, exit 0.

- [ ] **Step 8: Commit**

```bash
git add server/encounter_counter_pull.lua server/encounter.lua server/session.lua tests/encounter_counter_pull.test.lua tests/package.json
git commit -m "feat: add the counter-pull fight state machine"
```

---

## Task 2: The client bridge

**Files:**
- Create: `client/encounter.lua`
- Modify: `client/minigame.lua` (the `zfishing:bite` handler)

**Interfaces:**
- Consumes: the `zfishing:bite` payload's `encounter` and `difficulty` fields (Phase A); `zfishing:hook`'s `{ ok, challengeId, encounter }` (Task 1); `zfishing:encounter:act`'s `{ ok, seq, state, outcome }`.
- Produces: NUI messages `{ action = 'encounter', type, difficulty, state, challengeId }` and `{ action = 'encounterState', state, outcome }`; NUI callback `encounterAction` accepting `{ action = <string> }`.

- [ ] **Step 1: Keep the legacy handler off the encounter path**

In `client/minigame.lua`, at the very top of the `zfishing:bite` handler, add:

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
-- Encounter bridge. Routes an encounter bite to the NUI, polls the player's input,
-- and forwards one discrete action per press to the server.
--
-- This file simulates NOTHING. It holds no stamina, no timer that decides anything,
-- and no notion of whether an action was correct -- the server answers all three. Its
-- only state is the sequence number and the last authoritative payload.

local ENC = { active = false, seq = 0, challengeId = nil, sessionId = nil, type = nil }

-- action -> control. All four are analog on a gamepad already, so controller support
-- needs no separate mapping and no button mashing.
local KEYS = {
    { action = 'left',  control = 34 },   -- INPUT_MOVE_LEFT_ONLY   (A / stick left)
    { action = 'right', control = 35 },   -- INPUT_MOVE_RIGHT_ONLY  (D / stick right)
    { action = 'brace', control = 33 },   -- INPUT_MOVE_DOWN_ONLY   (S / stick down)
    { action = 'reel',  control = 22 },   -- the key the legacy fight already uses
}

local function stop()
    ENC.active = false
    ENC.challengeId, ENC.sessionId, ENC.type = nil, nil, nil
    ENC.seq = 0
end

-- The server stamps its windows with GetGameTimer(), which is milliseconds since the
-- game started -- a clock the NUI has no access to and cannot compare against
-- Date.now(). Translating to offsets HERE, at the one moment both clocks are readable
-- in the same breath, is the only place that conversion is correct. The NUI then adds
-- each offset to its own Date.now() on receipt.
local TIME_FIELDS = { telegraphAt = 'telegraphIn', windowOpensAt = 'windowOpensIn',
                      windowClosesAt = 'windowClosesIn', switchAt = 'switchIn' }

local function toOffsets(state)
    if type(state) ~= 'table' then return state end
    local now = GetGameTimer()
    local out = {}
    for k, v in pairs(state) do
        local offsetKey = TIME_FIELDS[k]
        if offsetKey then out[offsetKey] = v - now else out[k] = v end
    end
    return out
end

-- One round trip per press. The reply is authoritative: whatever it says the state is,
-- that is what the NUI draws.
local function send(action)
    if not ENC.active then return end
    local res = lib.callback.await('zfishing:encounter:act', false,
        ENC.sessionId, ENC.challengeId, ENC.seq + 1, action)
    if not res then return end

    if res.seq then ENC.seq = res.seq end
    if res.ok then
        SendNUIMessage({ action = 'encounterState', state = toOffsets(res.state), outcome = res.outcome })
        if res.outcome then
            ENC.active = false
            ZClient.reeling = false
        end
        return
    end

    -- A rejection that ends the fight has to end it here too, or the player sits in a
    -- UI nothing will ever update again.
    if res.reason == 'encounter_over' then
        SendNUIMessage({ action = 'encounterState', state = nil, outcome = res.outcome or 'timeout' })
        ENC.active = false
        ZClient.reeling = false
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

    ENC.active = true
    ENC.seq = 0
    ENC.sessionId = ZClient.sessionId
    ENC.challengeId = res.challengeId
    ENC.type = data.encounter
    ZClient.reeling = true

    SendNUIMessage({ action = 'encounter', type = data.encounter,
        difficulty = data.difficulty, state = toOffsets(res.encounter),
        startedAt = GetGameTimer() })
    Casting.StartFight()
    Anim.PlayClip('idle_c')

    -- Input polling. One event per PRESS, never per frame -- the loop itself runs at
    -- frame rate because that is how FiveM reads a key, but it only ever talks to the
    -- server on an edge.
    CreateThread(function()
        while ENC.active and ZClient.active do
            for _, k in ipairs(KEYS) do
                if IsDisabledControlJustPressed(0, k.control) then
                    send(k.action)
                    break
                end
            end
            Wait(0)
        end
    end)
end)

-- The NUI tells us its local window expired. The server decides what that means; it
-- refuses an `advance` that arrives before the deadline it set.
RegisterNUICallback('encounterAction', function(body, cb)
    cb({})
    if type(body) == 'table' and type(body.action) == 'string' then send(body.action) end
end)

-- Settlement is the same door as always: zfishing:claim. The success flag we pass is
-- ignored for an encounter session -- the server reads its own outcome -- but the
-- argument list is unchanged, so there is still exactly one settlement path.
RegisterNUICallback('encounterDone', function(_, cb)
    cb({})
    if not ZClient.sessionId then return end
    stop()
    ZClient.reeling = false
    local res = lib.callback.await('zfishing:claim', false, ZClient.sessionId, 0, false, nil)
    if res and res.ok and res.fish then
        SendNUIMessage({ action = 'caught',
            label = res.fish.label, weight = res.fish.weight, quality = res.fish.quality })
        Casting.StartDrift()
        SetNuiFocus(true, true)
        PlaySoundFrontend(-1, 'CHECKPOINT_PERFECT', 'HUD_MINI_GAME_SOUNDSET', true)
    elseif res and res.ok then
        local key = res.outcome == 'snap' and 'line_broke' or 'fish_escaped'
        TriggerEvent('zfishing:client:end', key, 'error')
    else
        TriggerEvent('zfishing:client:end', 'error_claim_failed', 'error')
    end
end)

AddEventHandler('zfishing:client:end', function() stop() end)
```

- [ ] **Step 3: Verify the legacy path is untouched**

```bash
node tests/luarun.mjs tests/water_validation_preservation.test.lua
```

Expected: `11 tests passed`. That suite drives `client/main.lua` and the cast/cancel lifecycle.

```bash
cd tests && npm run test:all
```

Expected: 10 suites, 210 tests, exit 0.

- [ ] **Step 4: Commit**

```bash
git add client/encounter.lua client/minigame.lua
git commit -m "feat: bridge encounter input between the NUI and the server"
```

---

## Task 3: The NUI

**Files:**
- Create: `web/src/encounters/types.ts`
- Create: `web/src/encounters/EncounterHost.tsx`
- Create: `web/src/encounters/CounterPull.tsx`
- Modify: `web/src/App.tsx`
- Modify: `web/src/style.css`

**Interfaces:**
- Consumes: `encounter` and `encounterState` NUI messages from Task 2; `fetchNui('encounterAction', { action })` and `fetchNui('encounterDone')`.
- Produces: an `encounter` view in `App.tsx`'s `View` union.

- [ ] **Step 1: Define the payload types**

Create `web/src/encounters/types.ts`:

```typescript
export type EncounterType = 'counter_pull' | 'fish_mindgame' | 'sonar_strike'
export type Outcome = 'success' | 'escape' | 'snap' | 'timeout'

export type CounterPullPhase = 'LEFT_RUN' | 'RIGHT_RUN' | 'DIVE' | 'FATIGUED' | 'LANDING'

// What server/encounter_counter_pull.lua's M.render returns, after client/encounter.lua
// has converted the server's GetGameTimer() stamps into offsets (see toOffsets there --
// the two clocks are unrelated and cannot be compared directly).
//
// Note what is NOT here: the required counter. The player reads it off the cue; the
// payload does not spell it out.
export type CounterPullState = {
  phase: CounterPullPhase
  cue: CounterPullPhase
  nextCue?: CounterPullPhase
  /** ms from when this payload was built until the cue appears (may be negative) */
  telegraphIn: number
  /** ms until the counter window opens */
  windowOpensIn: number
  /** ms until it shuts */
  windowClosesIn: number
  /** ms until a fake flips to nextCue; absent when the fish is not faking */
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
// material, same typography, same success/failure language. Only the fight inside
// differs.
export default function EncounterHost({ msg }: { msg: EncounterMessage }) {
  const [state, setState] = useState<CounterPullState>(msg.state)
  const [outcome, setOutcome] = useState<Outcome | null>(null)

  // React state moves on a TRANSITION, never per frame. The per-frame work lives
  // inside the child's requestAnimationFrame loop, reading refs.
  useNuiEvent((m) => {
    if (m.action !== 'encounterState') return
    if (m.state) setState(m.state)
    if (m.outcome) setOutcome(m.outcome)
  })

  useEffect(() => { setState(msg.state); setOutcome(null) }, [msg.startedAt])

  if (msg.type === 'counter_pull') {
    return <CounterPull state={state} outcome={outcome} difficulty={msg.difficulty} />
  }
  return null
}
```

- [ ] **Step 3: Write the counter-pull UI**

Create `web/src/encounters/CounterPull.tsx`:

```tsx
import type { CSSProperties } from 'react'
import { useEffect, useRef, useState } from 'react'
import { fetchNui } from '../hooks/useNui'
import { t } from '../i18n'
import Keycap from '../components/Keycap'
import type { CounterPullPhase, CounterPullState, Outcome } from './types'

// Direction, glyph and key for each phase. Every cue is carried by shape and motion
// and text as well as position -- never by colour alone.
const CUES: Record<CounterPullPhase, { glyph: string; key: string; label: string; dir: -1 | 0 | 1 }> = {
  LEFT_RUN:  { glyph: '◀', key: 'D', label: 'enc_cp_left',    dir: -1 },
  RIGHT_RUN: { glyph: '▶', key: 'A', label: 'enc_cp_right',   dir: 1 },
  DIVE:      { glyph: '▼', key: 'S', label: 'enc_cp_dive',    dir: 0 },
  FATIGUED:  { glyph: '⟳', key: 'SPACE', label: 'enc_cp_reel', dir: 0 },
  LANDING:   { glyph: '⤒', key: 'SPACE', label: 'enc_cp_land', dir: 0 },
}

export default function CounterPull(
  { state, outcome }: { state: CounterPullState; outcome: Outcome | null; difficulty: number }
) {
  // The payload arrives as offsets from "now"; anchor them to this client's clock once,
  // on receipt. Anchoring per render would drift the window every time React ran.
  const anchor = useRef(Date.now())
  const [shown, setShown] = useState<CounterPullPhase>(state.cue)
  const barRef = useRef<HTMLDivElement | null>(null)
  const advancedRef = useRef(false)

  const opensAt = anchor.current + state.windowOpensIn
  const closesAt = anchor.current + state.windowClosesIn

  // A new phase: re-anchor, redraw the cue, re-arm the advance guard.
  useEffect(() => {
    anchor.current = Date.now()
    setShown(state.cue)
    advancedRef.current = false
  }, [state.windowOpensIn, state.cue, state.phase])

  // The only per-frame work in the component, and it writes straight to the DOM node.
  // Going through React here would re-render the whole panel sixty times a second to
  // move one bar.
  useEffect(() => {
    let raf = 0
    const tick = () => {
      const el = barRef.current
      if (el) {
        const span = Math.max(1, closesAt - opensAt)
        const p = Math.min(1, Math.max(0, (Date.now() - opensAt) / span))
        el.style.width = `${(1 - p) * 100}%`
      }
      raf = requestAnimationFrame(tick)
    }
    raf = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(raf)
  }, [opensAt, closesAt])

  // The fish visibly changes its mind. A state change, not a frame update.
  useEffect(() => {
    if (state.switchIn === undefined || !state.nextCue) return
    const id = setTimeout(() => setShown(state.nextCue as CounterPullPhase),
      Math.max(0, state.switchIn))
    return () => clearTimeout(id)
  }, [state.switchIn, state.nextCue])

  // Our window expired and the player did nothing. Tell the server once; it decides
  // what that means, and refuses this outright if its own deadline has not passed.
  useEffect(() => {
    if (outcome) return
    const id = setTimeout(() => {
      if (advancedRef.current) return
      advancedRef.current = true
      fetchNui('encounterAction', { action: 'advance' })
    }, Math.max(0, state.windowClosesIn) + 300)
    return () => clearTimeout(id)
  }, [state.windowClosesIn, outcome])

  useEffect(() => {
    if (!outcome) return
    const id = setTimeout(() => fetchNui('encounterDone', {}), 700)
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

In `web/src/App.tsx`, add `'encounter'` to the `View` union, import `EncounterHost`, add the message case:

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
/* Encounter shell. Inherits the panel material, rail colour and radius from
   .hud-panel so the three encounters read as one product with the rest of the HUD. */
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

/* A fake flip is a visible event, not just a swapped glyph. */
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

`--rail`, `--warn` and `--danger` are already defined on `.hud-panel` and its
`--danger` modifier, so the encounter panel picks up the existing danger treatment
without redefining a single colour.

- [ ] **Step 6: Type-check and build**

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

## Task 4: Web tests and locale strings

**Files:**
- Create: `web/src/encounters/__tests__/CounterPull.test.tsx`
- Modify: `locales/en.json`, `locales/th.json`

**Interfaces:**
- Consumes: `CounterPull` and its props from Task 3.

- [ ] **Step 1: Add the strings**

Add to **both** locale files:

| key | en |
| --- | --- |
| `enc_cp_title` | `Counter the fish` |
| `enc_cp_left` | `Running left — pull right` |
| `enc_cp_right` | `Running right — pull left` |
| `enc_cp_dive` | `Diving — brace` |
| `enc_cp_reel` | `Tired — reel!` |
| `enc_cp_land` | `Land it!` |
| `enc_stamina` | `Fish stamina` |
| `enc_line` | `Mistakes` |
| `enc_outcome_success` | `Landed!` |
| `enc_outcome_escape` | `It got away` |
| `enc_outcome_snap` | `Your line snapped` |
| `enc_outcome_timeout` | `Out of time` |

Thai equivalents go in `locales/th.json` under the same keys.

- [ ] **Step 2: Write the component tests**

Create `web/src/encounters/__tests__/CounterPull.test.tsx`. These assert state
transitions, not markup shape:

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
  phase: 'LEFT_RUN', cue: 'LEFT_RUN',
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
        <CounterPull state={base({ phase, cue: phase })} outcome={null} difficulty={2} />
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
        outcome={null} difficulty={4}
      />
    )
    expect(document.querySelector('.enc-cue')!.className).toContain('left_run')
    act(() => { vi.advanceTimersByTime(650) })
    expect(document.querySelector('.enc-cue')!.className).toContain('dive')
  })

  it('carries the danger treatment when the line is nearly gone', () => {
    const { container, rerender } = render(
      <CounterPull state={base({ linePct: 90 })} outcome={null} difficulty={2} />
    )
    expect(container.querySelector('.hud-panel--danger')).toBeNull()
    rerender(<CounterPull state={base({ linePct: 30 })} outcome={null} difficulty={2} />)
    expect(container.querySelector('.hud-panel--danger')).not.toBeNull()
  })

  it('posts advance exactly once after the window closes', () => {
    render(<CounterPull state={base()} outcome={null} difficulty={2} />)
    act(() => { vi.advanceTimersByTime(1500) })
    expect(posted.filter((p) => p.data?.action === 'advance')).toHaveLength(0)
    act(() => { vi.advanceTimersByTime(1500) })
    const advances = posted.filter((p) => p.data?.action === 'advance')
    expect(advances).toHaveLength(1)
    act(() => { vi.advanceTimersByTime(5000) })
    expect(posted.filter((p) => p.data?.action === 'advance')).toHaveLength(1)
  })

  it('re-arms advance for the next phase', () => {
    const { rerender } = render(<CounterPull state={base()} outcome={null} difficulty={2} />)
    act(() => { vi.advanceTimersByTime(2400) })
    expect(posted.filter((p) => p.data?.action === 'advance')).toHaveLength(1)

    rerender(
      <CounterPull state={base({ phase: 'DIVE', cue: 'DIVE', windowOpensIn: 700, windowClosesIn: 1900 })}
        outcome={null} difficulty={2} />
    )
    act(() => { vi.advanceTimersByTime(2300) })
    expect(posted.filter((p) => p.data?.action === 'advance')).toHaveLength(2)
  })

  it('renders the outcome and closes the fight through encounterDone', () => {
    render(<CounterPull state={base()} outcome="snap" difficulty={2} />)
    expect(document.querySelector('.enc-outcome')!.textContent!.length).toBeGreaterThan(0)
    act(() => { vi.advanceTimersByTime(800) })
    expect(posted.some((p) => p.event === 'encounterDone')).toBe(true)
  })

  it('never sends the server a timing value it could trust', () => {
    render(<CounterPull state={base()} outcome={null} difficulty={2} />)
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

Expected: 71 existing plus the new file's tests, all passing.

- [ ] **Step 4: Commit**

```bash
git add web/src/encounters/__tests__ locales/en.json locales/th.json
git commit -m "test: cover the counter-pull UI state transitions"
```

---

## Task 5: Wire, build and document

**Files:**
- Modify: `fxmanifest.lua`
- Rebuild and commit: `web/dist`
- Modify: `docs/ARCHITECTURE.md`
- Modify: `docs/testing/zfishing-live-e2e-checklist.md`

- [ ] **Step 1: Load the new files**

In `fxmanifest.lua`, add `'server/encounter_counter_pull.lua',` to `server_scripts`
immediately after `'server/encounter.lua',`, and `'client/encounter.lua',` to
`client_scripts` immediately after `'client/minigame.lua',`.

- [ ] **Step 2: Rebuild the NUI bundle**

```bash
cd web && npm run build
```

`web/dist` is committed to this repository. Without this step the running resource has
the new Lua and none of the UI, and a forced counter-pull would leave the player
staring at nothing.

- [ ] **Step 3: Re-run everything**

```bash
cd tests && npm run test:all
```

Expected: 10 suites, 210 tests, exit 0.

```bash
cd web && npm test
```

Expected: all suites pass. The Lua hash-tree snapshot in
`bundleRebuildPreservation.test.ts` will fail — Lua changed deliberately, so re-record
it with `npx vitest --run -u src/__tests__/bundleRebuildPreservation.test.ts`, which is
what every Lua-touching commit in this repo has done.

- [ ] **Step 4: Document**

Add `### 12.10 Counter-Pull Fight` to `docs/ARCHITECTURE.md`: the five phases and their
counters, the grace window and why it is 250ms, the tier table, how fakes stay fair,
the two failure clocks (line damage and miss count) and why both exist, and the
statement that the render payload never carries `required`.

Add a change-history entry under `## 13`.

Add an "Encounter system" section to `docs/testing/zfishing-live-e2e-checklist.md`
covering: FORCED counter-pull at tier 1 and tier 5; each of the four counters and the
fatigue reel; a fake telegraph at tier 3+; a deliberate line snap; a deliberate walk-away
timeout; an admin changing the mode mid-fight and the fight not changing; two players in
counter-pull simultaneously; and resmon at idle, one fight, and several. Leave every box
unticked — nobody has run them.

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

- `Encounter.Playable('counter_pull')` is true, so an admin setting FORCED to
  counter-pull gets the real fight rather than a downgrade to legacy.
- No fish resolves to counter-pull on its own — no `encounter` field ships until Phase F,
  so DEFAULT still means the legacy fight for everyone.
- `fish_mindgame` and `sonar_strike` still downgrade to legacy.
- Live behaviour is **unverified**: nothing in this phase has been run inside FiveM.

## Known limitation to carry into the completion report

The fake telegraph sends `nextCue` in the same payload as `cue`, because the NUI has to
draw the flip and a round trip at that moment would cost exactly the reaction time the
mechanic is testing. A modified client can therefore read the real direction up front
and ignore fakes entirely. It gains immunity to a tier-3+ flourish, not free wins: the
counter still has to be the right key inside a server-owned window. This is a deliberate
trade, and it belongs in the release notes rather than in a fix.
