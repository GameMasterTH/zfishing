# zfishing — Architecture & Internals

**What this document is.** A self-contained internals reference for `zfishing`, a
skill-based fishing resource for FiveM. It is written so that someone (or some
model) with *no access to the repository* can reason about the system, answer
questions about it, and write correct code against it.

**What this document is not.** It is not the operator guide. `README.md` in the
resource root covers installation, `server.cfg` ordering, item definitions for
every inventory, item images, locale setup, admin commands, and the player-facing
"how it plays" walkthrough. Those are deliberately not repeated here. This
document covers what README does not: the session state machine, the exact
network/NUI contract with payload shapes, the database schema, the framework
bridge, the gameplay math, and the cross-file invariants that make edits
dangerous.

**One-paragraph summary of the system.** A player uses a fishing rod item from
their inventory. The client validates water proximity and zone membership as a UX
gate, then asks the server to cast. The server rolls the entire catch — species,
weight, quality, bite delay, hook window, fight energy — at cast time and keeps it
secret. After a delay, the server tells the client a fish is biting and ships only
*abstracted* fight parameters. The player passes a hook QTE, then plays a tension
minigame that runs entirely in a React NUI page. The NUI reports the outcome, and
the server validates the claim against timing plausibility before granting the item
and writing XP + a catch log row. The roll, the grant, and every state transition
are server-authoritative; the minigame *outcome* is not — see
`docs/superpowers/specs/2026-08-18-zfishing-minigame-authority-design.md`.

Version at time of writing: `1.0.0` plus the security-hardening pass of 2026-08-19
(§12). Roughly 2,900 lines of Lua and 1,500 lines of TypeScript/TSX source.

---

## 1. Runtime topology

### 1.1 Dependency chain

```
FiveM server
 ├─ ox_lib          (required)  callbacks, notify, textUI, locale, input dialogs
 ├─ oxmysql         (required)  all persistence
 ├─ zcore_lib       (required)  framework + inventory bridge; the ONLY path to either
 ├─ ox_inventory    (recommended) per-item metadata → enables "enhanced-rig" mode
 ├─ ox_target       (optional)  sell NPC interaction; falls back to [E] proximity
 └─ weathersync     (optional)  qb-weathersync or Renewed-Weathersync
```

zfishing never calls a framework or inventory export directly. Every such call goes
through `zcore_lib`. See §6.

### 1.2 Script load order

Declared in `fxmanifest.lua`. Order matters — several files depend on globals
defined by earlier ones.

```
shared_scripts:  @ox_lib/init.lua → shared/util.lua → shared/rig_rules.lua
                 → config/main.lua → config/fish.lua → config/equipment.lua
                 → config/zones.lua → config/weather.lua

server_scripts:  @oxmysql/lib/MySQL.lua → server/lib.lua → server/store.lua
                 → server/config_schema.lua → server/validate.lua → server/weather.lua
                 → server/progression.lua → server/generator.lua → server/rewards.lua
                 → server/admin.lua → server/rig.lua → server/boat_anchor.lua
                 → server/session.lua → server/usable.lua

client_scripts:  client/anim.lua → client/float_kinematics.lua → client/water_effects.lua
                 → client/casting.lua → client/store.lua → client/minigame.lua
                 → client/main.lua → client/rig.lua → client/zone_raycast.lua
                 → client/zonetool.lua → client/admin.lua

ui_page:         web/dist/index.html   (committed build artifact)
```

`server/config_schema.lua` loads *after* `server/store.lua` but *before*
`server/validate.lua`. `validate.lua` guards against `ConfigSchema` being nil with
an explicit CRITICAL ERROR print and a minimal fallback — that guard exists because
the ordering is fragile.

### 1.3 Global namespaces

These are plain Lua globals, not modules. No `require`, no return-table pattern.

| Global | Side | Defined in | Purpose |
|---|---|---|---|
| `Config` | shared | `config/main.lua` + siblings | all tunables; **overwritten from DB at boot**, see §5 |
| `ZUtil` | shared | `shared/util.lua` | `clamp`, `randFloat`, `weightedPick` |
| `RigRules` | shared | `shared/rig_rules.lua` | rod-assembly rules usable on both sides |
| `Zfishing` | server | `server/lib.lua` | the zcore_lib bridge facade |
| `Store` | server | `server/store.lua` | DB-backed config store |
| `ConfigSchema` / `Validate` | server | `config_schema.lua` / `validate.lua` | admin input validation |
| `Progression` | server | `server/progression.lua` | XP/level cache + persistence |
| `Generator` | server | `server/generator.lua` | the catch roll |
| `Rewards` | server | `server/rewards.lua` | pricing, granting, selling |
| `Rig` | server | `server/rig.lua` | rod metadata read/write |
| `BoatAnchor` | server | `server/boat_anchor.lua` | refcounted boat anchoring |
| `ZClient` | client | `client/main.lua` | client session state (`active`, `reeling`, `standby`, `rodSlot`, `hud`) |
| `Casting` | client | `client/casting.lua` | bobber, line rendering, cast charge |
| `Anim` | client | `client/anim.lua` | rod prop + animation clips |
| `ZoneRaycast` | client | `client/zone_raycast.lua` | camera raycast for the zone tool |

### 1.4 File → responsibility map

**Server**

| File | Lines | Responsibility |
|---|---|---|
| `server/session.lua` | 287 | **The anti-cheat core.** Per-player session state machine; `cast`/`hook`/`claim`/`cancel` callbacks; rate limiting; server-side zone and gear resolution |
| `server/rig.lua` | 249 | Rod-assembly metadata: read, normalize, wear, break, attach/detach callbacks |
| `server/store.lua` | 234 | DB-backed config: seed, load, mutate, broadcast to clients; `/zfishreload` |
| `server/config_schema.lua` | 133 | Declarative schema + clamps for every admin-editable value |
| `server/lib.lua` | 120 | zcore_lib bridge facade; resolves and caches the pinned feature mode |
| `server/generator.lua` | 96 | Weighted species roll, weight/quality roll, per-catch derived stats |
| `server/rewards.lua` | 93 | Price formula, `GiveCatch`, rare-loot roll, `sellAll` callback |
| `server/admin.lua` | 86 | Admin gate (`zcore_lib:IsAdmin`), config read/write callbacks, `/zfishzone` `/zfishadmin` |
| `server/usable.lua` | 71 | Registers rods as useable items (bridge first, direct framework hook as fallback) |
| `server/progression.lua` | 57 | XP cache, level curve, load/save, `/zfish_xp` |
| `server/boat_anchor.lua` | 84 | Refcounted boat anchoring so two anglers on one boat don't fight; server-side proximity + netId validation on `Add` (§9) |
| `server/weather.lua` | 26 | Weather/hour source with weathersync exports preferred, client report as fallback |
| `server/validate.lua` | 25 | Thin facade over `ConfigSchema` |

**Client**

| File | Lines | Responsibility |
|---|---|---|
| `client/main.lua` | 352 | Session lifecycle, use-rod entry, prompt HUD, weather reporting, zone/water gates, sell NPCs, cancel keybind, single teardown path |
| `client/casting.lua` | 215 | Cast charge bar, bobber spawn + arc flight, catenary line rendering, fight/drift/dive bobber modes |
| `client/rig.lua` | 176 | Rod-assembly NUI menu (G keybind), attach/detach forwarding, break notifications |
| `client/minigame.lua` | 93 | Bite handler, hook QTE, reel input streaming, claim, catch card |
| `client/anim.lua` | 76 | Rod prop attach, animation clips, rod-tip anchor point |
| `client/zonetool.lua` | 56 | `/zfishzone` in-world zone placement |
| `client/water_effects.lua` | 29 | Ripple markers around the bobber |
| `client/zone_raycast.lua` | 27 | Camera-to-world/water raycast |
| `client/float_kinematics.lua` | 19 | Pure math for bobber arc + fight position |
| `client/store.lua` | 16 | Receives config sync from server, overwrites client `Config` |
| `client/admin.lua` | 17 | Opens the admin NUI, generic `adminSave` passthrough |

**NUI (`web/`)** — React 18 + TypeScript + Vite, no motion library, plain CSS.

| Path | Responsibility |
|---|---|
| `web/src/App.tsx` | Single message switch; maps `action` → view state |
| `web/src/hooks/useNui.ts` | `fetchNui(event, data)` POSTs to `https://zfishing/<event>`; `useNuiEvent` listens on `window.message` |
| `web/src/engine/minigameEngine.ts` | **Pure, testable** tension/energy simulation. No React, no DOM |
| `web/src/components/TensionMinigame.tsx` | RAF loop driving the engine, renders bars, streams energy back to Lua |
| `web/src/components/` | `CastBar`, `WaitingHud`, `FishingInfoCard`, `CatchCard`, `PromptHud`, `Keycap`, `RigMenu` |
| `web/src/admin/` | `AdminPanel` + `SettingsTab` / `ZonesTab` / `FishTab` / `EquipmentTab` / `ui.tsx` |
| `web/src/i18n.ts` | Fetches the locale dict from Lua via the `getLocale` NUI callback |
| `web/src/rigRows.ts`, `rigText.ts`, `promptText.ts` | Pure view-model builders, unit-tested separately from components |

The visual language is called "Water HUD": transparent `.hud-panel` surfaces whose
only chrome is a 2px left accent rail, legibility from `text-shadow`, and
`border-radius: 0 !important` globally. Motion is split into two strict tiers —
values written every frame by the RAF loop carry **no CSS transition**, while
state-change moments use CSS keyframes on `transform`/`opacity`.

---

## 2. The session state machine

The server owns the authoritative state. `sessions[src]` in `server/session.lua` is
a single table per player, or `nil` when idle. Every session carries an `id` — a
per-cast token minted by `newSessionId()` (defined just below `reset()`, not
above it) — that every subsequent callback must present via
`sessionFor(src, sessionId)`, which only resolves the caller's session when the
token matches. The token is correlation and stale-request protection, not a
secret: a modified client can always read its own. See §3.1.

```
                     nil
                      │  zfishing:cast  (validated, fish rolled here)
                      ▼
                 'waiting'  ── SetTimeout(fish.biteDelay) ──┐
                      │                                     │
                      │                                     ▼
                      │                          bait consumed, state →
                      │                          'hooking', TriggerClientEvent
                      │                          'zfishing:bite'
                      ▼                                     │
                 'hooking'  ◄────────────────────────────────┘
                      │  zfishing:hook(sessionId)  before s.hookDeadline
                      ▼
                 'reeling'
                      │  zfishing:claim(sessionId, reelDurationMs, success, reason)
                      ├─ success == false ─────────────────────────► nil
                      │
                      │ success == true
                      ▼
                 'settling'   (locked BEFORE Rewards.GiveCatch is called)
                      │
                      ▼
                     nil   (+ item granted, XP added, catch logged, rate++
                            only when the catch COMMITTED — see §4.5)
```

**`settling` exists to close a replay window.** `Rewards.GiveCatch` does
`AddItem` → `Progression.SaveAwait` → `MySQL.insert.await`, each a yield point; the claim
callback sets `s.state = 'settling'` *before* calling it. `hook` requires
`s.state == 'hooking'` and `claim` requires `s.state == 'reeling'`, so a claim
replayed while the reward is still settling fails that check and is refused
rather than paid twice.

**`settling` also owns the session against `cancel`.** `cancel` used to match on
`sessionId` alone and always reset, so a cancel racing in during the settle window
nulled `sessions[src]` early. No reward was ever double-paid by that —
`Rewards.GiveCatch(src, fish, zone)` is called with `fish` and `zone` captured as
locals, not re-read from the session table — but it let the player start a *new*
cast while the previous reward was still in flight. `cancel` now answers
`{ ok = true }` for a session in `settling` **without** resetting it, so the client
still runs its single teardown path while the server keeps the slot until the
reward path clears it. The visible cost is a short window in which a cast right
after that cancel returns `busy`. Nothing moves a session out of `settling` into
another live state — from there it only ever proceeds to `nil`.

Because cancel can no longer rescue a stuck `settling`, the reward call is wrapped
in `pcall`: an error raised anywhere inside `GiveCatch` would otherwise park the
session in `settling` with nothing able to clear it and leave the player on `busy`
for every later cast until they reconnect. A raised settlement returns
`reason = 'settle_failed'` and still resets. That backstop is now narrow — every
secondary effect inside `GiveCatch` guards itself (§4.5) — but it is not dead: the
pre-commit path formats the item description from the rolled `quality`, the one
rolled field nothing reads before settlement, so a malformed roll still raises
there. `tests/security.test.lua` O4 pins that shape; if it ever stops raising,
`settle_failed` becomes unreachable and this paragraph is what has to change.

**Every path back to `nil`:**

| Trigger | Where |
|---|---|
| Committed catch (through `settling`) | `zfishing:claim` success branch |
| Uncommitted catch — fish never reached the inventory → `reason = 'inv_full'` | `zfishing:claim` success branch |
| Reward path raised before the commit point → `reason = 'settle_failed'` | `zfishing:claim` success branch |
| Failed claim (escape/snap) — still `ok = true`, `fish = nil` | `zfishing:claim` |
| Claim too fast (`elapsed < minMs * 0.9`) → `reason = 'too_fast'` | `zfishing:claim` |
| Claim too late (`elapsed > Config.Timings.reelTimeout + 5000`) → `reason = 'timeout'` | `zfishing:claim` |
| Hook pressed after `hookDeadline` → `reason = 'too_slow'` | `zfishing:hook` |
| Hook never pressed — watchdog `SetTimeout(hookWindow + hookLatency + 2000)` | `zfishing:cast` |
| Player presses X → `zfishing:cancel(sessionId)` | client `zfishing_cancel` command |
| Rod broke during the cast's wear pass → `reason = 'rod_broke'` | `zfishing:cast` |
| Player disconnected | `playerDropped` handler |

A rejected `hook`/`claim`/`cancel` call carrying an invalid or stale `sessionId`
(`reason = 'invalid_session'`) or one that trips the per-action flood gate
(`reason = 'too_many_requests'`) does **not** appear in the table above — it
leaves any existing session untouched rather than resetting it.

The bite timer and the hook watchdog both re-check `s.fish == fish` (identity, not
equality) before acting, so a stale timer from a previous session can never mutate
a new one.

**Client-side mirror.** `ZClient` in `client/main.lua`:

- `ZClient.active` — a fishing session is running (rod equipped onward)
- `ZClient.standby` — rod is in hand but nothing is cast yet; **the only phase in
  which the rig menu (G) may open**
- `ZClient.reeling` — the NUI minigame is live and input is being streamed
- `ZClient.rodSlot` — the inventory slot of the rod being used; sent to the server
  so it can read the components fitted on *that specific* rod
- `ZClient.sessionId` — the per-cast token returned by `zfishing:cast`; sent with
  every `hook`/`claim`/`cancel` call after it so the server can tell this session
  apart from a stale one
- `ZClient.hud` — `{ rod, bait, distance }` cached for re-sending to the NUI

There is exactly **one** client teardown path: `cleanup()` in `client/main.lua`,
reachable from anywhere via `TriggerEvent('zfishing:client:end', msgKey, msgType)`.
It closes the rig menu, removes the bobber, stops the animation, drops NUI focus,
hides the HUD, detaches the ped from a boat, un-anchors the boat, unfreezes the
ped, and hides any TextUI. Any new exit condition must route through it.

**Full happy path, end to end:**

1. Player uses a rod item. `ox_inventory` calls the client export `zfishing.useRod`;
   a framework-native inventory instead fires `zfishing:client:useRod` from
   `server/usable.lua`. Both land in `startRodUse(data, slot)`.
2. Client gates: not already fishing → boat not moving (`speed > 1.5` rejects) →
   `nearWater()` (a `TestProbeAgainstWater` probe 6m ahead) → `currentZone()`.
3. `startFishing()`: play the rod animation, anchor + attach to a boat if on one,
   start the control-blocking thread, show the "equip" prompt, set `standby = true`.
4. Player presses **E**. `standby = false`, prompt hides, `Casting.Charge()` runs an
   oscillating power bar (`±0.02` per 16ms frame, ping-ponging 0..1) until E is
   released. Returns `power` in `0..1`, or `nil` on an 8-second timeout.
5. Water proximity is **re-checked** here — the earlier gate fired when the rod was
   equipped, and the player may have drifted onto land inside the same 2D zone.
6. `lib.callback.await('zfishing:cast', false, power, ZClient.rodSlot)`.
7. Server validates everything (§3.1), rolls the fish, applies per-cast durability
   wear, stores the session, and schedules the bite.
8. Client freezes the ped (if `Config.FreezeWhileFishing` and not on a boat),
   plays the `idle_a` waiting pose, spawns the bobber, sends `waiting` to the NUI,
   and shows the "cancel" prompt.
9. After `fish.biteDelay`, the server consumes the bait, moves to `hooking`, and
   sends `zfishing:bite` with abstracted parameters.
10. Client dives the bobber, plays a sound, shakes the pad, sends
    `waiting/phase='bite'`, and opens a hook window of exactly `data.hookWindow` ms
    waiting for **SPACE**.
11. On SPACE: `zfishing:hook` → server checks the deadline, moves to `reeling`,
    records `reelStart`.
12. Client sends `reel` to the NUI with the fight parameters and starts a thread
    that streams SPACE hold/release as `reelInput` messages. `Casting.StartFight()`
    makes the bobber's distance track the fish's energy.
13. The NUI runs `MinigameEngine` in a RAF loop. It streams `reelEnergy` back
    (throttled: at most every 150ms, and only on a ≥1% change) so the bobber moves
    smoothly, and on finish posts `reelResult { success, reason, durationMs }`.
14. Client calls `zfishing:claim(sessionId, ...)`. Server validates timing, locks
    the session into `settling`, grants the item, adds XP, logs the catch, rolls
    rare loot, increments the rate counter, resets.
15. On success the client shows the catch card and takes NUI focus. The card's
    single "Continue" button fires the `keep` NUI callback, which closes the card
    and runs `cleanup()` — see §9.

---

## 3. Contract reference

Everything below is the complete external surface. Names are exact.

### 3.1 Server callbacks (`lib.callback.register`) — client awaits these

Every callback below except `cast` and `sellAll` takes a `sessionId` (or, for the
rig callbacks, is independently gated) — see the per-action flood gate note after
this list, and §2 for what the token protects against.

**`zfishing:cast(power: number 0..1, rodSlot: number) → table`**

Validation order, each returning `{ ok = false, reason = <string> }`:

| Check | reason |
|---|---|
| per-action flood gate (`cast`: max 3 per 2000ms) | `too_many_requests` |
| `Zfishing.Blocked()` — runtime profile unavailable | `unavailable` |
| session already exists | `busy` |
| rate limit exceeded (`Config.RateLimit` successful catches per fixed 60s window) | `rate` |
| `power` not a number in `0..1` | *(no reason field)* |
| enhanced mode: slot is not a rod the player owns | `no_rod` |
| enhanced mode: rig incomplete (`RigRules.IsComplete`) | `rig_incomplete` |
| simple/no-assembly mode: no owned rod at the player's level | `no_rod` |
| no bait item owned | `no_bait` |
| `resolveZone()` returned nil | `no_zone` |
| `Generator.Roll` produced no candidates | `empty_water` |
| rod hit 0 durability during the wear pass and `RodCanBreak` is on | `rod_broke` |

Success returns `{ ok = true, sessionId = <string>, rod = <rod label>, bait = <bait
label> }`. `sessionId` is a per-cast token, minted by `newSessionId()` in
`server/session.lua` — a monotonic sequence plus a random half. It is
correlation and stale-request protection, **not a secret**: a modified client
can always read its own. The client must send it back on every `hook`/`claim`/
`cancel` call for this session; a call with a missing, malformed, or mismatched
token gets `reason = 'invalid_session'` without touching any real session (see
§2).

The client turns any `reason` into a locale key by prefixing `error_`, e.g.
`error_no_bait`.

**`zfishing:hook(sessionId: string) → { ok, reason? }`**

`reason = 'invalid_session'` (bad token), `'too_many_requests'` (flood gate: max
5 per 2000ms), or `'too_slow'` (past `s.hookDeadline`).

**`zfishing:claim(sessionId: string, reelDurationMs: number, success: boolean, reason?: string) → table`**

- `{ ok = true, fish = { label, weight, quality, species } }` — caught
- `{ ok = true, fish = nil }` — legitimate escape or snap
- `{ ok = false, reason = 'too_fast' | 'timeout' | 'inv_full' | 'settle_failed' | 'invalid_session' | 'too_many_requests' }`

`too_many_requests` is the flood gate (max 3 per 3000ms), checked before the
session lookup.

**The three outcome shapes are distinct, and the client renders them
differently.** `client/minigame.lua`'s `reelResult` handler used to have a single
`else` arm that reported *every* `ok = false` as `fish_escaped` — telling a player
whose inventory was full that the fish got away. Failures now map through an
explicit `CLAIM_ERRORS` table:

| `reason` | locale key |
|---|---|
| `inv_full` | `error_inv_full` |
| `timeout` | `error_claim_timeout` |
| `settle_failed` | `error_settle_failed` |
| `too_many_requests` | `error_too_many_requests` |
| `invalid_session` | `error_invalid_session` |
| anything else, or no answer at all | `error_claim_failed` |

Explicit rather than `'error_' .. reason`: the reasons are wire-level, not every
one deserves a player-facing string, and a missing key renders as the raw reason
in-game. `web/src/__tests__/claimErrorLocales.test.ts` asserts every value in that
table plus the fallback exists and is non-blank in **both** locale files — an
earlier pass shipped an unreachable `error_settle_failed` for exactly this reason.
`error_settle_failed`'s wording is deliberately neutral about whether the fish was
secured, because the backstop it reports fires on the pre-commit path. `reason == 'snap'` on a failed claim destroys the fitted line
component (`Rig.breakLine`) and fires `zfishing:rig:notify` with `line_broke`.
A successful claim locks the session in `settling` before the reward is granted
— see §2.

Note: `reelDurationMs` is *sent by the client but not used* — the server measures
elapsed time itself from `s.reelStart`.

**`zfishing:cancel(sessionId: string) → { ok, reason? }`** — `reason =
'invalid_session'` on a bad token. In `waiting` / `hooking` / `reeling` it resets
the session immediately. In `settling` it answers `{ ok = true }` **without**
resetting: the reward path owns the session until it finishes (§2). Deliberately
**not** behind the flood gate — cancel is the "bail out" escape hatch (see §3.5 /
§9) and must never be throttled.

**`zfishing:sellAll() → { ok: boolean, total: number, reason? }`**

| Check | reason |
|---|---|
| per-action flood gate (`sell`: max 2 per 3000ms) | `too_many_requests` |
| `Zfishing.Blocked()` — runtime profile unavailable (also notifies server-side) | *(no reason field)* |
| a sale for this player is already in flight | `sale_busy` |
| nothing sold — the player carries no priced fish | *(no reason field)* |
| `Zfishing.AddMoney` refused; every removed fish was handed back | `payout_failed` |
| the sale raised (adapter error); the lock was released | `sale_failed` |

`{ ok = true, total = <sum> }` on success. `total` is always `0` on any failure
branch. The two reasonless branches keep the pre-existing client contract: the
sell NPC shows "you have no fish to sell" only when the server named no reason.
See §4.4 for the locking and payout rules.

**`zfishing:rig:get(slot: number) → RigView | nil`**

Returns bare `nil` — not an error table — both when the slot holds no rod the
player owns and when the per-action flood gate rejects the request (`get`: max
10 per 5000ms). The client's contract is `if not view`, so a truthy
`{ ok = false, ... }` would be mistaken for a real view and pushed to the NUI;
the gate deliberately matches the existing nil contract instead of introducing
a new shape.

```lua
{
  rod      = 'fishing_rod_common',        -- item name
  rodLabel = 'Bamboo Rod',
  rodDur   = 37, rodMax = 40,
  parts    = {                            -- only sockets that are filled
    reel  = { name = 'reel_carbon', label = 'Carbon Reel', dur = 98, max = 100 },
    line  = { ... }, hook = { ... }, float = { ... },
  },
  missing  = { 'hook', 'float' },         -- empty socket names
  carried  = {                            -- spare parts in the player's inventory
    reel  = { { slot = 12, name = 'reel_cheap', label = 'Cheap Reel', dur = 60, max = 60 }, ... },
    line = {...}, hook = {...}, float = {...},
  },
}
```

`carried` expands stacks: a stack of 3 identical hooks yields 3 entries, all with
the same inventory `slot`.

**`zfishing:rig:attach(slot, partType, itemName, partSlot) → { ok, err? }`**
`partType` ∈ `reel | line | hook | float`.
`err` ∈ `too_many_requests | bad_part | no_rod | bad_item | not_carried | inv_full | remove_failed | meta_failed`.
The flood gate (max 10 per 5000ms) is checked first and, unlike `rig:get`,
returns the normal `{ ok = false, err = ... }` table rather than bare `nil` —
`attach`/`detach` already have an error-table contract, so there is no
existing-shape reason to special-case it. If the socket is already occupied the
fitted part is returned to the inventory first; if that fails, the whole
operation aborts with `inv_full`. On a metadata write failure the removed part
is added back — a part is never destroyed silently.

**`zfishing:rig:detach(slot, partType) → { ok, err? }`**
`err` ∈ `too_many_requests | bad_part | no_rod | empty | inv_full` (same gate:
max 10 per 5000ms). The part is added back to the inventory **before** it is
cleared from the rod, so a full inventory leaves it fitted rather than deleting
it.

**Admin callbacks** — all gated by `exports.zcore_lib:IsAdmin(src, 'zfishing.admin')`
and returning `{ ok = false, err = 'denied' }` when refused:

| Callback | Args | Returns |
|---|---|---|
| `zfishing:admin:check` | — | `boolean` |
| `zfishing:admin:getConfig` | — | `{ settings, zones, fish, equipment, rarity, waterTypes }` or `nil` |
| `zfishing:admin:saveSetting` | `key, value` | `{ ok, err }` |
| `zfishing:admin:saveZone` | `zone` | `{ ok, id }` |
| `zfishing:admin:deleteZone` | `id` | `{ ok }` |
| `zfishing:admin:saveFish` | `species, data` | `{ ok, err }` |
| `zfishing:admin:deleteFish` | `species` | `{ ok }` |
| `zfishing:admin:saveEquipment` | `slot, item, data` | `{ ok, err }` |
| `zfishing:admin:resetDomain` | `'settings'\|'zones'\|'fish'\|'equipment'` | `{ ok, err }` |

### 3.2 Net events

**Server → client**

| Event | Payload |
|---|---|
| `zfishing:bite` | `{ behavior, tensionDiff, fishEnergy, hookWindow, greenZone, snapFactor, drainRate, baseDrain, reelTimeout, fishWeight }` |
| `zfishing:client:useRod` | the inventory item table (has `.slot`) |
| `zfishing:rig:notify` | `kind ∈ 'part_broke' \| 'rod_broke' \| 'line_broke'`, plus `label` for `part_broke` |
| `zfishing:store:sync` | `{ zones[], castMaxDistance, defaultWater, requireZone }` |
| `zfishing:client:syncBoatAnchor` | `netId, state:boolean` — broadcast to **all** clients |
| `zfishing:admin:open` | — |
| `zfishing:zonetool:start` | — |

The `zfishing:bite` payload is deliberately *abstracted*. It never contains
`species`, `label`, `price`, `xp`, `rarity`, or `quality`. `fishWeight` is sent
because the NUI needs it for fight dynamics — it is the one concrete value that
leaks, and it leaks after the roll is already locked in.

`drainRate` and `baseDrain` are not the same kind of number, and §8 invariant 6
already warns about the naming half of this — here is the units half: `baseDrain`
is `Config.Minigame.baseDrain`, a single server-tuned constant (energy drained
per second while in the green zone, same for every fight). `drainRate` is
per-session — `s.reelDrain`, the fitted reel's `drainRate` stat (how fast *this*
fish tires against *this* gear). The engine multiplies them:
`energy -= baseDrain * drainRate * dt` (§7.3). Confusing the two — e.g. trying to
retune fight difficulty by editing a reel's `drainRate` when the intent was the
global pace, or vice versa — changes the wrong thing.

**Client → server**

| Event | Payload | Gate |
|---|---|---|
| `zfishing:reportWeather` | `weather:string, hour:number` — low trust by design, bonuses only | max 3 per 60000ms |
| `zfishing:store:request` | — (sent once, 1s after client start) | max 3 per 10000ms |
| `zfishing:server:anchorBoat` | `netId` | max 5 per 5000ms |
| `zfishing:server:unanchorBoat` | `netId` | **none, deliberately** |

Every one of these is cheap per request, which is exactly why an ungated one is
worth flooding — `store:request` rebuilds the whole zone payload, `anchorBoat`
resolves an entity and can broadcast to `-1`. A throttled request is dropped
silently: no disconnect, no log line, and no effect on a fishing session.

`unanchorBoat` is ungated for the same reason `cancel` is: it is the release path.
A throttled unanchor would leave a boat frozen for good, because `client/main.lua`
nils `currentBoatNetId` unconditionally and never retries. Flooding it costs one
table lookup and broadcasts nothing unless the caller actually holds a reference to
that boat (§9).

**`reportWeather` is validated, not merely gated.** It is the only client-supplied
value the server *keeps*. `weather` must be a name in `ZUtil.WEATHER_TYPES` (the
same table `client/main.lua` reports from — §8 invariant 11) and `hour` a number in
`0..23`. Anything else — `nil`, a table, a string hour, `NaN`, `±inf`, a negative
hour, `24`, an unknown weather name — is dropped, leaving the previous state in
place. The old code did `math.floor(hour) % 24` on whatever arrived, which stored
`-nan` as the hour for an infinite input.

**Client-internal**

`zfishing:client:end(msgKey, msgType)` — the single teardown entry point.
`zfishing:rig:forceClose` — closes the rig menu during cleanup.

### 3.3 NUI messages (Lua → React, via `SendNUIMessage`)

Dispatched by a single `switch (msg.action)` in `App.tsx`.

| `action` | Fields | Effect |
|---|---|---|
| `cast` | `state ∈ 'start'\|'charge'\|'release'`, `power` | shows `CastBar` |
| `waiting` | `phase ∈ 'waiting'\|'bite'`, `rod`, `bait`, `distance` | shows `FishingInfoCard` + `WaitingHud` |
| `reel` | `behavior, tensionDiff, fishEnergy, greenZone, snapFactor, drainRate, baseDrain, reelTimeout, fishWeight, startedAt` | mounts `TensionMinigame`; `startedAt` is the React `key`, so each fight gets a fresh engine |
| `reelInput` | `holding: boolean` | updates hold state without remounting |
| `caught` | `label, weight, quality` | shows `CatchCard` |
| `prompt` | `titleKey, subtitleKey` | shows `PromptHud` (locale keys, not text) |
| `promptHide` | — | hides it |
| `rigOpen` | `view: RigView`, `catalog: CatalogEntry[]` | opens `RigMenu` |
| `rigClose` | — | closes it |
| `hide` | — | resets view, prompt, and rig to hidden |
| `admin` | `config` | replaces the whole UI with `AdminPanel` |

### 3.4 NUI callbacks (React → Lua, via `fetchNui`)

| Callback | Body | Handled in |
|---|---|---|
| `getLocale` | — | `client/main.lua` — returns the merged `en` + active-language dict |
| `reelEnergy` | `{ pct: 0..1 }` | `client/minigame.lua` — drives bobber distance |
| `reelResult` | `{ success, reason, durationMs }` | `client/minigame.lua` — triggers the claim; a failed claim maps through `CLAIM_ERRORS` (§3.1), never `fish_escaped` |
| `keep` | — | `client/minigame.lua` — closes the catch card. The NUI button is labeled "Continue" (Task 7 removed the Keep/Release choice); `keep` is the only callback the card fires |
| `rigAction` | `{ kind: 'attach'\|'detach', partType, itemName, slot }` | `client/rig.lua` |
| `rigClose` | — | `client/rig.lua` |
| `adminClose` | — | `client/admin.lua` |
| `adminSave` | `{ cbName, args[] }` | `client/admin.lua` — **generic passthrough** to any `lib.callback` |

`adminSave` is a deliberate passthrough: the NUI names a server callback and the
client forwards it verbatim. This is safe only because every `zfishing:admin:*`
callback re-checks `isAdmin` server-side. Do not add an admin callback that skips
that check.

### 3.5 Commands and keybinds

| Command | Side | Gate |
|---|---|---|
| `/zfishadmin` | server | admin |
| `/zfishzone` | server | admin |
| `/zfishreload` | server | admin — re-pull config from DB and broadcast |
| `/zfish_roll [water]` | server | admin — samples one roll (QA) |
| `/zfish_xp` | server | admin — grants 50 XP (QA) |

| Keybind | Default | Registered as | Condition |
|---|---|---|---|
| Start / charge cast | `E` | raw control 38 | during standby / charge |
| Hook + reel | `SPACE` | disabled control 22 | during bite / reel |
| Cancel fishing | `X` | `zfishing_cancel`, rebindable | **any** phase incl. mid-reel |
| Manage rod | `G` | `zfishing_rig`, rebindable | **only** while `ZClient.standby` |

`X` works in every phase deliberately: `Config.FreezeWhileFishing` removes the
walk-away escape hatch, so there must always be an explicit way out.

### 3.6 Exports

`exports('useRod', startRodUse)` on the client — this is what
`ox_inventory`'s `client = { export = 'zfishing.useRod' }` calls.

---

## 4. Data model

### 4.1 Tables

Schema lives in `migrations/mysql/001_schema.up.sql` (forward-only, with a matching
`.down.sql` and a `checks/001_schema.verify.sql`). Copies also exist in
`sql/zfishing.sql` and `sql/zfishing_admin.sql` as DBA reference.

```sql
zfishing_players (
  identifier VARCHAR(64) PRIMARY KEY,   -- from zcore_lib GetIdentifier
  xp         INT NOT NULL DEFAULT 0,
  level      INT NOT NULL DEFAULT 1,
  stats      LONGTEXT NULL,             -- JSON, currently written as {} — unused hook
  updated_at TIMESTAMP
)

zfishing_catches (                       -- append-only log; the basis for Phase 2
  id         INT AUTO_INCREMENT PRIMARY KEY,
  identifier VARCHAR(64) NOT NULL,       -- INDEX idx_identifier
  species    VARCHAR(32) NOT NULL,       -- INDEX idx_species
  weight     DECIMAL(6,2) NOT NULL,
  quality    TINYINT NOT NULL,           -- 1..5
  zone       VARCHAR(48) NULL,           -- zone NAME, not id
  created_at TIMESTAMP
)

zfishing_settings (`key` VARCHAR(48) PRIMARY KEY, `value` LONGTEXT)   -- value is JSON
zfishing_zones   (id INT AI PK, name, water, x, y, z, radius DOUBLE, pool LONGTEXT NULL, enabled TINYINT DEFAULT 1)
zfishing_fish    (species VARCHAR(32) PK, data LONGTEXT)              -- data is the whole Config.Fish entry as JSON
zfishing_equipment (slot VARCHAR(16), item VARCHAR(48), data LONGTEXT, PRIMARY KEY (slot, item))
```

`zfishing_zones.enabled` is respected by `Store.Load` (`WHERE enabled = 1`) but
nothing in the admin panel currently writes it — it is a manual DBA switch.

`zfishing_catches` has no foreign key to `zfishing_players` and no per-player
aggregate. Leaderboards and challenges are meant to be built as queries over this
table; no schema change is required.

### 4.2 Rod metadata (the "rig")

Assembled components live **inside the rod item's per-instance metadata**, so a
fully-built rod trades as a single item. Shape, from `server/rig.lua`:

```lua
{
  parts = { reel = 'reel_carbon', line = 'line_20', hook = 'hook_4', float = 'float_foam' },
  dur   = { rod = 37, reel = 98, line = 44, hook = 59, float = 78 },
  description = 'Rod 37/40 | Carbon Reel 98/100 | 20lb Line 44/50 | Size 4 Hook 59/60 | Foam Float 78/80',
}
```

- A missing key in `parts` = an empty socket. `dur` keys are cleared together with
  their part.
- `description` is rebuilt on **every** metadata write by `Rig.describe`.
- `Rig.slotMeta(src, slot)` normalizes: it creates `parts`/`dur` if absent and
  initializes `dur.rod` to the configured max. It returns `nil` if the slot does
  not hold a rod the player owns — the client never gets to assert what is in a
  slot.

**Detached parts use a different metadata shape.** When a part leaves the rod it is
handed back as a standalone item carrying `{ durability = '73%' }` — a percentage
string, matching the ox_inventory durability convention. `Rig.getMetaDur` reads it
back and converts to absolute points, accepting a string `'73%'`, a number `73`, or
a raw `dur` number, and defaulting to full durability when there is no metadata at
all. The two shapes are not interchangeable; conversion happens at the boundary in
`makePartMeta` / `Rig.getMetaDur`.

### 4.3 Wear

`Rig.degrade` runs once per cast, **after every validation passes**, so a rejected
cast never grinds gear. Each fitted part loses its configured `degrade` points; at
`<= 0` the part is removed from `parts` and reported in `wear.broke`. The rod
itself also wears: if it hits 0 and `Config.RodCanBreak` is on, the whole rod (with
everything fitted) is destroyed; if it is off, `dur.rod` is pinned at 1 and only the
parts keep wearing.

### 4.4 Selling

`zfishing:sellAll` branches on the pinned mode:

- **enhanced-rig** — every `fish_*` slot is priced from its own metadata via
  `Zfishing.Search`, then removed by slot.
- **simple-fishing** — no per-instance metadata exists, so every fish is priced at
  the species-average weight `(min + max) / 2` and quality 3, and the player is
  explicitly told: *"Sold at standard weight — this inventory has no per-catch
  weight"*.

**The sale invariant: money paid ≤ the value of the fish that actually left the
inventory, and only ever to the player it left.** Four rules hold it up.

1. **Remove first, pay once, from the removals.** Price is accumulated only inside
   the branch where `RemoveItemSlot` / `RemoveItem` returned true, so a slot the
   inventory refuses is never paid for and stays in the bag. (This part was already
   correct before this pass; it is written down here because it looks like the sort
   of thing that gets "simplified" into a sum-then-remove loop.)
2. **A failed payout returns the fish.** `Zfishing.AddMoney`'s result used to be
   discarded, so a refused payout removed the fish, paid nothing, and still reported
   `ok`. The sale now records what it removed (item, count, metadata) and re-adds
   every entry when the payout fails, then answers `payout_failed`. A restore that
   itself fails is printed to the console — that is the one case where a player has
   lost fish. The resource never destroys an item silently.
3. **One sale at a time per player.** Every step crosses the `zcore_lib` resource
   boundary and can yield, so two `sellAll` requests arriving together would each
   price the same fish and each reach `AddMoney`. A `selling[src]` lock is taken
   before the first inventory read; the second request gets `sale_busy`. The lock is
   released on **every** exit — success, empty bag, failed payout, a raised error
   (the callback wraps the sale in `pcall` and answers `sale_failed`), and a
   mid-sale disconnect (`playerDropped` in `server/rewards.lua`, because an
   abandoned callback coroutine never returns through the `pcall`).

4. **A sale belongs to an identity, not to a src.** `sellAll` captures
   `Zfishing.Identifier(src)` into the sale record before the first inventory
   yield and re-checks it at every mutation boundary: before the sweep, **before
   each removal inside it**, before `AddMoney`, and before compensation. A sale
   that cannot obtain an identifier is refused before the inventory is read.

   The sale cannot use `Progression.IdentityState` the way the catch path does —
   a player who has never cast has no progression cache, and treating that as
   "gone" would refuse every first sale — so it reads the canonical identifier
   from the pinned runtime contract instead. Never anything the client supplied.

   The per-removal check is not paranoia: the sweep is a loop of resource-boundary
   calls that each yield, so a src changing hands halfway through would have the
   remaining removals strip the *replacement* occupant's fish. It costs one
   identifier lookup per removed stack, on a manual NPC interaction.

A `sell` flood gate (max 2 per 3000ms) sits in front of all of it, so a spammed
sale costs a table lookup rather than a full inventory sweep.

**Reconciliation.** Every sale attempt mints a server-side `saleId`
(`<src>-<gametimer>-<seq>`, never sent to the client) so lines about the same sale
can be tied together in a console where several players are selling at once. A
failed payout logs one summary — `saleId`, `src`, `expectedPayout`, `removed`,
`restored`, `restoreFailed` — followed by one `CRITICAL sale reconciliation` line
per stack that could not be handed back, carrying the item, count, metadata
summary and expected payout. That is everything needed to make a player whole.
There is deliberately **no** per-sale success line: a successful sale already has
a client-visible receipt, and one line per sale would bury the CRITICAL lines. A
DB ledger is out of scope; the console record is what an admin reconciles from.

**Identity loss mid-sale takes the same route.** When a guard fires, the
transaction stops dead — the replacement occupant is neither paid nor given the
original player's fish back, because both would hand a stranger something that is
not theirs. What is already out of A's bag stays out, and the console gets:

```
[zfishing] sale aborted on identity loss saleId=<id> src=<n> identity=<safe> stage=<stage> expectedPayout=<n> removed=<n>
[zfishing] CRITICAL sale reconciliation saleId=<id> src=<n> identity=<safe> stage=<stage> lost item=… count=… meta=… expectedPayout=<n>
```

one CRITICAL per stack that left the inventory, all sharing the `saleId`.
`stage` is `removal`, `payout` or `compensation` — where identity was lost — and
the pre-existing failed-restore path now carries `stage=restore_failed`. This is
deliberately manual: the window is a disconnect landing between two specific
yields of one NPC interaction, and the reconciliation philosophy here has always
been "one correlated record an admin can act on", not a rollback.

### 4.5 The catch commit boundary

`Rewards.GiveCatch` returns a structured result, not a boolean:

```lua
{ ok = true,  committed = true,  warnings = { 'xp_save_failed', ... } }
{ ok = false, committed = false, reason = 'inv_full' }
```

**The fish item entering the inventory is the commit point.** Above it, a failure
means the player got nothing and the claim answers `inv_full`. Below it the catch
is *committed*, and nothing may turn it back into a failure — the fish is in the
player's bag, so answering "you caught nothing" would make the server state and
what the player sees disagree.

```
Zfishing.AddItem(fish)
      │
      ├─ false ─────────────► { committed = false, reason = 'inv_full' }
      │
      └─ true  ─────────────► COMMITTED
                                 ├─ XP + Progression.SaveAwait   → xp_save_failed
                                 ├─ catch log (MySQL.insert.await)→ catch_log_failed
                                 └─ rare loot roll + AddItem      → rare_loot_failed
```

Each secondary stage runs in its own `pcall` and must return an explicit boolean;
`runStage` treats `not err` as failure, so a stage that forgets to return cannot
pass silently. A failed stage appends `{ stage, detail }` to `warnings`.
**`rewards.lua` prints nothing.** `server/session.lua` — the only scope holding the
session id and the captured identity — prints one line per warning, next to the
`claim settled …` line. **The client is never told.**

```
[zfishing] catch settlement warning session=<id> src=<n> identity=<safe> stage=<stage> detail=<cause>
```

**One secondary failure produces exactly one console record.** `runStage` used to
print its own line *and* session.lua printed a second from `res.warnings`; that
duplication was removed in the 2026-08-19 identity pass. `tests/security.test.lua`
group S asserts the **count**, not the presence — a find-based assertion is
satisfied by the duplicate it exists to catch.

Two cases deliberately do *not* warn: a player who dropped mid-settle (the
identity guard below skips player-facing stages silently when nobody is on the
src — an expected disconnect, and warning on it would train operators to ignore
the line), and a 0-XP species (`ConfigSchema` clamps `xp` to `0..100000`, so 0 is
reachable, and MySQL reports 0 changed rows for a write of identical values —
`SaveAwait` therefore tests `affected ~= nil`, not `affected > 0`).

#### The identity guard: source-id reuse

**FiveM source ids are recycled.** A settlement yields on every step, so this
sequence is reachable:

```
player A on src=17 → claim enters settlement → AddItem yields
                                             → A disconnects
                                             → src=17 is assigned to player B
                                             → A's coroutine resumes holding src=17
```

Without a guard the resumed coroutine grants B the fish, adds B the XP, drops A's
rare loot in B's bag, files A's catch under B's identifier, and — in `session.lua`
itself — frees B's live session and spends one of B's `Config.RateLimit` slots.

The fix is a **stable identifier captured at cast time**, on the session next to
`sessionId`, and re-checked at every mutation boundary:

| Where | Comparison | On mismatch |
|---|---|---|
| `zfishing:cast` | `prog.identifier` must be a string | refuse the cast (`no_identity`) — fail closed before a reward-bearing session exists |
| `GiveCatch`, above `AddItem` | `Progression.IdentityState(src, ctx.identifier)` | nothing is committed: `player_gone` / `identity_changed` |
| XP stage, rare-loot stage | same | stage skipped; `changed` records a warning, `gone` is silent |
| catch-log stage | **none, deliberately** | writes `ctx.identifier` — see below |
| `session.lua`, after the settlement yield | `sessions[src] == s` | skip `reset(src)` and the rate increment |

`Progression.IdentityState(src, expected)` is the **single comparison** every
catch-side guard delegates to. It answers `same` / `gone` / `changed`, and a
non-string `expected` never matches, so a caller that forgot to capture identity
fails closed. Each mutation has exactly one guard: two layers would mean deleting
one still blocks the mutation, and the mutation tests could not fail.

**`sessionId` ≠ player identity, and neither substitutes for the other.**
`sessionId` is per-cast and makes a *stale or replayed request for this session*
detectable — which is still true when the src changed owners. The stable
identifier is per-player and makes *this src is no longer that player* detectable.
Different problems, both needed.

**The catch log is not identity-guarded, and that is the point.** The row is
history, not a player mutation, so it is written against `ctx.identifier`
regardless of what happened to the src. Re-reading `Progression.Get(src)` there —
which is what it used to do — files A's fish under whoever holds A's src by the
time the insert runs.

**Committed stays committed.** Identity lost *before* `AddItem` means nothing is
granted at all. Identity lost *after* it leaves `committed = true`, skips every
remaining player mutation, records a warning, and never rolls the fish back. The
client still gets `ok = true`.

**Disconnect is not a breach.** `gone` (nobody on that src) is the ordinary case
and is logged only as `reason=player_gone` on the routine claim line. `changed`
(someone else on that src) gets its own record:

```
[zfishing] identity guard blocked stale settlement session=<id> src=<n> expected=<safe> stage=catch_commit
```

Identifiers in both lines go through `ZUtil.SafeId` — scheme plus the last four
characters (`license:...7890`), enough to correlate two lines or match a DB row
without pasting a full license id into a console dump. Guards always compare the
**full** identifier; a redacted form can collide.

`player_gone`, `identity_changed` and `no_identity` never reach the wire.
`session.lua` collapses them to `claim_failed`, which `client/minigame.lua`'s
unmapped-reason fallback renders as `error_claim_failed`.

**Persistence is awaited only here.** `Progression.Save()` stays fire-and-forget
for `Unload` / `playerDropped` / the QA command, where nobody reads the result;
`Progression.SaveAwait()` exists so the settlement path can tell whether the write
landed. Before this, `pcall` around the reward path proved only that the calls were
*dispatched*.

**`Config.RateLimit` counts committed catches.** The increment moved behind
`committed`: a claim refused with `inv_full` used to burn one of the player's
successful catches for that minute.

---

## 5. The config → DB lifecycle

**This is the single most common source of wrong assumptions about this resource.**

`config/*.lua` files are **seed data, not live configuration**. The sequence at boot:

1. `Store.Seed()` — for each of the four domains (`settings`, `zones`, `fish`,
   `equipment`), if the marker row `_seeded_<domain>` is absent from
   `zfishing_settings`, copy the static `Config` values into the DB and write the
   marker.
2. `Store.Load()` — read the DB back and **overwrite the in-memory `Config`
   tables**. From this point the DB is the source of truth; the Lua file values are
   dead unless a domain is reset.
3. `Store.Broadcast()` / `Store.SyncTo(src)` — push the client-relevant subset to
   clients, where `client/store.lua` overwrites the client's `Config.Zones`,
   `Config.CastMaxDistance`, `Config.DefaultWater`, and `Config.RequireZone`.

**Which settings are DB-backed.** Only these nine keys, from `SETTING_KEYS` in
`server/store.lua`:

```
RateLimit  Timings  CastMaxDistance  Durability  RareLoot
DefaultWater  RequireZone  RodCanBreak  RequireAssembly
```

Everything else in `config/main.lua` is **file-only and restart-required**:
`Config.Locale`, `Config.PromptHud`, `Config.Keybind`, `Config.SellNpcs`,
`Config.FreezeWhileFishing`, `Config.Admin`. `Config.SellNpcs` in particular is
consumed by a boot thread that spawns the peds — it is not in the admin panel and
changing it needs a resource restart.

**Consequence for anyone editing this resource:** changing a value in
`config/fish.lua` on a server that has already booted once has **no effect**. The
change must go through the admin panel, a direct DB edit followed by
`/zfishreload`, or a domain reset (delete the `_seeded_<domain>` row and restart,
or call `zfishing:admin:resetDomain`).

**Schema ownership.** `server/store.lua`'s boot thread is explicit: the resource
must never create or alter schema. The migrations under `migrations/mysql/` are
applied by an external provisioner (the "Site Agent") *before* the resource starts.
`Seed()` and `Load()` only read and write business data into already-provisioned
tables. (`README.md` used to say tables are "created automatically on first
start" — that was stale and has been corrected; see its **Database** section.)

**Equipment field backfill.** `Store.Load` keeps a snapshot of the static
`Config.Equipment` taken *before* the DB overwrite, and backfills any key present in
the seed but missing from a DB row — then writes the repaired row back. This is how
fields added in later versions (e.g. `degrade`) reach installs that seeded from an
older build, without clobbering admin-edited values.

**Validation.** Every admin write passes through `ConfigSchema` in
`server/config_schema.lua`, which clamps rather than rejects for numbers:

```
RateLimit 1..120        CastMaxDistance 5..100
Timings.biteMin/biteMax 500..60000     Timings.hookWindow 200..10000
Timings.hookLatency 0..2000            Timings.reelTimeout 3000..120000
greenZone 0..1   rareBonus 0..5   durability 0..10000   level 1..100
drainRate 0.1..10   rating 1..500   hookMod 0.1..5   biteSpeed 0.1..5   degrade 0..1000
Water types: lake | river | ocean | swamp | dam
Behaviors:   steady_light | steady_heavy | run_stop | erratic
Equipment slots: rods | reels | lines | hooks | floats | baits
```

---

## 6. The zcore_lib bridge

zfishing supports ESX, QBCore, and QBox, and ox_inventory / qb-inventory / framework
-native inventories — but it contains **zero** framework-specific code outside
`server/usable.lua`. All of it lives behind `zcore_lib`.

### 6.1 Mode pinning

`zcore_lib` holds an operator-owned runtime profile at
`zcore_lib/shared/runtime_profile.lua`. `server/lib.lua` reads it **once** at boot
via `exports.zcore_lib:GetProfile()` and caches the result:

- `enhanced-rig` — the inventory supports per-item metadata. Rod assembly, per-catch
  weight/quality, and metadata pricing are all on.
- `simple-fishing` — no per-item metadata. Rod assembly is **explicitly disabled**
  (not silently degraded), fish are plain stacked items, and selling uses average
  weight.
- Anything else, or an unavailable profile → `Zfishing.Blocked()` returns an error
  table and **all fishing is refused** with reason `unavailable`.

There is no runtime probing, no `GetResourceState` auto-detection of the inventory,
and no silent downgrade. The mode is decided ahead of time and pinned.

### 6.2 The envelope

Every bridge call returns a structured envelope, not a bare value:

```lua
-- success
{ contract = <version>, ok = true, operation = 'inventory.addItem',
  correlationId = ..., adapter = {...}, evidence = {...},
  effects = { details = { <the actual payload> } }, warnings = {} }

-- failure
{ ok = false, error = { code = 'PROFILE_UNAVAILABLE', message = '...', retryable = false,
  capability = ..., unsupportedFields = {}, remediation = {} }, ... }
```

`server/lib.lua` unwraps this so that gameplay code works in plain values, and an
adapter failure surfaces as an explicit `false`/`nil`/`0` rather than a swallowed
error. Every call is wrapped in `pcall`.

### 6.3 The facade

| `Zfishing.*` | `zcore_lib` export | Operation | Unwrapped value |
|---|---|---|---|
| `Identifier(src)` | `GetIdentifier` | `player.getIdentifier` | `details.identifier` |
| `HasItem(src, item, n)` | `HasItem` | `inventory.has` | `details.hasItem == true` |
| `ItemCount(src, item)` | `GetItemCount` | `inventory.count` | `details.count` or `0` |
| `Search(src, items[])` | `SearchItem` | `inventory.search` | `details.items` or `{}` |
| `GetSlot(src, slot)` | `GetSlot` | `inventory.getSlot` | `details.item` |
| `SetSlotMeta(src, slot, meta)` | `SetSlotMeta` | `inventory.setMetadata` | boolean |
| `AddItem(src, item, n, meta)` | `AddItem` | `inventory.addItem` | boolean |
| `RemoveItem(src, item, n)` | `RemoveItem` | `inventory.removeItem` | boolean |
| `RemoveItemSlot(src, item, n, slot)` | `RemoveItemSlot` | `inventory.removeSlot` | boolean |
| `AddMoney(src, amount, reason)` | `AddMoney` | `money.add` | boolean (always `'cash'`) |
| `Notify(src, msg, kind)` | `Notify` | `ui.notify` | — |
| `Blocked()` / `Mode()` / `Enhanced()` / `Simple()` | `GetProfile` | `profile.get` | cached |

Admin permission uses `exports.zcore_lib:IsAdmin(src, 'zfishing.admin')` directly —
a shared zero-config policy across the ZCore ecosystem (console, an optional
resource ACE, common server-admin ACEs, or framework admin groups).

### 6.4 The one deliberate exception

`server/usable.lua` registers rods as useable items **directly against the
framework** rather than through the bridge. The reasoning is documented in the file:
registering a useable item means handing a *callback* across a resource boundary,
which is the fragile part of FiveM exports, unlike read operations that pass strings
and return tables. It probes the bridge once for diagnostics, then falls back to
`qb-core` / `qbx_core` / `es_extended` directly with a local callback. Under
ox_inventory this path is not used at all — ox calls the client export
`zfishing.useRod`.

---

## 7. Gameplay math

Every formula below is in the source; none are approximations.

### 7.1 The roll (`server/generator.lua`)

Candidate species = every fish whose `water` list contains the zone's water type,
restricted further by `zone.pool` if the zone defines one. Each candidate's spawn
weight starts at `Config.Rarity[rarity].weight`:

```
common 100 | uncommon 45 | rare 15 | epic 5 | legendary 1
```

and is then multiplied by:

| Factor | Multiplier |
|---|---|
| Bait matches one of the species' `baits` | `× 3` |
| Rod `rareBonus` × hook `rareBonus` | only for non-`common` species |
| Weather, from `Config.Weather.weather[<WEATHER>][species]` | e.g. `RAIN` → trout `× 1.6` |
| Hour range, from `Config.Weather.time` | e.g. 20:00–24:00 → catfish `× 1.8` |

Then `ZUtil.weightedPick`. Derived values for the picked fish:

```lua
weight      = randFloat(fish.weight.min, fish.weight.max), rounded to 2dp
quality     = clamp(1 + floor(ratio*4 + 0.5) + rand(-1,1), 1, 5)   -- ratio = position in the weight band
biteDelay   = rand(Config.Timings.biteMin, Config.Timings.biteMax)  -- default 4000..12000 ms
hookWindow  = floor(Config.Timings.hookWindow * rarity.hookMult * hook.hookMod)  -- base 1500 ms
tensionDiff = rarity.tension            -- common 1.0 … legendary 1.8
fishEnergy  = min(200, 40 + weight * 1.5)
```

The `min(200, ...)` cap on `fishEnergy` is load-bearing: uncapped, a 400 kg shark
would need a minimum plausible reel time longer than `Config.Timings.reelTimeout`
and become mathematically uncatchable.

At bite time the session computes one more value:

```lua
snapFactor = clamp(lineRating / max(1.0, fish.weight), 0.3, 3.0)
```

This abstracts "does my line outclass this fish" into a single number, so the
client learns how forgiving the line is **without** learning the species or weight
from it.

### 7.2 Gear stats (`shared/rig_rules.lua` → `ExtractStats`)

```lua
reelDrain      = reels[parts.reel].drainRate      or 1.0   -- how fast the fish tires
lineRating     = lines[parts.line].rating         or 10    -- kg-equiv before snapping
hook           = parts.hook                                -- item name, feeds the roll
floatBiteSpeed = floats[parts.float].biteSpeed    or 1.0   -- divides biteDelay, min 500 ms
```

Shipped values: reels `1.0 / 1.3 / 1.7`; lines `10 / 20 / 40 / 60`; hooks
`hookMod 1.2 / 1.0 / 0.85 / 0.7` with `rareBonus 1.0 / 1.1 / 1.2 / 1.35`; floats
`biteSpeed 1.0 / 1.15 / 1.3`; rods `greenZone 0 / 0.05 / 0.10 / 0.15` with
`rareBonus 1.0 / 1.15 / 1.3 / 1.6` and level gates `1 / 11 / 26 / 50`.

### 7.3 The tension minigame (`web/src/engine/minigameEngine.ts`)

A pure class, `tick(dt, holding, elapsedMs) → EngineState`, with no React or DOM
dependency. State per tick:

```ts
// green-zone band, centered on a moving target
greenHalf = 14 + greenZone * 80
center oscillates around 55, eased toward the target at lerpRate,
       clamped to [greenHalf + 4, 100 - greenHalf - 4]

// tension
tension += ((holding ? 40 : -50) + pull * tensionDiff) * dt      // clamped 0..100

// energy
in green:      energy -= baseDrain * drainRate * dt
below green:   energy += 3 * dt                                  // capped at fishEnergy
above green:   energy unchanged

// snapping
tension > 92:  snapMs += dt*1000     else snapMs -= dt*500 (floor 0)
snapBudget  =  900 * snapFactor
```

`baseDrain` and `reelTimeout` are not hard-coded in the engine — both are
injected from the `zfishing:bite` payload's `EngineConfig`
(`baseDrain = Config.Minigame.baseDrain`, `reelTimeout = Config.Timings.reelTimeout`,
both read server-side and shipped to the client at bite time). See §8 invariants
1 and 2 for why this single-sources them against the server's own claim-time math.

`pull` by behavior: `steady_light` 12, `steady_heavy` 22, `run_stop` 30 for the
first 3s of each 5s cycle then 5, `erratic` a re-rolled `5..35` every 700–1500ms.
Amplitude and speed of the center's oscillation also scale with a weight factor
`wf = clamp(fishWeight / 50, 0.3, 2.5)`.

Finish conditions, checked in this order:

| Condition | `finishReason` |
|---|---|
| fish was damaged (`energy` dropped below 98%) and has recovered to full | `escape` |
| `energy <= 0` | `success` |
| `snapMs >= snapBudget` | `snap` |
| `elapsedMs >= reelTimeout` | `timeout` |

### 7.4 Economy and progression

```
price = floor(Config.Fish[species].price × weight × qualityMult)
qualityMult = { 1: 0.7, 2: 0.9, 3: 1.0, 4: 1.3, 5: 1.8 }

level N requires floor(100 × N^1.5) additional cumulative XP
```

XP per species ranges from 10 (bass) to 200 (golden fish). Prices per kg range from
8 to 500. Rare loot is rolled **independently per entry** on every successful catch —
the shipped `Config.RareLoot` entries give about a 10.1% chance of something, and
the first entry that passes its own roll wins (the function returns on the first hit).

---

## 8. Cross-file invariants

These are couplings that are not enforced by any type system. Breaking one produces
a silent failure, not a crash.

**1. (Resolved) The drain constant used to be duplicated.**
`web/src/engine/minigameEngine.ts` used to drain a hard-coded `12 * drainRate *
dt` in the green zone while `server/session.lua`'s claim validation
independently computed `minMs` from its own hard-coded `12`, with no link
between them — changing one without the other made the server silently reject
legitimate catches. The constant is now `Config.Minigame.baseDrain` (default
`12.0`, `config/main.lua`), read server-side and shipped to the client in the
`zfishing:bite` payload. Both sides now consume the *same* value: the engine as
`energy -= baseDrain * drainRate * dt` (§7.3), the server's claim floor as
`minMs = (fish.fishEnergy / (Config.Minigame.baseDrain * drain)) * 1000` with a
`0.9` slack (`server/session.lua`). Retuning the drain rate is now a one-line
change in `config/main.lua` — no client rebuild, and nothing to keep in sync by
hand.

**2. (Resolved) The reel timeout used to have two different limits.**
The engine used to finish with `timeout` at a hard-coded `elapsedMs >= 28000`
while the server independently rejected a claim past
`Config.Timings.reelTimeout + 5000` — retuning `reelTimeout` in the admin panel
below 23,000ms put the server's cutoff *under* the engine's own hard-coded
timeout, rejecting a fight that legitimately ran long before the NUI ever gave
up. The engine now reads `reelTimeout` from the same `zfishing:bite` payload the
server derives its own cutoff from (`elapsedMs >= this.config.reelTimeout` in
`minigameEngine.ts`) — there is exactly **one** authoritative timeout,
`Config.Timings.reelTimeout`. The server's `+ 5000` (`server/session.lua:235`,
at the time of writing) **stays**, and is now purely latency grace layered on
top of that one timeout — the round trip for the NUI's `reelResult` to reach
the `claim` callback — not a second, competing limit. Do not "fix" it away to
match `reelTimeout` exactly; a fight that legitimately finishes right at the
wire still needs that grace, or network latency alone would fail it.

**3. The hook window is asymmetric on purpose.**
Server: `hookDeadline = now + fish.hookWindow + Config.Timings.hookLatency` (300ms
grace). Client: exactly `data.hookWindow`, no grace. The client is deliberately the
stricter of the two; the grace exists only to absorb network latency. Do not "fix"
the client to match.

**4. `PART_TYPES` is declared in three places.**
`shared/rig_rules.lua` (`RigRules.PART_TYPES`), `server/rig.lua` (local
`PART_TYPES` + `SLOT_OF`), and `client/rig.lua` (local `PART_TYPES` + `SLOT_OF`).
Adding a fifth socket type means editing all three, plus `web/src/rigRows.ts`.

**4b. A transient FiveM source id is never sufficient identity for a coroutine
that can survive a yield.**
Source ids are recycled. Any operation that yields and then mutates player state
must have captured something stable *before* the yield and re-checked it *after*:
the fishing session captures `identifier` alongside `sessionId`
(`server/session.lua`), the catch settlement carries it in `ctx`
(`server/rewards.lua`), the sale captures it into the sale record, and
`session.lua`'s own post-settlement `reset` / rate-increment guard on
`sessions[src] == s`. `Progression.IdentityState` is the one comparison the catch
side uses; the sale side uses `Zfishing.Identifier` because a player who never
cast has no progression cache. **Adding a new yielding operation that touches
player state means adding a capture and a re-check** — `sessionId` alone does not
cover it, because a replayed-session check is still satisfied when the src changed
owners. Every guard is individually mutation-tested (§10).

**5. Zone distance is 2D in both places and must stay that way.**
`client/main.lua`'s `currentZone()` and `server/session.lua`'s `resolveZone()` both
compare squared horizontal distance, ignoring Z. If one becomes 3D, players will
pass the client gate and be refused by the server (or worse, the reverse).

**6. `Rig.stats()` field names flow through three layers unrenamed.**
`RigRules.ExtractStats` produces `reelDrain / lineRating / hook / floatBiteSpeed`.
`session.lua` reads those names, stores `reelDrain` on the session, and ships it to
the NUI as `drainRate` (a rename that happens exactly once, in the `zfishing:bite`
payload). The NUI's `EngineConfig` expects `drainRate`. Both names are live.

**7. Every `.lua` file is sha256-snapshotted by a NUI test.**
`web/src/__tests__/bundleRebuildPreservation.test.ts` "Property 2" hashes every
`.lua` file under `client/`, `server/`, `shared/`, `config/`, plus `fxmanifest.lua`,
and compares against a stored baseline. **Any Lua edit fails `npm test` in `web/`
until the baseline is regenerated.** This is intentional — it was built to keep a
UI-only work stream from touching gameplay code — but it will surprise anyone
editing Lua who then runs the NUI suite.

**`.gitattributes` pins `*.lua text eol=lf`, and that line is load-bearing for this
guard.** The test hashes the *working tree*, not the committed blob. Git stores Lua
as LF, so under `core.autocrlf=true` (the Windows default) a checkout would
materialise CRLF and every hash would differ from the baseline — the guard would
pass only in the one working directory where the baseline happened to be generated,
and fail on every fresh clone. It did exactly that until 2026-08-19: a fresh
checkout of `d548217` mismatched on ~30 of 32 files, including files nothing had
ever edited. Pinning `eol=lf` makes checkout byte-identical to the blob on every
platform. **Removing that `.gitattributes` line silently breaks the guard for
everyone except whoever last regenerated the baseline.**

**8. Six CSS selectors must keep the literal string `#fff` in the built bundle.**
`web/src/__tests__/rigMenuBundleRebuild.exploration.test.ts` asserts against
`web/dist`'s minified CSS that `.rig-menu__title`, `.rig-menu__hint`,
`.rig-menu__empty`, `.rig-category-card__title`, `.rig-category-card__status`, and
`.rig-item-row__label` each contain both `text-shadow` and `#fff`. Tokenizing their
color to a CSS variable breaks a build-time assertion with no source-level hint why.

**9. `web/dist` is a committed build artifact.**
`fxmanifest.lua` declares `ui_page 'web/dist/index.html'`. Changing anything under
`web/src` has no in-game effect until `cd web && npm run build` is run and the
output is committed.

**10. Never write `transition: all` in the NUI CSS.**
The RAF loop writes tension and energy values every frame. A blanket transition on
those elements makes the displayed value visibly lag the engine.

**11. The weather name list is one shared table, in `shared/util.lua`.**
`ZUtil.WEATHER_TYPES` is what `client/main.lua` builds its `weatherByHash` lookup
from *and* what `server/weather.lua` whitelists an incoming report against. Two
copies would drift in the direction that fails silently: a server list narrower
than the client's drops honest reports and freezes the weather bonus at the
fallback with nothing in the log. Adding a weather name means adding it here, once.
`tests/security.test.lua` K4 walks the whole table through the real event handler.

Because it lives in `shared_scripts`, it also loads *before* `client_scripts` —
the two Lua water-validation suites now `dofile('shared/util.lua')` before
`client/main.lua` for that reason.

**12. Only the fish item's `AddItem` may decide a catch failed.**
`Rewards.GiveCatch`'s commit boundary (§4.5) is a rule spanning three files:
`rewards.lua` decides `committed`, `session.lua` reports it and gates the rate
counter on it, and `client/minigame.lua` renders the three outcome shapes.
Anything added after the commit point — a stat write, an achievement hook, a
webhook — belongs in a `runStage` call returning a boolean, never in the
pre-commit path and never as an early `return false`. Moving one of those above
the `AddItem` line, or letting one propagate a failure, silently re-creates the
bug this boundary exists to close: a player holding a fish while being told they
caught nothing. Groups N and O in `tests/security.test.lua` are the guard.

---

## 9. Behavioral notes that look like bugs but are not

- **`reelDurationMs` is sent but ignored.** The server times the fight itself. The
  client's number is not trusted and not used.
- **Bait is consumed at the bite, not at the catch.** Hit or miss, once the fish
  bites the bait is gone.
- **The bobber's position during a fight is driven by the NUI.** `reelEnergy`
  streams the fish's energy percentage back to Lua, which maps it to the bobber's
  distance from the player. This is cosmetic only — no gameplay value derives from
  it.
- **Weather is client-reported by default.** `client/main.lua` reports the current
  weather and hour every 60 seconds. `server/weather.lua` prefers a weathersync
  resource's exports and falls back to that report. This is low-trust by design; it
  only shifts spawn *bonuses*, never anything security-critical.
- **Boat anchoring is refcounted and broadcast to everyone.** Two players fishing
  from the same boat both hold a reference; the anchor releases only when the last
  one leaves. The sync event goes to `-1` (all clients) because boat state must
  agree across the session.
- **`BoatAnchor.Add` authorizes on four things, and 15m is one of them.** In
  order: the `netId` is a number and resolves to an existing entity; that entity
  is a vehicle (`GetEntityType == 2`) and a boat (`GetVehicleType == 'boat'` —
  both are server natives on the shipped artifact); the caller's ped is within
  **15m**; and the caller holds no *other* anchor. The type pair is hygiene
  rather than the security boundary — `SetBoatAnchor` on a car is inert
  client-side — but it keeps ped, object and car netIds out of the refcount table
  and out of the broadcast. The one-anchor rule is the real tightening: it caps a
  modified client at freezing one boat at a time, which is the same reach an
  honest client has (`client/main.lua` tracks a single `currentBoatNetId`).
  Residual, and accepted: two boats moored within 15m of each other are still
  interchangeable to a modified client, which can freeze *a* neighbouring boat —
  just not several, and not one across the map.
- **The 15m radius is not padding, and tightening it would break deck fishing.**
  The tempting argument is "the client only probes 3.5m
  (`GetClosestVehicle`), so 5–8m is plenty" — that reads one of
  `getFishingBoat()`'s three branches. The second is
  `GetVehiclePedIsIn(ped, true)`, the **last** vehicle, which matches at any
  distance: a player who was seated in a Tug or a Marquis, stood up and walked to
  the stern is 8–10m from the vehicle *origin*, and server-side
  `GetVehiclePedIsIn(ped, false)` returns `0` for them, so no seat check rescues
  that case either. This resource carries no boat-dimension data to pick a
  tighter number from, and the client attaches the ped to the deck whether or not
  the server accepts the anchor — a refusal strands a ped attached to a boat
  nobody froze. `tests/security.test.lua` H10 pins 10m as *allowed* so a future
  tightening trips a test instead of a player.
- **Boat anchoring is proximity-checked on `Add` but deliberately not on
  `Remove`.** `BoatAnchor.Remove`
  does not re-check distance or entity type, and that is not a lapsed guard.
  `players[src]`
  membership in a boat's anchor record is a capability only obtainable by
  already having passed every check in `Add`, so a remote `Remove` call can
  at most release the one reference the caller legitimately acquired — there is
  no capability to gate. Proximity-checking `Remove` too would instead strand a
  boat frozen forever the moment a player dies while fishing, respawns at a
  hospital kilometres away, and can never get back into range to release it —
  which would also block a co-angler's legitimate release, since the anchor is
  refcounted. Do not "tighten" `Remove` into a proximity or seat-occupancy
  check; it would break deck fishing after any respawn.
- **The rig menu opens only in equip standby.** After the line is in the water, `G`
  does nothing.

---

## 10. Known gaps, stale docs, and unverified claims

**Feature gaps carried from v1:**

- No true fish release. This is deferred to Phase 2, not a bug: the fish is
  granted at claim time, before the catch card is even shown, and the card's
  single "Continue" button (the `keep` NUI callback — see §3.4/§9) just closes
  it. There is no longer a Keep/Release choice in the UI for a player to be
  misled by; Task 7 removed the fake choice that used to make this look like an
  oversight.
- `simple-fishing` mode has no per-catch metadata: fish sell at species-average
  weight and 3★ quality, and rod assembly is disabled.
- `zfishing_players.stats` is written as `{}` and never read — a reserved hook.
- `zfishing_zones.enabled` is honored on load but has no UI.
- The minigame outcome is decided client-side and reported to the server, which
  only plausibility-checks it on timing (§3.1 `zfishing:claim`) — the server never
  simulates the fight itself. See
  `docs/superpowers/specs/2026-08-18-zfishing-minigame-authority-design.md` for
  the exploit this leaves open and the rewrite that would close it.

**Unverified:**

- End-to-end verification on a live FiveM server has not been run. The Lua side is
  covered by a small standalone harness (`tests/luarun.mjs` with
  `security.test.lua`, `water_validation.test.lua`,
  `water_validation_preservation.test.lua`); the NUI side by vitest +
  `@testing-library/react` + fast-check under `web/`. Neither exercises a real
  game client, a real inventory resource, or a real database.
  `docs/testing/zfishing-live-e2e-checklist.md` is the manual pass that has to be
  run on a real server before any of this is called production-verified.
- Suite sizes as of the 2026-08-19 identity-hardening pass: Lua **122 / 5 / 11**
  (`security`, `water_validation`, `water_validation_preservation`), `web/`
  **18 test files, 71 tests** (~7s, vitest 2.1.9; run it from `web/`, not the
  repo root — the jsdom environment comes from `web/`'s own config). The Lua count
  rose from 97: groups **Q** (source-id reuse on the catch path, 12 tests),
  **R** (source-id reuse on the sale path, 8) and **S** (one-warning-per-failure,
  5). Eight guards were mutation-tested individually — each was removed, the
  named test confirmed failing, and the guard restored before the next. The web run includes
  `bundleRebuildPreservation.test.ts`, so the Lua sha256 baseline described in §8
  invariant 7 currently *matches* the files on disk — the guard is live, not
  already broken.
- The rod-tip anchor offset in `client/anim.lua` (`TIP_OFFSET`) is documented as
  needing live tuning via a debug command that ships disabled.

**Phase 2, structurally ready:** daily challenges, weekly tournaments, and
leaderboards can be built as queries over `zfishing_catches` with no schema
migration.

---

## 11. Where to make common changes

| Goal | Touch |
|---|---|
| Add a fish species | `config/fish.lua` **and** reseed the `fish` domain (or add via the admin panel); register `fish_<species>` in the inventory |
| Add rare loot | `Config.RareLoot` in `config/main.lua` + inventory registration; reseed `settings` |
| Add an equipment tier | `config/equipment.lua` + inventory registration; reseed `equipment` |
| Add a fish behavior | `ConfigSchema.BEHAVIOR_TYPES`, `pullFor()` and `centerTargetFor()` in `minigameEngine.ts`, plus the constructor's amp/spd switch |
| Add a water type | `ConfigSchema.WATER_TYPES` and `Config.Admin.waterTypes` |
| Add a language | copy `locales/en.json` to `locales/<code>.json`, set `Config.Locale` |
| Change a HUD surface | `web/src/components/`, then `npm run build` in `web/` and commit `web/dist` |
| Add an admin-editable setting | `SETTING_KEYS` in `store.lua`, `ConfigSchema.Settings`, the `getConfig` payload in `admin.lua`, and a field in `web/src/admin/SettingsTab.tsx` |
| Add a new session validation | `server/session.lua` only — and add a matching `error_<reason>` locale key |

---

## 12. Change history

### The identity-hardening pass — 2026-08-19

Closes the **source-id reuse** class: a coroutine created for player A must never
mutate player B, even when B has since been given A's FiveM source id. No
previously shipped protection was changed — `sessionId`, the settling lock, claim
idempotency, the flood gates, the server-authoritative roll, the commit boundary
and the sale lock all still hold; this pass adds a second, orthogonal axis of
identity underneath them.

This was **defensive** work. Source-id reuse was reachable by reading the code, not
by an observed exploit, and the tests demonstrate the guards — not that anyone had
been through the window.

| Change | Where |
|---|---|
| `identifier` captured on the session at cast, alongside `sessionId`; cast fails closed without one | `server/session.lua` |
| `Progression.IdentityState(src, expected)` → `same` / `gone` / `changed` — the single catch-side comparison | `server/progression.lua` |
| `GiveCatch(src, fish, zone, ctx)`: identity gate above `AddItem`, per-stage guard on XP and rare loot | `server/rewards.lua` |
| Catch log writes the **captured** identifier instead of re-reading `Progression.Get(src)` | `server/rewards.lua` |
| Sale captures identity and re-checks it before the sweep, before each removal, before payout, before compensation | `server/rewards.lua` |
| `session.lua`'s own post-yield `reset(src)` + rate increment guarded on `sessions[src] == s` | `server/session.lua` |
| Duplicate settlement warning removed: `runStage` records, `session.lua` logs, one record per failure | `server/rewards.lua`, `server/session.lua` |
| `ZUtil.SafeId` — redacted identifier for console lines | `shared/util.lua` |
| `error_no_identity` | `locales/en.json`, `locales/th.json` |

**Deliberate non-changes.** The minigame stays client-authoritative (a separate
architectural project — §10). No DB economy ledger: mid-sale identity loss is
reconciled from the console, as a failed payout already was. `Progression.Save()`
stays fire-and-forget for its existing callers.

**Live E2E: still NOT VERIFIED.** Nothing in this pass was run inside FiveM.

### The final hardening pass — 2026-08-19

The last correctness pass before live E2E. Three themes: what "a catch happened"
means, what a player is told when it did not, and what an admin can reconstruct
afterwards. Scope was deliberately closed after this — no minigame authority work,
no Phase 2 features.

**Partial settlement was reportable as no catch.** `Rewards.GiveCatch` returned a
boolean and `session.lua` wrapped the whole thing in one `pcall`, so "the fish
never reached the inventory" and "the fish is in the bag but the XP write failed"
produced the same answer to the player. §4.5 is the fix: the fish item's `AddItem`
is an explicit commit point, secondary effects run as guarded stages, and a stage
failure becomes a console warning rather than a client-visible failure.

**Persistence was unverifiable.** `Progression.Save()` fires `MySQL.update`
without awaiting and returns nothing; the catch log used `MySQL.insert` the same
way. `pcall` around them proved only that the calls were dispatched.
`Progression.SaveAwait()` was added for the settlement path alone — `Save()` keeps
its old behaviour for the callers that never read a result.

**`Config.RateLimit` was charging for catches that never happened.** The counter
incremented before `given` was checked, so an `inv_full` claim spent one of the
player's successful catches for that minute.

**Every claim failure said "the fish escaped".** `client/minigame.lua` had one
`else` arm for `ok == false`. Failures now map through `CLAIM_ERRORS` (§3.1) with
four new locale keys, and a `web/` test asserts every mapped key exists in both
locale files — the guard against re-shipping the unreachable key the previous pass
had to delete.

**A failed sale was hard to reconcile.** Each sale attempt now carries a
server-side `saleId`, `restoreSale` reports what it restored and what it could
not, and an uncompensated failure logs one `CRITICAL` line per lost stack with
everything needed to make the player whole (§4.4).

**Tests.** `tests/security.test.lua` 81 → 97 (groups N, O, P — the commit
boundary over the real settlement stack, claim integration including rate
accounting, and sale reconciliation logging), plus
`web/src/__tests__/claimErrorLocales.test.ts`. Mutation-checked: removing the
commit boundary fails N3–N6, restoring the unconditional rate increment fails O2,
dropping the CRITICAL line fails P2, warning on a missing progression cache fails
N7, and mapping claim errors back to `fish_escaped` fails the whole `web/` locale
file.

**Still not verified on a live server.** See §10 — that is the next step, not more
architecture.

### The runtime-hardening pass — 2026-08-19

A second pass over the same surface, on request. It closed the money path, gated
the remaining cheap events, tightened boat anchoring where tightening was actually
safe, and made the settlement lifecycle explicit. It deliberately did **not** touch
the minigame authority gap (below), add caches, or re-tune the zone-distance math.

**Selling could pay for fish it did not sell — the other way round.** Two things
were wrong and one thing was already right. Already right: price was only ever
accumulated inside a successful removal, in both modes, so the "removed failed but
paid anyway" shape never existed (`server/rewards.lua`). Wrong: `Zfishing.AddMoney`
returned a boolean that was discarded, so a refused payout removed every fish, paid
nothing, and still answered `ok`. Also wrong: nothing serialised two overlapping
`sellAll` calls, and every step of a sale yields. Both are fixed under §4.4 — a
per-player `selling` lock released on all five exit paths, a `sell` flood gate, and
a restore-on-failed-payout that hands back item, count and metadata.

**The last ungated client events.** `store:request`, `reportWeather` and
`anchorBoat` now sit behind `ZUtil.MakeRateGate` (§3.2). `unanchorBoat` stays
ungated on purpose, for the same reason `cancel` does. `reportWeather` also gained
validation: it is the only client-supplied value the server keeps, and
`math.floor(hour) % 24` on an infinite input used to store `-nan` as the hour.

**Boat anchoring, part two.** `Add` now also requires a real vehicle, a boat, and
that the caller holds no other anchor; the 15m radius was evaluated for reduction
to 5–8m and deliberately **kept**, because `getFishingBoat()`'s last-vehicle branch
matches at any distance and the client attaches the ped regardless of the server's
answer. §9 carries the full reasoning and H10 pins 10m as allowed so a future
tightening trips a test.

**Settlement lifecycle.** `cancel` no longer frees a session in `settling` — it
answers `ok` so the client tears down, and the reward path keeps the slot until it
finishes (§2). That removed the only escape from a stuck `settling`, so the reward
call is now wrapped in `pcall` and always resets, answering `settle_failed`.

**Cleanup.** `server/rig.lua`'s gate never dropped its per-src buckets; it and the
two new gates now clear on `playerDropped`, alongside the `selling` lock.

**Tests.** `tests/security.test.lua` grew from 52 to 81: group H gained the entity
type / boat type / one-anchor / refcount / disconnect cases and the 10m allowance
pin, plus new groups I (selling: races driven as coroutines, partial removal
failure, failed payout with the fish asserted back in the bag, lock release after
both a failure and a raised error, the flood gate, simple mode), J (cancel in every
state, cancel during settling, replayed claim after that cancel, a raised
settlement), K (weather validation and gating, the full `ZUtil.WEATHER_TYPES`
round trip, `store:request` gating) and L (the anchor gate through the real net
event — every group H test calls `BoatAnchor.Add` directly and would miss it —
plus proof that `unanchorBoat` is *not* gated). Each new guard was
mutation-checked: the guard was reverted one at a time and the intended test
failed each time.

One harness trap worth knowing before adding more: `installHost` records event
handlers in a map keyed by name, so the last `AddEventHandler('playerDropped', …)`
wins. Under `loadSession` that is session.lua's (rig.lua is `dofile`'d first and
its handler is discarded), which is why the rig-gate cleanup test D4b goes through
`loadRig` instead.

**Still not verified on a live server.** See §10.

### The security-hardening pass — 2026-08-19

Prompted by an external review document that listed 20 issues. Most of that document
turned out to be a re-labelling of §8/§9/§10 of *this* file; its five P0 security
findings were real, it missed the most exploitable bug in the resource, and its
headline recommendation would not have worked. What follows is what actually
changed and why, so a reader who knew the 1.0.0 shape can find their footing.

**Test harness first.** The Lua suite was red on a clean checkout — 20 of 33 passing
— for reasons unrelated to any product defect. `tests/security.test.lua` loaded
`server/validate.lua` without `server/config_schema.lua`, so `validate.lua`'s
nil-guard fallback stub installed and every `Validate.*` call hit a nil field; the
same shape applied to `server/rig.lua` and `shared/rig_rules.lua`. The two
water-validation suites were red too, missing `GetVehiclePedIsIn` /
`GetClosestVehicle` stubs that `getFishingBoat()` needs. All three suites are now
green (52 / 5 / 11), which is what makes the rest of this list verifiable.

One stale assertion was corrected rather than preserved: `D2` asserted
`zfishing:rig:attach` returns `occupied` for a filled socket. That code has never
existed — attach implements swap-on-occupied by design (§3.1).

**Session identity and the reward path.** Every transition now carries a nonce.
`cast` mints a `sessionId` and returns it; `hook`, `claim` and `cancel` take it as
their first argument and refuse a mismatch with `invalid_session` before touching
state. The token is *not* a secret — a modified client can read its own — so it buys
stale-request and replay rejection and a correlation id for the settle log, nothing
more.

The claim reward path is now idempotent. Previously `claim` validated
`state == 'reeling'`, called `Rewards.GiveCatch`, and only cleared the session
afterwards — but `GiveCatch` does `AddItem` → `Progression.Save` → `MySQL.insert`,
and across any of those yields a replayed claim passed the same guard and was paid
again. The session moves to `settling` **before** `GiveCatch` is called; that
placement is the entire fix, and §2 documents the state.

**Request cost.** `Config.RateLimit` counts only *successful catches*, so cast spam
was free while costing the server a `Generator.Roll` plus a full inventory sweep per
request. `ZUtil.MakeRateGate` (`shared/util.lua`) now gates `cast`/`hook`/`claim`
and the three rig callbacks ahead of any validation. The two limiters are unrelated
and both are live — see §3.1.

**Commands.** `/zfish_xp` granted 50 XP to any caller and `/zfish_roll` exposed the
generator, neither with a permission check, so any player could level into every rod
tier. Both now use the `zfishing.admin` ACE gate that `/zfishreload` already used.

**Boat anchoring — the bug the external review missed.** `zfishing:server:anchorBoat`
accepted an arbitrary `netId`, validating only `netId ~= 0`, then broadcast to `-1`
so every client froze that entity. Any modified client could freeze any boat on the
server from anywhere on the map. The review filed boat anchoring as a P2 "migrate to
Entity StateBag" performance note, which would not have fixed it — the defect was
missing ownership validation, not transport. `Add` now requires the player within
15m; `Remove` deliberately does not (§9 explains why).

**Duplicated constants.** §8 invariants 1 and 2 are resolved: the base drain and the
reel timeout now ship in the bite payload from `Config.Minigame.baseDrain` and
`Config.Timings.reelTimeout`. The claim floor also dropped a `1.7` reel-drain
fallback that contradicted the `1.0` the payload told the client — the effective
threshold had been roughly 35% of the true minimum reel time, and is now 90%.

**UI.** Keep/Release collapsed to a single Continue button. Both had always called
the same teardown; the fish is granted at claim time, before the card renders. A
true release is Phase 2 work.

**What did NOT change, and matters most.** The minigame outcome is still decided by
the NUI. The server checks timing plausibility, not the fight. Tightening the
envelope removed free headroom; it did not move authority. The design for the fix —
a fixed-timestep contract where the server integrates and scores — is specified in
`docs/superpowers/specs/2026-08-18-zfishing-minigame-authority-design.md`, including
why the obvious approach (server-issued seed, client replay) does not work: the
engine integrates on client-supplied `dt`, demonstrated by an identical input
timeline yielding `success` at one `dt` and `snap` at another.

Live end-to-end verification on a real FiveM server still has not been run — see §10.

