-- สิทธิ์ผู้ดูแลมาจาก zcore_lib แบบกลาง: console, framework admin,
-- ACE มาตรฐาน หรือ zfishing.admin ที่เป็น override แบบ optional
function isAdmin(src)
    return exports.zcore_lib:IsAdmin(src, 'zfishing.admin')
end

lib.callback.register('zfishing:admin:check', function(src)
    return isAdmin(src)
end)

lib.callback.register('zfishing:admin:getConfig', function(src)
    if not isAdmin(src) then return nil end
    return {
        settings = {
            RateLimit = Config.RateLimit, Timings = Config.Timings,
            CastMaxDistance = Config.CastMaxDistance, Durability = Config.Durability,
            RareLoot = Config.RareLoot, DefaultWater = Config.DefaultWater,
            RequireZone = Config.RequireZone,
            RodCanBreak = Config.RodCanBreak, RequireAssembly = Config.RequireAssembly,
        },
        zones = Store.zonesPayloadWithId(),
        fish = Config.Fish,
        equipment = Config.Equipment,
        rarity = Config.Rarity,
        waterTypes = Config.Admin.waterTypes,
    }
end)

-- ---------------------------------------------------------------- mutations (ACE-gated)
lib.callback.register('zfishing:admin:saveSetting', function(src, key, value)
    if not isAdmin(src) then return { ok = false, err = 'denied' } end
    local ok, err = Store.SaveSetting(key, value)
    return { ok = ok, err = err }
end)

lib.callback.register('zfishing:admin:saveZone', function(src, zone)
    if not isAdmin(src) then return { ok = false, err = 'denied' } end
    local id, err = Store.UpsertZone(zone)
    if not id then return { ok = false, err = err } end
    return { ok = true, id = id }
end)

lib.callback.register('zfishing:admin:deleteZone', function(src, id)
    if not isAdmin(src) then return { ok = false, err = 'denied' } end
    return { ok = Store.DeleteZone(id) }
end)

lib.callback.register('zfishing:admin:saveFish', function(src, species, data)
    if not isAdmin(src) then return { ok = false, err = 'denied' } end
    local ok, err = Store.SaveFish(species, data)
    return { ok = ok, err = err }
end)

lib.callback.register('zfishing:admin:deleteFish', function(src, species)
    if not isAdmin(src) then return { ok = false, err = 'denied' } end
    return { ok = Store.DeleteFish(species) }
end)

lib.callback.register('zfishing:admin:saveEquipment', function(src, slot, item, data)
    if not isAdmin(src) then return { ok = false, err = 'denied' } end
    local ok, err = Store.SaveEquipment(slot, item, data)
    return { ok = ok, err = err }
end)

lib.callback.register('zfishing:admin:resetDomain', function(src, domain)
    if not isAdmin(src) then return { ok = false, err = 'denied' } end
    local ok, err = Store.ResetDomain(domain)
    return { ok = ok, err = err }
end)

-- ---------------------------------------------------------------- commands
RegisterCommand('zfishzone', function(src)
    if not isAdmin(src) then
        if src ~= 0 then exports.zcore_lib:Notify(src, 'No permission', 'error') end
        return
    end
    if src ~= 0 then TriggerClientEvent('zfishing:zonetool:start', src) end
end, false)

RegisterCommand('zfishadmin', function(src)
    if not isAdmin(src) then
        if src ~= 0 then exports.zcore_lib:Notify(src, 'No permission', 'error') end
        return
    end
    if src ~= 0 then TriggerClientEvent('zfishing:admin:open', src) end
end, false)
