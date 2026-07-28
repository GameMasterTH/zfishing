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
    if not Zfishing.AddItem(src, 'fish_'..fish.species, 1, meta) then return false end

    Progression.AddXP(src, fish.xp)
    Progression.Save(src)

    local c = Progression.Get(src)
    if c then
        MySQL.insert('INSERT INTO zfishing_catches (identifier, species, weight, quality, zone) VALUES (?, ?, ?, ?, ?)',
            { c.identifier, fish.species, fish.weight, fish.quality, zoneName })
    end

    local loot = Rewards.RollRareLoot(src)
    if loot and Zfishing.AddItem(src, loot, 1, nil) then
        Zfishing.Notify(src, 'You reeled in something extra!', 'success')
    end
    return true
end

-- Sells every fish_* item the player carries. Pricing follows the pinned mode:
--   * enhanced-rig: each slot is priced from its own per-instance metadata
--   * simple-fishing: no per-instance metadata, so fish are priced at the
--     species-average weight / 3-star quality and the player is told explicitly.
-- All inventory access goes through the pinned runtime contract -- no direct
-- vendor inventory export and no GetResourceState auto-detect.
lib.callback.register('zfishing:sellAll', function(src)
    if Zfishing.Blocked() then
        Zfishing.Notify(src, 'Fishing is unavailable right now', 'error')
        return { ok = false, total = 0 }
    end

    local total = 0
    if Zfishing.Enhanced() then
        for species in pairs(Config.Fish) do
            local item = 'fish_'..species
            for _, slot in ipairs(Zfishing.Search(src, { item })) do
                local price = Rewards.Price(species, slot.metadata) * (slot.count or 1)
                if price > 0 and Zfishing.RemoveItemSlot(src, item, slot.count or 1, slot.slot) then
                    total = total + price
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
                end
            end
        end
    end

    if total > 0 then
        Zfishing.AddMoney(src, total, 'fish-sale')
        if Zfishing.Simple() then
            Zfishing.Notify(src, 'Sold at standard weight -- this inventory has no per-catch weight', 'inform')
        end
    end
    return { ok = total > 0, total = total }
end)
