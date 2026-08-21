-- Fish Mindgame.
--
-- Read, decide, counter. The fish telegraphs an action; the player picks one of four
-- responses. Difficulty here is knowing WHAT to answer, not answering fast -- so every
-- turn opens with a telegraph nobody may answer into, and once the window is open an
-- answer at the first accepted millisecond is worth exactly what one at the last is.
--
-- Three of the four behaviours are fixed chains rather than random draws. That is the
-- point of the encounter: a player who has fought a catfish before knows it dives twice
-- and then rests, and that knowledge is worth something. Nothing but the turn itself may
-- advance a chain -- see pickDecoy.
--
-- What a fight costs in reads is the tier and nothing else. Gear buys survival: line to
-- spend on mistakes, a wider landing turn, more line back from a rest. It never buys a
-- shorter fight, because the count of reads is this encounter's entire content.
--
-- Same time discipline as counter_pull: state absolute, renders relative.

local M = {}

-- `turns` is how many correct reads the fight costs, and the only lever that changes
-- fight LENGTH. `decision` is thinking time. `line`, `escape` and `mistake` are what a
-- wrong read costs.
local TIERS = {
    [1] = { turns = 3, decision = 2400, line = 100, escape = 3, mistake = 30, fake = 0.00 },
    [2] = { turns = 4, decision = 2200, line = 100, escape = 3, mistake = 30, fake = 0.00 },
    [3] = { turns = 5, decision = 2000, line = 90,  escape = 3, mistake = 30, fake = 0.10 },
    [4] = { turns = 7, decision = 1800, line = 85,  escape = 3, mistake = 30, fake = 0.20 },
    [5] = { turns = 9, decision = 1600, line = 80,  escape = 3, mistake = 30, fake = 0.25 },
}

-- Both window edges are forgiving by this much, for the same reason counter_pull's are:
-- network jitter must never turn an honest answer into a miss.
local GRACE = 250
-- Every turn opens with a telegraph the player watches and cannot answer into. It is a
-- constant, not a tier field: a faking turn that ran longer than an honest one would be
-- detectable with a stopwatch instead of by reading the fish.
local TELEGRAPH = 1400
-- A fake flips here, which leaves the real action on screen for TELEGRAPH - FLIP_AT -
-- GRACE = 550ms before the earliest answer the server will accept. That margin is the
-- whole fairness argument: nobody is ever scored against an action the UI was not
-- showing them. It also means the fake protects nothing against a modified client -- it
-- is presentation, and ARCHITECTURE 12.11 says so out loud.
local FLIP_AT = 600
local DIVE_MULT = 1.5
-- Line a well-answered REST hands back, before the reel multiplier.
local REST_LINE = 12

local CORRECT = { RUN = 'give_line', DIVE = 'brace', THRASH = 'hold',
                  JUMP = 'give_line', REST = 'reel', LANDING = 'reel' }

local ACTIONS = { 'RUN', 'DIVE', 'THRASH', 'JUMP', 'REST' }

-- Fixed cycles for the three readable behaviours; erratic draws instead.
local CHAINS = {
    steady_light = { 'RUN', 'REST', 'RUN', 'THRASH' },
    steady_heavy = { 'DIVE', 'DIVE', 'REST' },
    run_stop     = { 'RUN', 'RUN', 'REST' },
}
local ERRATIC = { { 'RUN', 3 }, { 'DIVE', 3 }, { 'THRASH', 2 }, { 'JUMP', 2 }, { 'REST', 2 } }

-- Seeded LCG rather than math.random: the fight has to be reproducible from the challenge
-- seed alone, so a test can pin one and a desync can be investigated.
local function rand(st)
    st.rng = (1103515245 * st.rng + 12345) % 2147483648
    return st.rng / 2147483648
end

-- Advances the fish's authoritative behaviour. Called exactly once per turn, from nowhere
-- else.
local function nextAction(st)
    local chain = CHAINS[st.behavior]
    if chain then
        st.chainAt = (st.chainAt % #chain) + 1
        return chain[st.chainAt]
    end
    local total = 0
    for _, e in ipairs(ERRATIC) do total = total + e[2] end
    local r = rand(st) * total
    for _, e in ipairs(ERRATIC) do
        r = r - e[2]
        if r <= 0 then return e[1] end
    end
    return ERRATIC[#ERRATIC][1]
end

-- Presentation only, and deliberately NOT nextAction. Drawing a decoy from the chain would
-- consume the fish's next real move, so "dives twice then rests" would silently become
-- "dives once then rests" on any turn that happened to fake -- and that chain is the
-- encounter's entire premise.
local function pickDecoy(st, real)
    local pool = {}
    for _, a in ipairs(ACTIONS) do
        if a ~= real then pool[#pool + 1] = a end
    end
    return pool[math.floor(rand(st) * #pool) + 1]
end

-- Every arm bumps phaseId. Phase name and window lengths repeat exactly -- an id does not,
-- and the NUI re-anchors its clock on it. Without this two consecutive identical turns
-- leave React's effects thinking nothing happened, so the window bar never restarts and
-- the no-input `advance` never re-arms.
local function armTurn(st, now, action)
    st.phaseId = st.phaseId + 1
    st.phase = action == 'LANDING' and 'LANDING' or 'TURN'
    st.action = action
    st.answer = CORRECT[action]
    st.telegraphAt = now
    -- The landing is not a read, it is the payoff, so it opens at once and carries no
    -- telegraph to watch.
    local lead = action == 'LANDING' and 0 or TELEGRAPH
    st.windowOpensAt = now + lead
    st.windowClosesAt = st.windowOpensAt
        + (action == 'LANDING' and st.landingWindow or st.decision)
    st.deadline = st.windowClosesAt + GRACE
    st.cue, st.switchAt, st.nextCue = action, nil, nil

    if lead > 0 and st.tier.fake > 0 and rand(st) < st.tier.fake then
        st.cue = pickDecoy(st, action)
        st.nextCue = action
        st.switchAt = now + FLIP_AT
    end
end

M.actions = { give_line = true, brace = true, hold = true, reel = true }

function M.build(ctx)
    local tier = TIERS[ZUtil.clamp(math.floor(ctx.difficulty or 1), 1, 5)]
    local gear = ctx.gear or {}
    local drain = gear.reelDrain or 1.0

    local st = {
        rng = (ctx.seed or 1) % 2147483648,
        tier = tier,
        behavior = (ctx.fish or {}).behavior or 'steady_light',
        chainAt = 0,
        -- The rod widens thinking time. Nothing widens, or narrows, the read count.
        decision = math.floor(tier.decision * (1 + (gear.greenZone or 0))),
        maxLine = math.floor(tier.line * Encounters.LineMult(gear.lineRating or 10)),
        -- The two things a better reel buys, in full: more line back from a rest well
        -- answered, and a wider landing turn. `reads` below is the tier verbatim.
        restLine = math.floor(REST_LINE * drain),
        reads = tier.turns,
        progress = 0,
        pressure = 0, phaseId = 0,
    }
    st.line = st.maxLine
    st.landingWindow = math.floor(st.decision * ZUtil.clamp(drain, 1.0, 1.5))
    armTurn(st, ctx.now or 0, nextAction(st))

    -- Derived from the machine above, not guessed, which is what keeps a long honest
    -- fight from running into Encounter.Begin's expiry.
    --
    -- Every wrong answer spends line or escape risk, so failures are bounded: at most
    -- ceil(maxLine / mistake) - 1 line failures and escape - 1 risk failures can happen
    -- without ending the fight. A fumbled landing costs one risk and one read, so there
    -- are at most escape - 1 of those, and each buys back one read and one landing turn.
    local lineFails = math.ceil(st.maxLine / tier.mistake) - 1
    local riskFails = tier.escape - 1
    local turns = (tier.turns + riskFails)     -- reads, including those re-won after a fumble
        + lineFails + riskFails                -- turns lost to wrong answers
        + tier.escape                          -- landing attempts
    local estimate = turns * (TELEGRAPH + st.decision) + st.landingWindow

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
        -- One number, one meaning: progress is both how tired the fish is and how many
        -- reads are left, so there is no second bar restating it.
        progress = st.progress, reads = st.reads,
        linePct = math.max(0, math.floor(st.line / st.maxLine * 100)),
        pressure = st.pressure, escapeThreshold = st.tier.escape,
        -- `st.answer` is deliberately absent. See the header.
    }
end

function M.act(enc, action, now)
    local st = enc.state

    -- What was pressed and when. Inside the window timing carries no score at all; outside
    -- it nothing counts, and during the telegraph the UI is showing a shut window -- and
    -- on a faking turn may still be showing the decoy, which is exactly why answers are
    -- not taken yet.
    local hit
    if action == 'advance' then
        hit = false
    elseif now < st.windowOpensAt - GRACE or now > st.windowClosesAt + GRACE then
        hit = false
    else
        hit = (action == st.answer)
    end

    if st.phase == 'LANDING' then
        if hit then
            st.progress = st.reads
            return { render = M.render(enc, now), outcome = 'success', value = 1 }
        end
        -- A fumble costs the last read back and a point of escape risk. The risk is what
        -- bounds the retry: without it a player could stall at the net until the whole
        -- encounter expired.
        st.progress = math.max(0, st.reads - 1)
        st.pressure = st.pressure + 1
    elseif hit then
        st.progress = st.progress + 1
        if st.action == 'REST' then
            st.line = math.min(st.maxLine, st.line + st.restLine)
        end
    else
        local a = st.action
        if a == 'RUN' then
            st.line = st.line - st.tier.mistake
        elseif a == 'DIVE' then
            st.line = st.line - math.floor(st.tier.mistake * DIVE_MULT)
        elseif a == 'THRASH' then
            st.pressure = st.pressure + 1
        elseif a == 'JUMP' then
            st.pressure = st.pressure + 2
        else  -- REST
            -- A rest you fail to punish is a rest the fish gets to use. It also has to cost
            -- something bounded, or a player answering every rest wrong would never resolve
            -- the fight at all -- the estimate above depends on this.
            st.pressure = st.pressure + 1
        end
    end

    if st.line <= 0 then
        return { render = M.render(enc, now), outcome = 'snap', value = hit and 1 or 0 }
    end
    if st.pressure >= st.tier.escape then
        return { render = M.render(enc, now), outcome = 'escape', value = hit and 1 or 0 }
    end

    if st.progress >= st.reads then
        armTurn(st, now, 'LANDING')
    else
        armTurn(st, now, nextAction(st))
    end

    return { render = M.render(enc, now), outcome = nil, value = hit and 1 or 0 }
end

Encounter.Register('fish_mindgame', M)
