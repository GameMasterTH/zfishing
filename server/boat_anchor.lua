BoatAnchor = {}
local boatAnchors = {} -- [netId] = { count = N, players = { [src] = true } }

-- The client probes for a boat within 3.5m (client/main.lua:109) and may then
-- attach the ped to the deck. 15m of server-side allowance covers standing at
-- the bow of the largest boats and any position desync, while still refusing
-- the actual attack: anchoring an arbitrary netId from across the map. Without
-- this, any client can freeze any boat on the server -- the broadcast at the
-- bottom of this file reaches every player.
--
-- Proximity, NOT seat occupancy: GetVehiclePedIsIn returns 0 for a player
-- standing on the deck, which is a supported fishing position, and the anchor
-- request fires before the attach so there is no attachment state to read.
local ANCHOR_RANGE_SQ = 15.0 * 15.0

local function playerNearVehicle(src, netId)
    if not netId or netId == 0 then return false end
    local veh = NetworkGetEntityFromNetworkId(netId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return false end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    local p, v = GetEntityCoords(ped), GetEntityCoords(veh)
    local dx, dy, dz = p.x - v.x, p.y - v.y, p.z - v.z
    return (dx * dx + dy * dy + dz * dz) <= ANCHOR_RANGE_SQ
end

function BoatAnchor.Add(src, netId)
    if not playerNearVehicle(src, netId) then return false end
    boatAnchors[netId] = boatAnchors[netId] or { count = 0, players = {} }
    if not boatAnchors[netId].players[src] then
        boatAnchors[netId].players[src] = true
        boatAnchors[netId].count = boatAnchors[netId].count + 1
        if boatAnchors[netId].count == 1 then
            TriggerClientEvent('zfishing:client:syncBoatAnchor', -1, netId, true)
            return true
        end
    end
    return false
end

function BoatAnchor.Remove(src, netId)
    if not playerNearVehicle(src, netId) then return false end
    if not boatAnchors[netId] then return false end
    if boatAnchors[netId].players[src] then
        boatAnchors[netId].players[src] = nil
        boatAnchors[netId].count = math.max(0, boatAnchors[netId].count - 1)
        if boatAnchors[netId].count <= 0 then
            boatAnchors[netId] = nil
            TriggerClientEvent('zfishing:client:syncBoatAnchor', -1, netId, false)
            return true
        end
    end
    return false
end

function BoatAnchor.OnDisconnect(src)
    for netId, data in pairs(boatAnchors) do
        if data.players[src] then
            data.players[src] = nil
            data.count = math.max(0, data.count - 1)
            if data.count <= 0 then
                boatAnchors[netId] = nil
                TriggerClientEvent('zfishing:client:syncBoatAnchor', -1, netId, false)
            end
        end
    end
end
