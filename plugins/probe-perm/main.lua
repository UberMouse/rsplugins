-- Throwaway D2 probe: does OptionalPermissionChanged fire, and with what payload?
-- Deleted once answered. Not for submission.

local NAME = "probePermChanged"

-- The callback only prints, so any dispatch oddity is down to the client, not this code.
Event.OptionalPermissionChanged.Subscribe(NAME, function(e)
    print("[D2PROBE] perm " .. tostring(e.permissionName) .. " " .. tostring(e.enabled))
end)

-- Direct call, never handed to pcall (docs/api-concepts.md).
function PluginShutdown()
    Event.OptionalPermissionChanged.Unsubscribe(NAME)
end

print("[D2PROBE] perm loaded")
