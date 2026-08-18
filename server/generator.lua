Generator = {}

local function speciesInWater(species, water)
    for _, w in ipairs(Config.Fish[species].water) do
        if w == water then return true end
    end
    return false
end

function Generator.Quality(weight, wMin, wMax)
    local ratio = (weight - wMin) / math.max(0.001, (wMax - wMin))
    local base = 1 + math.floor(ratio * 4 + 0.5)         -- 1..5 by size
    local jitter = math.random(-1, 1)
    return ZUtil.clamp(base + jitter, 1, 5)
end

-- ctx: { water, pool (optional explicit species list), rod, reel, line, hook, float, bait }
function Generator.Roll(src, ctx)
    local weather = GetWeatherState()
    local rodCfg  = Config.Equipment.rods[ctx.rod] or {}
    local hookCfg = Config.Equipment.hooks[ctx.hook] or {}

    local speciesList = ctx.pool
    if not speciesList then
        speciesList = {}
        for name in pairs(Config.Fish) do speciesList[#speciesList+1] = name end
    end

    local candidates = {}
    for _, name in ipairs(speciesList) do
        local fish = Config.Fish[name]
        if fish and speciesInWater(name, ctx.water) then
            local rar = Config.Rarity[fish.rarity]
            local w = rar.weight

            -- bait affinity
            for _, b in ipairs(fish.baits) do
                if b == ctx.bait then w = w * 3 end
            end
            -- rare-boosting gear
            if fish.rarity ~= 'common' then
                w = w * (rodCfg.rareBonus or 1) * (hookCfg.rareBonus or 1)
            end
            -- weather + time
            local wm = Config.Weather.weather[weather.weather]
            if wm and wm[name] then w = w * wm[name] end
            for _, t in ipairs(Config.Weather.time) do
                if weather.hour >= t[1] and weather.hour < t[2] and t[3][name] then
                    w = w * t[3][name]
                end
            end

            candidates[#candidates+1] = { name = name, weight = w }
        end
    end

    if #candidates == 0 then return nil end
    local picked = ZUtil.weightedPick(candidates)
    local fish = Config.Fish[picked.name]
    local rar = Config.Rarity[fish.rarity]

    local weight = ZUtil.randFloat(fish.weight.min, fish.weight.max)
    local quality = Generator.Quality(weight, fish.weight.min, fish.weight.max)

    return {
        species     = picked.name,
        label       = fish.label,
        weight      = math.floor(weight * 100) / 100,
        quality     = quality,
        rarity      = fish.rarity,
        behavior    = fish.behavior,
        biteDelay   = math.random(Config.Timings.biteMin, Config.Timings.biteMax),
        hookWindow  = math.floor(Config.Timings.hookWindow * rar.hookMult * (hookCfg.hookMod or 1)),
        tensionDiff = rar.tension,
        -- heavier = longer fight, capped so the min plausible reel time always
        -- fits inside Config.Timings.reelTimeout (uncapped, a 400kg shark would
        -- need longer than the timeout and become uncatchable)
        fishEnergy  = math.min(200, 40 + weight * 1.5),
        xp          = fish.xp,
        price       = fish.price,
    }
end

-- QA helper: /zfish_roll [water] samples one roll. Admin-gated -- it leaks the
-- generator's behaviour and is a QA tool, not a player command.
RegisterCommand('zfish_roll', function(src, args)
    if src == 0 then return end
    if not exports.zcore_lib:IsAdmin(src, 'zfishing.admin') then return end
    local water = args[1] or 'ocean'
    local f = Generator.Roll(src, { water = water, rod='fishing_rod_common', hook='hook_4', bait='worm' })
    if f then
        exports.zcore_lib:Notify(src, ('%s %.2fkg %d* (%s)'):format(f.label, f.weight, f.quality, f.rarity), 'inform')
    else
        exports.zcore_lib:Notify(src, 'No fish for water: '..water, 'error')
    end
end, false)
