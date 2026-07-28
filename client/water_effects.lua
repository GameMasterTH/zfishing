WaterEffects = {}

function WaterEffects.DrawRipples(pos, bz, isFight)
    local now = GetGameTimer()
    local cycle = isFight and 700 or 1800
    local maxRadius = isFight and 1.3 or 1.1
    local progress = (now % cycle) / cycle
    local renderZ = math.max(pos.z, bz) + 0.03

    local oR, oG, oB, oA = isFight and 255 or 220, isFight and 140 or 245, isFight and 30 or 255, isFight and 220 or 180
    DrawMarker(23, pos.x, pos.y, renderZ,
        0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
        maxRadius, maxRadius, maxRadius,
        oR, oG, oB, oA,
        false, false, 2, false, nil, nil, false)

    local iRadius = 0.2 + (maxRadius - 0.2) * progress
    local baseAlpha = isFight and 150 or 110
    local iAlpha = math.floor(baseAlpha * (1.0 - progress))
    local iR, iG, iB = isFight and 239 or 69, isFight and 68 or 184, isFight and 68 or 164

    if iAlpha > 5 then
        DrawMarker(23, pos.x, pos.y, renderZ,
            0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
            iRadius, iRadius, iRadius,
            iR, iG, iB, iAlpha,
            false, false, 2, false, nil, nil, false)
    end
end
