# zfishing Encounter Framework (Phase A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the server-authoritative encounter framework — registry, resolver, difficulty tiers, session freezing, settings, action contract and claim boundary — while every fish keeps playing the existing tension minigame.

**Architecture:** A pure-Lua registry (`shared/encounters.lua`) names the encounters and converts a rolled fish into a 1-5 difficulty tier. One resolver (`server/encounter.lua`) turns the global mode plus the fish into an encounter id; `server/session.lua` calls it once at cast time and freezes the answer into the session. A single action callback carries every encounter's player input, gated by sequence numbers and a flood gate. `zfishing:claim` stays the only settlement door, but for an encounter session it reads the server's own outcome instead of the client's `success` flag.

**Tech Stack:** Lua 5.4 (FiveM `cerulean`), ox_lib callbacks, oxmysql, plain-Lua tests under a wasmoon runner (`tests/luarun.mjs`), React 18 + Vitest for the NUI (not touched in this phase).

**Spec:** `docs/superpowers/specs/2026-08-20-zfishing-encounter-system-design.md`

## Global Constraints

- **Server-only authority.** No callback in this phase accepts a client-supplied encounter type, difficulty, tier, timing value, or outcome. `zfishing:cast` keeps its signature `(src, power, rodSlot)`.
- **Lua test files must live flat in `client/`, `server/`, `shared/` or `tests/`.** `tests/luarun.mjs` mounts those directories non-recursively. A module at `server/encounters/x.lua` is invisible to the harness.
- **`shared/encounters.lua` calls no natives at load time.** It must `dofile` cleanly inside wasmoon.
- **Load order in `fxmanifest.lua`:** `shared/encounters.lua` after `shared/util.lua` (it uses `ZUtil.clamp`) and before `config/*`. `server/encounter.lua` before `server/session.lua`.
- **Adding a setting touches five places:** `config/main.lua`, `ConfigSchema.Settings`, `SETTING_KEYS` in `server/store.lua`, the `Store.Seed()` block, and the settings payload in `zfishing:admin:getConfig`. Missing any one fails silently in a different way.
- **Neither encounter setting goes into `clientPayload()`** (`server/store.lua:125`) — that broadcasts to every player.
- **Do not modify `tests/security.test.lua`.** It is a passing 133-test suite; it carries its own copy of the test scaffold on purpose.
- **Baseline to preserve:** `node tests/luarun.mjs tests/security.test.lua` currently reports `133 tests passed`. It must still say that at the end of every task.
- Stable ids, verbatim: `counter_pull`, `fish_mindgame`, `sonar_strike`, `legacy_tension`. Modes: `default`, `random`, `forced`.

---

## File Structure

| File | Responsibility | Task |
| --- | --- | --- |
| `shared/encounters.lua` | **Create.** Registry: ids, forceable set, random pool, modes, recommended map, `TierFor`, `LineMult`. Pure data + pure functions. | 1 |
| `tests/harness.lua` | **Create.** Shared test scaffold for the new suites. | 1, 5 |
| `tests/luarun.mjs` | **Modify.** Also mount `tests/*.lua` so suites can `dofile` the harness. | 1 |
| `server/encounter.lua` | **Create.** `Resolve` (policy), `Register`/`Playable`/`ResolveForSession` (module availability), challenge lifecycle, the action callback, outcome normalization. | 2, 6 |
| `config/main.lua` | **Modify.** Two new settings with their static defaults. | 3 |
| `server/config_schema.lua` | **Modify.** Two enum schemas; `encounter` added to the fish whitelist. | 3 |
| `server/store.lua` | **Modify.** `SETTING_KEYS` and the `Store.Seed()` block. | 3 |
| `server/admin.lua` | **Modify.** Settings payload plus an `encounters` block so the admin UI never hardcodes the registry. | 3 |
| `server/generator.lua` | **Modify.** Emit `difficulty` alongside `tensionDiff`. | 4 |
| `server/session.lua` | **Modify.** Resolve + freeze at cast; encounter-aware claim; the flood gate entry. | 5, 7 |
| `server/rewards.lua` | **Modify.** Optional `ctx.perfScore` on the XP grant only. | 7 |
| `fxmanifest.lua` | **Modify.** Load the two new server/shared files. | 1, 2 |
| `tests/package.json` | **Modify.** A script per suite plus `test:all`. | 8 |
| `docs/ARCHITECTURE.md` | **Modify.** Encounter framework section and a change-history entry. | 8 |

---

## Design addition not in the spec: `Encounter.Playable`

The spec assumes all three encounters exist. During a phased rollout they do not: after Phase A lands, an admin who sets `EncounterMode = forced, ForcedEncounter = sonar_strike` would put every player into an encounter with no module behind it and break fishing.

This plan therefore splits selection from availability:

- `Encounter.Resolve(fish)` is pure policy and returns exactly what the spec's resolver returns. The spec's resolver tests apply to it unchanged.
- `Encounter.ResolveForSession(fish)` applies policy, then downgrades to `legacy_tension` when no module is registered for the selected id, and reports what it downgraded so the console can say so.

`server/session.lua` calls `ResolveForSession`. Each later phase registers its module and the downgrade stops applying to that id. Task 8 records this in `docs/ARCHITECTURE.md` and amends the spec.

---

## Task 1: The registry and the test harness

**Files:**
- Create: `shared/encounters.lua`
- Create: `tests/harness.lua`
- Create: `tests/encounter_resolver.test.lua`
- Modify: `tests/luarun.mjs:30-41`
- Modify: `fxmanifest.lua:11-20`

**Interfaces:**
- Consumes: `ZUtil.clamp(v, min, max)` from `shared/util.lua`.
- Produces: global `Encounters` with `IDS`, `FORCEABLE`, `RANDOM_POOL` (list of `{id, weight}`), `MODES`, `FALLBACK` (`'legacy_tension'`), `FALLBACK_MODE` (`'default'`), `RECOMMENDED`, `TierFor(rarity, weight, wMin, wMax) -> integer 1..5`, `LineMult(rating) -> number`. Global `H` from the harness with `H.test`, `H.equal`, `H.truthy`, `H.falsy`, `H.deepcopy`, `H.installHost`, `H.baseConfig`, `H.run`.

- [ ] **Step 1: Let the runner mount the tests directory**

`tests/luarun.mjs` currently mounts only `client`, `server` and `shared`, so a suite cannot `dofile` a shared harness. Replace lines 30-41 (the comment block and the mount-list build) with:

```javascript
// Every resource file the harness may `dofile`, mounted at its root-relative path.
// The test itself, all shipped Lua under client/, server/ and shared/, and the
// other files in tests/ so a suite can `dofile('tests/harness.lua')` for the shared
// scaffold. Non-recursive on purpose: a module in a subdirectory would be invisible
// here, which is why the resource keeps its Lua flat.
const luaDirs = ['client', 'server', 'shared', 'tests'];
const mountList = [testFile];
for (const dir of luaDirs) {
    const abs = join(RESOURCE_ROOT, dir);
    if (!existsSync(abs)) continue;
    for (const name of readdirSync(abs)) {
        if (name.endsWith('.lua')) mountList.push(`${dir}/${name}`);
    }
}
// testFile is also picked up by the tests/ sweep above
const seen = new Set();
const filesToMount = mountList.filter((f) => (seen.has(f) ? false : (seen.add(f), true)));
```

- [ ] **Step 2: Verify the existing suites still pass after the runner change**

Run from the resource root:

```bash
node tests/luarun.mjs tests/security.test.lua
```

Expected: last line `133 tests passed`.

```bash
node tests/luarun.mjs tests/water_validation_preservation.test.lua
```

Expected: last line `11 tests passed`.

- [ ] **Step 3: Create the shared test harness**

Create `tests/harness.lua`:

```lua
-- Shared scaffold for the encounter test suites.
--
-- dofile'd rather than require'd: tests/luarun.mjs mounts files at their
-- repository-relative paths inside a bare wasmoon VM, and there is no package.path
-- set up in there.
--
-- tests/security.test.lua predates this file and carries its own copy of the same
-- scaffold. That is deliberate. It is a passing 133-test suite and rewriting it to
-- consume this harness would be risk with no payoff for the encounter work.

H = {}

local tests = {}

function H.test(name, cb) tests[#tests + 1] = { name = name, callback = cb } end

function H.equal(actual, expected, message)
    assert(actual == expected, (message or 'values differ') .. ': expected '
        .. tostring(expected) .. ', got ' .. tostring(actual))
end

function H.truthy(v, message) assert(v, message or 'expected a truthy value') end
function H.falsy(v, message) assert(not v, message or 'expected a falsy value') end

function H.deepcopy(v)
    if type(v) ~= 'table' then return v end
    local o = {}
    for k, val in pairs(v) do o[k] = H.deepcopy(val) end
    return o
end

-- Recorders, refreshed by H.installHost()
H.CB, H.CMD, H.EVENTS, H.NETEVENTS, H.THREADS, H.TIMERS, H.spy = nil, nil, nil, nil, nil, nil, nil

local function sqlNode(ret)
    local function run(sql, params)
        H.spy.sql[#H.spy.sql + 1] = sql
        H.spy.sqlCalls[#H.spy.sqlCalls + 1] = { sql = sql, params = params }
        return ret
    end
    return setmetatable({ await = function(sql, params) return run(sql, params) end },
        { __call = function(_, sql, params) return run(sql, params) end })
end

-- Installs a fresh set of host stubs and clears the module globals a previous
-- test's dofile defined, so each test starts from a known state.
function H.installHost()
    H.CB, H.CMD, H.EVENTS, H.NETEVENTS, H.THREADS, H.TIMERS = {}, {}, {}, {}, {}, {}
    H.spy = { sql = {}, sqlCalls = {}, clientEvents = {}, notifies = {} }

    Config, Zfishing, Progression, Generator, Rig, Rewards, Validate, Store, ZUtil,
        Encounters, Encounter, ConfigSchema =
        nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil

    _G.lib = { callback = { register = function(name, fn) H.CB[name] = fn end } }
    _G.RegisterCommand = function(name, fn) H.CMD[name] = fn end
    _G.RegisterNetEvent = function(name, fn) H.NETEVENTS[name] = fn end
    _G.AddEventHandler = function(name, fn) H.EVENTS[name] = fn end
    _G.CreateThread = function(fn) H.THREADS[#H.THREADS + 1] = fn end
    _G.Wait = function() end
    _G.SetTimeout = function(ms, fn) H.TIMERS[#H.TIMERS + 1] = { ms = ms, fn = fn } end
    _G.TriggerClientEvent = function(event, target, ...)
        H.spy.clientEvents[#H.spy.clientEvents + 1] = { event = event, target = target, args = { ... } }
    end
    _G.GetResourceState = function() return 'started' end

    _G.__NOW = 1000      -- GetGameTimer ms
    _G.__TIME = 100000   -- os.time seconds
    _G.__PING = 60       -- GetPlayerPing ms
    _G.GetGameTimer = function() return _G.__NOW end
    _G.GetPlayerPing = function() return _G.__PING end
    _G.GetPlayerPed = function() return 1 end
    _G.__POS = { x = 0.0, y = 0.0, z = 0.0 }
    _G.GetEntityCoords = function() return _G.__POS end
    _G.GetWeatherState = function() return { weather = 'CLEAR', hour = 12 } end

    _G.json = {
        encode = function(v) return { __enc = H.deepcopy(v) } end,
        decode = function(v)
            if type(v) == 'table' and v.__enc ~= nil then return H.deepcopy(v.__enc) end
            return v
        end,
    }
    _G.MySQL = {
        scalar = sqlNode(nil), query = sqlNode({}), prepare = sqlNode(true),
        insert = sqlNode(1), update = sqlNode(true), single = sqlNode(nil),
    }
    os.time = function() return _G.__TIME end
end

-- The five real rarities, because tier mapping is 1:1 with them, plus the four
-- real behavior names from config/fish.lua. A test config that invents rarities or
-- behaviors would pass while the shipped data failed.
function H.baseConfig()
    return {
        RateLimit = 6,
        Timings = { biteMin = 4000, biteMax = 12000, hookWindow = 1500, hookLatency = 300, reelTimeout = 30000 },
        Minigame = { baseDrain = 12.0 },
        CastMaxDistance = 25.0,
        Durability = false, RodCanBreak = false, RequireAssembly = false, RequireZone = false,
        DefaultWater = 'ocean',
        RareLoot = {},
        EncounterMode = 'default',
        ForcedEncounter = 'counter_pull',
        Rarity = {
            common    = { weight = 100, hookMult = 1.0,  tension = 1.0 },
            uncommon  = { weight = 45,  hookMult = 0.85, tension = 1.15 },
            rare      = { weight = 15,  hookMult = 0.7,  tension = 1.3 },
            epic      = { weight = 5,   hookMult = 0.6,  tension = 1.5 },
            legendary = { weight = 1,   hookMult = 0.5,  tension = 1.8 },
        },
        Weather = { weather = {}, time = {} },
        Zones = {},
        Fish = {},
        Equipment = {
            rods   = { fishing_rod_common = { level = 1, label = 'Common Rod', greenZone = 0.0, rareBonus = 1.0, degrade = 1, durability = 40 } },
            reels  = { reel_cheap = { level = 1, label = 'Cheap Reel', drainRate = 1.0, degrade = 1, durability = 60 } },
            lines  = { line_10 = { level = 1, label = '10lb Line', rating = 10, degrade = 2, durability = 30 } },
            hooks  = { hook_4 = { label = 'Size 4 Hook', hookMod = 1.0, rareBonus = 1.1 } },
            floats = { float_wood = { level = 1, label = 'Wood Float', biteSpeed = 1.0, degrade = 1, durability = 50 } },
            baits  = { worm = { label = 'Worm' } },
        },
        Admin = { waterTypes = { 'lake', 'river', 'ocean', 'swamp', 'dam' } },
    }
end

-- Runs a callback with math.random() (no arguments) pinned to `v`. ZUtil.weightedPick
-- is the only no-arg caller in the code under test, so this makes a weighted pick
-- deterministic without disturbing math.random(a, b) elsewhere.
function H.withRandom(v, fn)
    local real = math.random
    math.random = function(a, b)
        if a == nil then return v end
        return real(a, b)
    end
    local ok, err = pcall(fn)
    math.random = real
    if not ok then error(err, 0) end
end

function H.run()
    local failures = 0
    for _, entry in ipairs(tests) do
        local ok, err = pcall(entry.callback)
        if ok then
            print('ok - ' .. entry.name)
        else
            failures = failures + 1
            io.stderr:write('not ok - ' .. entry.name .. ': ' .. tostring(err) .. '\n')
        end
    end
    if failures > 0 then error(('%d test(s) failed'):format(failures)) end
    print(('%d tests passed'):format(#tests))
end
```

- [ ] **Step 4: Write the failing registry tests**

Create `tests/encounter_resolver.test.lua`:

```lua
-- Encounter registry and resolver. Run from the resource root:
--   node tests/luarun.mjs tests/encounter_resolver.test.lua
--
-- Covers the resolver checklist in
-- docs/superpowers/specs/2026-08-20-zfishing-encounter-system-design.md section 9.1.

dofile('tests/harness.lua')
local test, equal, truthy, falsy = H.test, H.equal, H.truthy, H.falsy

local function loadRegistry()
    H.installHost()
    Config = H.baseConfig()
    dofile('shared/util.lua')
    dofile('shared/encounters.lua')
end

test('R1 the registry sets are internally consistent', function()
    loadRegistry()
    truthy(Encounters.IDS.counter_pull)
    truthy(Encounters.IDS.fish_mindgame)
    truthy(Encounters.IDS.sonar_strike)
    truthy(Encounters.IDS.legacy_tension,
        'legacy must be a registered id so any resolved value is validatable against one set')
    falsy(Encounters.FORCEABLE.legacy_tension,
        'legacy must not be selectable in FORCED mode -- that would be a fourth mode in disguise')
    equal(#Encounters.RANDOM_POOL, 3)
    for _, entry in ipairs(Encounters.RANDOM_POOL) do
        truthy(Encounters.FORCEABLE[entry.id], 'random pool must hold only forceable ids: ' .. tostring(entry.id))
        truthy(entry.weight, 'pool entries carry a weight from day one so weighted random needs no resolver change')
    end
    equal(Encounters.FALLBACK, 'legacy_tension')
    truthy(Encounters.MODES.default); truthy(Encounters.MODES.random); truthy(Encounters.MODES.forced)
    falsy(Encounters.MODES.legacy)
end)

test('R2 TierFor maps the five rarities 1:1 onto the five tiers', function()
    loadRegistry()
    equal(Encounters.TierFor('common', 2, 1, 5), 1)
    equal(Encounters.TierFor('uncommon', 2, 1, 5), 2)
    equal(Encounters.TierFor('rare', 2, 1, 5), 3)
    equal(Encounters.TierFor('epic', 2, 1, 5), 4)
    equal(Encounters.TierFor('legendary', 2, 1, 5), 5)
end)

test('R3 a top-of-range specimen fights one tier harder, capped at 5', function()
    loadRegistry()
    equal(Encounters.TierFor('common', 5, 1, 5), 2, 'a maximum-weight fish steps up a tier')
    equal(Encounters.TierFor('common', 4, 1, 5), 2, 'ratio 0.75 is inclusive')
    equal(Encounters.TierFor('common', 3.9, 1, 5), 1, 'just under the threshold does not step up')
    equal(Encounters.TierFor('legendary', 5, 1, 5), 5, 'tier 5 is the ceiling')
end)

test('R4 TierFor survives unknown rarity and a zero-width weight range', function()
    loadRegistry()
    equal(Encounters.TierFor('mythic', 2, 1, 5), 1, 'an admin-invented rarity must not error')
    equal(Encounters.TierFor('common', 3, 3, 3), 1, 'a zero-width range must not divide by zero')
end)

test('R5 LineMult is exact at the shipped ratings, monotone between them, and clamped', function()
    loadRegistry()
    equal(Encounters.LineMult(10), 1.00)
    equal(Encounters.LineMult(20), 1.15)
    equal(Encounters.LineMult(40), 1.30)
    equal(Encounters.LineMult(60), 1.45)
    equal(Encounters.LineMult(5), 1.00, 'below the lowest anchor clamps rather than extrapolating')
    equal(Encounters.LineMult(500), 1.45, 'an admin-raised rating cannot run off the top of the curve')
    truthy(Encounters.LineMult(30) > Encounters.LineMult(20), 'an edited rating between anchors stays monotone')
    truthy(Encounters.LineMult(30) < Encounters.LineMult(40))
end)

H.run()
```

- [ ] **Step 5: Run the tests to verify they fail**

```bash
node tests/luarun.mjs tests/encounter_resolver.test.lua
```

Expected: `RUNNER ERROR` mentioning `shared/encounters.lua` — the file does not exist yet.

- [ ] **Step 6: Write the registry**

Create `shared/encounters.lua`:

```lua
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
```

- [ ] **Step 7: Run the tests to verify they pass**

```bash
node tests/luarun.mjs tests/encounter_resolver.test.lua
```

Expected: five `ok -` lines then `5 tests passed`.

- [ ] **Step 8: Add the registry to the manifest**

In `fxmanifest.lua`, inside `shared_scripts`, insert `'shared/encounters.lua',` immediately after `'shared/rig_rules.lua',` and before `'config/main.lua',`. It must come after `shared/util.lua` because `TierFor` calls `ZUtil.clamp`.

- [ ] **Step 9: Re-run the existing suites**

```bash
node tests/luarun.mjs tests/security.test.lua
```

Expected: `133 tests passed`.

- [ ] **Step 10: Commit**

```bash
git add shared/encounters.lua tests/harness.lua tests/encounter_resolver.test.lua tests/luarun.mjs fxmanifest.lua
git commit -m "feat: add the encounter registry and a shared Lua test harness"
```

---

## Task 2: The resolver

**Files:**
- Create: `server/encounter.lua`
- Modify: `tests/encounter_resolver.test.lua` (append)
- Modify: `fxmanifest.lua:22-37`

**Interfaces:**
- Consumes: `Encounters.*` from Task 1; `ZUtil.weightedPick(list)` from `shared/util.lua`; `Config.EncounterMode`, `Config.ForcedEncounter`.
- Produces: global `Encounter` with `Encounter.Resolve(fish) -> encounterId, mode`. Both return values are always strings; `encounterId` is always a key of `Encounters.IDS` and `mode` is always a key of `Encounters.MODES`.

- [ ] **Step 1: Write the failing resolver tests**

Append to `tests/encounter_resolver.test.lua`, immediately **before** the final `H.run()` line:

```lua
-- ---------------------------------------------------------------- resolver

local function loadResolver(mode, forced)
    H.installHost()
    Config = H.baseConfig()
    if mode ~= nil then Config.EncounterMode = mode end
    if forced ~= nil then Config.ForcedEncounter = forced end
    dofile('shared/util.lua')
    dofile('shared/encounters.lua')
    dofile('server/encounter.lua')
end

local function fishWith(encounter)
    return { species = 'bass', rarity = 'common', behavior = 'steady_light',
             weight = 2.0, encounter = encounter }
end

test('R6 DEFAULT resolves an explicitly configured fish encounter', function()
    loadResolver('default')
    local id, mode = Encounter.Resolve(fishWith('sonar_strike'))
    equal(id, 'sonar_strike')
    equal(mode, 'default')
end)

test('R7 DEFAULT falls back to legacy when the fish has no encounter', function()
    loadResolver('default')
    equal((Encounter.Resolve(fishWith(nil))), 'legacy_tension')
end)

test('R8 DEFAULT falls back to legacy on an unregistered fish encounter', function()
    loadResolver('default')
    equal((Encounter.Resolve(fishWith('boss_fight'))), 'legacy_tension',
        'a future id that is not registered yet must not reach a session')
    equal((Encounter.Resolve(fishWith(42))), 'legacy_tension', 'a non-string must not reach a session')
end)

test('R9 RANDOM only ever returns a pool member and never legacy', function()
    loadResolver('random')
    for _ = 1, 300 do
        local id, mode = Encounter.Resolve(fishWith(nil))
        truthy(Encounters.FORCEABLE[id], 'random returned an id outside the pool: ' .. tostring(id))
        falsy(id == 'legacy_tension', 'legacy must never come out of the random pool')
        equal(mode, 'random')
    end
end)

test('R10 RANDOM can reach every pool entry', function()
    loadResolver('random')
    -- ZUtil.weightedPick is the only no-argument math.random caller here; pinning it
    -- walks the three pool branches deterministically instead of hoping 300 draws
    -- happened to cover them.
    H.withRandom(0.1, function() equal((Encounter.Resolve(fishWith(nil))), 'counter_pull') end)
    H.withRandom(0.5, function() equal((Encounter.Resolve(fishWith(nil))), 'fish_mindgame') end)
    H.withRandom(0.9, function() equal((Encounter.Resolve(fishWith(nil))), 'sonar_strike') end)
end)

test('R11 FORCED returns the configured encounter for every fish', function()
    for _, forced in ipairs({ 'counter_pull', 'fish_mindgame', 'sonar_strike' }) do
        loadResolver('forced', forced)
        equal((Encounter.Resolve(fishWith(nil))), forced, 'unconfigured fish must still be forced')
        equal((Encounter.Resolve(fishWith('counter_pull'))), forced,
            'FORCED must override a fish that configured something else')
        local _, mode = Encounter.Resolve(fishWith(nil))
        equal(mode, 'forced')
    end
end)

test('R12 an invalid EncounterMode falls back to default behaviour', function()
    loadResolver('chaos')
    local id, mode = Encounter.Resolve(fishWith('sonar_strike'))
    equal(mode, 'default', 'an unusable stored mode must degrade to default, not error')
    equal(id, 'sonar_strike', 'and default behaviour still honours the fish')
    loadResolver(false)
    equal((select(2, Encounter.Resolve(fishWith(nil)))), 'default')
end)

test('R13 an invalid ForcedEncounter falls back to legacy, not to a random pick', function()
    loadResolver('forced', 'boss_fight')
    equal((Encounter.Resolve(fishWith(nil))), 'legacy_tension')
    loadResolver('forced', 'legacy_tension')
    equal((Encounter.Resolve(fishWith(nil))), 'legacy_tension',
        'legacy is not forceable, so forcing it lands on the fallback by the same route')
    loadResolver('forced', nil)
    equal((Encounter.Resolve(fishWith(nil))), 'legacy_tension')
end)
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
node tests/luarun.mjs tests/encounter_resolver.test.lua
```

Expected: `RUNNER ERROR` mentioning `server/encounter.lua` — the file does not exist yet.

- [ ] **Step 3: Write the resolver**

Create `server/encounter.lua`:

```lua
-- The encounter resolver and, from Task 6, the encounter challenge lifecycle.
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
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
node tests/luarun.mjs tests/encounter_resolver.test.lua
```

Expected: thirteen `ok -` lines then `13 tests passed`.

- [ ] **Step 5: Add the resolver to the manifest**

In `fxmanifest.lua`, inside `server_scripts`, insert `'server/encounter.lua',` immediately after `'server/generator.lua',` and before `'server/rewards.lua',`. It must load before `server/session.lua`.

- [ ] **Step 6: Commit**

```bash
git add server/encounter.lua tests/encounter_resolver.test.lua fxmanifest.lua
git commit -m "feat: resolve an encounter from the mode and the fish"
```

---

## Task 3: Settings, validation and the admin payload

**Files:**
- Modify: `config/main.lua:22-24`
- Modify: `server/config_schema.lua:7-23` and `server/config_schema.lua:100-119`
- Modify: `server/store.lua:8` and `server/store.lua:26-35`
- Modify: `server/admin.lua:11-27`
- Create: `tests/encounter_admin.test.lua`

**Interfaces:**
- Consumes: `Encounters.MODES`, `Encounters.FORCEABLE`, `Encounters.IDS`, `Encounters.RECOMMENDED` from Task 1.
- Produces: `Config.EncounterMode` and `Config.ForcedEncounter` as validated, DB-backed settings. `ConfigSchema.ValidateFish` now preserves an `encounter` field. `zfishing:admin:getConfig` returns `settings.EncounterMode`, `settings.ForcedEncounter`, and an `encounters = { modes, forceable, recommended }` block.

- [ ] **Step 1: Write the failing settings and admin tests**

Create `tests/encounter_admin.test.lua`:

```lua
-- Encounter settings validation and the admin surface. Run from the resource root:
--   node tests/luarun.mjs tests/encounter_admin.test.lua

dofile('tests/harness.lua')
local test, equal, truthy, falsy = H.test, H.equal, H.truthy, H.falsy

local function loadSchema()
    H.installHost()
    Config = H.baseConfig()
    dofile('shared/util.lua')
    dofile('shared/encounters.lua')
    dofile('server/config_schema.lua')
    dofile('server/validate.lua')
end

test('A1 EncounterMode accepts exactly the three modes', function()
    loadSchema()
    equal(Validate.Setting('EncounterMode', 'default'), 'default')
    equal(Validate.Setting('EncounterMode', 'random'), 'random')
    equal(Validate.Setting('EncounterMode', 'forced'), 'forced')
    local v, err = Validate.Setting('EncounterMode', 'chaos')
    falsy(v); truthy(err)
    falsy((Validate.Setting('EncounterMode', 'legacy')))
    falsy((Validate.Setting('EncounterMode', true)))
end)

test('A2 ForcedEncounter accepts the three encounters and refuses legacy', function()
    loadSchema()
    equal(Validate.Setting('ForcedEncounter', 'counter_pull'), 'counter_pull')
    equal(Validate.Setting('ForcedEncounter', 'fish_mindgame'), 'fish_mindgame')
    equal(Validate.Setting('ForcedEncounter', 'sonar_strike'), 'sonar_strike')
    local v, err = Validate.Setting('ForcedEncounter', 'legacy_tension')
    falsy(v, 'legacy is not forceable'); truthy(err)
    falsy((Validate.Setting('ForcedEncounter', 'boss_fight')))
    falsy((Validate.Setting('ForcedEncounter', '')))
end)

test('A3 ValidateFish keeps a registered encounter and rejects an unknown one', function()
    loadSchema()
    local base = { label = 'Bass', behavior = 'steady_light', rarity = 'common',
        weight = { min = 1, max = 4 }, price = 100, xp = 10, water = { 'lake' } }

    local none = Validate.Fish(H.deepcopy(base))
    truthy(none)
    equal(none.encounter, nil, 'no encounter key means unconfigured, and stays that way')

    local set = H.deepcopy(base); set.encounter = 'sonar_strike'
    equal(Validate.Fish(set).encounter, 'sonar_strike',
        'an encounter must survive validation -- an admin save would otherwise strip it')

    local legacy = H.deepcopy(base); legacy.encounter = 'legacy_tension'
    equal(Validate.Fish(legacy).encounter, 'legacy_tension',
        'an operator choosing legacy explicitly is a real, storable choice')

    local bad = H.deepcopy(base); bad.encounter = 'boss_fight'
    local v, err = Validate.Fish(bad)
    falsy(v, 'an unknown encounter is a hard error, not a silent drop'); truthy(err)
end)

-- ---------------------------------------------------------------- admin surface

local function loadAdmin(isAdminResult)
    H.installHost()
    Config = H.baseConfig()
    Config.EncounterMode = 'forced'
    Config.ForcedEncounter = 'sonar_strike'
    dofile('shared/util.lua')
    dofile('shared/encounters.lua')
    local saved = {}
    Store = {
        SaveSetting = function(key, value) saved[#saved + 1] = { key = key, value = value }; return true end,
        UpsertZone = function() return 7 end, DeleteZone = function() return true end,
        SaveFish = function() return true end, DeleteFish = function() return true end,
        SaveEquipment = function() return true end, ResetDomain = function() return true end,
        zonesPayloadWithId = function() return {} end,
    }
    _G.exports = { zcore_lib = {
        IsAdmin = function() return isAdminResult end,
        Notify = function() end,
    } }
    dofile('server/admin.lua')
    return saved
end

test('A4 getConfig exposes both settings and the registry, so the UI hardcodes nothing', function()
    loadAdmin(true)
    local cfg = H.CB['zfishing:admin:getConfig'](5)
    truthy(cfg)
    equal(cfg.settings.EncounterMode, 'forced', 'the panel cannot show a value it was never sent')
    equal(cfg.settings.ForcedEncounter, 'sonar_strike')
    truthy(cfg.encounters, 'the registry must travel to the admin UI or TypeScript will grow a second copy')
    truthy(cfg.encounters.modes.random)
    truthy(cfg.encounters.forceable.counter_pull)
    falsy(cfg.encounters.forceable.legacy_tension)
    equal(cfg.encounters.recommended.steady_heavy, 'fish_mindgame')
end)

test('A5 a non-admin cannot read the config or write either encounter setting', function()
    local saved = loadAdmin(false)
    equal(H.CB['zfishing:admin:getConfig'](5), nil)
    local a = H.CB['zfishing:admin:saveSetting'](5, 'EncounterMode', 'forced')
    equal(a.ok, false); equal(a.err, 'denied')
    local b = H.CB['zfishing:admin:saveSetting'](5, 'ForcedEncounter', 'sonar_strike')
    equal(b.ok, false)
    equal(#saved, 0, 'a denied write must never reach the data layer')
end)

test('A6 an admin write reaches the store under the right key', function()
    local saved = loadAdmin(true)
    truthy(H.CB['zfishing:admin:saveSetting'](5, 'EncounterMode', 'random').ok)
    equal(#saved, 1)
    equal(saved[1].key, 'EncounterMode')
    equal(saved[1].value, 'random')
end)

H.run()
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
node tests/luarun.mjs tests/encounter_admin.test.lua
```

Expected: six `not ok -` lines then `RUNNER ERROR: 6 test(s) failed`. A1/A2 fail with `unknown setting`, A3 with a nil `encounter`, A4 with a nil `cfg.encounters`.

- [ ] **Step 3: Add the static defaults**

In `config/main.lua`, immediately after the `Config.Minigame` block (which ends at line 24), insert:

```lua
-- Which fight a hooked fish becomes. 'default' = the fish decides (and a fish with no
-- `encounter` field keeps the legacy tension minigame), 'random' = the server picks
-- from the encounter pool per cast, 'forced' = every catch uses ForcedEncounter.
-- Server-owned: the client is never told the mode, only which encounter it is playing.
Config.EncounterMode = 'default'
Config.ForcedEncounter = 'counter_pull'
```

- [ ] **Step 4: Add the two enum schemas and the fish field**

In `server/config_schema.lua`, inside the `ConfigSchema.Settings` table, after the `RequireZone` line, add:

```lua
    EncounterMode    = { type = 'enum', values = Encounters.MODES },
    ForcedEncounter  = { type = 'enum', values = Encounters.FORCEABLE },
```

`Encounters` is a shared script and shared scripts load before server scripts, so it is defined by the time this table is built.

`ValidateSetting`'s `enum` branch currently hardcodes the message `'unknown water type'`. Replace that branch so the error names the key being validated:

```lua
    elseif schema.type == 'enum' then
        if schema.values[value] then return value end
        return nil, 'unknown value for ' .. key
```

Replace only those two lines of the branch body. Do **not** add an `end` — the branch
sits inside an `if/elseif` chain that continues with `elseif schema.type == 'object'`,
and closing it here would strip the object and array branches out of the function.

In `ConfigSchema.ValidateFish`, add the check immediately before the existing `return`:

```lua
    -- nil means "never configured" and resolves to the fallback. A present but
    -- unregistered value is a hard error: silently dropping it would let an admin
    -- believe a fish was assigned an encounter it never got.
    if data.encounter ~= nil and not Encounters.IDS[data.encounter] then
        return nil, 'unknown encounter'
    end
```

and extend the returned literal with `encounter = data.encounter,` as its last field. `ValidateFish` returns a table literal — it has no `clean` local, unlike `ValidateEquipment`.

- [ ] **Step 5: Persist and seed both settings**

In `server/store.lua`, extend `SETTING_KEYS` (line 8) to:

```lua
local SETTING_KEYS = { 'RateLimit', 'Timings', 'CastMaxDistance', 'Durability', 'RareLoot', 'DefaultWater', 'RequireZone', 'RodCanBreak', 'RequireAssembly', 'EncounterMode', 'ForcedEncounter' }
```

This list gates both `Store.Load` and `Store.ResetDomain('settings')`, so a key missing here is read back as the static default forever and never cleared by a reset.

In `Store.Seed()`, inside the `settings` branch, add before `putSetting(seededMark('settings'), true)`:

```lua
        putSetting('EncounterMode', Config.EncounterMode)
        putSetting('ForcedEncounter', Config.ForcedEncounter)
```

- [ ] **Step 6: Extend the admin payload**

In `server/admin.lua`, inside the `zfishing:admin:getConfig` return, add to the `settings` table:

```lua
            EncounterMode = Config.EncounterMode, ForcedEncounter = Config.ForcedEncounter,
```

and add a sibling key after `waterTypes`:

```lua
        -- The registry travels to the admin UI so the panel never hardcodes an
        -- encounter list that would drift from shared/encounters.lua. Admin payload
        -- only -- Store.clientPayload() deliberately carries none of this, because it
        -- broadcasts to every player and encounter selection is a server decision.
        encounters = {
            modes       = Encounters.MODES,
            forceable   = Encounters.FORCEABLE,
            recommended = Encounters.RECOMMENDED,
        },
```

- [ ] **Step 7: Run the tests to verify they pass**

```bash
node tests/luarun.mjs tests/encounter_admin.test.lua
```

Expected: six `ok -` lines then `6 tests passed`.

- [ ] **Step 8: Re-run the existing suites**

```bash
node tests/luarun.mjs tests/security.test.lua
```

Expected: `133 tests passed`. Group A tests exercise `Validate.Setting` and `Validate.Fish` directly; if `A2` there fails on the changed enum error message, the assertion is `truthy(werr)` and any non-empty message satisfies it.

- [ ] **Step 9: Commit**

```bash
git add config/main.lua server/config_schema.lua server/store.lua server/admin.lua tests/encounter_admin.test.lua
git commit -m "feat: persist and validate the encounter mode settings"
```

---

## Task 4: Difficulty on the roll

**Files:**
- Modify: `server/generator.lua:65-81`
- Create: `tests/encounter_difficulty.test.lua`

**Interfaces:**
- Consumes: `Encounters.TierFor` from Task 1.
- Produces: `Generator.Roll` returns an extra field `difficulty` — an integer 1..5 — alongside the existing `tensionDiff`.

- [ ] **Step 1: Write the failing difficulty tests**

Create `tests/encounter_difficulty.test.lua`:

```lua
-- Difficulty tiers on the roll, and the invariant that selection mode never touches
-- them. Run from the resource root:
--   node tests/luarun.mjs tests/encounter_difficulty.test.lua

dofile('tests/harness.lua')
local test, equal, truthy = H.test, H.equal, H.truthy

-- One species only, so the weighted pick is forced and the roll is predictable.
local function loadGenerator(species, def)
    H.installHost()
    Config = H.baseConfig()
    Config.Fish = { [species] = def }
    dofile('shared/util.lua')
    dofile('shared/encounters.lua')
    dofile('server/generator.lua')
end

local BASS = { label = 'Bass', water = { 'ocean' }, weight = { min = 1.0, max = 5.0 },
    rarity = 'common', price = 8, baits = { 'worm' }, behavior = 'steady_light', xp = 10 }
local MARLIN = { label = 'Marlin', water = { 'ocean' }, weight = { min = 40.0, max = 200.0 },
    rarity = 'legendary', price = 500, baits = { 'topwater' }, behavior = 'erratic', xp = 200 }

local function roll(randomValue)
    local out
    H.withRandom(randomValue, function()
        out = Generator.Roll(5, { water = 'ocean', rod = 'fishing_rod_common', hook = 'hook_4', bait = 'worm' })
    end)
    return out
end

test('D1 the roll carries a difficulty tier next to the tension multiplier', function()
    loadGenerator('bass', BASS)
    local f = roll(0.0)   -- ZUtil.randFloat -> min weight
    truthy(f)
    equal(f.difficulty, 1, 'a mid-to-low common fish is tier 1')
    equal(f.tensionDiff, 1.0, 'the existing field is untouched')
end)

test('D2 a top-of-range specimen rolls one tier harder', function()
    loadGenerator('bass', BASS)
    equal(roll(1.0).difficulty, 2, 'a 5.0kg bass in a 1.0-5.0 range is a big one')
end)

test('D3 a legendary fish is tier 5 and cannot exceed it', function()
    loadGenerator('marlin', MARLIN)
    equal(roll(0.0).difficulty, 5)
    equal(roll(1.0).difficulty, 5, 'the cap holds for a maximum-weight legendary')
end)

test('D4 selection mode never changes the tier -- RANDOM and FORCED preserve it', function()
    -- The invariant the whole difficulty-normalization design exists to protect:
    -- the encounter TYPE may change with the mode, the fish's difficulty may not.
    local tiers = {}
    for _, mode in ipairs({ 'default', 'random', 'forced' }) do
        loadGenerator('marlin', MARLIN)
        Config.EncounterMode = mode
        Config.ForcedEncounter = 'counter_pull'
        dofile('server/encounter.lua')
        local f = roll(0.5)
        local id = Encounter.Resolve(f)
        truthy(Encounters.IDS[id])
        tiers[#tiers + 1] = f.difficulty
    end
    equal(tiers[1], tiers[2], 'RANDOM must not soften a legendary fish')
    equal(tiers[2], tiers[3], 'FORCED must not soften a legendary fish')
    equal(tiers[1], 5)
end)

H.run()
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
node tests/luarun.mjs tests/encounter_difficulty.test.lua
```

Expected: four `not ok -` lines then `RUNNER ERROR: 4 test(s) failed`, each reporting `expected 1, got nil` (or similar) for `difficulty`.

- [ ] **Step 3: Emit the tier from the roll**

In `server/generator.lua`, inside the table `Generator.Roll` returns, add immediately after the `tensionDiff` line:

```lua
        -- Normalized 1..5 encounter difficulty. A pure function of the rolled fish, so
        -- it is identical no matter which encounter type the resolver goes on to pick
        -- -- that is what keeps a legendary fish legendary under RANDOM and FORCED.
        difficulty  = Encounters.TierFor(fish.rarity, weight, fish.weight.min, fish.weight.max),
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
node tests/luarun.mjs tests/encounter_difficulty.test.lua
```

Expected: four `ok -` lines then `4 tests passed`.

- [ ] **Step 5: Re-run the existing suites**

```bash
node tests/luarun.mjs tests/security.test.lua
```

Expected: `133 tests passed`.

- [ ] **Step 6: Commit**

```bash
git add server/generator.lua tests/encounter_difficulty.test.lua
git commit -m "feat: emit a normalized difficulty tier from the fish roll"
```

---

## Task 5: Freeze the encounter into the session

**Files:**
- Modify: `server/encounter.lua` (append)
- Modify: `server/session.lua:152-224`
- Modify: `tests/harness.lua` (append `H.makeZfishing`, `H.loadSession`)
- Create: `tests/encounter_session.test.lua`

**Interfaces:**
- Consumes: `Encounter.Resolve` from Task 2; `Generator.Roll(...).difficulty` from Task 4.
- Produces: `Encounter.Register(id, mod)`, `Encounter.Playable(id) -> boolean`, `Encounter.ResolveForSession(fish) -> id, mode, downgradedFrom`. `sessions[src].encounter = { type, mode, difficulty }` at cast time. The `zfishing:bite` client payload gains `encounter = <id>`.

- [ ] **Step 1: Extend the harness with the session scaffold**

Append to `tests/harness.lua`, immediately **before** `function H.run()`:

```lua
-- Minimal inventory-and-framework facade, matching the surface server/session.lua
-- and server/rig.lua actually call.
function H.makeZfishing(state)
    state = state or {}
    local inv = state.inv or {}
    local Z = {}
    function Z.Blocked() return state.blocked end
    function Z.Enhanced() return state.mode ~= 'simple' end
    function Z.Simple() return state.mode == 'simple' end
    function Z.Identifier() return 'license:test' end
    function Z.HasItem(src, item)
        for _, s in pairs(inv[src] or {}) do if s.name == item then return true end end
        return false
    end
    function Z.GetSlot(src, slot) return (inv[src] or {})[slot] end
    function Z.AddItem() return true end
    function Z.RemoveItem() return true end
    function Z.RemoveItemSlot() return true end
    function Z.SetMetadata() return true end
    function Z.Notify() end
    return Z
end

-- Boots server/session.lua against stubbed collaborators. Returns the recorded
-- Rewards.GiveCatch calls so a test can assert what settlement was handed.
function H.loadSession(opts)
    opts = opts or {}
    H.installHost()
    Config = H.baseConfig()
    Config.EncounterMode = opts.encounterMode or 'default'
    Config.ForcedEncounter = opts.forcedEncounter or 'counter_pull'
    Config.RequireZone = false
    Config.RequireAssembly = false
    Config.Durability = false

    -- opts.rig = true exercises the assembled-rod path, which is the only path that
    -- populates session.rigSlot -- and rigSlot is what Rig.breakLine needs, so a snap
    -- test has to run through it.
    Config.RequireAssembly = opts.rig == true

    local inv = { [5] = { [1] = { name = 'fishing_rod_common', count = 1 }, [2] = { name = 'worm', count = 5 } } }
    Zfishing = H.makeZfishing({ mode = opts.rig and 'enhanced' or 'simple', inv = inv })
    Progression = {
        Get = function() return { level = 5, identifier = 'license:test' } end,
        Load = function() return true end, AddXP = function() end, Save = function() end,
    }
    Generator = { Roll = function()
        local f = H.deepcopy(opts.fish or { species = 'bass', label = 'Bass', weight = 2.0, quality = 3,
            rarity = 'common', behavior = 'steady_light', biteDelay = 100, hookWindow = 1500,
            tensionDiff = 1.0, fishEnergy = 50, xp = 10, price = 100, difficulty = 1 })
        return f
    end }
    local calls = { give = 0, ctx = nil }
    Rewards = { GiveCatch = function(_, _, _, ctx)
        calls.give = calls.give + 1
        calls.ctx = ctx
        return { ok = true, committed = true, warnings = {} }
    end }
    local META = { parts = { reel = 'reel_cheap', line = 'line_10', hook = 'hook_4', float = 'float_wood' },
                   dur = { rod = 20, reel = 20, line = 20, hook = 20, float = 20 } }
    Rig = {
        slotMeta = function()
            if not opts.rig then return nil end
            return { name = 'fishing_rod_common' }, META
        end,
        isComplete = function() return opts.rig == true end,
        stats = function() return { lineRating = 10, reelDrain = 1.0, hook = 'hook_4', floatBiteSpeed = 1.0 } end,
        degrade = function() return { broke = {} } end,
        breakLine = function() calls.lineBroken = true end,
    }
    dofile('shared/util.lua')
    dofile('shared/encounters.lua')
    dofile('server/encounter.lua')
    dofile('server/session.lua')
    return calls
end

-- Finds the most recent recorded client event by name.
function H.lastClientEvent(name)
    for i = #H.spy.clientEvents, 1, -1 do
        if H.spy.clientEvents[i].event == name then return H.spy.clientEvents[i] end
    end
    return nil
end

-- Fires the most recently scheduled SetTimeout. Always the timer the call under test
-- just armed -- indexing H.TIMERS[1] breaks the moment a test casts twice, because the
-- first cast's bite timer is still sitting there and its identity guard makes firing it
-- a silent no-op.
function H.fireLatestTimer()
    local t = H.TIMERS[#H.TIMERS]
    assert(t, 'expected a scheduled timer')
    t.fn()
    return t
end
```

- [ ] **Step 2: Write the failing session tests**

Create `tests/encounter_session.test.lua`:

```lua
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
```

- [ ] **Step 3: Run the tests to verify they fail**

```bash
node tests/luarun.mjs tests/encounter_session.test.lua
```

Expected: eight `not ok -` lines then `RUNNER ERROR: 8 test(s) failed`, the first reporting a nil `Encounter.Register`.

- [ ] **Step 4: Add module registration and the session-safe resolver**

Append to `server/encounter.lua`:

```lua
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
```

- [ ] **Step 5: Freeze the encounter at cast and name it in the bite payload**

In `server/session.lua`, immediately after the `if not fish then return { ok = false, reason = 'empty_water' } end` line, insert:

```lua
    -- Resolved ONCE, here, and frozen into the session below. Nothing downstream reads
    -- Config.EncounterMode again for this session -- that is what lets an admin change
    -- the mode without altering a fight already in progress.
    local encType, encMode, encDowngraded = Encounter.ResolveForSession(fish)
    if encDowngraded then
        print(('[zfishing] encounter %s has no module deployed; using %s instead')
            :format(encDowngraded, encType))
    end
```

In the `sessions[src] = { ... }` table, add after the `rigSlot = rigSlot,` line:

```lua
        -- type and difficulty are frozen at cast; the challenge state is built at hook
        encounter = { type = encType, mode = encMode, difficulty = fish.difficulty or 1 },
```

In the `TriggerClientEvent('zfishing:bite', src, { ... })` payload, add after the `fishWeight = fish.weight,` line:

```lua
            -- which fight to render. NOT the mode: the client has no business knowing
            -- the global selection policy, only which encounter it was handed.
            encounter = s.encounter.type,
            difficulty = s.encounter.difficulty,
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
node tests/luarun.mjs tests/encounter_session.test.lua
```

Expected: eight `ok -` lines then `8 tests passed`.

- [ ] **Step 7: Re-run every suite**

```bash
node tests/luarun.mjs tests/security.test.lua
```

Expected: `133 tests passed`.

```bash
node tests/luarun.mjs tests/encounter_resolver.test.lua
```

Expected: `13 tests passed`.

- [ ] **Step 8: Commit**

```bash
git add server/encounter.lua server/session.lua tests/harness.lua tests/encounter_session.test.lua
git commit -m "feat: freeze the resolved encounter into the fishing session"
```

---

## Task 6: The action contract

**Files:**
- Modify: `server/encounter.lua` (append)
- Modify: `server/session.lua:11-16` (flood gate) and the `playerDropped` handler
- Create: `tests/encounter_action.test.lua`

**Interfaces:**
- Consumes: `Encounter.MODULES` from Task 5; `ZUtil.MakeRateGate` from `shared/util.lua`.
- Produces: the module contract every encounter implements —
  `mod.actions` (a set of valid action names, excluding `advance`, which is universal),
  `mod.build(ctx) -> state, estimatedFightMs` where `ctx = { difficulty, seed, fish, gear }`,
  `mod.act(enc, action, now) -> { render = <table>, outcome = <nil|'success'|'escape'|'snap'|'timeout'>, value = <nil|number 0..1> }`.
  The module owns `enc.state.deadline` — it writes the next per-turn deadline into its
  own state, and the dispatcher reads it to validate `advance`. `value` is the action's
  quality on a 0..1 scale and is what feeds `Encounter.PerfScore`; a module that omits
  it simply does not score that action.
  Plus `Encounter.Begin(s, gear)` (called from the hook callback) and the
  `zfishing:encounter:act` callback. `Encounter.Session` is the accessor `session.lua`
  passes in; the encounter code never reads `sessions[src]` itself.

- [ ] **Step 1: Write the failing action-contract tests**

Create `tests/encounter_action.test.lua`:

```lua
-- The action contract: sequencing, replay rejection, the `advance` deadline action,
-- and the flood gate. Run from the resource root:
--   node tests/luarun.mjs tests/encounter_action.test.lua

dofile('tests/harness.lua')
local test, equal, truthy, falsy = H.test, H.equal, H.truthy, H.falsy

-- A deliberately trivial module. It is the contract under test here, not any real
-- encounter: three correct actions win, one `advance` (a missed deadline) loses.
local function fakeModule()
    return {
        actions = { good = true, bad = true },
        build = function(ctx)
            return { hits = 0, misses = 0, difficulty = ctx.difficulty, deadline = 0 }, 20000
        end,
        act = function(enc, action, now)
            local st = enc.state
            if action == 'good' then st.hits = st.hits + 1 else st.misses = st.misses + 1 end
            local outcome
            if st.hits >= 3 then outcome = 'success' elseif st.misses >= 1 then outcome = 'escape' end
            st.deadline = now + 1000
            return { render = { hits = st.hits }, outcome = outcome, deadline = st.deadline }
        end,
    }
end

-- cast -> bite -> hook, leaving an armed encounter. Returns the session id and the
-- challenge id the server minted.
local function startEncounter(src, mod)
    local calls = H.loadSession({ encounterMode = 'forced', forcedEncounter = 'counter_pull' })
    Encounter.Register('counter_pull', mod or fakeModule())
    local cast = H.CB['zfishing:cast'](src, 0.5)
    truthy(cast.ok, tostring(cast.reason))
    H.fireLatestTimer()
    local hook = H.CB['zfishing:hook'](src, cast.sessionId)
    truthy(hook.ok)
    truthy(hook.challengeId, 'the hook answer must carry the challenge id the client will quote')
    return cast.sessionId, hook.challengeId, calls
end

test('C1 a correct action advances the sequence and returns the authoritative seq', function()
    local sid, cid = startEncounter(5)
    local r = H.CB['zfishing:encounter:act'](5, sid, cid, 1, 'good')
    truthy(r.ok)
    equal(r.seq, 1)
    equal(r.state.hits, 1)
    equal(r.outcome, nil)
end)

test('C2 a duplicate seq is rejected and changes nothing', function()
    local sid, cid = startEncounter(5)
    truthy(H.CB['zfishing:encounter:act'](5, sid, cid, 1, 'good').ok)
    local dup = H.CB['zfishing:encounter:act'](5, sid, cid, 1, 'good')
    falsy(dup.ok)
    equal(dup.reason, 'bad_seq')
    equal(dup.seq, 1, 'the reply carries the real seq so an honest client can resync')
    equal(H.CB['zfishing:encounter:act'](5, sid, cid, 2, 'good').state.hits, 2,
        'the duplicate must not have counted -- a replayed win is the whole attack')
end)

test('C3 a stale seq and an impossible future seq are both rejected', function()
    local sid, cid = startEncounter(5)
    H.CB['zfishing:encounter:act'](5, sid, cid, 1, 'good')
    H.CB['zfishing:encounter:act'](5, sid, cid, 2, 'good')
    equal(H.CB['zfishing:encounter:act'](5, sid, cid, 1, 'good').reason, 'bad_seq')
    equal(H.CB['zfishing:encounter:act'](5, sid, cid, 9, 'good').reason, 'bad_seq')
    equal(H.CB['zfishing:encounter:act'](5, sid, cid, 'x', 'good').reason, 'bad_seq')
end)

test('C4 a challenge id from another session is rejected', function()
    local sid, cid = startEncounter(5)
    equal(H.CB['zfishing:encounter:act'](5, sid, cid .. 'x', 1, 'good').reason, 'stale_challenge')
    equal(H.CB['zfishing:encounter:act'](5, 'not-my-session', cid, 1, 'good').reason, 'invalid_session')
end)

test('C5 an unknown action name is rejected without consuming the sequence', function()
    local sid, cid = startEncounter(5)
    equal(H.CB['zfishing:encounter:act'](5, sid, cid, 1, 'teleport').reason, 'bad_action')
    truthy(H.CB['zfishing:encounter:act'](5, sid, cid, 1, 'good').ok,
        'a rejected action must not burn the seq an honest retry needs')
end)

test('C6 advance is refused before the deadline and accepted after it', function()
    local sid, cid = startEncounter(5)
    truthy(H.CB['zfishing:encounter:act'](5, sid, cid, 1, 'good').ok)  -- sets deadline = now + 1000
    equal(H.CB['zfishing:encounter:act'](5, sid, cid, 2, 'advance').reason, 'bad_action',
        'an early advance would let a client skip a window it had not actually lost')
    _G.__NOW = _G.__NOW + 1500
    local r = H.CB['zfishing:encounter:act'](5, sid, cid, 2, 'advance')
    truthy(r.ok)
    equal(r.outcome, 'escape', 'the SERVER decides what an expired deadline means')
end)

test('C7 once an outcome is set the challenge accepts nothing more', function()
    local sid, cid = startEncounter(5)
    H.CB['zfishing:encounter:act'](5, sid, cid, 1, 'good')
    H.CB['zfishing:encounter:act'](5, sid, cid, 2, 'good')
    equal(H.CB['zfishing:encounter:act'](5, sid, cid, 3, 'good').outcome, 'success')
    equal(H.CB['zfishing:encounter:act'](5, sid, cid, 4, 'good').reason, 'encounter_over')
end)

test('C8 the encounter expiry timer resolves an abandoned fight as a timeout', function()
    local sid, cid = startEncounter(5)
    local expiry = H.TIMERS[#H.TIMERS]
    truthy(expiry, 'beginning an encounter must schedule exactly one expiry timer')
    expiry.fn()
    equal(H.CB['zfishing:encounter:act'](5, sid, cid, 1, 'good').reason, 'encounter_over')
end)

test('C9 flooding the action event cannot accelerate a catch', function()
    local sid, cid = startEncounter(5)
    local accepted, gated = 0, 0
    for i = 1, 200 do
        local r = H.CB['zfishing:encounter:act'](5, sid, cid, i, 'good')
        if r.ok then accepted = accepted + 1
        elseif r.reason == 'too_many_requests' then gated = gated + 1 end
    end
    truthy(gated > 0, 'the gate must engage under a flood')
    truthy(accepted <= 3, 'a flood cannot produce more progress than the module allows')
end)

test('C10 a dropped player leaves no encounter behind', function()
    local sid, cid = startEncounter(5)
    -- server/session.lua's handler reads the `source` global, which FiveM sets for it
    _G.source = 5
    H.EVENTS.playerDropped()
    equal(H.CB['zfishing:encounter:act'](5, sid, cid, 1, 'good').reason, 'invalid_session')
end)

test('C11 a legacy session has no encounter callback surface', function()
    H.loadSession({ encounterMode = 'default' })
    local cast = H.CB['zfishing:cast'](5, 0.5)
    H.fireLatestTimer()
    local hook = H.CB['zfishing:hook'](5, cast.sessionId)
    truthy(hook.ok)
    equal(hook.challengeId, nil, 'the legacy fight mints no challenge')
    equal(H.CB['zfishing:encounter:act'](5, cast.sessionId, 'anything', 1, 'good').reason, 'no_encounter')
end)

H.run()
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
node tests/luarun.mjs tests/encounter_action.test.lua
```

Expected: eleven `not ok -` lines then `RUNNER ERROR: 11 test(s) failed`, the first reporting a nil `hook.challengeId`.

- [ ] **Step 3: Build the challenge lifecycle**

Append to `server/encounter.lua`:

```lua
-- ---------------------------------------------------------------- challenge lifecycle

-- session.lua injects its own accessor here at load. The encounter code never touches
-- the sessions table directly: every lookup has to go through the same token check the
-- rest of the state machine uses.
Encounter.Session = nil

local MAX_DEADLINE = 120000
local MIN_DEADLINE = 15000

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
    s.encounter.expiresAt = now + ZUtil.clamp(estimate * 1.75, MIN_DEADLINE, MAX_DEADLINE)
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
```

- [ ] **Step 4: Wire the session accessor, the gate and the hook**

In `server/session.lua`, add `encounter = { max = 40, window = 10000 },` to the `gate` table (line 11-16), with this comment above the entry:

```lua
    -- Sized from counter-pull, the busiest encounter: a tier-5 fight is on the order of
    -- 28 counters plus fatigue reels across ~31s, and MakeRateGate is a FIXED window,
    -- so what matters is the busiest 10s slice, not the whole-fight average. Re-check
    -- this number against the final tier table when counter-pull lands (Phase B).
```

Then expose the two hooks `server/encounter.lua` needs. Place this block **immediately
after the `sessionFor` function** (it ends at line 44) — not next to the gate. Both
`sessions` and `sessionFor` are file-locals, and a closure written above `sessionFor`
would capture a nil upvalue:

```lua
-- server/encounter.lua never reads `sessions` directly: it resolves through the same
-- token check every other transition uses, and shares this file's flood gate.
--
-- Called with a src (the action callback) it is the full token check. Called without
-- one (the expiry timer, which outlives the request that armed it) it looks the session
-- up by id and the caller re-checks object identity before touching anything.
Encounter.Session = function(sessionId, src)
    if src ~= nil then return sessionFor(src, sessionId) end
    for _, s in pairs(sessions) do if s.id == sessionId then return s end end
    return nil
end
Encounter.Gate = function(src) return gate.allow(src, 'encounter') end
```

In the `zfishing:hook` callback, replace the tail:

```lua
    s.state = 'reeling'
    s.reelStart = GetGameTimer()
    return { ok = true }
```

with:

```lua
    s.state = 'reeling'
    s.reelStart = GetGameTimer()
    -- A legacy session mints no challenge: its fight runs client-side exactly as before.
    local challengeId
    if s.encounter and s.encounter.type ~= Encounters.FALLBACK then
        challengeId = Encounter.Begin(s, {
            lineRating = s.lineRating,
            reelDrain  = s.reelDrain or 1.0,
            greenZone  = (Config.Equipment.rods[s.rod] or {}).greenZone or 0.0,
            float      = s.float,
        })
    end
    return { ok = true, challengeId = challengeId }
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
node tests/luarun.mjs tests/encounter_action.test.lua
```

Expected: eleven `ok -` lines then `11 tests passed`.

- [ ] **Step 6: Re-run every suite**

```bash
node tests/luarun.mjs tests/security.test.lua
node tests/luarun.mjs tests/encounter_session.test.lua
```

Expected: `133 tests passed` and `8 tests passed`.

- [ ] **Step 7: Commit**

```bash
git add server/encounter.lua server/session.lua tests/encounter_action.test.lua
git commit -m "feat: add the sequenced, flood-gated encounter action contract"
```

---

## Task 7: The claim boundary and the XP bonus

**Files:**
- Modify: `server/session.lua:241-274`
- Modify: `server/rewards.lua` (the XP stage inside `Rewards.GiveCatch`)
- Modify: `client/minigame.lua:75-81` (claim error map)
- Modify: `locales/en.json`, `locales/th.json`
- Create: `tests/encounter_claim.test.lua`

**Interfaces:**
- Consumes: `Encounter.PerfScore(enc)` from Task 6.
- Produces: `zfishing:claim` ignores the client's `success` and `reason` for an encounter session and answers `{ ok = true, fish = nil, outcome = <outcome> }` on a loss. `Rewards.GiveCatch(src, fish, zone, ctx)` accepts `ctx.perfScore` and applies it to the XP grant only.

- [ ] **Step 1: Write the failing claim tests**

Create `tests/encounter_claim.test.lua`:

```lua
-- The claim boundary: for an encounter session the server's own outcome decides, and
-- the client's success flag is ignored. Run from the resource root:
--   node tests/luarun.mjs tests/encounter_claim.test.lua

dofile('tests/harness.lua')
local test, equal, truthy, falsy = H.test, H.equal, H.truthy, H.falsy

local function winnerModule(outcome, value)
    return {
        actions = { go = true },
        build = function() return { deadline = 0 }, 20000 end,
        act = function(enc, _, now)
            enc.state.deadline = now + 1000
            return { render = {}, outcome = outcome, value = value or 1 }
        end,
    }
end

-- opts.rig routes the cast through the assembled-rod path, which is the only path that
-- sets session.rigSlot -- and Rig.breakLine needs it, so the snap test must use it.
local function playTo(outcome, value, opts)
    opts = opts or {}
    local calls = H.loadSession({ encounterMode = 'forced', forcedEncounter = 'counter_pull',
                                  rig = opts.rig })
    Encounter.Register('counter_pull', winnerModule(outcome, value))
    local cast = H.CB['zfishing:cast'](5, 0.5, opts.rig and 1 or nil)
    truthy(cast.ok, tostring(cast.reason))
    H.fireLatestTimer()
    local hook = H.CB['zfishing:hook'](5, cast.sessionId)
    truthy(hook.ok)
    H.CB['zfishing:encounter:act'](5, cast.sessionId, hook.challengeId, 1, 'go')
    return cast.sessionId, calls
end

test('K1 a client claiming success on a lost encounter is not paid', function()
    local sid, calls = playTo('escape')
    local res = H.CB['zfishing:claim'](5, sid, 99999, true, nil)
    truthy(res.ok, 'a loss is a legitimate outcome, not an error')
    equal(res.fish, nil, 'the server said the fish escaped; the client saying otherwise changes nothing')
    equal(res.outcome, 'escape', 'the loss reason comes back from the server, not from the NUI')
    equal(calls.give, 0, 'settlement must never have run')
end)

test('K2 a client claiming failure on a won encounter is still paid', function()
    local sid, calls = playTo('success')
    local res = H.CB['zfishing:claim'](5, sid, 99999, false, 'snap')
    truthy(res.ok)
    truthy(res.fish, 'the server counted the win; the client cannot refuse it')
    equal(calls.give, 1)
end)

test('K3 a claim before the encounter has resolved is refused', function()
    local calls = H.loadSession({ encounterMode = 'forced', forcedEncounter = 'counter_pull' })
    Encounter.Register('counter_pull', winnerModule(nil))
    local cast = H.CB['zfishing:cast'](5, 0.5)
    H.fireLatestTimer()
    local hook = H.CB['zfishing:hook'](5, cast.sessionId)
    H.CB['zfishing:encounter:act'](5, cast.sessionId, hook.challengeId, 1, 'go')
    local res = H.CB['zfishing:claim'](5, cast.sessionId, 1000, true, nil)
    falsy(res.ok)
    equal(res.reason, 'encounter_active')
    equal(calls.give, 0)
end)

test('K4 a server-decided snap breaks the line component', function()
    local sid, calls = playTo('snap', 1, { rig = true })
    -- The client reports no reason at all. Before this change the line survived,
    -- because breakLine keyed off the reason string the NUI sent.
    local res = H.CB['zfishing:claim'](5, sid, 99999, false, nil)
    equal(res.outcome, 'snap')
    truthy(calls.lineBroken, 'Rig.breakLine must fire on the SERVER outcome, not on a client reason')
end)

test('K5 the encounter perf score reaches settlement and nothing else', function()
    local sid, calls = playTo('success', 1)
    truthy(H.CB['zfishing:claim'](5, sid, 99999, true, nil).ok)
    equal(calls.ctx.perfScore, 1, 'a flawless fight scores 1.0')
    truthy(calls.ctx.sessionId, 'the existing settlement context is preserved')
    truthy(calls.ctx.identifier)
end)

test('K6 a legacy session keeps the original claim path', function()
    local calls = H.loadSession({ encounterMode = 'default' })
    local cast = H.CB['zfishing:cast'](5, 0.5)
    H.fireLatestTimer()
    H.CB['zfishing:hook'](5, cast.sessionId)
    -- the minimum plausible reel time still applies to the client-run legacy fight
    local tooFast = H.CB['zfishing:claim'](5, cast.sessionId, 10, true, nil)
    falsy(tooFast.ok)
    equal(tooFast.reason, 'too_fast')
    equal(calls.give, 0)
end)

test('K7 a legacy win still pays, and carries no perf score', function()
    local calls = H.loadSession({ encounterMode = 'default' })
    local cast = H.CB['zfishing:cast'](5, 0.5)
    H.fireLatestTimer()
    H.CB['zfishing:hook'](5, cast.sessionId)
    _G.__NOW = _G.__NOW + 20000
    truthy(H.CB['zfishing:claim'](5, cast.sessionId, 20000, true, nil).ok)
    equal(calls.give, 1)
    equal(calls.ctx.perfScore, nil, 'the legacy fight grants exactly the XP it granted before')
end)

H.run()
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
node tests/luarun.mjs tests/encounter_claim.test.lua
```

Expected: seven tests run, K1-K5 fail (`RUNNER ERROR: 5 test(s) failed`); K6 and K7 pass because they describe today's behaviour.

- [ ] **Step 3: Make the claim encounter-aware**

In `server/session.lua`, inside the `zfishing:claim` callback, replace the block from `local drain = s.reelDrain or 1.0` through the end of the `if not success then ... end` block with:

```lua
    local encounter = (s.encounter and s.encounter.type ~= Encounters.FALLBACK) and s.encounter or nil

    if encounter then
        -- The server counted every action itself, so there is nothing left to take on
        -- trust. `success` and `reason` arrived from the client and are discarded --
        -- the plausibility floor below exists only because the LEGACY fight runs
        -- entirely client-side.
        if not encounter.outcome then return { ok = false, reason = 'encounter_active' } end
        success = (encounter.outcome == 'success')
        reason  = success and nil or encounter.outcome
        if GetGameTimer() > encounter.expiresAt + 5000 then
            reset(src); return { ok = false, reason = 'timeout' }
        end
    else
        -- Minimum plausible reel time. The NUI drains baseDrain * drainRate energy
        -- per second while in the green zone, so a real catch can never finish faster
        -- than this.
        local drain = s.reelDrain or 1.0
        local minMs = (fish.fishEnergy / (Config.Minigame.baseDrain * drain)) * 1000
        local elapsed = GetGameTimer() - s.reelStart
        if success and elapsed < minMs * 0.9 then
            reset(src); return { ok = false, reason = 'too_fast' }
        end
        if elapsed > Config.Timings.reelTimeout + 5000 then
            reset(src); return { ok = false, reason = 'timeout' }
        end
    end

    if not success then
        -- fish escaped / line broke: legitimate outcome, bait already consumed.
        -- a snapped line destroys the fitted line component for real.
        if reason == 'snap' and s.rigSlot then
            Rig.breakLine(src, s.rigSlot)
            TriggerClientEvent('zfishing:rig:notify', src, 'line_broke')
        end
        reset(src); return { ok = true, fish = nil, outcome = reason }
    end
```

`reason` is already a parameter of this callback, so assigning to it rebinds the local — that is the intended effect. The existing `local reason = ...` further down (which reads the settlement result) shadows it inside its own scope and is unaffected.

Then extend the `Rewards.GiveCatch` call to carry the score:

```lua
    local settled, res = pcall(Rewards.GiveCatch, src, fish, s.zone,
        { sessionId = s.id, identifier = s.identifier,
          perfScore = encounter and Encounter.PerfScore(encounter) or nil })
```

- [ ] **Step 4: Apply the score to XP only**

In `server/rewards.lua`, inside `Rewards.GiveCatch`, this is the XP stage today:

```lua
    runPlayerStage(src, expected, warnings, 'xp_save_failed', function()
        Progression.AddXP(src, fish.xp)
        return Progression.SaveAwait(src)
    end)
```

Replace it with:

```lua
    -- Encounter performance is worth at most +25% XP, and it is the ONLY reward this
    -- change touches: weight, quality, Rewards.Price and the rare-loot roll are all
    -- exactly where they were, so shipping encounters carries no economy delta. A
    -- legacy session passes no perfScore and grants precisely what it granted before.
    local xp = math.floor(fish.xp * (1 + 0.25 * (type(ctx) == 'table' and ctx.perfScore or 0)))
    runPlayerStage(src, expected, warnings, 'xp_save_failed', function()
        Progression.AddXP(src, xp)
        return Progression.SaveAwait(src)
    end)
```

The `local xp` line sits **outside** the stage closure on purpose: `runPlayerStage`
swallows a raise into a structured warning, and a nil-arithmetic bug in the multiplier
would then be reported as a failed XP save rather than surfacing.

- [ ] **Step 5: Map the new claim reasons to player-facing text**

In `client/minigame.lua`, add to the `CLAIM_ERRORS` table:

```lua
    encounter_active  = 'error_encounter_active',
    stale_challenge   = 'error_stale_challenge',
    bad_seq           = 'error_bad_seq',
```

Add to **both** `locales/en.json` and `locales/th.json`, next to the other `error_` keys:

```json
  "error_encounter_active": "That fight is not finished yet",
  "error_stale_challenge": "That fishing challenge is no longer valid",
  "error_bad_seq": "The fight fell out of sync — try again",
```

Thai:

```json
  "error_encounter_active": "ยังสู้กับปลาไม่จบ",
  "error_stale_challenge": "รอบการต่อสู้นี้หมดอายุแล้ว",
  "error_bad_seq": "จังหวะการต่อสู้ไม่ตรงกัน ลองใหม่อีกครั้ง",
```

`web/src/__tests__/claimErrorLocales.test.ts` asserts every `CLAIM_ERRORS` value exists in both locale files, so a missing key fails that suite.

- [ ] **Step 6: Run the tests to verify they pass**

```bash
node tests/luarun.mjs tests/encounter_claim.test.lua
```

Expected: seven `ok -` lines then `7 tests passed`.

- [ ] **Step 7: Run the web locale suite**

```bash
cd web && npm test
```

Expected: all suites pass, including `claimErrorLocales`.

- [ ] **Step 8: Re-run every Lua suite**

```bash
node tests/luarun.mjs tests/security.test.lua
node tests/luarun.mjs tests/encounter_action.test.lua
node tests/luarun.mjs tests/encounter_session.test.lua
```

Expected: `133 tests passed`, `11 tests passed`, `8 tests passed`.

- [ ] **Step 9: Commit**

```bash
git add server/session.lua server/rewards.lua client/minigame.lua locales/en.json locales/th.json tests/encounter_claim.test.lua
git commit -m "feat: settle an encounter from the server outcome, not the client flag"
```

---

## Task 8: Test scripts and documentation

**Files:**
- Modify: `tests/package.json`
- Modify: `docs/ARCHITECTURE.md`
- Modify: `docs/superpowers/specs/2026-08-20-zfishing-encounter-system-design.md`

**Interfaces:**
- Consumes: every suite created in Tasks 1-7.
- Produces: `npm run test:all` from `tests/` runs every Lua suite.

- [ ] **Step 1: Add a script per suite**

Replace the `scripts` block in `tests/package.json` with:

```json
  "scripts": {
    "test:water": "node luarun.mjs tests/water_validation.test.lua",
    "test:water-preservation": "node luarun.mjs tests/water_validation_preservation.test.lua",
    "test:security": "node luarun.mjs tests/security.test.lua",
    "test:encounter-resolver": "node luarun.mjs tests/encounter_resolver.test.lua",
    "test:encounter-admin": "node luarun.mjs tests/encounter_admin.test.lua",
    "test:encounter-difficulty": "node luarun.mjs tests/encounter_difficulty.test.lua",
    "test:encounter-session": "node luarun.mjs tests/encounter_session.test.lua",
    "test:encounter-action": "node luarun.mjs tests/encounter_action.test.lua",
    "test:encounter-claim": "node luarun.mjs tests/encounter_claim.test.lua",
    "test:all": "npm run test:water && npm run test:water-preservation && npm run test:security && npm run test:encounter-resolver && npm run test:encounter-admin && npm run test:encounter-difficulty && npm run test:encounter-session && npm run test:encounter-action && npm run test:encounter-claim"
  },
```

`security.test.lua` had no script at all before this — it was only ever runnable by hand.

- [ ] **Step 2: Run the whole suite**

```bash
cd tests && npm run test:all
```

Expected: every suite reports its own `N tests passed` line and the command exits 0.

- [ ] **Step 3: Document the framework in ARCHITECTURE.md**

Add a new section `## 13. The encounter framework` before `## 12. Change history` (renumber if the file's numbering requires it), covering: the registry and how to add an encounter; the resolver and the two-step DEFAULT chain; `EncounterMode` / `ForcedEncounter` and the five places a setting lives; session freezing and why an admin hot change cannot touch a fight in flight; difficulty normalization and the tier-preservation invariant; the action contract with its rejection order and the `advance` action; the flood gate and why flooding cannot accelerate a catch; the claim boundary and the discarded client `success` flag; `Encounter.Playable` and the phased rollout; and `legacy_tension` as the fallback and the rollback path.

Include the resolver diagram from section 1 of the spec verbatim.

Add a change-history entry dated 2026-08-20 titled "The encounter framework — 2026-08-20" summarising what Phase A shipped and what it deliberately did not (no encounter modules yet; every fish still plays the legacy fight).

- [ ] **Step 4: Amend the spec with `Encounter.Playable`**

In the spec's section 3.3, after the resolver code block, add:

```markdown
**Availability is separate from selection.** `Encounter.Resolve` is pure policy. During
the phased rollout the selected encounter may have no module deployed yet, so
`server/session.lua` calls `Encounter.ResolveForSession`, which downgrades an
unavailable id to `legacy_tension` and reports what it downgraded. Each phase registers
its module and the downgrade stops applying to that id. Without this, an admin setting
FORCED to an unbuilt encounter after Phase A would break fishing for everyone.
```

- [ ] **Step 5: Commit**

```bash
git add tests/package.json docs/ARCHITECTURE.md docs/superpowers/specs/2026-08-20-zfishing-encounter-system-design.md
git commit -m "docs: record the encounter framework and add per-suite test scripts"
```

---

## Phase A completion checklist

Run all of these and confirm the output before calling Phase A done:

```bash
cd tests && npm run test:all
```

```bash
cd web && npm test
```

Expected state at the end of Phase A:

- Every fish still plays `legacy_tension`, because no fish has an `encounter` field yet and no encounter module is registered.
- An admin can set `EncounterMode` and `ForcedEncounter`; a forced-but-unbuilt encounter degrades to the legacy fight and logs one line saying so.
- `zfishing:claim` is encounter-aware but no encounter can currently produce an outcome.
- No NUI change has shipped; `web/dist` does not need rebuilding for this phase.

---

## Plan roadmap — Phases B to G

Each of these gets its own plan document, written **after** its predecessor lands, because each one's `Interfaces` block has to quote the real signatures the previous phase produced rather than a guess at them.

| Phase | Plan | Scope |
| --- | --- | --- |
| B | `zfishing-encounter-counter-pull` plan | `server/encounter_counter_pull.lua` state machine, `client/encounter.lua` bridge and input polling, `web/src/encounters/EncounterHost.tsx` + `CounterPull.tsx`, the PART 26 test list, tier parameter table from spec 4.3 |
| C | `zfishing-encounter-mindgame` plan | `server/encounter_mindgame.lua` turn model and behavior chains, `FishMindgame.tsx`, forced landing turn, PART 27 test list |
| D | `zfishing-encounter-sonar` plan | `server/encounter_sonar.lua` seeded timeline and server-derived strike timing, `web/src/engine/sonarTimeline.ts`, `tests/fixtures/sonar_timeline.json` parity fixture, the millisecond re-derivation of the width table required by spec 6.4, PART 28 test list |
| E | `zfishing-encounter-admin-ui` plan | `Segmented` control in `admin/ui.tsx`, the encounter section in `SettingsTab.tsx`, the four-value dropdown in `FishTab.tsx`, Vitest coverage |
| F | `zfishing-encounter-fish-mapping` plan | the `Store.Load` fish backfill of spec 3.9.1, the pilot mapping for `mackerel` / `catfish` / `swordfish` |
| G | `zfishing-encounter-rollout` plan | full regression pass, `web/dist` rebuild and commit, `docs/testing/zfishing-live-e2e-checklist.md` encounter section, README admin documentation |
