-- Weather/time source for spawn bonuses. Prefers a weathersync resource's exports;
-- falls back to low-trust client reports. Bonus-only data — never security-critical,
-- so trusting the client here is acceptable by design.

local lastClient = { weather = 'CLEAR', hour = 12 }

RegisterNetEvent('zfishing:reportWeather', function(weather, hour)
    if type(weather) == 'string' and type(hour) == 'number' then
        lastClient = { weather = weather:upper(), hour = math.floor(hour) % 24 }
    end
end)

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
