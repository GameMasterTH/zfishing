Store = {}

-- snapshot of the static equipment seed, taken before Store.Load() overwrites
-- Config.Equipment with DB rows — used to backfill fields added in updates
-- (e.g. `degrade`) into rows seeded by an older version
local staticEquipment = json.decode(json.encode(Config.Equipment))

local SETTING_KEYS = { 'RateLimit', 'Timings', 'CastMaxDistance', 'Durability', 'RareLoot', 'DefaultWater', 'RequireZone', 'RodCanBreak', 'RequireAssembly' }

local function getSetting(key)
    local v = MySQL.scalar.await('SELECT `value` FROM zfishing_settings WHERE `key` = ?', { key })
    if v == nil then return nil end
    return json.decode(v)
end

local function putSetting(key, value)
    MySQL.prepare.await(
        'INSERT INTO zfishing_settings (`key`, `value`) VALUES (?, ?) ON DUPLICATE KEY UPDATE `value` = VALUES(`value`)',
        { key, json.encode(value) })
end

local function seededMark(domain) return '_seeded_' .. domain end

function Store.Seed()
    if getSetting(seededMark('settings')) == nil then
        putSetting('RateLimit', Config.RateLimit)
        putSetting('Timings', Config.Timings)
        putSetting('CastMaxDistance', Config.CastMaxDistance)
        putSetting('Durability', Config.Durability)
        putSetting('RareLoot', Config.RareLoot)
        putSetting('DefaultWater', Config.DefaultWater)
        putSetting('RequireZone', Config.RequireZone)
        putSetting('RodCanBreak', Config.RodCanBreak)
        putSetting('RequireAssembly', Config.RequireAssembly)
        putSetting(seededMark('settings'), true)
    end
    if getSetting(seededMark('zones')) == nil then
        for _, z in ipairs(Config.Zones) do
            MySQL.prepare.await(
                'INSERT INTO zfishing_zones (name, water, x, y, z, radius, pool) VALUES (?, ?, ?, ?, ?, ?, ?)',
                { z.name, z.water, z.coords.x, z.coords.y, z.coords.z, z.radius, z.pool and json.encode(z.pool) or nil })
        end
        putSetting(seededMark('zones'), true)
    end
    if getSetting(seededMark('fish')) == nil then
        for species, data in pairs(Config.Fish) do
            MySQL.prepare.await('INSERT INTO zfishing_fish (species, data) VALUES (?, ?)', { species, json.encode(data) })
        end
        putSetting(seededMark('fish'), true)
    end
    if getSetting(seededMark('equipment')) == nil then
        for slot, items in pairs(Config.Equipment) do
            for item, data in pairs(items) do
                MySQL.prepare.await('INSERT INTO zfishing_equipment (slot, item, data) VALUES (?, ?, ?)',
                    { slot, item, json.encode(data) })
            end
        end
        putSetting(seededMark('equipment'), true)
    end
end

function Store.Load()
    for _, key in ipairs(SETTING_KEYS) do
        local v = getSetting(key)
        if v ~= nil then Config[key] = v end
    end
    local zrows = MySQL.query.await('SELECT * FROM zfishing_zones WHERE enabled = 1') or {}
    local zones = {}
    for _, z in ipairs(zrows) do
        zones[#zones + 1] = {
            id = z.id, name = z.name, water = z.water,
            coords = vec3(z.x + 0.0, z.y + 0.0, z.z + 0.0), radius = z.radius + 0.0,
            pool = z.pool and json.decode(z.pool) or nil,
        }
    end
    Config.Zones = zones
    local frows = MySQL.query.await('SELECT species, data FROM zfishing_fish') or {}
    local fish = {}
    for _, f in ipairs(frows) do fish[f.species] = json.decode(f.data) end
    if next(fish) then Config.Fish = fish end
    local erows = MySQL.query.await('SELECT slot, item, data FROM zfishing_equipment') or {}
    local equip = {}
    for _, e in ipairs(erows) do
        local data = json.decode(e.data)
        -- migration: backfill keys the static seed has but this (older) DB row
        -- lacks — preserves admin-edited values, only fills the gaps
        local seed = staticEquipment[e.slot] and staticEquipment[e.slot][e.item]
        if seed then
            local changed = false
            for k, v in pairs(seed) do
                if data[k] == nil then data[k] = v; changed = true end
            end
            if changed then
                MySQL.prepare.await('UPDATE zfishing_equipment SET data = ? WHERE slot = ? AND item = ?',
                    { json.encode(data), e.slot, e.item })
            end
        end
        equip[e.slot] = equip[e.slot] or {}
        equip[e.slot][e.item] = data
    end
    for slot, items in pairs(equip) do
        if next(items) then Config.Equipment[slot] = items end
    end
end

function Store.zonesPayload()
    local out = {}
    for _, z in ipairs(Config.Zones) do
        out[#out + 1] = { name = z.name, water = z.water,
            x = z.coords.x, y = z.coords.y, z = z.coords.z, radius = z.radius, pool = z.pool }
    end
    return out
end

function Store.zonesPayloadWithId()
    local out = {}
    for _, z in ipairs(Config.Zones) do
        out[#out + 1] = { id = z.id, name = z.name, water = z.water,
            x = z.coords.x, y = z.coords.y, z = z.coords.z, radius = z.radius, pool = z.pool }
    end
    return out
end

-- ---------------------------------------------------------------- client sync
local function clientPayload()
    return {
        zones = Store.zonesPayload(),
        castMaxDistance = Config.CastMaxDistance,
        defaultWater = Config.DefaultWater,
        requireZone = Config.RequireZone,
    }
end

function Store.SyncTo(src) TriggerClientEvent('zfishing:store:sync', src, clientPayload()) end
function Store.Broadcast() TriggerClientEvent('zfishing:store:sync', -1, clientPayload()) end

-- An honest client asks once, 1s after its own start (client/store.lua). The
-- window is deliberately generous — a resource restart or a rejoin legitimately
-- re-asks — and a throttled request is simply dropped: no log, no disconnect, and
-- nothing about a fishing session depends on it.
local syncGate = ZUtil.MakeRateGate({
    request = { max = 3, window = 10000 },
})

RegisterNetEvent('zfishing:store:request', function()
    local src = source
    if not syncGate.allow(src, 'request') then return end
    Store.SyncTo(src)
end)

AddEventHandler('playerDropped', function() syncGate.forget(source) end)

RegisterCommand('zfishreload', function(src)
    if not exports.zcore_lib:IsAdmin(src, 'zfishing.admin') then return end
    Store.Load()
    Store.Broadcast()
    if src ~= 0 then exports.zcore_lib:Notify(src, 'zfishing config reloaded', 'success')
    else print('[zfishing] reloaded') end
end, false)

-- ---------------------------------------------------------------- mutations
function Store.SaveSetting(key, value)
    local clean, err = Validate.Setting(key, value)
    if err then return false, err end
    Config[key] = clean
    putSetting(key, clean)
    Store.Broadcast()
    return true
end

function Store.UpsertZone(z)
    local c, err = Validate.Zone(z)
    if err then return nil, err end
    if c.id then
        MySQL.prepare.await('UPDATE zfishing_zones SET name=?, water=?, x=?, y=?, z=?, radius=?, pool=? WHERE id=?',
            { c.name, c.water, c.x, c.y, c.z, c.radius, c.pool and json.encode(c.pool) or nil, c.id })
    else
        c.id = MySQL.insert.await('INSERT INTO zfishing_zones (name, water, x, y, z, radius, pool) VALUES (?, ?, ?, ?, ?, ?, ?)',
            { c.name, c.water, c.x, c.y, c.z, c.radius, c.pool and json.encode(c.pool) or nil })
    end
    Store.Load()
    Store.Broadcast()
    return c.id
end

function Store.DeleteZone(id)
    id = tonumber(id); if not id then return false end
    MySQL.prepare.await('DELETE FROM zfishing_zones WHERE id = ?', { id })
    Store.Load()
    Store.Broadcast()
    return true
end

function Store.SaveFish(species, data)
    if type(species) ~= 'string' or species == '' then return false, 'species key required' end
    local c, err = Validate.Fish(data); if err then return false, err end
    MySQL.prepare.await('INSERT INTO zfishing_fish (species, data) VALUES (?, ?) ON DUPLICATE KEY UPDATE data = VALUES(data)',
        { species, json.encode(c) })
    Config.Fish[species] = c
    return true
end

function Store.DeleteFish(species)
    MySQL.prepare.await('DELETE FROM zfishing_fish WHERE species = ?', { species })
    Config.Fish[species] = nil
    return true
end

function Store.SaveEquipment(slot, item, data)
    if type(item) ~= 'string' or item == '' then return false, 'item key required' end
    local c, err = Validate.Equipment(slot, data); if err then return false, err end
    MySQL.prepare.await('INSERT INTO zfishing_equipment (slot, item, data) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE data = VALUES(data)',
        { slot, item, json.encode(c) })
    Config.Equipment[slot] = Config.Equipment[slot] or {}
    Config.Equipment[slot][item] = c
    return true
end

-- domain: 'settings' | 'zones' | 'fish' | 'equipment' — wipe DB rows + reseed from static Config
function Store.ResetDomain(domain)
    local tables = { settings = 'zfishing_settings', zones = 'zfishing_zones', fish = 'zfishing_fish', equipment = 'zfishing_equipment' }
    if not tables[domain] then return false, 'unknown domain' end
    if domain == 'settings' then
        for _, key in ipairs(SETTING_KEYS) do
            MySQL.prepare.await('DELETE FROM zfishing_settings WHERE `key` = ?', { key })
        end
    else
        MySQL.query.await('TRUNCATE TABLE ' .. tables[domain])
    end
    MySQL.prepare.await('DELETE FROM zfishing_settings WHERE `key` = ?', { seededMark(domain) })
    Store.Seed()   -- reseeds only the cleared domain (its marker is gone)
    Store.Load()
    Store.Broadcast()
    return true
end

CreateThread(function()
    while GetResourceState('oxmysql') ~= 'started' do Wait(100) end
    -- Schema is provisioned declaratively by the Site Agent (migrations/mysql)
    -- BEFORE this resource starts. The resource must never create/alter schema
    -- at boot (Site Agent-only DB mutation boundary). Seed()/Load() only read
    -- and write package business data into the Agent-provisioned tables.
    Store.Seed()
    Store.Load()
    print('[zfishing] store loaded: ' .. #Config.Zones .. ' zones')
end)
