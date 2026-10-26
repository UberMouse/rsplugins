-- The client's API surface, for scripts/client-surface.py: every global, the keys of each
-- namespace and enum table, and the members of the API types a snapshot can reach without
-- changing anything. Names and type() only, never values (bar enum numbers), so the result
-- holds nothing about the player.
--
-- Not part of the plugin: an eval snippet (`rsdev.py eval --file`). Run, it defines SURFACE in
-- the bridge's scratch env. SURFACE.arm() adds eval probes on common events, which note each
-- payload's members when it first arrives; SURFACE.collect() removes them and returns the
-- snapshot. The probes only read type() of each member.

-- The bridge's own env (behind the scratch env this snippet runs in), and behind that the
-- table every plugin shares (docs/api-concepts.md).
local pluginEnv = getmetatable(_ENV).__index
local shared = getmetatable(pluginEnv).__index

-- sol's own members of a usertype's metatable, not API.
local SOL_MEMBERS = { class_cast = true, class_check = true, new = true }

-- Stdlib tables: namespaces, though math's constants would read as an enum.
local LIBS = { string = true, table = true, math = true, coroutine = true }

-- Events probed for payload members: the bridge's six load-time events, and others that fire
-- in ordinary play. KeyDown/KeyUp/KeyTyped (keystrokes) and PlayerEntityAdded (other players)
-- are left out.
local PAYLOAD_EVENTS = {
    "Logic",
    "ChatMessage",
    "VarTransmit",
    "InventoryUpdated",
    "MiniMenuEntrySelected",
    "GameStateChanged",
    "InventoryAdded",
    "InventoryRemoved",
    "SkillTransmit",
    "RunEnergyTransmit",
    "RunWeightTransmit",
    "MiniMenuEntryAdded",
    "MiniMenuOpened",
    "MiniMenuClosed",
    "MiniMenuReady",
    "WindowFocusChanged",
    "NPCEntityAdded",
    "LocAdded",
    "ObjStackEntityAdded",
    "WindowSizeChanged",
}

-- `type()` of each named member of a userdata, from its metatable, or nil if it has none.
---@param v any
---@return table? members name -> type
---@return string? usertype the metatable's __name
local function members(v)
    local mt = getmetatable(v)
    if type(mt) ~= "table" then return nil, nil end
    local out = {}
    for k in pairs(mt) do
        if type(k) == "string" and not k:find("^__") and not SOL_MEMBERS[k] then
            local ok, value = pcall(function()
                return v[k]
            end)
            out[k] = ok and type(value) or "error"
        end
    end
    return out, rawget(mt, "__name")
end

-- A table's own string keys, then those of a table its metatable's __index names (where a
-- sol enum keeps its values), as name -> value. Nil when sol refuses pairs (a class table).
---@param t table
---@return table?
---@return string how: "pairs", "index" (some came through __index) or "opaque"
local function entries(t)
    local out, how = {}, "pairs"
    local ok = pcall(function()
        for k, v in pairs(t) do
            if type(k) == "string" then out[k] = v end
        end
    end)
    if not ok then return nil, "opaque" end
    local mt = getmetatable(t)
    local index = type(mt) == "table" and rawget(mt, "__index") or nil
    if type(index) == "table" then
        for k, v in pairs(index) do
            if type(k) == "string" and out[k] == nil then
                out[k], how = v, "index"
            end
        end
    end
    return out, how
end

-- `type()` of each entry of a table (see entries).
---@param t table
---@return table? keys name -> type
---@return string how
local function keys(t)
    local found, how = entries(t)
    if not found then return nil, how end
    local out = {}
    for k, v in pairs(found) do
        out[k] = type(v)
    end
    return out, how
end

-- An enum's values by name: a table whose entries are numbers, bar functions (FromID).
---@param t table
---@return table?
local function enumValues(t)
    local found = entries(t)
    if not found then return nil end
    local out, n = {}, 0
    for k, v in pairs(found) do
        if type(v) == "number" then
            out[k], n = v, n + 1
        elseif type(v) ~= "function" then
            return nil
        end
    end
    return n > 0 and out or nil
end

-- The API objects a snapshot can reach read-only, keyed by the test harness's class names.
---@return table
local function instances()
    local found = {}
    local function add(owner, get)
        local ok, v = pcall(get)
        if ok and v ~= nil then found[owner] = v end
    end
    local function layer()
        return ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
    end
    add("PlayerEntity", function()
        return Player.GetEntity()
    end)
    add("CoordGrid", function()
        return Player.GetEntity().coordGrid
    end)
    add("Inv", function()
        return Inventory.Find(config.Inv.INV)
    end)
    add("InvSlot", function()
        -- Find returns an Inv, per game/inventory.html#findinvtype (the stub says Inv[]).
        local inv = Inventory.Find(config.Inv.INV) --[[@as Inv]]
        return inv:GetSlot(1)
    end)
    add("InvType", function()
        return config.Inv.INV
    end)
    add("ObjType", function()
        return config.Obj.FromID(995)
    end)
    -- QP (quest points), in docs/vars/vars.csv.
    add("VarType", function()
        return var.VarPlayer.FromID(1297)
    end)
    add("PersistentDB", function()
        return shared.PersistentDB
    end)
    -- Made, never started.
    add("HTTPRequest", function()
        return HTTPRequest.new(Plugin.urls.rsdev)
    end)
    add("ui.Layer", layer)
    add("ui.Interfaces", function()
        return ui.Interfaces
    end)
    add("Vector2", function()
        return layer().xyGlobal
    end)
    add("PluginURL", function()
        return Plugin.urls.rsdev
    end)
    add("LuaPlugin", function()
        return rawget(pluginEnv, "__THIS_PLUGIN")
    end)
    return found
end

-- Payload members per event, and the API types reached from payloads (ev.var...).
local payloads, payloadTypes = {}, {}

-- A global, so the next eval (in the same scratch env) can call it.
-- selene: allow(unscoped_variables)
SURFACE = {}

-- Probe PAYLOAD_EVENTS until collect().
function SURFACE.arm()
    for _, name in ipairs(PAYLOAD_EVENTS) do
        Event[name].Subscribe("surface", function(ev)
            if payloads[name] or ev == nil then return end
            payloads[name] = members(ev) or keys(ev)
            for field, owner in pairs({ var = "VarType", inv = "InvType" }) do
                local ok, v = pcall(function()
                    return ev[field]
                end)
                if ok and v ~= nil and not payloadTypes[owner] then
                    payloadTypes[owner] = { members(v) }
                end
            end
        end)
    end
    return #PAYLOAD_EVENTS
end

-- Remove the probes and return the snapshot in three parts, each well under the bridge's
-- 64 KB cap on one value: { version, globals, pluginEnv, namespaces }, enums, and
-- { types, events }.
---@return table, table, table
function SURFACE.collect()
    for _, name in ipairs(PAYLOAD_EVENTS) do
        Event[name].Unsubscribe("surface")
    end
    local snapshot = {
        version = _VERSION,
        globals = {},
        pluginEnv = {},
        namespaces = {},
        enums = {},
        types = {},
        events = payloads,
    }
    -- Its own keys only: its __index is the shared table.
    for name, v in pairs(pluginEnv) do
        if type(name) == "string" then snapshot.pluginEnv[name] = type(v) end
    end
    for name, v in pairs(shared) do
        if type(name) == "string" and not name:find("^sol%.") then
            snapshot.globals[name] = type(v)
            if type(v) == "table" and name ~= "_G" and name ~= "base" then
                local enum = not LIBS[name] and enumValues(v)
                if enum then
                    snapshot.enums[name] = enum
                else
                    local found, how = keys(v)
                    snapshot.namespaces[name] = { keys = found, via = how }
                end
            end
        end
    end
    -- The real Event, not the bridge's eval proxy of it.
    snapshot.namespaces["Event.Logic"] = { keys = keys(shared.Event.Logic), via = "pairs" }
    snapshot.namespaces.Plugin = { keys = keys(Plugin), via = "pairs" }
    for owner, v in pairs(instances()) do
        local found, usertype = members(v)
        snapshot.types[owner] = { members = found, usertype = usertype }
    end
    for owner, found in pairs(payloadTypes) do
        if not snapshot.types[owner] then
            snapshot.types[owner] = { members = found[1], usertype = found[2] }
        end
    end
    local enums, types, events = snapshot.enums, snapshot.types, snapshot.events
    snapshot.enums, snapshot.types, snapshot.events = nil, nil, nil
    return snapshot, enums, { types = types, events = events }
end

return "SURFACE defined: SURFACE.arm(), then SURFACE.collect()"
