-- Bind the fishing rods as useable items.
--
-- items.lua only flags rods `useable = true` — QBCore/ESX/QBox still need an
-- explicit useable-item callback, otherwise using a rod just prints "Used" and
-- nothing happens. Using a rod forwards the inventory item (with its slot) to the
-- client, which already listens on `zfishing:client:useRod`; the slot lets
-- enhanced-rig read the components fitted on THAT specific rod.
--
-- The zcore_lib bridge would be the "pure" path, but registering a useable item
-- means handing a CALLBACK across a resource boundary, which is the fragile part
-- of FiveM exports (unlike read ops that pass strings and return tables). So we
-- probe the bridge once for diagnostics, then register directly against the
-- framework with a local callback — robust and immediate.

local function onRodUsed(source, item)
    TriggerClientEvent('zfishing:client:useRod', source, item)
end

local function frameworkReady()
    return GetResourceState('qb-core') == 'started'
        or GetResourceState('qbx_core') == 'started'
        or GetResourceState('es_extended') == 'started'
end

-- Direct framework useable-item hook (local callback). Returns true on success.
local function directRegister(rodName)
    local ok, err = pcall(function()
        if GetResourceState('qb-core') == 'started' then
            exports['qb-core']:GetCoreObject().Functions.CreateUseableItem(rodName, onRodUsed)
        elseif GetResourceState('qbx_core') == 'started' then
            exports.qbx_core:CreateUseableItem(rodName, onRodUsed)
        elseif GetResourceState('es_extended') == 'started' then
            exports.es_extended:getSharedObject().RegisterUsableItem(rodName, onRodUsed)
        else
            error('no supported framework resource is started')
        end
    end)
    if not ok then
        print(('[zfishing] usable registration failed for %s: %s'):format(rodName, tostring(err)))
    end
    return ok
end

CreateThread(function()
    -- one diagnostic attempt through the bridge so its real result is visible
    local sample
    for rodName in pairs(Config.Equipment.rods) do sample = rodName break end
    if sample then
        local res = exports.zcore_lib:RegisterUsableItem(sample, onRodUsed)
        local err = type(res) == 'table' and res.error or nil
        if type(res) == 'table' and res.ok then
            print('[zfishing] bridge RegisterUsableItem works; registering rods via bridge')
            for rodName in pairs(Config.Equipment.rods) do
                if rodName ~= sample then exports.zcore_lib:RegisterUsableItem(rodName, onRodUsed) end
            end
            return
        end
        print(('[zfishing] bridge RegisterUsableItem unavailable ([%s] %s) -- using direct framework hook'):format(
            err and err.code or 'NO_ENVELOPE', err and err.message or tostring(res)))
    end

    for _ = 1, 100 do
        if frameworkReady() then break end
        Wait(100)
    end
    local failed = false
    for rodName in pairs(Config.Equipment.rods) do
        if not directRegister(rodName) then failed = true end
    end
    if not failed then print('[zfishing] usable rods registered via direct framework hook') end
end)
