Rewards = {}

-- price = base(price/kg) × weight × quality multiplier
local qualityMult = { [1]=0.7, [2]=0.9, [3]=1.0, [4]=1.3, [5]=1.8 }

function Rewards.Price(species, metadata)
    local fish = Config.Fish[species]
    if not fish then return 0 end
    metadata = metadata or {}
    return math.floor(fish.price * (tonumber(metadata.weight) or 1) * (qualityMult[metadata.quality] or 1.0))
end

function Rewards.RollRareLoot(src)
    for _, loot in ipairs(Config.RareLoot) do
        if math.random() < loot.chance then return loot.item end
    end
    return nil
end

-- Runs one secondary effect of an already-committed catch. A stage that fails --
-- raised, or reported false -- is recorded as a warning and logged with its cause;
-- it never propagates, because by the time these run the fish is already in the
-- player's inventory. Every stage must return an explicit boolean: `not err`
-- rather than `err == false` so a stage that forgets to return cannot pass silently.
local function runStage(src, warnings, stage, fn)
    local ok, err = pcall(fn)
    if not ok or not err then
        warnings[#warnings + 1] = stage
        print(('[zfishing] catch settlement warning src=%s stage=%s: %s')
            :format(tostring(src), stage, ok and 'stage reported failure' or tostring(err)))
    end
end

-- The catch commit boundary.
--
-- The fish item entering the inventory is the commit point. Everything after it --
-- XP, XP persistence, the catch log, rare loot -- is a secondary effect, and a
-- secondary failure must NEVER turn the catch back into a failure: the fish is in
-- the player's bag, so telling them they caught nothing would make the server state
-- and what they see disagree. Secondary failures surface as console warnings for an
-- operator, not as a client-visible outcome.
--
-- Returns a structured result rather than a boolean:
--   { ok = true,  committed = true,  warnings = { <stage>, ... } }
--   { ok = false, committed = false, reason = 'inv_full' }
function Rewards.GiveCatch(src, fish, zoneName)
    -- enhanced mode carries per-catch weight/quality in item metadata; simple mode
    -- has no per-instance metadata, so the catch is a plain stack. The mode is the
    -- one the resolver pinned -- we never send metadata that would be dropped.
    local meta
    if Zfishing.Enhanced() then
        meta = {
            weight = fish.weight, quality = fish.quality, label = fish.label,
            description = ('%s | %.2fkg | %d star'):format(fish.label, fish.weight, fish.quality),
        }
    end
    if not Zfishing.AddItem(src, 'fish_'..fish.species, 1, meta) then
        return { ok = false, committed = false, reason = 'inv_full' }
    end

    -- ---------------- COMMITTED from here down ----------------
    local warnings = {}

    runStage(src, warnings, 'xp_save_failed', function()
        -- the player dropped mid-settle: the progression cache is already gone, so
        -- there is nothing to persist and nothing worth warning an operator about
        if not Progression.Get(src) then return true end
        Progression.AddXP(src, fish.xp)
        return Progression.SaveAwait(src)
    end)

    runStage(src, warnings, 'catch_log_failed', function()
        local c = Progression.Get(src)
        if not c then return true end          -- dropped mid-settle: no identifier to log against
        return MySQL.insert.await(
            'INSERT INTO zfishing_catches (identifier, species, weight, quality, zone) VALUES (?, ?, ?, ?, ?)',
            { c.identifier, fish.species, fish.weight, fish.quality, zoneName }) ~= nil
    end)

    runStage(src, warnings, 'rare_loot_failed', function()
        local loot = Rewards.RollRareLoot(src)
        if not loot then return true end       -- nothing rolled is the common case
        if not Zfishing.AddItem(src, loot, 1, nil) then return false end
        Zfishing.Notify(src, 'You reeled in something extra!', 'success')
        return true
    end)

    return { ok = true, committed = true, warnings = warnings }
end

-- One sale at a time, per player. Every step below crosses the zcore_lib resource
-- boundary and can yield, so two sellAll requests arriving together would each
-- price the same fish and each reach AddMoney. The lock is taken before the first
-- inventory read and released on every exit: success, nothing to sell, a failed
-- payout, a raised error (the pcall in the callback) and a mid-sale disconnect
-- (the playerDropped handler at the bottom of this file).
local selling = {}

-- Selling is not on any hot path -- the NPC is a manual interaction -- so the
-- window only has to be loose enough that a double-click is never punished.
local gate = ZUtil.MakeRateGate({
    sell = { max = 2, window = 3000 },
})

-- Removes every fish the player carries and reports what ACTUALLY left the
-- inventory. Price is accumulated only inside the `remove succeeded` branch, so
-- the payout can never include a fish that is still in the player's bag.
-- Pricing follows the pinned mode:
--   * enhanced-rig: each slot is priced from its own per-instance metadata
--   * simple-fishing: no per-instance metadata, so fish are priced at the
--     species-average weight / 3-star quality and the player is told explicitly.
-- All inventory access goes through the pinned runtime contract -- no direct
-- vendor inventory export and no GetResourceState auto-detect.
local function collectSale(src)
    local total, removed = 0, {}
    if Zfishing.Enhanced() then
        for species in pairs(Config.Fish) do
            local item = 'fish_'..species
            for _, slot in ipairs(Zfishing.Search(src, { item })) do
                local count = slot.count or 1
                local price = Rewards.Price(species, slot.metadata) * count
                if price > 0 and Zfishing.RemoveItemSlot(src, item, count, slot.slot) then
                    total = total + price
                    removed[#removed + 1] = { item = item, count = count, metadata = slot.metadata }
                end
            end
        end
    else
        for species, cfg in pairs(Config.Fish) do
            local item = 'fish_'..species
            local count = Zfishing.ItemCount(src, item)
            if count > 0 then
                local avgWeight = (cfg.weight.min + cfg.weight.max) / 2
                local price = Rewards.Price(species, { weight = avgWeight, quality = 3 }) * count
                if Zfishing.RemoveItem(src, item, count) then
                    total = total + price
                    removed[#removed + 1] = { item = item, count = count }
                end
            end
        end
    end
    return total, removed
end

-- Correlation id for one sale attempt. Server-side only -- it is never sent to the
-- client. It exists so the payout line, the compensation line and every CRITICAL
-- line for the same sale can be tied together in a console an admin is reading
-- after the fact, on a server where several players sell at once.
local nextSaleSeq = 0
local function newSaleId(src)
    nextSaleSeq = nextSaleSeq + 1
    return ('%s-%s-%s'):format(tostring(src), GetGameTimer(), nextSaleSeq)
end

local function metaSummary(meta)
    if type(meta) ~= 'table' then return 'none' end
    return ('%skg/%s star'):format(tostring(tonumber(meta.weight) or '?'), tostring(meta.quality or '?'))
end

-- The fish are already out of the inventory when the payout is attempted, so a
-- failed AddMoney must hand them back -- the resource never destroys an item
-- silently (same rule as rig attach/detach). Reports what it managed rather than
-- printing and forgetting, so the caller can log one reconciliation record per
-- sale instead of scattered lines with no correlation.
local function restoreSale(src, removed)
    local restored, failed = 0, {}
    for _, r in ipairs(removed) do
        if Zfishing.AddItem(src, r.item, r.count, r.metadata) then
            restored = restored + 1
        else
            failed[#failed + 1] = r
        end
    end
    return { restored = restored, failed = failed }
end

local function runSale(src, saleId)
    local total, removed = collectSale(src)
    if total <= 0 then return { ok = false, total = 0 } end

    if not Zfishing.AddMoney(src, total, 'fish-sale') then
        local comp = restoreSale(src, removed)
        print(('[zfishing] sale payout failed saleId=%s src=%s expectedPayout=%d removed=%d restored=%d restoreFailed=%d')
            :format(saleId, tostring(src), total, #removed, comp.restored, #comp.failed))
        -- the only path where a player is actually down fish with nothing to show
        -- for it; everything an admin needs to make them whole goes on one line
        for _, r in ipairs(comp.failed) do
            print(('[zfishing] CRITICAL sale reconciliation saleId=%s src=%s lost item=%s count=%s meta=%s expectedPayout=%d')
                :format(saleId, tostring(src), r.item, tostring(r.count), metaSummary(r.metadata), total))
        end
        return { ok = false, total = 0, reason = 'payout_failed' }
    end

    if Zfishing.Simple() then
        Zfishing.Notify(src, 'Sold at standard weight -- this inventory has no per-catch weight', 'inform')
    end
    return { ok = true, total = total }
end

lib.callback.register('zfishing:sellAll', function(src)
    if not gate.allow(src, 'sell') then return { ok = false, total = 0, reason = 'too_many_requests' } end
    if Zfishing.Blocked() then
        Zfishing.Notify(src, 'Fishing is unavailable right now', 'error')
        return { ok = false, total = 0 }
    end
    if selling[src] then return { ok = false, total = 0, reason = 'sale_busy' } end

    selling[src] = true
    local saleId = newSaleId(src)
    local ok, res = pcall(runSale, src, saleId)
    selling[src] = nil

    if not ok then
        print(('[zfishing] sellAll errored saleId=%s src=%s: %s'):format(saleId, tostring(src), tostring(res)))
        return { ok = false, total = 0, reason = 'sale_failed' }
    end
    return res
end)

-- A player who drops mid-sale never returns through the pcall above, so the lock
-- is cleared here too; without this the src would refuse every sale after a
-- reconnect onto the same server id.
AddEventHandler('playerDropped', function()
    local src = source
    selling[src] = nil
    gate.forget(src)
end)
