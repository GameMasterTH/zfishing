-- The claim boundary: for an encounter session the server's own outcome decides, and
-- the client's success flag is ignored. Run from the resource root:
--   node tests/luarun.mjs tests/encounter_claim.test.lua

dofile('tests/harness.lua')
local test, equal, truthy, falsy = H.test, H.equal, H.truthy, H.falsy

local function winnerModule(outcome, value)
    return {
        actions = { go = true },
        build = function() return { deadline = 0 }, 20000 end,
        act = function(enc, _, now)
            enc.state.deadline = now + 1000
            return { render = {}, outcome = outcome, value = value or 1 }
        end,
    }
end

-- opts.rig routes the cast through the assembled-rod path, which is the only path that
-- sets session.rigSlot -- and Rig.breakLine needs it, so the snap test must use it.
local function playTo(outcome, value, opts)
    opts = opts or {}
    local calls = H.loadSession({ encounterMode = 'forced', forcedEncounter = 'counter_pull',
                                  rig = opts.rig })
    Encounter.Register('counter_pull', winnerModule(outcome, value))
    local cast = H.CB['zfishing:cast'](5, 0.5, opts.rig and 1 or nil)
    truthy(cast.ok, tostring(cast.reason))
    H.fireLatestTimer()
    local hook = H.CB['zfishing:hook'](5, cast.sessionId)
    truthy(hook.ok)
    H.CB['zfishing:encounter:act'](5, cast.sessionId, hook.challengeId, 1, 'go')
    return cast.sessionId, calls
end

test('K1 a client claiming success on a lost encounter is not paid', function()
    local sid, calls = playTo('escape')
    local res = H.CB['zfishing:claim'](5, sid, 99999, true, nil)
    truthy(res.ok, 'a loss is a legitimate outcome, not an error')
    equal(res.fish, nil, 'the server said the fish escaped; the client saying otherwise changes nothing')
    equal(res.outcome, 'escape', 'the loss reason comes back from the server, not from the NUI')
    equal(calls.give, 0, 'settlement must never have run')
end)

test('K2 a client claiming failure on a won encounter is still paid', function()
    local sid, calls = playTo('success')
    local res = H.CB['zfishing:claim'](5, sid, 99999, false, 'snap')
    truthy(res.ok)
    truthy(res.fish, 'the server counted the win; the client cannot refuse it')
    equal(calls.give, 1)
end)

test('K3 a claim before the encounter has resolved is refused', function()
    local calls = H.loadSession({ encounterMode = 'forced', forcedEncounter = 'counter_pull' })
    Encounter.Register('counter_pull', winnerModule(nil))
    local cast = H.CB['zfishing:cast'](5, 0.5)
    H.fireLatestTimer()
    local hook = H.CB['zfishing:hook'](5, cast.sessionId)
    H.CB['zfishing:encounter:act'](5, cast.sessionId, hook.challengeId, 1, 'go')
    local res = H.CB['zfishing:claim'](5, cast.sessionId, 1000, true, nil)
    falsy(res.ok)
    equal(res.reason, 'encounter_active')
    equal(calls.give, 0)
end)

test('K4 a server-decided snap breaks the line component', function()
    local sid, calls = playTo('snap', 1, { rig = true })
    -- The client reports no reason at all. Before this change the line survived,
    -- because breakLine keyed off the reason string the NUI sent.
    local res = H.CB['zfishing:claim'](5, sid, 99999, false, nil)
    equal(res.outcome, 'snap')
    truthy(calls.lineBroken, 'Rig.breakLine must fire on the SERVER outcome, not on a client reason')
end)

test('K5 the encounter perf score reaches settlement and nothing else', function()
    local sid, calls = playTo('success', 1)
    truthy(H.CB['zfishing:claim'](5, sid, 99999, true, nil).ok)
    equal(calls.ctx.perfScore, 1, 'a flawless fight scores 1.0')
    truthy(calls.ctx.sessionId, 'the existing settlement context is preserved')
    truthy(calls.ctx.identifier)
end)

test('K6 a legacy session keeps the original claim path', function()
    local calls = H.loadSession({ encounterMode = 'default' })
    local cast = H.CB['zfishing:cast'](5, 0.5)
    H.fireLatestTimer()
    H.CB['zfishing:hook'](5, cast.sessionId)
    -- the minimum plausible reel time still applies to the client-run legacy fight
    local tooFast = H.CB['zfishing:claim'](5, cast.sessionId, 10, true, nil)
    falsy(tooFast.ok)
    equal(tooFast.reason, 'too_fast')
    equal(calls.give, 0)
end)

test('K7 a legacy win still pays, and carries no perf score', function()
    local calls = H.loadSession({ encounterMode = 'default' })
    local cast = H.CB['zfishing:cast'](5, 0.5)
    H.fireLatestTimer()
    H.CB['zfishing:hook'](5, cast.sessionId)
    _G.__NOW = _G.__NOW + 20000
    truthy(H.CB['zfishing:claim'](5, cast.sessionId, 20000, true, nil).ok)
    equal(calls.give, 1)
    equal(calls.ctx.perfScore, nil, 'the legacy fight grants exactly the XP it granted before')
end)

H.run()
