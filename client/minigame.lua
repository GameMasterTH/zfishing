-- Bite → hook QTE → reel phase. Session-wide client state lives in ZClient
-- (owned by client/main.lua); cleanup always goes through zfishing:client:end
-- so there is exactly one teardown path.

ZClient = ZClient or { active = false, reeling = false, hud = {} }

local function endFishing(msgKey, msgType)
    TriggerEvent('zfishing:client:end', msgKey, msgType)
end

RegisterNetEvent('zfishing:bite', function(data)
    if not ZClient.active then return end
    Casting.diving = true   -- bobber dives the moment the fish takes the bait

    PlaySoundFrontend(-1, 'TIMER_STOP', 'HUD_MINI_GAME_SOUNDSET', true)
    SetPadShake(0, 300, 150)
    SendNUIMessage({ action = 'waiting', phase = 'bite',
        rod = ZClient.hud.rod, bait = ZClient.hud.bait, distance = ZClient.hud.distance })

    local deadline = GetGameTimer() + (data.hookWindow or 1500)
    local hooked = false
    while ZClient.active and GetGameTimer() < deadline do
        if IsDisabledControlJustPressed(0, 22) then hooked = true break end -- SPACE
        Wait(0)
    end
    if not ZClient.active then return end

    if not hooked then
        lib.callback.await('zfishing:cancel', false, ZClient.sessionId)
        return endFishing('fish_escaped', 'error')
    end

    local res = lib.callback.await('zfishing:hook', false, ZClient.sessionId)
    if not res or not res.ok then
        return endFishing('fish_escaped', 'error')
    end

    SendNUIMessage({ action = 'reel',
        behavior = data.behavior, tensionDiff = data.tensionDiff,
        fishEnergy = data.fishEnergy, greenZone = data.greenZone,
        snapFactor = data.snapFactor, drainRate = data.drainRate,
        baseDrain = data.baseDrain, reelTimeout = data.reelTimeout,
        fishWeight = data.fishWeight,
        startedAt = GetGameTimer() })
    Casting.StartFight()   -- bobber now tracks the fish's energy (see reelEnergy)
    Anim.PlayClip('idle_c') -- swap waiting pose (idle_a) -> active fight pose
    ZClient.reeling = true

    CreateThread(function()
        local lastHold
        while ZClient.reeling do
            local hold = IsDisabledControlPressed(0, 22)
            if hold ~= lastHold then
                lastHold = hold
                SendNUIMessage({ action = 'reelInput', holding = hold })
            end
            Wait(0)
        end
    end)
end)

-- live fish-energy stream from the NUI minigame; drives the bobber's distance
RegisterNUICallback('reelEnergy', function(body, cb)
    cb({})
    Casting.SetFightEnergy(body.pct)
end)

RegisterNUICallback('reelResult', function(body, cb)
    cb({})
    if not ZClient.reeling then return end
    ZClient.reeling = false

    local res = lib.callback.await('zfishing:claim', false, ZClient.sessionId, body.durationMs or 0, body.success == true, body.reason)
    if res and res.ok and res.fish then
        SendNUIMessage({ action = 'caught',
            label = res.fish.label, weight = res.fish.weight, quality = res.fish.quality })
        Casting.StartDrift()   -- bobber floats free with the current behind the catch card
        SetNuiFocus(true, true)
        PlaySoundFrontend(-1, 'CHECKPOINT_PERFECT', 'HUD_MINI_GAME_SOUNDSET', true)
        -- teardown happens on keep/release click
    elseif res and res.ok then
        endFishing(body.reason == 'snap' and 'line_broke' or 'fish_escaped', 'error')
    else
        endFishing('fish_escaped', 'error')
    end
end)

local function closeCatchCard()
    SetNuiFocus(false, false)
    endFishing(nil)
end

RegisterNUICallback('keep', function(_, cb) cb({}); closeCatchCard() end)
RegisterNUICallback('release', function(_, cb) cb({}); closeCatchCard() end)
