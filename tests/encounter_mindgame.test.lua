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
