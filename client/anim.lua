Anim = {}
local rodProp
local DICT = 'amb@world_human_stand_fishing@idle_a'

-- Cast wind-up: scrubbed manually so the throw reads as a slow motion that
-- tracks the charge power (0..1) instead of playing at its own speed.
local THROW_DICT = 'anim@veh@drivebytruck@wastelander@rps_rear_thrown'
local THROW_CLIP = 'throw_0'

-- Tip anchor in prop_fishing_rod_01's LOCAL space. The prop's pivot / long axis
-- can't be verified off-server, so TUNE on a live server: set Anim.debugTip = true,
-- restart once, then adjust live with /zfishtip until the red marker sits on the
-- rod's tip, and lock the values here. (Replaces casting.lua's hand-bone guess.)
local TIP_OFFSET = vector3(0.0, 0.0, 2.5)  -- local offset from rod prop to tip (tune with /zfishtip)
Anim.debugTip = false

-- tune-only command; debugTip=false (the shipped default) never registers it,
-- so there is no leftover surface in normal play. Visual + client-only anyway.
if Anim.debugTip then
    RegisterCommand('zfishtip', function(_, args)
        local x, y, z = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
        if x and y and z then TIP_OFFSET = vector3(x, y, z) end
        print(('zfishing tip offset: %.2f %.2f %.2f'):format(TIP_OFFSET.x, TIP_OFFSET.y, TIP_OFFSET.z))
    end, false)
end

-- Play a clip from DICT on the player without touching the attached rod prop.
-- Reused to swap between the waiting pose (idle_a) and the fight pose (idle_c).
function Anim.PlayClip(clip)
    lib.requestAnimDict(DICT)
    TaskPlayAnim(PlayerPedId(), DICT, clip, 8.0, -8.0, -1, 49, 0, false, false, false)
end

-- Equip: just put the rod prop in the player's hand. No pose yet — the throw
-- wind-up starts when the player begins charging the cast (Anim.Charge).
function Anim.Start()
    local ped = PlayerPedId()
    local model = `prop_fishing_rod_01`
    lib.requestModel(model)
    rodProp = CreateObject(model, 0.0, 0.0, 0.0, true, true, false)
    local bone = GetPedBoneIndex(ped, 18905) -- right hand
    AttachEntityToEntity(rodProp, ped, bone, 0.1, 0.05, 0.0, 80.0, 120.0, 160.0, true, true, false, true, 1, true)
    SetModelAsNoLongerNeeded(model)
end

-- Begin the cast wind-up. The clip is advanced by hand via Anim.ChargePhase so
-- it stays in lock-step with the charge bar rather than running on its own.
function Anim.Charge()
    lib.requestAnimDict(THROW_DICT)
    -- flag 48 = upper-body only + allow player control; legs stay planted.
    TaskPlayAnim(PlayerPedId(), THROW_DICT, THROW_CLIP, 8.0, -8.0, -1, 48, 0.0, false, false, false)
end

-- Scrub the throw clip to phase p (0..1) — call every frame while charging.
function Anim.ChargePhase(p)
    if p < 0.0 then p = 0.0 elseif p > 1.0 then p = 1.0 end
    SetEntityAnimCurrentTime(PlayerPedId(), THROW_DICT, THROW_CLIP, p)
end

-- World position of the rod's tip, derived from the actual attached prop (nil
-- if the prop is gone — callers fall back to their own guess).
function Anim.RodTip()
    if not (rodProp and DoesEntityExist(rodProp)) then return nil end
    local tip = GetOffsetFromEntityInWorldCoords(rodProp, TIP_OFFSET.x, TIP_OFFSET.y, TIP_OFFSET.z)
    if Anim.debugTip then
        DrawMarker(28, tip.x, tip.y, tip.z, 0.0,0.0,0.0, 0.0,0.0,0.0,
            0.06,0.06,0.06, 255, 40, 40, 220, false, false, 2, false, nil, nil, false)
    end
    return tip
end

function Anim.Stop()
    ClearPedTasks(PlayerPedId())
    if rodProp and DoesEntityExist(rodProp) then DeleteEntity(rodProp) end
    rodProp = nil
end
