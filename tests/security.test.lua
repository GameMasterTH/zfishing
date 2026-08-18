-- Plain-Lua server-side security & authority tests for zfishing.
-- Run from the resource root:  lua tests/security.test.lua
--
-- Mirrors the harness style of zcore_lib/tests/runtime.test.lua and
-- zcore_runtime_zfishing/tests/bootstrap.test.lua: no framework, every host
-- dependency is a dependency-injected mock, and the real server modules are
-- loaded with `dofile` so we exercise the shipped code, not a copy.
--
-- Coverage (Requirements 6.5, 23.5, 27.1):
--   A. Server-side input validation      (Validate.*)                6.5 / 23.5
--   B. Malicious metadata / input        (Validate.* sanitizing)     6.5 / 23.5
--   C. Authorization                     (admin.lua ACE gating)      23.5 / 27.1
--   D. Exact-slot ownership              (rig.lua + session slot)    23.5 / 27.1
--   E. Distance / rate controls          (session.lua)               6.5 / 23.5
--   F. Server-authoritative anti-cheat   (session claim/hook timing) 6.5 / 23.5
--   G. Absence of boot-time DB/host mutation (all server modules)    27.1

local tests = {}
local function test(name, cb) tests[#tests + 1] = { name = name, callback = cb } end
local function equal(actual, expected, message)
    assert(actual == expected, (message or 'values differ') .. ': expected '
        .. tostring(expected) .. ', got ' .. tostring(actual))
end
local function truthy(v, message) assert(v, message or 'expected a truthy value') end
local function falsy(v, message) assert(not v, message or 'expected a falsy value') end

-- ---------------------------------------------------------------- mock scaffold

local function deepcopy(v)
    if type(v) ~= 'table' then return v end
    local o = {}
    for k, val in pairs(v) do o[k] = deepcopy(val) end
    return o
end

-- shared recorders, reset by installHost()
local CB, CMD, EVENTS, NETEVENTS, THREADS, TIMERS, spy

local function sqlNode(ret)
    local function run(sql) spy.sql[#spy.sql + 1] = sql; return ret end
    return setmetatable({ await = function(sql) return run(sql) end },
        { __call = function(_, sql) return run(sql) end })
end

-- Installs a fresh set of global host stubs + recorders and clears any module
-- globals defined by a previous test's dofile, so each test gets a clean state.
local function installHost()
    CB, CMD, EVENTS, NETEVENTS, THREADS, TIMERS = {}, {}, {}, {}, {}, {}
    spy = { sql = {}, clientEvents = {}, notifies = {}, host = {} }

    -- module globals get redefined by dofile; nil them so a missing load is loud
    Config, Zfishing, Progression, Generator, Rig, Rewards, Validate, Store, ZUtil =
        nil, nil, nil, nil, nil, nil, nil, nil, nil

    _G.lib = { callback = { register = function(name, fn) CB[name] = fn end } }
    _G.RegisterCommand = function(name, fn) CMD[name] = fn end
    _G.RegisterNetEvent = function(name, fn) NETEVENTS[name] = fn end
    _G.AddEventHandler = function(name, fn) EVENTS[name] = fn end
    _G.CreateThread = function(fn) THREADS[#THREADS + 1] = fn end   -- deferred, like FiveM
    _G.Wait = function() end
    _G.SetTimeout = function(ms, fn) TIMERS[#TIMERS + 1] = { ms = ms, fn = fn } end
    _G.TriggerClientEvent = function(event, target, ...)
        spy.clientEvents[#spy.clientEvents + 1] = { event = event, target = target, args = { ... } }
    end
    _G.GetResourceState = function() return 'started' end

    -- controllable clocks
    _G.__NOW = 1000       -- GetGameTimer ms
    _G.__TIME = 100000    -- os.time seconds
    _G.GetGameTimer = function() return _G.__NOW end
    _G.GetPlayerPed = function() return 1 end
    _G.__POS = { x = 0.0, y = 0.0, z = 0.0 }
    _G.GetEntityCoords = function() return _G.__POS end
    _G.GetWeatherState = function() return { weather = 'CLEAR', hour = 12 } end

    -- host-mutation spies: must stay empty through boot
    _G.SetConvar = function(k, v) spy.host[#spy.host + 1] = { fn = 'SetConvar', k = k, v = v } end
    _G.SetConvarReplicated = function(k, v) spy.host[#spy.host + 1] = { fn = 'SetConvarReplicated', k = k } end
    os.execute = function(cmd) spy.host[#spy.host + 1] = { fn = 'os.execute', cmd = cmd }; return 0 end
    io.popen = function(cmd) spy.host[#spy.host + 1] = { fn = 'io.popen', cmd = cmd }; return nil end

    -- json + oxmysql
    _G.json = {
        encode = function(v) return { __enc = deepcopy(v) } end,
        decode = function(v)
            if type(v) == 'table' and v.__enc ~= nil then return deepcopy(v.__enc) end
            return v
        end,
    }
    _G.MySQL = {
        scalar = sqlNode(nil), query = sqlNode({}), prepare = sqlNode(true),
        insert = sqlNode(1), update = sqlNode(true), single = sqlNode(nil),
    }
    -- os.time override (kept restorable-free; tests set _G.__TIME)
    os.time = function() return _G.__TIME end
end

-- helper: was any recorded SQL a schema (DDL) statement?
local function anyDDL()
    for _, sql in ipairs(spy.sql) do
        if type(sql) == 'string' and sql:upper():find('CREATE TABLE')
            or (type(sql) == 'string' and sql:upper():find('ALTER TABLE'))
            or (type(sql) == 'string' and sql:upper():find('DROP TABLE')) then
            return sql
        end
    end
    return nil
end

-- ---------------------------------------------------------------- config seed

local function baseConfig()
    return {
        RateLimit = 6,
        Timings = { biteMin = 4000, biteMax = 12000, hookWindow = 1500, hookLatency = 300, reelTimeout = 30000 },
        CastMaxDistance = 25.0,
        Durability = true, RodCanBreak = false, RequireAssembly = true, RequireZone = true,
        DefaultWater = 'ocean',
        RareLoot = {},
        Rarity = {
            common = { weight = 100, tension = 1.0, hookMult = 1.0 },
            rare   = { weight = 10,  tension = 1.5, hookMult = 0.8 },
        },
        Zones = {},
        Fish = {},
        Equipment = {
            rods = { fishing_rod_common = { level = 1, label = 'Common Rod', greenZone = 0.2, degrade = 1, durability = 20 } },
            reels = { reel_basic = { level = 1, label = 'Basic Reel', drainRate = 1.0, degrade = 1, durability = 20 } },
            lines = { line_basic = { level = 1, label = 'Basic Line', rating = 15, degrade = 1, durability = 20 } },
            hooks = { hook_4 = { label = 'Size 4 Hook', hookMod = 1.0 } },
            floats = { float_basic = { label = 'Basic Float', biteSpeed = 1.0, degrade = 1, durability = 20 } },
            baits = { worm = { label = 'Worm' } },
        },
        Admin = { waterTypes = { 'lake', 'river', 'ocean', 'swamp', 'dam' } },
    }
end

-- =============================================================== GROUP A
-- Server-side input validation (Validate.*) — Requirements 6.5, 23.5

local function loadValidate()
    installHost()
    Config = baseConfig()
    dofile('server/config_schema.lua')
    dofile('server/validate.lua')
end

test('A1 Validate.Setting clamps RateLimit into range and rejects non-numbers', function()
    loadValidate()
    equal(Validate.Setting('RateLimit', 5000), 120)     -- clamped to max
    equal(Validate.Setting('RateLimit', -3), 1)          -- clamped to min
    local v, err = Validate.Setting('RateLimit', 'abc')
    falsy(v); truthy(err)
end)

test('A2 Validate.Setting rejects unknown keys and unknown water', function()
    loadValidate()
    local v, err = Validate.Setting('__proto', true)
    falsy(v); truthy(err, 'unknown setting must be rejected')
    local w, werr = Validate.Setting('DefaultWater', 'lava')
    falsy(w); truthy(werr)
    equal(Validate.Setting('DefaultWater', 'ocean'), 'ocean')
end)

test('A3 Validate.Zone rejects bad payloads and clamps radius', function()
    loadValidate()
    falsy((Validate.Zone('not-a-table')))
    falsy((Validate.Zone({ name = '', water = 'lake', x = 1, y = 2, z = 3, radius = 10 })))
    falsy((Validate.Zone({ name = 'z', water = 'lava', x = 1, y = 2, z = 3, radius = 10 })))
    falsy((Validate.Zone({ name = 'z', water = 'lake', x = 'x', y = 2, z = 3, radius = 10 })))
    local clean = Validate.Zone({ name = 'Pier', water = 'ocean', x = 1, y = 2, z = 3, radius = 999999 })
    truthy(clean); equal(clean.radius, 2000)  -- clamped to max
end)

test('A4 Validate.Fish enforces behavior, rarity, weight and clamps numbers', function()
    loadValidate()
    local ok = { label = 'Bass', behavior = 'steady_light', rarity = 'common',
        weight = { min = 1, max = 4 }, price = 100, xp = 10, water = { 'lake' } }
    truthy((Validate.Fish(ok)))
    local bad = deepcopy(ok); bad.behavior = 'teleport'
    falsy((Validate.Fish(bad)))
    bad = deepcopy(ok); bad.rarity = 'legendary_hack'
    falsy((Validate.Fish(bad)))
    bad = deepcopy(ok); bad.weight = { min = 0, max = 4 }
    falsy((Validate.Fish(bad)))
    bad = deepcopy(ok); bad.weight = { min = 5, max = 2 }
    falsy((Validate.Fish(bad)))
    bad = deepcopy(ok); bad.water = { 'lava' }
    falsy((Validate.Fish(bad)))
    local clamped = Validate.Fish((function() local f = deepcopy(ok); f.price = 9e9; return f end)())
    equal(clamped.price, 100000)  -- price clamped to max
end)

test('A5 Validate.Equipment rejects unknown slots and clamps numeric ranges', function()
    loadValidate()
    falsy((Validate.Equipment('__proto', { label = 'x' })))
    falsy((Validate.Equipment('rods', 'not-a-table')))
    falsy((Validate.Equipment('rods', { label = '' })))
    local clean = Validate.Equipment('reels', { label = 'Reel', drainRate = 9999 })
    truthy(clean); equal(clean.drainRate, 10)  -- clamped to max
    local clean2 = Validate.Equipment('rods', { label = 'Rod', greenZone = 5 })
    equal(clean2.greenZone, 1)                 -- clamped to [0,1]
end)

test('A6 Validate.num clamps and rejects non-numbers', function()
    loadValidate()
    equal(Validate.num(50, 1, 120), 50)
    equal(Validate.num(500, 1, 120), 120)
    equal(Validate.num(0, 1, 120), 1)
    falsy(Validate.num('nope', 1, 120))
end)

-- =============================================================== GROUP B
-- Malicious metadata / input sanitizing — Requirements 6.5, 23.5

test('B1 Validate.Fish drops non-string bait entries (no arbitrary injection)', function()
    loadValidate()
    local clean = Validate.Fish({ label = 'Bass', behavior = 'steady_light', rarity = 'common',
        weight = { min = 1, max = 4 }, price = 100, xp = 10, water = { 'lake' },
        baits = { 'worm', { evil = true }, 42, 'shrimp' } })
    truthy(clean)
    equal(#clean.baits, 2)
    equal(clean.baits[1], 'worm')
    equal(clean.baits[2], 'shrimp')
end)

test('B2 Validate.Zone sanitizes pool: non-strings dropped, empty -> nil', function()
    loadValidate()
    local clean = Validate.Zone({ name = 'Pier', water = 'ocean', x = 1, y = 2, z = 3, radius = 20,
        pool = { 'bass', 5, { drop = true }, 'trout' } })
    equal(#clean.pool, 2)
    equal(clean.pool[1], 'bass')
    local empty = Validate.Zone({ name = 'Pier', water = 'ocean', x = 1, y = 2, z = 3, radius = 20,
        pool = { 1, 2, 3 } })
    equal(empty.pool, nil)  -- all invalid -> pool removed, not an empty injection surface
    falsy((Validate.Zone({ name = 'Pier', water = 'ocean', x = 1, y = 2, z = 3, radius = 20, pool = 'notlist' })))
end)

test('B3 Validate.Equipment whitelists fields, stripping malicious extras', function()
    loadValidate()
    local clean = Validate.Equipment('rods', {
        label = 'Rod', durability = 20,
        onUse = 'os.execute("rm -rf")', __index = {}, arbitrary = 999, level = 5,
    })
    truthy(clean)
    equal(clean.label, 'Rod')
    equal(clean.durability, 20)
    equal(clean.level, 5)
    equal(clean.onUse, nil, 'unknown field must not survive validation')
    equal(clean.__index, nil)
    equal(clean.arbitrary, nil)
end)

test('B4 Validate.Setting Timings rejects garbage and normalizes inverted range', function()
    loadValidate()
    falsy((Validate.Setting('Timings', 'not-a-table')))
    -- a non-numeric sub-field is rejected outright (out-of-range numbers are clamped)
    falsy((Validate.Setting('Timings', { biteMin = 'x', biteMax = 5000, hookWindow = 1500, hookLatency = 0, reelTimeout = 30000 })))
    local t = Validate.Setting('Timings', {
        biteMin = 12000, biteMax = 4000,  -- inverted on purpose
        hookWindow = 1500, hookLatency = 300, reelTimeout = 30000 })
    truthy(t)
    truthy(t.biteMin <= t.biteMax, 'inverted bite window must be swapped, not trusted')
end)

-- =============================================================== GROUP C
-- Authorization / ACE gating (admin.lua) — Requirements 23.5, 27.1

-- Builds the admin surface with an injected IsAdmin decision and a Store spy that
-- counts how many times a mutation actually reached the data layer.
local function loadAdmin(isAdminResult)
    installHost()
    Config = baseConfig()
    local storeCalls = { SaveSetting = 0, UpsertZone = 0, DeleteZone = 0, SaveFish = 0,
        DeleteFish = 0, SaveEquipment = 0, ResetDomain = 0, zonesPayloadWithId = 0 }
    Store = {
        SaveSetting = function() storeCalls.SaveSetting = storeCalls.SaveSetting + 1; return true end,
        UpsertZone = function() storeCalls.UpsertZone = storeCalls.UpsertZone + 1; return 7 end,
        DeleteZone = function() storeCalls.DeleteZone = storeCalls.DeleteZone + 1; return true end,
        SaveFish = function() storeCalls.SaveFish = storeCalls.SaveFish + 1; return true end,
        DeleteFish = function() storeCalls.DeleteFish = storeCalls.DeleteFish + 1; return true end,
        SaveEquipment = function() storeCalls.SaveEquipment = storeCalls.SaveEquipment + 1; return true end,
        ResetDomain = function() storeCalls.ResetDomain = storeCalls.ResetDomain + 1; return true end,
        zonesPayloadWithId = function() storeCalls.zonesPayloadWithId = storeCalls.zonesPayloadWithId + 1; return {} end,
    }
    local adminCalls = {}
    _G.exports = { zcore_lib = {
        IsAdmin = function(_, src, ace) adminCalls[#adminCalls + 1] = { src = src, ace = ace }; return isAdminResult end,
        Notify = function() end,
    } }
    dofile('server/admin.lua')
    return storeCalls, adminCalls
end

test('C1 admin:getConfig denies non-admins without leaking data', function()
    loadAdmin(false)
    equal(CB['zfishing:admin:getConfig'](5), nil, 'non-admin must get nil config')
    equal(CB['zfishing:admin:check'](5), false)
end)

test('C1b admin:getConfig returns config for an admin (uses zfishing.admin ACE)', function()
    local _, adminCalls = loadAdmin(true)
    local cfg = CB['zfishing:admin:getConfig'](5)
    truthy(cfg and cfg.settings, 'admin must receive config')
    equal(adminCalls[#adminCalls].ace, 'zfishing.admin')
end)

test('C2 every admin mutation is denied for non-admins and never reaches Store', function()
    local storeCalls = loadAdmin(false)
    equal(CB['zfishing:admin:saveSetting'](5, 'RateLimit', 10).err, 'denied')
    equal(CB['zfishing:admin:saveZone'](5, {}).err, 'denied')
    equal(CB['zfishing:admin:deleteZone'](5, 1).err, 'denied')
    equal(CB['zfishing:admin:saveFish'](5, 'bass', {}).err, 'denied')
    equal(CB['zfishing:admin:deleteFish'](5, 'bass').err, 'denied')
    equal(CB['zfishing:admin:saveEquipment'](5, 'rods', 'r', {}).err, 'denied')
    equal(CB['zfishing:admin:resetDomain'](5, 'fish').err, 'denied')
    for name, n in pairs(storeCalls) do equal(n, 0, 'Store.' .. name .. ' must not run for a non-admin') end
end)

test('C3 an authorized admin mutation reaches Store', function()
    local storeCalls = loadAdmin(true)
    local res = CB['zfishing:admin:saveSetting'](5, 'RateLimit', 10)
    truthy(res.ok)
    equal(storeCalls.SaveSetting, 1)
end)

test('C4 admin commands are ACE-gated (no client event for a non-admin)', function()
    loadAdmin(false)
    CMD['zfishadmin'](5, {})
    CMD['zfishzone'](5, {})
    equal(#spy.clientEvents, 0, 'a non-admin must not open any admin UI')
end)

test('C4b admin commands open UI for an admin', function()
    loadAdmin(true)
    CMD['zfishadmin'](5, {})
    truthy(#spy.clientEvents >= 1, 'an admin must be able to open the panel')
end)

-- =============================================================== GROUP D
-- Exact-slot ownership (rig.lua) — Requirements 23.5, 27.1
-- The server re-reads the named slot from the player's OWN inventory; a client
-- can only name a slot, never assert what it holds.

-- Inventory-backed mock of the pinned zcore_lib contract. inv[src][slot] is the
-- ground truth; GetSlot only ever returns a slot the player actually owns.
local function makeZfishing(state)
    state = state or {}
    local inv = state.inv or {}
    local calls = { addItem = 0, removeSlot = 0, setMeta = 0, addMoney = 0, removeItem = 0 }
    local Z = {}
    function Z.Blocked() return state.blocked end
    function Z.Enhanced() return state.mode ~= 'simple' end
    function Z.Simple() return state.mode == 'simple' end
    function Z.Identifier() return 'license:test' end
    function Z.HasItem(src, item)
        for _, s in pairs(inv[src] or {}) do if s.name == item then return true end end
        return false
    end
    function Z.ItemCount(src, item)
        local n = 0
        for _, s in pairs(inv[src] or {}) do if s.name == item then n = n + (s.count or 1) end end
        return n
    end
    function Z.Search(src, items)
        local want, out = {}, {}
        for _, it in ipairs(items) do want[it] = true end
        for slot, s in pairs(inv[src] or {}) do
            if want[s.name] then
                out[#out + 1] = { slot = slot, name = s.name, count = s.count or 1, metadata = s.metadata }
            end
        end
        return out
    end
    function Z.GetSlot(src, slot)
        local s = (inv[src] or {})[slot]
        if not s then return nil end
        return { slot = slot, name = s.name, count = s.count or 1, metadata = s.metadata }
    end
    function Z.SetSlotMeta(src, slot, meta)
        calls.setMeta = calls.setMeta + 1
        if state.metaFails then return false end
        local s = (inv[src] or {})[slot]
        if not s then return false end
        s.metadata = meta
        return true
    end
    function Z.AddItem(src, item, count, meta)
        calls.addItem = calls.addItem + 1
        if state.addFails then return false end
        inv[src] = inv[src] or {}
        local slot = (#inv[src]) + 100
        inv[src][slot] = { name = item, count = count, metadata = meta }
        return true
    end
    function Z.RemoveItem(src, item, count)
        calls.removeItem = calls.removeItem + 1
        return true
    end
    function Z.RemoveItemSlot(src, item, count, slot)
        calls.removeSlot = calls.removeSlot + 1
        local s = (inv[src] or {})[slot]
        if not s or s.name ~= item then return false end
        inv[src][slot] = nil
        return true
    end
    function Z.AddMoney() calls.addMoney = calls.addMoney + 1; return true end
    function Z.Notify(src, msg, kind) spy.notifies[#spy.notifies + 1] = { src = src, msg = msg, kind = kind } end
    return Z, inv, calls
end

local function loadRig(state)
    installHost()
    Config = baseConfig()
    local Z, inv, calls = makeZfishing(state)
    Zfishing = Z
    dofile('shared/rig_rules.lua')
    dofile('server/rig.lua')
    return inv, calls
end

test('D1 Rig.slotMeta trusts only owned rod slots, never client-named ones', function()
    local inv = loadRig({ mode = 'enhanced', inv = { [5] = {
        [3] = { name = 'fishing_rod_common', count = 1, metadata = { parts = {}, dur = { rod = 20 } } },
        [7] = { name = 'worm', count = 1 },
    } } })
    -- string / non-number slot from a malicious client
    equal(Rig.slotMeta(5, 'evil'), nil)
    -- a slot the player does not own
    equal(Rig.slotMeta(5, 99), nil)
    -- a slot that is owned but is not a rod
    equal(Rig.slotMeta(5, 7), nil)
    -- the real rod slot resolves
    local s, meta = Rig.slotMeta(5, 3)
    truthy(s and meta, 'owned rod slot must resolve')
    equal(s.name, 'fishing_rod_common')
end)

test('D1b Rig.slotMeta returns nil in simple mode (assembly disabled)', function()
    loadRig({ mode = 'simple', inv = { [5] = {
        [3] = { name = 'fishing_rod_common', count = 1, metadata = {} } } } })
    equal(Rig.slotMeta(5, 3), nil)
end)

test('D2 rig:attach validates part, ownership, occupancy and item', function()
    local inv = { [5] = {
        [3] = { name = 'fishing_rod_common', count = 1, metadata = { parts = {}, dur = { rod = 20 } } },
        [4] = { name = 'reel_basic', count = 1 },
    } }
    loadRig({ mode = 'enhanced', inv = inv })
    equal(CB['zfishing:rig:attach'](5, 3, 'rocket', 'x').err, 'bad_part')
    equal(CB['zfishing:rig:attach'](5, 99, 'reel', 'reel_basic').err, 'no_rod')
    equal(CB['zfishing:rig:attach'](5, 3, 'reel', 'reel_nonexistent').err, 'bad_item')
    -- happy path: consumes the carried reel
    truthy(CB['zfishing:rig:attach'](5, 3, 'reel', 'reel_basic').ok)
    -- the only carried reel is now fitted, so there is nothing left to attach
    equal(CB['zfishing:rig:attach'](5, 3, 'reel', 'reel_basic').err, 'not_carried')
    -- attaching to a FILLED socket swaps: the fitted part returns to the
    -- inventory and the new one goes on. There is no 'occupied' refusal by
    -- design -- see server/rig.lua:196-204.
    inv[5][4] = { name = 'reel_basic', count = 1 }
    truthy(CB['zfishing:rig:attach'](5, 3, 'reel', 'reel_basic').ok,
        'a filled socket swaps rather than refusing')
end)

test('D2b rig:attach reports not_carried when the player lacks the part', function()
    loadRig({ mode = 'enhanced', inv = { [5] = {
        [3] = { name = 'fishing_rod_common', count = 1, metadata = { parts = {}, dur = { rod = 20 } } },
    } } })
    equal(CB['zfishing:rig:attach'](5, 3, 'reel', 'reel_basic').err, 'not_carried')
end)

test('D2c rig:attach returns the part when the metadata write fails (never eats items)', function()
    local _, calls = loadRig({ mode = 'enhanced', metaFails = true, inv = { [5] = {
        [3] = { name = 'fishing_rod_common', count = 1, metadata = { parts = {}, dur = { rod = 20 } } },
        [4] = { name = 'reel_basic', count = 1 },
    } } })
    local res = CB['zfishing:rig:attach'](5, 3, 'reel', 'reel_basic')
    equal(res.err, 'meta_failed')
    equal(calls.removeSlot, 1, 'the part was pulled from the slot')
    equal(calls.addItem, 1, 'and handed back after the failed write')
end)

test('D3 rig:detach aborts on a full inventory and leaves the part fitted (no dupe)', function()
    loadRig({ mode = 'enhanced', addFails = true, inv = { [5] = {
        [3] = { name = 'fishing_rod_common', count = 1,
            metadata = { parts = { reel = 'reel_basic' }, dur = { rod = 20, reel = 10 } } },
    } } })
    equal(CB['zfishing:rig:detach'](5, 3, 'reel').err, 'inv_full')
    -- part is still fitted because add-back failed first
    local view = CB['zfishing:rig:get'](5, 3)
    truthy(view.parts.reel, 'the part must stay fitted when it could not be returned')
end)

-- =============================================================== session loader
-- Loads the real session state machine (+ rig, for the assembly path) with the
-- gameplay dependencies mocked. Used by groups D4, E and F.

local function loadSession(opts)
    opts = opts or {}
    installHost()
    Config = baseConfig()
    Config.RequireAssembly = opts.requireAssembly == true
    Config.RequireZone = opts.requireZone ~= false           -- default true
    Config.Durability = opts.durability == true              -- default off (simpler v1 path)
    Config.DefaultWater = opts.defaultWater or 'ocean'
    if opts.rateLimit then Config.RateLimit = opts.rateLimit end
    if opts.zones then Config.Zones = opts.zones end

    local inv = opts.inv or { [5] = {
        [1] = { name = 'fishing_rod_common', count = 1, metadata = {
            parts = { reel = 'reel_basic', line = 'line_basic', hook = 'hook_4', float = 'float_basic' },
            dur = { rod = 20, reel = 20, line = 20, hook = 20, float = 20 } } },
        [2] = { name = 'worm', count = 5 },
    } }
    Zfishing = makeZfishing({ mode = opts.mode or 'enhanced', blocked = opts.blocked, inv = inv })
    Progression = {
        Get = function() return { level = opts.level or 5, identifier = 'license:test' } end,
        Load = function() end, AddXP = function() end, Save = function() end,
    }
    Generator = { Roll = function()
        if opts.emptyWater then return nil end
        return opts.fish or { species = 'bass', label = 'Bass', weight = 2.0, quality = 3,
            rarity = 'common', behavior = 'steady_light', biteDelay = 100, hookWindow = 1500,
            tensionDiff = 1.0, fishEnergy = 50, xp = 10, price = 100 }
    end }
    local rewardCalls = { give = 0 }
    Rewards = { GiveCatch = function() rewardCalls.give = rewardCalls.give + 1; return opts.giveCatch ~= false end }
    dofile('shared/util.lua')
    dofile('shared/rig_rules.lua')
    dofile('server/rig.lua')
    dofile('server/session.lua')
    return inv, rewardCalls
end

-- Runs cast -> bite -> hook -> claim(success) for src, advancing the clock past
-- the minimum plausible reel time. Returns the cast result and the claim result.
local function fullCatch(src, rodSlot)
    local cast = CB['zfishing:cast'](src, 0.5, rodSlot)
    if not cast.ok then return cast, nil end
    truthy(TIMERS[1], 'cast must schedule the bite timer')
    TIMERS[1].fn()                       -- bite fires -> state 'hooking'
    local hook = CB['zfishing:hook'](src)
    truthy(hook.ok, 'hook must succeed inside the window')
    _G.__NOW = _G.__NOW + 6000           -- plenty of reel time
    local claim = CB['zfishing:claim'](src, 6000, true, nil)
    return cast, claim
end

-- =============================================================== GROUP E
-- Distance / rate controls (session.lua) — Requirements 6.5, 23.5

test('E1 rate limit blocks a cast past Config.RateLimit and resets after the window', function()
    loadSession({ rateLimit = 1, requireZone = false })
    local _, claim = fullCatch(5)
    truthy(claim and claim.ok, 'first catch should succeed')
    local blocked = CB['zfishing:cast'](5, 0.5)
    equal(blocked.reason, 'rate', 'second cast in the window must be rate limited')
    _G.__TIME = _G.__TIME + 61           -- new 60s window
    local after = CB['zfishing:cast'](5, 0.5)
    truthy(after.ok, 'a cast in a fresh window is allowed again')
end)

test('E2 zone is resolved from the server-side player position, not a client claim', function()
    local zones = { { name = 'Lake', coords = { x = 0.0, y = 0.0, z = 0.0 }, radius = 50.0, water = 'lake' } }
    -- standing far away: no zone contains the player
    loadSession({ requireZone = true, zones = zones })
    _G.__POS = { x = 1000.0, y = 1000.0, z = 0.0 }
    equal(CB['zfishing:cast'](5, 0.5).reason, 'no_zone', 'outside every zone must fail closed')
    -- standing inside the radius: cast proceeds
    loadSession({ requireZone = true, zones = zones })
    _G.__POS = { x = 5.0, y = 5.0, z = 0.0 }
    truthy(CB['zfishing:cast'](5, 0.5).ok, 'inside the zone radius must be allowed')
end)

test('E3 cast rejects malicious power values', function()
    loadSession({ requireZone = false })
    falsy(CB['zfishing:cast'](5, 'lots').ok, 'non-number power rejected')
    loadSession({ requireZone = false })
    falsy(CB['zfishing:cast'](5, -1).ok, 'negative power rejected')
    loadSession({ requireZone = false })
    falsy(CB['zfishing:cast'](5, 5).ok, 'power > 1 rejected')
end)

test('E4 cast is gated by the blocked contract and by an in-flight session', function()
    loadSession({ blocked = { code = 'PROFILE_UNAVAILABLE' }, requireZone = false })
    equal(CB['zfishing:cast'](5, 0.5).reason, 'unavailable')
    loadSession({ requireZone = false })
    truthy(CB['zfishing:cast'](5, 0.5).ok, 'first cast starts a session')
    equal(CB['zfishing:cast'](5, 0.5).reason, 'busy', 'a second concurrent cast is refused')
end)

-- =============================================================== GROUP F
-- Server-authoritative anti-cheat timing (session.lua) — Requirements 6.5, 23.5

test('F1 claim rejects an implausibly fast reel and grants no reward', function()
    local _, rewardCalls = loadSession({ requireZone = false })
    local cast = CB['zfishing:cast'](5, 0.5)
    truthy(cast.ok)
    TIMERS[1].fn()
    truthy(CB['zfishing:hook'](5).ok)
    _G.__NOW = _G.__NOW + 300            -- way under the minimum plausible reel time
    local claim = CB['zfishing:claim'](5, 300, true, nil)
    falsy(claim.ok)
    equal(claim.reason, 'too_fast')
    equal(rewardCalls.give, 0, 'no reward is handed out for a rejected claim')
end)

test('F2 claim is refused unless the session is in the reeling state', function()
    loadSession({ requireZone = false })
    falsy(CB['zfishing:claim'](5, 5000, true, nil).ok, 'cannot claim without a live reeling session')
end)

test('F3 hook is refused after the hook window deadline passes', function()
    loadSession({ requireZone = false })
    truthy(CB['zfishing:cast'](5, 0.5).ok)
    TIMERS[1].fn()                       -- state 'hooking', deadline = now + window + latency
    _G.__NOW = _G.__NOW + 100000         -- blow past the deadline
    local hook = CB['zfishing:hook'](5)
    falsy(hook.ok)
    equal(hook.reason, 'too_slow')
end)

test('D4 assembly cast trusts the server-read slot, not a client-named one', function()
    loadSession({ requireAssembly = true, mode = 'enhanced', requireZone = false, durability = false })
    -- slot 99 is not owned by the player -> the server refuses
    equal(CB['zfishing:cast'](5, 0.5, 99).reason, 'no_rod')
    -- the real, fully-assembled rod slot is accepted
    loadSession({ requireAssembly = true, mode = 'enhanced', requireZone = false, durability = false })
    truthy(CB['zfishing:cast'](5, 0.5, 1).ok, 'the owned, complete rig is accepted')
end)

-- =============================================================== GROUP G
-- Absence of boot-time DB/host mutation — Requirement 27.1
-- Only the Site Agent may mutate the target/schema. Booting the resource must
-- read/write no DB and touch no host surface; schema DDL must never appear, and
-- even the deferred data thread only runs DML into Agent-provisioned tables.

local function loadAllServerModulesAtBoot()
    installHost()
    Config = baseConfig()
    _G.exports = { zcore_lib = {
        GetProfile = function() return { ok = false, error = { code = 'PROFILE_UNAVAILABLE' } } end,
        IsAdmin = function() return false end,
        Notify = function() end,
        GetIdentifier = function() return { ok = true, effects = { details = { identifier = 'license:test' } } } end,
    } }
    dofile('shared/util.lua')
    dofile('server/config_schema.lua')
    dofile('server/validate.lua')
    dofile('server/lib.lua')
    dofile('server/store.lua')
    dofile('server/generator.lua')
    dofile('server/progression.lua')
    dofile('server/rewards.lua')
    dofile('shared/rig_rules.lua')
    dofile('server/rig.lua')
    dofile('server/session.lua')
    dofile('server/weather.lua')
    dofile('server/admin.lua')
end

test('G1 booting every server module performs no DB read/write and no host mutation', function()
    loadAllServerModulesAtBoot()
    equal(#spy.sql, 0, 'no SQL may run at resource boot (Site-Agent-only DB boundary)')
    equal(#spy.host, 0, 'no host mutation (convar/process) may run at boot')
end)

test('G2 no server module ever issues schema DDL, even in the deferred data thread', function()
    loadAllServerModulesAtBoot()
    -- run the deferred CreateThread bodies (profile resolve + store seed/load)
    for _, fn in ipairs(THREADS) do pcall(fn) end
    truthy(#spy.sql > 0, 'the deferred data thread should touch the DB (seed/load)')
    equal(anyDDL(), nil, 'the resource must never CREATE/ALTER/DROP schema — that is the Agent migrations job')
    equal(#spy.host, 0, 'the deferred thread must still not mutate the host')
end)

test('G3 the runtime lock is read once from zcore_lib, never auto-probed schema', function()
    loadAllServerModulesAtBoot()
    for _, fn in ipairs(THREADS) do pcall(fn) end
    -- with an unavailable profile, fishing is blocked and no cast/claim path can run
    truthy(Zfishing.Blocked(), 'an unavailable runtime profile blocks gameplay')
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
