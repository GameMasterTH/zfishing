-- Multipliers applied to a species' spawn weight given current weather / hour.
Config.Weather = {
    weather = {
        CLEAR   = { bass=1.2 },
        RAIN    = { trout=1.6, catfish=1.2 },
        THUNDER = { golden=1.5, swordfish=1.3 },
        CLOUDS  = {},
    },
    -- hour ranges: {fromHour, toHour, {species=mult}}
    time = {
        { 5, 9,   { bass=1.3 } },                     -- morning
        { 17, 20, { catfish=1.4 } },                  -- evening
        { 20, 24, { catfish=1.8 } },                  -- night
        { 0, 5,   { catfish=1.8, shark=1.2 } },
    },
}
