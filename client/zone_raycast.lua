ZoneRaycast = {}

function ZoneRaycast.GetAimPoint(maxDist)
    maxDist = maxDist or 1000.0
    local cam = GetGameplayCamCoord()
    local rot = GetGameplayCamRot(2)
    local rx, rz = math.rad(rot.x), math.rad(rot.z)
    local cosrx = math.cos(rx)
    local dir = vec3(-math.sin(rz) * cosrx, math.cos(rz) * cosrx, math.sin(rx))
    local dest = cam + dir * maxDist

    local ray = StartExpensiveSynchronousShapeTestLosProbe(
        cam.x, cam.y, cam.z, dest.x, dest.y, dest.z, 1 + 16, PlayerPedId(), 7)
    local _, worldHit, worldCoords = GetShapeTestResult(ray)

    local waterHit, waterCoords = TestProbeAgainstWater(cam.x, cam.y, cam.z, dest.x, dest.y, dest.z)

    if waterHit and worldHit == 1 then
        if #(waterCoords - cam) <= #(worldCoords - cam) then return waterCoords, true end
        return worldCoords, false
    elseif waterHit then
        return waterCoords, true
    elseif worldHit == 1 then
        return worldCoords, false
    end
    return dest, false
end
