-- Package-owned view of the pinned runtime contract.
--
-- The Site Agent commits a locked runtime profile into zcore_lib. This module
-- reads the locked feature mode from that profile ONCE and caches it. zfishing
-- never probes GetResourceState, never calls a vendor inventory export directly,
-- and never silently downgrades: the mode ('enhanced-rig' | 'simple-fishing') is
-- decided ahead of time by the resolver, so gameplay either runs metadata-aware
-- enhanced behavior or gives an explicit simple-mode explanation.
--
-- Every inventory/economy call is routed through zcore_lib and the structured
-- envelope is unwrapped here, so gameplay code keeps working in plain values and
-- an adapter failure surfaces as an explicit false/nil (never a swallowed error).

Zfishing = Zfishing or {}

local MODE_ENHANCED = 'enhanced-rig'
local MODE_SIMPLE = 'simple-fishing'

local resolved = false
local mode = nil
local blocked = nil

local function resolve()
    if resolved then return end
    local success, profile = pcall(function() return exports.zcore_lib:GetProfile() end)
    if not success or type(profile) ~= 'table' or not profile.ok then
        blocked = (type(profile) == 'table' and profile.error)
            or { code = 'PROFILE_UNAVAILABLE', message = 'zcore_lib is not running or returned no runtime profile' }
        resolved = true
        print(('[zfishing] runtime profile unavailable [%s]: %s -- fishing disabled until zcore_lib is running')
            :format(blocked.code or 'BLOCKED', blocked.message or ''))
        return
    end
    local details = profile.effects.details
    if details.mode ~= MODE_ENHANCED and details.mode ~= MODE_SIMPLE then
        blocked = { code = 'MODE_UNSUPPORTED',
            message = 'locked feature mode is not one this package build supports: ' .. tostring(details.mode) }
        resolved = true
        print(('[zfishing] locked feature mode %q is unsupported by this build -- fishing disabled')
            :format(tostring(details.mode)))
        return
    end
    mode = details.mode
    resolved = true
    print(('[zfishing] runtime mode = %s (%s + %s)')
        :format(mode, details.framework.id, details.inventory.id))
    if mode == MODE_SIMPLE then
        print('[zfishing] simple-fishing mode: rod assembly and per-instance metadata are disabled; '
            .. '/fishrig explains this and fish sell at species-average weight')
    end
end

CreateThread(function()
    Wait(0) -- let zcore_lib finish its startup health check before reading the lock
    resolve()
end)

function Zfishing.Blocked() resolve(); return blocked end
function Zfishing.Mode() resolve(); return mode end
function Zfishing.Enhanced() resolve(); return mode == MODE_ENHANCED end
function Zfishing.Simple() resolve(); return mode == MODE_SIMPLE end

-- ---------------------------------------------------------------- contract calls

local function ok(res) return type(res) == 'table' and res.ok == true end
local function detail(resCall, key)
    local success, res = pcall(resCall)
    if not success or not ok(res) then return nil end
    return res.effects and res.effects.details and res.effects.details[key]
end

function Zfishing.Identifier(src)
    return detail(function() return exports.zcore_lib:GetIdentifier(src) end, 'identifier')
end

function Zfishing.HasItem(src, item, count)
    return detail(function() return exports.zcore_lib:HasItem(src, item, count or 1) end, 'hasItem') == true
end

function Zfishing.ItemCount(src, item)
    return detail(function() return exports.zcore_lib:GetItemCount(src, item) end, 'count') or 0
end

-- metadata-aware slot search; verified only in enhanced mode
function Zfishing.Search(src, items)
    return detail(function() return exports.zcore_lib:SearchItem(src, items) end, 'items') or {}
end

function Zfishing.GetSlot(src, slot)
    return detail(function() return exports.zcore_lib:GetSlot(src, slot) end, 'item')
end

function Zfishing.SetSlotMeta(src, slot, meta)
    local s, r = pcall(function() return exports.zcore_lib:SetSlotMeta(src, slot, meta) end)
    return s and ok(r)
end

function Zfishing.AddItem(src, item, count, meta)
    local s, r = pcall(function() return exports.zcore_lib:AddItem(src, item, count, meta) end)
    return s and ok(r)
end

function Zfishing.RemoveItem(src, item, count)
    local s, r = pcall(function() return exports.zcore_lib:RemoveItem(src, item, count, nil) end)
    return s and ok(r)
end

function Zfishing.RemoveItemSlot(src, item, count, slot)
    local s, r = pcall(function() return exports.zcore_lib:RemoveItemSlot(src, item, count, slot) end)
    return s and ok(r)
end

function Zfishing.AddMoney(src, amount, reason)
    local s, r = pcall(function() return exports.zcore_lib:AddMoney(src, 'cash', amount, reason) end)
    return s and ok(r)
end

function Zfishing.Notify(src, message, kind)
    pcall(function() exports.zcore_lib:Notify(src, message, kind or 'inform') end)
end
