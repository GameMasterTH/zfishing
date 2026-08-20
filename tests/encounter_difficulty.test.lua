-- Difficulty tiers on the roll, and the invariant that selection mode never touches
-- them. Run from the resource root:
--   node tests/luarun.mjs tests/encounter_difficulty.test.lua

dofile('tests/harness.lua')
local test, equal, truthy = H.test, H.equal, H.truthy

-- One species only, so the weighted pick is forced and the roll is predictable.
local function loadGenerator(species, def)
    H.installHost()
    Config = H.baseConfig()
    Config.Fish = { [species] = def }
    dofile('shared/util.lua')
    dofile('shared/encounters.lua')
    dofile('server/generator.lua')
end

local BASS = { label = 'Bass', water = { 'ocean' }, weight = { min = 1.0, max = 5.0 },
    rarity = 'common', price = 8, baits = { 'worm' }, behavior = 'steady_light', xp = 10 }
local MARLIN = { label = 'Marlin', water = { 'ocean' }, weight = { min = 40.0, max = 200.0 },
    rarity = 'legendary', price = 500, baits = { 'topwater' }, behavior = 'erratic', xp = 200 }

local function roll(randomValue)
    local out
    H.withRandom(randomValue, function()
        out = Generator.Roll(5, { water = 'ocean', rod = 'fishing_rod_common', hook = 'hook_4', bait = 'worm' })
    end)
    return out
end

test('D1 the roll carries a difficulty tier next to the tension multiplier', function()
    loadGenerator('bass', BASS)
    local f = roll(0.0)   -- ZUtil.randFloat -> min weight
    truthy(f)
    equal(f.difficulty, 1, 'a mid-to-low common fish is tier 1')
    equal(f.tensionDiff, 1.0, 'the existing field is untouched')
end)

test('D2 a top-of-range specimen rolls one tier harder', function()
    loadGenerator('bass', BASS)
    equal(roll(1.0).difficulty, 2, 'a 5.0kg bass in a 1.0-5.0 range is a big one')
end)

test('D3 a legendary fish is tier 5 and cannot exceed it', function()
    loadGenerator('marlin', MARLIN)
    equal(roll(0.0).difficulty, 5)
    equal(roll(1.0).difficulty, 5, 'the cap holds for a maximum-weight legendary')
end)

test('D4 selection mode never changes the tier -- RANDOM and FORCED preserve it', function()
    -- The invariant the whole difficulty-normalization design exists to protect:
    -- the encounter TYPE may change with the mode, the fish's difficulty may not.
    local tiers = {}
    for _, mode in ipairs({ 'default', 'random', 'forced' }) do
        loadGenerator('marlin', MARLIN)
        Config.EncounterMode = mode
        Config.ForcedEncounter = 'counter_pull'
        dofile('server/encounter.lua')
        local f = roll(0.5)
        local id = Encounter.Resolve(f)
        truthy(Encounters.IDS[id])
        tiers[#tiers + 1] = f.difficulty
    end
    equal(tiers[1], tiers[2], 'RANDOM must not soften a legendary fish')
    equal(tiers[2], tiers[3], 'FORCED must not soften a legendary fish')
    equal(tiers[1], 5)
end)

H.run()
