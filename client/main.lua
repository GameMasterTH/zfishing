lib.locale()
-- Config.Locale overrides the ox:locale convar for this resource (Lua notify
-- strings AND the NUI). false = follow the convar.
if Config.Locale and lib.setLocale then lib.setLocale(Config.Locale) end

local function activeLang()
    return Config.Locale or GetConvar('ox:locale', 'en')
end

ZClient = ZClient or { active = false, reeling = false, standby = false, hud = {} }

-- NUI strings come from the same locale files as the Lua side (ui_* keys).
-- en is the base; the active language overlays it so missing keys fall back.
RegisterNUICallback('getLocale', function(_, cb)
    local res = GetCurrentResourceName()
    local function load(l)
        local raw = LoadResourceFile(res, ('locales/%s.json'):format(l))
        return raw and json.decode(raw) or nil
    end
    local dict = load('en') or {}
    local lang = activeLang()
    if lang ~= 'en' then
        for k, v in pairs(load(lang) or {}) do dict[k] = v end
    end
    cb(dict)
end)

-- ---------------------------------------------------------------- weather
local WEATHERS = {
    'CLEAR','EXTRASUNNY','CLOUDS','OVERCAST','RAIN','CLEARING','THUNDER',
    'SMOG','FOGGY','XMAS','SNOW','SNOWLIGHT','BLIZZARD','HALLOWEEN','NEUTRAL',
}
local weatherByHash = {}
for _, w in ipairs(WEATHERS) do weatherByHash[GetHashKey(w)] = w end

local function currentWeatherName()
    local w1, w2, pct = GetWeatherTypeTransition()
    local h = (pct and pct > 0.5) and w2 or w1
    return weatherByHash[h] or 'CLEAR'
end

CreateThread(function()
    while true do
        TriggerServerEvent('zfishing:reportWeather', currentWeatherName(), GetClockHours())
        Wait(60000)
    end
end)

-- ---------------------------------------------------------------- zones / water
-- 2D horizontal distance to match server/session.lua's resolveZone() — this is a
-- client-side gate for UX only, the server re-resolves from real position and
-- never trusts anything the client sends.
local function currentZone()
    local pos = GetEntityCoords(PlayerPedId())
    for _, z in ipairs(Config.Zones) do
        local dx, dy = pos.x - z.coords.x, pos.y - z.coords.y
        if (dx * dx + dy * dy) <= (z.radius * z.radius) then return z.name end
    end
    if not Config.RequireZone then return 'open-water' end
    return nil
end

local function nearWater()
    local ped = PlayerPedId()
    local pos = GetEntityCoords(ped)
    local fwd = GetEntityForwardVector(ped)
    local ahead = pos + fwd * 6.0
    local hit = TestProbeAgainstWater(ahead.x, ahead.y, pos.z + 4.0, ahead.x, ahead.y, pos.z - 12.0)
    return hit
end

-- ---------------------------------------------------------------- prompt HUD
-- Prompt_HUD toggle: read Config.PromptHud once at resource start. A real
-- boolean is kept as-is; nil or any non-boolean defaults to true (HUD on).
local function normalizePromptHud(raw)
    if type(raw) == 'boolean' then return raw end
    return true
end
local PROMPT_HUD = normalizePromptHud(Config.PromptHud)

-- Show the fishing prompt. HUD on: hand title/subtitle keys to the NUI overlay.
-- HUD off: fall back to the original ox_lib TextUI using the subtitle key.
local function showPrompt(titleKey, subtitleKey)
    if PROMPT_HUD then
        SendNUIMessage({ action = 'prompt', titleKey = titleKey, subtitleKey = subtitleKey })
    else
        lib.showTextUI(locale(subtitleKey))
    end
end

-- Hide the fishing prompt, matching whichever surface showPrompt used.
local function hidePrompt()
    if PROMPT_HUD then
        SendNUIMessage({ action = 'promptHide' })
    else
        lib.hideTextUI()
    end
end

-- ---------------------------------------------------------------- boat anchor helper
local currentBoatNetId = nil

local function getFishingBoat()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if veh == 0 then veh = GetVehiclePedIsIn(ped, true) end
    if veh == 0 then
        local pos = GetEntityCoords(ped)
        veh = GetClosestVehicle(pos.x, pos.y, pos.z, 3.5, 0, 12294)
    end
    if veh ~= 0 and DoesEntityExist(veh) and IsThisModelABoat(GetEntityModel(veh)) then
        return veh
    end
    return nil
end

RegisterNetEvent('zfishing:client:syncBoatAnchor', function(netId, state)
    local veh = NetToVeh(netId)
    if veh ~= 0 and DoesEntityExist(veh) then
        SetBoatAnchor(veh, state)
        SetBoatFrozenWhenAnchored(veh, state)
        SetForcedBoatLocationWhenAnchored(veh, state)
        if state then SetEntityVelocity(veh, 0.0, 0.0, 0.0) end
    end
end)

-- ---------------------------------------------------------------- lifecycle
local function cleanup(msgKey, msgType)
    ZClient.active = false
    ZClient.reeling = false
    ZClient.standby = false
    TriggerEvent('zfishing:rig:forceClose')             -- close the rig menu if it's open when fishing ends
    Casting.RemoveFloat()
    Anim.Stop()
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'hide' })
    local ped = PlayerPedId()
    if IsEntityAttached(ped) then DetachEntity(ped, true, true) end
    if currentBoatNetId then
        TriggerServerEvent('zfishing:server:unanchorBoat', currentBoatNetId)
        currentBoatNetId = nil
    end
    FreezeEntityPosition(ped, false)
    lib.hideTextUI()
    if msgKey then lib.notify({ description = locale(msgKey) or msgKey, type = msgType or 'inform' }) end
end

RegisterNetEvent('zfishing:client:end', function(msgKey, msgType)
    cleanup(msgKey, msgType)
end)

local function startFishing()
    ZClient.active = true
    Anim.Start()

    local boat = getFishingBoat()
    if boat then
        currentBoatNetId = VehToNet(boat)
        if currentBoatNetId and currentBoatNetId ~= 0 then
            TriggerServerEvent('zfishing:server:anchorBoat', currentBoatNetId)
            lib.notify({ description = locale('boat_anchored'), type = 'inform' })
            local ped = PlayerPedId()
            local pPos = GetEntityCoords(ped)
            local offset = GetOffsetFromEntityGivenWorldCoords(boat, pPos.x, pPos.y, pPos.z)
            local pHead = GetEntityHeading(ped)
            local bHead = GetEntityHeading(boat)
            AttachEntityToEntity(ped, boat, 0, offset.x, offset.y, offset.z, 0.0, 0.0, pHead - bHead, false, false, false, false, 2, true)
        end
    end

    CreateThread(function()
        local gasHoldTime = 0
        while ZClient.active do
            DisableControlAction(0, 22, true)  -- INPUT_JUMP (Spacebar - prevents ped vaulting/climbing ledges)
            DisableControlAction(0, 23, true)  -- INPUT_ENTER (F / Enter)
            DisableControlAction(0, 44, true)  -- INPUT_COVER (Q)
            DisableControlAction(0, 140, true) -- INPUT_MELEE_ATTACK_LIGHT
            DisableControlAction(0, 141, true) -- INPUT_MELEE_ATTACK_HEAVY
            DisableControlAction(0, 142, true) -- INPUT_MELEE_ATTACK_ALTERNATE

            local ped = PlayerPedId()
            if boat and DoesEntityExist(boat) then
                if IsEntityInWater(ped) then
                    cleanup('cancelled')
                    break
                end
                local driver = GetPedInVehicleSeat(boat, -1)
                if driver ~= 0 and driver ~= ped then
                    if IsControlPressed(0, 71) or IsControlPressed(0, 72) then
                        gasHoldTime = gasHoldTime + 100
                        if gasHoldTime >= 1500 then
                            cleanup('cancelled')
                            lib.notify({ description = 'เรือเคลื่อนที่ การตกปลาถูกยกเลิก', type = 'inform' })
                            break
                        end
                    else
                        gasHoldTime = 0
                    end
                end
            end
            Wait(100)
        end
    end)

    -- Equipped standby: the rod prop is now in hand, but nothing casts yet. Wait
    -- for the player to press E to actually begin (X packs up). Holding E flows
    -- straight into the charge below; tapping it just starts the cast bar.
    showPrompt('equip_title', 'equip_hint')
    ZClient.standby = true                              -- rig menu (G) may open only in this phase
    while ZClient.active and not IsControlJustPressed(0, 38) do  -- E
        Wait(0)
    end
    ZClient.standby = false
    hidePrompt()
    if not ZClient.active then return end               -- X pressed during standby: cleanup ran

    local power = Casting.Charge()
    if not ZClient.active then return end               -- X pressed: cleanup already ran
    if power == nil then return cleanup('cancelled') end -- never started casting (timeout)

    -- Re-check water proximity at cast time: startRodUse's gate only fired when
    -- the rod was equipped, so the player can drift onto land (still inside the
    -- 2D zone radius) before casting. Reject here so you can't fish off dry land.
    if not nearWater() then return cleanup('need_water', 'error') end

    local res = lib.callback.await('zfishing:cast', false, power, ZClient.rodSlot)
    if not res or not res.ok then
        cleanup(res and res.reason and ('error_' .. res.reason) or 'error_busy', 'error')
        return
    end

    if Config.FreezeWhileFishing and not boat then FreezeEntityPosition(PlayerPedId(), true) end

    Anim.PlayClip('idle_a')   -- line is out: settle into the waiting pose
    Casting.SpawnFloat(power)
    ZClient.hud = { rod = res.rod, bait = res.bait, distance = Config.CastMaxDistance * power }
    SendNUIMessage({ action = 'waiting', phase = 'waiting',
        rod = res.rod, bait = res.bait, distance = ZClient.hud.distance })
    showPrompt('cancel_title', 'cancel_hint')
end

-- Cancel keybind. Works in EVERY phase (incl. mid-reel) because freezing removes
-- the walk-away escape hatch — pressing X must always be able to bail out.
RegisterCommand('zfishing_cancel', function()
    if not ZClient.active then return end
    ZClient.reeling = false
    CreateThread(function()
        lib.callback.await('zfishing:cancel', false)
        cleanup('cancelled')
    end)
end, false)
RegisterKeyMapping('zfishing_cancel', 'Cancel fishing', 'keyboard', 'X')

-- ---------------------------------------------------------------- use-rod trigger
-- Fishing starts by USING the rod item, not a proximity keybind. Gate order:
-- near water first (cheap, immediate feedback), then zone membership (the
-- "no catchable fish here" case) — server re-validates both independently.
local function startRodUse(data, slot)
    -- which rod item was used? ox_inventory's client export passes the slot
    -- data table; the framework-native event passes the slot number directly.
    local rodSlot
    if type(data) == 'table' and data.slot then rodSlot = data.slot
    elseif type(slot) == 'table' and slot.slot then rodSlot = slot.slot
    elseif type(slot) == 'number' then rodSlot = slot
    elseif type(data) == 'number' then rodSlot = data end
    ZClient.rodSlot = rodSlot

    if ZClient.active then
        lib.notify({ description = locale('error_busy'), type = 'error' })
        return
    end
    local boat = getFishingBoat()
    if boat and GetEntitySpeed(boat) > 1.5 then
        lib.notify({ description = locale('error_boat_moving'), type = 'error' })
        return
    end
    if not nearWater() then
        lib.notify({ description = locale('need_water'), type = 'error' })
        return
    end
    if not currentZone() then
        lib.notify({ description = locale('no_fish_here'), type = 'error' })
        return
    end
    startFishing()
end

exports('useRod', startRodUse)                            -- ox_inventory item.export
RegisterNetEvent('zfishing:client:useRod', startRodUse)   -- framework-native useable item

-- ---------------------------------------------------------------- sell NPCs
local function sellFish()
    local res = lib.callback.await('zfishing:sellAll', false)
    if res and res.ok then
        lib.notify({ description = locale('sold'):format(res.total), type = 'success' })
    else
        lib.notify({ description = locale('no_fish'), type = 'error' })
    end
end

CreateThread(function()
    local useTarget = GetResourceState('ox_target') == 'started'
    for _, npc in ipairs(Config.SellNpcs) do
        lib.requestModel(npc.model)
        local ped = CreatePed(4, npc.model, npc.coords.x, npc.coords.y, npc.coords.z - 1.0, npc.coords.w, false, true)
        SetEntityInvincible(ped, true)
        SetBlockingOfNonTemporaryEvents(ped, true)
        FreezeEntityPosition(ped, true)
        SetModelAsNoLongerNeeded(npc.model)

        if useTarget then
            exports.ox_target:addLocalEntity(ped, {{
                name = 'zfishing_sell',
                label = locale('sell'),
                icon = 'fa-solid fa-fish',
                onSelect = sellFish,
            }})
        else
            local at = vector3(npc.coords.x, npc.coords.y, npc.coords.z)
            CreateThread(function()
                local shown = false
                while true do
                    local sleep = 800
                    if not ZClient.active and #(GetEntityCoords(PlayerPedId()) - at) < 2.5 then
                        sleep = 0
                        if not shown then lib.showTextUI(locale('sell')); shown = true end
                        if IsControlJustPressed(0, 38) then sellFish() end
                    elseif shown then
                        lib.hideTextUI(); shown = false
                    end
                    Wait(sleep)
                end
            end)
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    FreezeEntityPosition(PlayerPedId(), false)
end)
