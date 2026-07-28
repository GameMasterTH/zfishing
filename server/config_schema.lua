ConfigSchema = {}

ConfigSchema.WATER_TYPES = { lake = true, river = true, ocean = true, swamp = true, dam = true }
ConfigSchema.BEHAVIOR_TYPES = { steady_light = true, steady_heavy = true, run_stop = true, erratic = true }
ConfigSchema.EQUIPMENT_SLOTS = { rods = true, reels = true, lines = true, hooks = true, floats = true, baits = true }

ConfigSchema.Settings = {
    RateLimit        = { type = 'number', min = 1, max = 120 },
    CastMaxDistance  = { type = 'number', min = 5, max = 100 },
    Durability       = { type = 'boolean' },
    RodCanBreak      = { type = 'boolean' },
    RequireAssembly  = { type = 'boolean' },
    RequireZone      = { type = 'boolean' },
    DefaultWater     = { type = 'enum', values = ConfigSchema.WATER_TYPES },
    Timings          = { type = 'object', fields = {
        biteMin     = { type = 'number', min = 500, max = 60000 },
        biteMax     = { type = 'number', min = 500, max = 60000 },
        hookWindow  = { type = 'number', min = 200, max = 10000 },
        hookLatency = { type = 'number', min = 0, max = 2000 },
        reelTimeout = { type = 'number', min = 3000, max = 120000 },
    }},
    RareLoot         = { type = 'array' },
}

ConfigSchema.EquipmentRanges = {
    greenZone  = { 0, 1 },
    rareBonus  = { 0, 5 },
    durability = { 0, 10000 },
    level      = { 1, 100 },
    drainRate  = { 0.1, 10 },
    rating     = { 1, 500 },
    hookMod    = { 0.1, 5 },
    biteSpeed  = { 0.1, 5 },
    degrade    = { 0, 1000 },
}

function ConfigSchema.ClampNum(v, min, max)
    v = tonumber(v)
    if not v then return nil end
    if v < min then v = min elseif v > max then v = max end
    return v
end

function ConfigSchema.ValidateSetting(key, value)
    local schema = ConfigSchema.Settings[key]
    if not schema then return nil, 'unknown setting: ' .. tostring(key) end

    if schema.type == 'number' then
        local v = ConfigSchema.ClampNum(value, schema.min, schema.max)
        return v, v and nil or (key .. ' invalid')
    elseif schema.type == 'boolean' then
        return (value == true or value == false), nil
    elseif schema.type == 'enum' then
        return schema.values[value] and value or nil, schema.values[value] and nil or 'unknown water type'
    elseif schema.type == 'object' then
        if type(value) ~= 'table' then return nil, 'Timings must be an object' end
        local t = {}
        for fName, fRule in pairs(schema.fields) do
            local v = ConfigSchema.ClampNum(value[fName], fRule.min, fRule.max)
            if v == nil then return nil, 'Timings.' .. fName .. ' invalid' end
            t[fName] = v
        end
        if t.biteMin and t.biteMax and t.biteMin > t.biteMax then
            t.biteMin, t.biteMax = t.biteMax, t.biteMin
        end
        return t
    elseif schema.type == 'array' then
        if type(value) ~= 'table' then return nil, 'RareLoot must be a list' end
        local out = {}
        for _, e in ipairs(value) do
            if type(e.item) ~= 'string' or e.item == '' then return nil, 'loot item name required' end
            out[#out + 1] = {
                item = e.item,
                chance = ConfigSchema.ClampNum(e.chance, 0, 1) or 0,
                label = tostring(e.label or e.item)
            }
        end
        return out
    end
    return nil, 'unknown setting: ' .. tostring(key)
end

function ConfigSchema.ValidateZone(z)
    if type(z) ~= 'table' then return nil, 'zone payload invalid' end
    if type(z.name) ~= 'string' or z.name == '' then return nil, 'zone name required' end
    if not ConfigSchema.WATER_TYPES[z.water] then return nil, 'unknown water type' end
    local x, y, zz = tonumber(z.x), tonumber(z.y), tonumber(z.z)
    local r = ConfigSchema.ClampNum(z.radius, 5, 2000)
    if not (x and y and zz and r) then return nil, 'zone coords/radius invalid' end
    local pool
    if z.pool ~= nil then
        if type(z.pool) ~= 'table' then return nil, 'pool must be a list' end
        pool = {}
        for _, s in ipairs(z.pool) do if type(s) == 'string' then pool[#pool + 1] = s end end
        if #pool == 0 then pool = nil end
    end
    return { id = tonumber(z.id), name = z.name, water = z.water, x = x, y = y, z = zz, radius = r, pool = pool }
end

function ConfigSchema.ValidateFish(data)
    if type(data) ~= 'table' then return nil, 'fish payload invalid' end
    if type(data.label) ~= 'string' or data.label == '' then return nil, 'label required' end
    if not ConfigSchema.BEHAVIOR_TYPES[data.behavior] then return nil, 'unknown behavior' end
    if type(data.rarity) ~= 'string' or Config.Rarity[data.rarity] == nil then return nil, 'unknown rarity' end
    local wmin = tonumber(data.weight and data.weight.min)
    local wmax = tonumber(data.weight and data.weight.max)
    if not (wmin and wmax) or wmin <= 0 or wmax <= wmin then return nil, 'weight.min must be > 0 and < weight.max' end
    local price = ConfigSchema.ClampNum(data.price, 0, 100000); if not price then return nil, 'price invalid' end
    local xp = ConfigSchema.ClampNum(data.xp, 0, 100000); if not xp then return nil, 'xp invalid' end
    if type(data.water) ~= 'table' or #data.water == 0 then return nil, 'at least one water type' end
    local water, baits = {}, {}
    for _, w in ipairs(data.water) do
        if not ConfigSchema.WATER_TYPES[w] then return nil, 'unknown water: ' .. tostring(w) end
        water[#water + 1] = w
    end
    for _, b in ipairs(data.baits or {}) do if type(b) == 'string' then baits[#baits + 1] = b end end
    return { label = data.label, water = water, weight = { min = wmin, max = wmax },
             rarity = data.rarity, price = price, baits = baits, behavior = data.behavior, xp = xp }
end

function ConfigSchema.ValidateEquipment(slot, data)
    if not ConfigSchema.EQUIPMENT_SLOTS[slot] then return nil, 'unknown slot' end
    if type(data) ~= 'table' then return nil, 'equipment payload invalid' end
    if type(data.label) ~= 'string' or data.label == '' then return nil, 'label required' end
    local clean = { label = data.label }
    for k, range in pairs(ConfigSchema.EquipmentRanges) do
        if data[k] ~= nil then
            local v = ConfigSchema.ClampNum(data[k], range[1], range[2]); if not v then return nil, k .. ' invalid' end
            clean[k] = v
        end
    end
    return clean
end
