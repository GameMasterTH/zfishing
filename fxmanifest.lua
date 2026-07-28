fx_version 'cerulean'
game 'gta5'
lua54 'yes'
name 'zfishing'
description 'Skill-based fishing system for ZCore'
author 'ZCore'
version '1.0.0'

dependencies { 'ox_lib', 'zcore_lib', 'oxmysql' }

shared_scripts {
    '@ox_lib/init.lua',
    'shared/util.lua',
    'shared/rig_rules.lua',
    'config/main.lua',
    'config/fish.lua',
    'config/equipment.lua',
    'config/zones.lua',
    'config/weather.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/lib.lua',
    'server/store.lua',
    'server/config_schema.lua',
    'server/validate.lua',
    'server/weather.lua',
    'server/progression.lua',
    'server/generator.lua',
    'server/rewards.lua',
    'server/admin.lua',
    'server/rig.lua',
    'server/boat_anchor.lua',
    'server/session.lua',
    'server/usable.lua',
}

client_scripts {
    'client/anim.lua',
    'client/float_kinematics.lua',
    'client/water_effects.lua',
    'client/casting.lua',
    'client/store.lua',
    'client/minigame.lua',
    'client/main.lua',
    'client/rig.lua',
    'client/zone_raycast.lua',
    'client/zonetool.lua',
    'client/admin.lua',
}

ui_page 'web/dist/index.html'

files {
    'locales/*.json',
    'web/dist/index.html',
    'web/dist/assets/*.js',
    'web/dist/assets/*.css',
    'web/dist/assets/*.woff2',
    'web/dist/assets/*.woff',
    'assets/items/*.png',
}
