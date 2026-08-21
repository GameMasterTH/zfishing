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
        -- Set after the boot (installHost resets it) and before the hook, because a pass
        -- fixes its compensation when it is armed.
        _G.__PING = opts.ping or 0
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
    -- The callback accepts only the action. An extra fabricated timestamp is ignored,
    -- so the server grades the packet's arrival during this (deliberately wrong) pass.
    local g = start({ difficulty = 5 })
    _G.__NOW = g.at + g.last.passStartsIn + 1
    g.seq = g.seq + 1
    local res = H.CB['zfishing:encounter:act'](5, g.sid, g.cid, g.seq, 'strike',
        perfectOffset(g))
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
        ('the closest decoy came within %.0fms of the real crossing'):format(worst))
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
    local plain = start({ difficulty = 5, seed = 19, rig = true, stats = { float = 'float_wood' } })
    local smart = start({ difficulty = 5, seed = 19, rig = true, stats = { float = 'float_smart' } })
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
