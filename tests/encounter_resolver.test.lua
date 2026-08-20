-- Encounter registry and resolver. Run from the resource root:
--   node tests/luarun.mjs tests/encounter_resolver.test.lua
--
-- Covers the resolver checklist in
-- docs/superpowers/specs/2026-08-20-zfishing-encounter-system-design.md section 9.1.

dofile('tests/harness.lua')
local test, equal, truthy, falsy = H.test, H.equal, H.truthy, H.falsy

local function loadRegistry()
    H.installHost()
    Config = H.baseConfig()
    dofile('shared/util.lua')
    dofile('shared/encounters.lua')
end

test('R1 the registry sets are internally consistent', function()
    loadRegistry()
    truthy(Encounters.IDS.counter_pull)
    truthy(Encounters.IDS.fish_mindgame)
    truthy(Encounters.IDS.sonar_strike)
    truthy(Encounters.IDS.legacy_tension,
        'legacy must be a registered id so any resolved value is validatable against one set')
    falsy(Encounters.FORCEABLE.legacy_tension,
        'legacy must not be selectable in FORCED mode -- that would be a fourth mode in disguise')
    equal(#Encounters.RANDOM_POOL, 3)
    for _, entry in ipairs(Encounters.RANDOM_POOL) do
        truthy(Encounters.FORCEABLE[entry.id], 'random pool must hold only forceable ids: ' .. tostring(entry.id))
        truthy(entry.weight, 'pool entries carry a weight from day one so weighted random needs no resolver change')
    end
    equal(Encounters.FALLBACK, 'legacy_tension')
    truthy(Encounters.MODES.default); truthy(Encounters.MODES.random); truthy(Encounters.MODES.forced)
    falsy(Encounters.MODES.legacy)
end)

test('R2 TierFor maps the five rarities 1:1 onto the five tiers', function()
    loadRegistry()
    equal(Encounters.TierFor('common', 2, 1, 5), 1)
    equal(Encounters.TierFor('uncommon', 2, 1, 5), 2)
    equal(Encounters.TierFor('rare', 2, 1, 5), 3)
    equal(Encounters.TierFor('epic', 2, 1, 5), 4)
    equal(Encounters.TierFor('legendary', 2, 1, 5), 5)
end)

test('R3 a top-of-range specimen fights one tier harder, capped at 5', function()
    loadRegistry()
    equal(Encounters.TierFor('common', 5, 1, 5), 2, 'a maximum-weight fish steps up a tier')
    equal(Encounters.TierFor('common', 4, 1, 5), 2, 'ratio 0.75 is inclusive')
    equal(Encounters.TierFor('common', 3.9, 1, 5), 1, 'just under the threshold does not step up')
    equal(Encounters.TierFor('legendary', 5, 1, 5), 5, 'tier 5 is the ceiling')
end)

test('R4 TierFor survives unknown rarity and a zero-width weight range', function()
    loadRegistry()
    equal(Encounters.TierFor('mythic', 2, 1, 5), 1, 'an admin-invented rarity must not error')
    equal(Encounters.TierFor('common', 3, 3, 3), 1, 'a zero-width range must not divide by zero')
end)

test('R5 LineMult is exact at the shipped ratings, monotone between them, and clamped', function()
    loadRegistry()
    equal(Encounters.LineMult(10), 1.00)
    equal(Encounters.LineMult(20), 1.15)
    equal(Encounters.LineMult(40), 1.30)
    equal(Encounters.LineMult(60), 1.45)
    equal(Encounters.LineMult(5), 1.00, 'below the lowest anchor clamps rather than extrapolating')
    equal(Encounters.LineMult(500), 1.45, 'an admin-raised rating cannot run off the top of the curve')
    truthy(Encounters.LineMult(30) > Encounters.LineMult(20), 'an edited rating between anchors stays monotone')
    truthy(Encounters.LineMult(30) < Encounters.LineMult(40))
end)

-- ---------------------------------------------------------------- resolver

local function loadResolver(mode, forced)
    H.installHost()
    Config = H.baseConfig()
    if mode ~= nil then Config.EncounterMode = mode end
    -- assigned unconditionally: passing nil must mean "no ForcedEncounter stored",
    -- which is one of the cases R13 exists to cover
    Config.ForcedEncounter = forced
    dofile('shared/util.lua')
    dofile('shared/encounters.lua')
    dofile('server/encounter.lua')
end

local function fishWith(encounter)
    return { species = 'bass', rarity = 'common', behavior = 'steady_light',
             weight = 2.0, encounter = encounter }
end

test('R6 DEFAULT resolves an explicitly configured fish encounter', function()
    loadResolver('default')
    local id, mode = Encounter.Resolve(fishWith('sonar_strike'))
    equal(id, 'sonar_strike')
    equal(mode, 'default')
end)

test('R7 DEFAULT falls back to legacy when the fish has no encounter', function()
    loadResolver('default')
    equal((Encounter.Resolve(fishWith(nil))), 'legacy_tension')
end)

test('R8 DEFAULT falls back to legacy on an unregistered fish encounter', function()
    loadResolver('default')
    equal((Encounter.Resolve(fishWith('boss_fight'))), 'legacy_tension',
        'a future id that is not registered yet must not reach a session')
    equal((Encounter.Resolve(fishWith(42))), 'legacy_tension', 'a non-string must not reach a session')
end)

test('R9 RANDOM only ever returns a pool member and never legacy', function()
    loadResolver('random')
    for _ = 1, 300 do
        local id, mode = Encounter.Resolve(fishWith(nil))
        truthy(Encounters.FORCEABLE[id], 'random returned an id outside the pool: ' .. tostring(id))
        falsy(id == 'legacy_tension', 'legacy must never come out of the random pool')
        equal(mode, 'random')
    end
end)

test('R10 RANDOM can reach every pool entry', function()
    loadResolver('random')
    -- ZUtil.weightedPick is the only no-argument math.random caller here; pinning it
    -- walks the three pool branches deterministically instead of hoping 300 draws
    -- happened to cover them.
    H.withRandom(0.1, function() equal((Encounter.Resolve(fishWith(nil))), 'counter_pull') end)
    H.withRandom(0.5, function() equal((Encounter.Resolve(fishWith(nil))), 'fish_mindgame') end)
    H.withRandom(0.9, function() equal((Encounter.Resolve(fishWith(nil))), 'sonar_strike') end)
end)

test('R11 FORCED returns the configured encounter for every fish', function()
    for _, forced in ipairs({ 'counter_pull', 'fish_mindgame', 'sonar_strike' }) do
        loadResolver('forced', forced)
        equal((Encounter.Resolve(fishWith(nil))), forced, 'unconfigured fish must still be forced')
        equal((Encounter.Resolve(fishWith('counter_pull'))), forced,
            'FORCED must override a fish that configured something else')
        local _, mode = Encounter.Resolve(fishWith(nil))
        equal(mode, 'forced')
    end
end)

test('R12 an invalid EncounterMode falls back to default behaviour', function()
    loadResolver('chaos')
    local id, mode = Encounter.Resolve(fishWith('sonar_strike'))
    equal(mode, 'default', 'an unusable stored mode must degrade to default, not error')
    equal(id, 'sonar_strike', 'and default behaviour still honours the fish')
    loadResolver(false)
    equal((select(2, Encounter.Resolve(fishWith(nil)))), 'default')
end)

test('R13 an invalid ForcedEncounter falls back to legacy, not to a random pick', function()
    loadResolver('forced', 'boss_fight')
    equal((Encounter.Resolve(fishWith(nil))), 'legacy_tension')
    loadResolver('forced', 'legacy_tension')
    equal((Encounter.Resolve(fishWith(nil))), 'legacy_tension',
        'legacy is not forceable, so forcing it lands on the fallback by the same route')
    loadResolver('forced', nil)
    equal((Encounter.Resolve(fishWith(nil))), 'legacy_tension')
end)

H.run()
