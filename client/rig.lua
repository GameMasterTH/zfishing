-- Rod assembly menu (NUI). The only entry point is the G keybind, and only while
-- the player is in equip standby (rod in hand, not yet cast). The old ox_lib
-- context menu, the ox_inventory "Manage Rod" right-click (zfishing:manageRod)
-- and the /fishrig command path (zfishing:rig:open) are all gone.
-- All mutations still go through the same server callbacks — this file only
-- renders state and forwards attach/detach requests unchanged.

-- part type -> Config.Equipment slot key (mirrors server/rig.lua's SLOT_OF)
local PART_TYPES = { 'reel', 'line', 'hook', 'float' }
local SLOT_OF = { reel = 'reels', line = 'lines', hook = 'hooks', float = 'floats' }

local RigState = { open = false, pending = false }

-- Enumerate every manageable part from Config.Equipment so the NUI can show a
-- row per item (incl. ones the player owns 0 of, rendered dimmed). Returns a
-- flat list of { partType, name, label }.
local function buildCatalog()
    local catalog = {}
    for _, partType in ipairs(PART_TYPES) do
        local group = Config.Equipment[SLOT_OF[partType]] or {}
        for name, cfg in pairs(group) do
            catalog[#catalog + 1] = {
                partType = partType,
                name = name,
                label = (cfg and cfg.label) or name,
            }
        end
    end
    return catalog
end

-- lib.callback.await has no built-in timeout; run it in a side thread and poll a
-- deadline so a silent server never leaves the menu stuck "pending". Returns
-- result, timedOut.
local function rigCallback(name, timeoutMs, ...)
    local n = select('#', ...)
    local args = { ... }
    local done, result = false, nil
    CreateThread(function()
        result = lib.callback.await(name, false, table.unpack(args, 1, n))
        done = true
    end)
    local deadline = GetGameTimer() + timeoutMs
    while not done and GetGameTimer() < deadline do Wait(0) end
    if not done then return nil, true end
    return result, false
end

-- Single, idempotent close point. SetNuiFocus(false,false) runs FIRST every time
-- so the mouse can never get stuck, even if a later step fails or the menu was
-- already closed.
local function closeMenu()
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'rigClose' })
    RigState.open = false
end

-- Label of a part for the attached/detached notify (%s). attach knows the item
-- name; detach reads it back from the last view we rendered.
local function attachLabel(partType, itemName)
    local group = Config.Equipment[SLOT_OF[partType]]
    local cfg = group and itemName and group[itemName]
    return (cfg and cfg.label) or itemName or partType
end

-- Push the current view + catalog to the NUI and remember it (detach needs the
-- fitted label for its notify).
local function sendOpen(view)
    RigState.view = view
    SendNUIMessage({ action = 'rigOpen', view = view, catalog = buildCatalog() })
end

-- ---------------------------------------------------------------- keybind
-- Toggle: open in standby, close if already open. Enhanced_Mode is the only
-- supported mode, so there is no mode check and no zfishing:rig:mode call.
local function rigCommand()
    if RigState.open then
        closeMenu()                                     -- toggle close (Req 1.4)
        return
    end
    -- gate: only in equip standby, no request in flight, not already open
    if ZClient.standby ~= true or RigState.pending or RigState.open then
        return                                          -- Req 1.3, 1.8
    end

    RigState.pending = true
    CreateThread(function()
        local view, timedOut = rigCallback('zfishing:rig:get', 5000, ZClient.rodSlot)
        RigState.pending = false
        if timedOut then
            lib.notify({ description = locale('rig_error') or 'rig_error', type = 'error' })  -- Req 1.7
            return
        end
        if not view then
            lib.notify({ description = locale('rig_no_rod') or 'No rod in that slot', type = 'error' })  -- Req 1.6
            return
        end
        sendOpen(view)                                  -- Req 3.1, 5.4
        SetNuiFocus(true, true)
        RigState.open = true
    end)
end

RegisterCommand('zfishing_rig', rigCommand, false)
RegisterKeyMapping('zfishing_rig', 'Manage fishing rod', 'keyboard', 'G')  -- Req 1.1, 1.5

-- ---------------------------------------------------------------- NUI callbacks
-- attach/detach forwarded to the SAME server callbacks with UNCHANGED args:
--   zfishing:rig:attach(slot, partType, itemName)
--   zfishing:rig:detach(slot, partType)
RegisterNUICallback('rigAction', function(body, cb)
    local kind = body and body.kind
    local partType = body and body.partType
    local itemName = body and body.itemName

    local partSlot = body and body.slot  -- inventory slot of the specific item instance the player clicked

    if kind ~= 'attach' and kind ~= 'detach' then
        cb({})
        return
    end

    -- resolve the notify label before mutating (detach removes it from parts)
    local label
    if kind == 'attach' then
        label = attachLabel(partType, itemName)
    else
        local fitted = RigState.view and RigState.view.parts and RigState.view.parts[partType]
        label = (fitted and fitted.label) or partType
    end

    CreateThread(function()
        local res, timedOut
        if kind == 'attach' then
            res, timedOut = rigCallback('zfishing:rig:attach', 5000, ZClient.rodSlot, partType, itemName, partSlot)  -- Req 4.1, 4.10
        else
            res, timedOut = rigCallback('zfishing:rig:detach', 5000, ZClient.rodSlot, partType)            -- Req 4.2, 4.10
        end

        if not timedOut and res and res.ok then
            -- refresh the displayed rig state (Req 4.4)
            local view = rigCallback('zfishing:rig:get', 5000, ZClient.rodSlot)
            if view and RigState.open then sendOpen(view) end
            local key = kind == 'attach' and 'attached' or 'detached'                                     -- Req 4.5, 4.6
            lib.notify({ description = (locale(key) or key):format(label), type = 'success' })
        else
            -- err inv_full -> rig_inv_full; any other err or timeout -> rig_error; keep state (Req 4.7-4.9)
            local key = (not timedOut and res and res.err == 'inv_full') and 'rig_inv_full' or 'rig_error'
            lib.notify({ description = locale(key) or key, type = 'error' })
        end
    end)

    cb({})
end)

RegisterNUICallback('rigClose', function(_, cb)
    closeMenu()                                         -- Req 3.2, 3.3
    cb({})
end)

-- fishing cleanup (main.lua) force-closes the menu so the mouse never gets stuck
AddEventHandler('zfishing:rig:forceClose', function()
    closeMenu()                                         -- Req 3.4
end)

-- broken-gear notifications pushed by the server during degrade (unrelated to the
-- menu — kept as-is)
RegisterNetEvent('zfishing:rig:notify', function(kind, label)
    if kind == 'part_broke' then
        lib.notify({ description = (locale('part_broke') or '%s broke!'):format(label), type = 'error' })
    elseif kind == 'rod_broke' then
        lib.notify({ description = locale('rod_broke') or 'Your rod snapped!', type = 'error' })
    elseif kind == 'line_broke' then
        lib.notify({ description = locale('line_item_broke') or 'Your line is destroyed', type = 'error' })
    end
end)
