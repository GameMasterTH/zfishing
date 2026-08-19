BoatAnchor = {}
local boatAnchors = {} -- [netId] = { count = N, players = { [src] = true } }

-- 15m, and it STAYS 15m. The obvious tightening -- "the client only probes 3.5m,
-- so 5-8m is plenty" -- reads only one of getFishingBoat()'s three branches
-- (client/main.lua:103-114). The second branch is GetVehiclePedIsIn(ped, true),
-- the LAST vehicle, which matches at any distance: a player who was seated in a
-- Tug or a Marquis, stood up and walked to the stern is 8-10m from the vehicle
-- ORIGIN and server-side GetVehiclePedIsIn(ped, false) returns 0 for them, so no
-- seat check rescues that case either. This resource carries no boat-dimension
-- data to pick a tighter number from, and the client attaches the ped to the deck
-- whether or not the server accepts the anchor -- a refusal strands a ped attached
-- to a boat nobody froze. 15m still refuses the actual attack (an arbitrary netId
-- from across the map); the checks that got tightened are the ones below it.
--
-- Proximity, NOT seat occupancy: GetVehiclePedIsIn returns 0 for a player
-- standing on the deck, which is a supported fishing position, and the anchor
-- request fires before the attach so there is no attachment state to read.
local ANCHOR_RANGE_SQ = 15.0 * 15.0

-- netId arrives straight off a net event, so it is whatever the client sent. A
-- table reaches NetworkGetEntityFromNetworkId and raises, so both entry points
-- fail closed on a non-number first (house pattern: server/weather.lua:8).
local function validNetId(netId)
    return type(netId) == 'number' and netId ~= 0
end

-- Resolves the netId to an entity that is actually a boat. GetEntityType == 2
-- (vehicle) and GetVehicleType == 'boat' are both server natives on the shipped
-- artifact (citizen/scripting/lua/natives_server.lua). This is hygiene rather
-- than the security boundary -- SetBoatAnchor on a car is inert client-side --
-- but it keeps a ped netId, an object netId or a car out of the refcount table
-- and out of the broadcast entirely.
local function resolveBoat(netId)
    if not validNetId(netId) then return nil end
    local veh = NetworkGetEntityFromNetworkId(netId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return nil end
    if GetEntityType(veh) ~= 2 then return nil end
    if GetVehicleType(veh) ~= 'boat' then return nil end
    return veh
end

local function playerNearVehicle(src, veh)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    local p, v = GetEntityCoords(ped), GetEntityCoords(veh)
    local dx, dy, dz = p.x - v.x, p.y - v.y, p.z - v.z
    return (dx * dx + dy * dy + dz * dz) <= ANCHOR_RANGE_SQ
end

-- One anchor per player, matching the client exactly: client/main.lua tracks a
-- single currentBoatNetId, so an honest player never holds two. Without this a
-- caller inside a marina could hold every boat within 15m frozen at once; with
-- it, the reach of a modified client is capped at one boat at a time -- the same
-- reach it already has with its own.
local function holdsOtherAnchor(src, netId)
    for held, data in pairs(boatAnchors) do
        if held ~= netId and data.players[src] then return true end
    end
    return false
end

function BoatAnchor.Add(src, netId)
    local veh = resolveBoat(netId)
    if not veh then return false end
    if not playerNearVehicle(src, veh) then return false end
    if holdsOtherAnchor(src, netId) then return false end
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

-- Deliberately NOT proximity-checked, unlike Add. The client has no death
-- handling, so ZClient.active and currentBoatNetId survive a death: a player who
-- dies while fishing, respawns at a hospital and bails out with X sends this from
-- a kilometre away, and client/main.lua:140-143 nils currentBoatNetId
-- unconditionally, so a refusal could never be retried -- the boat would stay
-- frozen until that player disconnected, and the stale reference would also block
-- a co-angler's legitimate release. Refusing here prevents nothing: players[src]
-- membership is a capability obtainable only by passing playerNearVehicle inside
-- Add, so a remote caller can at most release the one reference they legitimately
-- acquired, and Add still requires proximity so there is no re-anchor loop.
function BoatAnchor.Remove(src, netId)
    if not validNetId(netId) then return false end
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
