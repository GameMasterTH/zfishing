Validate = {}

if not ConfigSchema then
    print('^1[zfishing] CRITICAL ERROR: ConfigSchema is nil! Make sure server/config_schema.lua is loaded in fxmanifest.lua before server/validate.lua^7')
    ConfigSchema = { WATER_TYPES = { lake = true, river = true, ocean = true, swamp = true, dam = true }, ClampNum = function(v) return tonumber(v) end }
end

Validate.WATER = ConfigSchema.WATER_TYPES
Validate.num = ConfigSchema.ClampNum

function Validate.Setting(key, value)
    return ConfigSchema.ValidateSetting(key, value)
end

function Validate.Zone(z)
    return ConfigSchema.ValidateZone(z)
end

function Validate.Fish(data)
    return ConfigSchema.ValidateFish(data)
end

function Validate.Equipment(slot, data)
    return ConfigSchema.ValidateEquipment(slot, data)
end
