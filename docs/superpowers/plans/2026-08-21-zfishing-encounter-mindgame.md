# Fish Mindgame (Phase C) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `fish_mindgame` — read, decide, counter. A turn-based fight where the difficulty is knowing *what* to answer, not how fast, and where a player who has fished a species before genuinely knows more than one who has not.

**Architecture:** `server/encounter_mindgame.lua` implements the same module contract `counter_pull` uses, so nothing in `server/encounter.lua`, `server/session.lua` or the claim path changes. The fish's action comes from a per-behaviour Markov chain the server owns; the player picks one of four responses; the server scores it. The client bridge gains a per-encounter key map. The NUI gains a second component behind the existing `EncounterHost`.

**Tech Stack:** Lua 5.4 (FiveM `cerulean`), ox_lib callbacks, wasmoon test harness, React 18 + Vitest.

**Spec:** `docs/superpowers/specs/2026-08-20-zfishing-encounter-system-design.md` §5, plus `docs/ARCHITECTURE.md` §12.

**Prerequisite — verify before starting:**

```bash
grep -c "Encounter.Register" server/encounter_counter_pull.lua && grep -c "phaseId" web/src/encounters/types.ts
```

Both must be non-zero. Phase B merged to `main` at `127053d`, where 221 Lua tests and 78 web tests pass. This plan's branch is `encounter-mindgame`, cut from that merge.

## Global Constraints

- **The module contract is fixed and unchanged.** `build(ctx) -> state, estimate`, `render(enc, now)`, `act(enc, action, now) -> { render, outcome, value }`, `state.deadline` absolute, `Encounter.Register(id, mod)`. Phase C adds a module; it does not touch the framework.
- **Absolute time never leaves the server.** `render` emits `...In` durations only.
- **Every authoritative transition carries `phaseId`.** Not `turnId` — see the note below.
- **No render payload names the correct response.** The player reads the fish; the payload does not spell out the answer.
- **Responsibility boundary:** server = gameplay authority; client = orchestration; NUI = presentation.
- **Lua files stay flat.** `tests/luarun.mjs` mounts `client/`, `server/`, `shared/`, `tests/` non-recursively.
- **`legacy_tension` and `counter_pull` are untouched.** No change to either module, and `counter_pull`'s tests must stay green byte-for-byte.
- **Baseline to preserve:** `cd tests && npm run test:all` reports 11 suites / 221 tests; `npm --prefix web test` reports 78. Both must pass at the end of every task.
- Stable ids verbatim: encounter `fish_mindgame`; fish actions `RUN`, `DIVE`, `THRASH`, `JUMP`, `REST`; player responses `give_line`, `brace`, `hold`, `reel`, plus the universal `advance`; landing phase `LANDING`.

### One deliberate naming decision

The Phase B review suggested the transition-id pattern generalize as
`phaseId` / `turnId` / `attemptId` per encounter. This plan uses **`phaseId` for every
encounter instead.** `EncounterHost` and any shared encounter UI would otherwise have to
special-case a field name that means exactly the same thing in all three, and the
per-encounter name buys nothing the `phase` field does not already carry. The contract
word is "authoritative transition id"; the field is `phaseId` everywhere.

---

## What Phase C does not do

- **No fish is configured to use it.** DEFAULT still resolves everything to
  `legacy_tension`; `fish_mindgame` is reachable only through
  `EncounterMode = forced, ForcedEncounter = fish_mindgame` until Phase F.
- **No directional world feedback.** Still deferred to Phase G, along with
  counter-pull's.
- **No mouse or click input.** The fight runs without NUI focus, exactly as counter-pull
  does, so the four responses are keyboard/controller only and the on-screen buttons are
  labels with keycaps rather than click targets. This is stated so nobody implements a
  click handler that can never fire.

---

## File Structure

| File | Responsibility | Task |
| --- | --- | --- |
| `server/encounter_mindgame.lua` | **Create.** Behaviour chains, turn model, response scoring, forced landing. | 1 |
| `tests/encounter_mindgame.test.lua` | **Create.** The fight, deterministic throughout. | 1 |
| `tests/harness.lua` | **Modify.** A `stats` override so a test can choose its reel. | 1 |
| `tests/package.json` | **Modify.** Script + `test:all`. | 1, 2 |
| `client/encounter.lua` | **Modify.** Per-encounter key maps. | 2 |
| `tests/client_encounter.test.lua` | **Modify.** Key-map routing coverage. | 2 |
| `web/src/encounters/types.ts` | **Modify.** `MindgameState`, discriminated `EncounterMessage`. | 3 |
| `web/src/encounters/EncounterHost.tsx` | **Modify.** Dispatch on `msg.type`. | 3 |
| `web/src/encounters/FishMindgame.tsx` | **Create.** Telegraph + four responses. | 3 |
| `web/src/style.css` | **Modify.** Mindgame classes in the existing language. | 3 |
| `web/src/encounters/__tests__/FishMindgame.test.tsx` | **Create.** | 4 |
| `locales/en.json`, `locales/th.json` | **Modify.** | 4 |
| `fxmanifest.lua`, `web/dist`, `docs/*` | **Modify / rebuild.** | 5 |

---

## Task 1: The mindgame module

**Files:**
- Create: `server/encounter_mindgame.lua`
- Create: `tests/encounter_mindgame.test.lua`
- Modify: `tests/harness.lua`
- Modify: `tests/package.json`

**Interfaces:**
- Consumes: `Encounter.Register`, `ctx = { difficulty, seed, fish, gear, now }`, `Encounters.LineMult`, `ZUtil.clamp` — identical to `counter_pull`.
- Produces: `mod.actions = { give_line, brace, hold, reel }`; render payload
  `{ phaseId, phase, cue, nextCue?, telegraphIn, deadlineIn, switchIn?, staminaPct, linePct, pressure, escapeThreshold, turn, turns }`.

**The response table.** `RUN` and `JUMP` share a correct answer on purpose: they differ
in the *cost of being wrong*, not in the answer. Knowing the species tells you how bad a
mistake is about to be, which is the point of the encounter — it is not
rock-paper-scissors with five hands.

| fish action | correct | on correct | on wrong |
| --- | --- | --- | --- |
| `RUN` | `give_line` | stamina − | line − `mistake`, stamina + |
| `DIVE` | `brace` | stamina − | line − `mistake × 1.5`, stamina + |
| `THRASH` | `hold` | stamina − | pressure +1, stamina + |
| `JUMP` | `give_line` | stamina − | pressure +2, stamina + |
| `REST` | `reel` | stamina − × `(1 + reelDrain)` | turn wasted, stamina + |

**Behaviour chains.** Three of the four real behaviours are fixed cycles, so a player can
learn them; only `erratic` is weighted random. This is the mechanism behind the design
goal that species knowledge is a real skill.

| behavior | chain | what a player learns |
| --- | --- | --- |
| `steady_light` | RUN → REST → RUN → THRASH | most predictable; safe to learn on |
| `steady_heavy` | DIVE → DIVE → REST | "catfish dives twice, then rests" |
| `run_stop` | RUN → RUN → REST | long runs, then a reel opportunity |
| `erratic` | weighted random incl. JUMP | cannot be pre-read; answer live |

- [ ] **Step 1: Let a test choose the reel it fights with**

`H.loadSession`'s rig stub hardcodes `reelDrain = 1.0`, so no test can currently show
what a better reel buys. Add an override. In `tests/harness.lua`, inside `H.loadSession`,
replace the `stats` entry of the `Rig` stub with:

```lua
        stats = function()
            local base = { lineRating = 10, reelDrain = 1.0, hook = 'hook_4', floatBiteSpeed = 1.0 }
            for k, v in pairs(opts.stats or {}) do base[k] = v end
            return base
        end,
```

`opts.stats` only applies on the assembled-rod path, so a test that wants it must also
pass `rig = true`.

- [ ] **Step 2: Write the failing module tests**

Create `tests/encounter_mindgame.test.lua`:

```lua
-- Fish Mindgame. Run from the resource root:
--   node tests/luarun.mjs tests/encounter_mindgame.test.lua
--
-- Sequencing, replay, stale challenge, wrong session and disconnect are covered once
-- for every encounter in tests/encounter_action.test.lua. This suite is the fight.
--
-- Deterministic throughout: three of the four behaviours are fixed chains, and the
-- fourth is pinned with H.withSeed.

dofile('tests/harness.lua')
local test, equal, truthy, falsy = H.test, H.equal, H.truthy, H.falsy

local FISH = { species = 'catfish', label = 'Catfish', weight = 9.0, quality = 3,
    rarity = 'uncommon', behavior = 'steady_heavy', biteDelay = 100, hookWindow = 1500,
    tensionDiff = 1.15, fishEnergy = 50, xp = 20, price = 14, difficulty = 2 }

local CORRECT = { RUN = 'give_line', DIVE = 'brace', THRASH = 'hold',
                  JUMP = 'give_line', REST = 'reel', LANDING = 'reel' }

local function start(opts)
    opts = opts or {}
    local fish = H.deepcopy(FISH)
    if opts.difficulty then fish.difficulty = opts.difficulty end
    if opts.behavior then fish.behavior = opts.behavior end

    local g = {}
    local run = function()
        g.calls = H.loadSession({ fish = fish, encounterMode = 'forced',
                                  forcedEncounter = 'fish_mindgame', rig = opts.rig })
        dofile('server/encounter_mindgame.lua')
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

local function act(g, action, offset)
    _G.__NOW = g.at + (offset or 100)
    g.seq = g.seq + 1
    local res = H.CB['zfishing:encounter:act'](5, g.sid, g.cid, g.seq, action)
    if res.ok and res.state then g.last, g.at = res.state, _G.__NOW end
    return res
end

-- Answers the REAL action. A faking fish shows a decoy in `cue` and reveals the truth
-- in `nextCue`, so the honest answer is whichever one is live at decision time.
local function answer(g)
    local real = g.last.nextCue or g.last.cue
    return act(g, CORRECT[real])
end

test('M1 the hook answer opens turn 1 with a readable telegraph', function()
    local g = start()
    equal(g.last.turn, 1)
    truthy(g.last.turns >= 3, 'the fight has a declared length')
    truthy(CORRECT[g.last.cue], 'the cue names a fish action the player can respond to')
    equal(g.last.correct, nil, 'the render payload must never carry the answer')
    equal(g.last.required, nil)
    truthy(g.last.deadlineIn > 0, 'and a decision window measured as a duration')
    equal(g.last.deadlineAt, nil, 'absolute server time must never reach a client')
    equal(g.last.staminaPct, 100); equal(g.last.linePct, 100); equal(g.last.pressure, 0)
end)

test('M2 steady_heavy really does dive twice then rest', function()
    local g = start({ behavior = 'steady_heavy', difficulty = 5 })
    local seen = { g.last.cue }
    for _ = 1, 2 do
        answer(g)
        seen[#seen + 1] = g.last.cue
    end
    equal(seen[1], 'DIVE'); equal(seen[2], 'DIVE'); equal(seen[3], 'REST')
end)

test('M3 each behaviour runs its own chain', function()
    local function firstThree(behavior)
        local g = start({ behavior = behavior, difficulty = 5 })
        local out = { g.last.cue }
        for _ = 1, 2 do answer(g); out[#out + 1] = g.last.cue end
        return table.concat(out, ',')
    end
    equal(firstThree('steady_light'), 'RUN,REST,RUN')
    equal(firstThree('run_stop'), 'RUN,RUN,REST')
    truthy(#firstThree('erratic') > 0, 'erratic is random but must still produce actions')
end)

test('M4 a correct response drains stamina and never damages the line', function()
    local g = start()
    local res = answer(g)
    truthy(res.ok); equal(res.outcome, nil)
    truthy(res.state.staminaPct < 100)
    equal(res.state.linePct, 100)
    equal(res.state.pressure, 0)
    equal(res.state.turn, 2, 'the turn counter advances')
    truthy(res.state.phaseId > 1, 'and so does the transition id')
end)

test('M5 a wrong answer to DIVE costs more line than a wrong answer to RUN', function()
    local dive = start({ behavior = 'steady_heavy' })
    equal(dive.last.cue, 'DIVE')
    local diveLoss = 100 - act(dive, 'reel').state.linePct

    local run = start({ behavior = 'run_stop' })
    equal(run.last.cue, 'RUN')
    local runLoss = 100 - act(run, 'reel').state.linePct

    truthy(diveLoss > runLoss, 'a botched dive is the expensive mistake')
    truthy(runLoss > 0)
end)

test('M6 a wrong THRASH answer costs pressure, and a wrong JUMP costs twice as much', function()
    -- erratic is the only chain that emits JUMP; drive it and take the two cases as
    -- they come, so the assertion does not depend on which turn they land on.
    local thrash, jump
    for seed = 1, 40 do
        local g = start({ behavior = 'erratic', difficulty = 5, seed = seed })
        for _ = 1, 6 do
            local cue = g.last.nextCue or g.last.cue
            if cue == 'THRASH' and not thrash then
                thrash = act(g, 'reel').state.pressure
                break
            elseif cue == 'JUMP' and not jump then
                jump = act(g, 'brace').state.pressure
                break
            end
            if answer(g).outcome then break end
        end
        if thrash and jump then break end
    end
    truthy(thrash, 'erratic must be able to THRASH')
    truthy(jump, 'erratic must be able to JUMP')
    equal(thrash, 1)
    equal(jump, 2, 'a fish in the air is the one you can lose outright')
end)

test('M7 REST answered with REEL takes a bigger bite than an ordinary correct answer', function()
    -- run_stop is RUN, RUN, REST
    local g = start({ behavior = 'run_stop', difficulty = 5 })
    equal(g.last.cue, 'RUN')
    local runDrop = g.last.staminaPct - answer(g).state.staminaPct

    answer(g)                                  -- the second RUN
    equal(g.last.cue, 'REST')
    local restDrop = g.last.staminaPct - answer(g).state.staminaPct

    truthy(restDrop > runDrop,
        ('a rested fish must pay more than a running one: %d vs %d'):format(restDrop, runDrop))
    equal(g.last.linePct, 100, 'and correct answers never cost line')
end)

test('M8 a better reel boosts the REST payoff and softens a mistake, never the turn count', function()
    local function restDropWith(drain)
        local g = start({ behavior = 'run_stop', difficulty = 5, rig = true,
                          stats = { reelDrain = drain } })
        for _ = 1, 4 do
            if g.last.cue == 'REST' then break end
            answer(g)
        end
        equal(g.last.cue, 'REST')
        local drop = g.last.staminaPct - answer(g).state.staminaPct
        return drop, g.last.turns
    end
    local cheapDrop, cheapTurns = restDropWith(1.0)
    local goodDrop, goodTurns = restDropWith(1.7)
    truthy(goodDrop > cheapDrop,
        ('a better reel converts a REST into more stamina: %d vs %d'):format(goodDrop, cheapDrop))
    equal(cheapTurns, goodTurns,
        'but never into fewer decisions -- the number of reads is the encounter content')
end)

test('M8b a better reel hands less stamina back on a wrong answer', function()
    local function recoveryWith(drain)
        local g = start({ behavior = 'steady_heavy', difficulty = 5, rig = true,
                          stats = { reelDrain = drain } })
        answer(g)                              -- drain some stamina first
        local before = g.last.staminaPct
        return act(g, 'reel').state.staminaPct - before   -- wrong answer to DIVE
    end
    truthy(recoveryWith(1.7) < recoveryWith(1.0),
        'a better reel holds more ground under a mistake')
end)

test('M9 a missed decision deadline is scored as a wrong answer by the SERVER', function()
    local g = start()
    local res = act(g, 'advance', g.last.deadlineIn + 400)
    truthy(res.ok)
    truthy(res.state.linePct < 100 or res.state.pressure > 0,
        'an expired turn must cost something')
    equal(res.state.turn, 2, 'and the fight moves on rather than stalling')
end)

test('M10 turns is what makes the tier, and a flawless fight lands in exactly that many', function()
    local easy = start({ difficulty = 1 })
    local hard = start({ difficulty = 5 })
    truthy(hard.last.turns > easy.last.turns)
    truthy(hard.last.deadlineIn < easy.last.deadlineIn, 'and a shorter decision window')

    local g = start({ difficulty = 1 })
    local declared, answered, outcome = g.last.turns, 0, nil
    for _ = 1, 40 do
        local res = answer(g)
        answered = answered + 1
        outcome = res.outcome
        if outcome or g.last.phase == 'LANDING' then break end
    end
    equal(answered, declared, 'a flawless fight takes exactly `turns` correct answers to tire the fish')
end)

test('M11 stamina at zero forces a landing turn, whatever the chain was doing', function()
    -- steady_heavy never rests twice in a row; the landing must not depend on the chain
    -- ever emitting REST, or an unlucky fish would be unwinnable.
    local g = start({ behavior = 'steady_heavy', difficulty = 1 })
    local landing
    for _ = 1, 40 do
        if g.last.phase == 'LANDING' then landing = g.last break end
        if answer(g).outcome then break end
    end
    truthy(landing, 'the fight must reach a landing turn')
    equal(landing.cue, 'LANDING')
    local res = act(g, 'reel')
    equal(res.outcome, 'success')
    truthy(H.CB['zfishing:claim'](5, g.sid, 0, false, nil).fish)
    equal(g.calls.ctx.perfScore, 1, 'no wrong answer means a perfect score')
end)

test('M12 a fumbled landing gives the fish a second wind', function()
    local g = start({ behavior = 'steady_heavy', difficulty = 1 })
    for _ = 1, 40 do
        if g.last.phase == 'LANDING' then break end
        if answer(g).outcome then break end
    end
    equal(g.last.phase, 'LANDING')
    local res = act(g, 'brace')     -- wrong response to a landing
    truthy(res.ok)
    equal(res.outcome, nil, 'a fumbled landing is not a loss')
    truthy(res.state.staminaPct > 0, 'the fish recovers')
    falsy(res.state.phase == 'LANDING', 'and the fight resumes on the chain')
end)

test('M13 escape pressure ends the fight as an escape', function()
    local g = start({ behavior = 'erratic', difficulty = 5, seed = 7 })
    local outcome
    for _ = 1, 30 do
        -- answer wrongly on purpose, choosing a response that is never correct for the
        -- action shown, so every turn costs either line or pressure
        local cue = g.last.nextCue or g.last.cue
        local wrong = CORRECT[cue] == 'reel' and 'brace' or 'reel'
        local res = act(g, wrong)
        outcome = res.outcome
        if outcome then break end
    end
    truthy(outcome == 'escape' or outcome == 'snap',
        'answering everything wrong must lose the fish one way or the other, got '
            .. tostring(outcome))
    equal(g.calls.give, 0)
end)

test('M14 a fake telegraph reveals the real action in time to answer it', function()
    local found
    for seed = 1, 60 do
        local g = start({ behavior = 'erratic', difficulty = 5, seed = seed })
        for _ = 1, 6 do
            if g.last.nextCue then found = g.last break end
            if answer(g).outcome then break end
        end
        if found then break end
    end
    truthy(found, 'tier 5 must be able to fake')
    truthy(found.switchIn, 'a fake has to say when it flips')
    truthy(found.deadlineIn - found.switchIn >= 700,
        'the flip must land at least 700ms before the deadline, or it is unavoidable RNG')
    truthy(found.nextCue ~= found.cue)
end)

test('M15 a rejected action leaves the turn and the clock untouched', function()
    local g = start()
    local before = H.deepcopy(g.last)
    _G.__NOW = g.at + 100
    equal(H.CB['zfishing:encounter:act'](5, g.sid, g.cid, 9, 'brace').reason, 'bad_seq')
    equal(H.CB['zfishing:encounter:act'](5, g.sid, g.cid, 1, 'teleport').reason, 'bad_action')
    local ok = H.CB['zfishing:encounter:act'](5, g.sid, g.cid, 1, CORRECT[before.cue])
    truthy(ok.ok, 'seq 1 was never consumed')
    equal(ok.state.turn, before.turn + 1, 'exactly one turn happened')
end)

H.run()
```

- [ ] **Step 3: Run the tests to verify they fail**

```bash
node tests/luarun.mjs tests/encounter_mindgame.test.lua
```

Expected: `RUNNER ERROR` naming `server/encounter_mindgame.lua`.

- [ ] **Step 4: Write the module**

Create `server/encounter_mindgame.lua`:

```lua
-- Fish Mindgame.
--
-- Read, decide, counter. The fish telegraphs an action; the player picks one of four
-- responses. Difficulty here is knowing WHAT to answer, not answering fast -- so the
-- whole decision window is open from the moment the cue appears, and an early answer is
-- as good as a late one.
--
-- Three of the four behaviours are fixed chains rather than random draws. That is the
-- point of the encounter: a player who has fought a catfish before knows it dives twice
-- and then rests, and that knowledge is worth something.
--
-- Same time discipline as counter_pull: state absolute, renders relative.

local M = {}

local TIERS = {
    [1] = { turns = 3, decision = 3000, line = 100, escape = 4, mistake = 22, fake = 0.00 },
    [2] = { turns = 4, decision = 2600, line = 100, escape = 4, mistake = 24, fake = 0.00 },
    [3] = { turns = 5, decision = 2200, line = 90,  escape = 3, mistake = 26, fake = 0.10 },
    [4] = { turns = 7, decision = 1900, line = 85,  escape = 3, mistake = 28, fake = 0.20 },
    [5] = { turns = 9, decision = 1600, line = 80,  escape = 3, mistake = 30, fake = 0.25 },
}

local GRACE = 250
-- More headroom than counter_pull's 400ms: a mindgame response is a considered choice,
-- not a reflex, so a fake has to leave room to reconsider rather than just to twitch.
local FAKE_LEAD = 700
local DIVE_MULT = 1.5
local LANDING_RECOVERY = 25

local CORRECT = { RUN = 'give_line', DIVE = 'brace', THRASH = 'hold',
                  JUMP = 'give_line', REST = 'reel', LANDING = 'reel' }

-- Fixed cycles for the three readable behaviours; erratic draws instead.
local CHAINS = {
    steady_light = { 'RUN', 'REST', 'RUN', 'THRASH' },
    steady_heavy = { 'DIVE', 'DIVE', 'REST' },
    run_stop     = { 'RUN', 'RUN', 'REST' },
}
local ERRATIC = { { 'RUN', 3 }, { 'DIVE', 3 }, { 'THRASH', 2 }, { 'JUMP', 2 }, { 'REST', 2 } }

local function rand(st)
    st.rng = (1103515245 * st.rng + 12345) % 2147483648
    return st.rng / 2147483648
end

local function nextAction(st)
    local chain = CHAINS[st.behavior]
    if chain then
        st.chainAt = (st.chainAt % #chain) + 1
        return chain[st.chainAt]
    end
    local total = 0
    for _, e in ipairs(ERRATIC) do total = total + e[2] end
    local r = rand(st) * total
    for _, e in ipairs(ERRATIC) do
        r = r - e[2]
        if r <= 0 then return e[1] end
    end
    return ERRATIC[#ERRATIC][1]
end

local function armTurn(st, now, action)
    st.phaseId = st.phaseId + 1
    st.phase = action == 'LANDING' and 'LANDING' or 'TURN'
    st.action = action
    st.required = CORRECT[action]
    st.telegraphAt = now
    local window = st.decision
    if action == 'LANDING' then window = st.landingWindow end
    st.deadlineAt = now + window
    st.deadline = st.deadlineAt + GRACE
    st.cue, st.switchAt, st.nextCue = action, nil, nil

    -- A fake shows one action and flips to the real one, far enough ahead of the
    -- deadline that the player can still change their mind.
    if action ~= 'LANDING' and st.tier.fake > 0 and rand(st) < st.tier.fake
        and window - FAKE_LEAD > 0 then
        local decoy = nextAction(st)
        if decoy ~= action then
            st.cue = decoy
            st.nextCue = action
            st.switchAt = st.deadlineAt - FAKE_LEAD
        end
    end
end

M.actions = { give_line = true, brace = true, hold = true, reel = true }

function M.build(ctx)
    local tier = TIERS[ZUtil.clamp(math.floor(ctx.difficulty or 1), 1, 5)]
    local gear = ctx.gear or {}
    local drain = gear.reelDrain or 1.0

    local st = {
        rng = (ctx.seed or 1) % 2147483648,
        tier = tier,
        behavior = (ctx.fish or {}).behavior or 'steady_light',
        chainAt = 0,
        decision = math.floor(tier.decision * (1 + (gear.greenZone or 0))),
        -- A better reel buys a more forgiving landing turn, never fewer decisions.
        landingWindow = 0,
        maxStamina = 100, stamina = 100,
        maxLine = math.floor(tier.line * Encounters.LineMult(gear.lineRating or 10)),
        -- `turns` IS the tier. drainRate deliberately does NOT multiply this: at 1.7 a
        -- tier-5 fight would land in about 6 correct answers instead of 9, and the
        -- number of reads is this encounter's entire content.
        perTurn = 100 / tier.turns,
        -- A wrong answer hands half a turn back, which is why mistakes lengthen a fight
        -- rather than only damaging it. A better reel holds more ground under one.
        recover = (50 / tier.turns) / drain,
        restMult = 1 + drain,
        drain = drain,
        pressure = 0, turn = 1, phaseId = 0, answered = 0,
    }
    st.line = st.maxLine
    st.landingWindow = math.floor(st.decision * ZUtil.clamp(drain, 1.0, 1.5))
    armTurn(st, ctx.now or 0, nextAction(st))

    -- Worst honest fight: every turn landed, plus a wrong answer for each one (they
    -- return stamina and add turns), plus the escape budget and the landing.
    local estimate = (tier.turns * 2 + tier.escape + 1) * st.decision

    return st, estimate
end

function M.render(enc, now)
    local st = enc.state
    return {
        phaseId = st.phaseId,
        phase = st.phase,
        cue = st.cue, nextCue = st.nextCue,
        telegraphIn = st.telegraphAt - now,
        deadlineIn = st.deadlineAt - now,
        switchIn = st.switchAt and (st.switchAt - now) or nil,
        staminaPct = math.max(0, math.floor(st.stamina / st.maxStamina * 100)),
        linePct = math.max(0, math.floor(st.line / st.maxLine * 100)),
        pressure = st.pressure, escapeThreshold = st.tier.escape,
        turn = st.turn, turns = st.tier.turns,
        -- `required` is deliberately absent.
    }
end

function M.act(enc, action, now)
    local st = enc.state

    local hit
    if action == 'advance' then
        hit = false                                  -- the turn expired
    elseif now > st.deadlineAt + GRACE then
        hit = false                                  -- answered too late
    else
        hit = (action == st.required)
    end

    if hit then
        if st.phase == 'LANDING' then
            st.stamina = 0
            return { render = M.render(enc, now), outcome = 'success', value = 1 }
        end
        local bite = st.perTurn
        if st.action == 'REST' then bite = bite * st.restMult end
        st.stamina = st.stamina - bite
        st.answered = st.answered + 1
    else
        st.stamina = math.min(st.maxStamina, st.stamina + st.recover)
        if st.phase == 'LANDING' then
            st.stamina = LANDING_RECOVERY
        elseif st.action == 'RUN' then
            st.line = st.line - st.tier.mistake
        elseif st.action == 'DIVE' then
            st.line = st.line - math.floor(st.tier.mistake * DIVE_MULT)
        elseif st.action == 'THRASH' then
            st.pressure = st.pressure + 1
        elseif st.action == 'JUMP' then
            st.pressure = st.pressure + 2
        end
        -- REST answered wrongly costs only the turn: the fish gets its breath back.
    end

    if st.line <= 0 then
        return { render = M.render(enc, now), outcome = 'snap', value = hit and 1 or 0 }
    end
    if st.pressure >= st.tier.escape then
        return { render = M.render(enc, now), outcome = 'escape', value = hit and 1 or 0 }
    end

    st.turn = st.turn + 1
    if st.stamina <= 0 then
        -- Forced, because the chain gives no guarantee of a REST: an unlucky sequence
        -- would otherwise leave a tired fish with no way to land it.
        armTurn(st, now, 'LANDING')
    else
        armTurn(st, now, nextAction(st))
    end

    return { render = M.render(enc, now), outcome = nil, value = hit and 1 or 0 }
end

Encounter.Register('fish_mindgame', M)
```

- [ ] **Step 5: Add the npm script**

In `tests/package.json`, add to `scripts`:

```json
    "test:encounter-mindgame": "node luarun.mjs tests/encounter_mindgame.test.lua",
```

and append ` && npm run test:encounter-mindgame` to `test:all`.

- [ ] **Step 6: Run the tests to verify they pass**

```bash
node tests/luarun.mjs tests/encounter_mindgame.test.lua
```

Expected: sixteen `ok -` lines then `16 tests passed`.

M6 and M14 scan seeds to find an `erratic` fish that emits `JUMP`/`THRASH` and a fake.
If either exhausts its range, widen the seed loop before touching the weights — and if
widening does not help, print what the chain actually produced, because that means
`nextAction` is not reaching those entries at all.

- [ ] **Step 7: Re-run every suite**

```bash
cd tests && npm run test:all
```

Expected: 12 suites, 221 + 16 = 237 tests, exit 0. `counter_pull`'s 13 must be among them, unchanged.

- [ ] **Step 8: Commit**

```bash
git add server/encounter_mindgame.lua tests/encounter_mindgame.test.lua tests/harness.lua tests/package.json
git commit -m "feat: add the fish mindgame turn model"
```

---

## Task 2: Per-encounter key maps in the bridge

`client/encounter.lua` currently polls one fixed key map built for `counter_pull`. A
mindgame session needs four different action names on the same four controls.

**Files:**
- Modify: `client/encounter.lua`
- Modify: `tests/client_encounter.test.lua`

- [ ] **Step 1: Write the failing bridge tests**

Append to `tests/client_encounter.test.lua`, before `H.run()`:

```lua
-- ---------------------------------------------------------------- per-encounter keys

-- Presses a control and returns the action the bridge sent for it, or nil.
local function pressAndRead(control)
    local before = #sent
    _G.__PRESS(control)
    for _, thread in ipairs(H.THREADS) do thread() end
    for i = before + 1, #sent do
        if sent[i].name == 'zfishing:encounter:act' then return sent[i].args[4] end
    end
    return nil
end

test('B11 counter-pull maps the four controls to its own action names', function()
    loadBridge(happyServer())
    biteAndHook('counter_pull')
    equal(pressAndRead(34), 'left')
    equal(pressAndRead(35), 'right')
    equal(pressAndRead(33), 'brace')
    equal(pressAndRead(22), 'reel')
end)

test('B12 the mindgame maps the same controls to its own action names', function()
    loadBridge(happyServer())
    biteAndHook('fish_mindgame')
    equal(pressAndRead(34), 'give_line')
    equal(pressAndRead(33), 'brace')
    equal(pressAndRead(35), 'hold')
    equal(pressAndRead(22), 'reel')
end)

test('B13 an encounter with no key map polls nothing rather than sending nonsense', function()
    loadBridge(happyServer())
    biteAndHook('sonar_strike')
    equal(pressAndRead(34), nil, 'an unmapped encounter must send no action at all')
end)
```

- [ ] **Step 2: Run them to verify they fail**

```bash
node tests/luarun.mjs tests/client_encounter.test.lua
```

Expected: B11 passes (counter-pull already works), B12 and B13 fail — the mindgame press sends `left`.

- [ ] **Step 3: Key the map on the encounter type**

In `client/encounter.lua`, replace the single `KEYS` table with:

```lua
-- control -> action, per encounter. The four controls are the same everywhere because
-- all four are analog on a gamepad already, so controller support needs no separate
-- mapping and no mashing; only the action names differ.
--
-- The mindgame's four responses are not directional, so their meaning is carried by the
-- on-screen label beside each keycap rather than by the key's position. That is
-- affordable there and not in counter-pull, because a mindgame turn is a considered
-- choice with seconds to read, not a reflex.
local KEYMAPS = {
    counter_pull = {
        { action = 'left',  control = 34 },   -- INPUT_MOVE_LEFT_ONLY   (A / stick left)
        { action = 'right', control = 35 },   -- INPUT_MOVE_RIGHT_ONLY  (D / stick right)
        { action = 'brace', control = 33 },   -- INPUT_MOVE_DOWN_ONLY   (S / stick down)
        { action = 'reel',  control = 22 },
    },
    fish_mindgame = {
        { action = 'give_line', control = 34 },
        { action = 'brace',     control = 33 },
        { action = 'hold',      control = 35 },
        { action = 'reel',      control = 22 },
    },
}
```

and in the polling thread, read the map for the live encounter:

```lua
    CreateThread(function()
        -- An encounter with no map polls nothing: sending another encounter's action
        -- names would only earn a bad_action per keypress.
        local keys = KEYMAPS[ENC.type]
        while ENC.active and ZClient.active do
            if keys and not ENC.inFlight then
                for _, k in ipairs(keys) do
                    if IsDisabledControlJustPressed(0, k.control) then
                        send(k.action)
                        break
                    end
                end
            end
            Wait(0)
        end
    end)
```

- [ ] **Step 4: Run the bridge suite**

```bash
node tests/luarun.mjs tests/client_encounter.test.lua
```

Expected: thirteen `ok -` lines then `13 tests passed`.

- [ ] **Step 5: Re-run every suite**

```bash
cd tests && npm run test:all
```

Expected: 12 suites, 240 tests, exit 0.

- [ ] **Step 6: Commit**

```bash
git add client/encounter.lua tests/client_encounter.test.lua
git commit -m "feat: key the bridge input map on the live encounter"
```

---

## Task 3: The mindgame NUI

**Files:**
- Modify: `web/src/encounters/types.ts`
- Modify: `web/src/encounters/EncounterHost.tsx`
- Create: `web/src/encounters/FishMindgame.tsx`
- Modify: `web/src/style.css`

- [ ] **Step 1: Add the mindgame state type and discriminate the message**

In `web/src/encounters/types.ts`, append:

```typescript
export type FishAction = 'RUN' | 'DIVE' | 'THRASH' | 'JUMP' | 'REST' | 'LANDING'

// server/encounter_mindgame.lua's M.render(enc, now). Durations, never timestamps, and
// no field naming the correct response.
export type MindgameState = {
  phaseId: number
  phase: 'TURN' | 'LANDING'
  cue: FishAction
  nextCue?: FishAction
  telegraphIn: number
  deadlineIn: number
  switchIn?: number
  staminaPct: number
  linePct: number
  pressure: number
  escapeThreshold: number
  turn: number
  turns: number
}
```

and replace `EncounterMessage` with a discriminated union so a component can never be
handed the wrong shape:

```typescript
export type EncounterMessage =
  | { type: 'counter_pull';  difficulty: number; state: CounterPullState; startedAt: number }
  | { type: 'fish_mindgame'; difficulty: number; state: MindgameState;    startedAt: number }
```

- [ ] **Step 2: Dispatch on the type**

Rewrite `web/src/encounters/EncounterHost.tsx`'s body so each branch keeps its own state,
which is what makes the union safe:

```tsx
import { useEffect, useState } from 'react'
import { useNuiEvent } from '../hooks/useNui'
import CounterPull from './CounterPull'
import FishMindgame from './FishMindgame'
import type { EncounterMessage, Outcome } from './types'

// One shell for every encounter, so they read as one product: same panel material, same
// typography, same success/failure language. Only the fight inside differs.
export default function EncounterHost({ msg }: { msg: EncounterMessage }) {
  const [state, setState] = useState<any>(msg.state)
  const [outcome, setOutcome] = useState<Outcome | null>(null)

  // React state moves on a TRANSITION, never per frame.
  useNuiEvent((m) => {
    if (m.action !== 'encounterState') return
    if (m.state) setState(m.state)
    if (m.outcome) setOutcome(m.outcome)
  })

  useEffect(() => { setState(msg.state); setOutcome(null) }, [msg.startedAt])

  switch (msg.type) {
    case 'counter_pull':
      return <CounterPull state={state} outcome={outcome} />
    case 'fish_mindgame':
      return <FishMindgame state={state} outcome={outcome} />
    default:
      return null
  }
}
```

The `any` on `state` is deliberate and load-bearing: the payload arrives untyped over the
NUI message channel, and the `switch` is what narrows it. Typing it as the union would
force a cast at every use site instead of one.

- [ ] **Step 3: Write the mindgame UI**

Create `web/src/encounters/FishMindgame.tsx`:

```tsx
import { useEffect, useMemo, useRef, useState } from 'react'
import { fetchNui } from '../hooks/useNui'
import { t } from '../i18n'
import Keycap from '../components/Keycap'
import type { FishAction, MindgameState, Outcome } from './types'

// What the fish is doing. Shape and text, never colour alone.
const ACTIONS: Record<FishAction, { glyph: string; label: string }> = {
  RUN:     { glyph: '⇥', label: 'enc_mg_run' },
  DIVE:    { glyph: '⤓', label: 'enc_mg_dive' },
  THRASH:  { glyph: '⇋', label: 'enc_mg_thrash' },
  JUMP:    { glyph: '⤒', label: 'enc_mg_jump' },
  REST:    { glyph: '◦', label: 'enc_mg_rest' },
  LANDING: { glyph: '⚓', label: 'enc_mg_landing' },
}

// The four responses, in the order the bridge maps them. Labels carry the meaning; the
// keycaps carry the input. There is no click handler on purpose -- the fight runs
// without NUI focus, so a click could never fire.
const RESPONSES: { key: string; label: string }[] = [
  { key: 'A',     label: 'enc_mg_give_line' },
  { key: 'S',     label: 'enc_mg_brace' },
  { key: 'D',     label: 'enc_mg_hold' },
  { key: 'SPACE', label: 'enc_mg_reel' },
]

export default function FishMindgame(
  { state, outcome }: { state: MindgameState; outcome: Outcome | null }
) {
  // Anchored once per authoritative turn, keyed on phaseId. See CounterPull for why a
  // ref mutated inside an effect is not good enough.
  const timing = useMemo(() => {
    const receivedAt = Date.now()
    return {
      deadlineAt: receivedAt + state.deadlineIn,
      switchAt: state.switchIn === undefined ? undefined : receivedAt + state.switchIn,
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [state.phaseId])

  const [shown, setShown] = useState<FishAction>(state.cue)
  const [faked, setFaked] = useState(false)
  const barRef = useRef<HTMLDivElement | null>(null)

  useEffect(() => { setShown(state.cue); setFaked(false) }, [state.phaseId, state.cue])

  // The only per-frame work, written straight to the DOM node.
  useEffect(() => {
    let raf = 0
    const start = Date.now()
    const span = Math.max(1, timing.deadlineAt - start)
    const tick = () => {
      const el = barRef.current
      if (el) {
        const p = Math.min(1, Math.max(0, (Date.now() - start) / span))
        el.style.width = `${(1 - p) * 100}%`
      }
      raf = requestAnimationFrame(tick)
    }
    raf = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(raf)
  }, [timing])

  // The fish changes its mind, visibly and with time left to reconsider.
  useEffect(() => {
    if (timing.switchAt === undefined || !state.nextCue) return
    const id = setTimeout(() => { setShown(state.nextCue as FishAction); setFaked(true) },
      Math.max(0, timing.switchAt - Date.now()))
    return () => clearTimeout(id)
  }, [timing, state.nextCue])

  // The turn expired and the player chose nothing. The server decides what that means.
  useEffect(() => {
    if (outcome) return
    const id = setTimeout(() => { fetchNui('encounterAction', { action: 'advance' }) },
      Math.max(0, timing.deadlineAt - Date.now()) + 300)
    return () => clearTimeout(id)
  }, [timing, outcome])

  useEffect(() => {
    if (!outcome) return
    const id = setTimeout(() => fetchNui('encounterClosed', {}), 700)
    return () => clearTimeout(id)
  }, [outcome])

  const cue = ACTIONS[shown]
  const danger = state.linePct <= 33 || state.pressure >= state.escapeThreshold - 1

  return (
    <div className={`hud-panel enc-panel mg-panel${danger ? ' hud-panel--danger' : ''}`}>
      <div className="panel-title">
        {t('enc_mg_title')} <span className="mg-turn">{state.turn}/{state.turns}</span>
      </div>

      <div className={`mg-cue${faked ? ' mg-cue--faked' : ''}`} role="status">
        <span className="enc-glyph" aria-hidden="true">{cue.glyph}</span>
        <span className="enc-cue-text">{t(cue.label)}</span>
      </div>

      <div className="bar-track enc-window"><div className="bar-fill enc-window-fill" ref={barRef} /></div>

      <div className="mg-responses">
        {RESPONSES.map((r) => (
          <div className="mg-response" key={r.key}>
            <Keycap label={r.key} />
            <span className="mg-response-text">{t(r.label)}</span>
          </div>
        ))}
      </div>

      <div className="bar-row">
        <div className="bar-label">{t('enc_stamina')}</div>
        <div className="bar-caption">{state.staminaPct}%</div>
      </div>
      <div className="bar-track"><div className="bar-fill energy-fill" style={{ width: `${state.staminaPct}%` }} /></div>

      <div className="bar-row">
        <div className="bar-label">{t('enc_mg_pressure')}</div>
        <div className="bar-caption">{state.pressure}/{state.escapeThreshold}</div>
      </div>
      <div className="bar-track"><div className="bar-fill enc-line-fill" style={{ width: `${state.linePct}%` }} /></div>

      {outcome && <div className="enc-outcome">{t(`enc_outcome_${outcome}`)}</div>}
    </div>
  )
}
```

- [ ] **Step 4: Add the styles**

Append to `web/src/style.css`:

```css
/* Mindgame. Reuses the encounter shell; only the telegraph and the response row are
   new, because the fight is a decision rather than a direction. */
.mg-panel { min-width: 26vw; }
.mg-turn { opacity: .6; font-size: .82em; margin-left: .4vw; }

.mg-cue {
  display: flex; align-items: center; justify-content: center; gap: 0.6vw;
  padding: 0.8vh 0 0.6vh;
}
/* A fake flips visibly -- the change itself has to be perceptible, not just the result. */
.mg-cue--faked .enc-glyph { animation: mg-flip 320ms ease-out; }
@keyframes mg-flip {
  0%   { transform: rotateX(90deg) scale(.8); opacity: .2; }
  100% { transform: rotateX(0) scale(1); opacity: 1; }
}

.mg-responses {
  display: grid; grid-template-columns: repeat(2, 1fr);
  gap: 0.4vh 0.8vw; margin: 0.8vh 0 0.4vh;
}
.mg-response { display: flex; align-items: center; gap: 0.45vw; }
.mg-response-text { font-size: 1.2vh; letter-spacing: .03em; }

@media (prefers-reduced-motion: reduce) {
  .mg-cue--faked .enc-glyph { animation: none; }
}
```

- [ ] **Step 5: Type-check**

```bash
cd web && npx tsc --noEmit
```

Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add web/src/encounters web/src/style.css
git commit -m "feat: render the fish mindgame in the NUI"
```

---

## Task 4: Web tests and locale strings

**Files:**
- Create: `web/src/encounters/__tests__/FishMindgame.test.tsx`
- Modify: `locales/en.json`, `locales/th.json`

- [ ] **Step 1: Add the strings**

Add to **both** locale files:

| key | en | th |
| --- | --- | --- |
| `enc_mg_title` | `Read the fish` | `อ่านปลา` |
| `enc_mg_run` | `Running` | `ปลาวิ่ง` |
| `enc_mg_dive` | `Diving` | `ปลาดำ` |
| `enc_mg_thrash` | `Thrashing` | `ปลาสะบัด` |
| `enc_mg_jump` | `Jumping` | `ปลากระโดด` |
| `enc_mg_rest` | `Resting` | `ปลาพัก` |
| `enc_mg_landing` | `Bring it in` | `ดึงขึ้นมา` |
| `enc_mg_give_line` | `Give line` | `ปล่อยสาย` |
| `enc_mg_brace` | `Brace` | `ยันไว้` |
| `enc_mg_hold` | `Hold` | `จับนิ่ง` |
| `enc_mg_reel` | `Reel` | `รีล` |
| `enc_mg_pressure` | `Escape risk` | `ความเสี่ยงหลุด` |

- [ ] **Step 2: Write the component tests**

Create `web/src/encounters/__tests__/FishMindgame.test.tsx`:

```tsx
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render, act } from '@testing-library/react'
import FishMindgame from '../FishMindgame'
import type { MindgameState } from '../types'

const posted: { event: string; data: any }[] = []
vi.mock('../../hooks/useNui', () => ({
  fetchNui: (event: string, data?: unknown) => {
    posted.push({ event, data })
    return Promise.resolve({})
  },
}))

const base = (over: Partial<MindgameState> = {}): MindgameState => ({
  phaseId: 1, phase: 'TURN', cue: 'DIVE',
  telegraphIn: 0, deadlineIn: 2200,
  staminaPct: 100, linePct: 100, pressure: 0, escapeThreshold: 3,
  turn: 1, turns: 5,
  ...over,
})

beforeEach(() => { posted.length = 0; vi.useFakeTimers() })
afterEach(() => { vi.useRealTimers() })

describe('FishMindgame', () => {
  it('gives every fish action its own glyph and text', () => {
    const seen = new Set<string>()
    for (const cue of ['RUN', 'DIVE', 'THRASH', 'JUMP', 'REST', 'LANDING'] as const) {
      const { unmount } = render(<FishMindgame state={base({ cue })} outcome={null} />)
      const glyph = document.querySelector('.mg-cue .enc-glyph')!.textContent!
      expect(seen.has(glyph)).toBe(false)
      seen.add(glyph)
      expect(document.querySelector('.mg-cue .enc-cue-text')!.textContent!.length).toBeGreaterThan(0)
      unmount()
    }
  })

  it('always offers all four responses with their keycaps', () => {
    render(<FishMindgame state={base()} outcome={null} />)
    expect(document.querySelectorAll('.mg-response')).toHaveLength(4)
    expect(document.querySelectorAll('.mg-response .keycap')).toHaveLength(4)
  })

  it('shows the turn counter', () => {
    render(<FishMindgame state={base({ turn: 3, turns: 7 })} outcome={null} />)
    expect(document.querySelector('.mg-turn')!.textContent).toBe('3/7')
  })

  it('shows the decoy first, then flips to the real action and marks the flip', () => {
    render(
      <FishMindgame
        state={base({ cue: 'REST', nextCue: 'DIVE', switchIn: 900 })}
        outcome={null}
      />
    )
    const first = document.querySelector('.mg-cue .enc-glyph')!.textContent
    expect(document.querySelector('.mg-cue--faked')).toBeNull()
    act(() => { vi.advanceTimersByTime(950) })
    expect(document.querySelector('.mg-cue .enc-glyph')!.textContent).not.toBe(first)
    expect(document.querySelector('.mg-cue--faked')).not.toBeNull()
  })

  it('carries the danger treatment as escape risk approaches the threshold', () => {
    const { container, rerender } = render(
      <FishMindgame state={base({ pressure: 0 })} outcome={null} />
    )
    expect(container.querySelector('.hud-panel--danger')).toBeNull()
    rerender(<FishMindgame state={base({ phaseId: 2, pressure: 2 })} outcome={null} />)
    expect(container.querySelector('.hud-panel--danger')).not.toBeNull()
  })

  it('posts advance once per turn, and re-arms for the next one', () => {
    const { rerender } = render(<FishMindgame state={base()} outcome={null} />)
    act(() => { vi.advanceTimersByTime(2000) })
    expect(posted.filter((p) => p.data?.action === 'advance')).toHaveLength(0)
    act(() => { vi.advanceTimersByTime(1000) })
    expect(posted.filter((p) => p.data?.action === 'advance')).toHaveLength(1)

    rerender(<FishMindgame state={base({ phaseId: 2, turn: 2 })} outcome={null} />)
    act(() => { vi.advanceTimersByTime(3000) })
    expect(posted.filter((p) => p.data?.action === 'advance')).toHaveLength(2)
  })

  it('renders the outcome and closes the presentation', () => {
    render(<FishMindgame state={base()} outcome="escape" />)
    expect(document.querySelector('.enc-outcome')!.textContent!.length).toBeGreaterThan(0)
    act(() => { vi.advanceTimersByTime(800) })
    expect(posted.some((p) => p.event === 'encounterClosed')).toBe(true)
  })

  it('never sends the server a timing value it could trust', () => {
    render(<FishMindgame state={base()} outcome={null} />)
    act(() => { vi.advanceTimersByTime(4000) })
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

Expected: the Lua hash snapshot fails, because Lua changed in Tasks 1-2. Re-record it and re-run:

```bash
cd web && npx vitest --run -u src/__tests__/bundleRebuildPreservation.test.ts && npm test
```

Expected then: 78 + 8 = 86 tests, all passing.

- [ ] **Step 4: Commit**

```bash
git add web/src/encounters/__tests__ locales/en.json locales/th.json web/src/__tests__/__snapshots__/bundleRebuildPreservation.test.ts.snap
git commit -m "test: cover the fish mindgame UI state transitions"
```

---

## Task 5: Wire, build and document

**Files:**
- Modify: `fxmanifest.lua`
- Rebuild and commit: `web/dist`
- Modify: `docs/ARCHITECTURE.md`, `docs/testing/zfishing-live-e2e-checklist.md`

- [ ] **Step 1: Load the module**

In `fxmanifest.lua`, add `'server/encounter_mindgame.lua',` to `server_scripts`
immediately after `'server/encounter_counter_pull.lua',`.

- [ ] **Step 2: Rebuild the bundle**

```bash
cd web && npm run build
```

- [ ] **Step 3: Re-run everything**

```bash
cd tests && npm run test:all
```

Expected: 12 suites, 240 tests, exit 0.

```bash
cd web && npx vitest --run -u src/__tests__/bundleRebuildPreservation.test.ts && npm test && npx tsc --noEmit
```

Expected: 86 tests passing, no type errors.

- [ ] **Step 4: Document**

Add `### 12.11 Fish Mindgame` to `docs/ARCHITECTURE.md`: the five fish actions and four
responses; the response table with its wrong-answer costs and why `RUN` and `JUMP` share
an answer; the four behaviour chains and what a player learns from each; the tier table;
why `turns` is the tier and why `drainRate` deliberately does not multiply it; the forced
landing turn and the unwinnable-chain problem it removes; the 700ms fake lead and why it
is longer than counter-pull's 400ms.

Add a change-history entry under `## 13`, stating plainly that no fish is configured to
use the mindgame yet and that nothing was run in FiveM.

Extend section L of `docs/testing/zfishing-live-e2e-checklist.md` with a Mindgame block:
FORCED mindgame at tier 1 and tier 5; each of the five fish actions answered correctly;
each wrong-answer cost observed (line on RUN, more line on DIVE, escape risk on THRASH
and double on JUMP); a REST answered with REEL taking a visibly bigger bite; a tier 4+
fake flipping with time to react; a forced landing after a chain that never rested; a
fumbled landing resuming the fight; an escape by escape-risk and a snap by line; a
walk-away timeout; and a controller run. Leave every box unticked.

- [ ] **Step 5: Commit**

```bash
git add fxmanifest.lua web/dist docs/ARCHITECTURE.md docs/testing/zfishing-live-e2e-checklist.md web/src/__tests__/__snapshots__/bundleRebuildPreservation.test.ts.snap
git commit -m "feat: ship the fish mindgame end to end"
```

---

## Phase C completion checklist

```bash
cd tests && npm run test:all
cd web && npm test && npx tsc --noEmit
```

Expected state at the end of Phase C:

- `Encounter.Playable('fish_mindgame')` is true; FORCED reaches the real fight.
- `sonar_strike` still downgrades to legacy.
- No fish resolves to either new encounter on its own — DEFAULT is still the legacy fight for everyone until Phase F.
- Live behaviour is **unverified**: nothing in this phase has been run inside FiveM.

## Known limitations to carry into the completion report

**Fake telegraphs are advisory against a modified client**, exactly as in counter-pull:
`nextCue` ships with `cue` because the NUI must draw the flip. A modified client can read
the real action up front. It still has to send a response the server accepts for that
action.

**Response meaning is carried by the label, not the key.** `give_line` on A and `hold` on
D are arbitrary pairings; a player who ignores the on-screen text has nothing to fall
back on. That is affordable in a turn-based encounter with seconds to read, and would not
be in counter-pull.
