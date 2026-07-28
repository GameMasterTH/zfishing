-- Hybrid model: any water gives the default pool; these named zones override
-- the water type (and optionally restrict the species pool).
Config.DefaultWater = 'lake'   -- water type assumed for un-zoned open water
Config.Zones = {
    { name='Alamo Sea',        water='lake',  coords=vec3(1300.0, 4200.0, 30.0),   radius=600.0 },
    { name='Los Santos River', water='river', coords=vec3(-100.0, -1600.0, 20.0),  radius=400.0 },
    { name='Del Perro Pier',   water='ocean', coords=vec3(-1850.0, -1250.0, 5.0),  radius=500.0 },
}
