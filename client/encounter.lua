-- Encounter bridge and orchestrator.
--
-- Routes an encounter bite to the NUI, polls input, forwards one discrete action at a
-- time, and drives settlement when the server says the fight is over.
--
-- It simulates NOTHING: no stamina, no timer that decides anything, no notion of
-- whether an action was correct. The server answers all three. Its own state is the
-- sequence number, the in-flight lock and the last authoritative payload.

local ENC = { active = false, seq = 0, inFlight = false,
              challengeId = nil, sessionId = nil, type = nil }

-- action -> control. All four are analog on a gamepad already, so controller support
-- needs no separate mapping and no button mashing.
local KEYS = {
    { action = 'left',  control = 34 },   -- INPUT_MOVE_LEFT_ONLY   (A / stick left)
    { action = 'right', control = 35 },   -- INPUT_MOVE_RIGHT_ONLY  (D / stick right)
    { action = 'brace', control = 33 },   -- INPUT_MOVE_DOWN_ONLY   (S / stick down)
    { action = 'reel',  control = 22 },   -- the key the legacy fight already uses
}

local function reset()
    ENC.active, ENC.inFlight = false, false
    ENC.challengeId, ENC.sessionId, ENC.type = nil, nil, nil
    ENC.seq = 0
end

-- Settlement. Runs once, from here, the moment the server reports a terminal outcome.
-- The NUI is a spectator to this: if it never posts encounterClosed the catch still
-- settles, and if it posts twice the session is already gone.
local function settle(outcome)
    local sessionId = ENC.sessionId
    reset()
    ZClient.reeling = false
    if not sessionId then return end

    Wait(700)   -- let the ending render before the catch card replaces it

    -- The same door as always. `success` is ignored for an encounter session -- the
    -- server reads its own outcome -- but the argument list is unchanged, so there is
    -- still exactly one settlement path in the resource.
    local res = lib.callback.await('zfishing:claim', false, sessionId, 0, false, nil)
    if res and res.ok and res.fish then
        SendNUIMessage({ action = 'caught',
            label = res.fish.label, weight = res.fish.weight, quality = res.fish.quality })
        Casting.StartDrift()
        SetNuiFocus(true, true)
        PlaySoundFrontend(-1, 'CHECKPOINT_PERFECT', 'HUD_MINI_GAME_SOUNDSET', true)
    elseif res and res.ok then
        TriggerEvent('zfishing:client:end',
            (res.outcome or outcome) == 'snap' and 'line_broke' or 'fish_escaped', 'error')
    else
        TriggerEvent('zfishing:client:end', 'error_claim_failed', 'error')
    end
end

-- One request in flight at a time. Input polling and the NUI's deadline `advance` are
-- two independent senders, and near a window edge both would claim the same seq -- the
-- server rejects the loser as bad_seq, which is safe but costs an honest player the
-- input they actually made. Counter-pull is discrete and human-paced, so a lock is
-- enough; do not add a queue without evidence that one is needed.
local function send(action)
    if not ENC.active or ENC.inFlight then return end
    ENC.inFlight = true

    local res = lib.callback.await('zfishing:encounter:act', false,
        ENC.sessionId, ENC.challengeId, ENC.seq + 1, action)

    ENC.inFlight = false
    if not res then return end
    if res.seq then ENC.seq = res.seq end

    if res.ok then
        SendNUIMessage({ action = 'encounterState', state = res.state, outcome = res.outcome })
        if res.outcome then settle(res.outcome) end
        return
    end

    -- A rejection that ends the fight has to end it here too, or the player sits in a
    -- UI nothing will ever update again.
    if res.reason == 'encounter_over' then
        SendNUIMessage({ action = 'encounterState', state = nil, outcome = res.outcome or 'timeout' })
        settle(res.outcome or 'timeout')
    end
end

RegisterNetEvent('zfishing:bite', function(data)
    if not ZClient.active then return end
    if not data.encounter or data.encounter == 'legacy_tension' then return end

    Casting.diving = true
    PlaySoundFrontend(-1, 'TIMER_STOP', 'HUD_MINI_GAME_SOUNDSET', true)
    SetPadShake(0, 300, 150)
    SendNUIMessage({ action = 'waiting', phase = 'bite',
        rod = ZClient.hud.rod, bait = ZClient.hud.bait, distance = ZClient.hud.distance })

    -- The hook QTE is unchanged: SPACE inside the window, exactly as the legacy path.
    local deadline = GetGameTimer() + (data.hookWindow or 1500)
    local hooked = false
    while ZClient.active and GetGameTimer() < deadline do
        if IsDisabledControlJustPressed(0, 22) then hooked = true break end
        Wait(0)
    end
    if not ZClient.active then return end
    if not hooked then
        lib.callback.await('zfishing:cancel', false, ZClient.sessionId)
        return TriggerEvent('zfishing:client:end', 'fish_escaped', 'error')
    end

    local res = lib.callback.await('zfishing:hook', false, ZClient.sessionId)
    if not res or not res.ok or not res.challengeId then
        return TriggerEvent('zfishing:client:end', 'fish_escaped', 'error')
    end

    ENC.active, ENC.inFlight, ENC.seq = true, false, 0
    ENC.sessionId, ENC.challengeId, ENC.type = ZClient.sessionId, res.challengeId, data.encounter
    ZClient.reeling = true

    SendNUIMessage({ action = 'encounter', type = data.encounter,
        difficulty = data.difficulty, state = res.encounter,
        startedAt = GetGameTimer() })
    Casting.StartFight()
    Anim.PlayClip('idle_c')

    -- Input polling. One event per PRESS, never per frame -- the loop runs at frame
    -- rate because that is how FiveM reads a key, but it only talks to the server on an
    -- edge, and only when no request is already out.
    CreateThread(function()
        while ENC.active and ZClient.active do
            if not ENC.inFlight then
                for _, k in ipairs(KEYS) do
                    if IsDisabledControlJustPressed(0, k.control) then
                        send(k.action)
                        break
                    end
                end
            end
            Wait(0)
        end
    end)
end)

-- The NUI's local window expired. The server decides what that means, and refuses an
-- `advance` that arrives before the deadline it set.
RegisterNUICallback('encounterAction', function(body, cb)
    cb({})
    if type(body) == 'table' and type(body.action) == 'string' then send(body.action) end
end)

-- Presentation close only. Settlement already happened in settle(); this exists so the
-- NUI can say its ending animation is done. It grants no permission.
RegisterNUICallback('encounterClosed', function(_, cb) cb({}) end)

AddEventHandler('zfishing:client:end', function() reset() end)
