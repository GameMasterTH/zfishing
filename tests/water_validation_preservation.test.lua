-- Preservation property test for the zfishing water-validation fix (Property 2).
-- Run from the resource root:  lua tests/water_validation_preservation.test.lua
--
-- Mirrors the harness style of tests/security.test.lua and the sibling
-- tests/water_validation.test.lua (Property 1): no framework, every host
-- dependency is a dependency-injected mock, and the REAL shipped client module
-- (client/main.lua) is loaded with `dofile` so we exercise the actual decision
-- path in startRodUse()/startFishing(), not a copy.
--
-- Spec: .kiro/specs/zfishing-water-validation-fix
-- Property 2 (Preservation): for EVERY input that is NOT a bug condition
-- (isBugCondition(input) == false), the fixed code SHALL produce the same
-- observable outcome as the original code. This test encodes the observed
-- baseline behaviour on the UNFIXED code so that re-running it after the fix
-- (task 3.3) proves no regression.
--
-- **Validates: Requirements 3.1, 3.2, 3.3, 3.4, 3.5**
--
-- EXPECTED OUTCOME on the UNFIXED code: this test PASSES. Every non-bug input
-- already behaves as asserted; the fix only adds a gate on the bug-condition
-- inputs (Property 1), leaving all of these paths untouched.

local tests = {}
local function test(name, cb) tests[#tests + 1] = { name = name, callback = cb } end
local function equal(actual, expected, message)
    assert(actual == expected, (message or 'values differ') .. ': expected '
        .. tostring(expected) .. ', got ' .. tostring(actual))
end
local function truthy(v, message) assert(v, message or 'expected a truthy value') end

-- ---------------------------------------------------------------- vector3 mock
-- client/main.lua does real vector math (pos + fwd * 6.0) inside nearWater();
-- give the coord tables +/-/* metamethods so the arithmetic does not blow up.
-- The actual water result is driven by the TestProbeAgainstWater stub, so these
-- numbers never matter — they only have to be valid vectors.
local vmeta = {}
vmeta.__add = function(a, b) return setmetatable({ x = a.x + b.x, y = a.y + b.y, z = a.z + b.z }, vmeta) end
vmeta.__sub = function(a, b) return setmetatable({ x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }, vmeta) end
vmeta.__mul = function(a, b)
    if type(a) == 'number' then a, b = b, a end   -- normalise number * vector
    return setmetatable({ x = a.x * b, y = a.y * b, z = a.z * b }, vmeta)
end
local function vec3(x, y, z) return setmetatable({ x = x, y = y, z = z }, vmeta) end

-- ---------------------------------------------------------------- host scaffold
-- shared recorders, reset per run by installHost()
local CB_AWAIT, NETEVENTS, THREADS, EXPORTS, COMMANDS, spy, waterSeq, waterIdx

local function installHost(opts)
    opts = opts or {}
    CB_AWAIT, NETEVENTS, THREADS, EXPORTS, COMMANDS = {}, {}, {}, {}, {}
    spy = { notifies = {}, nui = {}, castCalls = 0, cancelCalls = 0,
        spawnFloatCalls = 0, removeFloatCalls = 0, freezes = {} }

    -- nearWater() -> TestProbeAgainstWater() returns the next boolean in waterSeq.
    -- [1] = probe at rod pickup (startRodUse), [2] = probe at cast re-check
    -- (only read by the FIXED code). Exhausted sequence repeats the last value.
    waterSeq = opts.waterSeq or { true, true }
    waterIdx = 0

    -- how the emulated server responds to the cast callback
    local castOk = opts.castOk
    if castOk == nil then castOk = true end
    local castReason = opts.castReason

    -- module globals redefined by dofile; nil old ones so a missing load is loud
    Config, ZClient, Anim, Casting = nil, nil, nil, nil

    _G.lib = {
        locale = function() end,
        setLocale = function() end,
        notify = function(t) spy.notifies[#spy.notifies + 1] = t end,
        showTextUI = function() end,
        hideTextUI = function() end,
        requestModel = function() end,
        callback = {
            await = function(name, ...)
                if name == 'zfishing:cast' then
                    spy.castCalls = spy.castCalls + 1
                    if castOk then return { ok = true, rod = 'rod', bait = 'worm' } end
                    return { ok = false, reason = castReason }
                elseif name == 'zfishing:cancel' then
                    spy.cancelCalls = spy.cancelCalls + 1
                    return true
                end
                return nil
            end,
        },
    }

    -- locale() returns the key so a notify's description IS the key we assert on
    _G.locale = function(k) return k end
    _G.GetConvar = function(_, d) return d end
    _G.json = { decode = function() return {} end, encode = function(v) return v end }
    _G.LoadResourceFile = function() return nil end
    _G.GetCurrentResourceName = function() return 'zfishing' end

    _G.RegisterNUICallback = function() end
    _G.RegisterNetEvent = function(name, fn) NETEVENTS[name] = fn end
    _G.AddEventHandler = function() end
    _G.RegisterCommand = function(name, fn) COMMANDS[name] = fn end
    _G.RegisterKeyMapping = function() end
    _G.exports = function(name, fn) EXPORTS[name] = fn end
    _G.GetResourceState = function() return 'stopped' end

    -- deferred, like FiveM: stored, never auto-run (weather + sell-NPC threads).
    -- Tests that need a deferred body (cancel) run the recorded thread explicitly.
    _G.CreateThread = function(fn) THREADS[#THREADS + 1] = fn end
    _G.Wait = function() end
    _G.SetTimeout = function() end
    _G.TriggerServerEvent = function() end
    _G.GetHashKey = function() return 0 end
    _G.GetWeatherTypeTransition = function() return 0, 0, 0.0 end
    _G.GetClockHours = function() return 12 end

    _G.PlayerPedId = function() return 1 end
    _G.GetEntityCoords = function() return vec3(0.0, 0.0, 0.0) end
    _G.GetEntityForwardVector = function() return vec3(0.0, 1.0, 0.0) end
    _G.vector3 = vec3

    _G.TestProbeAgainstWater = function()
        waterIdx = waterIdx + 1
        local v = waterSeq[waterIdx]
        if v == nil then v = waterSeq[#waterSeq] end
        return v
    end

    _G.SendNUIMessage = function(m) spy.nui[#spy.nui + 1] = m end
    _G.SetNuiFocus = function() end
    _G.FreezeEntityPosition = function(_, on) spy.freezes[#spy.freezes + 1] = on end
    -- standby loop waits for E (38). Return true so the player "presses E" at once.
    _G.IsControlJustPressed = function() return true end
    _G.IsControlPressed = function() return true end

    _G.Casting = {
        Charge = function() return opts.power end,   -- nil = never started casting
        RemoveFloat = function() spy.removeFloatCalls = spy.removeFloatCalls + 1 end,
        SpawnFloat = function() spy.spawnFloatCalls = spy.spawnFloatCalls + 1 end,
    }
    _G.Anim = {
        Start = function() end, Stop = function() end, PlayClip = function() end,
    }
end

-- ---------------------------------------------------------------- config seed
local function baseConfig(inZone)
    return {
        Locale = false,          -- follow convar; skips lib.setLocale branch
        PromptHud = true,
        RequireZone = true,
        FreezeWhileFishing = false,
        CastMaxDistance = 25.0,
        -- inZone => a zone at the origin big enough to contain PlayerPedId, so
        -- currentZone() passes; otherwise no zones at all so it fails closed.
        Zones = inZone and { { name = 'Lake', coords = vec3(0.0, 0.0, 0.0), radius = 100.0, water = 'lake' } } or {},
    }
end

-- Loads the REAL client module with the mocked host and returns the captured
-- startRodUse entry point (exported by main.lua via exports('useRod', ...)).
local function loadClient(opts)
    installHost(opts)
    Config = baseConfig(opts.inZone ~= false)
    dofile('client/main.lua')
    local entry = EXPORTS['useRod'] or NETEVENTS['zfishing:client:useRod']
    truthy(entry, 'startRodUse must be exported/bound by client/main.lua')
    return entry
end

-- Drives the full pickup -> standby -> charge -> cast decision path for one
-- input and reports what the system did (the shared observation vocabulary).
local function runScenario(opts)
    local entry = loadClient(opts)
    if opts.preActive then ZClient.active = true end
    entry({ slot = 3 })   -- USE the rod item (ox_inventory-style slot payload)
    local lastNotify = spy.notifies[#spy.notifies]
    return {
        castCallbackInvoked = spy.castCalls > 0,
        sessionStarted = spy.spawnFloatCalls > 0,
        notified = lastNotify and lastNotify.description or nil,
        activeAfter = ZClient and ZClient.active or false,
    }
end

-- The documented baseline outcome for a NON-bug input, straight from main.lua's
-- gate order: busy -> need_water -> no_fish_here -> (standby) -> charge -> cast.
local function expectedOutcome(inp)
    if inp.preActive then
        return { castCallbackInvoked = false, sessionStarted = false,
                 notified = 'error_busy', activeAfter = true }
    elseif not inp.nearAtRodUse then
        return { castCallbackInvoked = false, sessionStarted = false,
                 notified = 'need_water', activeAfter = false }
    elseif not inp.inZone then
        return { castCallbackInvoked = false, sessionStarted = false,
                 notified = 'no_fish_here', activeAfter = false }
    elseif inp.power == nil then
        return { castCallbackInvoked = false, sessionStarted = false,
                 notified = 'cancelled', activeAfter = false }
    elseif not inp.castOk then
        return { castCallbackInvoked = true, sessionStarted = false,
                 notified = inp.castReason and ('error_' .. inp.castReason) or 'error_busy',
                 activeAfter = false }
    else
        -- near real water at cast (guaranteed for non-bug), server accepts:
        -- the session starts exactly as before.
        return { castCallbackInvoked = true, sessionStarted = true,
                 notified = nil, activeAfter = true }
    end
end

-- reached the cast decision at all? (passed busy + rod-pickup gates)
local function reachesCast(inp)
    return (not inp.preActive) and inp.nearAtRodUse and inp.inZone
end
-- design's isBugCondition: active in startFishing, an actual cast attempt, and
-- not near real water at cast time.
local function isBugCondition(inp)
    local castAttempt = reachesCast(inp) and (inp.power ~= nil)
    return castAttempt and (inp.nearAtCast == false)
end

-- Build the mock opts for a scenario input.
local function optsFor(inp)
    return {
        preActive = inp.preActive,
        inZone = inp.inZone,
        power = inp.power,
        castOk = inp.castOk,
        castReason = inp.castReason,
        waterSeq = { inp.nearAtRodUse and true or false, inp.nearAtCast and true or false },
    }
end

local function assertOutcome(inp, label)
    local exp = expectedOutcome(inp)
    local got = runScenario(optsFor(inp))
    equal(got.castCallbackInvoked, exp.castCallbackInvoked, label .. ': castCallbackInvoked')
    equal(got.sessionStarted, exp.sessionStarted, label .. ': sessionStarted')
    equal(got.notified, exp.notified, label .. ': notified')
    equal(got.activeAfter, exp.activeAfter, label .. ': activeAfter')
end

-- ============================================================ representative cases
-- These mirror the Preservation test cases in design.md.

test('Preservation case: cast while genuinely near water starts the session (3.1, 3.4)', function()
    assertOutcome({ preActive = false, nearAtRodUse = true, inZone = true,
        power = 0.5, castOk = true, nearAtCast = true }, 'near-water-cast')
end)

test('Preservation case: rod pickup with no water is rejected with need_water (3.2)', function()
    assertOutcome({ preActive = false, nearAtRodUse = false, inZone = true,
        power = 0.5, castOk = true, nearAtCast = false }, 'pickup-no-water')
end)

test('Preservation case: rod pickup outside any zone is rejected with no_fish_here (3.3)', function()
    assertOutcome({ preActive = false, nearAtRodUse = true, inZone = false,
        power = 0.5, castOk = true, nearAtCast = true }, 'pickup-no-zone')
end)

test('Preservation case: charge timeout (power=nil) cleans up as cancelled (3.5)', function()
    assertOutcome({ preActive = false, nearAtRodUse = true, inZone = true,
        power = nil, castOk = true, nearAtCast = true }, 'charge-timeout')
end)

test('Preservation case: already fishing rejects a second pickup with error_busy (3.5)', function()
    assertOutcome({ preActive = true, nearAtRodUse = true, inZone = true,
        power = 0.5, castOk = true, nearAtCast = true }, 'busy')
end)

test('Preservation case: server refusal after cast cleans up with the error key (3.4)', function()
    assertOutcome({ preActive = false, nearAtRodUse = true, inZone = true,
        power = 0.5, castOk = false, castReason = 'no_zone', nearAtCast = true }, 'server-refuse')
end)

-- ============================================================ false-positive guard
-- No input that is genuinely near water at cast time may ever be rejected.
-- Sweep the valid power domain: every one must reach the cast + start a session.
test('No false positive: nearWater@cast=true is never wrongly rejected', function()
    math.randomseed(4242)
    local powers = { 0.0001, 0.01, 0.25, 0.5, 0.75, 0.999, 1.0 }
    for _ = 1, 100 do powers[#powers + 1] = math.random() end
    for _, p in ipairs(powers) do
        local inp = { preActive = false, nearAtRodUse = true, inZone = true,
            power = p, castOk = true, nearAtCast = true }
        assertOutcome(inp, ('near@cast power=%.5f'):format(p))
    end
end)

-- ============================================================ randomized PBT
-- Generate a broad slice of the input space, skip the bug-condition inputs
-- (that is Property 1's job) and assert every non-bug input matches the
-- documented baseline outcome.
test('PBT: every non-bug input matches the documented baseline outcome', function()
    math.randomseed(20240607)
    local checked, skipped = 0, 0
    for _ = 1, 500 do
        local startedCast = math.random() < 0.7
        local inp = {
            preActive   = math.random() < 0.2,
            nearAtRodUse = math.random() < 0.6,
            inZone      = math.random() < 0.6,
            power       = startedCast and math.random() or nil,
            castOk      = math.random() < 0.7,
            castReason  = (math.random() < 0.5) and 'no_zone' or nil,
            nearAtCast  = math.random() < 0.5,
        }
        if isBugCondition(inp) then
            skipped = skipped + 1
        else
            checked = checked + 1
            local label = ('rnd#%d[pre=%s near0=%s zone=%s pow=%s ok=%s near1=%s]'):format(
                checked, tostring(inp.preActive), tostring(inp.nearAtRodUse),
                tostring(inp.inZone), tostring(inp.power ~= nil), tostring(inp.castOk),
                tostring(inp.nearAtCast))
            assertOutcome(inp, label)
        end
    end
    truthy(checked > 100, 'expected a healthy number of non-bug inputs checked')
    print(('   (checked %d non-bug inputs, skipped %d bug-condition inputs)'):format(checked, skipped))
end)

-- ============================================================ cancel (X) preservation
-- Pressing X must still tear the session down cleanly in every phase (3.5).
local function loadEntryActiveSession()
    local entry = loadClient({ preActive = false, inZone = true, power = 0.5,
        castOk = true, waterSeq = { true, true } })
    entry({ slot = 3 })                 -- start a real session (active == true)
    truthy(ZClient.active == true, 'a session should be live before cancelling')
    return entry
end

test('Preservation: cancel (X) during an active session cleans up as cancelled (3.5)', function()
    loadEntryActiveSession()
    local cancel = COMMANDS['zfishing_cancel']
    truthy(cancel, 'the zfishing_cancel command must be registered')
    local before = #THREADS
    cancel()                            -- schedules the cancel/cleanup thread
    truthy(#THREADS > before, 'cancel must schedule a cleanup thread')
    THREADS[#THREADS]()                 -- run the deferred cancel body
    equal(spy.cancelCalls, 1, 'the zfishing:cancel server callback must fire once')
    equal(ZClient.active, false, 'the session must be torn down (active == false)')
    local lastNotify = spy.notifies[#spy.notifies]
    equal(lastNotify and lastNotify.description, 'cancelled', "cancel must notify 'cancelled'")
    truthy(spy.removeFloatCalls > 0, 'cleanup must remove the float')
end)

test('Preservation: cancel (X) with no active session is a silent no-op (3.5)', function()
    loadClient({ inZone = true, power = 0.5, waterSeq = { true, true } })
    local cancel = COMMANDS['zfishing_cancel']
    truthy(cancel, 'the zfishing_cancel command must be registered')
    local before = #THREADS
    cancel()
    equal(#THREADS, before, 'no cleanup thread may be scheduled when inactive')
    equal(#spy.notifies, 0, 'an inactive cancel must not notify')
end)

-- ---------------------------------------------------------------- runner
local failures = 0
for _, entry in ipairs(tests) do
    local ok, err = pcall(entry.callback)
    if ok then
        print('ok - ' .. entry.name)
    else
        failures = failures + 1
        io.stderr:write('not ok - ' .. entry.name .. ': ' .. tostring(err) .. '\n')
        print('not ok - ' .. entry.name .. ': ' .. tostring(err))
    end
end
if failures > 0 then error(('%d test(s) failed'):format(failures)) end
print(('%d tests passed'):format(#tests))
