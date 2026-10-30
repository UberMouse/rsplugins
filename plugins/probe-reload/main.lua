-- Throwaway D2 probe: when subscriber A reloads this plugin mid-dispatch, does the OLD
-- instance's subscriber B still run in that same dispatch after PluginShutdown? Deleted once
-- answered. Not for submission.

-- The generation counter lives in PersistentDB so each reloaded instance can be told apart.
local gen = (PersistentDB:GetInt("gen") or 0) + 1
PersistentDB:Set("gen", gen)

-- Set by PluginShutdown; printed by the callbacks so a stale instance shows up.
local shutdown = false

function PluginShutdown()
    print("[D2PROBE] reload shutdown gen=" .. gen)
    shutdown = true
    Event.ServerLogic.Unsubscribe("probeReloadA")
    Event.ServerLogic.Unsubscribe("probeReloadB")
end

local aCalled = false
Event.ServerLogic.Subscribe("probeReloadA", function()
    if aCalled then return end
    aCalled = true
    -- Fire once ever, so the reloaded instance doesn't reload again.
    if PersistentDB:GetBool("fired") then return end
    PersistentDB:Set("fired", true)
    print("[D2PROBE] reload A gen=" .. gen .. " reloading")
    ExecuteConsoleCommand("prl probe-reload")
    print("[D2PROBE] reload A gen=" .. gen .. " after prl shutdown=" .. tostring(shutdown))
end)

local bCalls = 0
Event.ServerLogic.Subscribe("probeReloadB", function()
    if bCalls >= 3 then return end
    bCalls = bCalls + 1
    print("[D2PROBE] reload B gen=" .. gen .. " shutdown=" .. tostring(shutdown))
end)

print("[D2PROBE] reload loaded gen=" .. gen)
