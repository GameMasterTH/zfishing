# Fish Mindgame (Phase C) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `fish_mindgame` — read, decide, counter. A turn-based fight where the difficulty is knowing *what* to answer, not how fast, and where a player who has fought a behaviour before genuinely knows more than one who has not.

**Architecture:** `server/encounter_mindgame.lua` implements the same module contract `counter_pull` uses, so nothing in `server/encounter.lua`, `server/session.lua` or the claim path changes. Each turn is a telegraph the player watches, followed by a decision window the player answers into; the server owns both. The client bridge gains a per-encounter key map. The NUI gains a second component behind the existing `EncounterHost`.

**Tech Stack:** Lua 5.4 (FiveM `cerulean`), ox_lib callbacks, wasmoon test harness, React 18 + Vitest.

**Spec:** `docs/superpowers/specs/2026-08-20-zfishing-encounter-system-design.md` §5, plus `docs/ARCHITECTURE.md` §12.

**Prerequisite — verify before starting:**

```bash
grep -c "Encounter.Register" server/encounter_counter_pull.lua && grep -c "phaseId" web/src/encounters/types.ts
```

Both must be non-zero. Phase B merged to `main` at `127053d`, where 221 Lua tests and 78 web tests pass. This plan's branch is `encounter-mindgame`, cut from that merge.

## Global Constraints

- **The module contract is fixed and unchanged.** `build(ctx) -> state, estimate`, `render(enc, now)`, `act(enc, action, now) -> { render, outcome, value }`, `state.deadline` absolute, `Encounter.Register(id, mod)`. Phase C adds a module; it does not touch the framework. In particular there is **no new "rejected without consuming the turn" result** — that would change the shared dispatcher and drag `counter_pull` into a Phase C change.
- **Absolute time never leaves the server.** `render` emits `...In` durations only.
- **Every authoritative transition carries `phaseId`.** Not `turnId` — see the note below.
- **No render payload names the correct response.** The player reads the fish; the payload does not spell out the answer.
- **The number of correct reads a fight costs is `tier.turns`, exactly, always.** No behaviour, no rod, no reel and no mistake may change it. That count is the encounter's content; gear buys survival, never a shorter fight.
- **Nothing may perturb a behaviour chain except the turn itself.** A decoy, a fake roll, a render — none of them may advance `chainAt`.
- **A player is never scored against an action the UI was not showing them.** Answers are accepted only from the moment the decision window opens, and any fake has already flipped to the truth by then.
- **Responsibility boundary:** server = gameplay authority; client = orchestration; NUI = presentation.
- **Lua files stay flat.** `tests/luarun.mjs` mounts `client/`, `server/`, `shared/`, `tests/` non-recursively.
- **`legacy_tension` and `counter_pull`'s Lua modules are untouched.** No gameplay change to either, and every existing `counter_pull` test must stay green. Task 4 does fix one shipped HUD defect in `CounterPull.tsx` — see below; that is a presentation correction, not a gameplay change.
- **Baseline to preserve:** `cd tests && npm run test:all` reports 11 suites / 221 tests; `npm --prefix web test` reports 78. Both must pass at the end of every task.
- Stable ids verbatim: encounter `fish_mindgame`; fish actions `RUN`, `DIVE`, `THRASH`, `JUMP`, `REST`; player responses `give_line`, `brace`, `hold`, `reel`, plus the universal `advance`; landing phase `LANDING`.

### One deliberate naming decision

The Phase B review suggested the transition-id pattern generalize as
`phaseId` / `turnId` / `attemptId` per encounter. This plan uses **`phaseId` for every
encounter instead.** `EncounterHost` and any shared encounter UI would otherwise have to
special-case a field name that means exactly the same thing in all three, and the
per-encounter name buys nothing the `phase` field does not already carry. The contract
word is "authoritative transition id"; the field is `phaseId` everywhere.

### Why the two encounters fake differently

`counter_pull` flips its decoy *inside* the action window. There the feint punishing an
early commitment **is** the mechanic, and with a 700–1400ms window there is no long safe
period to move the flip into.

`fish_mindgame` flips during the telegraph, before any answer is accepted. It has to,
because its whole contract is "timing carries no score" — a turn where answering early
was silently wrong would break that promise in the one place a player cannot see.

The consequence is worth stating plainly: **in the mindgame the fake is presentation, not
protection.** It costs a player who pre-commits their composure and nothing else, and it
gives a modified client no advantage at all, because the truth is on screen for every
client before the first answer the server will take. Write this down in ARCHITECTURE
§12.11 — the next reviewer will otherwise read the difference between the two encounters
as an oversight.

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
- **No device-aware keycaps.** See the known limitations at the end: this is a real gap,
  it is inherited from Phase B, and fixing it for the mindgame alone would make the two
  encounters inconsistent with each other.

---

## File Structure

| File | Responsibility | Task |
| --- | --- | --- |
| `server/encounter_mindgame.lua` | **Create.** Behaviour chains, telegraph/decision turns, response scoring, landing. | 1 |
| `tests/encounter_mindgame.test.lua` | **Create.** The fight, deterministic throughout. | 1 |
| `tests/harness.lua` | **Modify.** A `stats` override so a test can choose its gear. | 1 |
| `tests/package.json` | **Modify.** Script + `test:all`. | 1, 2 |
| `client/encounter.lua` | **Modify.** Per-encounter key maps. | 2 |
| `tests/client_encounter.test.lua` | **Modify.** Key-map routing coverage. | 2 |
| `web/src/encounters/types.ts` | **Modify.** `MindgameState`, discriminated `EncounterMessage`. | 3 |
| `web/src/encounters/EncounterHost.tsx` | **Modify.** Typed dispatch on `msg.type`. | 3 |
| `web/src/encounters/FishMindgame.tsx` | **Create.** Telegraph, decision window, four responses. | 3 |
| `web/src/style.css` | **Modify.** Mindgame classes in the existing language. | 3 |
| `web/src/encounters/__tests__/FishMindgame.test.tsx` | **Create.** | 4 |
| `web/src/encounters/CounterPull.tsx` | **Modify.** Uncross the line and miss bars — a Phase B defect. | 4 |
| `web/src/encounters/__tests__/CounterPull.test.tsx` | **Modify.** One test pinning each bar to its own number. | 4 |
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
  `{ phaseId, phase, cue, nextCue?, telegraphIn, windowOpensIn, windowClosesIn, switchIn?, progress, reads, linePct, pressure, escapeThreshold }`.

### The shape of a turn

```
armTurn(now)
 |
 |<--------------------- TELEGRAPH 1400ms, uniform --------------------->|
 |                                                                       |
 |          a fake flips at +600ms, and from there on every client        |
 |          is looking at the real action                                 |
 |                                                                       |
 |                              answers accepted from +1150ms (GRACE) ----|
 |                                                                       |
 |                                                   |<-- decision window (tier) -->|
                                                                                    |
                                                                              deadline
```

Two properties fall out of this, and both are load-bearing:

- **An answer during the telegraph is a miss** — the same rule `counter_pull` already
  applies to a pre-window press. That is only fair here because the UI draws a visibly
  shut window and dimmed responses for the whole telegraph, which Task 3 owns.
- **Inside the window, timing carries no score whatsoever.** The first accepted
  millisecond and the last are worth exactly the same. This is the encounter's identity:
  difficulty is knowing *what*, never *when*.

`TELEGRAPH` is a constant rather than a tier field on purpose: if a faking turn ran longer
than an honest one, a fake would be detectable with a stopwatch instead of by reading the
fish.

### The response table

`RUN` and `JUMP` share a correct answer on purpose: they differ in the *cost of being
wrong*, not in the answer. Knowing the fish tells you how bad a mistake is about to be,
which is the point of the encounter — it is not rock-paper-scissors with five hands.

| fish action | correct | on correct | on wrong |
| --- | --- | --- | --- |
| `RUN` | `give_line` | progress +1 | line − `mistake` |
| `DIVE` | `brace` | progress +1 | line − `mistake × 1.5` |
| `THRASH` | `hold` | progress +1 | escape risk +1 |
| `JUMP` | `give_line` | progress +1 | escape risk +2 |
| `REST` | `reel` | progress +1, **line + `12 × reelDrain`** | escape risk +1 |
| `LANDING` | `reel` | **success** | escape risk +1, progress −1 |

Three things this table is built to guarantee:

1. **Every correct read is worth exactly +1, and the fight needs exactly `tier.turns` of
   them.** No multiplier anywhere. A wrong answer costs the turn and a resource; it does
   not cost progress, so the read count cannot drift with skill or with gear.
2. **A better reel changes one number inside the fight: the line a well-answered `REST`
   gives back** (plus the width of the landing turn). That is the whole of what gear buys
   once the fight has started.
3. **Every wrong answer spends a bounded resource** — line, or escape risk. Including a
   wrong `REST`, which is what stops a player from answering rests wrong forever and never
   resolving. This is what makes fight length provably bounded, and it is what the
   estimate in `M.build` is derived from.

### Behaviour chains

Three of the four real behaviours are fixed cycles, so a player can learn them; only
`erratic` is weighted random.

| behavior | chain | what a player learns |
| --- | --- | --- |
| `steady_light` | RUN → REST → RUN → THRASH | most predictable; safe to learn on |
| `steady_heavy` | DIVE → DIVE → REST | "catfish dives twice, then rests" |
| `run_stop` | RUN → RUN → REST | long runs, then a reel opportunity |
| `erratic` | weighted random incl. JUMP | cannot be pre-read; answer live |

The chain is authoritative state. `nextAction` is the **only** function allowed to advance
it, and it is called exactly once per turn. A decoy comes from `pickDecoy`, which draws
from a plain list and touches nothing.

- [ ] **Step 1: Let a test choose the gear it fights with**

`H.loadSession`'s rig stub hardcodes `lineRating = 10, reelDrain = 1.0`, so no test can
currently show what better gear buys. Add an override. In `tests/harness.lua`, inside
`H.loadSession`, replace the `stats` entry of the `Rig` stub with:

```lua
        stats = function()
            local base = { lineRating = 10, reelDrain = 1.0, hook = 'hook_4', floatBiteSpeed = 1.0 }
            for k, v in pairs(opts.stats or {}) do base[k] = v end
            return base
        end,
```

`opts.stats` only applies on the assembled-rod path, so a test that wants it must also pass
`rig = true`.

- [ ] **Step 2: Write the failing module tests**

Create `tests/encounter_mindgame.test.lua`:

```lua
-- Fish Mindgame. Run from the resource root:
--   node tests/luarun.mjs tests/encounter_mindgame.test.lua
--
-- Sequencing, replay, stale challenge, wrong session and disconnect are covered once for
-- every encounter in tests/encounter_action.test.lua. This suite is the fight.
--
-- Deterministic throughout: three of the four behaviours are fixed chains, and the fourth
-- is pinned with H.withSeed.

dofile('tests/harness.lua')
local test, equal, truthy = H.test, H.equal, H.truthy

local FISH = { species = 'catfish', label = 'Catfish', weight = 9.0, quality = 3,
    rarity = 'uncommon', behavior = 'steady_heavy', biteDelay = 100, hookWindow = 1500,
    tensionDiff = 1.15, fishEnergy = 50, xp = 20, price = 14, difficulty = 2 }

local CORRECT = { RUN = 'give_line', DIVE = 'brace', THRASH = 'hold',
                  JUMP = 'give_line', REST = 'reel', LANDING = 'reel' }
local TIER_READS = { 3, 4, 5, 7, 9 }

local function start(opts)
    opts = opts or {}
    local fish = H.deepcopy(FISH)
    if opts.difficulty then fish.difficulty = opts.difficulty end
    if opts.behavior then fish.behavior = opts.behavior end

    local g = {}
    local run = function()
        g.calls = H.loadSession({ fish = fish, encounterMode = 'forced',
                                  forcedEncounter = 'fish_mindgame',
                                  rig = opts.rig, stats = opts.stats })
        dofile('server/encounter_mindgame.lua')
        local cast = H.CB['zfishing:cast'](5, 0.5, opts.rig and 1 or nil)
        truthy(cast.ok, tostring(cast.reason))
        H.fireLatestTimer()
        local hook = H.CB['zfishing:hook'](5, cast.sessionId)
        truthy(hook.ok); truthy(hook.challengeId); truthy(hook.encounter)
        g.expiryMs = H.TIMERS[#H.TIMERS].ms      -- Encounter.Begin's expiry timer
        g.sid, g.cid = cast.sessionId, hook.challengeId
        g.last, g.at, g.seq = hook.encounter, _G.__NOW, 0
    end
    if opts.seed then H.withSeed(opts.seed, run) else run() end
    return g
end

-- Acts `offset` ms after the render was taken. The default lands just inside the decision
-- window, because during the telegraph nothing is accepted -- see M13.
local function act(g, action, offset)
    _G.__NOW = g.at + (offset or (g.last.windowOpensIn + 200))
    g.seq = g.seq + 1
    local res = H.CB['zfishing:encounter:act'](5, g.sid, g.cid, g.seq, action)
    if res.ok and res.state then g.last, g.at = res.state, _G.__NOW end
    return res
end

-- What an honest player is looking at when the window opens. On a faking turn the server
-- still carries the decoy in `cue` and the truth in `nextCue` -- the flip itself is drawn
-- client-side -- and by the time answers are accepted the truth is what is on screen.
local function live(g) return g.last.nextCue or g.last.cue end
local function answer(g) return act(g, CORRECT[live(g)]) end

test('M1 the hook answer opens turn 1 with a telegraph, a shut window and no answer', function()
    local g = start()
    equal(g.last.phase, 'TURN')
    truthy(CORRECT[g.last.cue], 'the cue names a fish action the player can respond to')
    equal(g.last.progress, 0)
    equal(g.last.reads, TIER_READS[2], 'a tier-2 catfish owes four reads')
    truthy(g.last.windowOpensIn > 0, 'the window is still shut when the turn opens')
    truthy(g.last.windowClosesIn > g.last.windowOpensIn)
    equal(g.last.answer, nil, 'the render payload must never carry the answer')
    equal(g.last.correct, nil)
    equal(g.last.deadlineAt, nil, 'absolute server time must never reach a client')
    equal(g.last.windowOpensAt, nil)
    equal(g.last.linePct, 100); equal(g.last.pressure, 0)
end)

test('M2 steady_heavy really does dive twice then rest', function()
    local g = start({ behavior = 'steady_heavy', difficulty = 5 })
    local seen = { live(g) }
    for _ = 1, 2 do
        answer(g)
        seen[#seen + 1] = live(g)
    end
    equal(seen[1], 'DIVE'); equal(seen[2], 'DIVE'); equal(seen[3], 'REST')
end)

test('M3 each behaviour runs its own chain', function()
    local function firstThree(behavior)
        local g = start({ behavior = behavior, difficulty = 5 })
        local out = { live(g) }
        for _ = 1, 2 do answer(g); out[#out + 1] = live(g) end
        return table.concat(out, ',')
    end
    equal(firstThree('steady_light'), 'RUN,REST,RUN')
    equal(firstThree('run_stop'), 'RUN,RUN,REST')
    truthy(#firstThree('erratic') > 0, 'erratic is random but must still produce actions')
end)

test('M4 a correct response is worth one read and costs nothing', function()
    local g = start()
    local res = answer(g)
    truthy(res.ok); equal(res.outcome, nil)
    equal(res.state.progress, 1)
    equal(res.state.linePct, 100)
    equal(res.state.pressure, 0)
    truthy(res.state.phaseId > 1, 'the transition id advances')
end)

test('M5 a wrong answer to DIVE costs more line than a wrong answer to RUN', function()
    local dive = start({ behavior = 'steady_heavy' })
    equal(live(dive), 'DIVE')
    local diveLoss = 100 - act(dive, 'reel').state.linePct

    local run = start({ behavior = 'run_stop' })
    equal(live(run), 'RUN')
    local runLoss = 100 - act(run, 'reel').state.linePct

    truthy(diveLoss > runLoss, 'a botched dive is the expensive mistake')
    truthy(runLoss > 0)
end)

test('M6 a wrong THRASH answer costs one escape risk, a wrong JUMP costs two', function()
    -- erratic is the only chain that emits JUMP; drive it and take the two cases as they
    -- come, so the assertion does not depend on which turn they land on.
    local thrash, jump
    for seed = 1, 40 do
        local g = start({ behavior = 'erratic', difficulty = 5, seed = seed })
        for _ = 1, 6 do
            local cue = live(g)
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

test('M7 a wrong REST answer costs escape risk, which is what bounds the fight', function()
    local g = start({ behavior = 'run_stop', difficulty = 5 })
    answer(g); answer(g)
    equal(live(g), 'REST')
    local res = act(g, 'hold')
    equal(res.state.pressure, 1, 'a rest you fail to punish is a rest the fish gets to use')
    equal(res.state.linePct, 100, 'and it is not a line mistake')
end)

test('M8 a better reel gives more line back on a REST, and no reads back at all', function()
    local function restGain(drain)
        local g = start({ behavior = 'run_stop', difficulty = 5, rig = true,
                          stats = { reelDrain = drain } })
        act(g, 'hold')                              -- a wrong RUN answer, to spend line
        while live(g) ~= 'REST' do answer(g) end
        local before = g.last.linePct
        local res = answer(g)
        return res.state.linePct - before, res.state.reads
    end
    local cheapGain, cheapReads = restGain(1.0)
    local goodGain, goodReads = restGain(1.7)
    truthy(cheapGain > 0, 'a rest well answered gives line back')
    truthy(goodGain > cheapGain,
        ('a better reel gives more back: %d vs %d'):format(goodGain, cheapGain))
    equal(cheapReads, goodReads, 'and never changes what the fight costs in reads')
end)

test('M9 the read count is the tier, for every tier and every readable behaviour', function()
    for tier = 1, 5 do
        for _, behavior in ipairs({ 'steady_light', 'steady_heavy', 'run_stop' }) do
            local g = start({ difficulty = tier, behavior = behavior })
            equal(g.last.reads, TIER_READS[tier],
                ('tier %d declares %d reads'):format(tier, TIER_READS[tier]))
            local answered = 0
            while g.last.phase ~= 'LANDING' do
                local res = answer(g)
                answered = answered + 1
                truthy(res.ok and not res.outcome,
                    ('tier %d %s ended early at read %d'):format(tier, behavior, answered))
                truthy(answered <= 20, 'the fight must reach a landing')
            end
            equal(answered, TIER_READS[tier],
                ('tier %d %s must cost exactly %d correct reads, took %d')
                    :format(tier, behavior, TIER_READS[tier], answered))
        end
    end
end)

test('M10 better gear buys survival, never a shorter fight', function()
    local function readsToLanding(stats)
        local g = start({ difficulty = 5, behavior = 'run_stop', rig = true, stats = stats })
        local n = 0
        while g.last.phase ~= 'LANDING' do answer(g); n = n + 1 end
        return n
    end
    equal(readsToLanding({ lineRating = 10, reelDrain = 1.0 }), TIER_READS[5])
    equal(readsToLanding({ lineRating = 60, reelDrain = 1.7 }), TIER_READS[5],
        'the best gear in the game must still owe nine reads')
end)

test('M11 a fake never perturbs the chain, and reveals itself before answers are taken', function()
    -- Tier 5 fakes a quarter of the time; forty seeds is plenty to hit several.
    local faked = false
    for seed = 1, 40 do
        local g = start({ behavior = 'steady_heavy', difficulty = 5, seed = seed })
        local seen = {}
        for _ = 1, 3 do
            seen[#seen + 1] = live(g)
            if g.last.nextCue then
                faked = true
                truthy(g.last.switchIn, 'a fake must tell the client when it flips')
                truthy(g.last.switchIn < g.last.windowOpensIn,
                    'the truth has to be on screen before the first answer is accepted')
                truthy(g.last.cue ~= g.last.nextCue, 'a decoy that matches is not a decoy')
            end
            answer(g)
        end
        equal(table.concat(seen, ','), 'DIVE,DIVE,REST',
            ('seed %d: a decoy consumed a real move'):format(seed))
    end
    truthy(faked, 'tier 5 must actually fake sometimes, or this test proves nothing')
end)

test('M12 inside the window, an early answer is worth exactly what a late one is', function()
    local early = start({ behavior = 'run_stop', difficulty = 5 })
    local first = act(early, 'give_line', early.last.windowOpensIn)

    local late = start({ behavior = 'run_stop', difficulty = 5 })
    local last = act(late, 'give_line', late.last.windowClosesIn)

    -- The dispatcher returns { ok, seq, state, outcome } and no score, so the claim that
    -- timing is worth nothing has to be made on the state it produced. M19 checks the
    -- score itself, end to end.
    equal(first.state.progress, 1); equal(last.state.progress, 1)
    equal(first.state.linePct, last.state.linePct)
    equal(first.state.pressure, last.state.pressure)
    equal(first.state.phase, last.state.phase, 'timing carries no score inside this window')
end)

test('M13 an answer during the telegraph is a miss, and the telegraph is long enough to read', function()
    local g = start({ behavior = 'run_stop', difficulty = 5 })
    truthy(g.last.windowOpensIn > 400, 'nobody can read a cue that flashes')
    local res = act(g, 'give_line', 100)          -- the correct response, far too early
    equal(res.state.progress, 0, 'nothing is banked from an answer the window never took')
    truthy(res.state.linePct < 100, 'and it costs the turn like any other miss')
end)

test('M14 advance after the deadline moves the fight on as a miss', function()
    local g = start({ behavior = 'run_stop', difficulty = 5 })
    local res = act(g, 'advance', g.last.windowClosesIn + 400)
    truthy(res.ok)
    equal(res.state.progress, 0)
    truthy(res.state.linePct < 100, 'a run nobody answered still takes line')
    truthy(res.state.phaseId > 1, 'and the next turn is armed')
end)

test('M15 the line running out snaps it', function()
    local g = start({ behavior = 'steady_heavy', difficulty = 5 })
    local res
    for _ = 1, 12 do
        res = act(g, 'reel')                       -- wrong against DIVE, which is the whole opening
        if res.outcome then break end
    end
    equal(res.outcome, 'snap')
    equal(res.state.linePct, 0)
end)

test('M16 escape risk reaching the threshold loses the fish', function()
    -- steady_light is RUN, REST, RUN, THRASH: answer only the rests and thrashes wrong,
    -- so the fight ends on escape risk with the line still intact.
    local g = start({ behavior = 'steady_light', difficulty = 5 })
    local res
    for _ = 1, 20 do
        local cue = live(g)
        if cue == 'REST' or cue == 'THRASH' then
            res = act(g, 'give_line')
        else
            res = answer(g)
        end
        if res.outcome then break end
    end
    equal(res.outcome, 'escape')
    truthy(res.state.pressure >= res.state.escapeThreshold)
    equal(res.state.linePct, 100, 'this fish was lost to risk, not to the line')
end)

test('M17 finishing the reads opens the landing, and reeling it in wins', function()
    local g = start({ difficulty = 1, behavior = 'run_stop' })
    local n = 0
    while g.last.phase ~= 'LANDING' do answer(g); n = n + 1 end
    equal(n, TIER_READS[1])
    equal(g.last.cue, 'LANDING')
    equal(g.last.windowOpensIn, 0, 'the landing is the payoff, not another read')
    local res = act(g, 'reel', 200)
    equal(res.outcome, 'success')
    equal(res.state.progress, res.state.reads, 'a landed fish owes nothing')
end)

test('M18 fumbled landings are bounded -- they cannot second-wind forever', function()
    local g = start({ difficulty = 1, behavior = 'run_stop' })
    while g.last.phase ~= 'LANDING' do answer(g) end
    local threshold = g.last.escapeThreshold

    local res, fumbles = nil, 0
    for _ = 1, 30 do
        if g.last.phase == 'LANDING' then
            res = act(g, 'hold', 200)              -- wrong at the net
            fumbles = fumbles + 1
        else
            res = answer(g)                        -- win the read back
        end
        if res.outcome then break end
    end
    equal(res.outcome, 'escape', 'the escape risk a fumble costs is what ends the loop')
    truthy(fumbles <= threshold,
        ('a fumble budget of %d must not stretch to %d'):format(threshold, fumbles))
end)

test('M19 an imperfect winning fight scores between zero and one', function()
    local g = start({ difficulty = 1, behavior = 'run_stop' })
    act(g, 'hold')                                 -- one deliberate mistake against RUN
    while g.last.phase ~= 'LANDING' do answer(g) end
    local res = act(g, 'reel', 200)
    equal(res.outcome, 'success')

    -- zfishing:claim(src, sessionId, reelDurationMs, success, reason). With an encounter
    -- live the last two are ignored -- settlement reads encounter.outcome, not the client.
    local claim = H.CB['zfishing:claim'](5, g.sid, 0, true)
    truthy(claim.ok, tostring(claim.reason))
    equal(g.calls.give, 1, 'the catch was committed once')
    local ctx = g.calls.ctx
    truthy(ctx.perfScore > 0 and ctx.perfScore < 1,
        ('one mistake in a won fight must land strictly inside 0..1, got %s')
            :format(tostring(ctx.perfScore)))
end)

test('M20 the derived estimate fits inside the framework deadline, unclamped', function()
    -- Encounter.Begin clamps estimate * 1.75 into [15s, 120s]. If a clamp is what is
    -- producing the deadline then the estimate is not really derived from the machine,
    -- and a long honest fight can expire mid-fight.
    for tier = 1, 5 do
        local g = start({ difficulty = tier, behavior = 'steady_light', rig = true,
                          stats = { lineRating = 60, reelDrain = 1.7 } })
        truthy(g.expiryMs < 120500,
            ('tier %d with the best gear wants %dms, past the 120s clamp'):format(tier, g.expiryMs))
        truthy(g.expiryMs > 15500, ('tier %d must not be floored either'):format(tier))
    end
end)

H.run()
```

- [ ] **Step 3: Run the tests to verify they fail**

```bash
node tests/luarun.mjs tests/encounter_mindgame.test.lua
```

Expected: the run aborts — `server/encounter_mindgame.lua` does not exist, so the first
`dofile` inside `start` errors.

- [ ] **Step 4: Write the module**

Create `server/encounter_mindgame.lua`:

```lua
-- Fish Mindgame.
--
-- Read, decide, counter. The fish telegraphs an action; the player picks one of four
-- responses. Difficulty here is knowing WHAT to answer, not answering fast -- so every
-- turn opens with a telegraph nobody may answer into, and once the window is open an
-- answer at the first accepted millisecond is worth exactly what one at the last is.
--
-- Three of the four behaviours are fixed chains rather than random draws. That is the
-- point of the encounter: a player who has fought a catfish before knows it dives twice
-- and then rests, and that knowledge is worth something. Nothing but the turn itself may
-- advance a chain -- see pickDecoy.
--
-- What a fight costs in reads is the tier and nothing else. Gear buys survival: line to
-- spend on mistakes, a wider landing turn, more line back from a rest. It never buys a
-- shorter fight, because the count of reads is this encounter's entire content.
--
-- Same time discipline as counter_pull: state absolute, renders relative.

local M = {}

-- `turns` is how many correct reads the fight costs, and the only lever that changes
-- fight LENGTH. `decision` is thinking time. `line`, `escape` and `mistake` are what a
-- wrong read costs.
local TIERS = {
    [1] = { turns = 3, decision = 2400, line = 100, escape = 3, mistake = 30, fake = 0.00 },
    [2] = { turns = 4, decision = 2200, line = 100, escape = 3, mistake = 30, fake = 0.00 },
    [3] = { turns = 5, decision = 2000, line = 90,  escape = 3, mistake = 30, fake = 0.10 },
    [4] = { turns = 7, decision = 1800, line = 85,  escape = 3, mistake = 30, fake = 0.20 },
    [5] = { turns = 9, decision = 1600, line = 80,  escape = 3, mistake = 30, fake = 0.25 },
}

-- Both window edges are forgiving by this much, for the same reason counter_pull's are:
-- network jitter must never turn an honest answer into a miss.
local GRACE = 250
-- Every turn opens with a telegraph the player watches and cannot answer into. It is a
-- constant, not a tier field: a faking turn that ran longer than an honest one would be
-- detectable with a stopwatch instead of by reading the fish.
local TELEGRAPH = 1400
-- A fake flips here, which leaves the real action on screen for TELEGRAPH - FLIP_AT -
-- GRACE = 550ms before the earliest answer the server will accept. That margin is the
-- whole fairness argument: nobody is ever scored against an action the UI was not
-- showing them. It also means the fake protects nothing against a modified client -- it
-- is presentation, and ARCHITECTURE 12.11 says so out loud.
local FLIP_AT = 600
local DIVE_MULT = 1.5
-- Line a well-answered REST hands back, before the reel multiplier.
local REST_LINE = 12

local CORRECT = { RUN = 'give_line', DIVE = 'brace', THRASH = 'hold',
                  JUMP = 'give_line', REST = 'reel', LANDING = 'reel' }

local ACTIONS = { 'RUN', 'DIVE', 'THRASH', 'JUMP', 'REST' }

-- Fixed cycles for the three readable behaviours; erratic draws instead.
local CHAINS = {
    steady_light = { 'RUN', 'REST', 'RUN', 'THRASH' },
    steady_heavy = { 'DIVE', 'DIVE', 'REST' },
    run_stop     = { 'RUN', 'RUN', 'REST' },
}
local ERRATIC = { { 'RUN', 3 }, { 'DIVE', 3 }, { 'THRASH', 2 }, { 'JUMP', 2 }, { 'REST', 2 } }

-- Seeded LCG rather than math.random: the fight has to be reproducible from the challenge
-- seed alone, so a test can pin one and a desync can be investigated.
local function rand(st)
    st.rng = (1103515245 * st.rng + 12345) % 2147483648
    return st.rng / 2147483648
end

-- Advances the fish's authoritative behaviour. Called exactly once per turn, from nowhere
-- else.
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

-- Presentation only, and deliberately NOT nextAction. Drawing a decoy from the chain would
-- consume the fish's next real move, so "dives twice then rests" would silently become
-- "dives once then rests" on any turn that happened to fake -- and that chain is the
-- encounter's entire premise.
local function pickDecoy(st, real)
    local pool = {}
    for _, a in ipairs(ACTIONS) do
        if a ~= real then pool[#pool + 1] = a end
    end
    return pool[math.floor(rand(st) * #pool) + 1]
end

-- Every arm bumps phaseId. Phase name and window lengths repeat exactly -- an id does not,
-- and the NUI re-anchors its clock on it. Without this two consecutive identical turns
-- leave React's effects thinking nothing happened, so the window bar never restarts and
-- the no-input `advance` never re-arms.
local function armTurn(st, now, action)
    st.phaseId = st.phaseId + 1
    st.phase = action == 'LANDING' and 'LANDING' or 'TURN'
    st.action = action
    st.answer = CORRECT[action]
    st.telegraphAt = now
    -- The landing is not a read, it is the payoff, so it opens at once and carries no
    -- telegraph to watch.
    local lead = action == 'LANDING' and 0 or TELEGRAPH
    st.windowOpensAt = now + lead
    st.windowClosesAt = st.windowOpensAt
        + (action == 'LANDING' and st.landingWindow or st.decision)
    st.deadline = st.windowClosesAt + GRACE
    st.cue, st.switchAt, st.nextCue = action, nil, nil

    if lead > 0 and st.tier.fake > 0 and rand(st) < st.tier.fake then
        st.cue = pickDecoy(st, action)
        st.nextCue = action
        st.switchAt = now + FLIP_AT
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
        -- The rod widens thinking time. Nothing widens, or narrows, the read count.
        decision = math.floor(tier.decision * (1 + (gear.greenZone or 0))),
        maxLine = math.floor(tier.line * Encounters.LineMult(gear.lineRating or 10)),
        -- The two things a better reel buys, in full: more line back from a rest well
        -- answered, and a wider landing turn. `reads` below is the tier verbatim.
        restLine = math.floor(REST_LINE * drain),
        reads = tier.turns,
        progress = 0,
        pressure = 0, phaseId = 0,
    }
    st.line = st.maxLine
    st.landingWindow = math.floor(st.decision * ZUtil.clamp(drain, 1.0, 1.5))
    armTurn(st, ctx.now or 0, nextAction(st))

    -- Derived from the machine above, not guessed, which is what keeps a long honest
    -- fight from running into Encounter.Begin's expiry.
    --
    -- Every wrong answer spends line or escape risk, so failures are bounded: at most
    -- ceil(maxLine / mistake) - 1 line failures and escape - 1 risk failures can happen
    -- without ending the fight. A fumbled landing costs one risk and one read, so there
    -- are at most escape - 1 of those, and each buys back one read and one landing turn.
    local lineFails = math.ceil(st.maxLine / tier.mistake) - 1
    local riskFails = tier.escape - 1
    local turns = (tier.turns + riskFails)     -- reads, including those re-won after a fumble
        + lineFails + riskFails                -- turns lost to wrong answers
        + tier.escape                          -- landing attempts
    local estimate = turns * (TELEGRAPH + st.decision) + st.landingWindow

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
        -- One number, one meaning: progress is both how tired the fish is and how many
        -- reads are left, so there is no second bar restating it.
        progress = st.progress, reads = st.reads,
        linePct = math.max(0, math.floor(st.line / st.maxLine * 100)),
        pressure = st.pressure, escapeThreshold = st.tier.escape,
        -- `st.answer` is deliberately absent. See the header.
    }
end

function M.act(enc, action, now)
    local st = enc.state

    -- What was pressed and when. Inside the window timing carries no score at all; outside
    -- it nothing counts, and during the telegraph the UI is showing a shut window -- and
    -- on a faking turn may still be showing the decoy, which is exactly why answers are
    -- not taken yet.
    local hit
    if action == 'advance' then
        hit = false
    elseif now < st.windowOpensAt - GRACE or now > st.windowClosesAt + GRACE then
        hit = false
    else
        hit = (action == st.answer)
    end

    if st.phase == 'LANDING' then
        if hit then
            st.progress = st.reads
            return { render = M.render(enc, now), outcome = 'success', value = 1 }
        end
        -- A fumble costs the last read back and a point of escape risk. The risk is what
        -- bounds the retry: without it a player could stall at the net until the whole
        -- encounter expired.
        st.progress = math.max(0, st.reads - 1)
        st.pressure = st.pressure + 1
    elseif hit then
        st.progress = st.progress + 1
        if st.action == 'REST' then
            st.line = math.min(st.maxLine, st.line + st.restLine)
        end
    else
        local a = st.action
        if a == 'RUN' then
            st.line = st.line - st.tier.mistake
        elseif a == 'DIVE' then
            st.line = st.line - math.floor(st.tier.mistake * DIVE_MULT)
        elseif a == 'THRASH' then
            st.pressure = st.pressure + 1
        elseif a == 'JUMP' then
            st.pressure = st.pressure + 2
        else  -- REST
            -- A rest you fail to punish is a rest the fish gets to use. It also has to cost
            -- something bounded, or a player answering every rest wrong would never resolve
            -- the fight at all -- the estimate above depends on this.
            st.pressure = st.pressure + 1
        end
    end

    if st.line <= 0 then
        return { render = M.render(enc, now), outcome = 'snap', value = hit and 1 or 0 }
    end
    if st.pressure >= st.tier.escape then
        return { render = M.render(enc, now), outcome = 'escape', value = hit and 1 or 0 }
    end

    if st.progress >= st.reads then
        armTurn(st, now, 'LANDING')
    else
        armTurn(st, now, nextAction(st))
    end

    return { render = M.render(enc, now), outcome = nil, value = hit and 1 or 0 }
end

Encounter.Register('fish_mindgame', M)
```

- [ ] **Step 5: Add the npm script**

In `tests/package.json`, add `"test:mindgame": "node luarun.mjs ../tests/encounter_mindgame.test.lua"`
alongside the other per-suite scripts, matching the exact path style the neighbouring
`test:counterpull` entry uses. Then add the same suite to the `test:all` sweep in the
position the existing list implies (after the counter-pull suite).

- [ ] **Step 6: Run the tests to verify they pass**

```bash
node tests/luarun.mjs tests/encounter_mindgame.test.lua
```

Expected: twenty `ok -` lines then `20 tests passed`.

- [ ] **Step 7: Re-run every suite**

```bash
cd tests && npm run test:all
```

Expected: 12 suites, 221 + 20 = 241 tests, exit 0.

- [ ] **Step 8: Commit**

```bash
git add server/encounter_mindgame.lua tests/encounter_mindgame.test.lua tests/harness.lua tests/package.json
git commit -m "feat: add the fish mindgame encounter module"
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

-- Runs one pass of the bridge's input-polling thread and returns the action it sent for
-- `control`, or nil. The poll loop is `while ENC.active and ZClient.active`, and the
-- harness's Wait() is a no-op, so it is stopped after a single pass by dropping the one
-- half of that condition a test can reach. The thread under test is always the last one
-- created -- the bite handler starts it as its final act.
--
-- Do not iterate all of H.THREADS instead: whichever thread runs first would drop
-- ZClient.active before the poll thread was reached, and running the poll thread with a
-- no-op Wait and no exit condition hangs the suite outright.
local function pressAndRead(control)
    local before = #sent
    _G.__PRESS(control)
    local realWait = _G.Wait
    _G.Wait = function() _G.ZClient.active = false end
    H.THREADS[#H.THREADS]()
    _G.Wait, _G.ZClient.active = realWait, true
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

Expected: B11 passes (counter-pull already works), B12 and B13 fail — the mindgame press
sends `left`.

- [ ] **Step 3: Key the map on the encounter type**

In `client/encounter.lua`, replace the single `KEYS` table with:

```lua
-- control -> action, per encounter. The four controls are the same everywhere because all
-- four are analog on a gamepad already, so controller support needs no separate mapping
-- and no mashing; only the action names differ.
--
-- The mindgame's four responses are not directional, so their meaning is carried by the
-- on-screen label beside each keycap rather than by the key's position. That is affordable
-- there and not in counter-pull, because a mindgame turn is a considered choice with
-- seconds to read, not a reflex.
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
        -- An encounter with no map polls nothing: sending another encounter's action names
        -- would only earn a bad_action per keypress.
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

Expected: 12 suites, 244 tests, exit 0.

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

// server/encounter_mindgame.lua's M.render(enc, now). Durations, never timestamps, and no
// field naming the correct response.
//
// `progress`/`reads` is the single progress number: how tired the fish is AND how many
// reads are left. There is deliberately no second stamina figure restating it.
export type MindgameState = {
  phaseId: number
  phase: 'TURN' | 'LANDING'
  cue: FishAction
  nextCue?: FishAction
  telegraphIn: number
  windowOpensIn: number
  windowClosesIn: number
  switchIn?: number
  progress: number
  reads: number
  linePct: number
  pressure: number
  escapeThreshold: number
}
```

and replace `EncounterMessage` with a discriminated union, so `type` and `state` can only
ever be narrowed together:

```typescript
export type EncounterMessage =
  | { type: 'counter_pull';  difficulty: number; state: CounterPullState; startedAt: number }
  | { type: 'fish_mindgame'; difficulty: number; state: MindgameState;    startedAt: number }
```

- [ ] **Step 2: Dispatch on the type without losing the types**

Rewrite `web/src/encounters/EncounterHost.tsx`:

```tsx
import { useEffect, useState } from 'react'
import type { ReactNode } from 'react'
import { useNuiEvent } from '../hooks/useNui'
import CounterPull from './CounterPull'
import FishMindgame from './FishMindgame'
import type { EncounterMessage, Outcome } from './types'

// Holds one encounter's live state at its own type. The single cast below is at the only
// place a cast belongs -- the NUI message channel, which really is untyped -- and every
// use site downstream is checked.
function Live<S>({ initial, startedAt, children }: {
  initial: S
  startedAt: number
  children: (state: S, outcome: Outcome | null) => ReactNode
}) {
  const [state, setState] = useState<S>(initial)
  const [outcome, setOutcome] = useState<Outcome | null>(null)

  // React state moves on a TRANSITION, never per frame. The per-frame work lives in the
  // child's requestAnimationFrame loop and writes straight to a DOM node.
  useNuiEvent((m) => {
    if (m.action !== 'encounterState') return
    if (m.state) setState(m.state as S)
    if (m.outcome) setOutcome(m.outcome)
  })

  useEffect(() => { setState(initial); setOutcome(null) }, [startedAt])

  return <>{children(state, outcome)}</>
}

// One shell for every encounter, so they read as one product: same panel material, same
// typography, same success/failure language. Only the fight inside differs.
//
// The `key` is what makes switching encounters safe: both branches render the same
// component type, so without it React would reconcile them as one and keep the previous
// encounter's state shape for a frame.
export default function EncounterHost({ msg }: { msg: EncounterMessage }) {
  switch (msg.type) {
    case 'counter_pull':
      return (
        <Live key="counter_pull" initial={msg.state} startedAt={msg.startedAt}>
          {(state, outcome) => <CounterPull state={state} outcome={outcome} />}
        </Live>
      )
    case 'fish_mindgame':
      return (
        <Live key="fish_mindgame" initial={msg.state} startedAt={msg.startedAt}>
          {(state, outcome) => <FishMindgame state={state} outcome={outcome} />}
        </Live>
      )
    default:
      return null
  }
}
```

- [ ] **Step 3: Write the mindgame UI**

Create `web/src/encounters/FishMindgame.tsx`. Note what the shut state is doing: the server
scores an answer during the telegraph as a miss, so the panel has to *show* that the window
is shut for exactly as long as that is true. Without it the rule would be unfair rather
than merely strict.

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
// keycaps carry the input. There is no click handler on purpose -- the fight runs without
// NUI focus, so a click could never fire.
const RESPONSES: { key: string; label: string }[] = [
  { key: 'A',     label: 'enc_mg_give_line' },
  { key: 'S',     label: 'enc_mg_brace' },
  { key: 'D',     label: 'enc_mg_hold' },
  { key: 'SPACE', label: 'enc_mg_reel' },
]

export default function FishMindgame(
  { state, outcome }: { state: MindgameState; outcome: Outcome | null }
) {
  // Anchored once per authoritative turn, keyed on phaseId. See CounterPull for why a ref
  // mutated inside an effect is not good enough.
  const timing = useMemo(() => {
    const receivedAt = Date.now()
    return {
      opensAt: receivedAt + state.windowOpensIn,
      closesAt: receivedAt + state.windowClosesIn,
      switchAt: state.switchIn === undefined ? undefined : receivedAt + state.switchIn,
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [state.phaseId])

  const [shown, setShown] = useState<FishAction>(state.cue)
  const [faked, setFaked] = useState(false)
  const [open, setOpen] = useState(state.windowOpensIn <= 0)
  const barRef = useRef<HTMLDivElement | null>(null)

  useEffect(() => {
    setShown(state.cue)
    setFaked(false)
    setOpen(state.windowOpensIn <= 0)
  }, [state.phaseId])

  // The window opens on the server's schedule, and the panel says so before it does.
  useEffect(() => {
    if (open) return
    const id = setTimeout(() => setOpen(true), Math.max(0, timing.opensAt - Date.now()))
    return () => clearTimeout(id)
  }, [timing, open])

  // The only per-frame work, written straight to the DOM node. During the telegraph the
  // bar fills toward the opening; after it, it drains toward the deadline.
  useEffect(() => {
    let raf = 0
    const tick = () => {
      const el = barRef.current
      if (el) {
        const now = Date.now()
        if (now < timing.opensAt) {
          const span = Math.max(1, state.windowOpensIn)
          el.style.width = `${Math.min(100, (1 - (timing.opensAt - now) / span) * 100)}%`
        } else {
          const span = Math.max(1, timing.closesAt - timing.opensAt)
          el.style.width = `${Math.max(0, (timing.closesAt - now) / span) * 100}%`
        }
      }
      raf = requestAnimationFrame(tick)
    }
    raf = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(raf)
  }, [timing, state.windowOpensIn])

  // The fish changes its mind, visibly, and always before the window opens.
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
      Math.max(0, timing.closesAt - Date.now()) + 300)
    return () => clearTimeout(id)
  }, [timing, outcome])

  useEffect(() => {
    if (!outcome) return
    const id = setTimeout(() => fetchNui('encounterClosed', {}), 700)
    return () => clearTimeout(id)
  }, [outcome])

  const cue = ACTIONS[shown]
  const danger = state.linePct <= 33 || state.pressure >= state.escapeThreshold - 1
  const riskPct = Math.min(100, (state.pressure / Math.max(1, state.escapeThreshold)) * 100)
  const readPct = Math.min(100, (state.progress / Math.max(1, state.reads)) * 100)

  return (
    <div className={`hud-panel enc-panel mg-panel${danger ? ' hud-panel--danger' : ''}`}>
      <div className="panel-title">{t('enc_mg_title')}</div>

      <div className={`mg-cue${faked ? ' mg-cue--faked' : ''}`} role="status">
        <span className="enc-glyph" aria-hidden="true">{cue.glyph}</span>
        <span className="enc-cue-text">{t(cue.label)}</span>
      </div>

      <div className={`bar-track enc-window${open ? '' : ' enc-window--shut'}`}>
        <div className="bar-fill enc-window-fill" ref={barRef} />
      </div>

      <div className={`mg-responses${open ? '' : ' mg-responses--shut'}`}>
        {RESPONSES.map((r) => (
          <div className="mg-response" key={r.key}>
            <Keycap label={r.key} />
            <span className="mg-response-text">{t(r.label)}</span>
          </div>
        ))}
      </div>

      <div className="bar-row">
        <div className="bar-label">{t('enc_mg_reads')}</div>
        <div className="bar-caption mg-reads">{state.progress}/{state.reads}</div>
      </div>
      <div className="bar-track"><div className="bar-fill energy-fill" style={{ width: `${readPct}%` }} /></div>

      <div className="bar-row">
        <div className="bar-label">{t('enc_line')}</div>
        <div className="bar-caption">{state.linePct}%</div>
      </div>
      <div className="bar-track"><div className="bar-fill enc-line-fill" style={{ width: `${state.linePct}%` }} /></div>

      <div className="bar-row">
        <div className="bar-label">{t('enc_mg_pressure')}</div>
        <div className="bar-caption mg-risk">{state.pressure}/{state.escapeThreshold}</div>
      </div>
      <div className="bar-track"><div className="bar-fill enc-risk-fill" style={{ width: `${riskPct}%` }} /></div>

      {outcome && <div className="enc-outcome">{t(`enc_outcome_${outcome}`)}</div>}
    </div>
  )
}
```

- [ ] **Step 4: Add the styles**

Append to `web/src/style.css`:

```css
/* Mindgame. Reuses the encounter shell; the telegraph, the shut state and the response
   row are the new parts, because the fight is a decision rather than a direction. */
.mg-panel { min-width: 26vw; }

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

/* The server scores an answer given now as a miss, so the panel has to say so. */
.enc-window--shut .enc-window-fill { background: var(--rail); opacity: .55; }
.mg-responses--shut { opacity: .38; filter: saturate(.4); }
.mg-responses--shut .keycap { border-style: dashed; }

.mg-responses {
  display: grid; grid-template-columns: repeat(2, 1fr);
  gap: 0.4vh 0.8vw; margin: 0.8vh 0 0.4vh;
  transition: opacity 140ms linear, filter 140ms linear;
}
.mg-response { display: flex; align-items: center; gap: 0.45vw; }
.mg-response-text { font-size: 1.2vh; letter-spacing: .03em; }

.enc-risk-fill { background: var(--danger); }

@media (prefers-reduced-motion: reduce) {
  .mg-cue--faked .enc-glyph { animation: none; }
  .mg-responses { transition: none; }
}
```

- [ ] **Step 5: Type-check**

```bash
cd web && npx tsc --noEmit
```

Expected: no errors. If `CounterPull`'s props complain, the union in Step 1 is wrong —
fix the type, not the component.

- [ ] **Step 6: Commit**

```bash
git add web/src/encounters web/src/style.css
git commit -m "feat: render the fish mindgame in the NUI"
```

---

## Task 4: Web tests and locale strings

**Files:**
- Create: `web/src/encounters/__tests__/FishMindgame.test.tsx`
- Modify: `web/src/encounters/CounterPull.tsx`
- Modify: `web/src/encounters/__tests__/CounterPull.test.tsx`
- Modify: `locales/en.json`, `locales/th.json`

### A shipped defect this task also fixes

`CounterPull.tsx` renders its second bar like this today, on `main`:

```tsx
<div className="bar-label">{t('enc_line')}</div>          {/* "Mistakes" / "พลาด" */}
<div className="bar-caption">{state.misses}/{state.maxMisses}</div>
...
<div className="bar-fill enc-line-fill" style={{ width: `${state.linePct}%` }} />
```

The caption counts mistakes and the bar's *length* is line health — two different numbers
in one row, so the bar contradicts its own caption during a fight. The review that flagged
this read it as a Phase C typo; it is not, the mindgame draft inherited it from Phase B.

Fixing it only in the mindgame would leave the two encounters disagreeing about what a bar
means, so this task fixes both. `counter_pull`'s Lua is not touched and its existing tests
must stay green.

- [ ] **Step 1: Add the strings**

Add to **both** locale files, and **retarget `enc_line`**, which currently reads
"Mistakes"/"พลาด" — after this step it labels the line bar it was always drawn next to, and
the new `enc_cp_misses` carries the miss count. `enc_stamina` and `enc_outcome_*` are
unchanged from Phase B.

| key | en | th |
| --- | --- | --- |
| `enc_line` *(retarget)* | `Line` | `สาย` |
| `enc_cp_misses` *(new)* | `Mistakes` | `พลาด` |
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
| `enc_mg_reads` | `Fish tiring` | `ปลาเริ่มล้า` |
| `enc_mg_pressure` | `Escape risk` | `ความเสี่ยงหลุด` |

- [ ] **Step 2: Uncross counter-pull's bars**

In `web/src/encounters/CounterPull.tsx`, replace the single second bar row with two, so
every caption sits over the bar that draws it:

```tsx
      <div className="bar-row">
        <div className="bar-label">{t('enc_line')}</div>
        <div className="bar-caption cp-line">{state.linePct}%</div>
      </div>
      <div className="bar-track"><div className="bar-fill enc-line-fill" style={{ width: `${state.linePct}%` }} /></div>

      <div className="bar-row">
        <div className="bar-label">{t('enc_cp_misses')}</div>
        <div className="bar-caption cp-misses">{state.misses}/{state.maxMisses}</div>
      </div>
      <div className="bar-track">
        <div
          className="bar-fill enc-risk-fill"
          style={{ width: `${Math.min(100, (state.misses / Math.max(1, state.maxMisses)) * 100)}%` }}
        />
      </div>
```

`.enc-risk-fill` is the class Task 3 added for the mindgame's escape-risk bar; a miss
budget and an escape budget are the same kind of quantity, so they read the same.

Add one test to `web/src/encounters/__tests__/CounterPull.test.tsx`, inside the existing
`describe`:

```tsx
  it('draws the line bar from linePct and the miss bar from misses', () => {
    render(<CounterPull state={base({ linePct: 40, misses: 2, maxMisses: 4 })} outcome={null} />)
    expect(document.querySelector('.cp-line')!.textContent).toBe('40%')
    expect(document.querySelector('.cp-misses')!.textContent).toBe('2/4')
    const style = (sel: string) => (document.querySelector(sel) as HTMLElement).style.width
    expect(style('.enc-line-fill')).toBe('40%')
    expect(style('.enc-risk-fill')).toBe('50%')
  })
```

- [ ] **Step 3: Write the mindgame component tests**

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
  telegraphIn: 0, windowOpensIn: 1150, windowClosesIn: 3150,
  progress: 0, reads: 5, linePct: 100, pressure: 0, escapeThreshold: 3,
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

  it('draws the window shut for the whole telegraph, then open', () => {
    render(<FishMindgame state={base()} outcome={null} />)
    expect(document.querySelector('.mg-responses--shut')).not.toBeNull()
    expect(document.querySelector('.enc-window--shut')).not.toBeNull()
    act(() => { vi.advanceTimersByTime(1200) })
    expect(document.querySelector('.mg-responses--shut')).toBeNull()
    expect(document.querySelector('.enc-window--shut')).toBeNull()
  })

  it('reveals the real action before the window opens, never after', () => {
    render(
      <FishMindgame
        state={base({ cue: 'REST', nextCue: 'DIVE', switchIn: 600, windowOpensIn: 1150 })}
        outcome={null}
      />
    )
    const decoy = document.querySelector('.mg-cue .enc-glyph')!.textContent
    act(() => { vi.advanceTimersByTime(650) })
    const real = document.querySelector('.mg-cue .enc-glyph')!.textContent
    expect(real).not.toBe(decoy)
    expect(document.querySelector('.mg-cue--faked')).not.toBeNull()
    // The fairness property: the truth is up while answers are still being refused.
    expect(document.querySelector('.mg-responses--shut')).not.toBeNull()
  })

  it('reads the progress bar from progress and the risk bar from pressure', () => {
    // The two used to be crossed: an "Escape risk 2/3" caption over a line-health bar.
    render(<FishMindgame state={base({ progress: 2, reads: 4, linePct: 60, pressure: 2 })} outcome={null} />)
    expect(document.querySelector('.mg-reads')!.textContent).toBe('2/4')
    expect(document.querySelector('.mg-risk')!.textContent).toBe('2/3')
    const style = (sel: string) => (document.querySelector(sel) as HTMLElement).style.width
    expect(style('.energy-fill')).toBe('50%')
    expect(style('.enc-line-fill')).toBe('60%')
    expect(parseFloat(style('.enc-risk-fill'))).toBeCloseTo(66.6, 0)
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
    act(() => { vi.advanceTimersByTime(3000) })
    expect(posted.filter((p) => p.data?.action === 'advance')).toHaveLength(0)
    act(() => { vi.advanceTimersByTime(1000) })
    expect(posted.filter((p) => p.data?.action === 'advance')).toHaveLength(1)

    // Same phase name, same durations, different turn: phaseId is the only difference.
    rerender(<FishMindgame state={base({ phaseId: 2 })} outcome={null} />)
    act(() => { vi.advanceTimersByTime(4000) })
    expect(posted.filter((p) => p.data?.action === 'advance')).toHaveLength(2)
  })

  it('opens the landing turn with no shut phase at all', () => {
    render(
      <FishMindgame
        state={base({ phase: 'LANDING', cue: 'LANDING', windowOpensIn: 0, windowClosesIn: 2400 })}
        outcome={null}
      />
    )
    expect(document.querySelector('.mg-responses--shut')).toBeNull()
  })

  it('renders the outcome and closes the presentation', () => {
    render(<FishMindgame state={base()} outcome="escape" />)
    expect(document.querySelector('.enc-outcome')!.textContent!.length).toBeGreaterThan(0)
    act(() => { vi.advanceTimersByTime(800) })
    expect(posted.some((p) => p.event === 'encounterClosed')).toBe(true)
  })

  it('never sends the server a timing value it could trust', () => {
    render(<FishMindgame state={base()} outcome={null} />)
    act(() => { vi.advanceTimersByTime(5000) })
    for (const p of posted) {
      const keys = Object.keys(p.data ?? {})
      expect(keys.filter((k) => /At$|In$|ms$|time/i.test(k))).toHaveLength(0)
    }
  })
})
```

- [ ] **Step 4: Run the web suite**

```bash
cd web && npm test
```

Expected: the Lua hash snapshot fails, because Lua changed in Tasks 1-2. Re-record it and
re-run:

```bash
cd web && npx vitest --run -u src/__tests__/bundleRebuildPreservation.test.ts && npm test
```

Expected then: 78 + 10 mindgame + 1 counter-pull = 89 tests, all passing. If any *existing*
counter-pull test went red, Step 2 changed more than the two bar rows — revert and redo it.

- [ ] **Step 5: Commit**

```bash
git add web/src/encounters locales/en.json locales/th.json web/src/__tests__/__snapshots__/bundleRebuildPreservation.test.ts.snap
git commit -m "test: cover the fish mindgame UI, and uncross counter-pull's bars"
```

---

## Task 5: Wire, build and document

**Files:**
- Modify: `fxmanifest.lua`
- Rebuild and commit: `web/dist`
- Modify: `docs/ARCHITECTURE.md`, `docs/testing/zfishing-live-e2e-checklist.md`

- [ ] **Step 1: Load the module, and pin the order it loads in**

In `fxmanifest.lua`, add `'server/encounter_mindgame.lua',` to `server_scripts` immediately
after `'server/encounter_counter_pull.lua',`.

That position is load-bearing and nothing currently guards it: each encounter module calls
`Encounter.Register` in its body, so listing one before `server/encounter.lua` is a
boot-time crash in FiveM — and no encounter suite would catch it, because they all `dofile`
their module directly instead of walking the manifest. Close that by adding both modules to
`loadAllServerModulesAtBoot` in `tests/security.test.lua`, in manifest order, right after
`dofile('server/encounter.lua')`:

```lua
    -- In fxmanifest order, and that order is the point: each module's body calls
    -- Encounter.Register at load, so listing one before server/encounter.lua is a
    -- boot-time crash in FiveM that no per-encounter suite would catch -- they dofile
    -- their module directly and never walk the manifest.
    dofile('server/encounter_counter_pull.lua')
    dofile('server/encounter_mindgame.lua')
```

```bash
node tests/luarun.mjs tests/security.test.lua
```

Expected: still `133 tests passed` — the modules only register at load, so G1's "no DB, no
host mutation at boot" assertions are unaffected.

- [ ] **Step 2: Rebuild the bundle**

```bash
cd web && npm run build
```

- [ ] **Step 3: Re-run everything**

```bash
cd tests && npm run test:all
```

Expected: 12 suites, 244 tests, exit 0.

```bash
cd web && npx vitest --run -u src/__tests__/bundleRebuildPreservation.test.ts && npm test && npx tsc --noEmit
```

Expected: 89 tests passing, no type errors.

- [ ] **Step 4: Document**

Add `### 12.11 Fish Mindgame` to `docs/ARCHITECTURE.md`, covering:

- The five fish actions and four responses, with the response table and its wrong-answer
  costs, and why `RUN` and `JUMP` share an answer.
- The four behaviour chains and what a player learns from each.
- The turn diagram: telegraph → decision window, `TELEGRAPH = 1400`, `FLIP_AT = 600`,
  `GRACE = 250`, and the 550ms margin between a fake revealing itself and the first
  accepted answer.
- **Why timing carries no score inside the window**, and why an answer during the telegraph
  is nonetheless a miss — with the UI's shut state named as the thing that makes that fair.
- **Why the two encounters fake differently**, verbatim from this plan's section above,
  including that the mindgame's fake is presentation rather than protection.
- The tier table, and the invariant it exists to serve: `turns` is the read count, the read
  count is the tier, and nothing — behaviour, rod, reel, or mistake — moves it. Name the
  three things gear does move instead (max line, `REST` line-back, landing width).
- Why every wrong answer including a wrong `REST` spends a bounded resource, and how
  `M.build`'s estimate is derived from that bound rather than guessed.
- Why a fumbled landing costs escape risk: it is what stops the second-wind loop.
- Why `pickDecoy` exists separately from `nextAction`.

Add a change-history entry under `## 13`, stating plainly that no fish is configured to use
the mindgame yet, that Task 4 also corrected a Phase B HUD defect where counter-pull's miss
caption sat over a line-health bar, and that nothing was run in FiveM.

Extend section L of `docs/testing/zfishing-live-e2e-checklist.md` with a Mindgame block:
FORCED mindgame at tier 1 and tier 5; each of the five fish actions answered correctly; each
wrong-answer cost observed (line on RUN, more line on DIVE, escape risk on THRASH and double
on JUMP, escape risk on a wasted REST); a `REST` answered with REEL visibly returning line,
and returning more of it with a better reel; a tier 4+ fake flipping while the responses are
still visibly shut; a tier-5 fight counted to confirm it costs exactly nine reads; the same
count again with the best gear in the game; a fumbled landing resuming the fight and a third
fumble losing it; an escape by risk and a snap by line; a walk-away timeout; and a controller
run. Leave every box unticked.

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
- No fish resolves to either new encounter on its own — DEFAULT is still the legacy fight
  for everyone until Phase F.
- A tier-5 mindgame costs exactly nine correct reads with any gear in the game.
- Live behaviour is **unverified**: nothing in this phase has been run inside FiveM.

## Known limitations to carry into the completion report

**Keycaps name keyboard keys on both encounters.** `CounterPull` shipped `A`/`S`/`D`/`SPACE`
in Phase B against controls 34/35/33/22, which are movement controls — on a gamepad those
are stick directions and a face button, so "A" reads as the Xbox A button rather than as
left. The mindgame inherits the same treatment deliberately: fixing it for one encounter
and not the other would be worse than the shared flaw. The responses' *labels* are already
input-agnostic, so this is cosmetic. A device-aware `Keycap` belongs in a cross-encounter
task, not in Phase C.

**Fake telegraphs protect nothing.** By design here, unlike counter-pull — the truth is on
screen for every client before the first accepted answer, so `nextCue` in the payload gives
a modified client nothing it would not have had 550ms later anyway. The mindgame's defence
against a scripted client is that the server holds the chain, the answer and the clock;
the fake is atmosphere.

**Players learn behaviour archetypes, not species.** Two fish sharing `run_stop` share a
chain exactly. The design goal — "knowing the fish is worth something" — is met at the
archetype level, which is all `config/fish.lua` currently distinguishes. Per-species chain
variants are a Phase F-or-later idea, not a gap in this phase.
