Config.Equipment = {
    -- greenZone = tension safe-zone half-width bonus; rareBonus = mult to rare spawn weight
    -- durability = max wear points; degrade = points lost per cast (admin-tunable per item)
    rods = {
        fishing_rod_common    = { label='Bamboo Rod',   greenZone=0.0,  rareBonus=1.0,  durability=40,  degrade=1, level=1 },
        fishing_rod_rare      = { label='Carbon Rod',   greenZone=0.05, rareBonus=1.15, durability=80,  degrade=1, level=11 },
        fishing_rod_epic      = { label='Graphite Rod', greenZone=0.10, rareBonus=1.3,  durability=150, degrade=1, level=26 },
        fishing_rod_legendary = { label='Master Rod',   greenZone=0.15, rareBonus=1.6,  durability=300, degrade=1, level=50 },
    },
    -- drainRate = fish-energy drain speed while reeling
    reels = {
        reel_cheap    = { label='Cheap Reel',    drainRate=1.0, durability=60,  degrade=1, level=1 },
        reel_carbon   = { label='Carbon Reel',   drainRate=1.3, durability=100, degrade=1, level=15 },
        reel_electric = { label='Electric Reel', drainRate=1.7, durability=160, degrade=1, level=35 },
    },
    -- rating = max tension (kg-equiv) before line snaps; lines wear the fastest
    lines = {
        line_10 = { label='10lb Line', rating=10, durability=30,  degrade=2, level=1 },
        line_20 = { label='20lb Line', rating=20, durability=50,  degrade=2, level=8 },
        line_40 = { label='40lb Line', rating=40, durability=80,  degrade=2, level=20 },
        line_60 = { label='60lb Line', rating=60, durability=120, degrade=2, level=40 },
    },
    -- hookMod = extra hook-window multiplier; smaller hook = harder but more rare bites
    hooks = {
        hook_2 = { label='Size 2 Hook', hookMod=1.2,  rareBonus=1.0,  durability=40,  degrade=1, level=1 },
        hook_4 = { label='Size 4 Hook', hookMod=1.0,  rareBonus=1.1,  durability=60,  degrade=1, level=5 },
        hook_6 = { label='Size 6 Hook', hookMod=0.85, rareBonus=1.2,  durability=90,  degrade=1, level=18 },
        hook_8 = { label='Size 8 Hook', hookMod=0.7,  rareBonus=1.35, durability=130, degrade=1, level=30 },
    },
    floats = {
        float_wood  = { label='Wood Float',  biteSpeed=1.0,  durability=50,  degrade=1, level=1 },
        float_foam  = { label='Foam Float',  biteSpeed=1.15, durability=80,  degrade=1, level=6 },
        float_smart = { label='Smart Float', biteSpeed=1.3,  durability=120, degrade=1, level=22 },
    },
    -- baits: consumed on bite. Species affinity handled via Config.Fish.baits.
    baits = {
        worm={label='Worm'}, minnow={label='Minnow'}, shrimp={label='Shrimp'},
        insect={label='Insect'}, chicken_liver={label='Chicken Liver'},
        spinner={label='Spinner'}, jig={label='Jig'}, crankbait={label='Crankbait'},
        topwater={label='Topwater'},
    },
}
