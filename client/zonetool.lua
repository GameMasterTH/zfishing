local A = Config.Admin

local function drawDisc(pos, radius, col)
    DrawMarker(1, pos.x, pos.y, pos.z - (A.markerHeight / 2.0), 0, 0, 0, 0, 0, 0,
        radius * 2.0, radius * 2.0, A.markerHeight, col.r, col.g, col.b, col.a,
        false, false, 2, false, nil, nil, false)
end

local function drawExistingZones()
    for _, z in ipairs(Config.Zones) do
        drawDisc(z.coords, z.radius, { r = 255, g = 180, b = 0, a = 70 })
    end
end

RegisterNetEvent('zfishing:zonetool:start', function()
    local radius = 50.0
    local waterIdx = 1
    local placing = true

    lib.notify({ description = 'Zone tool: aim + click to place • scroll = radius • G = water type • BACKSPACE = cancel', type = 'inform' })

    while placing do
        local pos = ZoneRaycast.GetAimPoint()
        local water = A.waterTypes[waterIdx]
        drawExistingZones()
        drawDisc(pos, radius, A.markerColor)

        if IsControlPressed(0, 241) then radius = math.min(A.radiusMax, radius + A.radiusStep) end -- wheel up
        if IsControlPressed(0, 242) then radius = math.max(A.radiusMin, radius - A.radiusStep) end -- wheel down
        if IsControlJustPressed(0, 47) then waterIdx = waterIdx % #A.waterTypes + 1 end            -- G: cycle water

        SetTextScale(0.4, 0.4); SetTextFont(4); SetTextColour(255, 255, 255, 220)
        SetTextOutline(); BeginTextCommandDisplayText('STRING')
        AddTextComponentSubstringPlayerName(('Water: %s   Radius: %.0fm'):format(water, radius))
        EndTextCommandDisplayText(0.5, 0.85)

        if IsControlJustPressed(0, 24) or IsControlJustPressed(0, 191) then -- LMB / Enter → confirm
            placing = false
            local input = lib.inputDialog('New Fishing Zone', {
                { type = 'input', label = 'Zone name', required = true, default = ('Zone %d'):format(math.random(100, 999)) },
            })
            if input then
                local res = lib.callback.await('zfishing:admin:saveZone', false, {
                    name = input[1], water = water, x = pos.x, y = pos.y, z = pos.z, radius = radius,
                })
                if res and res.ok then lib.notify({ description = 'Zone saved (#' .. res.id .. ')', type = 'success' })
                else lib.notify({ description = 'Save failed: ' .. (res and res.err or '?'), type = 'error' }) end
            end
        elseif IsControlJustPressed(0, 177) then -- BACKSPACE → cancel
            placing = false
            lib.notify({ description = 'Zone tool cancelled', type = 'inform' })
        end

        Wait(0)
    end
end)
