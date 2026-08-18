Config = {}
-- UI + notification language: name of a file in locales/ ('th', 'en', ...).
-- Set to false to follow the server-wide ox:locale convar instead.
Config.Locale = 'th'
-- true  = prompt ตอนตกปลา (equip/cancel) แสดงเป็น HUD กลางจอล่าง (NUI)
-- false = ใช้ ox_lib TextUI มุมขวาแบบเดิม
Config.PromptHud = true
Config.Keybind = 'E'                      -- start fishing near water
Config.Durability = true                  -- master toggle: gear wears out per cast (see README)
Config.RodCanBreak = false                -- true = rod hits 0 durability -> rod + all fitted parts destroyed
Config.RequireAssembly = true             -- true = fishing needs a fully assembled rod (reel/line/hook/float fitted)
Config.RateLimit = 6                      -- max successful catches per minute
Config.Timings = {
    biteMin = 4000, biteMax = 12000,      -- ms wait for bite
    hookWindow = 1500,                    -- base QTE window (modified by rarity/hook)
    hookLatency = 300,                    -- server grace for client latency
    reelTimeout = 30000,                  -- ms to finish reeling before fish escapes
}
-- Authoritative tension-minigame constants. The NUI receives these in the bite
-- payload rather than hard-coding its own copies -- the server validates claims
-- against the same numbers the client was told to play by.
Config.Minigame = {
    baseDrain = 12.0,   -- energy drained per second while the tension is in the green zone
}
Config.CastMaxDistance = 25.0             -- meters at full power
-- true  = fishing only works inside a Config.Zones entry (current default)
-- false = falls back to open water anywhere, using Config.DefaultWater as the pool
Config.RequireZone = true
Config.FreezeWhileFishing = true          -- lock player in place for the whole fishing session
Config.SellNpcs = {
    { model = `s_m_m_dockwork_01`, coords = vec4(-1817.5, -1235.6, 13.0, 133.0) },
}
-- Each catch rolls every entry independently — add a line to add new loot.
-- The item must also be registered in your inventory (see README).
Config.RareLoot = {
    { item = 'old_boot',       chance = 0.05,  label = 'Old Boot' },
    { item = 'bottle_message', chance = 0.02,  label = 'Message in a Bottle' },
    { item = 'treasure_map',   chance = 0.01,  label = 'Treasure Map' },
    { item = 'treasure_chest', chance = 0.008, label = 'Treasure Chest' },
    { item = 'pearl',          chance = 0.008, label = 'Pearl' },
    { item = 'ancient_coin',   chance = 0.006, label = 'Ancient Coin' },
    { item = 'diamond',        chance = 0.003, label = 'Diamond' },
}

-- Zone-tool marker + admin keys. Static config in this folder is the SEED for the
-- DB store (server/store.lua); after first boot the DB is the source of truth.
Config.Admin = {
    markerColor = { r = 0, g = 150, b = 255, a = 120 },
    markerHeight = 2.0,
    radiusStep = 5.0,     -- meters per scroll tick
    radiusMin = 10.0,
    radiusMax = 1000.0,
    waterTypes = { 'lake', 'river', 'ocean', 'swamp', 'dam' },
}
