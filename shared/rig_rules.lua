RigRules = {}

RigRules.PART_TYPES = { 'reel', 'line', 'hook', 'float' }

function RigRules.IsComplete(meta)
    if not meta or not meta.parts or not meta.dur then return false end
    if (meta.dur.rod or 0) <= 0 then return false end
    for _, t in ipairs(RigRules.PART_TYPES) do
        if not meta.parts[t] or (meta.dur[t] or 0) <= 0 then return false end
    end
    return true
end

function RigRules.Missing(meta)
    local out = {}
    if not meta or not meta.parts then
        return { 'reel', 'line', 'hook', 'float' }
    end
    for _, t in ipairs(RigRules.PART_TYPES) do
        if not meta.parts[t] then out[#out + 1] = t end
    end
    return out
end

function RigRules.ExtractStats(meta)
    local p = (meta and meta.parts) or {}
    local reel  = Config.Equipment.reels[p.reel] or {}
    local line  = Config.Equipment.lines[p.line] or {}
    local hook  = p.hook
    local float = Config.Equipment.floats[p.float] or {}
    return {
        reelDrain      = reel.drainRate or 1.0,
        lineRating     = line.rating or 10,
        hook           = hook,
        floatBiteSpeed = float.biteSpeed or 1.0,
    }
end
