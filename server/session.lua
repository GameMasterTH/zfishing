-- Per-player fishing session state machine. This file is the anti-cheat core:
-- every fish is rolled server-side at cast time, the client is never told the
-- species until a validated claim, and every transition re-checks state,
-- inventory, and timing plausibility.

local sessions = {}   -- [src] = { state, fish, bait, rod, castAt, hookDeadline, reelStart, zone }
local rate = {}       -- [src] = { count, windowStart }

-- Per-action flood gate. Distinct from Config.RateLimit, which is the catch-rate
-- economy control and only counts SUCCESSFUL catches. This one counts requests.
local gate = ZUtil.MakeRateGate({
    cast   = { max = 3, window = 2000 },
    hook   = { max = 5, window = 2000 },
    claim  = { max = 3, window = 3000 },
    anchor = { max = 5, window = 5000 },
})

local function reset(src) sessions[src] = nil end

-- Settlement reasons that exist for the console, not for a player: they describe
-- what the server refused and, in the identity cases, refer to a player who is no
-- longer the one holding this src. They never reach the wire (see the claim tail).
local INTERNAL_REASONS = {
    player_gone = true, identity_changed = true, no_identity = true,
}

local nextSessionSeq = 0

-- Session tokens are correlation + stale-request protection, not secrets: a
-- modified client can always read its own. The sequence guarantees uniqueness
-- even if math.random repeats; the random half stops a client guessing the
-- token of a session it does not own.
local function newSessionId()
    nextSessionSeq = nextSessionSeq + 1
    return ('%d-%d'):format(nextSessionSeq, math.random(100000, 999999))
end

-- Resolves the caller's session only when the token matches. Every transition
-- goes through this -- never read sessions[src] directly in a callback.
local function sessionFor(src, sessionId)
    local s = sessions[src]
    if not s or type(sessionId) ~= 'string' or s.id ~= sessionId then return nil end
    return s
end

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
    if not gate.allow(src, 'cast') then return { ok = false, reason = 'too_many_requests' } end
    if Zfishing.Blocked() then return { ok = false, reason = 'unavailable' } end
    if sessions[src] then return { ok = false, reason = 'busy' } end
    if not withinRate(src) then return { ok = false, reason = 'rate' } end
    if type(power) ~= 'number' or power < 0 or power > 1 then return { ok = false } end

    -- Load yields on its DB work and refuses when the src changed owner across it,
    -- so its answer has to be read -- a discarded false leaves prog nil and the
    -- next line indexing it.
    if not Progression.Get(src) and not Progression.Load(src) then
        return { ok = false, reason = 'no_identity' }
    end
    local prog = Progression.Get(src)
    -- A session that can end in a reward has to be tied to a stable identity, not
    -- just to the src it was cast from. Settlement survives yields and FiveM
    -- reassigns source ids, so without a captured identifier nothing downstream can
    -- tell whether the player it is about to pay is still the one who cast. Fail
    -- closed here rather than create a reward-bearing session nobody can verify.
    if not prog or type(prog.identifier) ~= 'string' then
        return { ok = false, reason = 'no_identity' }
    end
    local level = prog.level or 1

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
        id = newSessionId(),
        -- `id` and `identifier` solve DIFFERENT problems and neither substitutes
        -- for the other: `id` is per-cast and makes a stale or replayed request
        -- for THIS session detectable; `identifier` is per-player and stable, and
        -- is what tells a settlement that survived a yield whether the src it
        -- holds still belongs to the player the fish was rolled for.
        identifier = prog.identifier,
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
            baseDrain = Config.Minigame.baseDrain,   -- authoritative; the server validates against it
            reelTimeout = Config.Timings.reelTimeout, -- single source of truth for the fight clock
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
    return { ok = true, sessionId = sessions[src].id, rod = rodCfg.label, bait = baitCfg.label }
end)

lib.callback.register('zfishing:hook', function(src, sessionId)
    if not gate.allow(src, 'hook') then return { ok = false, reason = 'too_many_requests' } end
    local s = sessionFor(src, sessionId)
    if not s then return { ok = false, reason = 'invalid_session' } end
    if s.state ~= 'hooking' then return { ok = false } end
    if GetGameTimer() > s.hookDeadline then
        reset(src)
        return { ok = false, reason = 'too_slow' }
    end
    s.state = 'reeling'
    s.reelStart = GetGameTimer()
    return { ok = true }
end)

lib.callback.register('zfishing:claim', function(src, sessionId, reelDurationMs, success, reason)
    if not gate.allow(src, 'claim') then return { ok = false, reason = 'too_many_requests' } end
    local s = sessionFor(src, sessionId)
    if not s then return { ok = false, reason = 'invalid_session' } end
    if s.state ~= 'reeling' then return { ok = false } end
    local fish = s.fish

    -- Minimum plausible reel time. The NUI drains baseDrain * drainRate energy
    -- per second while in the green zone, so a real catch can never finish
    -- faster than this. drainRate defaults to 1.0 to match exactly what the bite
    -- payload told the client -- assuming a faster reel here would hand every
    -- non-assembly player a 1.7x discount on the floor.
    local drain = s.reelDrain or 1.0
    local minMs = (fish.fishEnergy / (Config.Minigame.baseDrain * drain)) * 1000
    local elapsed = GetGameTimer() - s.reelStart
    -- 0.9 rather than a tighter value only to absorb frame quantisation: minMs
    -- assumes a perfect green-zone hold for the whole fight, and network latency
    -- only ever increases the elapsed time the server measures.
    if success and elapsed < minMs * 0.9 then
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

    -- Lock the session BEFORE the first yield. GiveCatch does AddItem +
    -- Progression.Save + MySQL.insert, and across any of those yields a second
    -- claim would otherwise still find state == 'reeling' and be paid again.
    s.state = 'settling'

    -- Backstop pcall. Every secondary effect inside GiveCatch guards itself, so
    -- this only fires for a raise on the pre-commit path (or a broken Rewards
    -- table) -- but it must stay, because cancel no longer frees a settling
    -- session: without it an error would park sessions[src] in 'settling' with
    -- nothing able to clear it and leave the player on `busy` until they reconnect.
    local settled, res = pcall(Rewards.GiveCatch, src, fish, s.zone,
        { sessionId = s.id, identifier = s.identifier })
    local committed = settled and type(res) == 'table' and res.committed == true
    local reason = (settled and type(res) == 'table' and res.reason) or nil

    -- `sessions[src]` and `rate[src]` are keyed by a TRANSIENT src, and GiveCatch
    -- just yielded across every step of the settlement. If the player dropped
    -- during it, playerDropped already cleared both -- and if their src has since
    -- been handed to somebody else, that someone owns these entries now. Touching
    -- them would free a stranger's live session and spend a slot out of their
    -- catch-rate budget. Same object-identity check the bite and hook-timeout
    -- timers use (`s.fish ~= fish`), for the same reason.
    --
    -- For a player who is still here this always holds: cancel deliberately does
    -- not free a settling session, cast is refused while one exists, and both
    -- timers bail out on any state other than the one they scheduled for.
    if sessions[src] == s then
        -- Config.RateLimit counts SUCCESSFUL catches (§3.1), so only a committed
        -- catch spends a slot: a claim that never put a fish in the inventory must
        -- not cost the player one.
        if committed and rate[src] then rate[src].count = rate[src].count + 1 end
        reset(src)
    end

    print(('[zfishing] claim settled session=%s src=%s species=%s committed=%s%s')
        :format(s.id, src, fish.species, tostring(committed), reason and (' reason=' .. reason) or ''))

    -- ONE line per failed settlement stage, and it is logged here rather than in
    -- rewards.lua because this is the only scope that holds the session id and the
    -- captured identity. GiveCatch records structured warnings and prints nothing,
    -- so one failed stage leaves exactly one record for an operator to read.
    if settled and type(res) == 'table' then
        for _, w in ipairs(res.warnings or {}) do
            print(('[zfishing] catch settlement warning session=%s src=%s identity=%s stage=%s detail=%s')
                :format(s.id, src, ZUtil.SafeId(s.identifier), w.stage, w.detail))
        end
    end

    -- The src changed hands while this catch was settling: the fish was rolled for
    -- a player who is no longer on this id, and nothing was granted. Worth seeing.
    -- A plain disconnect (player_gone) is NOT logged -- it is the ordinary case,
    -- and warning on it would train operators to ignore the line.
    if reason == 'identity_changed' then
        print(('[zfishing] identity guard blocked stale settlement session=%s src=%s expected=%s stage=catch_commit')
            :format(s.id, src, ZUtil.SafeId(s.identifier)))
    end

    if not settled then
        print(('[zfishing] settlement errored session=%s src=%s: %s'):format(s.id, src, tostring(res)))
        return { ok = false, reason = 'settle_failed' }
    end
    if not committed then
        -- Identity failures name a server-side condition, and when the src was
        -- reused the client receiving this answer is not even the player the catch
        -- belonged to. They collapse to one generic outcome; client/minigame.lua's
        -- unmapped-reason fallback renders it as error_claim_failed.
        return { ok = false, reason = INTERNAL_REASONS[reason] and 'claim_failed' or (reason or 'inv_full') }
    end
    return { ok = true, fish = { label = fish.label, weight = fish.weight, quality = fish.quality, species = fish.species } }
end)

lib.callback.register('zfishing:cancel', function(src, sessionId)
    local s = sessionFor(src, sessionId)
    if not s then return { ok = false, reason = 'invalid_session' } end
    -- Settlement owns the session from 'settling' until the claim callback clears
    -- it. Answer ok so the client still runs its single teardown path (UI, anim,
    -- bobber, boat) -- but do NOT free sessions[src] here: an early reset would let
    -- the next cast start while the previous reward is still in flight. The cost is
    -- a short window where a cast returns `busy` after a cancel; the reward path
    -- clears the session a moment later. Cancel stays instant in every other state.
    if s.state == 'settling' then return { ok = true } end
    reset(src); return { ok = true }
end)

RegisterNetEvent('zfishing:server:anchorBoat', function(netId)
    local src = source
    if not gate.allow(src, 'anchor') then return end
    BoatAnchor.Add(src, netId)
end)

-- Deliberately ungated, for the same reason cancel is: this is the release path.
-- A throttled unanchor leaves a boat frozen for good -- client/main.lua nils
-- currentBoatNetId unconditionally, so the request is never retried. Flooding it
-- costs one table lookup and broadcasts nothing unless the caller actually holds
-- a reference to that boat.
RegisterNetEvent('zfishing:server:unanchorBoat', function(netId)
    local src = source
    BoatAnchor.Remove(src, netId)
end)

AddEventHandler('playerDropped', function()
    local src = source
    reset(src); rate[src] = nil
    gate.forget(src)
    BoatAnchor.OnDisconnect(src)
end)
