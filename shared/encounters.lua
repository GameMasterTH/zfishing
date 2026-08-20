-- The encounter registry. Pure data and pure functions: this file is loaded inside
-- the plain-Lua test VM, so it must not touch a native at load time.
--
-- Adding an encounter later (rhythm_reel, pattern_memory, boss_fight) means adding an
-- id here, a pool entry, and a server/encounter_<id>.lua module. server/session.lua
-- does not change.

Encounters = {}

Encounters.IDS = {
    counter_pull   = true,
    fish_mindgame  = true,
    sonar_strike   = true,
    legacy_tension = true,
}

-- What an admin may pick in FORCED mode. legacy_tension is deliberately absent:
-- forcing it would be a fourth selection mode wearing a third mode's clothes.
Encounters.FORCEABLE = {
    counter_pull  = true,
    fish_mindgame = true,
    sonar_strike  = true,
}

-- A list of {id, weight} from day one, which is exactly the shape ZUtil.weightedPick
-- consumes. Weighted random therefore needs a data edit, never a resolver change.
Encounters.RANDOM_POOL = {
    { id = 'counter_pull',  weight = 1 },
    { id = 'fish_mindgame', weight = 1 },
    { id = 'sonar_strike',  weight = 1 },
}

Encounters.MODES = { default = true, random = true, forced = true }

Encounters.FALLBACK      = 'legacy_tension'
Encounters.FALLBACK_MODE = 'default'

-- DOCUMENTATION AND ADMIN HINT ONLY -- the resolver never reads this. The DEFAULT
-- chain is two steps (explicit fish encounter, then the fallback) so that shipping
-- this framework does not move any fish off the existing fight. See the design doc
-- section 2.1 for why the spec's behavior-based fallback step was dropped.
Encounters.RECOMMENDED = {
    steady_light = 'counter_pull',
    steady_heavy = 'fish_mindgame',
    run_stop     = 'counter_pull',
    erratic      = 'fish_mindgame',
}

local TIER_BY_RARITY = { common = 1, uncommon = 2, rare = 3, epic = 4, legendary = 5 }

-- Difficulty tier 1..5, a pure function of the rolled fish. Deterministic given a
-- roll, so a test can assert a tier without stubbing RNG -- which is what makes the
-- "RANDOM and FORCED preserve fish difficulty" invariants checkable.
--
-- Equipment is deliberately NOT an input. Tier belongs to the fish; gear enters each
-- encounter as its own named knob.
function Encounters.TierFor(rarity, weight, wMin, wMax)
    local t = TIER_BY_RARITY[rarity] or 1
    local lo = tonumber(wMin) or 0
    local span = math.max(0.001, (tonumber(wMax) or 0) - lo)
    local ratio = ((tonumber(weight) or 0) - lo) / span
    if ratio >= 0.75 then t = t + 1 end   -- a big specimen of its species fights harder
    return ZUtil.clamp(t, 1, 5)
end

-- Line health multiplier.
--
-- Deliberately NOT rating/10. The shipped ratings are 10/20/40/60, so that formula
-- gives a 6x pool at 60lb; at tier 5 (base line 80, mistakeDamage 30, maxMisses 4)
-- four mistakes deal 120 damage against a 480 pool, so the fish always escapes on the
-- miss count and every upgrade past 20lb buys nothing an encounter can express.
--
-- Interpolated rather than looked up because Config.Equipment.lines[*].rating is
-- admin-editable (ConfigSchema.EquipmentRanges allows 1..500). A bare lookup would
-- silently hand an edited rating the 1.0 floor -- a better line scoring worse.
local LINE_ANCHORS = { { 10, 1.00 }, { 20, 1.15 }, { 40, 1.30 }, { 60, 1.45 } }

function Encounters.LineMult(rating)
    rating = tonumber(rating) or LINE_ANCHORS[1][1]
    for _, a in ipairs(LINE_ANCHORS) do
        if rating == a[1] then return a[2] end   -- exact at every shipped rating
    end
    if rating <= LINE_ANCHORS[1][1] then return LINE_ANCHORS[1][2] end
    for i = 2, #LINE_ANCHORS do
        local lo, hi = LINE_ANCHORS[i - 1], LINE_ANCHORS[i]
        if rating < hi[1] then
            return lo[2] + ((rating - lo[1]) / (hi[1] - lo[1])) * (hi[2] - lo[2])
        end
    end
    return LINE_ANCHORS[#LINE_ANCHORS][2]
end
