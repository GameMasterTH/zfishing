-- Encounter settings validation and the admin surface. Run from the resource root:
--   node tests/luarun.mjs tests/encounter_admin.test.lua

dofile('tests/harness.lua')
local test, equal, truthy, falsy = H.test, H.equal, H.truthy, H.falsy

local function loadSchema()
    H.installHost()
    Config = H.baseConfig()
    dofile('shared/util.lua')
    dofile('shared/encounters.lua')
    dofile('server/config_schema.lua')
    dofile('server/validate.lua')
end

test('A1 EncounterMode accepts exactly the three modes', function()
    loadSchema()
    equal(Validate.Setting('EncounterMode', 'default'), 'default')
    equal(Validate.Setting('EncounterMode', 'random'), 'random')
    equal(Validate.Setting('EncounterMode', 'forced'), 'forced')
    local v, err = Validate.Setting('EncounterMode', 'chaos')
    falsy(v); truthy(err)
    falsy((Validate.Setting('EncounterMode', 'legacy')))
    falsy((Validate.Setting('EncounterMode', true)))
end)

test('A2 ForcedEncounter accepts the three encounters and refuses legacy', function()
    loadSchema()
    equal(Validate.Setting('ForcedEncounter', 'counter_pull'), 'counter_pull')
    equal(Validate.Setting('ForcedEncounter', 'fish_mindgame'), 'fish_mindgame')
    equal(Validate.Setting('ForcedEncounter', 'sonar_strike'), 'sonar_strike')
    local v, err = Validate.Setting('ForcedEncounter', 'legacy_tension')
    falsy(v, 'legacy is not forceable'); truthy(err)
    falsy((Validate.Setting('ForcedEncounter', 'boss_fight')))
    falsy((Validate.Setting('ForcedEncounter', '')))
end)

test('A3 ValidateFish keeps a registered encounter and rejects an unknown one', function()
    loadSchema()
    local base = { label = 'Bass', behavior = 'steady_light', rarity = 'common',
        weight = { min = 1, max = 4 }, price = 100, xp = 10, water = { 'lake' } }

    local none = Validate.Fish(H.deepcopy(base))
    truthy(none)
    equal(none.encounter, nil, 'no encounter key means unconfigured, and stays that way')

    local set = H.deepcopy(base); set.encounter = 'sonar_strike'
    equal(Validate.Fish(set).encounter, 'sonar_strike',
        'an encounter must survive validation -- an admin save would otherwise strip it')

    local legacy = H.deepcopy(base); legacy.encounter = 'legacy_tension'
    equal(Validate.Fish(legacy).encounter, 'legacy_tension',
        'an operator choosing legacy explicitly is a real, storable choice')

    local bad = H.deepcopy(base); bad.encounter = 'boss_fight'
    local v, err = Validate.Fish(bad)
    falsy(v, 'an unknown encounter is a hard error, not a silent drop'); truthy(err)
end)

-- ---------------------------------------------------------------- admin surface

local function loadAdmin(isAdminResult)
    H.installHost()
    Config = H.baseConfig()
    Config.EncounterMode = 'forced'
    Config.ForcedEncounter = 'sonar_strike'
    dofile('shared/util.lua')
    dofile('shared/encounters.lua')
    local saved = {}
    Store = {
        SaveSetting = function(key, value) saved[#saved + 1] = { key = key, value = value }; return true end,
        UpsertZone = function() return 7 end, DeleteZone = function() return true end,
        SaveFish = function() return true end, DeleteFish = function() return true end,
        SaveEquipment = function() return true end, ResetDomain = function() return true end,
        zonesPayloadWithId = function() return {} end,
    }
    _G.exports = { zcore_lib = {
        IsAdmin = function() return isAdminResult end,
        Notify = function() end,
    } }
    dofile('server/admin.lua')
    return saved
end

test('A4 getConfig exposes both settings and the registry, so the UI hardcodes nothing', function()
    loadAdmin(true)
    local cfg = H.CB['zfishing:admin:getConfig'](5)
    truthy(cfg)
    equal(cfg.settings.EncounterMode, 'forced', 'the panel cannot show a value it was never sent')
    equal(cfg.settings.ForcedEncounter, 'sonar_strike')
    truthy(cfg.encounters, 'the registry must travel to the admin UI or TypeScript will grow a second copy')
    truthy(cfg.encounters.modes.random)
    truthy(cfg.encounters.forceable.counter_pull)
    falsy(cfg.encounters.forceable.legacy_tension)
    equal(cfg.encounters.recommended.steady_heavy, 'fish_mindgame')
end)

test('A5 a non-admin cannot read the config or write either encounter setting', function()
    local saved = loadAdmin(false)
    equal(H.CB['zfishing:admin:getConfig'](5), nil)
    local a = H.CB['zfishing:admin:saveSetting'](5, 'EncounterMode', 'forced')
    equal(a.ok, false); equal(a.err, 'denied')
    local b = H.CB['zfishing:admin:saveSetting'](5, 'ForcedEncounter', 'sonar_strike')
    equal(b.ok, false)
    equal(#saved, 0, 'a denied write must never reach the data layer')
end)

test('A6 an admin write reaches the store under the right key', function()
    local saved = loadAdmin(true)
    truthy(H.CB['zfishing:admin:saveSetting'](5, 'EncounterMode', 'random').ok)
    equal(#saved, 1)
    equal(saved[1].key, 'EncounterMode')
    equal(saved[1].value, 'random')
end)

H.run()
