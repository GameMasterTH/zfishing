Rewards = {}

-- price = base(price/kg) × weight × quality multiplier
local qualityMult = { [1]=0.7, [2]=0.9, [3]=1.0, [4]=1.3, [5]=1.8 }

function Rewards.Price(species, metadata)
    local fish = Config.Fish[species]
    if not fish then return 0 end
    metadata = metadata or {}
    return math.floor(fish.price * (tonumber(metadata.weight) or 1) * (qualityMult[metadata.quality] or 1.0))
end

function Rewards.RollRareLoot(src)
    for _, loot in ipairs(Config.RareLoot) do
        if math.random() < loot.chance then return loot.item end
    end
    return nil
end

-- Detail recorded when a stage was skipped because the src changed hands. One
-- string so the console line and the tests agree on what a blocked stage looks like.
local IDENTITY_BLOCKED = 'identity guard blocked stale settlement'

-- Runs one secondary effect of an already-committed catch. A stage that fails --
-- raised, or reported false -- is recorded as a structured warning carrying its
-- cause; it never propagates, because by the time these run the fish is already in
-- the player's inventory. Every stage must return an explicit boolean: `not err`
-- rather than `err == false` so a stage that forgets to return cannot pass silently.
--
-- Nothing is printed here, deliberately. `server/session.lua` owns the session id
-- and the captured identity, so it is the only place that can log the full context
-- -- and it logs each warning exactly once. Printing here as well put two console
-- records in front of an operator for one logical failure.
local function runStage(warnings, stage, fn)
    local ok, err = pcall(fn)
    if not ok or not err then
        warnings[#warnings + 1] = {
            stage = stage,
            detail = ok and 'stage reported failure' or tostring(err),
        }
    end
end

-- A post-commit stage that mutates the PLAYER (inventory, XP cache, a notification)
-- runs only while the src still belongs to the player this catch was rolled for:
--
--   gone     an ordinary disconnect. Skipped silently -- there is nobody to
--            mutate, and warning on an expected disconnect trains operators to
--            ignore the line (the same reason the old cache-empty early returns
--            were silent).
--   changed  the src was reused mid-settlement. Skipped AND recorded: a stale
--            coroutine reaching a different player is the thing this guard exists
--            for, so it must be visible in the console.
local function runPlayerStage(src, expected, warnings, stage, fn)
    local state = Progression.IdentityState(src, expected)
    if state == 'gone' then return end
    if state == 'changed' then
        warnings[#warnings + 1] = { stage = stage, detail = IDENTITY_BLOCKED }
        return
    end
    runStage(warnings, stage, fn)
end

-- The catch commit boundary.
--
-- The fish item entering the inventory is the commit point. Everything after it --
-- XP, XP persistence, the catch log, rare loot -- is a secondary effect, and a
-- secondary failure must NEVER turn the catch back into a failure: the fish is in
-- the player's bag, so telling them they caught nothing would make the server state
-- and what they see disagree. Secondary failures surface as console warnings for an
-- operator, not as a client-visible outcome.
--
-- Returns a structured result rather than a boolean:
--   { ok = true,  committed = true,  warnings = { { stage = ..., detail = ... }, ... } }
--   { ok = false, committed = false, reason = 'inv_full' | 'player_gone'
--                                             | 'identity_changed' | 'no_identity' }
--
-- `ctx` carries the identity this catch was rolled for: { sessionId, identifier }.
-- It is REQUIRED. Settlement spans several yields, and FiveM reassigns source ids,
-- so "whoever is on src" is not the same statement as "the player who cast" --
-- only the captured identifier is. A missing one fails closed.
function Rewards.GiveCatch(src, fish, zoneName, ctx)
    local expected = type(ctx) == 'table' and ctx.identifier or nil
    if type(expected) ~= 'string' then
        return { ok = false, committed = false, reason = 'no_identity' }
    end

    -- The identity gate, above the commit point. Between the cast that rolled this
    -- fish and this line the player may have dropped, and their src may already
    -- belong to somebody else. Handing the catch to whoever holds that src now
    -- would give a stranger a fish that was rolled against another player's gear,
    -- level and zone -- so nothing is granted at all.
    local state = Progression.IdentityState(src, expected)
    if state ~= 'same' then
        return { ok = false, committed = false,
            reason = state == 'gone' and 'player_gone' or 'identity_changed' }
    end

    -- enhanced mode carries per-catch weight/quality in item metadata; simple mode
    -- has no per-instance metadata, so the catch is a plain stack. The mode is the
    -- one the resolver pinned -- we never send metadata that would be dropped.
    local meta
    if Zfishing.Enhanced() then
        meta = {
            weight = fish.weight, quality = fish.quality, label = fish.label,
            description = ('%s | %.2fkg | %d star'):format(fish.label, fish.weight, fish.quality),
        }
    end
    if not Zfishing.AddItem(src, 'fish_'..fish.species, 1, meta) then
        return { ok = false, committed = false, reason = 'inv_full' }
    end

    -- ---------------- COMMITTED from here down ----------------
    local warnings = {}

    -- AddXP writes cache[src] and SaveAwait reads it, so both would land on the
    -- replacement occupant if the src changed hands during the AddItem above.
    -- (SaveAwait's WHERE clause is safe on its own -- it captures c.identifier
    -- before the MySQL yield -- but the cache mutation in AddXP is not.)
    runPlayerStage(src, expected, warnings, 'xp_save_failed', function()
        Progression.AddXP(src, fish.xp)
        return Progression.SaveAwait(src)
    end)

    -- NOT identity-guarded, and that is the point: this row is catch HISTORY, not
    -- a player mutation, and it belongs to the identifier the fish was rolled for
    -- whatever happened to the src since. Re-reading Progression.Get(src) here --
    -- which is what this did -- files the catch under whoever holds that src by
    -- the time the insert runs, so a reused src rewrote another player's history.
    runStage(warnings, 'catch_log_failed', function()
        return MySQL.insert.await(
            'INSERT INTO zfishing_catches (identifier, species, weight, quality, zone) VALUES (?, ?, ?, ?, ?)',
            { expected, fish.species, fish.weight, fish.quality, zoneName }) ~= nil
    end)

    runPlayerStage(src, expected, warnings, 'rare_loot_failed', function()
        local loot = Rewards.RollRareLoot(src)
        if not loot then return true end       -- nothing rolled is the common case
        if not Zfishing.AddItem(src, loot, 1, nil) then return false end
        Zfishing.Notify(src, 'You reeled in something extra!', 'success')
        return true
    end)

    return { ok = true, committed = true, warnings = warnings }
end

-- One sale at a time, per player. Every step below crosses the zcore_lib resource
-- boundary and can yield, so two sellAll requests arriving together would each
-- price the same fish and each reach AddMoney. The lock is taken before the first
-- inventory read and released on every exit: success, nothing to sell, a failed
-- payout, a raised error (the pcall in the callback) and a mid-sale disconnect
-- (the playerDropped handler at the bottom of this file).
local selling = {}

-- Selling is not on any hot path -- the NPC is a manual interaction -- so the
-- window only has to be loose enough that a double-click is never punished.
local gate = ZUtil.MakeRateGate({
    sell = { max = 2, window = 3000 },
})

-- Removes every fish the player carries and reports what ACTUALLY left the
-- inventory. Price is accumulated only inside the `remove succeeded` branch, so
-- the payout can never include a fish that is still in the player's bag.
-- Pricing follows the pinned mode:
--   * enhanced-rig: each slot is priced from its own per-instance metadata
--   * simple-fishing: no per-instance metadata, so fish are priced at the
--     species-average weight / 3-star quality and the player is told explicitly.
-- All inventory access goes through the pinned runtime contract -- no direct
-- vendor inventory export and no GetResourceState auto-detect.
--
-- `samePlayer()` is re-checked before EVERY removal, not once at the top. The
-- sweep is a loop of resource-boundary calls that each yield, so a src that
-- changes hands halfway through would have the remaining removals strip the
-- REPLACEMENT occupant's fish. It costs one identifier lookup per removed stack;
-- selling is a manual NPC interaction, not a hot path. Returns a third value:
-- false means the sweep stopped early and `removed` is a partial list somebody
-- has to reconcile.
local function collectSale(src, samePlayer)
    local total, removed = 0, {}
    if Zfishing.Enhanced() then
        for species in pairs(Config.Fish) do
            local item = 'fish_'..species
            for _, slot in ipairs(Zfishing.Search(src, { item })) do
                if not samePlayer() then return total, removed, false end
                local count = slot.count or 1
                local price = Rewards.Price(species, slot.metadata) * count
                if price > 0 and Zfishing.RemoveItemSlot(src, item, count, slot.slot) then
                    total = total + price
                    -- `value` is what THIS stack was worth, not the sale total. A
                    -- reconciliation where two of three stacks came back is
                    -- unreadable without it: an admin would have to re-price the
                    -- lost stack by hand to know what is still owed.
                    removed[#removed + 1] = { item = item, count = count, metadata = slot.metadata, value = price }
                end
            end
        end
    else
        for species, cfg in pairs(Config.Fish) do
            local item = 'fish_'..species
            local count = Zfishing.ItemCount(src, item)
            if count > 0 then
                if not samePlayer() then return total, removed, false end
                local avgWeight = (cfg.weight.min + cfg.weight.max) / 2
                local price = Rewards.Price(species, { weight = avgWeight, quality = 3 }) * count
                if Zfishing.RemoveItem(src, item, count) then
                    total = total + price
                    removed[#removed + 1] = { item = item, count = count, value = price }
                end
            end
        end
    end
    return total, removed, true
end

-- Correlation id for one sale attempt. Server-side only -- it is never sent to the
-- client. It exists so the payout line, the compensation line and every CRITICAL
-- line for the same sale can be tied together in a console an admin is reading
-- after the fact, on a server where several players sell at once.
local nextSaleSeq = 0
local function newSaleId(src)
    nextSaleSeq = nextSaleSeq + 1
    return ('%s-%s-%s'):format(tostring(src), GetGameTimer(), nextSaleSeq)
end

local function metaSummary(meta)
    if type(meta) ~= 'table' then return 'none' end
    return ('%skg/%s star'):format(tostring(tonumber(meta.weight) or '?'), tostring(meta.quality or '?'))
end

local function sumValue(list)
    local n = 0
    for _, r in ipairs(list) do n = n + (r.value or 0) end
    return n
end

-- One CRITICAL line per stack that left the original player's inventory and did
-- not get back into it. Both value figures are on the line on purpose:
--   lostValue       what THIS stack was worth -- the amount still owed for it
--   expectedPayout  what the WHOLE sale was worth
-- The sale total alone is ambiguous the moment part of a sale was recovered, and
-- the console record is the only reconciliation mechanism this resource offers.
local function logLostStacks(sale, stage, lost, total)
    for _, r in ipairs(lost) do
        print(('[zfishing] CRITICAL sale reconciliation saleId=%s src=%s identity=%s stage=%s lost item=%s count=%s meta=%s lostValue=%d expectedPayout=%d')
            :format(sale.id, tostring(sale.src), ZUtil.SafeId(sale.identifier), stage,
                r.item, tostring(r.count), metaSummary(r.metadata), r.value or 0, total))
    end
end

-- The fish are already out of the inventory when the payout is attempted, so a
-- failed AddMoney must hand them back -- the resource never destroys an item
-- silently (same rule as rig attach/detach).
--
-- `samePlayer()` is re-checked before EVERY AddItem, not once before the loop.
-- Each AddItem crosses the zcore_lib resource boundary and yields, so a src that
-- changes hands after the first stack is back would have every remaining stack
-- materialise in the REPLACEMENT occupant's bag. On identity loss the loop stops
-- dead -- it does not keep restoring, does not retry, and does not hand the rest
-- to whoever holds the src now. What is already back stays back; what is still
-- out becomes a reconciliation item for the player who is owed it.
--
-- Reports lists rather than counts, and prints nothing: the caller owns the
-- saleId, so it is the only scope that can emit correlated records -- and an
-- admin needs to know exactly WHICH stacks are outstanding and what each is
-- worth, which a pair of integers cannot say.
local function restoreSale(src, removed, samePlayer)
    local restored, failed, remaining = {}, {}, {}
    for i, r in ipairs(removed) do
        if not samePlayer() then
            for j = i, #removed do remaining[#remaining + 1] = removed[j] end
            break
        end
        if Zfishing.AddItem(src, r.item, r.count, r.metadata) then
            restored[#restored + 1] = r
        else
            failed[#failed + 1] = r
        end
    end
    return {
        identityLost = #remaining > 0,
        restored = restored, failed = failed, remaining = remaining,
        restoredValue = sumValue(restored),
        -- everything that left the bag and is not back in it, whichever way it was
        -- lost. The accounting an admin reconstructs from the log is:
        --   removedValue (== expectedPayout) = restoredValue + unreconciledValue
        unreconciledValue = sumValue(failed) + sumValue(remaining),
    }
end

-- Is the player on this src still the one this sale was opened for?
--
-- The catch path asks Progression for this, but a sale cannot: a player who has
-- never cast has no progression cache, and treating that as "gone" would refuse
-- every first sale. So the sale reads the canonical identifier straight from the
-- pinned runtime contract -- never anything the client supplied.
local function saleIdentityState(src, expected)
    local current = Zfishing.Identifier(src)
    if not current then return 'gone' end
    if current ~= expected then return 'changed' end
    return 'same'
end

-- A sale whose player changed underneath it. The fish are already out of the
-- ORIGINAL player's inventory and there is nobody safe to settle against: paying
-- the replacement occupant hands a stranger another player's money, and restoring
-- into them hands a stranger another player's fish. So the transaction stops dead
-- and prints everything an admin needs to make the original player whole by hand.
--
-- Deliberately console-only. A DB economy ledger is a separate piece of work; this
-- window is a disconnect landing between two specific yields of one manual NPC
-- interaction, and the reconciliation philosophy already in place for a failed
-- payout is "one correlated record an admin can act on", not "roll it back".
--
-- Nothing was restored on this path, so everything that left the bag is still
-- outstanding: restoredValue is 0 and unreconciledValue is the whole of `removed`.
local function abortSale(sale, stage, total, removed)
    print(('[zfishing] sale aborted on identity loss saleId=%s src=%s identity=%s stage=%s expectedPayout=%d removed=%d restoredValue=0 unreconciledValue=%d')
        :format(sale.id, tostring(sale.src), ZUtil.SafeId(sale.identifier), stage, total, #removed, sumValue(removed)))
    logLostStacks(sale, stage, removed, total)
    return { ok = false, total = 0, reason = 'sale_failed' }
end

local function runSale(src, sale)
    local function samePlayer() return saleIdentityState(src, sale.identifier) == 'same' end

    -- before anything leaves the inventory
    if not samePlayer() then return abortSale(sale, 'removal', 0, {}) end

    local total, removed, swept = collectSale(src, samePlayer)
    if not swept then return abortSale(sale, 'removal', total, removed) end
    if total <= 0 then return { ok = false, total = 0 } end

    -- before money moves. The sweep's own guard cannot cover this: it stops
    -- checking once the last stack is gone, and the removals themselves yield.
    if not samePlayer() then return abortSale(sale, 'payout', total, removed) end

    if not Zfishing.AddMoney(src, total, 'fish-sale') then
        -- before the fish go back. Compensation is an AddItem to `src`, so a src
        -- that changed hands during the failed payout would have the original
        -- player's fish materialise in the replacement occupant's bag.
        if not samePlayer() then return abortSale(sale, 'compensation', total, removed) end

        local comp = restoreSale(src, removed, samePlayer)
        print(('[zfishing] sale payout failed saleId=%s src=%s identity=%s expectedPayout=%d removed=%d restored=%d restoreFailed=%d restoredValue=%d unreconciledValue=%d identityLost=%s')
            :format(sale.id, tostring(sale.src), ZUtil.SafeId(sale.identifier), total, #removed,
                #comp.restored, #comp.failed, comp.restoredValue, comp.unreconciledValue,
                tostring(comp.identityLost)))
        -- the only paths where a player is actually down fish with nothing to show
        -- for it. Two distinct stages, because an admin reads them differently:
        --   restore_failed   the inventory refused the stack -- the player is still
        --                    here, and it can be handed back by hand
        --   restore_aborted  the src changed owner mid-compensation, so the rest was
        --                    deliberately NOT handed back; the player who is owed it
        --                    is gone and is named only by `identity=`
        logLostStacks(sale, 'restore_failed', comp.failed, total)
        logLostStacks(sale, 'restore_aborted', comp.remaining, total)
        -- Identity loss collapses to the same generic outcome every other guard
        -- uses: the client on the other end of this callback may not even be the
        -- player who opened the sale, so it is not told that a payout failed.
        return { ok = false, total = 0, reason = comp.identityLost and 'sale_failed' or 'payout_failed' }
    end

    if Zfishing.Simple() then
        Zfishing.Notify(src, 'Sold at standard weight -- this inventory has no per-catch weight', 'inform')
    end
    return { ok = true, total = total }
end

lib.callback.register('zfishing:sellAll', function(src)
    if not gate.allow(src, 'sell') then return { ok = false, total = 0, reason = 'too_many_requests' } end
    if Zfishing.Blocked() then
        Zfishing.Notify(src, 'Fishing is unavailable right now', 'error')
        return { ok = false, total = 0 }
    end
    if selling[src] then return { ok = false, total = 0, reason = 'sale_busy' } end

    selling[src] = true
    -- Captured once, before the first inventory yield: every mutation boundary in
    -- runSale compares the live identifier against this one, so a src reassigned
    -- mid-transaction can never be removed from, paid, or compensated.
    local sale = { id = newSaleId(src), src = src, identifier = Zfishing.Identifier(src) }
    if type(sale.identifier) ~= 'string' then
        selling[src] = nil
        -- fail closed: with no identity to capture, no guard below can mean anything
        print(('[zfishing] sale refused: no stable identity saleId=%s src=%s'):format(sale.id, tostring(src)))
        return { ok = false, total = 0, reason = 'sale_failed' }
    end

    local ok, res = pcall(runSale, src, sale)
    selling[src] = nil

    if not ok then
        print(('[zfishing] sellAll errored saleId=%s src=%s: %s'):format(sale.id, tostring(src), tostring(res)))
        return { ok = false, total = 0, reason = 'sale_failed' }
    end
    return res
end)

-- A player who drops mid-sale never returns through the pcall above, so the lock
-- is cleared here too; without this the src would refuse every sale after a
-- reconnect onto the same server id.
AddEventHandler('playerDropped', function()
    local src = source
    selling[src] = nil
    gate.forget(src)
end)
