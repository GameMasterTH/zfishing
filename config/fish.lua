Config.Fish = {
    bass      = { label='Bass',       water={'lake','river'},         weight={min=0.5, max=5.0},   rarity='common',    price=8,   baits={'worm','minnow'},    behavior='steady_light', xp=10 },
    trout     = { label='Trout',      water={'river','lake'},         weight={min=0.3, max=8.0},   rarity='common',    price=10,  baits={'insect','worm'},    behavior='steady_light', xp=12 },
    catfish   = { label='Catfish',    water={'river','swamp','dam'},  weight={min=2.0, max=20.0},  rarity='uncommon',  price=14,  baits={'chicken_liver'},    behavior='steady_heavy', xp=20 },
    salmon    = { label='Salmon',     water={'river','ocean'},        weight={min=1.0, max=15.0},  rarity='uncommon',  price=16,  baits={'shrimp','spinner'}, behavior='run_stop',     xp=22 },
    pike      = { label='Pike',       water={'lake','dam'},           weight={min=1.0, max=12.0},  rarity='uncommon',  price=18,  baits={'minnow','jig'},     behavior='erratic',      xp=24 },
    mackerel  = { label='Mackerel',   water={'ocean'},                weight={min=0.4, max=3.0},   rarity='common',    price=9,   baits={'shrimp'},           behavior='steady_light', xp=12 },
    tuna      = { label='Tuna',       water={'ocean'},                weight={min=15.0, max=80.0}, rarity='rare',      price=22,  baits={'jig','minnow'},     behavior='run_stop',     xp=40 },
    swordfish = { label='Swordfish',  water={'ocean'},                weight={min=40.0, max=200.0},rarity='epic',      price=30,  baits={'crankbait'},        behavior='run_stop',     xp=60 },
    shark     = { label='Shark',      water={'ocean'},                weight={min=80.0, max=400.0},rarity='epic',      price=28,  baits={'crankbait','jig'},  behavior='erratic',      xp=70 },
    golden    = { label='Golden Fish',water={'lake','river','ocean'}, weight={min=0.5, max=2.0},   rarity='legendary', price=500, baits={'topwater'},         behavior='erratic',      xp=200 },
}

-- rarity → base spawn weight, hook window multiplier, tension difficulty
Config.Rarity = {
    common    = { weight=100, hookMult=1.0,  tension=1.0 },
    uncommon  = { weight=45,  hookMult=0.85, tension=1.15 },
    rare      = { weight=15,  hookMult=0.7,  tension=1.3 },
    epic      = { weight=5,   hookMult=0.6,  tension=1.5 },
    legendary = { weight=1,   hookMult=0.5,  tension=1.8 },
}
