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
