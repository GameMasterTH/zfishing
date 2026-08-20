# zfishing — live end-to-end checklist

**Why this file exists.** Everything in `zfishing` is covered by two automated
suites that run without a game: the Lua harness (`tests/luarun.mjs`) and the NUI
vitest suite under `web/`. Neither one starts FiveM, talks to a real inventory
resource, or writes to a real database. Nothing in this resource has been verified
against a running server. Until every row below is filled in on a real server,
**zfishing is not production-verified** — say "tests pass", not "it works".

## How to run it

- One tester can do everything except the rows marked **2 players**.
- Server console visible throughout: several rows are only observable there.
- Have an admin account (`zfishing.admin` or any ACE in **Admin access**) for the
  `/zfish*` rows.
- Note the pinned mode first (`enhanced-rig` or `simple-fishing`) — it is printed
  at boot by `server/lib.lua` and changes what several rows expect.

Mode under test: `________________`  ·  Server build: `________________`  ·
Date: `________________`  ·  Tester: `________________`

**Status: NOT VERIFIED.** No row below has been executed on a real server. This
file is the release-candidate gate: `zfishing` cannot be called READY FOR
PRODUCTION until it is filled in and signed off. Automated suites passing is not
evidence for any row here.

**Marking rules.** `Pass` means you performed the steps and observed the expected
result. `Fail` means you observed something else — write what. `N/A` means the row
cannot be executed here and needs a stated reason (no second player, no modified
client, no way to force a DB failure). **Never mark a row Pass that you did not
run**, and never infer one row from another.

### Coverage map

| Area | Sections |
|---|---|
| Core fishing (catch, miss hook, escape, snap, timeout, inventory full) | B, C |
| Session security (stale/replayed claim, cancel while settling, disconnects) | D, G |
| Sales (normal, double-click, payout + compensation failures, disconnect) | E |
| Boats | F |
| Persistence (XP, catch row, restart, DB failure) | I |
| Runtime compatibility | J |
| Performance | K |

---

## A. Boot and mode

| # | Steps | Expected | Pass/Fail | Notes |
|---|---|---|---|---|
| A1 | Start the server with `zcore_lib` running | Console prints `[zfishing] runtime mode = <mode> (<framework> + <inventory>)` and **no** DDL/schema line | | |
| A2 | Start the server with `zcore_lib` **stopped** | Console prints `runtime profile unavailable ... fishing disabled`; using a rod notifies "unavailable", nothing crashes | | |
| A3 | Join the server, watch the console for 30s | Exactly one `zfishing:store:sync` per client; no repeated sync spam | | |
| A4 | Make `zcore_lib` return a valid profile but **no identifier** for your account (break the framework's identifier lookup), then use a rod and cast | Cast is refused with *"Your player identity could not be verified — rejoin and try again"* (`error_no_identity`) — the message renders, not the raw key. No session starts, nothing in the console crashes. If the framework cannot be made to answer without an identifier, mark **N/A** with that reason | | |

## B. The happy path

| # | Steps | Expected | Pass/Fail | Notes |
|---|---|---|---|---|
| B1 | Use a rod near water inside a zone, press **E**, cast, wait, press **SPACE** on the bite, reel to a catch | Catch card shows species / weight / quality; the fish is in the inventory; console logs `claim settled session=... reward=true` | | |
| B2 | Press **Continue** on the catch card | Card closes, NUI focus released, rod animation stops, player unfrozen — one clean teardown | | |
| B3 | (enhanced mode) Inspect the caught fish item | Metadata carries the same weight/quality the card showed | | |
| B4 | (simple mode) Inspect the caught fish item | Plain stacked item, no per-catch metadata; no error in console | | |
| B5 | Repeat B1 until `Config.RateLimit` successful catches inside one minute, then cast again | Refused with the `error_rate` message; a cast in the next minute works again | | |

## C. Losing the fish

| # | Steps | Expected | Pass/Fail | Notes |
|---|---|---|---|---|
| C1 | Cast, then **never press SPACE** on the bite | Session ends by itself, bait consumed, player can cast again with no stuck state | | |
| C2 | Reel badly until the fish escapes | "fish escaped" message, no item granted, no console error | | |
| C3 | Over-tension until the line snaps | Snap message; (enhanced mode) the fitted **line component is destroyed** and `line_broke` notifies | | |
| C4 | Let the fight run past `Config.Timings.reelTimeout` | The NUI ends the fight; the claim is refused as `timeout`; no item | | |

## D. Cancel and lifecycle

| # | Steps | Expected | Pass/Fail | Notes |
|---|---|---|---|---|
| D1 | Press **X** during equip standby | Rod packs up immediately, player unfrozen | | |
| D2 | Press **X** while waiting for a bite | Same, immediate | | |
| D3 | Press **X** during the hook window | Same, immediate | | |
| D4 | Press **X** mid-reel | Same, immediate — this is the only way out while frozen | | |
| D5 | Press **X** at the exact moment the catch settles (spam X during the last second of the fight) | Client tears down cleanly. The catch is either granted or not — never granted twice. A cast attempted immediately after may be refused with `error_busy` for a moment; the next one works | | |
| D6 | Disconnect mid-fight, reconnect | No stuck session: fishing works immediately on rejoin; no orphan session in the console | | |
| D7 | Fill the inventory completely, then land a catch | Player is told the **inventory is full** (not "the fish escaped"); no item, session cleared | | |
| D8 | Same as D7, then check `Config.RateLimit`: land `RateLimit` real catches in the same minute | The full-inventory attempt did **not** consume one of them | | |
| D9 | Stop the database (or break the `zfishing_players` write), then land a catch | Player gets the fish and the catch card as normal; console prints `catch settlement warning … stage=xp_save_failed` | | |
| D10 | Same with the catch log write broken | Same — fish granted, `stage=catch_log_failed` in the console only | | |
| D11 | Land a catch with the inventory full of everything **except** one fish slot, with rare loot rolling | Fish granted; if the loot cannot fit, console warns `stage=rare_loot_failed` and the catch still succeeds | | |
| D12 | Disconnect **during settlement** — alt-F4 in the last half-second of the fight, repeat until one lands mid-settle | No console error, no stuck session; the claim line reads `committed=false reason=player_gone` **or** the catch committed before the drop. **No** `identity guard` line — a plain disconnect is not a breach | | |
| D13 | Disconnect while **waiting for a bite**; reconnect and cast again | The new cast is accepted immediately — **not** `error_busy`. (The pending bite timer is guarded by object identity, `s.fish ~= fish`, so it cannot fire into the new session; that guard is covered by the Lua suite, not by anything visible here. The observable signal is only that the rejoined player can fish.) | | |
| D14 | Disconnect **mid-reel** (while frozen in the fight); reconnect and cast again | Same — accepted immediately, no stuck `busy`, and the reel HUD does not reappear on rejoin | | |
| D15 | Check the console after any D9–D11 failure | **Exactly one** `catch settlement warning` line per failed stage, carrying `session=`, `src=`, `identity=` and `detail=`. Two lines for one failure is a regression | | |

## E. Selling

| # | Steps | Expected | Pass/Fail | Notes |
|---|---|---|---|---|
| E1 | Carry several fish, sell at the dock NPC | Paid once; **all** fish removed; the amount matches base × weight × quality | | |
| E2 | Sell with no fish | "You have no fish to sell"; no money | | |
| E3 | Spam the sell interaction as fast as possible (10+ times) | At most one payout per batch of fish; later requests answer "Slow down" / "a sale is already going through"; **no duplicate money, no duplicate fish** | | |
| E4 | (2 players) Both sell at the same NPC simultaneously | Each is paid for their own fish only | | |
| E5 | (simple mode) Sell | Extra notification: "Sold at standard weight — this inventory has no per-catch weight" | | |
| E6 | If you can force a money-add failure (framework offline / account missing), sell | Message "The payment failed — your fish were returned"; **the fish are back in the inventory**; console logs `sale payout failed … restoreFailed=0` and **no** CRITICAL line | | |
| E7 | Force a money-add failure **and** a full inventory so the fish cannot go back | Console logs one `CRITICAL sale reconciliation` line per lost stack with item, count, metadata and expectedPayout, sharing the `saleId` of the summary line — enough to refund by hand | | |
| E8 | Disconnect during a sale (alt-F4 the instant you confirm, repeat until one lands mid-sale) | No console error; the sale either completed before the drop or logged `sale aborted on identity loss` with a `stage=`; the reconnected player can sell again immediately (the lock was released) | | |

## F. Boats

| # | Steps | Expected | Pass/Fail | Notes |
|---|---|---|---|---|
| F1 | Fish while seated in a boat | Boat anchors (stops drifting); "boat anchored" notification | | |
| F2 | Stand on the deck (not seated) and fish | Same — deck fishing must still anchor | | |
| F3 | Sit in a large boat (Tug/Marquis), stand up, walk to the stern, fish | Still anchors — this is the case the 15m allowance exists for | | |
| F4 | Press **X** to stop fishing | Boat unfreezes for every player | | |
| F5 | (2 players) Both fish from the same boat; one stops | Boat stays anchored until the **second** one stops | | |
| F6 | (2 players) Both fish from the same boat; one disconnects | Boat stays anchored for the remaining angler | | |
| F7 | Die while fishing on a boat, respawn at a hospital, press **X** | The boat unfreezes — a release from far away must still work | | |
| F8 | Moor a second boat alongside and fish from the first | Only the boat you are fishing from freezes; you cannot hold two anchors | | |
| F9 | Drive the boat away while a passenger is fishing | Passenger's session cancels after ~1.5s of throttle; no ped left attached | | |

## G. Abuse paths (needs a modified client or a console `emit`)

These are the rows the hardening exists for. If you cannot produce forged events,
mark them **N/A — no tooling** rather than Pass.

| # | Steps | Expected | Pass/Fail | Notes |
|---|---|---|---|---|
| G1 | Fire `zfishing:server:anchorBoat` with a netId of a boat across the map | Nothing happens; no boat freezes | | |
| G2 | Fire it with a netId of a **car** or a ped | Nothing happens | | |
| G3 | Fire it 50 times in a second | Gate absorbs it; no console spam; no freeze storm | | |
| G4 | Fire `zfishing:reportWeather` with garbage (`nil`, `"LAVA"`, hour `999`, `0/0`) | Weather bonuses keep using the last good value; nothing in the console | | |
| G5 | Fire `zfishing:store:request` 100 times | At most 3 syncs per 10s; server stays responsive | | |
| G6 | Replay a `zfishing:claim` for a session already claimed | Refused; exactly one fish granted | | |
| G7 | Spam `zfishing:cast` | Refused with `too_many_requests` before any fish roll; no bait consumed | | |
| G8 | Spam the rig menu callbacks (attach/detach) | Refused after 10 per 5s; no item duplicated or destroyed | | |
| G9 | Call `/zfish_xp` and `/zfish_roll` as a **non-admin** | Both refused | | |
| G10 | Call them as an admin | Both work | | |
| G11 | **Source reuse, catch.** Land a catch and disconnect inside the settlement window, then have a second player join onto the freed server id fast enough to inherit it | The replacement player receives **no** fish, **no** XP and **no** rare loot. If the id really was reused, the console shows one `identity guard blocked stale settlement … stage=catch_commit` line. Server ids are assigned by the server, so this is usually **N/A — cannot force src assignment** | | |
| G12 | **Source reuse, sale.** Same, but disconnect during a sale | The replacement player is not paid and receives no restored fish; console shows `sale aborted on identity loss` plus one `CRITICAL sale reconciliation` per stack that left the original player's bag. Usually **N/A — cannot force src assignment** | | |
| G13 | Check every identity/reconciliation line printed during G11–G12 | Identifiers appear redacted (`license:...1234`), never in full | | |

## H. Admin surface

| # | Steps | Expected | Pass/Fail | Notes |
|---|---|---|---|---|
| H1 | `/zfishadmin`, change a setting, save | Takes effect without a restart | | |
| H2 | `/zfishzone`, place a zone, then fish in it | Zone works immediately for every player | | |
| H3 | `/zfishreload` after editing a DB row directly | New value is live | | |

## I. Persistence

| # | Steps | Expected | Pass/Fail | Notes |
|---|---|---|---|---|
| I1 | Land a catch, then read `zfishing_players` for your identifier | `xp` and `level` reflect the catch | | |
| I2 | Land a catch, then read `zfishing_catches` | One new row: your identifier, species, weight, quality, zone — matching the catch card | | |
| I3 | Land a catch, disconnect immediately, read `zfishing_catches` | The row is still written, and under **your** identifier — a catch belongs to whoever caught it | | |
| I4 | Restart the server, rejoin, check level and the admin panel | XP/level survived; every admin-edited config value survived | | |
| I5 | Stop the DB, then fish | The player still gets the fish and the card; console warns per failed stage; nothing crashes and the session is not stuck | | |
| I6 | Start the DB again, land a catch | Persistence resumes with no restart and no warnings | | |

## J. Runtime compatibility

Only the combinations this build actually claims to support, and only the ones you
really started. Do **not** fill in a row you did not boot.

| # | Framework + inventory (pinned mode) | Boot line correct | Catch | Sell | Rig menu | Pass/Fail | Notes |
|---|---|---|---|---|---|---|---|
| J1 | `________` + `________` (`enhanced-rig`) | | | | | | |
| J2 | `________` + `________` (`simple-fishing`) | | | | | | |
| J3 | `________` + `________` | | | | | | |

## K. Performance

Measure with FiveM's own tools — `resmon 1` for the per-resource frame cost and
`profiler record <frames>` / `profiler view` for a breakdown. **Record the measured
numbers first.** This table deliberately has no target column: a threshold invented
after reading the result is not a threshold. Once these are filled in on real
hardware, a follow-up pass can propose budgets from them.

| # | Scenario | resmon ms (client) | resmon ms (server) | Notes |
|---|---|---|---|---|
| K1 | Idle, rod stowed | | | |
| K2 | Rod equipped, standby | | | |
| K3 | Cast, waiting for a bite | | | |
| K4 | Active reeling (NUI minigame running) | | | |
| K5 | Catch card open | | | |
| K6 | 2+ anglers fishing simultaneously (state how many) | | | |
| K7 | `profiler record 500` during K4, then `profiler view` | Name the top three zfishing entries | | |

Hardware / server spec these were taken on: `________________________________`

---

## Sign-off

Every row Pass (or an explicit, justified N/A): `______`  ·  Date: `__________`

Until that line is signed, the release status is **RELEASE CANDIDATE at best** —
never READY FOR PRODUCTION.

Known gaps that this checklist **cannot** close, and that stay open regardless of
the result: the minigame outcome is still decided by the NUI and only
plausibility-checked on timing by the server (see
`docs/superpowers/specs/2026-08-18-zfishing-minigame-authority-design.md`), and
two boats moored within 15m of each other remain interchangeable to a modified
client (`docs/ARCHITECTURE.md` §9).
