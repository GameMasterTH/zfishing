ZUtil = {}

function ZUtil.clamp(v, min, max)
    if v < min then return min elseif v > max then return max end
    return v
end

function ZUtil.randFloat(min, max)
    return min + math.random() * (max - min)
end

-- list: array of { weight = n, ... }; returns one element by weight.
function ZUtil.weightedPick(list)
    local total = 0
    for _, e in ipairs(list) do total = total + (e.weight or 1) end
    local r = math.random() * total
    for _, e in ipairs(list) do
        r = r - (e.weight or 1)
        if r <= 0 then return e end
    end
    return list[#list]
end

-- Cheap fixed-window request gate. Runs in front of expensive validation so a
-- flood of forged events costs a table lookup, not an inventory sweep or a fish
-- roll. Windows are deliberately generous: network jitter and a double-tapped
-- key must never trip it for an honest player.
function ZUtil.MakeRateGate(limits)
    local hits = {}
    local gate = {}

    function gate.allow(src, action)
        local lim = limits[action]
        if not lim then return true end
        local now = GetGameTimer()
        local bySrc = hits[src]
        if not bySrc then bySrc = {}; hits[src] = bySrc end
        local h = bySrc[action]
        if not h or (now - h.since) >= lim.window then
            bySrc[action] = { n = 1, since = now }
            return true
        end
        h.n = h.n + 1
        return h.n <= lim.max
    end

    function gate.forget(src) hits[src] = nil end
    return gate
end
