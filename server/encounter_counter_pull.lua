-- Counter-Pull Fight.
--
-- The fish telegraphs a direction; the player counters it. The server owns which
-- direction it is, when the window opens and closes, and what every action cost --
-- the client is told what to draw and nothing more. In particular the render payload
-- never carries `required`: a player derives the counter from the cue, which is the
-- game, but handing an auto-counter bot the answer costs an honest client nothing.
--
-- Two things about time in here. State is ABSOLUTE server milliseconds, because that
-- is what an incoming action is judged against. Renders are RELATIVE durations,
-- because the client's GetGameTimer() is a different clock entirely and no arithmetic
-- between the two means anything.

local M = {}

-- Difficulty tiers. Times in ms; stamina and line are pools.
local TIERS = {
    [1] = { telegraph = 900, window = 1400, perFatigue = 3, reels = 2, stamina = 100, line = 100, mistake = 20, maxMisses = 6, fake = 0.00 },
    [2] = { telegraph = 800, window = 1200, perFatigue = 3, reels = 2, stamina = 120, line = 100, mistake = 22, maxMisses = 5, fake = 0.00 },
    [3] = { telegraph = 650, window = 1000, perFatigue = 4, reels = 3, stamina = 150, line = 90,  mistake = 25, maxMisses = 5, fake = 0.10 },
    [4] = { telegraph = 520, window = 850,  perFatigue = 4, reels = 3, stamina = 180, line = 85,  mistake = 28, maxMisses = 4, fake = 0.18 },
    [5] = { telegraph = 420, window = 700,  perFatigue = 5, reels = 3, stamina = 220, line = 80,  mistake = 30, maxMisses = 4, fake = 0.25 },
}

-- Both window edges are forgiving by this much. Network jitter must never turn an
-- honest counter into a miss -- the same reason Config.Timings.hookLatency exists.
local GRACE = 250
local FATIGUE_WINDOW = 2500
local LANDING_MULT = 1.5
local STAMINA_PER_COUNTER = 8
local STAMINA_PER_REEL = 12
local MISS_RECOVERY = 3
local LANDING_RECOVERY = 25
-- A fake must flip at least this long before the window shuts, so the switch is always
-- something a watching player can react to rather than unavoidable RNG.
local FAKE_LEAD = 400

local COUNTER = { LEFT_RUN = 'right', RIGHT_RUN = 'left', DIVE = 'brace' }
local RUNS = { 'LEFT_RUN', 'RIGHT_RUN', 'DIVE' }

-- Keyed on the four behavior names that actually exist in config/fish.lua.
local BEHAVIOR = {
    steady_light = { LEFT_RUN = 5, RIGHT_RUN = 5, DIVE = 1 },
    steady_heavy = { LEFT_RUN = 2, RIGHT_RUN = 2, DIVE = 7 },
    run_stop     = { LEFT_RUN = 4, RIGHT_RUN = 4, DIVE = 2 },
    erratic      = { LEFT_RUN = 3, RIGHT_RUN = 3, DIVE = 3 },
}

-- Seeded LCG rather than math.random: the fight has to be reproducible from the
-- challenge seed alone, so a test can pin one and a desync can be investigated.
local function rand(st)
    st.rng = (1103515245 * st.rng + 12345) % 2147483648
    return st.rng / 2147483648
end

local function pickRun(st)
    local w = BEHAVIOR[st.behavior] or BEHAVIOR.steady_light
    local total = 0
    for _, name in ipairs(RUNS) do total = total + (w[name] or 1) end
    local r = rand(st) * total
    for _, name in ipairs(RUNS) do
        r = r - (w[name] or 1)
        if r <= 0 then return name end
    end
    return RUNS[#RUNS]
end

-- Every arm* below bumps phaseId. Phase name and window lengths repeat exactly -- an
-- id does not, and the NUI re-anchors its clock on it. Without this, two consecutive
-- identical LEFT_RUN phases leave React's effects thinking nothing happened, so the
-- window bar never restarts and the no-input `advance` never re-arms.
local function bump(st)
    st.phaseId = (st.phaseId or 0) + 1
end

local function armRun(st, now)
    bump(st)
    st.phase = pickRun(st)
    st.required = COUNTER[st.phase]
    st.telegraphAt = now
    st.windowOpensAt = now + st.tier.telegraph
    st.windowClosesAt = st.windowOpensAt + st.window
    st.deadline = st.windowClosesAt + GRACE
    st.reelsLeft = nil
    st.cue, st.switchAt, st.nextCue = st.phase, nil, nil

    if st.tier.fake > 0 and rand(st) < st.tier.fake then
        -- Show a different direction first, then visibly flip to the real one.
        local decoy = pickRun(st)
        if decoy ~= st.phase then
            st.cue = decoy
            st.nextCue = st.phase
            st.switchAt = st.windowClosesAt - math.max(FAKE_LEAD, math.floor(st.window * 0.5))
        end
    end
end

local function armFatigue(st, now, reelsLeft)
    bump(st)
    st.phase = 'FATIGUED'
    st.required = 'reel'
    -- The break the fish just took resets the count toward the next one. Tracking
    -- "counters since the last break" rather than "counters % perFatigue" is what stops
    -- a fumbled landing from dropping straight back into another break: with a modulo
    -- the total is still divisible, so the fight would stall instead of resuming.
    st.countersSinceFatigue = 0
    st.telegraphAt = now
    st.windowOpensAt = now
    st.windowClosesAt = now + FATIGUE_WINDOW
    st.deadline = st.windowClosesAt + GRACE
    st.reelsLeft = reelsLeft or st.tier.reels
    st.cue, st.switchAt, st.nextCue = 'FATIGUED', nil, nil
end

local function armLanding(st, now)
    bump(st)
    st.phase = 'LANDING'
    st.required = 'reel'
    st.telegraphAt = now
    st.windowOpensAt = now
    st.windowClosesAt = now + math.floor(st.window * LANDING_MULT)
    st.deadline = st.windowClosesAt + GRACE
    st.reelsLeft = nil
    st.cue, st.switchAt, st.nextCue = 'LANDING', nil, nil
end

M.actions = { left = true, right = true, brace = true, reel = true }

function M.build(ctx)
    local tier = TIERS[ZUtil.clamp(math.floor(ctx.difficulty or 1), 1, 5)]
    local gear = ctx.gear or {}
    local drain = gear.reelDrain or 1.0
    local window = math.floor(tier.window * (1 + (gear.greenZone or 0)))

    local st = {
        rng = (ctx.seed or 1) % 2147483648,
        tier = tier,
        window = window,
        behavior = (ctx.fish or {}).behavior or 'steady_light',
        maxStamina = tier.stamina,
        stamina = tier.stamina,
        maxLine = math.floor(tier.line * Encounters.LineMult(gear.lineRating or 10)),
        perCounter = STAMINA_PER_COUNTER * drain,
        perReel = STAMINA_PER_REEL * drain,
        counters = 0, countersSinceFatigue = 0, misses = 0, phaseId = 0,
    }
    st.line = st.maxLine
    armRun(st, ctx.now or 0)

    -- Worst honest fight: every counter landed, plus a full miss budget, plus one
    -- fatigue break per `perFatigue` counters, plus the landing window. Computed at
    -- drainRate 1.0 so a cheap reel still fits inside the deadline.
    local counters = math.ceil(tier.stamina / STAMINA_PER_COUNTER)
    local estimate = (counters + tier.maxMisses) * (tier.telegraph + window)
        + math.ceil(counters / tier.perFatigue) * FATIGUE_WINDOW
        + math.floor(window * LANDING_MULT)

    return st, estimate
end

-- Durations, never timestamps. See the header.
function M.render(enc, now)
    local st = enc.state
    return {
        phaseId = st.phaseId,
        phase = st.phase,
        cue = st.cue, nextCue = st.nextCue,
        telegraphIn = st.telegraphAt - now,
        windowOpensIn = st.windowOpensAt - now,
        windowClosesIn = st.windowClosesAt - now,
        switchIn = st.switchAt and (st.switchAt - now) or nil,
        staminaPct = math.max(0, math.floor(st.stamina / st.maxStamina * 100)),
        linePct = math.max(0, math.floor(st.line / st.maxLine * 100)),
        misses = st.misses, maxMisses = st.tier.maxMisses,
        reelsLeft = st.reelsLeft,
        -- `required` is deliberately absent. See the header.
    }
end

function M.act(enc, action, now)
    local st = enc.state

    -- `advance` means the player's window expired. Everything else is judged on both
    -- WHAT was pressed and WHEN -- the right key outside the window is still a miss.
    local hit
    if action == 'advance' then
        hit = false
    elseif now < st.windowOpensAt - GRACE or now > st.windowClosesAt + GRACE then
        hit = false
    else
        hit = (action == st.required)
    end

    if hit then
        if st.phase == 'LANDING' then
            st.stamina = 0
            return { render = M.render(enc, now), outcome = 'success', value = 1 }
        elseif st.phase == 'FATIGUED' then
            st.stamina = st.stamina - st.perReel
            st.reelsLeft = (st.reelsLeft or 1) - 1
        else
            st.stamina = st.stamina - st.perCounter
            st.counters = st.counters + 1
            st.countersSinceFatigue = st.countersSinceFatigue + 1
        end
    else
        st.misses = st.misses + 1
        st.line = st.line - st.tier.mistake
        if st.phase == 'LANDING' then
            -- A second wind, and a clean slate toward the next break: the fish just had
            -- one, so dropping straight back into another reads as the fight stalling.
            st.stamina = LANDING_RECOVERY
            st.countersSinceFatigue = 0
        else
            st.stamina = math.min(st.maxStamina, st.stamina + MISS_RECOVERY)
        end
    end

    if st.line <= 0 then
        return { render = M.render(enc, now), outcome = 'snap', value = hit and 1 or 0 }
    end
    if st.misses >= st.tier.maxMisses then
        return { render = M.render(enc, now), outcome = 'escape', value = hit and 1 or 0 }
    end

    if st.stamina <= 0 then
        armLanding(st, now)
    elseif st.phase == 'FATIGUED' and (st.reelsLeft or 0) > 0 then
        armFatigue(st, now, st.reelsLeft)      -- same break, fresh window
    elseif st.phase ~= 'FATIGUED' and st.countersSinceFatigue >= st.tier.perFatigue then
        armFatigue(st, now)
    else
        armRun(st, now)
    end

    return { render = M.render(enc, now), outcome = nil, value = hit and 1 or 0 }
end

Encounter.Register('counter_pull', M)
