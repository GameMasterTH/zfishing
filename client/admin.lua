RegisterNetEvent('zfishing:admin:open', function()
    local config = lib.callback.await('zfishing:admin:getConfig', false)
    if not config then return end
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'admin', config = config })
end)

RegisterNUICallback('adminClose', function(_, cb)
    SetNuiFocus(false, false)
    cb({})
end)

-- generic passthrough: NUI calls fetchNui('adminSave', { cbName, args })
RegisterNUICallback('adminSave', function(body, cb)
    local res = lib.callback.await(body.cbName, false, table.unpack(body.args or {}))
    cb(res or {})
end)
