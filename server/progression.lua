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

function Progression.Unload(src)
    Progression.Save(src); cache[src] = nil
end

AddEventHandler('playerDropped', function()
    Progression.Unload(source)
end)

-- QA helper: grants 50 xp and reports level/xp
RegisterCommand('zfish_xp', function(src)
    if src == 0 then return end
    if not Progression.Get(src) then Progression.Load(src) end
    Progression.AddXP(src, 50)
    Progression.Save(src)
    local c = Progression.Get(src)
    exports.zcore_lib:Notify(src, ('Level %d, XP %d'):format(c.level, c.xp), 'inform')
end, false)
