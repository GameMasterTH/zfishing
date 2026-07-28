RegisterNetEvent('zfishing:store:sync', function(payload)
    local zones = {}
    for _, z in ipairs(payload.zones or {}) do
        zones[#zones + 1] = { name = z.name, water = z.water,
            coords = vec3(z.x, z.y, z.z), radius = z.radius, pool = z.pool }
    end
    Config.Zones = zones
    Config.CastMaxDistance = payload.castMaxDistance
    Config.DefaultWater = payload.defaultWater
    Config.RequireZone = payload.requireZone
end)

CreateThread(function()
    Wait(1000)
    TriggerServerEvent('zfishing:store:request')
end)
