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

---

## A. Boot and mode

| # | Steps | Expected | Pass/Fail | Notes |
|---|---|---|---|---|
| A1 | Start the server with `zcore_lib` running | Console prints `[zfishing] runtime mode = <mode> (<framework> + <inventory>)` and **no** DDL/schema line | | |
| A2 | Start the server with `zcore_lib` **stopped** | Console prints `runtime profile unavailable ... fishing disabled`; using a rod notifies "unavailable", nothing crashes | | |
| A3 | Join the server, watch the console for 30s | Exactly one `zfishing:store:sync` per client; no repeated sync spam | | |

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
| D7 | Fill the inventory completely, then land a catch | Claim answers `inv_full`; no item, no silent loss, session cleared | | |

## E. Selling

| # | Steps | Expected | Pass/Fail | Notes |
|---|---|---|---|---|
| E1 | Carry several fish, sell at the dock NPC | Paid once; **all** fish removed; the amount matches base × weight × quality | | |
| E2 | Sell with no fish | "You have no fish to sell"; no money | | |
| E3 | Spam the sell interaction as fast as possible (10+ times) | At most one payout per batch of fish; later requests answer "Slow down" / "a sale is already going through"; **no duplicate money, no duplicate fish** | | |
| E4 | (2 players) Both sell at the same NPC simultaneously | Each is paid for their own fish only | | |
| E5 | (simple mode) Sell | Extra notification: "Sold at standard weight — this inventory has no per-catch weight" | | |
| E6 | If you can force a money-add failure (framework offline / account missing), sell | Message "The payment failed — your fish were returned"; **the fish are back in the inventory**; console prints nothing about a lost item | | |

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

## H. Admin surface

| # | Steps | Expected | Pass/Fail | Notes |
|---|---|---|---|---|
| H1 | `/zfishadmin`, change a setting, save | Takes effect without a restart | | |
| H2 | `/zfishzone`, place a zone, then fish in it | Zone works immediately for every player | | |
| H3 | `/zfishreload` after editing a DB row directly | New value is live | | |

---

## Sign-off

Every row Pass (or an explicit, justified N/A): `______`  ·  Date: `__________`

Known gaps that this checklist **cannot** close, and that stay open regardless of
the result: the minigame outcome is still decided by the NUI and only
plausibility-checked on timing by the server (see
`docs/superpowers/specs/2026-08-18-zfishing-minigame-authority-design.md`), and
two boats moored within 15m of each other remain interchangeable to a modified
client (`docs/ARCHITECTURE.md` §9).
