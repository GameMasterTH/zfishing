Progression = {}
local cache = {}   -- [src] = { identifier, xp, level, stats }

-- level N needs 100 * N^1.5 cumulative xp (simple, tunable)
function Progression.LevelForXP(xp)
    local lvl = 1
    while xp >= math.floor(100 * (lvl ^ 1.5)) do
        xp = xp - math.floor(100 * (lvl ^ 1.5)); lvl = lvl + 1
    end
    return lvl
end

function Progression.Load(src)
    local id = Zfishing.Identifier(src)
    if not id then return end
    local row = MySQL.single.await('SELECT xp, level, stats FROM zfishing_players WHERE identifier = ?', { id })
    if not row then
        MySQL.insert.await('INSERT INTO zfishing_players (identifier, xp, level) VALUES (?, 0, 1)', { id })
        row = { xp = 0, level = 1, stats = nil }
    end
    cache[src] = { identifier = id, xp = row.xp, level = row.level, stats = row.stats and json.decode(row.stats) or {} }
end

function Progression.Get(src) return cache[src] end

function Progression.AddXP(src, amount)
    local c = cache[src]; if not c then return 1 end
    c.xp = c.xp + amount
    c.level = Progression.LevelForXP(c.xp)
    return c.level
end

function Progression.Save(src)
    local c = cache[src]; if not c then return end
    MySQL.update('UPDATE zfishing_players SET xp = ?, level = ?, stats = ? WHERE identifier = ?',
        { c.xp, c.level, json.encode(c.stats or {}), c.identifier })
end

-- Same write as Save, but awaited so the caller can tell whether the XP actually
-- persisted. Only the catch settlement path uses it: Save() stays fire-and-forget
-- for Unload / playerDropped / the QA command, where nobody reads the result and a
-- yielding write would be a regression risk for no gain.
--
-- Success is `affected ~= nil`, NOT `affected > 0`. oxmysql reports rows *changed*,
-- and ConfigSchema clamps a species' xp to 0..100000 -- an admin can set 0, and a
-- 0-XP catch writes identical values, which MySQL reports as 0 changed rows for a
-- write that worked. Only nil, meaning no result came back at all, is a failure.
function Progression.SaveAwait(src)
    local c = cache[src]; if not c then return false end
    local affected = MySQL.update.await(
        'UPDATE zfishing_players SET xp = ?, level = ?, stats = ? WHERE identifier = ?',
        { c.xp, c.level, json.encode(c.stats or {}), c.identifier })
    return affected ~= nil
end

function Progression.Unload(src)
    Progression.Save(src); cache[src] = nil
end

AddEventHandler('playerDropped', function()
    Progression.Unload(source)
end)

-- QA helper: grants 50 xp and reports level/xp. Admin-gated -- an ungated
-- version lets any player unlock every rod tier for free.
RegisterCommand('zfish_xp', function(src)
    if src == 0 then return end
    if not exports.zcore_lib:IsAdmin(src, 'zfishing.admin') then return end
    if not Progression.Get(src) then Progression.Load(src) end
    Progression.AddXP(src, 50)
    Progression.Save(src)
    local c = Progression.Get(src)
    exports.zcore_lib:Notify(src, ('Level %d, XP %d'):format(c.level, c.xp), 'inform')
end, false)
