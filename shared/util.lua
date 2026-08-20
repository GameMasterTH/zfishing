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

-- Canonical GTA weather names, shared so the client's report and the server's
-- whitelist can never drift. client/main.lua reports one of these every 60s;
-- server/weather.lua accepts only a name from this list. A server-side list
-- narrower than what the client can send would silently freeze the weather
-- bonus at its fallback instead of failing loudly.
ZUtil.WEATHER_TYPES = {
    'CLEAR','EXTRASUNNY','CLOUDS','OVERCAST','RAIN','CLEARING','THUNDER',
    'SMOG','FOGGY','XMAS','SNOW','SNOWLIGHT','BLIZZARD','HALLOWEEN','NEUTRAL',
}

local weatherSet = {}
for _, w in ipairs(ZUtil.WEATHER_TYPES) do weatherSet[w] = true end

function ZUtil.IsWeather(name) return weatherSet[name] == true end

-- Console-safe form of a player identifier. The identity guards below log WHICH
-- player a blocked operation belonged to, and those lines end up in console dumps
-- and bug reports; the scheme plus the last four characters is enough to
-- correlate two lines with each other or with a DB row, without pasting a full
-- license/steam id somewhere it will be read by strangers.
--
-- Never used for comparison. Every guard compares the FULL identifier -- a
-- redacted form has collisions, and an identity check that can collide is not
-- an identity check.
function ZUtil.SafeId(id)
    if type(id) ~= 'string' or id == '' then return 'none' end
    local scheme, rest = id:match('^(%w+):(.+)$')
    if not scheme then return '...' .. id:sub(-4) end
    if #rest <= 4 then return scheme .. ':' .. rest end
    return scheme .. ':...' .. rest:sub(-4)
end
