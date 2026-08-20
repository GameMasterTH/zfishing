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
