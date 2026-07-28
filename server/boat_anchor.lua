BoatAnchor = {}
local boatAnchors = {} -- [netId] = { count = N, players = { [src] = true } }

function BoatAnchor.Add(src, netId)
    if not netId or netId == 0 then return false end
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
    if not netId or not boatAnchors[netId] then return false end
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
