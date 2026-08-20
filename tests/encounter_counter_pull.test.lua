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
