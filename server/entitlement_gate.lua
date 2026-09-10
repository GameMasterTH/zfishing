-- zcore_lib owns entitlement verification. This wrapper turns every bridge
-- failure into a denial, so a broken verifier cannot permit a mutation.
function RequireEntitlement(feature)
    if type(feature) ~= 'string' or feature == '' then return false end

    local ok, granted = pcall(function()
        return exports.zcore_lib:RequireEntitlement(feature)
    end)
    return ok and granted == true
end
