-- The encounter resolver and the encounter challenge lifecycle.
--
-- This file owns the ONE path by which an encounter type is chosen. session.lua
-- freezes the answer into the session at cast time and every later read comes from
-- the session -- nothing re-reads Config.EncounterMode during a fight, which is what
-- makes an admin's hot change leave in-flight fights alone.

Encounter = {}

-- Selection policy only. A stored value that is unusable degrades to the safe option
-- rather than raising: a bad row in zfishing_settings must never stop players fishing.
function Encounter.Resolve(fish)
    local mode = Encounters.MODES[Config.EncounterMode] and Config.EncounterMode
        or Encounters.FALLBACK_MODE

    if mode == 'forced' then
        local forced = Config.ForcedEncounter
        return Encounters.FORCEABLE[forced] and forced or Encounters.FALLBACK, mode
    end

    if mode == 'random' then
        return ZUtil.weightedPick(Encounters.RANDOM_POOL).id, mode
    end

    local wanted = fish and fish.encounter
    return Encounters.IDS[wanted] and wanted or Encounters.FALLBACK, mode
end

-- Encounter modules register themselves as they load. legacy_tension has no module:
-- it IS the existing client-side tension fight, driven by client/minigame.lua.
Encounter.MODULES = {}

function Encounter.Register(id, mod)
    if not Encounters.IDS[id] then
        error('encounter module registered under an unregistered id: ' .. tostring(id))
    end
    Encounter.MODULES[id] = mod
end

function Encounter.Playable(id)
    return id == Encounters.FALLBACK or Encounter.MODULES[id] ~= nil
end

-- Selection, then availability. The two are separate because the encounters ship one
-- phase at a time: an admin who forces an encounter whose module is not deployed yet
-- must get the legacy fight, not a fight nothing can run. `downgradedFrom` is returned
-- so the console can say what happened instead of quietly disagreeing with the panel.
function Encounter.ResolveForSession(fish)
    local id, mode = Encounter.Resolve(fish)
    if not Encounter.Playable(id) then
        return Encounters.FALLBACK, mode, id
    end
    return id, mode, nil
end
