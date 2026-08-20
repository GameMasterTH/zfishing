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

-- RegisterNUICallback handlers take (body, cb); the harness has no NUI to supply the
-- callback, so every invocation here provides a no-op in its place.
local function nuiCall(name, body)
    return H.CB['nui:' .. name](body, function() end)
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
    nuiCall('encounterAction', { action = 'advance' })
    nuiCall('encounterAction', { action = 'advance' })
    local seqs = {}
    for _, s in ipairs(sent) do
        if s.name == 'zfishing:encounter:act' then seqs[#seqs + 1] = s.args[3] end
    end
    equal(seqs[1], 1); equal(seqs[2], 2)
end)

test('B5 no action payload carries a timing value or an encounter type', function()
    loadBridge(happyServer())
    biteAndHook('counter_pull')
    nuiCall('encounterAction', { action = 'advance', atMs = 1234, type = 'sonar_strike' })
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
    nuiCall('encounterAction', { action = 'advance' })

    local claims = 0
    for _, s in ipairs(sent) do if s.name == 'zfishing:claim' then claims = claims + 1 end end
    equal(claims, 1, 'the client settles exactly once, without waiting on the NUI')

    local before = actCalls()
    nuiCall('encounterAction', { action = 'advance' })
    equal(actCalls(), before, 'no further action is accepted after the fight ends')
end)

test('B7 settlement does not need the NUI to ask for it', function()
    loadBridge(happyServer({ outcomeAt = 1, outcome = 'snap' }))
    biteAndHook('counter_pull')
    nuiCall('encounterAction', { action = 'advance' })
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
    nuiCall('encounterAction', { action = 'advance' })
    local last = ended[#ended]
    truthy(last)
    equal(last.key, 'line_broke', 'a server-decided snap must read as a snapped line')
end)

test('B9 teardown resets the bridge so a stale action goes nowhere', function()
    loadBridge(happyServer())
    biteAndHook('counter_pull')
    H.EVENTS['zfishing:client:end']()
    local before = actCalls()
    nuiCall('encounterAction', { action = 'advance' })
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
