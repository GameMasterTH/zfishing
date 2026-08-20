-- Shared scaffold for the encounter test suites.
--
-- dofile'd rather than require'd: tests/luarun.mjs mounts files at their
-- repository-relative paths inside a bare wasmoon VM, and there is no package.path
-- set up in there.
--
-- tests/security.test.lua predates this file and carries its own copy of the same
-- scaffold. That is deliberate. It is a passing 133-test suite and rewriting it to
-- consume this harness would be risk with no payoff for the encounter work.

H = {}

local tests = {}

function H.test(name, cb) tests[#tests + 1] = { name = name, callback = cb } end

function H.equal(actual, expected, message)
    assert(actual == expected, (message or 'values differ') .. ': expected '
        .. tostring(expected) .. ', got ' .. tostring(actual))
end

function H.truthy(v, message) assert(v, message or 'expected a truthy value') end
function H.falsy(v, message) assert(not v, message or 'expected a falsy value') end

function H.deepcopy(v)
    if type(v) ~= 'table' then return v end
    local o = {}
    for k, val in pairs(v) do o[k] = H.deepcopy(val) end
    return o
end

-- Recorders, refreshed by H.installHost()
H.CB, H.CMD, H.EVENTS, H.NETEVENTS, H.THREADS, H.TIMERS, H.spy = nil, nil, nil, nil, nil, nil, nil

local function sqlNode(ret)
    local function run(sql, params)
        H.spy.sql[#H.spy.sql + 1] = sql
        H.spy.sqlCalls[#H.spy.sqlCalls + 1] = { sql = sql, params = params }
        return ret
    end
    return setmetatable({ await = function(sql, params) return run(sql, params) end },
        { __call = function(_, sql, params) return run(sql, params) end })
end

-- Installs a fresh set of host stubs and clears the module globals a previous
-- test's dofile defined, so each test starts from a known state.
function H.installHost()
    H.CB, H.CMD, H.EVENTS, H.NETEVENTS, H.THREADS, H.TIMERS = {}, {}, {}, {}, {}, {}
    H.spy = { sql = {}, sqlCalls = {}, clientEvents = {}, notifies = {} }

    Config, Zfishing, Progression, Generator, Rig, Rewards, Validate, Store, ZUtil,
        Encounters, Encounter, ConfigSchema =
        nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil

    _G.lib = { callback = { register = function(name, fn) H.CB[name] = fn end } }
    _G.RegisterCommand = function(name, fn) H.CMD[name] = fn end
    _G.RegisterNetEvent = function(name, fn) H.NETEVENTS[name] = fn end
    _G.AddEventHandler = function(name, fn) H.EVENTS[name] = fn end
    _G.CreateThread = function(fn) H.THREADS[#H.THREADS + 1] = fn end
    _G.Wait = function() end
    _G.SetTimeout = function(ms, fn) H.TIMERS[#H.TIMERS + 1] = { ms = ms, fn = fn } end
    _G.TriggerClientEvent = function(event, target, ...)
        H.spy.clientEvents[#H.spy.clientEvents + 1] = { event = event, target = target, args = { ... } }
    end
    _G.GetResourceState = function() return 'started' end

    _G.__NOW = 1000      -- GetGameTimer ms
    _G.__TIME = 100000   -- os.time seconds
    _G.__PING = 60       -- GetPlayerPing ms
    _G.GetGameTimer = function() return _G.__NOW end
    _G.GetPlayerPing = function() return _G.__PING end
    _G.GetPlayerPed = function() return 1 end
    _G.__POS = { x = 0.0, y = 0.0, z = 0.0 }
    _G.GetEntityCoords = function() return _G.__POS end
    _G.GetWeatherState = function() return { weather = 'CLEAR', hour = 12 } end

    _G.json = {
        encode = function(v) return { __enc = H.deepcopy(v) } end,
        decode = function(v)
            if type(v) == 'table' and v.__enc ~= nil then return H.deepcopy(v.__enc) end
            return v
        end,
    }
    _G.MySQL = {
        scalar = sqlNode(nil), query = sqlNode({}), prepare = sqlNode(true),
        insert = sqlNode(1), update = sqlNode(true), single = sqlNode(nil),
    }
    os.time = function() return _G.__TIME end
end

-- The five real rarities, because tier mapping is 1:1 with them, plus the four
-- real behavior names from config/fish.lua. A test config that invents rarities or
-- behaviors would pass while the shipped data failed.
function H.baseConfig()
    return {
        RateLimit = 6,
        Timings = { biteMin = 4000, biteMax = 12000, hookWindow = 1500, hookLatency = 300, reelTimeout = 30000 },
        Minigame = { baseDrain = 12.0 },
        CastMaxDistance = 25.0,
        Durability = false, RodCanBreak = false, RequireAssembly = false, RequireZone = false,
        DefaultWater = 'ocean',
        RareLoot = {},
        EncounterMode = 'default',
        ForcedEncounter = 'counter_pull',
        Rarity = {
            common    = { weight = 100, hookMult = 1.0,  tension = 1.0 },
            uncommon  = { weight = 45,  hookMult = 0.85, tension = 1.15 },
            rare      = { weight = 15,  hookMult = 0.7,  tension = 1.3 },
            epic      = { weight = 5,   hookMult = 0.6,  tension = 1.5 },
            legendary = { weight = 1,   hookMult = 0.5,  tension = 1.8 },
        },
        Weather = { weather = {}, time = {} },
        Zones = {},
        Fish = {},
        Equipment = {
            rods   = { fishing_rod_common = { level = 1, label = 'Common Rod', greenZone = 0.0, rareBonus = 1.0, degrade = 1, durability = 40 } },
            reels  = { reel_cheap = { level = 1, label = 'Cheap Reel', drainRate = 1.0, degrade = 1, durability = 60 } },
            lines  = { line_10 = { level = 1, label = '10lb Line', rating = 10, degrade = 2, durability = 30 } },
            hooks  = { hook_4 = { label = 'Size 4 Hook', hookMod = 1.0, rareBonus = 1.1 } },
            floats = { float_wood = { level = 1, label = 'Wood Float', biteSpeed = 1.0, degrade = 1, durability = 50 } },
            baits  = { worm = { label = 'Worm' } },
        },
        Admin = { waterTypes = { 'lake', 'river', 'ocean', 'swamp', 'dam' } },
    }
end

-- Runs a callback with math.random() (no arguments) pinned to `v`. ZUtil.weightedPick
-- is the only no-arg caller in the code under test, so this makes a weighted pick
-- deterministic without disturbing math.random(a, b) elsewhere.
function H.withRandom(v, fn)
    local real = math.random
    math.random = function(a, b)
        if a == nil then return v end
        return real(a, b)
    end
    local ok, err = pcall(fn)
    math.random = real
    if not ok then error(err, 0) end
end

-- Minimal inventory-and-framework facade, matching the surface server/session.lua
-- and server/rig.lua actually call.
function H.makeZfishing(state)
    state = state or {}
    local inv = state.inv or {}
    local Z = {}
    function Z.Blocked() return state.blocked end
    function Z.Enhanced() return state.mode ~= 'simple' end
    function Z.Simple() return state.mode == 'simple' end
    function Z.Identifier() return 'license:test' end
    function Z.HasItem(src, item)
        for _, s in pairs(inv[src] or {}) do if s.name == item then return true end end
        return false
    end
    function Z.GetSlot(src, slot) return (inv[src] or {})[slot] end
    function Z.AddItem() return true end
    function Z.RemoveItem() return true end
    function Z.RemoveItemSlot() return true end
    function Z.SetMetadata() return true end
    function Z.Notify() end
    return Z
end

-- Boots server/session.lua against stubbed collaborators. Returns the recorded
-- Rewards.GiveCatch calls so a test can assert what settlement was handed.
function H.loadSession(opts)
    opts = opts or {}
    H.installHost()
    Config = H.baseConfig()
    Config.EncounterMode = opts.encounterMode or 'default'
    Config.ForcedEncounter = opts.forcedEncounter or 'counter_pull'
    Config.RequireZone = false
    Config.Durability = false

    -- opts.rig = true exercises the assembled-rod path, which is the only path that
    -- populates session.rigSlot -- and rigSlot is what Rig.breakLine needs, so a snap
    -- test has to run through it.
    Config.RequireAssembly = opts.rig == true

    local inv = { [5] = { [1] = { name = 'fishing_rod_common', count = 1 }, [2] = { name = 'worm', count = 5 } } }
    Zfishing = H.makeZfishing({ mode = opts.rig and 'enhanced' or 'simple', inv = inv })
    Progression = {
        Get = function() return { level = 5, identifier = 'license:test' } end,
        Load = function() return true end, AddXP = function() end, Save = function() end,
    }
    Generator = { Roll = function()
        return H.deepcopy(opts.fish or { species = 'bass', label = 'Bass', weight = 2.0, quality = 3,
            rarity = 'common', behavior = 'steady_light', biteDelay = 100, hookWindow = 1500,
            tensionDiff = 1.0, fishEnergy = 50, xp = 10, price = 100, difficulty = 1 })
    end }
    local calls = { give = 0, ctx = nil }
    Rewards = { GiveCatch = function(_, _, _, ctx)
        calls.give = calls.give + 1
        calls.ctx = ctx
        return { ok = true, committed = true, warnings = {} }
    end }
    local META = { parts = { reel = 'reel_cheap', line = 'line_10', hook = 'hook_4', float = 'float_wood' },
                   dur = { rod = 20, reel = 20, line = 20, hook = 20, float = 20 } }
    Rig = {
        slotMeta = function()
            if not opts.rig then return nil end
            return { name = 'fishing_rod_common' }, META
        end,
        isComplete = function() return opts.rig == true end,
        stats = function() return { lineRating = 10, reelDrain = 1.0, hook = 'hook_4', floatBiteSpeed = 1.0 } end,
        degrade = function() return { broke = {} } end,
        breakLine = function() calls.lineBroken = true end,
    }
    -- session.lua's playerDropped handler calls into the boat anchor module, which the
    -- encounter suites never exercise; stubbed so a disconnect test can run the handler.
    BoatAnchor = { Add = function() end, Remove = function() end, OnDisconnect = function() end }
    dofile('shared/util.lua')
    dofile('shared/encounters.lua')
    dofile('server/encounter.lua')
    dofile('server/session.lua')
    return calls
end

-- Finds the most recent recorded client event by name.
function H.lastClientEvent(name)
    for i = #H.spy.clientEvents, 1, -1 do
        if H.spy.clientEvents[i].event == name then return H.spy.clientEvents[i] end
    end
    return nil
end

-- Fires the most recently scheduled SetTimeout. Always the timer the call under test
-- just armed -- indexing H.TIMERS[1] breaks the moment a test casts twice, because the
-- first cast's bite timer is still sitting there and its identity guard makes firing it
-- a silent no-op.
function H.fireLatestTimer()
    local t = H.TIMERS[#H.TIMERS]
    assert(t, 'expected a scheduled timer')
    t.fn()
    return t
end

-- Pins math.random(a, b) -- the form Encounter.Begin uses to mint a challenge seed --
-- so a fight's whole RNG stream is reproducible. Without it a behaviour test can only
-- assert a distribution, and a distribution assertion is a flaky test wearing a
-- statistics costume.
function H.withSeed(seed, fn)
    local real = math.random
    math.random = function(a, b)
        if a == nil then return real() end
        if b == nil then return math.min(seed, a) end
        return math.max(a, math.min(b, seed))
    end
    local ok, err = pcall(fn)
    math.random = real
    if not ok then error(err, 0) end
end

function H.run()
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
end
