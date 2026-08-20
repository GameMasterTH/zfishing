-- The action contract: sequencing, replay rejection, the `advance` deadline action,
-- and the flood gate. Run from the resource root:
--   node tests/luarun.mjs tests/encounter_action.test.lua

dofile('tests/harness.lua')
local test, equal, truthy, falsy = H.test, H.equal, H.truthy, H.falsy

-- A deliberately trivial module. It is the contract under test here, not any real
-- encounter: three correct actions win, one `advance` (a missed deadline) loses.
local function fakeModule()
    return {
        actions = { good = true, bad = true },
        build = function(ctx)
            return { hits = 0, misses = 0, difficulty = ctx.difficulty, deadline = 0 }, 20000
        end,
        act = function(enc, action, now)
            local st = enc.state
            if action == 'good' then st.hits = st.hits + 1 else st.misses = st.misses + 1 end
            local outcome
            if st.hits >= 3 then outcome = 'success' elseif st.misses >= 1 then outcome = 'escape' end
            st.deadline = now + 1000
            return { render = { hits = st.hits }, outcome = outcome, value = action == 'good' and 1 or 0 }
        end,
    }
end

-- cast -> bite -> hook, leaving an armed encounter. Returns the session id and the
-- challenge id the server minted.
local function startEncounter(src, mod)
    local calls = H.loadSession({ encounterMode = 'forced', forcedEncounter = 'counter_pull' })
    Encounter.Register('counter_pull', mod or fakeModule())
    local cast = H.CB['zfishing:cast'](src, 0.5)
    truthy(cast.ok, tostring(cast.reason))
    H.fireLatestTimer()
    local hook = H.CB['zfishing:hook'](src, cast.sessionId)
    truthy(hook.ok)
    truthy(hook.challengeId, 'the hook answer must carry the challenge id the client will quote')
    return cast.sessionId, hook.challengeId, calls
end

test('C1 a correct action advances the sequence and returns the authoritative seq', function()
    local sid, cid = startEncounter(5)
    local r = H.CB['zfishing:encounter:act'](5, sid, cid, 1, 'good')
    truthy(r.ok)
    equal(r.seq, 1)
    equal(r.state.hits, 1)
    equal(r.outcome, nil)
end)

test('C2 a duplicate seq is rejected and changes nothing', function()
    local sid, cid = startEncounter(5)
    truthy(H.CB['zfishing:encounter:act'](5, sid, cid, 1, 'good').ok)
    local dup = H.CB['zfishing:encounter:act'](5, sid, cid, 1, 'good')
    falsy(dup.ok)
    equal(dup.reason, 'bad_seq')
    equal(dup.seq, 1, 'the reply carries the real seq so an honest client can resync')
    equal(H.CB['zfishing:encounter:act'](5, sid, cid, 2, 'good').state.hits, 2,
        'the duplicate must not have counted -- a replayed win is the whole attack')
end)

test('C3 a stale seq and an impossible future seq are both rejected', function()
    local sid, cid = startEncounter(5)
    H.CB['zfishing:encounter:act'](5, sid, cid, 1, 'good')
    H.CB['zfishing:encounter:act'](5, sid, cid, 2, 'good')
    equal(H.CB['zfishing:encounter:act'](5, sid, cid, 1, 'good').reason, 'bad_seq')
    equal(H.CB['zfishing:encounter:act'](5, sid, cid, 9, 'good').reason, 'bad_seq')
    equal(H.CB['zfishing:encounter:act'](5, sid, cid, 'x', 'good').reason, 'bad_seq')
end)

test('C4 a challenge id from another session is rejected', function()
    local sid, cid = startEncounter(5)
    equal(H.CB['zfishing:encounter:act'](5, sid, cid .. 'x', 1, 'good').reason, 'stale_challenge')
    equal(H.CB['zfishing:encounter:act'](5, 'not-my-session', cid, 1, 'good').reason, 'invalid_session')
end)

test('C5 an unknown action name is rejected without consuming the sequence', function()
    local sid, cid = startEncounter(5)
    equal(H.CB['zfishing:encounter:act'](5, sid, cid, 1, 'teleport').reason, 'bad_action')
    truthy(H.CB['zfishing:encounter:act'](5, sid, cid, 1, 'good').ok,
        'a rejected action must not burn the seq an honest retry needs')
end)

test('C6 advance is refused before the deadline and accepted after it', function()
    local sid, cid = startEncounter(5)
    truthy(H.CB['zfishing:encounter:act'](5, sid, cid, 1, 'good').ok)  -- sets deadline = now + 1000
    equal(H.CB['zfishing:encounter:act'](5, sid, cid, 2, 'advance').reason, 'bad_action',
        'an early advance would let a client skip a window it had not actually lost')
    _G.__NOW = _G.__NOW + 1500
    local r = H.CB['zfishing:encounter:act'](5, sid, cid, 2, 'advance')
    truthy(r.ok)
    equal(r.outcome, 'escape', 'the SERVER decides what an expired deadline means')
end)

test('C7 once an outcome is set the challenge accepts nothing more', function()
    local sid, cid = startEncounter(5)
    H.CB['zfishing:encounter:act'](5, sid, cid, 1, 'good')
    H.CB['zfishing:encounter:act'](5, sid, cid, 2, 'good')
    equal(H.CB['zfishing:encounter:act'](5, sid, cid, 3, 'good').outcome, 'success')
    equal(H.CB['zfishing:encounter:act'](5, sid, cid, 4, 'good').reason, 'encounter_over')
end)

test('C8 the encounter expiry timer resolves an abandoned fight as a timeout', function()
    local sid, cid = startEncounter(5)
    local expiry = H.TIMERS[#H.TIMERS]
    truthy(expiry, 'beginning an encounter must schedule exactly one expiry timer')
    expiry.fn()
    equal(H.CB['zfishing:encounter:act'](5, sid, cid, 1, 'good').reason, 'encounter_over')
end)

test('C9 flooding the action event cannot accelerate a catch', function()
    local sid, cid = startEncounter(5)
    local accepted, gated = 0, 0
    for i = 1, 200 do
        local r = H.CB['zfishing:encounter:act'](5, sid, cid, i, 'good')
        if r.ok then accepted = accepted + 1
        elseif r.reason == 'too_many_requests' then gated = gated + 1 end
    end
    truthy(gated > 0, 'the gate must engage under a flood')
    truthy(accepted <= 3, 'a flood cannot produce more progress than the module allows')
end)

test('C10 a dropped player leaves no encounter behind', function()
    local sid, cid = startEncounter(5)
    -- server/session.lua's handler reads the `source` global, which FiveM sets for it
    _G.source = 5
    H.EVENTS.playerDropped()
    equal(H.CB['zfishing:encounter:act'](5, sid, cid, 1, 'good').reason, 'invalid_session')
end)

test('C11 a legacy session has no encounter callback surface', function()
    H.loadSession({ encounterMode = 'default' })
    local cast = H.CB['zfishing:cast'](5, 0.5)
    H.fireLatestTimer()
    local hook = H.CB['zfishing:hook'](5, cast.sessionId)
    truthy(hook.ok)
    equal(hook.challengeId, nil, 'the legacy fight mints no challenge')
    equal(H.CB['zfishing:encounter:act'](5, cast.sessionId, 'anything', 1, 'good').reason, 'no_encounter')
end)

H.run()
