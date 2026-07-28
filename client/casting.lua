Casting = {}
local floatObj

-- rod-tip anchor: right-hand bone + a nudge toward the rod tip. ped is frozen
-- while fishing so this stays stable — tune these two if the line looks off.
local TIP_FWD, TIP_UP = 0.6, 0.6
local RH_BONE = 18905
local DIVE_DEPTH = 0.4   -- metres the bobber sinks below the surface once hooked

-- fallback only: Anim.RodTip() (derived from the real rod prop) is preferred;
-- this hand-bone guess is used when the prop doesn't exist.
local function rodTip()
    local ped = PlayerPedId()
    local hand = GetPedBoneCoords(ped, RH_BONE, 0.0, 0.0, 0.0)
    local fwd = GetEntityForwardVector(ped)
    return vector3(hand.x + fwd.x * TIP_FWD, hand.y + fwd.y * TIP_FWD, hand.z + TIP_UP)
end

-- fake catenary: subdivide the line and sag the middle down by gravity. sag
-- scales with horizontal span, capped so short lines stay near-taut.
local LINE_SEGMENTS = 12
local function drawFishingLine(a, b)
    local dx, dy = b.x - a.x, b.y - a.y
    local sag = math.min(math.sqrt(dx * dx + dy * dy) * 0.08, 1.5)
    local px, py, pz = a.x, a.y, a.z
    for i = 1, LINE_SEGMENTS do
        local t = i / LINE_SEGMENTS
        local x = a.x + dx * t
        local y = a.y + dy * t
        local z = a.z + (b.z - a.z) * t - sag * (4.0 * t * (1.0 - t))
        DrawLine(px, py, pz, x, y, z, 235, 235, 235, 200)
        px, py, pz = x, y, z
    end
end

-- parabolic hop: bobber flies rod-tip -> landing in an arc over FLIGHT_MS.
local FLIGHT_MS = 600

-- Shows the cast bar in NUI; returns power 0..1 when E is released, or nil if
-- the player never started the cast (cancelled / timed out).
function Casting.Charge()
    if not ZClient.active then return nil end
    SendNUIMessage({ action = 'cast', state = 'start' })
    -- Fishing starts by USING the rod (a click), so E is not held yet — wait
    -- for the player to start the cast. Bail out on X (ZClient.active drops)
    -- or timeout instead of silently casting at power 0.
    local deadline = GetGameTimer() + 8000
    while not IsControlPressed(0, 38) do
        if not ZClient.active or GetGameTimer() > deadline then
            SendNUIMessage({ action = 'hide' })
            return nil
        end
        Wait(0)
    end
    Anim.Charge()   -- wind-up throw, scrubbed to the charge power below
    local power = 0.0
    local rising = true
    while IsControlPressed(0, 38) do   -- E held
        if not ZClient.active then
            SendNUIMessage({ action = 'hide' })
            return nil
        end
        power = power + (rising and 0.02 or -0.02)
        if power >= 1.0 then power = 1.0; rising = false end
        if power <= 0.0 then power = 0.0; rising = true end
        Anim.ChargePhase(power)
        SendNUIMessage({ action = 'cast', state = 'charge', power = power })
        Wait(16)
    end
    if not ZClient.active then
        SendNUIMessage({ action = 'hide' })
        return nil
    end
    SendNUIMessage({ action = 'cast', state = 'release', power = power })
    return power
end

-- ---- fight mode: bobber tracks fish energy (streamed from the NUI minigame).
-- distance from player = energy fraction * distance at hook time, so a tiring
-- fish drifts in and a recovering one pulls back out.
function Casting.StartFight()
    if not Casting.anchor then return end
    Casting.diving = false
    Casting.fight = {
        origin = Casting.anchor,   -- where the fight started (max distance point)
        d0 = nil,                  -- captured on first frame from live player pos
        energy = 1.0,              -- target (NUI stream)
        cur = 1.0,                 -- smoothed display value
    }
end

function Casting.SetFightEnergy(pct)
    if Casting.fight and type(pct) == 'number' then
        Casting.fight.energy = math.max(0.0, math.min(1.0, pct))
    end
end

-- ---- drift mode: after the catch, the bobber floats free on the surface,
-- meandering slowly like it's carried by the current, until teardown.
function Casting.StartDrift()
    Casting.fight = nil
    Casting.diving = false
    if not Casting.anchor then return end
    Casting.drift = { heading = math.random() * 6.283, speed = 0.15 }
end

function Casting.SpawnFloat(power)
    local ped = PlayerPedId()
    local fwd = GetEntityForwardVector(ped)
    local aim = GetEntityCoords(ped) + fwd * (Config.CastMaxDistance * power)
    -- land the float on the water surface if we can find it
    local hasWater, waterZ = GetWaterHeight(aim.x, aim.y, aim.z + 5.0)
    local landing = vector3(aim.x, aim.y, hasWater and waterZ or aim.z)

    local start = Anim.RodTip() or rodTip()
    local dx, dy = landing.x - start.x, landing.y - start.y
    local hop = math.min(math.sqrt(dx * dx + dy * dy) * 0.18, 4.0)

    -- vanilla GTA has no dedicated float prop on every build; fall back to a
    -- drawn marker below if absent so the bobber is always visible
    local model = `prop_fishing_float_01`
    if IsModelValid(model) then
        lib.requestModel(model)
        floatObj = CreateObject(model, start.x, start.y, start.z, false, false, false)
        SetModelAsNoLongerNeeded(model)
    end

    Casting.anchor = nil    -- not landed yet: arc flight in progress
    Casting.diving = false

    CreateThread(function()
        -- Phase 1: arc flight rod tip -> landing
        local t0 = GetGameTimer()
        while ZClient.active do
            local t = (GetGameTimer() - t0) / FLIGHT_MS
            if t >= 1.0 then break end
            local p = FloatKinematics.ArcPoint(start, landing, t, hop)
            if floatObj then
                SetEntityCoordsNoOffset(floatObj, p.x, p.y, p.z, false, false, false)
            else
                -- same no-prop fallback as the resting phase: never an invisible bobber
                DrawMarker(28, p.x, p.y, p.z, 0.0,0.0,0.0, 0.0,0.0,0.0, 0.12,0.12,0.12,
                    220, 40, 40, 200, false, false, 2, false, nil, nil, false)
            end
            drawFishingLine(Anim.RodTip() or start, p)
            Wait(0)
        end
        if not ZClient.active then return end   -- cancelled mid-flight; RemoveFloat cleaned up

        -- Phase 2: rest on the surface. Three sub-modes, one loop:
        --   fight  = bobber distance follows the fish's live energy (StartFight)
        --   drift  = free-floating with the current after the catch (StartDrift)
        --   diving = short bite->hook dip, the "fish took the bait" cue
        -- self-stops when the session ends (active=false) or RemoveFloat() clears the anchor.
        Casting.anchor = landing
        while ZClient.active and Casting.anchor do
            local a = Casting.anchor
            local now = GetGameTimer()
            local dt = GetFrameTime()
            local bz = a.z

            local fight, drift = Casting.fight, Casting.drift
            if fight then
                -- live player pos so this also works when FreezeWhileFishing is off
                local pp = GetEntityCoords(PlayerPedId())
                local dx, dy = fight.origin.x - pp.x, fight.origin.y - pp.y
                local full = math.sqrt(dx * dx + dy * dy)
                if full > 0.01 then
                    fight.d0 = fight.d0 or full
                    -- ease toward the streamed energy so 150ms updates look continuous
                    fight.cur = fight.cur + (fight.energy - fight.cur) * math.min(1.0, dt * 1.2)
                    local pos, d0 = FloatKinematics.FightPosition(fight.origin, pp, full, fight.d0, fight.cur, now, dt)
                    fight.d0 = d0
                    local hasW, wz = GetWaterHeight(pos.x, pos.y, a.z + 3.0)
                    Casting.anchor = vector3(pos.x, pos.y, hasW and wz or a.z)
                    a = Casting.anchor
                end
                -- splashy but on the surface — never buried out of sight
                bz = a.z - 0.10 + math.sin(now / 140.0) * 0.09
            elseif drift then
                -- lazy meander: heading slowly wanders, gentle bob
                drift.heading = drift.heading + math.sin(now / 2600.0) * 0.4 * dt
                local x = a.x + math.cos(drift.heading) * drift.speed * dt
                local y = a.y + math.sin(drift.heading) * drift.speed * dt
                local hasW, wz = GetWaterHeight(x, y, a.z + 3.0)
                Casting.anchor = vector3(x, y, hasW and wz or a.z)
                a = Casting.anchor
                bz = a.z + math.sin(now / 900.0) * 0.05
            elseif Casting.diving then
                bz = a.z - DIVE_DEPTH + math.sin(now / 150.0) * 0.08
            else
                -- idle: gentle two-wave bob while waiting for a bite
                bz = a.z + math.sin(now / 700.0) * 0.06 + math.sin(now / 263.0) * 0.02
            end

            if floatObj then SetEntityCoordsNoOffset(floatObj, a.x, a.y, bz, false, false, false) end
            drawFishingLine(Anim.RodTip() or rodTip(), vector3(a.x, a.y, bz))
            WaterEffects.DrawRipples(a, bz, fight ~= nil)
            if not floatObj then
                DrawMarker(28, a.x, a.y, bz, 0.0,0.0,0.0, 0.0,0.0,0.0, 0.12,0.12,0.12,
                    220, 40, 40, 200, false, false, 2, false, nil, nil, false)
            end
            Wait(0)
        end
    end)
end

function Casting.RemoveFloat()
    Casting.anchor = nil
    Casting.diving = false
    Casting.fight = nil
    Casting.drift = nil
    if floatObj and DoesEntityExist(floatObj) then DeleteEntity(floatObj) end
    floatObj = nil
end
