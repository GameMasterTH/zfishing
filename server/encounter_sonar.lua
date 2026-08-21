-- Sonar Strike.
--
-- The client reports that it struck, never when it believes it struck. The server owns
-- the pass timeline and grades arrival time after a bounded compensation frozen when
-- that pass armed; sampling ping on arrival would create a bounded timing lever.

local M = {}
Sonar = Sonar or {}

local TIERS = {
    [1] = { requiredHits = 2, maxMisses = 3, duration = 4000, weakHalf = 0.18, perfectHalf = 0.07 },
    [2] = { requiredHits = 3, maxMisses = 3, duration = 3600, weakHalf = 0.15, perfectHalf = 0.06 },
    [3] = { requiredHits = 3, maxMisses = 2, duration = 3200, weakHalf = 0.12, perfectHalf = 0.05 },
    [4] = { requiredHits = 4, maxMisses = 2, duration = 2800, weakHalf = 0.10, perfectHalf = 0.04 },
    [5] = { requiredHits = 5, maxMisses = 2, duration = 2400, weakHalf = 0.08, perfectHalf = 0.03 },
}

local TARGET = 0.5
local INTERVAL = 700
local GRACE = 250
local MAX_COMPENSATION = 200
local MIN_PERFECT_MS = 90
local MIN_WEAK_MS = 240
local MIN_DECOY_SEPARATION = 550
local HOLD_JITTER = 0.06

local PROFILES = {
    steady_light = { name = 'DART',    k = -0.40, hold = 0.00 },
    steady_heavy = { name = 'HEAVY',   k =  0.50, hold = 0.00 },
    run_stop     = { name = 'STALKER', k = -0.30, hold = 0.35 },
    erratic      = { name = 'GHOST',   k =  0.00, hold = 0.00 },
}

local FLOAT_TIER = { float_wood = 1, float_foam = 2, float_smart = 3 }

local function rand(st)
    st.rng = (1103515245 * st.rng + 12345) % 2147483648
    return st.rng / 2147483648
end

-- `t` is elapsed milliseconds in this pass, never a client timestamp.
function Sonar.WeakAt(pass, t)
    local travel = pass.duration - pass.hold
    local u = (t - pass.hold) / travel
    if u < 0 then u = 0 elseif u > 1 then u = 1 end
    local c = u - 0.5
    local f = 0.5 + (1 - pass.k) * c + 4 * pass.k * c * c * c
    return pass.dir > 0 and f or (1 - f)
end

function Sonar.TargetSpeed(pass)
    return (1 - pass.k) / (pass.duration - pass.hold)
end

local function armPass(st, now, ping)
    st.phaseId = st.phaseId + 1
    st.attempt = st.attempt + 1

    local profile = st.profileDef
    st.dir = rand(st) < 0.5 and 1 or -1
    st.k = profile.k
    local holdFrac = profile.hold + (rand(st) - 0.5) * 2 * HOLD_JITTER
    st.hold = math.floor(st.duration * ZUtil.clamp(holdFrac, 0, 0.5))

    st.compensationMs = ZUtil.clamp((ping or 0) * 0.5, 0, MAX_COMPENSATION)

    local speed = Sonar.TargetSpeed(st)
    st.weakHalf = math.max(st.tier.weakHalf * (1 + st.greenZone), MIN_WEAK_MS * speed)
    st.perfectHalf = math.max(st.tier.perfectHalf, MIN_PERFECT_MS * speed)
    st.perfectHalf = math.min(st.perfectHalf, st.weakHalf * 0.8)

    st.decoy = nil
    if st.canDecoy and profile.name == 'GHOST' then
        -- Shape alone cannot make a false opportunity: every easing curve crosses the
        -- target at its own midpoint. Give the decoy an independent crossing instead.
        local realCross = st.hold + (st.duration - st.hold) * 0.5
        local lo, hi = 200, st.duration - 200
        local early, late = realCross - MIN_DECOY_SEPARATION, realCross + MIN_DECOY_SEPARATION
        local crossAt
        if early > lo and (late > hi or rand(st) < 0.5) then
            crossAt = lo + rand(st) * (early - lo)
        else
            crossAt = late + rand(st) * math.max(0, hi - late)
        end
        crossAt = math.floor(crossAt)
        st.decoy = {
            k = (rand(st) - 0.5) * 0.8,
            dir = rand(st) < 0.5 and 1 or -1,
            hold = 0,
            duration = 2 * crossAt,
            crossAt = crossAt,
        }
    end

    st.passStartAt = now + INTERVAL
    st.passEndAt = st.passStartAt + st.duration
    st.deadline = st.passEndAt + GRACE
end

M.actions = { strike = true }

function M.build(ctx)
    local tierIndex = ZUtil.clamp(math.floor(ctx.difficulty or 1), 1, 5)
    local tier = TIERS[tierIndex]
    local gear = ctx.gear or {}
    local behavior = (ctx.fish or {}).behavior or 'steady_light'
    local st = {
        rng = (ctx.seed or 1) % 2147483648,
        tier = tier,
        tierIndex = tierIndex,
        profileDef = PROFILES[behavior] or PROFILES.steady_light,
        duration = tier.duration,
        greenZone = gear.greenZone or 0.0,
        floatTier = FLOAT_TIER[gear.float] or 1,
        hits = 0, misses = 0, attempt = 0, phaseId = 0,
        lastGrade = nil,
    }
    st.profile = st.profileDef.name
    st.canDecoy = tierIndex >= 4
    st.maxAttempts = tier.requiredHits + tier.maxMisses - 1
    armPass(st, ctx.now or 0, ctx.ping)

    -- Every scored pass spends one bounded attempt; only a client no-op during the
    -- reacquire gap does not, and it also costs no time in this bound.
    return st, st.maxAttempts * (INTERVAL + tier.duration)
end

function M.render(enc, now)
    local st = enc.state
    return {
        phaseId = st.phaseId,
        attempt = st.attempt, maxAttempts = st.maxAttempts,
        hits = st.hits, requiredHits = st.tier.requiredHits,
        misses = st.misses, maxMisses = st.tier.maxMisses,
        passStartsIn = st.passStartAt - now,
        passEndsIn = st.passEndAt - now,
        duration = st.duration, hold = st.hold,
        profile = st.profile, dir = st.dir, k = st.k,
        weakHalf = st.weakHalf, perfectHalf = st.perfectHalf,
        target = TARGET,
        decoy = st.decoy,
        floatTier = st.floatTier,
        lastGrade = st.lastGrade,
    }
end

function M.act(enc, action, now, meta)
    local st = enc.state
    local grade
    if action == 'advance' then
        grade = 'miss'
    else
        local strikeAt = now - (st.compensationMs or 0)
        local elapsed = strikeAt - st.passStartAt
        if elapsed < 0 then
            local frame = M.render(enc, now)
            frame.notReady = true
            return { render = frame }
        elseif elapsed > st.duration then
            grade = 'miss'
        else
            local distance = math.abs(Sonar.WeakAt(st, elapsed) - TARGET)
            if distance <= st.perfectHalf then grade = 'perfect'
            elseif distance <= st.weakHalf then grade = 'safe'
            else grade = 'miss' end
        end
    end

    st.lastGrade = grade
    local value
    if grade == 'miss' then
        st.misses = st.misses + 1
        value = 0
    else
        st.hits = st.hits + 1
        value = grade == 'perfect' and 1.0 or 0.7
    end

    if st.hits >= st.tier.requiredHits then
        return { render = M.render(enc, now), outcome = 'success', value = value }
    end
    if st.misses >= st.tier.maxMisses then
        return { render = M.render(enc, now), outcome = 'escape', value = value }
    end

    armPass(st, now, meta and meta.ping)
    return { render = M.render(enc, now), value = value }
end

Encounter.Register('sonar_strike', M)
