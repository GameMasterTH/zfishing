# Sonar Strike Polish (Phase D3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the three gaps between the shipped `sonar_strike` encounter and what its design called for: a memorised midpoint press that scores PERFECT without reading the animation, a decoy that freezes at the lane edge halfway through the pass, and GHOST's missing fade.

**Architecture:** The crossing time stops being a structural constant and becomes a real per-pass parameter. Today every curve in the easing family crosses the target at the midpoint of its own travel, so the only lever anyone had for moving a crossing was to shorten the timeline — which is exactly how the decoy ended up freezing. Giving the fish a narrower arc placed inside the lane (`a`, `span`) moves the crossing while keeping the motion smooth, keeps both blips on-lane for the whole pass, and makes #1 and #2 one change instead of two.

**Tech Stack:** Lua 5.4 (server, wasmoon test harness), TypeScript + React (NUI), Vitest, plain-Lua spec tests.

**Spec:** `docs/superpowers/specs/2026-08-20-zfishing-encounter-system-design.md` §11 (phase D), and the shipped Phase D plans `docs/superpowers/plans/2026-08-21-zfishing-encounter-sonar-server.md` / `-client.md`.

## Global Constraints

- Server-authoritative: the client reports **that** it struck, never **when**. Nothing in this phase moves grading toward the client.
- A strike is never scored against something the UI is not showing (ARCHITECTURE §12.11's telegraph rule, §12.12's `notReady` rule). Every position this phase produces must be inside the drawn lane for the whole pass.
- `Sonar.WeakAt` is implemented once in Lua and mirrored in TypeScript; `tests/sonar_fixture.lua` and `web/src/engine/__fixtures__/sonarTimeline.json` are generated from the Lua by `tests/gen_sonar_fixture.mjs` and must be regenerated together.
- Millisecond floors stay: `MIN_PERFECT_MS = 90`, `MIN_WEAK_MS = 240`, measured on the **narrower** of the two half-windows, on the actual curve.
- `MAX_COMPENSATION = 200` and the frozen-at-arm compensation are untouched.
- Branch: `encounter-sonar-polish`, forked from `main`. Server and NUI ship together, one merge — same rule as Phase D.
- Expected suite sizes after each task are stated per task. Read the printed totals; do not infer them.

---

## D3.1 Why a memorised press works today

`Sonar.WeakAt` is

```
u = clamp((t - hold) / (duration - hold), 0, 1)
c = u - 0.5
f = 0.5 + (1 - k)·c + 4k·c³
```

`f` is antisymmetric about `(0.5, 0.5)`: `f(0.5) = 0.5` for **every** `k`, and `dir` mirrors about the same point. So the weak centre is over the target at `hold + (duration - hold)/2` in every pass ever generated, whatever the profile and whatever the direction.

`HOLD_JITTER = 0.06` was added to disturb that. It cannot. It moves the crossing by `hold/2`, at most 72ms at tier 5, and for the three zero-hold profiles the negative half of the jitter is clamped back to zero, so roughly half of all passes cross at the unmoved midpoint. Measured against the true PERFECT half-window on the actual curve at tier 5:

| profile | PERFECT half-window | max crossing shift |
| --- | --- | --- |
| DART | ±90.1ms | 72ms |
| HEAVY | ±133.5–142.0ms | 72ms |
| GHOST | ±90.0ms | 72ms |
| STALKER | ±90.3ms | 72ms |

The shift is smaller than the window at every profile and every tier, so pressing at `duration/2` scores PERFECT every time. Reading the animation buys nothing.

> Note for whoever writes the docs: the earlier review circulated a `72–126ms` PERFECT range. That was wrong — it multiplied `perfectHalf` (a **lane fraction**) by `duration` instead of dividing by the crossing speed. The table above is the corrected one, binary-searched on the curve.

## D3.2 The fix: move the arc, not the clock

Keep `f` exactly as it is. Let the fish travel a `span`-wide arc that starts at `a` instead of the whole lane:

```
pos(u) = a + span · f(u)
```

Pick the crossing fraction `crossFrac` first, then solve forward — no inversion, no Newton:

```
a = 0.5 - span · f(k, crossFrac)
```

At `u = crossFrac` the position is exactly `0.5`. `f` stays monotone for `k ∈ (-0.5, 1)`, so the crossing is still unique. Speed stays continuous — there is no seam at the crossing for a player to spot. Setting `a = 0, span = 1` reproduces today's behaviour exactly, which is why the change is expressible as two optional fields.

**The lane bound is the design constraint, not a nicety.** `pct()` in `SonarStrike.tsx` clamps to `[0, 100]`, so any position outside the lane renders as a blip parked at the edge — the exact defect this phase removes. `a ≥ 0` and `a + span ≤ 1` must hold for every `(k, crossFrac)` the generator can produce. Verified for the constants below: real pass `a ∈ [0.0068, …]`, `a + span ≤ 0.9932`; decoy `a ∈ [0.0130, …]`, `a + span ≤ 0.9870`.

## D3.3 Why `TargetSpeed` must stop reporting the crossing speed

`Sonar.TargetSpeed` returns `(1 - k) / travel`, which is `f'(0.5)` — correct only while the crossing is pinned to the middle. The derivative is

```
f'(u) = (1 - k) + 12k·(u - 0.5)²
```

so for `k > 0` the curve is slowest in the middle and speeds up toward the ends, and for `k < 0` the opposite. Once the crossing can sit anywhere in `[0.35, 0.65]`, sizing the bands off the speed *at the crossing* leaves the band asymmetric: the faster side falls under the millisecond floor while the test, which only searches forward, may or may not notice depending on which way the pass runs.

Size the bands off the fastest the centre ever moves in the pass instead:

```
f'max = max(1 - k, 1 + 2k)        -- middle for k < 0, ends for k > 0
TargetSpeed = span · f'max / travel
```

This is conservative — bands are never narrower than the floor on either side. Verified across all 5 tiers × 4 profiles × 41 crossing positions × 3 hold-jitter values, measuring the **narrower** half: worst PERFECT `90.0ms`, worst SAFE `240.7ms`.

## D3.4 The alternative, priced and rejected

One-sided `HOLD_JITTER = 0.12` gives a 288ms hold at tier 5, a 144ms crossing shift, which clears HEAVY's 142ms window without touching `WeakAt`, the TypeScript mirror, or the fixture. It is genuinely cheaper.

It is rejected because hold is **dead time**. It buys the shift by freezing the fish at its entry point, trading the midpoint tell for a freeze-at-entry tell; it blurs STALKER, whose `hold = 0.35` is its entire signature; and it leaves the decoy freeze (#2) open, because that defect exists precisely *because* shortening a timeline was the only crossing lever available.

## D3.5 The tuning table, and what a blind press is worth after this

`SPAN = 0.70`, `CROSS_SPREAD = 0.15`. Grade a player who presses at the travel midpoint every pass without watching, sampled uniformly across the crossing range and all four profiles:

| tier | PERFECT | SAFE | MISS |
| --- | --- | --- | --- |
| 1 | 64.9% | 35.1% | 0% |
| 2 | 58.9% | 41.1% | 0% |
| 3 | 50.0% | 41.6% | 8.4% |
| 4 | 43.1% | 43.1% | 13.9% |
| 5 | 44.1% | 40.1% | 15.8% |

Today that column reads 100% PERFECT at every tier. The gradient is the intended shape and is worth writing down as an invariant rather than a magic number:

> **The crossing-shift range must exceed the worst-case PERFECT half-window expressed as a fraction of travel.** Where it does, a blind midpoint press cannot be relied on for score. Where the tier is deliberately forgiving, it still lands a hit. Low tiers stay generous, high tiers demand reading the animation.

Anyone retuning `CROSS_SPREAD`, the tier table, or the ms floors must re-derive that table, not assume it.

A stronger anti-tell setting exists — `SPAN = 0.65`, `CROSS_SPREAD = 0.20`, which pushes tier-5 MISS to ~29% — and is **not** chosen here because it also widens every window in milliseconds (speed scales with `span`), which re-tunes difficulty as a side effect. It belongs to a balance pass with live data, and gets a checklist row in Task 4, not a code change here.

## D3.6 HEAVY is deliberately the widest — and that claim needs its qualifier

`k = +0.5` makes HEAVY slowest in the middle, so at a **midpoint** crossing it has the widest PERFECT window of the four (±524ms at tier 1, ±142ms at tier 5). This is intended: a heavy fish moving slowly through the target should be the easiest to time. Confirmed as deliberate by the user on 2026-08-24; document it, do not "fix" it.

The qualifier matters after this phase. Moving the crossing off centre **raises** `f'` for `k > 0`, narrowing HEAVY toward the other profiles, and lowers it for `k < 0`, widening DART and STALKER. So the docs must say "widest at a midpoint crossing", or the note goes stale the day this lands.

---

## Task 1: The crossing becomes a parameter, and the decoy stops freezing

**Files:**
- Modify: `server/encounter_sonar.lua`
- Test: `tests/encounter_sonar.test.lua`

**Interfaces:**
- Consumes: nothing new.
- Produces: `Sonar.WeakAt(pass, t)` now reads two additional optional fields on `pass` — `a` (number, arc origin in lane units, default `0`) and `span` (number, arc width in lane units, default `1`). `M.render` gains `a`, `span`, `crossFrac`, `crossAt` on the pass, and `a`, `span` on `decoy`; `decoy.duration` now equals the pass duration. Task 2 mirrors these in TypeScript.

- [ ] **Step 0: Branch**

```bash
git checkout -b encounter-sonar-polish
```

Confirm with `git status` that the tree is clean first — `main` is currently at the Phase D merge plus a Vitest refresh, with nothing uncommitted.

- [ ] **Step 1a: Replace the shared measuring helper**

`trueWindowMs` (around `tests/encounter_sonar.test.lua:91`) has two premises that D3 makes false: it starts its search at `u = 0.5`, assuming the crossing is at the midpoint, and it re-implements the curve inline **without** `a`/`span`, so it measures a whole-lane journey. After Task 1 it would size bands off the real arc and then measure them against a curve running `1/span` too fast — tier-5 DART reports 63ms against an 89.5ms floor, and S14 goes red for a reason that has nothing to do with the module.

Delete `trueWindowMs` and put these three helpers in its place, above `S1`, so both halves of the file share one correct measurement:

```lua
local function passOf(s)
    return { duration = s.duration, hold = s.hold, k = s.k, dir = s.dir,
             a = s.a, span = s.span }
end

-- Where the weak centre actually sits on the target, found on the curve rather than
-- assumed at the midpoint. Returns elapsed ms within the pass.
local function crossingMs(pass)
    local lo, hi = pass.hold, pass.duration
    local rising = Sonar.WeakAt(pass, pass.duration) > Sonar.WeakAt(pass, pass.hold)
    for _ = 1, 60 do
        local mid = (lo + hi) * 0.5
        local below = Sonar.WeakAt(pass, mid) < 0.5
        if below == rising then lo = mid else hi = mid end
    end
    return (lo + hi) * 0.5
end

-- The TRUE half-window in ms, on one side of the crossing: how long the weak centre
-- actually takes to travel from the target out to `half`, walked along the real arc
-- rather than derived from a slope. The linear figure half/TargetSpeed diverges from it
-- for k ~= 0, so asserting on that instead would let a tuning change slip a real window
-- under the floor while the test stayed green. Since D3 the two sides differ, because
-- the crossing is no longer at the midpoint -- always check the narrower one.
local function halfWindowMs(pass, half, backward)
    local cross = crossingMs(pass)
    local lo, hi = cross, backward and pass.hold or pass.duration
    for _ = 1, 60 do
        local mid = (lo + hi) * 0.5
        if math.abs(Sonar.WeakAt(pass, mid) - 0.5) <= half then lo = mid else hi = mid end
    end
    return math.abs(lo - cross)
end
```

- [ ] **Step 1b: Write the failing tests**

Append to `tests/encounter_sonar.test.lua`, before the final `H.run()`:

```lua
-- ------------------------------------------------------- D3: the crossing bias

test('S24 the crossing is not pinned to the midpoint of the travel', function()
    -- The whole defect in one assertion: every curve in this family crosses its own
    -- midpoint, so before the arc shift a memorised duration/2 press was always right.
    local far = 0
    for _, behavior in ipairs({ 'steady_light', 'steady_heavy', 'run_stop', 'erratic' }) do
        for seed = 1, 25 do
            local s = start({ difficulty = 5, behavior = behavior, seed = seed }).last
            local midpoint = s.hold + (s.duration - s.hold) * 0.5
            local gap = math.abs(crossingMs(passOf(s)) - midpoint)
            if gap > far then far = gap end
        end
    end
    truthy(far > 200, ('the furthest crossing was only %.0fms off the midpoint'):format(far))
end)

test('S25 a blind midpoint press cannot be relied on for a perfect strike', function()
    -- Not "never perfect" -- a crossing that happens to land near the middle should still
    -- reward a press there. The claim is that it stops being a substitute for watching.
    local perfect, total = 0, 0
    for _, behavior in ipairs({ 'steady_light', 'steady_heavy', 'run_stop', 'erratic' }) do
        for seed = 1, 40 do
            local s = start({ difficulty = 5, behavior = behavior, seed = seed }).last
            local midpoint = s.hold + (s.duration - s.hold) * 0.5
            local d = math.abs(Sonar.WeakAt(passOf(s), midpoint) - 0.5)
            if d <= s.perfectHalf then perfect = perfect + 1 end
            total = total + 1
        end
    end
    truthy(perfect < total * 0.75,
        ('%d of %d blind midpoint presses were PERFECT'):format(perfect, total))
    truthy(perfect > 0,
        'a crossing near the middle must still reward a press there -- this is not a ban')
end)

test('S26 both blips stay inside the drawn lane for the whole pass', function()
    -- The NUI clamps position to [0,1], so any excursion renders as a blip parked at the
    -- edge. That is the frozen-decoy defect; it must be impossible by construction.
    for tier = 1, 5 do
        for _, behavior in ipairs({ 'steady_light', 'steady_heavy', 'run_stop', 'erratic' }) do
            for seed = 1, 8 do
                local s = start({ difficulty = tier, behavior = behavior, seed = seed }).last
                local records = { passOf(s) }
                if s.decoy then records[#records + 1] = s.decoy end
                for _, rec in ipairs(records) do
                    for i = 0, 60 do
                        local p = Sonar.WeakAt(rec, s.duration * i / 60)
                        truthy(p >= -1e-9 and p <= 1 + 1e-9,
                            ('tier %d %s: position %.4f left the lane'):format(tier, behavior, p))
                    end
                end
            end
        end
    end
end)

test('S27 the decoy runs the full pass instead of freezing at the edge', function()
    -- A decoy that ends its own timeline early clamps to an edge and sits there, which
    -- reveals it the moment the player has seen one. It has to keep swimming.
    for seed = 1, 20 do
        local s = start({ difficulty = 5, behavior = 'erratic', seed = seed }).last
        equal(s.decoy.duration, s.duration, 'the decoy shares the pass timeline')
        local late = Sonar.WeakAt(s.decoy, s.duration * 0.97)
        local later = Sonar.WeakAt(s.decoy, s.duration)
        truthy(math.abs(later - late) > 1e-4,
            ('seed %d: the decoy was motionless at the end of the pass'):format(seed))
    end
end)

test('S28 the millisecond floor holds on the NARROWER side of every band', function()
    -- S14 checks one side per case. With the crossing off centre the two halves differ,
    -- so a forward-only check can pass while the other side is under the budget.
    for tier = 1, 5 do
        for _, behavior in ipairs({ 'steady_light', 'steady_heavy', 'run_stop', 'erratic' }) do
            for seed = 1, 6 do
                local s = start({ difficulty = tier, behavior = behavior, seed = seed }).last
                local pass = passOf(s)
                local p = math.min(halfWindowMs(pass, s.perfectHalf, false),
                                   halfWindowMs(pass, s.perfectHalf, true))
                local w = math.min(halfWindowMs(pass, s.weakHalf, false),
                                   halfWindowMs(pass, s.weakHalf, true))
                truthy(p >= 89.5, ('tier %d %s: PERFECT half is %.1fms'):format(tier, behavior, p))
                truthy(w >= 239.5, ('tier %d %s: SAFE half is %.1fms'):format(tier, behavior, w))
            end
        end
    end
end)

test('S29 only the stalker holds -- the others start moving immediately', function()
    -- Dead time at the start would trade the midpoint tell for a freeze-at-entry tell.
    -- The crossing bias does that job now, so the other three profiles need no hold.
    for _, behavior in ipairs({ 'steady_light', 'steady_heavy', 'erratic' }) do
        for seed = 1, 10 do
            equal(start({ difficulty = 5, behavior = behavior, seed = seed }).last.hold, 0)
        end
    end
    truthy(start({ difficulty = 5, behavior = 'run_stop', seed = 1 }).last.hold > 0)
end)
```

- [ ] **Step 1c: Update the five existing tests the new timeline invalidates**

Four of these still assume the crossing sits at the travel midpoint. Do all five in this step — each one is a red in Step 2 otherwise, landing in exactly the code Task 1 changed and inviting a wild-goose debug of `armPass`.

**`S14`** — swap the helper. Each case now checks the narrower half, which is what the floor actually promises:

```lua
            local perfectMs = math.min(halfWindowMs(passOf(s), s.perfectHalf, false),
                                       halfWindowMs(passOf(s), s.perfectHalf, true))
            local weakMs = math.min(halfWindowMs(passOf(s), s.weakHalf, false),
                                    halfWindowMs(passOf(s), s.weakHalf, true))
```

**`S14b`** — both terms were stale, not just the linear one. The comparison is still "the module's own speed estimate versus the curve", now on the real arc:

```lua
    local pass = passOf(s)
    local linear = s.weakHalf / Sonar.TargetSpeed(pass)
    truthy(linear - halfWindowMs(pass, s.weakHalf, false) > 15,
        'the linear estimate must still be measurably optimistic for k > 0')
```

**`S16b`** — the crossing is no longer `hold + travel/2`. Key the set on the real one:

```lua
        seen[math.floor(crossingMs(passOf(s)))] = true
```

**`S17`** — builds its pass record by hand without the arc, so it silently keeps testing the pre-D3 curve. It is the crossing-uniqueness guard, so it has to test the shipped one:

```lua
        local pass = passOf(s)
```

**`S18b`** — measures decoy separation from the midpoint, but `armPass` separates from `st.crossAt`. At tier 5 the crossing sits up to 360ms off the midpoint, so a decoy a legitimate 550ms from the crossing measures as little as 190ms from the midpoint and the assertion fails:

```lua
            local gap = math.abs(s.decoy.crossAt - s.crossAt)
```

Delete the now-unused `local realCross = ...` line above it.

Finally, replace the body of `S18c` (it asserts the old `duration = 2 * crossAt` construction):

```lua
test('S18c the decoy carries its own crossing, not the pass crossing', function()
    local s = start({ difficulty = 5, behavior = 'erratic', seed = 3 }).last
    equal(s.decoy.hold, 0)
    equal(s.decoy.duration, s.duration, 'it runs the full pass so it never freezes')
    truthy(s.decoy.span < s.span,
        'a narrower arc is what lets the decoy cross anywhere without leaving the lane')
    -- And the maths agrees: the decoy is on the target at its own crossAt.
    truthy(math.abs(Sonar.WeakAt(s.decoy, s.decoy.crossAt) - 0.5) < 1e-9)
end)
```

- [ ] **Step 2: Run them to verify they fail**

```bash
node tests/luarun.mjs tests/encounter_sonar.test.lua
```

Expected reds, all for the same reason — `armPass` does not yet produce an arc, so `s.a`, `s.span` and `s.crossAt` are `nil`:

| test | failure |
| --- | --- |
| S24 | `the furthest crossing was only 0ms off the midpoint` |
| S27 | `decoy.duration` is `2 * crossAt`, not the pass duration |
| S29 | zero-hold profiles still receive jittered holds |
| S18b / S18c | `s.crossAt` / `decoy.span` are `nil` |

`S25`, `S26` and `S28` are regression guards rather than new-behaviour proofs and may already pass. `S14`, `S14b`, `S16b` and `S17` should still be green after Step 1c — with `a`/`span` absent, `passOf` yields exactly the pre-D3 record and `halfWindowMs` reduces to what `trueWindowMs` measured.

- [ ] **Step 3: Write the implementation**

In `server/encounter_sonar.lua`, replace the constants block, the curve functions and `armPass`.

Constants — replace `HOLD_JITTER`'s neighbours and add the three new ones:

```lua
local MIN_DECOY_SEPARATION = 550
local HOLD_JITTER = 0.06
-- The fish swims a SPAN-wide arc inside the lane rather than the whole lane, and the
-- arc is placed so the target crossing lands at CROSS_SPREAD either side of the middle.
-- Both bounds are load-bearing: SPAN + the spread must keep the arc inside [0,1] (the
-- NUI clamps, and a clamped blip is a frozen blip), and the spread must exceed the
-- PERFECT half-window as a fraction of travel or a memorised midpoint press still wins.
-- See docs/ARCHITECTURE.md 12.12 for the derivation and the retuning rule.
local SPAN = 0.70
local CROSS_SPREAD = 0.15
local DECOY_SPAN = 0.50
```

Add the shared curve above `Sonar.WeakAt`:

```lua
-- Progress along the fish's own arc: 0 at its start, 0.5 at its midpoint, 1 at its end.
-- Monotone for k in (-0.5, 1), which is what keeps the target crossing unique.
local function curve(k, u)
    local c = u - 0.5
    return 0.5 + (1 - k) * c + 4 * k * c * c * c
end
```

Replace `Sonar.WeakAt` and `Sonar.TargetSpeed`:

```lua
-- `t` is elapsed milliseconds in this pass, never a client timestamp. `a` and `span`
-- place the arc: omitting them is the old whole-lane journey, which is what the
-- pre-D3 fixture rows still describe.
function Sonar.WeakAt(pass, t)
    local travel = pass.duration - pass.hold
    local u = (t - pass.hold) / travel
    if u < 0 then u = 0 elseif u > 1 then u = 1 end
    local p = (pass.a or 0.0) + (pass.span or 1.0) * curve(pass.k, u)
    return pass.dir > 0 and p or (1 - p)
end

-- The FASTEST the weak centre moves in this pass, not its speed at the crossing.
-- f'(u) = (1-k) + 12k(u-0.5)^2 peaks in the middle for k < 0 and at the ends for k > 0.
-- Since D3 the crossing is no longer pinned to the middle, so sizing the bands off the
-- crossing speed would leave the faster side of the band under the millisecond floor.
function Sonar.TargetSpeed(pass)
    local fastest = math.max(1 - pass.k, 1 + 2 * pass.k)
    return (pass.span or 1.0) * fastest / (pass.duration - pass.hold)
end
```

Replace the top of `armPass` down to and including the decoy block:

```lua
    local profile = st.profileDef
    st.dir = rand(st) < 0.5 and 1 or -1
    st.k = profile.k
    st.span = SPAN

    -- STALKER's wait is its signature, so it keeps a jittered hold. The other three sit
    -- at hold 0 deliberately: dead time at the start would only trade the midpoint tell
    -- for a freeze-at-entry tell, and the crossing bias below breaks the midpoint properly.
    if profile.hold > 0 then
        local holdFrac = profile.hold + (rand(st) - 0.5) * 2 * HOLD_JITTER
        st.hold = math.floor(st.duration * ZUtil.clamp(holdFrac, 0, 0.5))
    else
        st.hold = 0
    end

    -- Every curve in this family crosses its own midpoint, so the crossing cannot be
    -- moved by reshaping the curve -- only by moving the whole arc. Solve forward: pick
    -- where on the travel the crossing should be, then place the arc so it lands there.
    st.crossFrac = 0.5 + (rand(st) - 0.5) * 2 * CROSS_SPREAD
    st.a = 0.5 - SPAN * curve(st.k, st.crossFrac)
    st.crossAt = math.floor(st.hold + (st.duration - st.hold) * st.crossFrac)

    st.compensationMs = ZUtil.clamp((ping or 0) * 0.5, 0, MAX_COMPENSATION)

    local speed = Sonar.TargetSpeed(st)
    st.weakHalf = math.max(st.tier.weakHalf * (1 + st.greenZone), MIN_WEAK_MS * speed)
    st.perfectHalf = math.max(st.tier.perfectHalf, MIN_PERFECT_MS * speed)
    st.perfectHalf = math.min(st.perfectHalf, st.weakHalf * 0.8)

    st.decoy = nil
    if st.canDecoy and profile.name == 'GHOST' then
        -- A decoy has to be wrong to strike at, and it has to stay believable after it
        -- has been wrong. Its crossing is pushed at least MIN_DECOY_SEPARATION from the
        -- real one, and it runs the FULL pass on a narrower arc -- narrow enough that any
        -- crossing fraction keeps it inside the lane, so it never clamps and never freezes.
        local lo, hi = 200, st.duration - 200
        local early, late = st.crossAt - MIN_DECOY_SEPARATION, st.crossAt + MIN_DECOY_SEPARATION
        local crossAt
        if early > lo and (late > hi or rand(st) < 0.5) then
            crossAt = lo + rand(st) * (early - lo)
        else
            crossAt = late + rand(st) * math.max(0, hi - late)
        end
        crossAt = math.floor(crossAt)
        local k = (rand(st) - 0.5) * 0.8
        st.decoy = {
            k = k,
            dir = rand(st) < 0.5 and 1 or -1,
            hold = 0,
            duration = st.duration,
            crossAt = crossAt,
            span = DECOY_SPAN,
            a = 0.5 - DECOY_SPAN * curve(k, crossAt / st.duration),
        }
    end
```

Add the new fields to `M.render`, next to `profile`, `dir`, `k`:

```lua
        profile = st.profile, dir = st.dir, k = st.k,
        a = st.a, span = st.span,
        crossFrac = st.crossFrac, crossAt = st.crossAt,
```

- [ ] **Step 4: Run the suite to verify it passes**

```bash
node tests/luarun.mjs tests/encounter_sonar.test.lua
```

Expected: `38 tests passed` (32 before, plus S24–S29).

- [ ] **Step 5: Run the whole Lua suite**

```bash
cd tests && npm run test:all
```

Expected: every suite green; the sonar suite prints `38 tests passed`, the others are unchanged. Read the printed per-suite totals rather than assuming them.

- [ ] **Step 6: Commit**

```bash
git add server/encounter_sonar.lua tests/encounter_sonar.test.lua
git commit -m "fix: give each sonar pass its own target crossing"
```

---

## Task 2: The TypeScript mirror and the parity fixture

**Files:**
- Modify: `web/src/engine/sonarTimeline.ts`, `web/src/encounters/types.ts`, `tests/gen_sonar_fixture.mjs`, `web/src/engine/__tests__/sonarTimeline.test.ts`
- Generated: `tests/sonar_fixture.lua`, `web/src/engine/__fixtures__/sonarTimeline.json`

**Interfaces:**
- Consumes: `a`, `span`, `crossFrac`, `crossAt` from Task 1's `M.render`; `decoy.span`, `decoy.a`, `decoy.duration == pass duration`.
- Produces: `weakAt(pass, elapsed)` honouring optional `a`/`span`; fixture rows carrying `a` and `span`.

- [ ] **Step 1: Update the fixture generator**

In `tests/gen_sonar_fixture.mjs`, the profile table hardcodes `{ k, holdRatio }`. If it does not learn the new fields the regenerated fixture only ever exercises `a = 0, span = 1`, and the parity tests stay green while testing nothing new — the same silent-degradation trap `S14b` guards against. Replace the `profiles`/`durations`/`dirs` block and the sample loop's pass construction:

```javascript
// Crossing fractions at both extremes and the middle. The extremes are the rows that
// would go untested if the fixture kept sampling only midpoint crossings.
const profiles = [
    { k: -0.4, holdRatio: 0.00 },
    { k:  0.5, holdRatio: 0.00 },
    { k: -0.3, holdRatio: 0.35 },
    { k:  0.0, holdRatio: 0.00 },
];
const durations = [4000, 3200, 2400];
const dirs = [1, -1];
const spans = [
    { span: 1.0, crossFrac: 0.50 },   // the pre-D3 whole-lane journey
    { span: 0.7, crossFrac: 0.35 },
    { span: 0.7, crossFrac: 0.50 },
    { span: 0.7, crossFrac: 0.65 },
    { span: 0.5, crossFrac: 0.12 },   // decoy geometry
    { span: 0.5, crossFrac: 0.88 },
];

const curve = (k, u) => {
    const c = u - 0.5;
    return 0.5 + (1 - k) * c + 4 * k * c * c * c;
};
```

Widen the Lua shim to take the arc:

```javascript
    await lua.doString(`
        function __sonarWeak(duration, hold, k, dir, a, span, t)
            return Sonar.WeakAt({ duration = duration, hold = hold, k = k, dir = dir,
                                  a = a, span = span }, t)
        end
    `);
```

and the sample loop:

```javascript
    const samples = [];
    for (const profile of profiles) {
        for (const dir of dirs) {
            for (const duration of durations) {
                for (const arc of spans) {
                    const hold = Math.floor(duration * profile.holdRatio);
                    // Round BEFORE calling Lua, and use the rounded value for both. Rounding
                    // the emitted row after generating `pos` from the full-precision value
                    // leaves the TypeScript side recomputing from a slightly different `a`,
                    // which lands right on toBeCloseTo's 6-digit threshold -- a test that
                    // passes or fails on the last bit is worse than one that fails outright.
                    const a = Math.round((0.5 - arc.span * curve(profile.k, arc.crossFrac)) * 1e6) / 1e6;
                    for (let i = 0; i <= 20; i += 1) {
                        const t = Math.round(duration * i / 20);
                        const raw = await lua.global.call('__sonarWeak',
                            duration, hold, profile.k, dir, a, arc.span, t);
                        samples.push({
                            duration, hold, k: profile.k, dir, t,
                            a,
                            span: arc.span,
                            crossFrac: arc.crossFrac,
                            pos: Math.round(Number(raw[0]) * 1_000_000) / 1_000_000,
                        });
                    }
                }
            }
        }
    }
```

and the Lua row writer:

```javascript
    const luaRows = samples.map((s) =>
        `    { duration = ${s.duration}, hold = ${s.hold}, k = ${s.k}, dir = ${s.dir}, `
        + `a = ${s.a}, span = ${s.span}, t = ${s.t}, pos = ${s.pos} },`
    );
```

- [ ] **Step 2: Port the arc to TypeScript**

`web/src/engine/sonarTimeline.ts`:

```typescript
export type SonarPass = {
  duration: number
  hold: number
  k: number
  dir: 1 | -1
  /** arc origin in lane units; absent means the pre-D3 whole-lane journey */
  a?: number
  /** arc width in lane units; absent means 1 */
  span?: number
}

const clamp = (value: number, low: number, high: number) => Math.min(high, Math.max(low, value))

export function passProgress(pass: SonarPass, elapsed: number): number {
  const travel = Math.max(1, pass.duration - pass.hold)
  return clamp((elapsed - pass.hold) / travel, 0, 1)
}

export function weakAt(pass: SonarPass, elapsed: number): number {
  const u = passProgress(pass, elapsed)
  const c = u - 0.5
  const f = 0.5 + (1 - pass.k) * c + 4 * pass.k * c * c * c
  const p = (pass.a ?? 0) + (pass.span ?? 1) * f
  return pass.dir > 0 ? p : 1 - p
}
```

`web/src/encounters/types.ts` — add to `SonarDecoy`:

```typescript
export type SonarDecoy = {
  k: number
  dir: 1 | -1
  hold: number
  duration: number
  crossAt: number
  a: number
  span: number
}
```

and to `SonarState`, beside `k`:

```typescript
  k: number
  a: number
  span: number
  crossFrac: number
  crossAt: number
```

**`SonarStrike.tsx` must pass the arc through, or the NUI silently draws the pre-D3 journey while the server grades the new one.** The component builds its own pass record; give it the two new fields and add them to the effect's dependency list:

```tsx
function blipTransform(pass: SonarPass, elapsed: number) {
  return `translateX(${pct(weakAt(pass, elapsed))}) translateX(-50%)`
}
```

```tsx
    const pass = { duration: state.duration, hold: state.hold, k: state.k, dir: state.dir,
                   a: state.a, span: state.span }
```

```tsx
  }, [state.phaseId, state.duration, state.hold, state.k, state.dir,
      state.a, state.span, state.decoy, timing])
```

Import the type alongside the function: `import { weakAt, type SonarPass } from '../engine/sonarTimeline'`.

Making the new state fields required breaks two existing fixtures at compile time, which is the point — anything the live server renders after Task 1 always carries them. Fix both in `web/src/encounters/__tests__/SonarStrike.test.tsx`:

```typescript
const base = (over: Record<string, unknown> = {}) => ({
  phaseId: 1, attempt: 1, maxAttempts: 6,
  hits: 0, requiredHits: 5, misses: 0, maxMisses: 2,
  passStartsIn: 700, passEndsIn: 3100, duration: 2400, hold: 0,
  profile: 'GHOST', dir: 1 as const, k: 0, weakHalf: 0.1, perfectHalf: 0.0375,
  a: 0.15, span: 0.7, crossFrac: 0.5, crossAt: 1200,
  target: 0.5, floatTier: 1,
  ...over,
})
```

and the decoy literal in the "draws a GHOST decoy" case, which still describes the old short-timeline geometry:

```typescript
    render(<SonarStrike state={base({ decoy: { k: 0.3, dir: -1, hold: 0,
      duration: 2400, crossAt: 600, span: 0.5, a: 0.28 } })} outcome={null} />)
```

- [ ] **Step 3: Update the timeline test**

In `web/src/engine/__tests__/sonarTimeline.test.ts`, the second case asserts the midpoint crossing, which is now false by design. Replace it:

```typescript
  it('crosses the target at its own crossing fraction, not the midpoint', () => {
    for (const sample of fixture) {
      const at = sample.hold + (sample.duration - sample.hold) * sample.crossFrac
      expect(weakAt(sample, at)).toBeCloseTo(0.5, 9)
    }
    const shifted = fixture.filter((s) => s.crossFrac !== 0.5)
    expect(shifted.length).toBeGreaterThan(0)
  })
```

- [ ] **Step 4: Regenerate and run both suites**

```bash
cd tests && npm run gen:sonar-fixture
```

Expected: `generated 3024 sonar timeline samples` (4 profiles × 2 dirs × 3 durations × 6 arcs × 21 points; it was 504 before the arcs were added).

```bash
node tests/luarun.mjs tests/encounter_sonar.test.lua
```

Expected: `38 tests passed` — `S22` and `S23` now read the widened fixture.

```bash
cd web && npx vitest --run
```

Expected: 22 files, 99 tests, all green. Note the npm `test` script already carries `--run`; passing it again is a Vitest parse error.

- [ ] **Step 5: Commit**

```bash
git add web/src/engine/sonarTimeline.ts web/src/encounters/types.ts tests/gen_sonar_fixture.mjs web/src/engine/__tests__/sonarTimeline.test.ts tests/sonar_fixture.lua web/src/engine/__fixtures__/sonarTimeline.json
git commit -m "test: mirror the sonar crossing bias and widen the parity fixture"
```

---

## Task 3: GHOST fades and returns

**Files:**
- Modify: `web/src/style.css`, `web/src/encounters/SonarStrike.tsx`
- Test: `web/src/encounters/__tests__/SonarStrike.test.tsx`

**Interfaces:**
- Consumes: `state.profile` from `SonarState`.
- Produces: a `sonar-panel--ghost` class on the panel when the profile is GHOST.

The design called for GHOST's echo to fade and return, never below an opacity floor of 0.35 — a strike must never be graded against something the player cannot see. Today the component has no profile-specific opacity at all.

**The composition trap:** `.sonar-float--1 .sonar-fish--real { opacity: .72 }` sits on the same element a fade would animate, and an animation on `opacity` overrides the declared value outright — adding a keyframe there silently deletes the float-tier signal. Drive both through one custom property instead, so the floor and the tier compose.

- [ ] **Step 1: Write the failing test**

Append inside the existing `describe` in `web/src/encounters/__tests__/SonarStrike.test.tsx`:

```typescript
  it('marks the ghost profile so its echo can fade, and no other profile', () => {
    const { rerender } = render(<SonarStrike state={base({ profile: 'GHOST' })} outcome={null} />)
    expect(document.querySelector('.sonar-panel--ghost')).not.toBeNull()

    rerender(<SonarStrike state={base({ profile: 'DART' })} outcome={null} />)
    expect(document.querySelector('.sonar-panel--ghost')).toBeNull()
  })
```

This reuses the file's existing `base(over)` fixture helper and its `document.querySelector` idiom — do not introduce a second fixture or switch to `container`.

- [ ] **Step 2: Run it to verify it fails**

```bash
cd web && npx vitest --run src/encounters/__tests__/SonarStrike.test.tsx
```

Expected: FAIL — `expect(received).not.toBeNull()`.

- [ ] **Step 3: Implement**

In `web/src/encounters/SonarStrike.tsx`, extend the panel class list:

```tsx
    <div className={`hud-panel enc-panel sonar-panel sonar-float--${state.floatTier}`
      + `${state.profile === 'GHOST' ? ' sonar-panel--ghost' : ''}`
      + `${danger ? ' hud-panel--danger' : ''}`}>
```

In `web/src/style.css`, replace the two float-tier opacity rules with custom-property versions and add the fade:

```css
.sonar-fish--real { opacity: var(--echo-visibility, 1); }
.sonar-float--1 .sonar-fish--real { --echo-visibility: .72; }
.sonar-float--2 .sonar-fish--real { --echo-visibility: .88; }
.sonar-float--3 .sonar-fish--real { --echo-visibility: 1; }
/* GHOST's echo fades and returns. The floor is 0.35 of whatever the float tier already
   allows, never absolute darkness: a strike is graded against this blip, so it must
   stay visible the whole time it is strikeable. */
.sonar-panel--ghost .sonar-fish--real { animation: sonarGhostFade 1.6s ease-in-out infinite; }
@keyframes sonarGhostFade {
    0%, 100% { opacity: var(--echo-visibility, 1); }
    50%      { opacity: calc(var(--echo-visibility, 1) * .35); }
}
```

- [ ] **Step 4: Verify**

```bash
cd web && npx vitest --run
```

Expected: 22 files, 100 tests, all green.

- [ ] **Step 5: Commit**

```bash
git add web/src/style.css web/src/encounters/SonarStrike.tsx web/src/encounters/__tests__/SonarStrike.test.tsx
git commit -m "feat: fade the ghost echo without losing the float tier signal"
```

---

## Task 4: Rebuild, document, and record what still needs live data

**Files:**
- Modify: `docs/ARCHITECTURE.md` §12.12, `docs/testing/zfishing-live-e2e-checklist.md`
- Rebuild: `web/dist` (committed to the repo — the running NUI reads the bundle, not the source)

- [ ] **Step 1: Rebuild the bundle**

```bash
cd web && npm run build
```

`web/dist` is committed and is what FiveM actually serves. Skipping this ships Task 3's CSS and Task 2's timeline to nobody.

- [ ] **Step 2: Amend ARCHITECTURE §12.12**

Add a subsection after the existing timeline description covering, in this order:

1. Why the crossing used to be fixed — `f(0.5) = 0.5` for every `k`, `dir` mirrors about the same point — and why `HOLD_JITTER` could not fix it (the shift was smaller than every PERFECT window; half of all zero-hold passes clamped back to the unmoved midpoint).
2. The arc form `pos(u) = a + span·f(u)`, solved forward as `a = 0.5 - span·f(k, crossFrac)`.
3. The lane bound as a hard constraint, with the reason: the NUI clamps, and a clamped blip is a frozen blip. Quote the verified margins (`a ≥ 0.0068`, `a + span ≤ 0.9932` for the pass; `0.0130` / `0.9870` for the decoy).
4. Why `TargetSpeed` reports `span·max(1-k, 1+2k)/travel` rather than the crossing speed, and that the floors are measured on the **narrower** half.
5. The retuning invariant from D3.5, stated as derivable, with the blind-press table.
6. HEAVY's widest-window property **with its qualifier**: widest *at a midpoint crossing*; moving the crossing off centre narrows `k > 0` and widens `k < 0`. Mark it deliberate, decided 2026-08-24.
7. The decoy: full-pass duration, narrower arc, `MIN_DECOY_SEPARATION` unchanged, and why the old `duration = 2·crossAt` construction had to go.
8. The rejected alternative from D3.4, so the next reviewer does not re-propose it.

Add a change-history entry.

- [ ] **Step 3: Extend the live checklist**

Add to the sonar section of `docs/testing/zfishing-live-e2e-checklist.md`:

| # | check | pass criteria |
| --- | --- | --- |
| N7 | Play 20 tier-5 passes pressing at the visual midpoint without watching | PERFECT well under half the time; at least some misses |
| N8 | Watch a tier-5 GHOST pass end to end | the decoy keeps moving to the end of the pass; it never parks at an edge |
| N9 | Watch a GHOST pass on `float_wood` | the echo fades and returns; it is legible at its dimmest |
| N10 | Both blips, every profile, every tier | neither ever sits motionless against the lane edge |
| N11 | Measure tier-5 PERFECT rate for a watching player at <60ms, ~120ms and >200ms ping | rates comparable across bands; if not, `MAX_COMPENSATION` needs revisiting |
| N12 | Record the tier-5 miss rate for a blind midpoint presser | feeds the `SPAN`/`CROSS_SPREAD` decision in D3.5; the 0.65/0.20 alternative is only on the table with this number in hand |

State plainly in the section header that none of these can be ticked in this environment.

- [ ] **Step 4: Full verification**

```bash
cd tests && npm run test:all
```

Expected: all suites green, sonar prints `38 tests passed`.

```bash
cd web && npx vitest --run
```

Expected: 22 files, 100 tests green. `bundleRebuildPreservation.test.ts` holds a snapshot of the built bundle — if Step 1 changed it, re-record with `npx vitest --run -u` and include the updated snapshot in the commit.

- [ ] **Step 5: Commit**

```bash
git add docs/ARCHITECTURE.md docs/testing/zfishing-live-e2e-checklist.md web/dist web/src/__tests__/__snapshots__
git commit -m "docs: record the sonar crossing bias and rebuild the bundle"
```

- [ ] **Step 6: Finish the branch**

Now — and only now — use superpowers:finishing-a-development-branch. Unlike Phase D there is no second half waiting: server and NUI both ship in this branch, so it is complete and mergeable on its own.

---

## Self-review notes

- **Spec coverage:** D3.1–D3.2 → Task 1; the TypeScript half of the same contract → Task 2; the GHOST fade → Task 3; documentation and the bundle → Task 4. The `phaseId`-binding hardening raised in both review rounds is deliberately **not** here: it changes the wire signature of `zfishing:encounter:act` for all three encounters and belongs in its own cross-encounter task, alongside the device-aware-keycap gap left over from Phase B.
- **Type consistency:** `a`/`span` are optional in both `Sonar.WeakAt` and `weakAt` (defaulting to `0`/`1`) so a pre-D3 fixture row still describes a valid pass; they are **required** on `SonarState`/`SonarDecoy`, because anything the live server renders after this phase always carries them.
- **Numbers:** every figure quoted in D3.1, D3.3, D3.5 and D3.6 was computed against the shipped formula, not estimated. Whoever retunes must recompute rather than scale them.
