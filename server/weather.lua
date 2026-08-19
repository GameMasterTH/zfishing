-- Weather/time source for spawn bonuses. Prefers a weathersync resource's exports;
-- falls back to low-trust client reports. Bonus-only data — never security-critical,
-- so trusting the client here is acceptable by design.
--
-- "Low trust" is not "no validation": the report is still a client→server event any
-- modified client can spam. It is gated (an honest client sends one per 60s) and the
-- payload is whitelisted against ZUtil.WEATHER_TYPES / an 0..23 hour, so a malformed
-- report is dropped rather than written over the fallback state.

local lastClient = { weather = 'CLEAR', hour = 12 }

local gate = ZUtil.MakeRateGate({
    report = { max = 3, window = 60000 },
})

RegisterNetEvent('zfishing:reportWeather', function(weather, hour)
    local src = source
    if not gate.allow(src, 'report') then return end
    if type(weather) ~= 'string' or type(hour) ~= 'number' then return end
    -- positive form on purpose: `hour < 0 or hour > 23` would let NaN through,
    -- and math.floor(NaN) % 24 is what used to reach lastClient
    if not (hour >= 0 and hour <= 23) then return end
    local name = weather:upper()
    if not ZUtil.IsWeather(name) then return end
    lastClient = { weather = name, hour = math.floor(hour) }
end)

AddEventHandler('playerDropped', function() gate.forget(source) end)

function GetWeatherState()
    if GetResourceState('qb-weathersync') == 'started' then
        local ok, w = pcall(function() return exports['qb-weathersync']:getWeatherState() end)
        local okt, t = pcall(function() return exports['qb-weathersync']:getTime() end)
        if ok and w then
            return { weather = tostring(w):upper(), hour = (okt and type(t) == 'table' and t.hour) or lastClient.hour }
        end
    end
    if GetResourceState('Renewed-Weathersync') == 'started' then
        local ok, w = pcall(function() return exports['Renewed-Weathersync']:getWeather() end)
        if ok and w then return { weather = tostring(w):upper(), hour = lastClient.hour } end
    end
    return lastClient
end
