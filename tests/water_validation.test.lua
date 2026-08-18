-- Bug-condition exploration test for the zfishing water-validation fix.
-- Run from the resource root:  lua tests/water_validation.test.lua
--
-- Mirrors the harness style of tests/security.test.lua: no framework, every
-- host dependency is a dependency-injected mock, and the REAL shipped client
-- module (client/main.lua) is loaded with `dofile` so we exercise the actual
-- decision path in startFishing(), not a copy.
--
-- Spec: .kiro/specs/zfishing-water-validation-fix
-- Property 1 (Bug Condition): for every valid cast power, when the player is
-- holding the rod (active=true), attempts to cast (castAttempt=true) and is NOT
-- near real water at cast time (nearWater()==false), the system SHALL reject the
-- cast, start no session, notify 'need_water' and clean up state.
--
-- **Validates: Requirements 1.1, 1.2, 2.1, 2.2**
--
-- EXPECTED OUTCOME on the UNFIXED code: this test FAILS. startFishing() never
-- re-checks nearWater() before firing the 'zfishing:cast' callback, so the cast
-- callback IS invoked even though nearWater()==false at cast time. That failure
-- is the counterexample that proves the bug exists.

local tests = {}
local function test(name, cb) tests[#tests + 1] = { name = name, callback = cb } end
local function equal(actual, expected, message)
    assert(actual == expected, (message or 'values differ') .. ': expected '
        .. tostring(expected) .. ', got ' .. tostring(actual))
end
local function truthy(v, message) assert(v, message or 'expected a truthy value') end
local function falsy(v, message) assert(not v, message or 'expected a falsy value') end

-- ---------------------------------------------------------------- vector3 mock
-- client/main.lua does real vector math (pos + fwd * 6.0) inside nearWater();
-- give the coord tables +/* metamethods so the arithmetic does not blow up.
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
local CB_AWAIT, NETEVENTS, THREADS, EXPORTS, spy, startRodUse

-- water probe sequencing: nearWater() -> TestProbeAgainstWater() returns the
-- next boolean in waterSeq. This lets a scenario be "near water at pickup, then
-- NOT near water at cast time" (walked away / faced inland / on the rocks).
local waterSeq, waterIdx

local function installHost(opts)
    opts = opts or {}
    CB_AWAIT, NETEVENTS, THREADS, EXPORTS = {}, {}, {}, {}
    startRodUse = nil
    spy = { notifies = {}, nui = {}, castCalls = 0, spawnFloatCalls = 0,
        cleanupCalls = 0, freezes = {} }

    waterSeq = opts.waterSeq or { true }
    waterIdx = 0

    -- module globals redefined below; nil old ones so a missing load is loud
    Config, ZClient, Anim, Casting = nil, nil, nil, nil

    -- ox_lib surface
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
                    -- emulate a server that WOULD accept the cast, so that on the
                    -- unfixed code the flow proceeds into a real session. This makes
                    -- the "cast succeeded" defect observable.
                    return { ok = true, rod = 'rod', bait = 'worm' }
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

    -- registration surface: capture startRodUse where main.lua exports/binds it
    _G.RegisterNUICallback = function() end
    _G.RegisterNetEvent = function(name, fn) NETEVENTS[name] = fn end
    _G.AddEventHandler = function() end
    _G.RegisterCommand = function() end
    _G.RegisterKeyMapping = function() end
    _G.exports = function(name, fn) EXPORTS[name] = fn end
    _G.GetResourceState = function() return 'stopped' end

    -- deferred, like FiveM: stored, never auto-run (weather + sell-NPC threads)
    _G.CreateThread = function(fn) THREADS[#THREADS + 1] = fn end
    _G.Wait = function() end
    _G.SetTimeout = function() end
    _G.TriggerServerEvent = function() end
    _G.GetHashKey = function() return 0 end
    _G.GetWeatherTypeTransition = function() return 0, 0, 0.0 end
    _G.GetClockHours = function() return 12 end

    -- ped / world natives
    _G.PlayerPedId = function() return 1 end
    _G.GetEntityCoords = function() return vec3(0.0, 0.0, 0.0) end
    _G.GetEntityForwardVector = function() return vec3(0.0, 1.0, 0.0) end
    _G.vector3 = vec3
    -- boat-anchor probe (client/main.lua getFishingBoat, ~:103-114): these
    -- suites are about water proximity, not boats, so "no vehicle found" is
    -- the right default. 0 short-circuits getFishingBoat() before it reaches
    -- DoesEntityExist/IsThisModelABoat.
    _G.GetVehiclePedIsIn = function() return 0 end
    _G.GetClosestVehicle = function() return 0 end
    -- cleanup() (client/main.lua ~:128-145): fires a local event and checks
    -- for an entity attachment on the way out. No-op / "not attached" is the
    -- right default -- these suites don't exercise the rig menu or attaching.
    _G.TriggerEvent = function() end
    _G.IsEntityAttached = function() return false end

    -- THE water probe: returns the next scripted boolean. nearWater() takes the
    -- first return value only. Once the sequence is exhausted, repeat the last.
    _G.TestProbeAgainstWater = function()
        waterIdx = waterIdx + 1
        local v = waterSeq[waterIdx]
        if v == nil then v = waterSeq[#waterSeq] end
        return v
    end

    -- NUI / control natives
    _G.SendNUIMessage = function(m) spy.nui[#spy.nui + 1] = m end
    _G.SetNuiFocus = function() end
    _G.FreezeEntityPosition = function(_, on) spy.freezes[#spy.freezes + 1] = on end
    -- standby loop waits for E (38). Return true so the player "presses E" at once.
    _G.IsControlJustPressed = function() return true end
    _G.IsControlPressed = function() return true end

    -- Casting / Anim live in other client files; stub the surface main.lua uses.
    -- Casting.Charge returns the scripted cast power (nil = never started casting).
    _G.Casting = {
        Charge = function() return opts.power end,
        RemoveFloat = function() end,
        SpawnFloat = function() spy.spawnFloatCalls = spy.spawnFloatCalls + 1 end,
    }
    _G.Anim = {
        Start = function() end, Stop = function() end, PlayClip = function() end,
    }
end

-- ---------------------------------------------------------------- config seed
local function baseConfig()
    return {
        Locale = false,          -- follow convar; skips lib.setLocale branch
        PromptHud = true,
        RequireZone = true,
        FreezeWhileFishing = false,
        CastMaxDistance = 25.0,
        -- a single zone at the origin large enough that PlayerPedId is inside it,
        -- so currentZone() passes and the ONLY gate left is nearWater()
        Zones = { { name = 'Lake', coords = vec3(0.0, 0.0, 0.0), radius = 100.0, water = 'lake' } },
    }
end

-- Loads the REAL client module with the mocked host and returns the captured
-- startRodUse entry point (exported by main.lua via exports('useRod', ...)).
local function loadClient(opts)
    installHost(opts)
    Config = baseConfig()
    dofile('client/main.lua')
    local entry = EXPORTS['useRod'] or NETEVENTS['zfishing:client:useRod']
    truthy(entry, 'startRodUse must be exported/bound by client/main.lua')
    return entry
end

-- Drives the full pickup -> standby -> charge -> cast decision path for one
-- input and reports what the system did, in the vocabulary of Property 1.
local function runCast(opts)
    local entry = loadClient(opts)
    entry({ slot = 3 })   -- USE the rod item (ox_inventory-style slot payload)
    local lastNotify = spy.notifies[#spy.notifies]
    return {
        castCallbackInvoked = spy.castCalls > 0,
        sessionStarted = spy.spawnFloatCalls > 0,
        notified = lastNotify and lastNotify.description or nil,
        stateClean = (ZClient and ZClient.active == false),
    }
end

-- ---------------------------------------------------------------- scoped PBT
-- Property 1: for EVERY valid cast power, a bug-condition input
-- (active=true, castAttempt=true, nearWater@cast=false) must be rejected.
-- waterSeq = { true, false }: near water at the pickup gate, NOT near water at
-- the cast re-check — exactly the isBugCondition(input) shape from the design.
local function assertRejected(res, label)
    equal(res.castCallbackInvoked, false, label .. ': cast callback must NOT be invoked')
    equal(res.sessionStarted, false, label .. ': no fishing session may start')
    equal(res.notified, 'need_water', label .. ": must notify 'need_water'")
    equal(res.stateClean, true, label .. ': state must be clean (ZClient.active == false)')
end

test('P1 scoped PBT: any valid power with nearWater@cast=false is rejected', function()
    -- deterministic sweep across the valid power domain (0, 1], incl. edges
    local powers = { 0.0001, 0.01, 0.25, 0.5, 0.75, 0.999, 1.0 }
    math.randomseed(1337)
    for _ = 1, 200 do powers[#powers + 1] = math.random() end   -- (0,1)
    for _, p in ipairs(powers) do
        local res = runCast({ power = p, waterSeq = { true, false } })
        assertRejected(res, ('power=%.5f'):format(p))
    end
end)

-- The four narrative cases from the design all collapse to the same decision
-- (isBugCondition == true: near at pickup, not near at cast), so each asserts
-- the same Property-1 rejection with a representative power.
test('P1 case 1: stand on land inside the zone, then cast', function()
    assertRejected(runCast({ power = 0.5, waterSeq = { true, false } }), 'land-in-zone')
end)

test('P1 case 2: face away from the water before casting', function()
    assertRejected(runCast({ power = 0.8, waterSeq = { true, false } }), 'faced-inland')
end)

test('P1 case 3: walk out during standby, then cast', function()
    assertRejected(runCast({ power = 0.3, waterSeq = { true, false } }), 'walked-out')
end)

test('P1 case 4 (edge): stand right on the water boundary', function()
    -- marginal probe miss at cast time still counts as nearWater==false
    assertRejected(runCast({ power = 1.0, waterSeq = { true, false } }), 'boundary')
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
    end
end
if failures > 0 then error(('%d test(s) failed'):format(failures)) end
print(('%d tests passed'):format(#tests))
