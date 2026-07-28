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
