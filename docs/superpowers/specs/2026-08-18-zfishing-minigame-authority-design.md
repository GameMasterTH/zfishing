# zfishing — Server-Authoritative Minigame Outcome (design only)

Resource root: `e:\Web\ZCore\zfishing` (branch `security-hardening`, HEAD `603ecb6`)

**Status: design only. Nothing here is implemented.** This document specifies the
rewrite that moves the reel outcome from the client to the server, records why the
approach the external review recommended does not achieve that, and states plainly
what the rewrite does and does not buy. It is deliberately not being built now: it
changes the bite payload, the `claim` signature, `web/src/engine/minigameEngine.ts`
and the NUI input loop together, and that is a bigger change than the nine hardening
tasks that preceded it.

Every code reference below was checked against the tree at `603ecb6`. Every empirical
claim was measured; the measurements are reproducible and the method is given inline.

---

## 1. Where authority actually sits today

Nine tasks on this branch hardened the edges of the fishing flow — session nonces, an
idempotent claim lock, per-action rate limiting, admin-gated commands, boat-anchor
ownership, single-sourced constants. None of them changed the central fact:

**The NUI decides whether the player caught the fish.**

The path is short and worth reading as one piece:

| Step | Location | What crosses the boundary |
|---|---|---|
| Server rolls the fish, ships fight parameters | `server/session.lua:178-187` | `behavior, tensionDiff, fishEnergy, greenZone, snapFactor, drainRate, baseDrain, reelTimeout, fishWeight` |
| Client forwards them to the NUI | `client/minigame.lua:38-44` | the same, plus `startedAt` |
| NUI simulates the whole fight | `web/src/components/TensionMinigame.tsx:42-62` → `web/src/engine/minigameEngine.ts:109` | nothing — this is entirely client-side |
| NUI reports the verdict | `TensionMinigame.tsx:39` | `{ success, reason, durationMs }` |
| Client claims | `client/minigame.lua:73` | `claim(sessionId, reelDurationMs, success, reason)` |
| Server checks plausibility | `server/session.lua:214-237` | accepts or rejects on **timing only** |

The server never simulates anything. `success` is a boolean the client chose.

Task 6 tightened the plausibility envelope around that boolean. `server/session.lua:227`
computes the floor as `minMs = (fish.fishEnergy / (Config.Minigame.baseDrain * drain)) * 1000`
and `:232` accepts anything at or above `minMs * 0.9`. For the shipped defaults
(`fishEnergy` 100, `baseDrain` 12.0 at `config/main.lua:23`) that floor is 8.333s, and
the tolerance is now 90% of it rather than the ~35% it was before Task 6. That removes
free headroom. It does not move authority: a client that waits 7.5 seconds and then
reports `success = true` is still paid.

### 1.1 The second, quieter exploit

`server/session.lua:242` special-cases only one failure reason:

```lua
if reason == 'snap' and s.rigSlot then
    Rig.breakLine(src, s.rigSlot)
```

`reason` is client-supplied. A client whose line genuinely snapped can report
`reason = 'escape'` instead and keep its line component. The consequence is smaller
than free fish, but it is a real, currently-exploitable durability bypass, and it is
closed by the same change — for the same reason, and at no extra cost.

---

## 2. Why seed-plus-replay does not work

The external review's headline recommendation was: ship a `fightSeed` from the server,
have the client replay a deterministic minigame, send the input timeline, and let the
server re-simulate it. This does not move authority, and the reason is not the one most
people reach for first.

**The first obstacle is the integrator, not the randomness.**

`MinigameEngine.tick(dt, holding, elapsedMs)` (`minigameEngine.ts:109`) is a `dt`
integrator. Every accumulating quantity is scaled by the caller's `dt`:

```ts
this.smoothCenter += (targetCenter - this.smoothCenter) * Math.min(1.0, dt * this.lerpRate)  // :127
this.tensionV     += ((holding ? 40 : -50) + pull) * dt                                       // :133
this.energyV      -= this.config.baseDrain * (this.config.drainRate || 1) * dt                // :137
this.snapMs       += dt * 1000                                                                // :142
```

`dt` comes from the client's frame clock (`TensionMinigame.tsx:43`,
`Math.min(0.05, (now - last) / 1000)`). To replay a client-supplied input timeline the
server needs that `dt` sequence. A client that supplies its own `dt` values still
controls the integration result — the exploit moves one layer down, from "assert the
outcome" to "assert the frame timing that produces the outcome", at the cost of a full
determinism port.

**This is measured, not argued.** Replaying an *identical* holding timeline — expressed
in wall-clock milliseconds, so both runs see the same player intent at every instant —
at two different `dt` values flips the outcome:

```
steady_light, hold 600ms / release 600ms, fishEnergy 100, greenZone 0.2, snapFactor 1:
  dt = 4.2ms  -> success @ 9263ms
  dt = 50ms   -> snap    @ 9150ms
```

One flip in an 81-timeline sweep over three behaviours and a grid of duty cycles. A low
rate on *random* timelines — but an attacker does not sample randomly, they search, and
the flips cluster exactly where an honest fight is near the snap threshold. An existence
proof is all that is needed: the server cannot distinguish a legitimate `dt` sequence
from a fabricated one, so accepting `dt` from the client means accepting the outcome
from the client.

**The `Math.random()` calls are the second obstacle.** `pullFor` re-rolls
`5 + Math.random() * 30` every 700–1500ms for the `erratic` behaviour
(`minigameEngine.ts:37-38`), and `centerTargetFor` re-rolls the band centre
(`:62`). These do need fixing — §5.3 — but a design that leads with the randomness has
misdiagnosed the problem. Seeding the PRNG while still accepting client `dt` buys
nothing.

---

## 3. The design: a fixed-timestep contract

The server stops accepting a verdict and starts computing one. It does this by owning
the *time base* rather than trying to validate the client's.

> **Server picks the tick schedule. Client reports only `holding` at those ticks.
> Server integrates with its own constant `dt` and decides the outcome.**

The client's verdict stops being an input. `durationMs`, `success` and `reason` all
leave the `claim` signature.

### 3.1 Deriving the schedule

The server picks a tick interval `tickMs` and derives the tick count from the fight
clock it already owns:

```
tickMs    = Config.Minigame.tickMs        -- new constant, proposed default 50
tickCount = ceil(Config.Timings.reelTimeout / tickMs)
dt        = tickMs / 1000                 -- the server's constant, never the client's
```

Both `tickMs` and `tickCount` ship in the `zfishing:bite` payload alongside the
existing `baseDrain` and `reelTimeout` that earlier tasks added at
`server/session.lua:184-185`.

**Size the buffer against the schema maximum, not the default.**
`config/main.lua:17` ships `reelTimeout = 30000`, but `server/config_schema.lua:20`
permits an admin to set it anywhere in `[3000, 120000]` from the admin panel. So:

| `reelTimeout` | ticks at 50ms |
|---|---|
| 3000 (schema min) | 60 |
| 30000 (shipped default) | 600 |
| 120000 (schema max) | 2400 |

Any cap expressed as a constant will break legitimate fights the first time an admin
raises `reelTimeout`. The cap must be **derived**, not literal — see §3.4.

### 3.2 The tick interval is not a free choice

Picking 50ms is defensible but it is a tuning decision, not a neutral one. Measured
against the shipped engine:

**What is dt-invariant.** Energy drain and the snap budget are linear in `dt`, so
totals over a fight do not depend on step size. A closed-loop "competent player"
(hold while tension is below the band centre) finishes in:

```
dt = 6.9ms (144fps)  -> success @ 8333ms
dt = 16.7ms (60fps)  -> success @ 8317ms
dt = 50ms            -> success @ 8300ms
```

A 33ms spread — one tick of quantisation — across a 7x change in step size. Time-to-
success is effectively dt-invariant, and it lands on the theoretical floor
`fishEnergy / (baseDrain * drainRate) = 8.333s`, which is the same floor
`server/session.lua:227` already computes.

**What is not dt-invariant.**

1. *The exponential ease at `:127`.* `smoothCenter += (target - smoothCenter) * min(1, dt * lerpRate)`
   is forward Euler on an exponential decay, so coarser steps overshoot toward the
   target. Easing from 55 toward a constant 80 for one second at `lerpRate = 3.0`:

   | step | result | vs continuous solution 78.755 |
   |---|---|---|
   | 6.9ms | 78.819 | +0.064 |
   | 16.7ms | 78.848 | +0.093 |
   | 50ms | 79.031 | +0.276 |

   A 0.21-unit spread on a 25-unit move — under 1%, and small against `greenHalf`
   (`14 + greenZone * 80`, `:97`, so 14–94). Not a balance break, but it is a change.

2. *Control granularity.* The player's minimum tension increment is
   `((holding ? 40 : -50) + pull) * dt`:

   | step | hold | release |
   |---|---|---|
   | 6.9ms (144fps) | +0.36 | -0.26 |
   | 16.7ms (60fps) | +0.87 | -0.63 |
   | 50ms | +2.60 | -1.90 |

   At 50ms the player's control is 3x coarser than the 60fps client they have today.
   The bang-bang limit cycle around the band centre widens proportionally. This is the
   most visible feel change in the whole rewrite.

3. *Threshold sampling.* `tension > 92` (`:142`) is evaluated at tick boundaries, so a
   coarser tick can step over the danger band and accumulate snap time that a finer
   tick would have avoided — or miss a brief excursion entirely.

**Consequence for the implementer:** `lerpRate`, the `40` / `-50` rates and
`snapBudget = 900 * snapFactor` (`:96`) were tuned against ~16ms steps. Adopting 50ms
implies a retune pass, and the retune is part of this work, not a follow-up. If the
feel regression is unacceptable, 25ms halves the ripple at double the buffer cost
(1200 ticks default, 4800 at the schema max) — still small under the encoding in §3.4.
**Do not present the tick interval as a free parameter.**

### 3.3 The wire contract

**Bite payload** (`server/session.lua:178-187`) gains three fields:

```lua
TriggerClientEvent('zfishing:bite', src, {
    -- ... existing fields unchanged ...
    baseDrain   = Config.Minigame.baseDrain,
    reelTimeout = Config.Timings.reelTimeout,
    tickMs      = Config.Minigame.tickMs,     -- NEW: the sampling interval
    tickCount   = tickCount,                  -- NEW: ceil(reelTimeout / tickMs)
    fightSeed   = seed,                       -- NEW: uint32, minted per bite (§5.3)
})
```

The seed is stored on the session (`sessions[src].fightSeed`) at the same moment it is
sent, so the server can reproduce the identical sequence at claim time. It is not a
secret — the client must have it to render the same fight — it is a *shared* seed.

**Claim signature.** Today:

```lua
claim(sessionId, reelDurationMs, success, reason)   -- server/session.lua:214
```

Becomes:

```lua
claim(sessionId, inputBuffer)
```

`reelDurationMs`, `success` and `reason` are all removed. The server derives all three:
the tick index at which the fight finished gives the duration, and the finish condition
it reaches gives `success` and `reason`. `client/minigame.lua:68-73` (`reelResult`)
forwards the buffer instead of the verdict.

**Return value** is unchanged in shape — `{ ok, fish }` — so `client/minigame.lua:74-85`
and the catch card need no changes. The NUI learns the real outcome from the claim
result rather than from its own simulation.

### 3.4 Buffer encoding and its own abuse surface

One bit per tick is the naive encoding: 600 bits at the default, 2400 at the schema
maximum. That is small in absolute terms, but a raw bit array is a poor fit for the
data — humans hold and release in runs of hundreds of milliseconds, not per-tick.

**Encode as a run-length list of `holding` transitions.** The buffer is a list of tick
indices at which `holding` changed, with the convention that `holding` starts `false`:

```
[]                 -> never held
[0]                -> held from tick 0 to the end
[12, 40, 55, 90]   -> released..hold@12..release@40..hold@55..release@90..end
```

This matches the shape of the data the client already produces:
`client/minigame.lua:49-59` runs a thread that pushes a `reelInput` NUI message *only
when `holding` changes* (`:55`), which is a transition list in all but name. A realistic
30s fight produces on the order of 60–120 transitions, well under the 600 raw bits, and
degenerate cases (never holding, holding throughout) cost one entry or none.

**The cap must be derived and enforced server-side.** The buffer is a flood vector: an
unbounded transition list is an unbounded allocation and an unbounded integration loop,
reachable three times per three seconds through the existing gate at
`server/session.lua:14`. Validate, in this order, **before** any integration:

1. `type(inputBuffer) == 'table'` and `#inputBuffer <= tickCount` — a transition list
   longer than the tick count is impossible by construction (at most one transition per
   tick). This derives the cap from `reelTimeout`, so raising `reelTimeout` in the admin
   panel raises the cap in step and never breaks a legitimate fight.
2. Every entry is a number, an integer, and in `[0, tickCount)`.
3. Entries are **strictly increasing**. This is the cheap check that matters — it makes
   the buffer canonical, so there is exactly one encoding per fight, and it rejects
   duplicate-index padding without needing to look at values.
4. Reject the whole claim on any violation rather than repairing it. A malformed buffer
   is not a recoverable condition.

A practical tightening worth considering: humans cannot toggle a key faster than roughly
every 60–80ms, so a minimum gap between transitions is defensible. It is deliberately
*not* specified here — it is an input-pattern heuristic (§6), it will produce false
positives on key-repeat and network hiccups, and it does not belong in the correctness
layer.

---

## 4. The NUI restructure

`TensionMinigame.tsx` currently integrates once per animation frame, at whatever `dt`
the frame took, and derives `elapsed` from `performance.now()` (`:45`). Under the fixed
schedule the scored path must instead use `tickIndex * tickMs`. The RAF loop becomes the
standard **fixed-step update plus render interpolation** accumulator:

```
accumulator += frameDelta
while (accumulator >= tickMs) {
    holdingBuffer.sample(tickIndex, holdingRef.current)   // one sample per scheduled tick
    state = engine.tick(dt, holdingRef.current, tickIndex * tickMs)   // dt is the CONSTANT
    accumulator -= tickMs
    tickIndex++
}
render(interpolate(previousState, state, accumulator / tickMs))       // presentation only
```

Three properties this must have:

- **The engine is never called with a frame-derived `dt`.** `dt` is `tickMs / 1000`,
  full stop. The `Math.min(0.05, ...)` clamp at `:43` disappears with the frame `dt`
  it was clamping.
- **Rendering stays decoupled.** The NUI may draw at 144fps or 30fps; only the number of
  scheduled ticks consumed changes, never the physics. Interpolation between the last
  two states keeps the bars smooth at frame rates above the tick rate.
- **A slow client falls behind, it does not desync.** If a frame takes 200ms the loop
  runs four ticks in a row, sampling the same `holding` value. That is correct — it is
  what the server will compute, because the server sees only the transition list. Guard
  the `while` with a maximum catch-up (e.g. 8 ticks per frame) so a tab stall cannot
  spiral.

`holdingRef` (`:27-28`) and the `reelInput` message that feeds it (`App.tsx:39-40`) stay
exactly as they are. The Lua thread at `client/minigame.lua:49-59` already pushes on
every change; the NUI samples that latched value at tick boundaries. **This part of the
existing code is already correct for this design** and should not be touched.

### 4.1 What does *not* move to the server

`shouldStreamEnergy`, `lastSentAt` and `lastSentPct` (`minigameEngine.ts:148-153`, `:81-82`)
are presentation state. They throttle the `reelEnergy` NUI callback
(`TensionMinigame.tsx:51`) that drives the bobber's distance in `client/casting.lua`.
They have no effect on the outcome and must be **excluded from the scored subset**, so
the Lua reference implementation does not carry dead state. The same goes for
`energyPct` and the `overTension` display flag.

---

## 5. Porting the integrator to Lua

### 5.1 What moves

A new pure module — `shared/minigame_sim.lua`, following the discipline of
`shared/rig_rules.lua` — implementing exactly the scored subset:

| Piece | Source | Notes |
|---|---|---|
| Constructor derivations | `minigameEngine.ts:96-106` | `snapBudget = 900 * snapFactor`, `greenHalf = 14 + greenZone * 80`, `wf`/`amp`/`spd`/`lerpRate` per behaviour |
| Band centre easing | `:126-128` | ease, then clamp to `[greenHalf + 4, 100 - greenHalf - 4]` |
| `centerTargetFor` | `:47-70` | **transcendental removed — see §5.2** |
| `pullFor` | `:25-45` | `erratic` branch reseeded — see §5.3 |
| Tension update | `:132-134` | `((holding ? 40 : -50) + pull * tensionDiff) * dt`, clamped 0..100 |
| Energy update | `:136-140` | in-band drain / below-band regen / above-band unchanged |
| Snap budget | `:142-143` | `+dt*1000` above 92, `-dt*500` otherwise, floored at 0 |
| `damaged` latch | `:145-146` | set once energy drops below 98% |
| Finish conditions | `:155-167` | **ordering is load-bearing — see below** |

The finish ordering at `:155-167` is `escape` → `success` → `snap` → `timeout`, and it
must be reproduced exactly. `escape` is checked first, so a fish that recovers to full
energy escapes even on the tick its energy would otherwise have hit zero; `success`
precedes `snap`, so landing the fish on the same tick the line would have broken is a
catch. Reordering these changes outcomes on boundary ticks and would show up as the
server disagreeing with the client the player watched.

**The Lua side becomes the reference; TypeScript mirrors it.** This is the inversion
that matters. Today `minigameEngine.ts` is the only implementation. After this change
the server's copy defines the fight, and `minigameEngine.ts` exists so the player *sees*
what the server scores. Any divergence is a TypeScript bug by definition. Make the
module a pure function of a config table passed in — never a reader of the `Config`
global — so it cannot depend on whether it loads before `config/main.lua`.
`shared_scripts` loads before `server_scripts` (`fxmanifest.lua:11-37`) so the server can
call it, and `tests/luarun.mjs` mounts `shared/` so it is directly testable.

### 5.2 Float behaviour — measured, and the decision it forces

The design must not hand-wave this, so it was measured. Method: compare Lua 5.4 under
the harness VM (wasmoon, the same one `tests/luarun.mjs` uses) against V8, on the exact
expressions from the engine.

**Result 1 — the non-transcendental scored path is bit-identical.** Tension, energy,
snap budget, the exponential ease, and every `math.max`/`math.min` clamp, run for 600
and 2400 ticks at `dt = 0.05`:

```
ticks=600   lua: 84.799999999999955, -21.799999999999773, 14750.0, 40.045066417136916
            js : 84.799999999999955, -21.799999999999773, 14750.0, 40.045066417136916
ticks=2400  lua: 84.799999999999955, -324.20000000000061, 64250.0, 40.045066417136916
            js : 84.799999999999955, -324.20000000000061, 64250.0, 40.045066417136916
```

Identical to the last bit, *including* the accumulated representation error. Lua 5.4
numbers and JS numbers are both IEEE-754 doubles and the arithmetic here is multiply,
add, compare and clamp. This is exact, not approximately exact.

**Result 2 — `math.sin` and `Math.sin` do not agree.** On the exact call shape at
`minigameEngine.ts:55` (`Math.sin(elapsed / spd) * amp`, `steady_light`, `fishWeight` 5,
so `spd = 1400/0.3` and `amp = 11.5`), sampled every 1ms across the full 0–30000ms fight:

```
  mismatches: 195 / 30001 samples  (0.65%)
  max absolute difference: 1.78e-15
  worst case: elapsed=3715  js=8.218055251780827  lua=8.218055251780829
```

Last-ULP disagreement, on the arguments this code actually uses. And that is only
*two* libm implementations. Production adds a third: CitizenFX's Lua 5.4 (`fxmanifest.lua:3`
`lua54 'yes'`) links the platform libm, not the WASM one the test harness uses. So the
harness cannot even reproduce the production pairing — a parity test that passes in CI
would prove nothing about the live server.

**Decision: keep the transcendental out of the scored path. Do not accept a tolerance band.**

A tolerance band fails here for a specific, structural reason, and it is worth stating
so nobody re-litigates it. `Math.sin` feeds `smoothCenter`, which sets `gLo`/`gHi`,
which selects the branch at `:136-140`:

```ts
if (this.tensionV >= gLo && this.tensionV <= gHi)  { /* drain */ }
else if (this.tensionV < gLo)                      { /* regen */ }
```

That is a *discrete branch on a continuous comparison*. A 1.78e-15 difference in `gLo`
flips it whenever `tension` lands within 1.78e-15 of the boundary. Rare per tick — but
the consequence is not small: one flipped branch is one tick of drain-versus-regen
(`0.6` versus `+0.15` energy units at 50ms), which is macroscopic, and it changes the
trajectory for every subsequent tick. A tolerance on the *final* energy cannot recover a
branch that flipped 400 ticks earlier; by then the two simulations are simply running
different fights. The failure mode is a rare, unreproducible "the server stole my fish"
report, which is the single worst class of bug to inherit.

**Mechanism: a shared integer-indexed sine table.** Replace `Math.sin(elapsed / spd)`
with a lookup into a fixed table of N entries over one period, with linear interpolation
between entries. Requirements:

- The table is generated **once, offline**, and committed as explicit decimal literals
  in both `shared/minigame_sim.lua` and `minigameEngine.ts`. Never computed at load time
  by either host — that reintroduces the libm dependency it exists to remove.
- Entry count fixed and identical on both sides (256 is ample: the band centre is a
  slow visual oscillation, and interpolation error at 256 entries is far below the
  ~1-unit visual resolution of the bar).
- Index derivation is integer arithmetic; interpolation is multiply and add. Both are in
  the bit-exact class from Result 1.

This also removes the last obstacle to a meaningful parity test: with no transcendental,
a cross-runtime test asserting **bit-identical** results is achievable and is the right
assertion, rather than a tolerance that would silently mask a real divergence.

Do **not** adopt the tempting half-measure of "server uses the table, client keeps
`Math.sin` because it only renders". The client's render *is* the fight the player
plays; if it diverges from the scored simulation the player is being shown a lie.

### 5.3 Eliminating the randomness

Both `Math.random()` sites become draws from a seeded PRNG:

| Site | Current | Draws per re-roll |
|---|---|---|
| `pullFor`, `erratic` | `minigameEngine.ts:37-38` — value `5 + rand*30`, then interval `700 + rand*800` | **2** |
| `centerTargetFor`, `erratic` | `:62` — centre `55 + (rand - 0.5) * 2 * amp` | **1** |

**Algorithm: xorshift32.** Explicitly not `math.random` / `Math.random`, whose sequences
differ between implementations and are not stable across host versions. xorshift32 is
chosen over a 64-bit generator for a concrete cross-language reason: Lua 5.4 has 64-bit
integers and native bitwise operators, but **JavaScript's bitwise operators are 32-bit**
(operands are coerced to int32). A 32-bit generator is the widest that both sides express
naturally.

- Lua: mask with `& 0xFFFFFFFF` after every shift/xor to stay in the unsigned 32-bit
  domain (Lua's integers are signed 64-bit, so the mask is what keeps the two sides in
  step).
- JS: use `>>> 0` after each step to force the unsigned interpretation.
- Pin the float conversion divisor identically on both sides — `state / 4294967296` for
  `[0, 1)` — as an explicit literal, not a named constant that could drift.

**Pin the draw order.** The sequence is only reproducible if both sides draw in the same
order. Specify it: within a tick, `centerTargetFor` is evaluated before `pullFor`
(matching the current call order at `:126` and `:132`), and `pullFor`'s re-roll draws
**value first, then interval**. Write this into the module's header comment; it is the
kind of detail a well-meaning refactor silently breaks.

**Seeding.** The server mints a uint32 at bite time, stores it on the session, and ships
it in the payload (§3.3). Two generator instances per fight — one for `pullFor`, one for
`centerTargetFor` — seeded from the same fight seed by distinct, fixed derivations
(e.g. `seed` and `seed XOR 0x9E3779B9`), so the two streams cannot alias.

---

## 6. What this buys, and what it does not

**It makes the outcome server-decided.** After this change:

- The server computes `success`, `snap`, `timeout` and `escape` itself. A client cannot
  assert a catch it did not play.
- The `reason == 'snap'` durability bypass at `server/session.lua:242` closes, because
  `reason` is now the server's own finish condition rather than a client claim.
- The plausibility floor at `:227-232` — `minMs * 0.9`, Task 6's work — becomes
  **redundant**. It exists to bound a number the server no longer accepts. It should be
  deleted in the same change, not left as belt-and-braces around a variable that is no
  longer an input. This is the honest measure of the rewrite's value: it makes Task 6
  dead code.
- The wall-clock guard at `:235` (`elapsed > reelTimeout + 5000`) **stays**. It is not a
  plausibility check on the outcome; it is a stall and latency sanity bound on how long a
  session may sit in `reeling`, and it is still needed.

**It does not stop a bot from playing perfectly, and the design should not pretend otherwise.**

The bite payload deliberately ships every parameter needed to simulate the fight — that
is what lets the NUI render it — and after this change it also ships the seed. An
attacker can therefore run the identical simulation offline, search for a transition list
that wins, and submit it. The server will accept it, because it *is* a valid winning
play. The rewrite converts **"claim any outcome"** into **"submit a sequence that
actually wins"**. That is a genuine and worthwhile reduction — it restores the invariant
that the reward matches a real playthrough of a real fight, and it makes the fight
parameters mean something again — but it is not detection, and it does not end cheating.

Catching the bot is an **input-pattern problem**: superhuman transition timing,
implausibly low variance, identical buffers across fights. That is a statistical layer
over the buffers this design produces — which is a real side benefit, since those buffers
are exactly the data such a layer would need and the server does not currently have them.
It is explicitly **out of scope** here and is not designed in this document. It is noted
so that nobody reads the first half of this section as a claim that the problem is solved.

---

## 7. Migration

These change together and cannot be staged independently:

| Change | Files |
|---|---|
| Add `tickMs`, mint the seed, ship the schedule | `config/main.lua` (`Config.Minigame.tickMs`), `server/config_schema.lua` (bounds for it), `server/session.lua:178-187` |
| New simulation module | `shared/minigame_sim.lua` (new), `fxmanifest.lua:11-20` |
| Server integrates and scores | `server/session.lua:214-247` — new `claim` signature, buffer validation, integration, derive `success`/`reason`; delete `:221-233` |
| Forward the schedule | `client/minigame.lua:38-44` |
| Send the buffer | `client/minigame.lua:68-73` |
| Mirror the reference | `web/src/engine/minigameEngine.ts` — sine table, seeded PRNG, no `Math.random` |
| Fixed-step loop and buffer capture | `web/src/components/TensionMinigame.tsx:31-65` |
| Pass the schedule through | `web/src/App.tsx:73-85` |

`client/minigame.lua:49-59` and `App.tsx:39-40` — the `holding` transition path — are
already the right shape and should be left alone.

**Ordering.** Build `shared/minigame_sim.lua` first and get it green against the existing
`web/src/engine/__tests__/minigameEngine.test.ts` scenarios ported to Lua; that pins the
reference before anything depends on it. Then the wire contract, then the NUI. There is no
useful intermediate state that ships — do not attempt to land this in halves.

**Test strategy:**

1. *Parity, bit-exact.* Drive both implementations with the same buffer, seed and config;
   assert identical tension, energy, snap budget, finish tick and finish reason. Assert
   **equality**, not a tolerance — §5.2 shows that is achievable once the transcendental
   is gone, and a tolerance would hide the exact class of bug this test exists to catch.
   Run it across all four behaviours and both `erratic` PRNG streams.
2. *Buffer validation.* Over-length, non-integer, out-of-range, non-monotonic and
   duplicate-index buffers are each rejected before integration. Assert the integration
   function is never entered (a call-count spy on the sim module), not merely that the
   claim failed.
3. *Cap derivation.* Raising `Config.Timings.reelTimeout` to the schema maximum of 120000
   raises the accepted buffer length in step. This is the regression a hard-coded cap
   would cause, so it needs its own test.
4. *Outcome cases.* Server-derived `success`, `snap`, `timeout` and `escape` each reachable
   from a constructed buffer, with the `:155-167` ordering asserted on boundary ticks.
5. *The closed exploit.* A buffer whose fight genuinely snaps must break the line
   component, with no client-supplied `reason` available to route around it.
6. The Lua sha256 snapshot in `web/src/__tests__/bundleRebuildPreservation.test.ts`
   regenerates in the same commit (branch policy), and `web/dist` rebuilds and commits.

**Retune gate.** Before merge, play the fight at the chosen `tickMs` and compare against
the current 60fps feel (§3.2). If the coarser control granularity reads badly, drop to
25ms and re-measure rather than shipping and iterating in production — this resource has
never been verified end-to-end on a live server (ARCHITECTURE §10), so there is no
feedback channel that would catch it.

---

## 8. Open questions

1. **`tickMs` = 50 or 25?** 50 is specified above as the starting point. The decision
   needs a play test (§3.2), not analysis; both are cheap under the transition-list
   encoding.
2. **Does `Config.Minigame.tickMs` belong in the admin panel?** Exposing it means every
   admin change is a physics retune. Recommendation: keep it a code constant with schema
   bounds, and do not surface it in `web/src/admin/SettingsTab.tsx`.
3. **Sine table entry count.** 256 is proposed; if the band oscillation reads as stepped
   at low `spd` values, 512 costs nothing meaningful.
4. **Does the NUI need the claim result to correct its display?** If server and client
   agree bit-for-bit they never disagree, so no. But if a parity bug ever ships, the
   player sees a catch and gets a refusal. Consider having the NUI trust the claim result
   over its own simulation for the *displayed* outcome, purely as a graceful-degradation
   measure.

---

## 9. Verification of this document

Every path, symbol and line number cited was checked against `603ecb6`. The empirical
claims in §2, §3.2 and §5.2 were measured by bundling the shipped
`web/src/engine/minigameEngine.ts` with esbuild and driving it from Node, and by running
Lua 5.4 under wasmoon (the same VM `tests/luarun.mjs` uses) against V8 on identical
expressions. No repository file was modified to obtain them.

Baseline at the time of writing, unchanged by this document: Lua suites 52/52, 5/5,
11/11; `web/` 17 files / 66 tests.
