-- Rod assembly ("rig") — components (reel/line/hook/float) live INSIDE the rod
-- item's per-instance metadata, so a fully-built rod trades as one item. All
-- inventory access goes through zcore_lib's pinned runtime contract. Assembly is
-- an enhanced-rig capability: the resolver decides the mode ahead of time, so in
-- simple-fishing mode assembly is explicitly disabled (not silently degraded) and
-- the session uses v1 best-owned-gear resolution.
--
-- metadata shape on a rod item:
--   parts = { reel=?, line=?, hook=?, float=? }   -- item names, nil = empty socket
--   dur   = { rod=n, reel=n, line=n, hook=n, float=n }  -- points left
--   description = human tooltip (rebuilt on every write)

Rig = {}

local PART_TYPES = { 'reel', 'line', 'hook', 'float' }
-- part type -> Config.Equipment slot key
local SLOT_OF = { reel = 'reels', line = 'lines', hook = 'hooks', float = 'floats' }

local gate = ZUtil.MakeRateGate({
    get    = { max = 10, window = 5000 },
    attach = { max = 10, window = 5000 },
    detach = { max = 10, window = 5000 },
})

local function partCfg(partType, item)
    return Config.Equipment[SLOT_OF[partType]] and Config.Equipment[SLOT_OF[partType]][item]
end

function Rig.maxDur(partType, item)
    local cfg = partType == 'rod' and Config.Equipment.rods[item] or partCfg(partType, item)
    return cfg and (cfg.durability or 20) or 20
end

local function degradeOf(partType, item)
    local cfg = partType == 'rod' and Config.Equipment.rods[item] or partCfg(partType, item)
    return cfg and (cfg.degrade or 1) or 1
end

local function labelOf(partType, item)
    local cfg = partType == 'rod' and Config.Equipment.rods[item] or partCfg(partType, item)
    return cfg and cfg.label or item
end

-- tooltip shown on the rod item; rebuilt on every metadata write
function Rig.describe(rodName, meta)
    local segs = {}
    for _, t in ipairs(PART_TYPES) do
        local item = meta.parts[t]
        segs[#segs + 1] = item
            and ('%s %d/%d'):format(labelOf(t, item), meta.dur[t] or 0, Rig.maxDur(t, item))
            or (t .. ': -')
    end
    return ('Rod %d/%d | %s'):format(meta.dur.rod or 0, Rig.maxDur('rod', rodName), table.concat(segs, ' | '))
end

function Rig.missing(meta)
    return RigRules.Missing(meta)
end

function Rig.isComplete(meta)
    return RigRules.IsComplete(meta)
end

-- gear numbers the session feeds into the roll / minigame
function Rig.stats(meta)
    return RigRules.ExtractStats(meta)
end

-- Normalizes (or initializes) rig metadata on a rod slot. Returns slotInfo, meta.
-- nil when the slot doesn't hold a rod owned by src — never trust client slots.
function Rig.slotMeta(src, slot)
    if not Zfishing.Enhanced() or type(slot) ~= 'number' then return nil end
    local s = Zfishing.GetSlot(src, slot)
    if not s or not Config.Equipment.rods[s.name] then return nil end
    local meta = s.metadata or {}
    meta.parts = meta.parts or {}
    meta.dur = meta.dur or {}
    if meta.dur.rod == nil then meta.dur.rod = Rig.maxDur('rod', s.name) end
    return s, meta
end

local function writeMeta(src, slot, rodName, meta)
    meta.description = Rig.describe(rodName, meta)
    return Zfishing.SetSlotMeta(src, slot, meta)
end

-- Wears every fitted part + the rod itself by its configured degrade rate.
-- Returns { broke = {partType...}, rodBroke = bool }. Caller handles rod removal.
function Rig.degrade(src, slot, rodName, meta)
    local broke = {}
    for _, t in ipairs(PART_TYPES) do
        local item = meta.parts[t]
        if item then
            meta.dur[t] = (meta.dur[t] or Rig.maxDur(t, item)) - degradeOf(t, item)
            if meta.dur[t] <= 0 then
                meta.parts[t], meta.dur[t] = nil, nil
                broke[#broke + 1] = { part = t, label = labelOf(t, item) }
            end
        end
    end
    meta.dur.rod = (meta.dur.rod or Rig.maxDur('rod', rodName)) - degradeOf('rod', rodName)
    if meta.dur.rod <= 0 then
        if Config.RodCanBreak then
            return { broke = broke, rodBroke = true }
        end
        meta.dur.rod = 1 -- rod breaking disabled: pin at 1, parts still wear out
    end
    writeMeta(src, slot, rodName, meta)
    return { broke = broke, rodBroke = false }
end

-- Line snapped during the reel minigame — the line component is destroyed.
function Rig.breakLine(src, slot)
    local s, meta = Rig.slotMeta(src, slot)
    if not s or not meta.parts.line then return end
    meta.parts.line, meta.dur.line = nil, nil
    writeMeta(src, slot, s.name, meta)
end

-- ---------------------------------------------------------------- callbacks

local function partItemNames(partType)
    local names = {}
    for name in pairs(Config.Equipment[SLOT_OF[partType]] or {}) do names[#names + 1] = name end
    return names
end

function Rig.getMetaDur(metadata, partType, itemName)
    local max = Rig.maxDur(partType, itemName)
    if not metadata then return max end
    if type(metadata.durability) == 'string' then
        local pct = tonumber(metadata.durability:match('(%d+)'))
        if pct then
            return math.max(1, math.floor((pct / 100) * max + 0.5))
        end
    elseif type(metadata.durability) == 'number' then
        return math.max(1, math.floor((metadata.durability / 100) * max + 0.5))
    end
    if type(metadata.dur) == 'number' then
        return metadata.dur
    end
    return max
end

local function makePartMeta(partType, itemName, remainingDur)
    local max = Rig.maxDur(partType, itemName)
    if not remainingDur or remainingDur >= max then return nil end
    local pct = math.max(1, math.min(100, math.floor((remainingDur / max) * 100 + 0.5)))
    return { durability = ('%d%%'):format(pct) }
end

lib.callback.register('zfishing:rig:get', function(src, slot)
    if not gate.allow(src, 'get') then return { ok = false, err = 'too_many_requests' } end
    local s, meta = Rig.slotMeta(src, slot)
    if not s then return nil end
    -- carried spare parts, grouped by part type, so the client can offer them
    local carried = {}
    for _, t in ipairs(PART_TYPES) do
        carried[t] = {}
        for _, found in ipairs(Zfishing.Search(src, partItemNames(t))) do
            local count = found.count or 1
            for c = 1, count do
                carried[t][#carried[t] + 1] = {
                    slot = found.slot, name = found.name, label = labelOf(t, found.name),
                    dur = Rig.getMetaDur(found.metadata, t, found.name),
                    max = Rig.maxDur(t, found.name),
                }
            end
        end
    end
    local view = { rod = s.name, rodLabel = labelOf('rod', s.name), parts = {}, missing = Rig.missing(meta), carried = carried }
    for _, t in ipairs(PART_TYPES) do
        local item = meta.parts[t]
        if item then
            view.parts[t] = { name = item, label = labelOf(t, item), dur = meta.dur[t] or 0, max = Rig.maxDur(t, item) }
        end
    end
    view.rodDur, view.rodMax = meta.dur.rod or 0, Rig.maxDur('rod', s.name)
    return view
end)

lib.callback.register('zfishing:rig:attach', function(src, slot, partType, itemName, partSlot)
    if not gate.allow(src, 'attach') then return { ok = false, err = 'too_many_requests' } end
    if not SLOT_OF[partType] then return { ok = false, err = 'bad_part' } end
    local s, meta = Rig.slotMeta(src, slot)
    if not s then return { ok = false, err = 'no_rod' } end
    if not partCfg(partType, itemName) then return { ok = false, err = 'bad_item' } end

    -- find the specific carried instance the player selected (by inventory slot)
    local found
    local results = Zfishing.Search(src, { itemName })
    if partSlot then
        for _, r in ipairs(results) do
            if r.slot == partSlot then
                found = r
                break
            end
        end
    end
    -- fallback: if partSlot didn't match (e.g. stale data), use first result
    if not found then found = results[1] end
    if not found then return { ok = false, err = 'not_carried' } end

    -- If slot is currently occupied, detach existing item back into player inventory first
    local prevItem = meta.parts[partType]
    local prevDur = meta.dur[partType]
    if prevItem then
        local giveMeta = makePartMeta(partType, prevItem, prevDur)
        if not Zfishing.AddItem(src, prevItem, 1, giveMeta) then
            return { ok = false, err = 'inv_full' }
        end
        meta.parts[partType], meta.dur[partType] = nil, nil
    end

    local dur = Rig.getMetaDur(found.metadata, partType, itemName)

    if not Zfishing.RemoveItemSlot(src, itemName, 1, found.slot) then
        return { ok = false, err = 'remove_failed' }
    end
    meta.parts[partType], meta.dur[partType] = itemName, dur
    if not writeMeta(src, slot, s.name, meta) then
        -- metadata write failed: give the part back, never eat it
        Zfishing.AddItem(src, itemName, 1, found.metadata)
        return { ok = false, err = 'meta_failed' }
    end
    return { ok = true }
end)

lib.callback.register('zfishing:rig:detach', function(src, slot, partType)
    if not gate.allow(src, 'detach') then return { ok = false, err = 'too_many_requests' } end
    if not SLOT_OF[partType] then return { ok = false, err = 'bad_part' } end
    local s, meta = Rig.slotMeta(src, slot)
    if not s then return { ok = false, err = 'no_rod' } end
    local item = meta.parts[partType]
    if not item then return { ok = false, err = 'empty' } end

    -- add back FIRST — if the inventory is full we abort and the part stays fitted
    local giveMeta = makePartMeta(partType, item, meta.dur[partType])
    if not Zfishing.AddItem(src, item, 1, giveMeta) then
        return { ok = false, err = 'inv_full' }
    end
    meta.parts[partType], meta.dur[partType] = nil, nil
    writeMeta(src, slot, s.name, meta)
    return { ok = true }
end)
