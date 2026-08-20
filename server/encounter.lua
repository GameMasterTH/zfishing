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

-- ---------------------------------------------------------------- challenge lifecycle

-- session.lua injects its own accessor and its own flood gate here at load. The
-- encounter code never touches the sessions table directly: every lookup has to go
-- through the same token check the rest of the state machine uses.
Encounter.Session = nil
Encounter.Gate = nil

local MIN_DEADLINE = 15000
local MAX_DEADLINE = 120000

-- Builds the challenge. Called at hook time, not at cast: the type and tier were
-- frozen at cast (session.lua), the fight state starts when the fight does.
function Encounter.Begin(s, gear)
    local mod = Encounter.MODULES[s.encounter.type]
    if not mod then return nil end

    local state, estimate = mod.build({
        difficulty = s.encounter.difficulty,
        seed       = math.random(1, 2147483647),
        fish       = s.fish,
        gear       = gear or {},
    })

    local now = GetGameTimer()
    s.encounter.challengeId = s.id .. '#' .. math.random(100000, 999999)
    s.encounter.seq       = 0
    s.encounter.state     = state
    s.encounter.startedAt = now
    s.encounter.expiresAt = now + ZUtil.clamp((estimate or 0) * 1.75, MIN_DEADLINE, MAX_DEADLINE)
    s.encounter.outcome   = nil
    s.encounter.perf      = { sum = 0, actions = 0 }

    -- ONE timer, not a tick loop. Per-turn deadlines are evaluated lazily when the
    -- next action arrives; this is only the backstop for a fight nobody finishes.
    -- Guarded on object identity for the same reason the bite and hook timers are: the
    -- src may belong to somebody else by the time it fires.
    local fish = s.fish
    SetTimeout(s.encounter.expiresAt - now + 500, function()
        local live = Encounter.Session and Encounter.Session(s.id)
        if not live or live.fish ~= fish or not live.encounter then return end
        if live.encounter.outcome == nil then live.encounter.outcome = 'timeout' end
    end)

    return s.encounter.challengeId
end

-- Normalized outcomes. Anything an encounter module reports has to be one of these --
-- reward logic never sees an encounter-internal failure name.
local OUTCOMES = { success = true, escape = true, snap = true, timeout = true }

local function evaluate(s, action, now)
    local enc = s.encounter
    local mod = Encounter.MODULES[enc.type]
    local res = mod.act(enc, action, now) or {}

    if res.outcome ~= nil and not OUTCOMES[res.outcome] then
        -- A module bug must not leak a made-up reason into settlement.
        print(('[zfishing] encounter %s reported an unknown outcome %s; treating it as escape')
            :format(enc.type, tostring(res.outcome)))
        res.outcome = 'escape'
    end

    if res.value ~= nil then
        enc.perf.sum = enc.perf.sum + res.value
        enc.perf.actions = enc.perf.actions + 1
    end
    if res.outcome then enc.outcome = res.outcome end
    return res
end

-- The mean quality of the actions the player actually took, 0..1. Every module scores
-- its own actions on that scale so a flawless fight is 1.0 in all of them -- otherwise
-- identical skill would pay different XP depending on which encounter RANDOM handed out.
function Encounter.PerfScore(enc)
    if not enc or not enc.perf or enc.perf.actions == 0 then return 0 end
    return ZUtil.clamp(enc.perf.sum / enc.perf.actions, 0, 1)
end

lib.callback.register('zfishing:encounter:act', function(src, sessionId, challengeId, seq, action)
    if not Encounter.Gate or not Encounter.Gate(src) then
        return { ok = false, reason = 'too_many_requests' }
    end

    local s = Encounter.Session and Encounter.Session(sessionId, src)
    if not s then return { ok = false, reason = 'invalid_session' } end

    local enc = s.encounter
    if not enc or enc.type == Encounters.FALLBACK or not enc.challengeId then
        return { ok = false, reason = 'no_encounter' }
    end
    if enc.challengeId ~= challengeId then return { ok = false, reason = 'stale_challenge' } end
    if enc.outcome ~= nil then return { ok = false, reason = 'encounter_over', outcome = enc.outcome } end

    local now = GetGameTimer()
    if now > enc.expiresAt then
        enc.outcome = 'timeout'
        return { ok = false, reason = 'encounter_over', outcome = 'timeout' }
    end

    local mod = Encounter.MODULES[enc.type]
    if action == 'advance' then
        -- The universal "my window expired" action. Accepted only once the deadline has
        -- genuinely passed, so a client cannot use it to skip a window it still owns --
        -- and refusing to send it only starves the player into the expiry above.
        if type(enc.state.deadline) ~= 'number' or now < enc.state.deadline then
            return { ok = false, reason = 'bad_action', seq = enc.seq }
        end
    elseif not (mod.actions and mod.actions[action]) then
        -- A structurally invalid action. An action that is well-formed but wrong for
        -- the current state is NOT this -- that is a miss, and the module scores it.
        return { ok = false, reason = 'bad_action', seq = enc.seq }
    end

    -- One comparison covering every sequencing attack: a duplicate is not seq+1, an
    -- older one is not seq+1, a fabricated future one is not seq+1. A previously
    -- successful action can never be replayed because its seq is behind.
    if type(seq) ~= 'number' or seq ~= enc.seq + 1 then
        return { ok = false, reason = 'bad_seq', seq = enc.seq }
    end
    enc.seq = seq

    local res = evaluate(s, action, now)
    return { ok = true, seq = enc.seq, state = res.render, outcome = enc.outcome }
end)
