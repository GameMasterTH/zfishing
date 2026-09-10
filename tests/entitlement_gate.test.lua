-- Entitlement boundary tests. The gate is deliberately tiny because every
-- mutation entrypoint depends on it being fail-closed when zcore_lib is absent
-- or unhealthy.

dofile('tests/harness.lua')

H.test('RequireEntitlement forwards the resource to zcore_lib and allows an explicit grant', function()
    H.installHost()
    local requested = {}
    _G.exports = {
        zcore_lib = {
            RequireEntitlement = function(_, feature)
                requested.feature = feature
                return true
            end,
        },
    }

    dofile('server/entitlement_gate.lua')

    H.truthy(RequireEntitlement('zfishing'))
    H.equal(requested.feature, 'zfishing')
end)

H.test('RequireEntitlement denies when zcore_lib denies or raises', function()
    H.installHost()
    _G.exports = { zcore_lib = { RequireEntitlement = function() return false end } }
    dofile('server/entitlement_gate.lua')
    H.falsy(RequireEntitlement('zfishing'), 'an explicit denial must block mutations')

    _G.exports.zcore_lib.RequireEntitlement = function() error('bridge unavailable') end
    H.falsy(RequireEntitlement('zfishing'), 'bridge failures must also block mutations')
end)

H.test('RequireEntitlement denies malformed feature names', function()
    H.installHost()
    _G.exports = { zcore_lib = { RequireEntitlement = function() return true end } }
    dofile('server/entitlement_gate.lua')

    H.falsy(RequireEntitlement(nil))
    H.falsy(RequireEntitlement(''))
end)

H.test('RequireEntitlement denies when zcore_lib has no entitlement export', function()
    H.installHost()
    _G.exports = { zcore_lib = {} }
    dofile('server/entitlement_gate.lua')

    H.falsy(RequireEntitlement('zfishing'))
end)

H.run()
