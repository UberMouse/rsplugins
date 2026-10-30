-- Throwaway D2 probe: is it safe to Subscribe to other events from inside an
-- OptionalPermissionChanged callback (what var-dump's start() does)? Deleted once answered.

-- Same table pattern as var-dump so Subscribe and Unsubscribe can't drift apart.
local SUBS = {
    OptionalPermissionChanged = "probePermSubChanged",
    Logic = "probePermSubLogic",
    ServerLogic = "probePermSubServerLogic",
}

-- Guards against subscribing twice on a repeated permission event.
local started = false

-- Subscribes the tick events, each printing on its first call only.
local function start()
    if started then return end
    started = true
    local logicSeen, serverSeen = false, false
    Event.Logic.Subscribe(SUBS.Logic, function()
        if not logicSeen then
            logicSeen = true
            print("[D2PROBE] permsub logic tick")
        end
    end)
    Event.ServerLogic.Subscribe(SUBS.ServerLogic, function()
        if not serverSeen then
            serverSeen = true
            print("[D2PROBE] permsub serverlogic tick")
        end
    end)
end

Event.OptionalPermissionChanged.Subscribe(SUBS.OptionalPermissionChanged, function(e)
    print("[D2PROBE] permsub " .. tostring(e.permissionName) .. " " .. tostring(e.enabled))
    if e.enabled then start() end
end)

-- Unsubscribing a never-made subscription returns false, which is fine. Direct calls.
function PluginShutdown()
    for event, name in pairs(SUBS) do
        Event[event].Unsubscribe(name)
    end
end

print("[D2PROBE] permsub loaded")
