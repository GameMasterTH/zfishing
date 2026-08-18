# zfishing

Skill-based fishing for FiveM: hold-to-cast, hook QTE, tension reeling minigame,
fish quality/weight metadata, XP progression, weather/time bonuses, rare loot,
and a sell NPC. Server-authoritative — every fish is rolled server-side and every
client transition is validated.

## Requirements

| Resource | Required | Notes |
|---|---|---|
| [ox_lib](https://github.com/overextended/ox_lib) | yes | callbacks, notify, textUI, locale |
| `zcore_lib` | yes | ships alongside this resource (framework bridge) |
| [oxmysql](https://github.com/overextended/oxmysql) | yes | XP + catch log persistence |
| [ox_inventory](https://github.com/overextended/ox_inventory) | recommended | per-fish weight/quality metadata + metadata-priced selling |
| ox_target | optional | sell NPC targeting; falls back to `[E]` proximity |
| qb-weathersync / Renewed-Weathersync | optional | authoritative weather for spawn bonuses; falls back to client-reported |

Frameworks: **ESX**, **QBCore**, **QBox**. The framework/inventory adapter and the
feature mode (`enhanced-rig` vs `simple-fishing`) are selected ahead of time and
pinned in the runtime profile that the Site Agent commits into `zcore_lib` — never
auto-detected or silently downgraded at runtime.

> **Standalone (ไม่ใช้ zpm)?** `zcore_lib/shared/runtime_profile.lua` เป็น
> **operator-owned config** — เมื่ออัปเดต `zcore_lib` ด้วยการก๊อปโฟลเดอร์ทับ **ห้ามทับ**
> ไฟล์นี้ (ไม่งั้น fishing จะถูก block ทั้งหมด) และดูวิธี retarget framework/inventory ได้ที่
> `zcore_lib/README.md` → **Operator Note**

## Install

1. Apply the database schema — see **Database** below — then add to `server.cfg`
   **in this order** (after your framework + oxmysql):
   ```cfg
   ensure ox_lib
   ensure zcore_lib
   ensure zfishing
   ```
2. Register the items below in your inventory.
3. (Optional) Rebuild the UI after changing `web/src`: `cd web && npm install && npm run build`.

### Database

The resource does **not** create or alter schema. Apply
`migrations/mysql/001_schema.up.sql` with your usual migration tooling before
starting the resource for the first time; `migrations/checks/001_schema.verify.sql`
confirms the result. `migrations/mysql/001_schema.down.sql` reverses it.

On first boot the static files in `config/` are seeded into the database. After
that **the database is the source of truth** — editing `config/fish.lua` and
restarting will not change anything. Use the admin panel, or reseed.

### Admin access

The zone tool + admin panel use `zcore_lib:IsAdmin`, a shared zero-config policy
across the ZCore ecosystem. It accepts, in order:

1. **Server console** (`src == 0`).
2. **An optional resource ACE** (`zfishing.admin`) when a server wants a dedicated,
   least-privilege fishing administrator.
3. **Common server-admin ACEs** — `zcore.admin`, `command`, `admin`, or `god`.
   Standard QBCore/txAdmin installations already grant `command` to `group.admin`,
   so their existing admins work without adding another permission line.
4. **Framework admins** — ESX group `admin`/`superadmin`, or QBCore permission
   `admin`/`god`.

Most servers need no extra setup. For a fishing-only administrator who must not
receive normal server-admin permissions, the dedicated ACE remains available:

```cfg
add_ace identifier.fivem:123456 zfishing.admin allow
```

The common ecosystem policy is configurable once in
`zcore_lib/shared/config.lua` through `ZLib.AdminAces`; individual ZCore resources
do not need duplicate `server.cfg` grants.

## Admin tools

Config is **DB-backed**: on first start (once the schema is applied — see
**Database** above) `config/*.lua` is copied into the DB as seed defaults. After
that the DB is the source of truth — edit it live with these tools (all gated by
`isAdmin` — see **Admin access** above):

| Command | What it does |
|---|---|
| `/zfishadmin` | Opens the admin panel (Settings / Zones / Fish / Equipment tabs) |
| `/zfishzone` | Zone placement tool — noclip up, aim the camera at the water, **scroll** = radius, **G** = water type, **click/Enter** = place, **BACKSPACE** = cancel |
| `/zfishreload` | Re-pull config from the DB (after editing rows directly) |

**Live vs restart:** zones, fish, equipment, timings, rate limit, cast distance, and
rare loot all take effect immediately. `Config.SellNpcs` is spawned in a boot thread —
changing it needs a resource restart, and it is **not** in the admin panel.

**Require zone to fish:** on (default) — rods only work inside a placed zone. Toggle
it off in the panel (or set `RequireZone` in `config/main.lua`) to let rods work
anywhere near water; the "Open water fallback pool" (`DefaultWater`) setting decides
which species pool applies outside every zone.

**Reset to defaults:** each panel tab (or a table truncate) restores that domain's static
seed values. The `_seeded_*` rows in `zfishing_settings` mark which domains were seeded;
deleting one and reloading reseeds only that domain.

**Panel layout:** left sidebar picks the section (Settings / Fishing Zones / Fish /
Equipment). Fields are edited freely; a save bar appears at the bottom the moment
anything changes ("N unsaved changes · Save all / Discard") and only the changed
entries are written. Switching tabs or closing with unsaved edits asks first.
Destructive actions (delete / reset) confirm through an in-panel dialog.

## Language / Locale

All text — in-game notifications, the fishing HUD, and the whole admin panel — comes
from `locales/<lang>.json`. Pick the language in `config/main.lua`:

```lua
Config.Locale = 'th'    -- Thai everywhere (HUD, admin panel, notifications)
Config.Locale = false   -- follow the server-wide ox:locale convar instead
```

Default is `'th'`. `en.json` is the base; the active language overlays it, so any
key missing from a translation falls back to English instead of breaking. To add a
language, copy `locales/en.json` to `locales/<code>.json` and translate — the NUI
picks it up on resource restart, nothing else to edit. The UI ships with a bundled
Thai-capable font (Noto Sans Thai), so no client-side font install is needed.

## Item definitions

### ox_inventory (`ox_inventory/data/items.lua`)

Rods are **usable items** — fishing starts by using one, not a proximity keybind.
Each rod needs `client = { export = 'zfishing.useRod' }` so ox_inventory calls the
resource's client export directly on use. `consume = 0` stops ox_inventory from
eating the rod when the `export` fires on use.

The rod-assembly menu opens with the **G** keybind in-game (see **Assembling a
rod** below), not an inventory right-click entry — rod items don't need a
`buttons` table.

```lua
-- rods (usable — starts fishing; assembly menu opens with the G keybind)
['fishing_rod_common']    = { label = 'Bamboo Rod',   weight = 1000, stack = false, close = true, consume = 0, client = { export = 'zfishing.useRod' } },
['fishing_rod_rare']      = { label = 'Carbon Rod',   weight = 900,  stack = false, close = true, consume = 0, client = { export = 'zfishing.useRod' } },
['fishing_rod_epic']      = { label = 'Graphite Rod', weight = 800,  stack = false, close = true, consume = 0, client = { export = 'zfishing.useRod' } },
['fishing_rod_legendary'] = { label = 'Master Rod',   weight = 700,  stack = false, close = true, consume = 0, client = { export = 'zfishing.useRod' } },
-- reels / lines / hooks / floats
['reel_cheap']    = { label = 'Cheap Reel',    weight = 300, stack = false, close = true },
['reel_carbon']   = { label = 'Carbon Reel',   weight = 250, stack = false, close = true },
['reel_electric'] = { label = 'Electric Reel', weight = 350, stack = false, close = true },
['line_10'] = { label = '10lb Line', weight = 50, stack = true, close = true },
['line_20'] = { label = '20lb Line', weight = 50, stack = true, close = true },
['line_40'] = { label = '40lb Line', weight = 60, stack = true, close = true },
['line_60'] = { label = '60lb Line', weight = 70, stack = true, close = true },
['hook_2'] = { label = 'Size 2 Hook', weight = 5, stack = true, close = true },
['hook_4'] = { label = 'Size 4 Hook', weight = 5, stack = true, close = true },
['hook_6'] = { label = 'Size 6 Hook', weight = 5, stack = true, close = true },
['hook_8'] = { label = 'Size 8 Hook', weight = 5, stack = true, close = true },
['float_wood']  = { label = 'Wood Float',  weight = 20, stack = true, close = true },
['float_foam']  = { label = 'Foam Float',  weight = 15, stack = true, close = true },
['float_smart'] = { label = 'Smart Float', weight = 30, stack = true, close = true },
-- baits (consumed when a fish bites)
['worm']          = { label = 'Worm',          weight = 10, stack = true, close = true },
['minnow']        = { label = 'Minnow',        weight = 15, stack = true, close = true },
['shrimp']        = { label = 'Shrimp',        weight = 15, stack = true, close = true },
['insect']        = { label = 'Insect',        weight = 5,  stack = true, close = true },
['chicken_liver'] = { label = 'Chicken Liver', weight = 20, stack = true, close = true },
['spinner']       = { label = 'Spinner',       weight = 25, stack = true, close = true },
['jig']           = { label = 'Jig',           weight = 25, stack = true, close = true },
['crankbait']     = { label = 'Crankbait',     weight = 30, stack = true, close = true },
['topwater']      = { label = 'Topwater',      weight = 30, stack = true, close = true },
-- fish (stack = false so per-fish weight/quality metadata is preserved)
['fish_bass']      = { label = 'Bass',        weight = 500,  stack = false, close = true },
['fish_trout']     = { label = 'Trout',       weight = 500,  stack = false, close = true },
['fish_catfish']   = { label = 'Catfish',     weight = 1500, stack = false, close = true },
['fish_salmon']    = { label = 'Salmon',      weight = 1000, stack = false, close = true },
['fish_pike']      = { label = 'Pike',        weight = 1000, stack = false, close = true },
['fish_mackerel']  = { label = 'Mackerel',    weight = 400,  stack = false, close = true },
['fish_tuna']      = { label = 'Tuna',        weight = 5000, stack = false, close = true },
['fish_swordfish'] = { label = 'Swordfish',   weight = 8000, stack = false, close = true },
['fish_shark']     = { label = 'Shark',       weight = 9000, stack = false, close = true },
['fish_golden']    = { label = 'Golden Fish', weight = 200,  stack = false, close = true },
-- rare loot
['old_boot']       = { label = 'Old Boot',            weight = 800, stack = true, close = true },
['bottle_message'] = { label = 'Message in a Bottle', weight = 300, stack = true, close = true },
['treasure_map']   = { label = 'Treasure Map',        weight = 50,  stack = true, close = true },
['treasure_chest'] = { label = 'Treasure Chest',      weight = 2000, stack = true, close = true },
['pearl']          = { label = 'Pearl',               weight = 20,  stack = true, close = true },
['ancient_coin']   = { label = 'Ancient Coin',        weight = 30,  stack = true, close = true },
['diamond']        = { label = 'Diamond',             weight = 10,  stack = true, close = true },
```

### QBCore fallback (`qb-core/shared/items.lua`)

Same names — copy the pattern:

Rods use `useable = true` — `zcore_lib:RegisterUsableItem` wires the QBCore
`CreateUseableItem` hook automatically at boot, no extra code needed here.

```lua
['fishing_rod_common'] = { name = 'fishing_rod_common', label = 'Bamboo Rod', weight = 1000, type = 'item', image = 'fishing_rod.png', unique = true, useable = true, shouldClose = true, description = 'A simple fishing rod' },
['worm']               = { name = 'worm', label = 'Worm', weight = 10, type = 'item', image = 'worm.png', unique = false, useable = false, shouldClose = true, description = 'Fishing bait' },
['fish_bass']          = { name = 'fish_bass', label = 'Bass', weight = 500, type = 'item', image = 'fish_bass.png', unique = true, useable = false, shouldClose = true, description = 'A freshly caught bass' },
-- ...repeat for every item listed above; only rods need useable = true
```

### ESX fallback

```sql
INSERT INTO items (name, label, weight) VALUES
  ('fishing_rod_common', 'Bamboo Rod', 1), ('fishing_rod_rare', 'Carbon Rod', 1),
  ('fishing_rod_epic', 'Graphite Rod', 1), ('fishing_rod_legendary', 'Master Rod', 1),
  ('reel_cheap', 'Cheap Reel', 1), ('reel_carbon', 'Carbon Reel', 1), ('reel_electric', 'Electric Reel', 1),
  ('line_10', '10lb Line', 1), ('line_20', '20lb Line', 1), ('line_40', '40lb Line', 1), ('line_60', '60lb Line', 1),
  ('hook_2', 'Size 2 Hook', 1), ('hook_4', 'Size 4 Hook', 1), ('hook_6', 'Size 6 Hook', 1), ('hook_8', 'Size 8 Hook', 1),
  ('float_wood', 'Wood Float', 1), ('float_foam', 'Foam Float', 1), ('float_smart', 'Smart Float', 1),
  ('worm', 'Worm', 1), ('minnow', 'Minnow', 1), ('shrimp', 'Shrimp', 1), ('insect', 'Insect', 1),
  ('chicken_liver', 'Chicken Liver', 1), ('spinner', 'Spinner', 1), ('jig', 'Jig', 1),
  ('crankbait', 'Crankbait', 1), ('topwater', 'Topwater', 1),
  ('fish_bass', 'Bass', 1), ('fish_trout', 'Trout', 1), ('fish_catfish', 'Catfish', 1),
  ('fish_salmon', 'Salmon', 1), ('fish_pike', 'Pike', 1), ('fish_mackerel', 'Mackerel', 1),
  ('fish_tuna', 'Tuna', 1), ('fish_swordfish', 'Swordfish', 1), ('fish_shark', 'Shark', 1),
  ('fish_golden', 'Golden Fish', 1),
  ('old_boot', 'Old Boot', 1), ('bottle_message', 'Message in a Bottle', 1),
  ('treasure_map', 'Treasure Map', 1), ('treasure_chest', 'Treasure Chest', 1),
  ('pearl', 'Pearl', 1), ('ancient_coin', 'Ancient Coin', 1), ('diamond', 'Diamond', 1);
```

## Item images

- **ox_inventory** — drop a PNG named after the item into `ox_inventory/web/images/`.
  No config needed; the inventory matches by filename:
  `fishing_rod_common.png`, `worm.png`, `fish_bass.png`, `old_boot.png`, …
  (one image per item name listed above).
- **qb-inventory** — set `image = '<name>.png'` on each item in
  `qb-core/shared/items.lua` and put the file in `qb-inventory/html/images/`.
- **Per-fish override (ox only):** fish carry metadata, so `Rewards.GiveCatch`
  can set `meta.image` to swap the picture per catch (e.g. a golden variant for
  5★ fish). Not enabled by default.

## Adding more rare loot

`Config.RareLoot` in `config/main.lua` is the whole system — each catch rolls
every entry independently. To add loot:

1. Add a line: `{ item = 'my_item', chance = 0.01, label = 'My Item' }`.
2. Register `my_item` in your inventory (plus an image, see above).

`chance` is per-catch probability (0.01 = 1%).

## Rod assembly & durability

Fishing needs a **fully assembled rod**: a reel, line, hook and float must be
fitted onto the rod item before it can cast (`Config.RequireAssembly`, default
on — toggle in the admin panel to fall back to the old "best gear you carry"
behavior).

- **Assembling a rod:** equip a fishing rod and press **G** while in equip
  standby (before you cast) to open the rig menu — the only entry point.
  The keybind is registered as `zfishing_rig` and can be rebound in
  **Settings → Key Bindings → FiveM**. Once the line is in the water the menu
  is closed and `G` does nothing. The menu shows every socket, what's fitted,
  its condition, and lets you fit spare parts from your bags or detach fitted
  ones (detached parts keep their remaining durability).
- **Tradeable:** the components live inside the rod item's metadata — selling
  or giving the rod hands over the whole assembled kit. The rod tooltip lists
  what's fitted and each part's condition.
- **Durability:** every cast wears the rod and each fitted part by its
  `degrade` value (per-item, Equipment tab). When a part hits 0 it **breaks and
  disappears** — you're told which one, the rod survives, fit a spare to keep
  fishing. Snapping the line in the reel minigame destroys the fitted line too.
- **Rod breaking** (`RodCanBreak`, default off): when enabled, a rod that hits
  0 durability is destroyed **together with everything fitted on it**.
- **Admin knobs:** `Durability` (master wear toggle), `RodCanBreak`,
  `RequireAssembly` in Settings; per-item `durability` (max) and `degrade`
  (wear per cast) in the Equipment tab. All live — no restart.

**Inventory support:** rod assembly is the `enhanced-rig` feature mode and needs
per-item metadata — **ox_inventory** and **qb-inventory** provide it (any framework:
ESX/QBCore/QBox — it's the *inventory* resource that matters). The resolver pins the
mode up front: when the pinned profile is `simple-fishing` (e.g. plain ESX native),
assembly is explicitly disabled — the rig menu (G) has no rod slot to show —
and fishing uses the best gear you carry instead; there is no runtime probe and
no silent metadata drop. zfishing never touches an inventory directly; every
call goes through `zcore_lib`'s pinned runtime contract.

## How it plays

1. **Use a fishing rod** from your inventory. The rod must be fully assembled
   (see **Rod assembly & durability**), and by default this only starts fishing
   if you're near water **and** standing inside a configured `Config.Zones` entry
   (admins can turn this off in the panel — see **Require zone to fish** below).
   - Rod not assembled → "Your rod isn't fully assembled"
   - Not near water → "You need to be near water"
   - Near water but outside every zone (with zones required) → "No catchable fish in this area"
2. Hold **E** to charge the cast, release to throw. Longer hold = further cast.
   A thin line runs from your rod tip to a bobber floating on the water at the
   cast point (`prop_fishing_float_01` if your build has it, otherwise a small
   red marker).
3. Wait for the bite (bait is consumed at the bite, hit or miss).
4. **BIG BITE!** → the bobber dives underwater and stays down for the whole
   fight — press **SPACE** inside the hook window (shorter for rarer fish).
5. Reel: hold/release **SPACE** to keep tension in the green zone. Over-tension too
   long and the line snaps — a heavier line vs. fish weight gives more slack.
6. Catch card shows species / weight / quality (1–5★). Sell at the dock NPC —
   price = base × weight × quality multiplier.

While fishing your character is **locked in place** (camera still free to look
around) — controlled by `Config.FreezeWhileFishing` (default `true`; set to
`false` to let players walk around while fishing, old behavior). Press **X**
to cancel at any point, including mid-reel — it's the only way out while
locked, and it's rebindable in FiveM's Settings > Key Bindings > "Cancel
fishing". Use `/zfishzone` to place zones — without at least one zone, rods
can't be used anywhere.

QA commands (admin-only): `/zfish_roll [water]` samples a server roll, `/zfish_xp`
grants 50 XP.

## Anti-cheat model

- Fish species/weight/quality/bite-time are rolled **server-side at cast**; the
  client never sees them until a validated claim.
- The zone (and its water type / species pool) is resolved server-side from the
  player's **actual position** — the client's zone check is a UX gate only, never
  trusted for the roll itself.
- Every callback (`cast`/`hook`/`claim`) re-checks session state, inventory,
  hook-window timing, and minimum plausible reel duration.
- Every cast mints a random per-session `sessionId`; `hook`, `claim`, and
  `cancel` all require it and refuse a mismatch with `invalid_session` before
  touching any state. This is stale-request and replay protection, **not**
  secrecy — a modified client can read its own token back.
- A claim locks the session in a `settling` state **before** the reward is
  granted, so a claim replayed while the inventory/DB write is still in
  flight is refused instead of paid out twice.
- A per-action flood gate sits in front of `cast`/`hook`/`claim` and the rig
  callbacks, rejecting a burst of requests before any inventory sweep or fish
  roll runs. This is separate from `Config.RateLimit` below — that one throttles
  the catch *economy* (successful catches only); the flood gate throttles raw
  request rate regardless of outcome.
- The claim's minimum-reel-time floor uses the exact drain rate the server told
  the client in the bite payload, not an assumed constant.
- Successful catches are rate-limited (`Config.RateLimit` per minute).
- `/zfish_xp` and `/zfish_roll` require the same admin ACE as `/zfishreload` —
  no player can self-grant XP or sample rolls.
- Anchoring a boat requires the player be within 15m of it, with the netId
  type-checked — a forged event can't freeze an arbitrary vehicle from across
  the map.
- Weather/time input is low-trust by design — it only shifts spawn *bonuses*.

Full session-state and callback contract: see `docs/ARCHITECTURE.md` §§2–3.

## v1 limitations (remaining)

- **No true release yet** — the catch card has a single **Continue** button;
  the fish is granted server-side at claim time, before the card renders. A
  true release — removing the granted item in exchange for something (XP,
  conservation reputation) — is deferred to Phase 2.
- **Simple-fishing mode has no per-catch metadata** — when the resolver pins
  `simple-fishing` (e.g. plain ESX native), fish are plain items sold at
  species-average weight / 3★ quality and rod assembly is explicitly disabled
  (see **Rod assembly & durability**). This is decided up front by the pinned
  mode, not a silent runtime downgrade.
- **The reel minigame decides its own outcome** — it runs entirely in the NUI,
  which reports success or failure; the server measures the reel time itself
  and checks it against a physical minimum for the fish rolled, not the
  outcome itself (see **Anti-cheat model** above). See
  `docs/superpowers/specs/2026-08-18-zfishing-minigame-authority-design.md` for
  the rewrite that would close this.

Implemented since v1: per-hook mechanics, reel drain speed, float bite speed,
and full component durability — all wired through the assembled rod.

## Phase 2 (structure already in place)

Daily challenges, weekly tournaments, and leaderboards can be built directly on
the `zfishing_catches` log — no schema migration needed.
