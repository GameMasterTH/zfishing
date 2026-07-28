-- Per-player fishing session state machine. This file is the anti-cheat core:
-- every fish is rolled server-side at cast time, the client is never told the
-- species until a validated claim, and every transition re-checks state,
-- inventory, and timing plausibility.

local sessions = {}   -- [src] = { state, fish, bait, rod, castAt, hookDeadline, reelStart, zone }
local rate = {}       -- [src] = { count, windowStart }

local function reset(src) sessions[src] = nil end

local function withinRate(src)
    local now = os.time()
    local r = rate[src]
    if not r or now - r.windowStart >= 60 then
        rate[src] = { count = 0, windowStart = now }
        r = rate[src]
    end
    return r.count < Config.RateLimit
end

-- Best rod the player owns AND has the level for (highest level requirement wins).
local function resolveRod(src, level)
    local best, bestLevel
    for name, cfg in pairs(Config.Equipment.rods) do
        if cfg.level <= level and (not bestLevel or cfg.level > bestLevel) then
            if Zfishing.HasItem(src, name, 1) then
                best, bestLevel = name, cfg.level
            end
        end
    end
    return best
end

-- Best line the player owns and can use; everyone implicitly has 10lb as a floor
-- so a missing line item never blocks fishing.
local function resolveLineRating(src, level)
    local best = 10
    for name, cfg in pairs(Config.Equipment.lines) do
        if cfg.level <= level and cfg.rating > best and Zfishing.HasItem(src, name, 1) then
            best = cfg.rating
        end
    end
    return best
end

local function resolveBait(src)
    for baitName in pairs(Config.Equipment.baits) do
        if Zfishing.HasItem(src, baitName, 1) then return baitName end
    end
    return nil
end

-- Zone the player is actually standing in, resolved server-side from their real
-- position — never trust a zone name the client claims. 2D horizontal distance to
-- match client/main.lua's currentZone(). Returns nil when no zone contains them
-- AND Config.RequireZone is on ("no catchable fish here"). When RequireZone is off
-- (admin-toggleable via the panel), falls back to an open-water pool using
-- Config.DefaultWater — the pre-zone-mandatory behavior.
local function resolveZone(src)
    local pos = GetEntityCoords(GetPlayerPed(src))
    for _, z in ipairs(Config.Zones) do
        if z.coords then
            local dx, dy = pos.x - z.coords.x, pos.y - z.coords.y
            if (dx * dx + dy * dy) <= (z.radius * z.radius) then return z end
        end
    end
    if not Config.RequireZone then
        return { name = 'Open Water', water = Config.DefaultWater, pool = nil }
    end
    return nil
end

lib.callback.register('zfishing:cast', function(src, power, rodSlot)
    if Zfishing.Blocked() then return { ok = false, reason = 'unavailable' } end
    if sessions[src] then return { ok = false, reason = 'busy' } end
    if not withinRate(src) then return { ok = false, reason = 'rate' } end
    if type(power) ~= 'number' or power < 0 or power > 1 then return { ok = false } end

    if not Progression.Get(src) then Progression.Load(src) end
    local prog = Progression.Get(src)
    local level = prog and prog.level or 1

    -- Assembled-rig path: gear comes from the components fitted on THIS rod item
    -- (server re-reads the slot — the client only names it). Fallback = v1
    -- best-owned resolution when assembly is off or the pinned mode is simple.
    local rod, stats, rigSlot, rigMeta
    if Config.RequireAssembly and Zfishing.Enhanced() then
        local s, meta = Rig.slotMeta(src, rodSlot)
        if not s then return { ok = false, reason = 'no_rod' } end
        if not Rig.isComplete(meta) then return { ok = false, reason = 'rig_incomplete' } end
        rod, stats, rigSlot, rigMeta = s.name, Rig.stats(meta), rodSlot, meta
    else
        rod = resolveRod(src, level)
        if not rod then return { ok = false, reason = 'no_rod' } end
    end

    local chosenBait = resolveBait(src)
    if not chosenBait then return { ok = false, reason = 'no_bait' } end

    local zone = resolveZone(src)
    if not zone then return { ok = false, reason = 'no_zone' } end

    local fish = Generator.Roll(src, {
        water = zone.water, pool = zone.pool,
        rod = rod, hook = stats and stats.hook or 'hook_4', bait = chosenBait,
    })
    if not fish then return { ok = false, reason = 'empty_water' } end

    -- float speeds up (or slows down) the wait for a bite
    if stats and stats.floatBiteSpeed and stats.floatBiteSpeed > 0 then
        fish.biteDelay = math.max(500, math.floor(fish.biteDelay / stats.floatBiteSpeed))
    end

    -- wear per cast — only now that the cast is definitely happening (after
    -- every validation), so a failed cast never grinds the gear. A component
    -- can break on this very cast; the session still runs on the stats
    -- snapshot taken above.
    if rigMeta and Config.Durability then
        local wear = Rig.degrade(src, rigSlot, rod, rigMeta)
        for _, b in ipairs(wear.broke) do
            TriggerClientEvent('zfishing:rig:notify', src, 'part_broke', b.label)
        end
        if wear.rodBroke then
            Zfishing.RemoveItemSlot(src, rod, 1, rigSlot)
            TriggerClientEvent('zfishing:rig:notify', src, 'rod_broke')
            return { ok = false, reason = 'rod_broke' }
        end
    end

    sessions[src] = {
        state = 'waiting', fish = fish, bait = chosenBait, rod = rod,
        lineRating = stats and stats.lineRating or resolveLineRating(src, level),
        reelDrain = stats and stats.reelDrain or nil,
        rigSlot = rigSlot,
        castAt = GetGameTimer(), zone = zone.name,
    }

    SetTimeout(fish.biteDelay, function()
        local s = sessions[src]
        if not s or s.state ~= 'waiting' or s.fish ~= fish then return end
        -- bait is spent the moment the fish bites, success or not
        Zfishing.RemoveItem(src, s.bait, 1)
        s.state = 'hooking'
        s.hookDeadline = GetGameTimer() + fish.hookWindow + Config.Timings.hookLatency
        local rodCfg = Config.Equipment.rods[s.rod] or {}
        -- snapFactor abstracts line-vs-fish without leaking the exact species/weight:
        -- >1 line outclasses the fish, <1 the fish can snap it fast when over-tensioned
        local snapFactor = ZUtil.clamp(s.lineRating / math.max(1.0, fish.weight), 0.3, 3.0)
        TriggerClientEvent('zfishing:bite', src, {
            behavior = fish.behavior, tensionDiff = fish.tensionDiff,
            fishEnergy = fish.fishEnergy, hookWindow = fish.hookWindow,
            greenZone = rodCfg.greenZone or 0.0,
            snapFactor = snapFactor,
            drainRate = s.reelDrain or 1.0,   -- reel quality = how fast the fish tires
            fishWeight = fish.weight,          -- actual rolled weight for NUI dynamics
        })
        -- if the player never presses hook, don't leave the session stuck
        SetTimeout(fish.hookWindow + Config.Timings.hookLatency + 2000, function()
            local s2 = sessions[src]
            if s2 and s2.state == 'hooking' and s2.fish == fish then reset(src) end
        end)
    end)

    local rodCfg = Config.Equipment.rods[rod] or {}
    local baitCfg = Config.Equipment.baits[chosenBait] or {}
    return { ok = true, rod = rodCfg.label, bait = baitCfg.label }
end)

lib.callback.register('zfishing:hook', function(src)
    local s = sessions[src]
    if not s or s.state ~= 'hooking' then return { ok = false } end
    if GetGameTimer() > s.hookDeadline then
        reset(src)
        return { ok = false, reason = 'too_slow' }
    end
    s.state = 'reeling'
    s.reelStart = GetGameTimer()
    return { ok = true }
end)

lib.callback.register('zfishing:claim', function(src, reelDurationMs, success, reason)
    local s = sessions[src]
    if not s or s.state ~= 'reeling' then return { ok = false } end
    local fish = s.fish

    -- minimum plausible reel time: NUI drains 12 * drainRate energy/sec in the
    -- green zone, so a real catch can never finish faster than this
    local drain = s.reelDrain or 1.7   -- v1 path: assume the fastest reel (lenient)
    local minMs = (fish.fishEnergy / (12 * drain)) * 1000
    local elapsed = GetGameTimer() - s.reelStart
    if success and elapsed < minMs * 0.6 then
        reset(src); return { ok = false, reason = 'too_fast' }
    end
    if elapsed > Config.Timings.reelTimeout + 5000 then
        reset(src); return { ok = false, reason = 'timeout' }
    end

    if not success then
        -- fish escaped / line broke: legit outcome, bait already consumed.
        -- a snapped line destroys the fitted line component for real.
        if reason == 'snap' and s.rigSlot then
            Rig.breakLine(src, s.rigSlot)
            TriggerClientEvent('zfishing:rig:notify', src, 'line_broke')
        end
        reset(src); return { ok = true, fish = nil }
    end

    local given = Rewards.GiveCatch(src, fish, s.zone)
    rate[src].count = rate[src].count + 1
    reset(src)
    if not given then return { ok = false, reason = 'inv_full' } end
    return { ok = true, fish = { label = fish.label, weight = fish.weight, quality = fish.quality, species = fish.species } }
end)

lib.callback.register('zfishing:cancel', function(src)
    reset(src); return { ok = true }
end)

RegisterNetEvent('zfishing:server:anchorBoat', function(netId)
    local src = source
    BoatAnchor.Add(src, netId)
end)

RegisterNetEvent('zfishing:server:unanchorBoat', function(netId)
    local src = source
    BoatAnchor.Remove(src, netId)
end)

AddEventHandler('playerDropped', function()
    local src = source
    reset(src); rate[src] = nil
    BoatAnchor.OnDisconnect(src)
end)
