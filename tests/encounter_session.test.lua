-- The encounter is chosen once, at cast, and frozen into the session. Run from root:
--   node tests/luarun.mjs tests/encounter_session.test.lua

dofile('tests/harness.lua')
local test, equal, truthy, falsy = H.test, H.equal, H.truthy, H.falsy

-- Drives cast -> bite so the bite payload (the only place the client learns which
-- encounter it is playing) can be inspected.
local function castAndBite(src)
    local cast = H.CB['zfishing:cast'](src, 0.5)
    truthy(cast.ok, 'cast should succeed: ' .. tostring(cast.reason))
    H.fireLatestTimer()   -- the bite timer this cast just armed
    return cast, H.lastClientEvent('zfishing:bite')
end

test('S1 the bite payload names the resolved encounter', function()
    H.loadSession({ encounterMode = 'forced', forcedEncounter = 'counter_pull' })
    Encounter.Register('counter_pull', { actions = {} })
    local _, bite = castAndBite(5)
    truthy(bite)
    equal(bite.args[1].encounter, 'counter_pull')
end)

test('S2 an unconfigured fish plays the legacy fight and the payload says so', function()
    H.loadSession({ encounterMode = 'default' })
    local _, bite = castAndBite(5)
    equal(bite.args[1].encounter, 'legacy_tension')
    truthy(bite.args[1].fishEnergy, 'the legacy payload fields must be untouched')
    truthy(bite.args[1].baseDrain)
end)

test('S3 an encounter with no registered module downgrades to legacy', function()
    -- Phase A ships the resolver before any encounter module exists. Without this an
    -- admin setting FORCED=sonar_strike would put every player into a fight nothing
    -- can run.
    H.loadSession({ encounterMode = 'forced', forcedEncounter = 'sonar_strike' })
    local _, bite = castAndBite(5)
    equal(bite.args[1].encounter, 'legacy_tension')
    local id, _, downgraded = Encounter.ResolveForSession({ rarity = 'common' })
    equal(id, 'legacy_tension')
    equal(downgraded, 'sonar_strike', 'the downgrade must be reportable, not silent')
end)

test('S4 registering a module makes that encounter playable', function()
    H.loadSession({ encounterMode = 'forced', forcedEncounter = 'sonar_strike' })
    falsy(Encounter.Playable('sonar_strike'))
    Encounter.Register('sonar_strike', { actions = {} })
    truthy(Encounter.Playable('sonar_strike'))
    truthy(Encounter.Playable('legacy_tension'), 'legacy has no module -- it IS the existing client fight')
    local _, bite = castAndBite(5)
    equal(bite.args[1].encounter, 'sonar_strike')
end)

test('S5 Register refuses an id that is not in the registry', function()
    H.loadSession()
    local ok = pcall(Encounter.Register, 'boss_fight', {})
    falsy(ok, 'a typo in a module id must fail loudly at boot, not silently never run')
end)

test('S6 an admin change mid-session does not touch the fight already in progress', function()
    H.loadSession({ encounterMode = 'default' })
    Encounter.Register('sonar_strike', { actions = {} })
    local cast = H.CB['zfishing:cast'](5, 0.5)
    truthy(cast.ok)

    -- the admin flips the mode after the cast but before the bite
    Config.EncounterMode = 'forced'
    Config.ForcedEncounter = 'sonar_strike'

    H.fireLatestTimer()
    equal(H.lastClientEvent('zfishing:bite').args[1].encounter, 'legacy_tension',
        'the encounter was frozen at cast; the fight in flight must not change under the player')
end)

test('S7 the next cast picks up the new mode', function()
    H.loadSession({ encounterMode = 'default' })
    Encounter.Register('sonar_strike', { actions = {} })
    local first = H.CB['zfishing:cast'](5, 0.5)
    truthy(H.CB['zfishing:cancel'](5, first.sessionId).ok)

    Config.EncounterMode = 'forced'
    Config.ForcedEncounter = 'sonar_strike'

    local _, bite = castAndBite(5)
    equal(bite.args[1].encounter, 'sonar_strike')
end)

test('S8 the frozen difficulty is the fish difficulty, whatever the mode', function()
    local legendary = { species = 'golden', label = 'Golden Fish', weight = 1.9, quality = 5,
        rarity = 'legendary', behavior = 'erratic', biteDelay = 100, hookWindow = 1500,
        tensionDiff = 1.8, fishEnergy = 60, xp = 200, price = 500, difficulty = 5 }
    for _, mode in ipairs({ 'default', 'random', 'forced' }) do
        H.loadSession({ fish = legendary, encounterMode = mode, forcedEncounter = 'counter_pull' })
        Encounter.Register('counter_pull', { actions = {} })
        Encounter.Register('fish_mindgame', { actions = {} })
        Encounter.Register('sonar_strike', { actions = {} })
        local _, bite = castAndBite(5)
        equal(bite.args[1].difficulty, 5,
            mode .. ' must not soften a legendary fish -- only the encounter type may vary')
    end
end)

H.run()
