FloatKinematics = {}

function FloatKinematics.ArcPoint(a, b, t, hop)
    return vector3(
        a.x + (b.x - a.x) * t,
        a.y + (b.y - a.y) * t,
        a.z + (b.z - a.z) * t + hop * (4.0 * t * (1.0 - t))
    )
end

function FloatKinematics.FightPosition(origin, pp, full, d0, cur, now, dt)
    d0 = d0 or full
    local dist = math.max(4.0, d0 * (0.35 + 0.65 * cur))
    local nx, ny = (origin.x - pp.x) / full, (origin.y - pp.y) / full
    local wob = math.sin(now / 230.0) * 0.35
    local x = pp.x + nx * dist - ny * wob
    local y = pp.y + ny * dist + nx * wob
    return vector3(x, y, 0.0), d0
end
