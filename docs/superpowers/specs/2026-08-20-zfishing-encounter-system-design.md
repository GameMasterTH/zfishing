# zfishing — Fishing Encounter System (design)

**Date:** 2026-08-20
**Status:** approved design, not yet implemented
**Supersedes nothing.** Extends `docs/superpowers/specs/2026-08-18-zfishing-minigame-authority-design.md`.

---

## 1. Why

Fishing is currently architected around one hard-coded fight: the tension minigame
(`web/src/engine/minigameEngine.ts`, driven by `client/minigame.lua`). Everything
about a fight — its rules, its difficulty knobs, its failure modes — is that one
minigame. Adding a second kind of fight today means branching inside the client.

This design replaces "the minigame" with a **resolved encounter**:

```
                    Fish Roll  (server/generator.lua)
                       |
                       v
                Encounter Resolver  (server/encounter.lua)
                       |
        +--------------+--------------+
        |              |              |
     DEFAULT         RANDOM         FORCED
        |              |              |
        v              v              v
   fish.encounter   server RNG    admin setting
        |              |              |
        +--------------+--------------+
                       v
              Session Encounter  (frozen into sessions[src])
                       |
        +--------+-----+------+---------+
        v        v            v         v
   counter_   fish_       sonar_    legacy_
    pull    mindgame      strike    tension
        |        |            |         |
        +--------+-----+------+---------+
                       v
              Catch Settlement  (unchanged: zfishing:claim -> Rewards.GiveCatch)
```

The encounter decides **how the fight plays**. It never decides species, weight,
quality, rarity, price or loot — those stay exactly where they are today.

---

## 2. Decisions taken during brainstorming

Three decisions were made by the maintainer and are load-bearing. They are recorded
here because two of them deviate from the original task brief.

### 2.1 DEFAULT falls back to `legacy_tension`

A fish with no `encounter` field resolves to `legacy_tension` — the existing tension
minigame, byte-for-byte unchanged.

**Deviation from the brief (PART 6).** The brief proposed a four-step fallback chain:
explicit fish encounter -> behavior-based default -> rarity-based fallback -> safe
global fallback. A behavior-based step would move all ten configured fish onto new
encounters the moment the resource restarts, which is a full production cutover.

The chain implemented here is two steps:

```
explicit fish.encounter  ->  legacy_tension
```

The behavior->encounter mapping still ships, as **data** (`Encounters.RECOMMENDED`),
and is used to fill the fish mapping table in section 7, to drive the "suggested"
hint in the admin Fish tab, and to document the intended end state. The resolver does
not read it. Turning on the full cutover later is a one-line change to the resolver
plus a data migration, not a redesign.

### 2.2 Only three fish ship with an explicit encounter

`mackerel`, `catfish` and `swordfish` (section 7). The other seven stay on
`legacy_tension`. Rollback of the pilot is deleting three `encounter` fields.

Rationale for picking these three rather than the most-caught fish: FORCED mode
already lets an admin test any encounter against any fish, so the pilot's job is to
minimise production exposure, not to maximise play time. `bass` and `trout` — the
core freshwater loop — stay on the legacy fight.

### 2.3 Encounter performance affects XP only

A perfect sonar strike, a clean counter-pull, a mindgame won without a wrong answer:
all of these raise XP by at most 25%. They do **not** touch weight, quality, price,
or rare-loot rolls.

**Narrowing of the brief (PART 9).** The brief listed "quality modifier" as a possible
performance effect. It is excluded so this change carries no economy delta: the
`Rewards.Price` path and `qualityMult` table are untouched, and the diff in
`server/rewards.lua` is a single optional multiplier on the XP grant.

---

## 3. Architecture

### 3.1 `shared/encounters.lua` — the registry

New file. Pure Lua: no natives called at load time, so `dofile` works under the
wasmoon harness (`tests/luarun.mjs`).

```lua
Encounters = {}

Encounters.IDS = {
    counter_pull   = true,
    fish_mindgame  = true,
    sonar_strike   = true,
    legacy_tension = true,
}

-- What an admin may select in FORCED mode. legacy_tension is deliberately absent:
-- forcing it would be a fourth mode wearing a third mode's clothes.
Encounters.FORCEABLE = {
    counter_pull  = true,
    fish_mindgame = true,
    sonar_strike  = true,
}

-- List-of-weights from day one so weighted random needs no resolver change --
-- ZUtil.weightedPick already consumes exactly this shape.
Encounters.RANDOM_POOL = {
    { id = 'counter_pull',  weight = 1 },
    { id = 'fish_mindgame', weight = 1 },
    { id = 'sonar_strike',  weight = 1 },
}

Encounters.MODES = { default = true, random = true, forced = true }

-- DOCUMENTATION AND ADMIN HINT ONLY. The resolver does not read this table.
-- See section 2.1.
Encounters.RECOMMENDED = {
    steady_light = 'counter_pull',
    steady_heavy = 'fish_mindgame',
    run_stop     = 'counter_pull',
    erratic      = 'fish_mindgame',
}

Encounters.DIFFICULTY_TIERS = { 1, 2, 3, 4, 5 }
```

`legacy_tension` is a member of `IDS` so that a resolved value can always be
validated against one set. It is excluded from `FORCEABLE` and `RANDOM_POOL`.

Extending the registry later (`rhythm_reel`, `pattern_memory`, `boss_fight`) means
adding an id, a pool entry, and an encounter module. `server/session.lua` does not
change.

### 3.2 Difficulty normalization

Also in `shared/encounters.lua`:

```lua
local TIER_BY_RARITY = { common = 1, uncommon = 2, rare = 3, epic = 4, legendary = 5 }

-- Pure function of the rolled fish. Deterministic given a roll, so a test can
-- assert tier without stubbing RNG.
function Encounters.TierFor(rarity, weight, wMin, wMax)
    local t = TIER_BY_RARITY[rarity] or 1
    local ratio = (weight - wMin) / math.max(0.001, wMax - wMin)
    if ratio >= 0.75 then t = t + 1 end   -- a big specimen of its species fights harder
    return ZUtil.clamp(t, 1, 5)
end
```

The five rarities map 1:1 onto the five tiers. This is not a new progression axis:
`Config.Rarity[*].tension` (1.0 / 1.15 / 1.3 / 1.5 / 1.8) is already the same ordering
expressed as a multiplier, and `Generator.Roll` already emits it as `tensionDiff`.

`Generator.Roll` gains one field in its return table:

```lua
difficulty = Encounters.TierFor(fish.rarity, weight, fish.weight.min, fish.weight.max),
```

**Equipment is deliberately excluded from the tier.** Tier is a property of the fish
alone. That makes the PART 19/20 invariants — "FORCED preserves fish difficulty",
"RANDOM preserves fish difficulty" — directly testable: assert `tier` is identical
across all three modes for the same roll.

Gear enters each encounter as separate, named knobs:

| gear stat | source | effect inside an encounter |
| --- | --- | --- |
| `lineRating` | `Config.Equipment.lines[*].rating` | size of the line-health pool, via the lookup below |
| `reelDrain` | `Config.Equipment.reels[*].drainRate` | stamina removed per successful action — **counter-pull only**, see section 5.3 |
| `greenZone` | `Config.Equipment.rods[*].greenZone` | widens counter window / decision time / weak spot by `1 + greenZone` |
| float tier | `Config.Equipment.floats` | **sonar readability in the NUI only** — never changes a server-side hit window |

The float rule is what keeps Sonar Strike playable without a Smart Float: better
floats draw a clearer picture, they do not make the target bigger.

**A raw equipment stat is never used directly as a multiplier.** Line ratings are
10 / 20 / 40 / 60, so a naive `lineRating / 10` yields 1x / 2x / 4x / 6x. At tier 5
that turns a base pool of 80 into 480 for a 60lb line — but tier 5 also has
`maxMisses = 4` and `mistakeDamage = 30`, so four mistakes deal 120 damage and the
fish escapes on the miss count long before the line is anywhere near breaking. Every
upgrade past 20lb would buy nothing an encounter could ever express.

Line health therefore uses an explicit, encounter-facing curve in the registry:

| line | rating | pool multiplier |
| --- | --- | --- |
| `line_10` | 10 | 1.00x |
| `line_20` | 20 | 1.15x |
| `line_40` | 40 | 1.30x |
| `line_60` | 60 | 1.45x |

The implementation plan must check this curve against `mistakeDamage` and `maxMisses`
per tier and confirm that both failure conditions stay reachable — a line upgrade
should change *which* failure you are racing, not retire one of them.

### 3.3 `server/encounter.lua` — the one resolver

New file. This is the **only** place an encounter type is chosen. `session.lua`,
`generator.lua`, the client and the NUI all consume its answer and never re-derive it.

```lua
function Encounter.Resolve(fish)
    -- A bad DB value must not brick fishing. Fall back to the safe mode, do not error.
    local mode = Encounters.MODES[Config.EncounterMode] and Config.EncounterMode or 'default'

    if mode == 'forced' then
        local forced = Config.ForcedEncounter
        return Encounters.FORCEABLE[forced] and forced or 'legacy_tension', mode
    end

    if mode == 'random' then
        return ZUtil.weightedPick(Encounters.RANDOM_POOL).id, mode
    end

    return Encounters.IDS[fish.encounter] and fish.encounter or 'legacy_tension', mode
end
```

**Availability is separate from selection.** `Encounter.Resolve` is pure policy.
During the phased rollout the selected encounter may have no module deployed yet, so
`server/session.lua` calls `Encounter.ResolveForSession`, which downgrades an
unavailable id to `legacy_tension` and reports what it downgraded. Each phase registers
its module and the downgrade stops applying to that id. Without this, an admin setting
FORCED to an unbuilt encounter after Phase A would break fishing for everyone.

Debug logging (behind the existing debug/print conventions, one line per cast, not
per action):

```
[zfishing] encounter resolved session=<id> species=<s> behavior=<b> rarity=<r> mode=<m> encounter=<e> tier=<n>
```

### 3.4 Session binding and freezing

The encounter **type and tier are resolved at cast time**, alongside the fish roll.
The encounter **challenge state is built at hook time**, when the fight actually
starts. An admin changing `EncounterMode` between a player's cast and their hook does
not affect that session.

`sessions[src]` gains one sub-table:

```lua
sessions[src].encounter = {
    -- frozen at cast, never re-read from Config afterwards
    type       = 'counter_pull',
    mode       = 'default',        -- what the mode was at cast time; for logs only
    difficulty = 3,

    -- built at hook
    challengeId = s.id .. '#' .. math.random(100000, 999999),
    seed        = math.random(1, 2^31 - 1),
    seq         = 0,               -- last accepted client sequence number
    startedAt   = GetGameTimer(),
    expiresAt   = GetGameTimer() + deadline,   -- see below

    state   = { ... },             -- encounter-specific, owned entirely by the server
    outcome = nil,                 -- nil | 'success' | 'escape' | 'snap' | 'timeout'
    perf    = { hits = 0, misses = 0, perfect = 0 },
}
```

`challengeId` embeds the session id, so a challenge minted for one fishing session can
never be replayed into another: the request is rejected twice over, once by
`sessionFor(src, sessionId)` and once by the `challengeId` comparison.

**The deadline is derived, not a constant.** Each encounter module reports the
worst-case honest fight length for its tier. Each estimate must count the **longest
survivable** run, not the flawless one — a fight that ends in a win after several
mistakes is the case that has to fit:

| encounter | estimate |
| --- | --- |
| `counter_pull` | `(counters + maxMisses) * (telegraph + counterWindow)` plus its fatigue windows |
| `fish_mindgame` | `(turns + escapeThreshold + 1) * decisionTime` — wrong answers return stamina, so they add turns; the `+1` is the forced landing turn |
| `sonar_strike` | `(requiredHits + maxMisses - 1) * passDuration` — the maximum attempts of section 6.4, not `requiredHits` |

The deadline is that estimate with headroom:

```lua
deadline = ZUtil.clamp(estimatedFightMs * 1.75, 15000, 120000)
```

`Config.Timings.reelTimeout` continues to govern `legacy_tension` sessions and nothing
else. A turn-based encounter at tier 5 legitimately runs longer than 30s, so reusing
that constant would kill honest fights.

**One timer per encounter**, not a tick loop. A single `SetTimeout` fires at
`expiresAt`; per-turn and per-window deadlines are evaluated lazily when the next
action arrives. The timer guards on object identity exactly as the existing bite and
hook-timeout timers do (`if not s or s.fish ~= fish then return end`,
`server/session.lua:216`) so a src that changed hands is never touched.

**No client-supplied encounter, anywhere.** `zfishing:cast` keeps its existing
signature `(src, power, rodSlot)`. No callback in this design accepts a requested,
preferred or hinted encounter type from the client. The client learns which encounter
it is playing only from the server's own hook-time payload.

**Disconnect.** `playerDropped` already calls `reset(src)`, which nils the whole
session including `encounter`. The expiry timer's identity guard then makes its own
firing a no-op. No new cleanup path is needed.

### 3.5 The action contract

One new callback. All three encounters share it.

```lua
lib.callback.register('zfishing:encounter:act', function(src, sessionId, challengeId, seq, action)
```

Rejection order — each step is cheaper than the one after it:

| # | check | failure reason |
| --- | --- | --- |
| 1 | `gate.allow(src, 'encounter')` | `too_many_requests` |
| 2 | `sessionFor(src, sessionId)` — the existing helper, never `sessions[src]` directly | `invalid_session` |
| 3 | `s.encounter and s.encounter.type ~= 'legacy_tension'` | `no_encounter` |
| 4 | `s.encounter.challengeId == challengeId` | `stale_challenge` |
| 5 | `s.encounter.outcome == nil` | `encounter_over` |
| 6 | `seq == s.encounter.seq + 1` | `bad_seq` |
| 7 | action is a member of the encounter's action set | `bad_action` |

Step 6 is one comparison covering every sequencing attack the brief lists: a duplicate
seq is not `seq+1`, an older seq is not `seq+1`, a fabricated future seq is not
`seq+1`. A previously successful action cannot be replayed because its seq is now in
the past.

Step 7 rejects a structurally invalid action. An action that is *well-formed but wrong
for the current state* (bracing when the fish is running) is not an error — it is a
miss, and it is scored as one.

The response always carries the authoritative sequence number so a client that lost a
reply can resynchronise rather than desynchronise:

```lua
{ ok = true, seq = s.encounter.seq, state = <render payload>, outcome = <nil or terminal> }
```

#### The no-input problem, and the `advance` action

Lazy deadline evaluation has a hole: **if the player never acts, no action arrives, so
nothing evaluates the deadline.** A counter-pull phase whose window closed sits in
`LEFT_RUN` forever. A mindgame turn whose decision deadline passed is specced as "a
missed deadline is scored as a wrong answer", but there is no request that would
execute that transition. A sonar attempt with no strike is specced as a MISS, but
nothing produces the MISS. In every case the encounter stalls until overall expiry and
resolves as `timeout` — which is the wrong outcome, and takes far too long to reach it.

The fix costs no server tick. The NUI sends a **neutral `advance` action** when its
own local deadline passes, and the server validates that the deadline really has:

```lua
if action == 'advance' then
    if GetGameTimer() < phase.deadline then return { ok = false, reason = 'bad_action' } end
    -- the SERVER decides what an expired deadline means:
    --   counter_pull   -> miss
    --   fish_mindgame  -> wrong answer
    --   sonar_strike   -> missed attempt
end
```

The client cannot use this to go faster: an early `advance` is rejected, so each one
costs real elapsed time. It cannot use it to go slower in any useful way either — a
late `advance` only delays a transition the player already lost, and the overall
expiry backstops a client that stops sending them entirely.

`advance` is deliberately **not** called `timeout`: `timeout` is a terminal encounter
outcome (section 3.7), and reusing the word for a per-turn transition would make log
lines and test names ambiguous.

`advance` consumes a `seq` like any other action, so it is covered by the same replay
and ordering guarantees, and it counts against the flood gate.

**Flood gate.** One new entry in the existing table at `server/session.lua:11`:

```lua
encounter = { max = 40, window = 10000 },
```

Sizing: counter-pull is by far the busiest encounter — a tier-5 fight is on the order
of 28 counters plus fatigue reels across roughly 31 seconds; mindgame tops out at 9
turns; sonar at 5 strikes. `ZUtil.MakeRateGate` is a **fixed** window, not a sliding
one (`shared/util.lua:39`), so the real constraint is the busiest 10-second slice of a
tier-5 counter-pull, not the whole-fight average.

The implementation plan must compute that worst honest slice from the tier-5 table and
set `max` to at least twice it. `40` is the starting proposal, not a verified figure —
do not treat it as settled without doing the arithmetic against the final tier
numbers.

Flooding still cannot accelerate a catch regardless of the limit: `seq` must strictly
advance, and every unit of progress is computed server-side.

Flooding cannot accelerate a catch: `seq` must strictly advance, and every unit of
progress is computed server-side from the server's own state.

### 3.6 The claim boundary — where authority is won

`zfishing:claim` stays the **single door** to settlement. No `CounterPullClaim`, no
`SonarClaim`. One branch is added:

```lua
if s.encounter and s.encounter.type ~= 'legacy_tension' then
    if not s.encounter.outcome then
        return { ok = false, reason = 'encounter_active' }
    end
    -- The server counted every action itself. The client's `success` and `reason`
    -- arguments are ignored outright -- there is nothing left to take on trust, and
    -- the `too_fast` plausibility floor exists only because the legacy minigame
    -- runs entirely on the client.
    success = (s.encounter.outcome == 'success')
    reason  = success and nil or s.encounter.outcome
end
```

A `legacy_tension` session takes the existing path unchanged, including the `minMs`
plausibility floor at `server/session.lua:254`.

The elapsed-time ceiling at `server/session.lua:262` —
`elapsed > Config.Timings.reelTimeout + 5000` — must also become encounter-aware.
For an encounter session it compares against `s.encounter.expiresAt` instead; leaving
it on `reelTimeout` would reject a legitimately-won tier-5 fight as a timeout.

Everything downstream of this branch — the `settling` lock, the `pcall` backstop, the
identity guard, the `Config.RateLimit` accounting, `Rewards.GiveCatch` — is untouched.

### 3.6.1 The XP bonus

**Each encounter module reports its own `perfScore` in 0..1**, and a flawless fight
must return exactly `1.0` in all three. A single shared formula does not work: only
sonar has a PERFECT band, so a shared `perfect`-weighted expression would pay more XP
for a flawless sonar fight than a flawless counter-pull — and under RANDOM the
encounter is pure luck, so identical skill would earn different XP for no reason the
player can see or influence.

All three take the same shape — **the average quality of the actions you actually
took** — so the numbers are comparable across encounters rather than merely all
topping out at 1.0:

| encounter | score | action values |
| --- | --- | --- |
| `counter_pull` | `sum(actionValues) / attempts` | correct counter 1.0, miss 0 |
| `fish_mindgame` | `sum(actionValues) / turnsTaken` | correct answer 1.0, wrong 0 |
| `sonar_strike` | `sum(actionValues) / attempts` | PERFECT 1.0, SAFE 0.7, MISS 0 |

Each is clamped to 0..1 and reaches exactly 1.0 on a flawless fight.

Two earlier formulas were dropped for reasons worth recording. `1 - misses/maxMisses`
for counter-pull could never reach 0 on a *successful* catch, because reaching
`maxMisses` ends the fight as an escape — so the documented range was wrong.
`perfectStrikes / requiredHits` for sonar was too coarse to be useful: a tier-1 fight
with two required hits could only ever score 0, 0.5 or 1.0, and a tier-2 fight only
0, 0.33, 0.67 or 1.0. Giving SAFE partial credit and dividing by attempts smooths both
and makes a sonar score mean the same kind of thing a mindgame score does.

It is passed to settlement in the existing context table
(`Rewards.GiveCatch(src, fish, zone, { sessionId, identifier, perfScore })`) and
applied at exactly one place, the XP grant:

```lua
local xp = math.floor(fish.xp * (1 + 0.25 * (ctx.perfScore or 0)))
```

`Rewards.Price`, `qualityMult`, `fish.weight`, `fish.quality` and
`Rewards.RollRareLoot` are not touched. A `legacy_tension` session passes no
`perfScore` and gets `fish.xp` exactly as today.

### 3.7 Outcome normalization

Every encounter terminates in exactly one of four values, matching the vocabulary the
resource already uses:

| outcome | meaning | typical cause |
| --- | --- | --- |
| `success` | fish landed | stamina exhausted and the landing action succeeded |
| `snap` | line broke | line health reached zero |
| `escape` | fish got away | too many misses / escape pressure threshold |
| `timeout` | ran out of time | `expiresAt` passed with no terminal outcome |

Encounter-internal failure detail (`bad_seq`, `stale_challenge`) never reaches reward
logic. It is answered on the action callback and never becomes an outcome.

**Both existing consumers of the failure reason read it from the client and must be
rewired.** Today the reason arrives as the fifth argument of `zfishing:claim`, sent by
the NUI:

- `if reason == 'snap' and s.rigSlot then Rig.breakLine(...)` (`server/session.lua:269`)
- `endFishing(body.reason == 'snap' and 'line_broke' or 'fish_escaped')`
  (`client/minigame.lua:97`), where `body.reason` is what the NUI reported

For an encounter session the client does not know the reason — the server does. Left
as-is, an encounter snap would never destroy the line component, and `snap`, `escape`
and `timeout` would all render to the player as "the fish got away". Three changes:

1. `Rig.breakLine` keys off `s.encounter.outcome == 'snap'` for encounter sessions,
   and off the client `reason` only for `legacy_tension`.
2. A failed claim returns the authoritative outcome to the client:
   `{ ok = true, fish = nil, outcome = 'snap' }`.
3. `client/encounter.lua` renders the end-of-fight message from that returned
   `outcome`, not from anything it computed itself. `client/minigame.lua` keeps its
   existing `body.reason` behaviour for the legacy path.

### 3.8 Settings and persistence

Two new settings. Adding a setting to this resource touches **five** places; missing
any one of them fails silently in a different way.

| location | addition | what breaks if missed |
| --- | --- | --- |
| `config/main.lua` | `Config.EncounterMode = 'default'`, `Config.ForcedEncounter = 'counter_pull'` | no static seed value |
| `ConfigSchema.Settings` (`server/config_schema.lua:7`) | two `enum` entries bound to `Encounters.MODES` / `Encounters.FORCEABLE` | admin writes are unvalidated |
| `SETTING_KEYS` (`server/store.lua:8`) | both keys | `Store.Load` never reads them back; `ResetDomain` never clears them |
| `Store.Seed()` (`server/store.lua:26-34`) | two `putSetting` calls | no DB row on first boot |
| `zfishing:admin:getConfig` settings payload (`server/admin.lua:14-20`) | two fields | the admin UI cannot read the current values |

Schema:

```lua
EncounterMode    = { type = 'enum', values = Encounters.MODES },
ForcedEncounter  = { type = 'enum', values = Encounters.FORCEABLE },
```

An invalid stored value is not an error at read time — `Encounter.Resolve` falls back
to `default` / `legacy_tension` (section 3.3). The enum only prevents an invalid value
being *written*.

**Hot change comes free.** `Store.SaveSetting` already does
`Config[key] = clean; putSetting(key, clean); Store.Broadcast()`
(`server/store.lua:162`). The resolver reads `Config.EncounterMode` at cast time and
freezes the answer into the session, so PART 5's invariant — an in-flight fight never
changes encounter — falls out of the existing lifecycle with no new machinery.

**Neither key is added to `clientPayload()`** (`server/store.lua:125`). That function
broadcasts to every client; encounter selection is a server decision and the client
has no business knowing the global mode.

### 3.9 Fish schema

`ConfigSchema.ValidateFish` (`server/config_schema.lua:100`) returns a **whitelist** —
`{label, water, weight, rarity, price, baits, behavior, xp}`. An `encounter` field
added to `config/fish.lua` survives `Store.Seed()` (which `json.encode`s the raw
table) but is stripped the first time an admin saves that fish through the panel.

`ValidateFish` returns a **table literal** — unlike `ValidateEquipment`, it has no
`clean` local — so the field is validated before the return and carried into the
literal:

```lua
    -- ... after the existing xp / water / baits validation, before the return:
    if data.encounter ~= nil and not Encounters.IDS[data.encounter] then
        return nil, 'unknown encounter'
    end
    return { label = data.label, water = water, weight = { min = wmin, max = wmax },
             rarity = data.rarity, price = price, baits = baits,
             behavior = data.behavior, xp = xp,
             encounter = data.encounter }
```

`nil` is valid and means "use the fallback". A present-but-unknown value is a hard
validation error, not a silent drop.

### 3.9.1 Getting the pilot mapping onto a server that has already booted

Adding `encounter` to `config/fish.lua` is, on its own, a **no-op on every existing
server**. This is the single most likely way for this feature to ship and appear to do
nothing:

- `Store.Seed()` gates fish seeding on `getSetting('_seeded_fish')`
  (`server/store.lua:45`). On a live server that marker already exists, so the new
  static values are never inserted.
- `Store.Load()` then does `if next(fish) then Config.Fish = fish end`
  (`server/store.lua:80`) — a wholesale replacement of `Config.Fish` with DB rows that
  have no `encounter` key.
- The resolver therefore sees `fish.encounter == nil` for all ten fish and returns
  `legacy_tension` forever, while every unit test passes because tests construct
  `Config` directly.

The repository has already solved this exact shape once, for equipment: `Store.Load`
compares each DB row against a `staticEquipment` snapshot taken before load and
backfills keys the row is missing, preserving admin edits and writing the result back
(`server/store.lua:85-97`). Fish has no equivalent.

**This design adds the same backfill for fish**, mirroring the equipment one. It is
the existing convention and it does not require an operator to remember a manual step.

That backfill only fills keys a row **lacks**, which creates one requirement on the
admin UI: the Fish tab's legacy option must write `encounter = 'legacy_tension'`
**explicitly**, never omit the key. Omitting it would make the backfill re-add the
pilot encounter on the next boot and silently undo an operator's rollback.
`legacy_tension` is a member of `Encounters.IDS`, so it validates and the resolver
returns it directly. An absent `encounter` key therefore means exactly one thing:
"never configured".

### 3.10 Client and NUI transport

```
NUI component
  -> fetchNui('encounterAction', { seq, action, ...payload })
  -> client/encounter.lua  (RegisterNUICallback)
  -> lib.callback.await('zfishing:encounter:act', sessionId, challengeId, seq, action)
  -> server evaluates, advances, returns authoritative state
  -> SendNUIMessage({ action = 'encounterState', ... })
  -> NUI re-renders
```

`client/encounter.lua` is a **bridge only**: no simulation, no timers beyond input
polling, no high-frequency loop. `client/minigame.lua` keeps the legacy bite/reel path
untouched and is entered only when `encounter.type == 'legacy_tension'`.

New files:

| file | role |
| --- | --- |
| `shared/encounters.lua` | registry, tier function, recommended map |
| `server/encounter.lua` | resolver, challenge lifecycle, action dispatch, outcome normalization |
| `server/encounter_counter_pull.lua` | counter-pull state machine |
| `server/encounter_mindgame.lua` | mindgame turn model |
| `server/encounter_sonar.lua` | sonar timeline generation and strike evaluation |
| `client/encounter.lua` | NUI <-> callback bridge, input polling |
| `web/src/encounters/EncounterHost.tsx` | shared shell, dispatch by type |
| `web/src/encounters/CounterPull.tsx` | |
| `web/src/encounters/FishMindgame.tsx` | |
| `web/src/encounters/SonarStrike.tsx` | |
| `web/src/engine/sonarTimeline.ts` | deterministic path math mirroring the Lua side |
| `web/src/encounters/types.ts` | shared payload types |

**Server Lua files must stay flat.** `tests/luarun.mjs:33` mounts `client/`, `server/`
and `shared/` with a non-recursive `readdirSync`. A module at `server/encounters/x.lua`
would be invisible to the Lua harness and therefore untestable.

Load order in `fxmanifest.lua`: `shared/encounters.lua` goes into `shared_scripts`
**after `shared/util.lua`** — it calls `ZUtil.clamp` — and before `config/*`. The
three `server/encounter_*.lua` modules load before `server/encounter.lua`, which loads
before `server/session.lua`. `server/config_schema.lua` must load after
`shared/encounters.lua` because its enum schemas reference `Encounters.MODES` and
`Encounters.FORCEABLE`; shared scripts already load ahead of server scripts, so this
holds without reordering the server block.

---

## 4. Encounter 1 — `counter_pull`

**Identity.** The player fights the fish by reacting to the direction it pulls. Not a
moving green zone.

### 4.1 Inputs

Chosen because these controls are analog on a gamepad already, so controller support
needs no separate mapping and no button mashing.

| intent | control | keyboard | controller |
| --- | --- | --- | --- |
| counter left | `34` INPUT_MOVE_LEFT_ONLY | A | left stick left |
| counter right | `35` INPUT_MOVE_RIGHT_ONLY | D | left stick right |
| brace | `33` INPUT_MOVE_DOWN_ONLY | S | left stick down |
| reel | `22` (already used by the legacy fight) | SPACE | A / cross |

### 4.2 State machine

Fish states: `LEFT_RUN`, `RIGHT_RUN`, `DIVE`, `FATIGUED`, `LANDING`.

```
server builds a phase:
    { state, telegraphAt, windowOpensAt, windowClosesAt, required, fake? }
        |
        v  cue renders the moment the client receives the payload
player presses the counter -> act(seq, action)
        |
        +-- correct  -> stamina -= 8 * reelMult
        +-- wrong or window missed -> line -= mistakeDamage, stamina += 3, misses += 1
        |
        v  after N correct counters
    FATIGUED  (long window; up to k reels, each stamina -= 12 * reelMult)
        |
        v  stamina <= 0
    LANDING   (one final reel inside one window)
        |
        +-- hit  -> outcome = 'success'
        +-- miss -> fish recovers to stamina 25, fight continues
```

Counter map: `LEFT_RUN` -> right, `RIGHT_RUN` -> left, `DIVE` -> brace,
`FATIGUED` and `LANDING` -> reel.

**Grace: +/-250ms** on both edges of every window, in the same spirit as
`Config.Timings.hookLatency = 300`. A server window narrower than real network jitter
would fail honest players, which PART 12 explicitly warns against.

### 4.3 Tier parameters

| tier | telegraph | counterWindow | counters per fatigue | reels per fatigue | stamina | line | mistake damage | maxMisses | fakeChance |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 900ms | 1400ms | 3 | 2 | 100 | 100 | 20 | 6 | 0 |
| 2 | 800ms | 1200ms | 3 | 2 | 120 | 100 | 22 | 5 | 0 |
| 3 | 650ms | 1000ms | 4 | 3 | 150 | 90 | 25 | 5 | 0.10 |
| 4 | 520ms | 850ms | 4 | 3 | 180 | 85 | 28 | 4 | 0.18 |
| 5 | 420ms | 700ms | 5 | 3 | 220 | 80 | 30 | 4 | 0.25 |

`counterWindow` is multiplied by `1 + rodGreenZone`. `line` is scaled by the line
curve of section 3.2, not by `lineRating / 10`. `reelMult` is the reel's `drainRate`
— counter-pull is the one encounter where it multiplies stamina damage (section 5.3
explains why the mindgame does not).

Two independent failure clocks run in parallel and that is intentional: `line`
punishes *how badly* you were wrong (mistake damage), `maxMisses` punishes *how often*.
A player on heavy line survives more mistakes but not more of them.

### 4.4 Fake telegraphs

Only at tier 3 and above, at `fakeChance`.

The server decides the fake **when it builds the phase**, keeps the resulting
`required` counter entirely to itself, and sends the NUI only what it needs to draw:
`displayCue = X`, `switchAt`, `nextDisplayCue = Y`, and the window times. `switchAt`
is constrained to be **at least 400ms before `windowClosesAt`**, so the NUI always has
time to render a visible flip. There is no unavoidable RNG failure: a player watching
the cue can always react to the switch.

**Render data is not resolution data.** No encounter payload carries the required
answer. A player can derive the counter from the cue — that is the game — but a
payload field spelling out `required = counter_right` hands an auto-counter bot the
answer without it having to interpret anything, and buys an honest client nothing. The
same rule applies to the mindgame telegraph (section 5.4) and to the sonar weak-spot
band, which the NUI reconstructs from the pass record rather than being told about.

### 4.5 State selection by behavior

Weighted, using the four behavior names that actually exist in `config/fish.lua`:

| behavior | weighting |
| --- | --- |
| `steady_light` | favours LEFT_RUN / RIGHT_RUN, rare DIVE |
| `steady_heavy` | favours DIVE |
| `run_stop` | long runs alternating with pauses |
| `erratic` | uniform across states, highest fake rate |

### 4.6 Outcomes

`line <= 0` -> `snap`. `misses >= maxMisses` -> `escape`. `now > expiresAt` ->
`timeout`. Otherwise `success`.

### 4.7 Presentation and accessibility

The cue is carried by direction, icon shape, world animation and sound — never by
colour alone: an arrow pointing the pull direction, a distinct icon silhouette per
state, the rod visibly leaning, a splash on the side the fish runs to, and a sound
cue. Text labels accompany the icons.

---

## 5. Encounter 2 — `fish_mindgame`

**Identity.** Read, decide, counter. Turn-based, not continuous reflex.

### 5.1 Actions and responses

Fish actions: `RUN`, `DIVE`, `THRASH`, `JUMP`, `REST`.
Player responses: `GIVE_LINE`, `BRACE`, `HOLD`, `REEL`.

| fish action | correct response | on correct | on wrong |
| --- | --- | --- | --- |
| `RUN` | `GIVE_LINE` | stamina -- | line --, stamina + |
| `DIVE` | `BRACE` | stamina -- | line --- |
| `THRASH` | `HOLD` | stamina -- | escapePressure + |
| `JUMP` | `GIVE_LINE` | stamina -- | escapePressure ++ |
| `REST` | `REEL` | stamina -- -- (double value) | turn wasted, stamina + |

`RUN` and `JUMP` share a correct response on purpose. They differ in the **cost of
being wrong**, not in the answer. This keeps the table readable while stopping the
encounter degenerating into rock-paper-scissors: knowing the species tells you how bad
a mistake is about to be, not merely which button to press.

### 5.2 Behavior profiles

Each behavior is a weighted Markov chain over the fish actions. This is the mechanism
behind PART 8's design goal — players learning species behavior.

| behavior | characteristic sequence | what a player learns |
| --- | --- | --- |
| `steady_light` | RUN -> REST -> RUN -> THRASH | most predictable; safe to learn on |
| `steady_heavy` | DIVE -> DIVE -> REST | "catfish usually dives twice before resting" |
| `run_stop` | RUN -> RUN -> REST | long runs, then a reel opportunity |
| `erratic` | weighted random, includes JUMP, highest fake rate | cannot be pre-read; must be answered live |

### 5.3 Tier parameters

| tier | turns | decision time | line | escape threshold | fakeChance |
| --- | --- | --- | --- | --- | --- |
| 1 | 3 | 3000ms | 100 | 4 | 0 |
| 2 | 4 | 2600ms | 100 | 4 | 0 |
| 3 | 5 | 2200ms | 90 | 3 | 0.10 |
| 4 | 7 | 1900ms | 85 | 3 | 0.20 |
| 5 | 9 | 1600ms | 80 | 3 | 0.25 |

Turn counts sit inside the brief's targets (common 3-5, uncommon/rare 5-7,
epic/legendary 6-10). Decision time is multiplied by `1 + rodGreenZone`.

**`turns` is what makes the tier real.** Stamina starts at 100 and each correct
response removes `100 / turns`, so a flawless fight lands the fish in exactly `turns`
correct answers. A wrong answer returns `50 / turns` stamina, which is why mistakes
lengthen a fight rather than only damaging it.

**The reel's `drainRate` deliberately does not multiply that damage.** It would break
the sentence above: with an Electric Reel (`drainRate = 1.7`) a tier-5 fight would
land in about 6 correct answers instead of 9, and a tier-1 fight in 2 instead of 3.
The number of reads *is* this encounter's content, so letting gear delete a third of
them removes gameplay rather than rewarding investment — and it would make the tier
figure in the table untrue.

Reel quality helps the mindgame in ways that do not shorten it:

- a wrong answer returns less stamina (a better reel holds ground under a mistake)
- the `REST` -> `REEL` play converts into more stamina damage
- the landing turn below is more forgiving

Counter-pull is the opposite case and keeps its `drainRate` multiplier on stamina:
it is a continuous fight, not a fixed number of decisions, and its tier is carried by
telegraph and window timings rather than by a turn count.

Escape pressure accrues only on the two actions where a wrong answer risks the hook:
a wrong `THRASH` answer adds 1, a wrong `JUMP` answer adds 2. Reaching the tier's
threshold ends the fight as `escape`.

### 5.4 Fake telegraphs

Tier 4-5 only. The server sends `displayCue`, `switchAt` and `nextDisplayCue` — never
the correct response, per the render-vs-resolution rule in section 4.4. `switchAt` is
constrained to be **at least 700ms before the decision deadline** — more headroom than
counter-pull because a mindgame response is a considered choice, not a reflex.

### 5.5 Outcomes

`line <= 0` -> `snap`. `escapePressure >= threshold` -> `escape`. A missed decision
deadline is scored as a wrong answer, not as a separate failure — the `advance` action
of section 3.5 is what makes the server execute that transition. `now > expiresAt` ->
`timeout`.

**Landing is a forced turn, not a second resource.** When stamina reaches zero the
server overrides the behavior chain and issues a `LANDING` turn: one `REEL` inside one
decision window ends the fight as `success`; missing it returns the fish to stamina 25
and the chain resumes.

This exists because the Markov chain gives no guarantee about `REST`. A tier-5 fish
could legitimately roll RUN / DIVE / THRASH / RUN / DIVE / JUMP / RUN / DIVE / THRASH
and never rest once — under a design where landing required a separate progress
counter fed only by `REST`, that fish would be unwinnable through no fault of the
player. Forcing the landing turn makes an unwinnable state unreachable by RNG, and it
mirrors counter-pull's `LANDING` state (section 4.2), so both encounters end the same
way.

### 5.6 Presentation and accessibility

Each fish action has a distinct icon **shape** plus a text label plus a distinct
animation. Response buttons carry both an icon and a label, and are keyboard- and
controller-reachable. No cue depends on colour.

---

## 6. Encounter 3 — `sonar_strike`

**Identity.** The player watches the fish move through a compact sonar view and
strikes when its vulnerable window crosses the target. Not a shrinking circle, and not
a green bar.

### 6.1 The pass record

The server generates the full set of attempts up front from the challenge seed — the
count is bounded at `requiredHits + maxMisses - 1` (section 6.4), so pre-generating
them all is finite, and it keeps the timeline deterministic from the seed alone, which
is what the cross-language parity fixture of section 9.3 depends on. Attempts past the
terminating one are simply never used.

```lua
pass = {
    index, startAt, duration,
    profile,                      -- movement profile, from fish behavior
    speed, dir,
    weakOffset, weakHalf,         -- normalized 0..1 across the lane
    perfectHalf,
    decoy,                        -- optional false echo, tier >= 4 on erratic fish
}
```

`posAt(t)` is pure mathematics over this record. It is implemented **twice** — in
`server/encounter_sonar.lua` and `web/src/engine/sonarTimeline.ts` — and a committed
fixture guarantees the two agree (section 9.3).

### 6.2 Movement profiles

| behavior | profile | movement |
| --- | --- | --- |
| `steady_light` | DART | fast linear pass |
| `steady_heavy` | HEAVY | slow, but a narrower weak zone |
| `run_stop` | STALKER | forward, pause, reverse, accelerate |
| `erratic` | GHOST | signal fades and returns; decoy echo at tier >= 4 |

### 6.3 Strike evaluation

**The client does not tell the server when it struck. It tells the server *that* it
struck, and the server decides when that was.**

An earlier draft of this design had the client send `atMs` (its own elapsed time into
the pass) and the server accept it if `now - (startAt + atMs)` fell inside
`[-100ms, +1200ms]`. That is not server authority, it is a retrospective selection
window. A modified client knows the canonical timeline — it has to, in order to draw
it — so it can wait until `now = startAt + 2400`, then submit `atMs = 1840` because
1840 is the perfect centre. The arrival check passes (`2400 - 1840 = 560ms`) even
though the player struck at no such moment. The wider the latency allowance, the
bigger the cheat.

The strike payload is therefore:

```
{ challengeId, seq, passIndex, action = 'strike' }
```

and the server derives the moment itself:

```lua
local receivedAt   = GetGameTimer()
local ping         = GetPlayerPing(src)
local compensation = ZUtil.clamp(ping * 0.5, 0, MAX_COMPENSATION)   -- MAX_COMPENSATION = 200ms
local strikeAt     = receivedAt - compensation
local t            = strikeAt - pass.startAt
```

```
1. passIndex must equal the current pass          -> stale_pass
2. t must fall within [0, duration]               -> MISS (struck outside the pass)
3. d = |posAt(t) - weakCenter(t)|
       d <= perfectHalf  -> PERFECT   (one hit, perfect++)
       d <= weakHalf     -> SAFE      (one hit)
       otherwise         -> MISS      (line damage, misses++)
4. the pass ends with no strike                   -> MISS (via the `advance` action, section 3.5)
```

A client may send a `clientAtMs` alongside the strike. It is recorded for telemetry
and debug logging and **must not appear in any expression that decides a hit, a
grade, or a reward.**

What a modified client can still do is *delay* — arrive later than a human would. That
moves `strikeAt` forward in real time only; it can never move it backward, so there is
no way to select a favourable past moment. Delaying is exactly the power an honest
laggy player has, and it makes strikes worse, not better.

**SAFE and PERFECT advance the encounter by exactly the same amount — one hit.**
PERFECT buys nothing but score, which feeds the XP bonus of section 3.6.1. Letting a
perfect strike also shorten the fight would make the required hit count vary with
player skill and quietly break the tier-preservation invariant that sections 3.2 and
9.1 items 13-14 exist to protect.

Because the timeline comes from the server, **client frame rate cannot alter it**. A
30fps and a 240fps client are evaluated against the same `posAt`.

### 6.4 Tier parameters

`passes` is renamed `requiredHits`, because a missed attempt used to consume a pass
without producing a hit and the two counts are not the same thing. With
`requiredHits = 3, maxMisses = 2`, the sequence MISS / PERFECT / PERFECT left the
encounter with two hits, no passes remaining, and neither a success nor an escape
condition met — an undefined state.

The server generates a new attempt until one of two things is true:

```
hits   >= requiredHits  -> success
misses >= maxMisses     -> escape
```

so the longest possible successful fight is `requiredHits + maxMisses - 1` attempts.
The deadline estimate of section 3.4 must use **that** number, not `requiredHits`.

| tier | requiredHits | maxMisses | max attempts | pass duration | weakHalf | perfectHalf |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 2 | 3 | 4 | 4000ms | 0.18 | 0.07 |
| 2 | 3 | 3 | 5 | 3600ms | 0.15 | 0.06 |
| 3 | 3 | 2 | 4 | 3200ms | 0.12 | 0.05 |
| 4 | 4 | 2 | 5 | 2800ms | 0.10 | 0.04 |
| 5 | 5 | 2 | 6 | 2400ms | 0.08 | 0.03 |

Widths are normalized to the lane. `weakHalf` is multiplied by `1 + rodGreenZone`.

**These widths must be re-derived in milliseconds before implementation.** Server-side
lag compensation is approximate, so the real question is how much timing error a band
tolerates. At tier 5 a linear pass crosses the lane in 2400ms, so `perfectHalf = 0.03`
is a **±72ms** window — tighter than the compensation error budget, which would make
PERFECT partly a lottery on connection quality. The implementation plan must convert
every width to milliseconds of travel, compare against a stated error budget, and
widen the tight tiers as needed. The normalized figures above are a starting point,
not a tuned table.

### 6.5 Equipment

Float tier changes **what the NUI draws**: a clearer silhouette, and at the top tier a
weak-zone indicator band. It does **not** change `weakHalf` or `perfectHalf` on the
server. Sonar Strike is fully playable with a Wood Float; better tackle makes the
picture easier to read, not the target easier to hit.

### 6.6 Outcomes

`misses >= maxMisses` -> `escape`. `line <= 0` -> `snap`. `now > expiresAt` ->
`timeout`. `hits >= requiredHits` -> `success`.

### 6.7 Presentation and accessibility

Target identity is carried by shape and border treatment and position, not fill
colour. SAFE and PERFECT are distinguished by ring geometry and by a text/haptic
confirmation, not by hue alone.

---

## 7. Fish mapping

Tier column shows the tier for a mid-weight and a top-weight specimen where they
differ.

| fish | behavior | rarity | weight | tier | ships with | reason |
| --- | --- | --- | --- | --- | --- | --- |
| **mackerel** | steady_light | common | 0.4-3 | 1 | **`counter_pull`** | ocean-only, tier 1 — exercises the easiest tier without touching the freshwater loop |
| **catfish** | steady_heavy | uncommon | 2-20 | 2-3 | **`fish_mindgame`** | `steady_heavy` is literally DIVE -> DIVE -> REST, the brief's own worked example |
| **swordfish** | run_stop | epic | 40-200 | 4-5 | **`sonar_strike`** | deep-sea and exotic; exercises a high tier, and shares ocean water with mackerel so one trip tests two encounters |
| bass | steady_light | common | 0.5-5 | 1-2 | `legacy_tension` | *recommended: counter_pull* — most-caught fish; left on the legacy fight deliberately |
| trout | steady_light | common | 0.3-8 | 1-2 | `legacy_tension` | *recommended: counter_pull* |
| salmon | run_stop | uncommon | 1-15 | 2-3 | `legacy_tension` | *recommended: counter_pull* — runs then stops |
| pike | erratic | uncommon | 1-12 | 2-3 | `legacy_tension` | *recommended: fish_mindgame* — erratic must be read live |
| tuna | run_stop | rare | 15-80 | 3-4 | `legacy_tension` | *recommended: counter_pull* |
| shark | erratic | epic | 80-400 | 4-5 | `legacy_tension` | *recommended: sonar_strike* |
| golden | erratic | legendary | 0.5-2 | 5 | `legacy_tension` | *recommended: sonar_strike* |

The seven non-pilot fish ship with **no `encounter` key at all** — "unconfigured",
which the resolver turns into `legacy_tension`. They are deliberately not given an
explicit `encounter = 'legacy_tension'`: that value is reserved for an operator's
choice, and writing it here would take the backfill of section 3.9.1 off the table for
those fish when they are eventually promoted.

---

## 8. Admin surface

### 8.1 UI

One new `Section` in `web/src/admin/SettingsTab.tsx`. No second admin system, no new
tab.

```
+-- Fishing Encounter ---------------------------------+
| Mode        [ Default ] [ Random ] [ Forced ]        |
|             explanation text changes with selection  |
| Forced Encounter   [ Counter-Pull Fight        v ]   |   disabled unless mode = forced
| Currently active: DEFAULT - each fish uses its own   |
+------------------------------------------------------+
```

Explanations:

| mode | text |
| --- | --- |
| DEFAULT | Each fish uses its configured encounter. |
| RANDOM | A random encounter is selected for every new catch. |
| FORCED | Every new catch uses the selected encounter. |

A small `Segmented` control (~20 lines) is added to `web/src/admin/ui.tsx`, reusing
the existing `Btn` styling. The forced selector is **disabled**, not hidden, so the
current forced value stays visible while in another mode.

`web/src/admin/FishTab.tsx` gains a per-fish `encounter` dropdown with **four explicit
values and no null option**:

```
Counter-Pull Fight  -> counter_pull
Fish Mindgame       -> fish_mindgame
Sonar Strike        -> sonar_strike
Legacy Tension      -> legacy_tension
```

An admin save always writes one of those four. This is not cosmetic — an earlier draft
offered a "— (legacy)" option that wrote `nil`, which contradicts section 3.9.1: the
fish backfill fills keys a row lacks, so a `nil` rollback would be silently undone by
the pilot value on the next boot. With the null option gone, the two states mean
exactly one thing each:

| value | meaning |
| --- | --- |
| absent | never explicitly configured — the backfill may populate it |
| `legacy_tension` | an operator chose the legacy fight — the backfill leaves it alone |

The `Encounters.RECOMMENDED[behavior]` value is shown next to the dropdown as a hint.

**How the registry reaches the UI.** The registry is Lua and the admin panel is
TypeScript, so without a stated transport the obvious thing to write is a second copy
of the tables in TS — which will drift from the Lua one the first time an encounter is
added. `zfishing:admin:getConfig` therefore returns the registry itself:

```lua
encounters = {
    modes       = Encounters.MODES,
    forceable   = Encounters.FORCEABLE,
    recommended = Encounters.RECOMMENDED,
},
```

This lives in the **admin** payload only. `clientPayload()` (`server/store.lua:125`)
still carries none of it, for the same reason it carries neither setting: it
broadcasts to every player. `shared/encounters.lua` stays the single source of truth,
and the admin UI holds no hardcoded encounter list.

### 8.2 Authorization

**No new server callback.** Both settings are written through the existing
`zfishing:admin:saveSetting`, which already checks `isAdmin(src)` before
`Store.SaveSetting` (`server/admin.lua:30`). Access to the NUI admin page grants
nothing on its own: `client/admin.lua`'s `adminSave` passthrough reaches a callback
that re-checks permission server-side every time, and the enum schema rejects an
unregistered encounter string even from a genuine admin.

---

## 9. Test plan

### 9.1 Lua suites

Run through the existing wasmoon harness: `node tests/luarun.mjs tests/<file>`.

| file | covers | count |
| --- | --- | --- |
| `tests/encounter_resolver.test.lua` | PART 25, items 1-14 | 14 |
| `tests/encounter_counter_pull.test.lua` | PART 26, all items | 14 |
| `tests/encounter_mindgame.test.lua` | PART 27, all items | 14 |
| `tests/encounter_sonar.test.lua` | PART 28, all items | 14 |
| `tests/encounter_admin.test.lua` | PART 29, all items | 6 |

Resolver suite (PART 25), explicitly:

1. DEFAULT resolves an explicit `fish.encounter`.
2. DEFAULT falls back to `legacy_tension` when the field is absent.
3. DEFAULT falls back to `legacy_tension` when the field is an unregistered string.
4. RANDOM only ever returns a member of `RANDOM_POOL` (never `legacy_tension`).
5-7. FORCED returns each of the three forceable encounters.
8. An invalid `EncounterMode` falls back to `default`.
9. An invalid `ForcedEncounter` falls back to `legacy_tension`.
10. A forged `type` or `difficulty` field inside an action payload has no effect on
    the frozen `s.encounter` — the server reads only its own copy. (The brief's
    "client cannot request an encounter" is structural, not behavioural: no callback
    in the contract accepts one, so it needs an assertion that can actually fail.)
11. The resolved encounter is frozen into `sessions[src].encounter`.
12. Changing the setting mid-session does not change an active session's encounter;
    the next cast picks up the new mode.
13. RANDOM preserves the fish's difficulty tier.
14. FORCED preserves the fish's difficulty tier.

Items 13 and 14 are asserted by rolling the same fish under all three modes and
comparing `encounter.difficulty` for equality.

Beyond the brief's checklist, each mechanism added during design review carries its
own assertions. These are the ones most likely to regress silently:

| mechanism | assertions |
| --- | --- |
| `advance` (3.5) | an `advance` sent before the deadline is rejected as `bad_action` and changes no state; one sent after the deadline produces a miss in counter-pull, a wrong answer in mindgame, a missed attempt in sonar; spamming `advance` cannot outrun real elapsed time |
| server-derived strike time (6.3) | a `clientAtMs` in the payload does not appear in the hit decision — two strikes with identical arrival times and wildly different `clientAtMs` grade identically; a strike delayed past the pass grades as a miss; latency compensation is bounded by `MAX_COMPENSATION` |
| sonar termination (6.4) | MISS / HIT / HIT with `requiredHits = 3, maxMisses = 2` continues to a fourth attempt rather than reaching an undefined state; success at `hits >= requiredHits`; escape at `misses >= maxMisses`; attempts never exceed `requiredHits + maxMisses - 1` |
| forced landing (5.5) | a behavior chain that never emits `REST` is still winnable; stamina reaching zero issues the `LANDING` turn; a missed landing returns the fish to stamina 25 and the fight continues |
| `perfScore` (3.6.1) | a flawless fight returns exactly 1.0 in all three encounters; a mixed sonar run scores between its SAFE and PERFECT bounds |
| mindgame turn count (5.3) | the reel's `drainRate` does not change the number of correct answers needed — a tier-5 fight is 9 either way |
| fish backfill (3.9.1) | a DB row with no `encounter` receives the static value on load; a row explicitly set to `legacy_tension` is left untouched across a reload |

**Harness gap to fix:** `tests/package.json` has scripts only for the two water
suites — `security.test.lua` has none. Add a script per suite plus a `test:all` that
runs every Lua suite and reports a combined result.

### 9.2 Web suites

Vitest, under `web/src/encounters/__tests__/`. State transitions, not markup
snapshots.

| component | assertions |
| --- | --- |
| `CounterPull` | direction cue renders per state; fatigue state changes the prompt; correct/incorrect input feedback; success and failure end states |
| `FishMindgame` | telegraph renders; response buttons enabled per state; turn advances on server reply; result rendering |
| `SonarStrike` | attempt renders from the pass record; a strike dispatches `action: 'strike'` and **no timing field the server would trust**; hit/miss/perfect result rendering; the next attempt begins |
| `SettingsTab` | three modes selectable; forced selector disabled outside FORCED; current active configuration displayed; options come from the `encounters` payload rather than a hardcoded list |
| `FishTab` | the encounter dropdown offers four values and never writes `null` |

### 9.3 Cross-language parity

`server/encounter_sonar.lua` and `web/src/engine/sonarTimeline.ts` both implement
`posAt`. A generated fixture, `tests/fixtures/sonar_timeline.json`, holds sampled
`(pass, t) -> position` values. **Both** the Lua sonar suite and a Vitest test assert
against that same fixture, so the two implementations cannot drift apart silently.

### 9.4 Regression

`tests/security.test.lua`, `tests/water_validation.test.lua`,
`tests/water_validation_preservation.test.lua` and the existing Vitest suites must all
still pass. `web/src/__tests__/claimErrorLocales.test.ts` will require the new claim
reasons to exist in both `locales/en.json` and `locales/th.json`.

New locale keys: `error_encounter_active`, `error_stale_challenge`,
`error_bad_seq`, plus the encounter UI strings and admin labels. New entries in
`CLAIM_ERRORS` (`client/minigame.lua:75`) for any reason that should not collapse to
`error_claim_failed`.

---

## 10. Documentation

- `docs/ARCHITECTURE.md` — new section covering the registry, the resolver, the two
  settings, session freezing, difficulty normalization, all three state machines, the
  authority boundary, flood gates, persistence and admin semantics, including the
  resolver diagram from section 1. Add a change-history entry.
- `docs/testing/zfishing-live-e2e-checklist.md` — new "Encounter system" section:
  DEFAULT for each configured pilot fish; RANDOM producing different encounters
  across catches; FORCED for each of the three; admin hot change leaving an active
  session alone while the next session picks up the change; two players running
  different encounters simultaneously; resmon at idle, during one encounter, and
  during several.
- `README.md` — admin-facing description of the three modes.
- `web/dist` is committed to the repository (it is not gitignored). The bundle must be
  rebuilt with `npm run build` and committed, or the running NUI will not contain the
  encounter UI.

---

## 11. Phasing

Each phase is a separate implementation plan. The encounter contract (Phase A) must be
stable before any encounter is built.

| phase | content |
| --- | --- |
| A | registry, resolver, difficulty tiers, session integration, settings, action contract, flood gate, claim boundary, resolver tests |
| B | `counter_pull` — server module, client bridge, NUI, tests |
| C | `fish_mindgame` — same |
| D | `sonar_strike` — same, plus the parity fixture |
| E | admin UI wired to the live persisted settings |
| F | pilot fish mapping in `config/fish.lua`, **plus the `Store.Load` fish backfill of section 3.9.1** — without it the mapping is a no-op on any server that has already booted |
| G | regression pass, docs, bundle rebuild, live checklist |

---

## 12. Out of scope

Explicitly not part of this work: Fishdex, tournaments, leaderboards, dailies, True
Release, skill trees, a dynamic fish market, quests, NPC tournaments, a new boat
system, a StateBag migration, inventory changes, a progression redesign, a framework
redesign, a `PART_TYPES` refactor, and any future encounter (`rhythm_reel`,
`pattern_memory`, `boss_fight`).

Deletion or rewriting of the legacy tension minigame is out of scope. It remains the
DEFAULT fallback and the rollback path.

---

## 13. Verification limits

These are stated up front so they are not a surprise in the completion report.

| item | status |
| --- | --- |
| Live FiveM end-to-end | **Cannot be run in this environment.** The checklist will be written; it will not be ticked. The completion report will say NOT VERIFIED. |
| resmon / FiveM profiler | Not measured. No performance numbers will be reported. |
| Release recommendation | Capped at **RELEASE CANDIDATE**. READY FOR PRODUCTION requires live verification. |

Automated Lua and Vitest suites *can* be run here, and their real results will be
reported.
