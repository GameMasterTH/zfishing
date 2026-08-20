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

H.run()
