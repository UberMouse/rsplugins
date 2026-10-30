-- Test harness for RS3 client plugins: runs a plugin's main.lua under plain Lua 5.4 against a
-- mock of the Client Plugin API, in a scripted world. See docs/testing.md.
--
--   local harness = require("tests.harness")
--   local h = harness.new("var-dump", { grant = { "httpAccess" } })
--   h.world:login("Zezima")
--   h:load()                -- runs main.lua
--   h:advance(600)          -- 30 Logic ticks and one ServerLogic
--   assert.matches("...", h:output())
--
-- This file is the shell: it owns the clock and the plugin instance, and turns world changes
-- (world.lua) into events for the mocks (api/) to dispatch. A recording can drive the same
-- world (h:useRecording, replay.lua).

local dkjson = require("dkjson")
local chat = require("tests.harness.api.chat")
local events = require("tests.harness.api.events")
local http = require("tests.harness.api.http")
local inventory = require("tests.harness.api.inventory")
local paths = require("tests.harness.paths")
local persistentdb = require("tests.harness.api.persistentdb")
local player = require("tests.harness.api.player")
local pluginApi = require("tests.harness.api.plugin")
local prettyui = require("tests.harness.api.prettyui")
local replay = require("tests.harness.replay")
local runtime = require("tests.harness.runtime")
local sandbox = require("tests.harness.sandbox")
local strict = require("tests.harness.strict")
local vars = require("tests.harness.api.vars")
local world = require("tests.harness.world")

local M = {}

-- The client's fixed logic rate (core/events.html#logic) and the server tick
-- (core/events.html#serverlogic: "approximately ... 0.6 seconds"), in logic ticks.
local LOGIC_MS = 20
local SERVER_TICK = 30

-- Enums, for test code: the sandbox's copies are only visible inside the plugin.
M.enums = {
    ChatType = chat.ChatType,
    PersistentDBType = persistentdb.PersistentDBType,
    PluginPermissions = pluginApi.PluginPermissions,
    SkillType = player.SkillType,
    ValueType = vars.ValueType,
}

local Harness = {}
Harness.__index = Harness

-- The scripted world: each method builds a world op, applies it and fires what changed.
local Builder = {}
Builder.__index = Builder

---@param plugin string|table "name" for plugins/<name>, a path containing "/", or a table of
---  inline files { ["main.lua"] = "...", ["plugin.json"] = "..." }
---@param opts table? { grant = { perm... }, budgetMs = 1000, stdlib = { os = true }, echo = false,
---  absent = { "load", ... }, randomSeed = 1, textWidth = function(fontID, text) return n end,
---  allowLeftSubscriptions = false }
---@return table h
function M.new(plugin, opts)
    opts = opts or {}
    local h = setmetatable({
        budgetMs = opts.budgetMs or 1000,
        stdlib = opts.stdlib or {},
        echo = opts.echo or false,
        -- unload() faults on subscriptions PluginShutdown left, unless a spec about leaking says so
        allowLeftSubscriptions = opts.allowLeftSubscriptions or false,
        randomState = opts.randomSeed or 1, -- random()'s generator (api/helpers.lua)
        textWidth = opts.textWidth, -- utils.CalcTextWidth's metrics, from the test
        tick = 0, -- logic ticks so far; Logic payloads carry it as logicTick
        pendingMs = 0, -- advance() time not yet a whole tick
        console = {}, -- { kind = "print"|"log", text }
        chatLog = {}, -- { message, chatType, sender } as the chat window would show them
        chatQueue = {}, -- Chat.AddMessage text waiting for the next logic step
        requests = {}, -- HTTP requests, in the order they were started
        consoleCommands = {}, -- ExecuteConsoleCommand arguments, in order
        onConsoleCommand = nil, -- set by a test: called with each console command
        absent = {}, -- globals that read nil, as in a client without them (opts.absent)
        db = {}, -- PersistentDB entries: key -> { type, value }
        dbWrites = 0, -- PersistentDB stores (Set and the typed setters) so far, across reloads
        varProxies = {},
        configProxies = {},
        instance = nil,
    }, Harness)

    if type(plugin) == "table" then
        h.label = "inline"
        h.readFile = function(file)
            return plugin[file]
        end
    else
        local root = plugin:find("/") and plugin or ("plugins/" .. plugin)
        h.label = root
        h.readFile = function(file)
            return paths.read(paths.repo(root .. "/" .. file))
        end
    end

    local manifestText = h.readFile("plugin.json")
    -- A manifest is optional during development (docs/plugin-anatomy.md).
    h.manifest = manifestText and assert(dkjson.decode(manifestText), "plugin.json is not JSON")
        or {}
    if #(h.manifest.requiredPermissions or {}) > 0 then
        error(
            "plugin.json requiredPermissions is broken in the client (the plugin doesn't run); "
                .. "use optionalPermissions (docs/plugin-anatomy.md)",
            2
        )
    end

    for _, name in ipairs(opts.absent or {}) do
        h.absent[name] = true
    end

    h.world = setmetatable({ h = h, state = world.new(h.manifest) }, Builder)
    h.ui = prettyui.driver(h)
    for _, perm in ipairs(opts.grant or {}) do
        world.apply(h.world.state, { op = "setPermission", permission = perm, enabled = true })
    end
    return h
end

-- The error message `fn` raises; fails if it doesn't raise. Use it with assert.matches when a
-- test checks the "Event.Logic subscriber 'name': file:line:" prefix, which luassert's
-- error_matches strips before matching.
---@param fn function
---@return string
function M.errorOf(fn, ...)
    local ok, err = pcall(fn, ...)
    assert(not ok, "expected an error, but the call succeeded")
    return tostring(err)
end

-- new() then load().
---@param plugin string|table
---@param opts table?
---@return table h
function M.load(plugin, opts)
    local h = M.new(plugin, opts)
    h:load()
    return h
end

---------------------------------------------------------------------------
-- Plugin lifecycle
---------------------------------------------------------------------------

-- Enable the plugin: a fresh environment, then main.lua.
function Harness:load()
    assert(not (self.instance and self.instance.alive), "plugin already loaded; use reload()")
    local instance = { alive = true, subs = {} }
    self.instance = instance
    instance.env = sandbox.build(self, instance)
    self.env = instance.env
    local source = self.readFile("main.lua")
    assert(source, self.label .. "/main.lua not found")
    -- selene: allow(incorrect_standard_library_use) -- its std has the pre-5.2 load/loadfile
    local chunk = assert(load(source, "@" .. self.label .. "/main.lua", "t", instance.env))
    -- Replaying, main.lua sees the reads recorded while it ran, and the events recorded
    -- before the first Logic tick follow it.
    replay.beforeLogic(self)
    runtime.call(self.budgetMs, "main.lua", chunk)
    replay.afterLogic(self)
end

-- Disable the plugin: call its global PluginShutdown, if any (docs/plugin-anatomy.md). From
-- then on its subscribers and pending HTTP callbacks are never called.
function Harness:unload()
    local instance = self.instance
    assert(instance and instance.alive, "plugin not loaded")
    local shutdown = rawget(instance.env, "PluginShutdown")
    -- Dead from here on, so nothing PluginShutdown triggers reaches the plugin's subscribers.
    instance.alive = false
    -- The client doesn't keep a key held on the plugin's behalf across a reload.
    self.ui:holdAlt(false)
    -- Nor is anything hovered in the plugin's next UI.
    self.ui.hovering = nil
    -- And no press is held on it.
    self.ui.pressing = nil
    -- A PluginShutdown that raises or times out is reported by runtime.call alone: the leak
    -- check below doesn't run, since a half-run shutdown leaves subscriptions by definition.
    if type(shutdown) == "function" then runtime.call(self.budgetMs, "PluginShutdown", shutdown) end
    if not self.allowLeftSubscriptions then
        local left = {}
        for event, list in pairs(instance.subs) do
            for _, entry in ipairs(list) do
                -- A removal deferred to the end of a running dispatch is already gone.
                if not entry.removed then left[#left + 1] = event .. " '" .. entry.name .. "'" end
            end
        end
        table.sort(left)
        if #left > 0 then
            -- The repo rule from crash 8 (docs/api-concepts.md), not a probed client behaviour.
            strict.fault(
                "PluginShutdown left subscriptions behind (unsubscribe each one, "
                    .. "tee.shutdown()/recorder.shutdown() included): "
                    .. table.concat(left, ", ")
            )
        end
    end
end

-- `prl <plugin>`: unload, then load into a fresh environment. PersistentDB, the world and
-- granted permissions carry over.
function Harness:reload()
    self:unload()
    self:load()
end

---------------------------------------------------------------------------
-- Time
---------------------------------------------------------------------------

-- One logic step: deliver answered HTTP requests, then queued chat messages, then snap back
-- PrettyUI roots moved by a bare SetPos (api/prettyui.lua), then fire Logic, and ServerLogic
-- every SERVER_TICK steps. The order within a step is the harness's choice;
-- the client's is undocumented. Replaying, the recording's entries for this tick go around
-- Logic, and a recording that has ServerLogic events supplies it until it ends.
function Harness:step()
    self.tick = self.tick + 1
    http.deliver(self)
    chat.flush(self)
    prettyui.step(self)
    replay.beforeLogic(self)
    events.dispatch(self, "Logic", events.payload("Logic", { logicTick = self.tick }))
    local recorded = replay.afterLogic(self)
    if not recorded and self.tick % SERVER_TICK == 0 then
        events.dispatch(self, "ServerLogic", nil)
    end
end

-- Run the client clock forward by `ms` milliseconds (whole 20 ms logic ticks; a remainder
-- carries over to the next call).
---@param ms number
function Harness:advance(ms)
    self.pendingMs = self.pendingMs + ms
    while self.pendingMs >= LOGIC_MS do
        self.pendingMs = self.pendingMs - LOGIC_MS
        self:step()
    end
end

---------------------------------------------------------------------------
-- Driving events and HTTP from a test
---------------------------------------------------------------------------

-- Fire any stub event with a payload built from `fields` (checked against the stub's
-- payload class). Use it for events the world builder doesn't model.
---@param event string e.g. "KeyDown"
---@param fields table?
function Harness:fire(event, fields)
    events.dispatch(self, event, events.payload(event, fields))
end

-- Answer an HTTP request (an entry of h.requests); it arrives on the next logic step. A
-- status of 400 or more arrives failed, as in the client.
---@param record table
---@param response table { status = 200, body = "", header = "" } | { timedOut = true } |
---  { error = "info", errorCode = n }
function Harness:respond(record, response)
    http.respond(record, response)
end

---------------------------------------------------------------------------
-- Replaying a recording (docs/testing.md, "Replaying a recording")
---------------------------------------------------------------------------

-- Drive the world from a recording: its events fire at their recorded ticks as the clock
-- runs, and reads the world can't answer get the latest recorded value. Call before load().
-- Builder calls work as usual alongside and after it, on the same world. A recording with
-- dropped entries is refused unless opts.allowDropped.
---@param source string|table a .jsonl path (repo-relative or absolute), or a list of entries
---@param opts table? { allowDropped = true }
---@return table timeline
function Harness:useRecording(source, opts)
    return replay.attach(self, source, opts)
end

-- Run the clock to the recording's last tick.
function Harness:playRecording()
    assert(self.replay, "no recording (h:useRecording)")
    while self.tick < self.replay.timeline.lastTick do
        self:step()
    end
end

-- For the mocks: a value the world doesn't hold. Replaying, the latest recorded read of
-- `key`, or a fault `unrecorded: <key>`; otherwise a fault with `message`.
---@param key string the recorder's path for the read, e.g. "var.VarPlayer.QP.value"
---@param message string? the fault when not replaying
---@return any
function Harness:recorded(key, message)
    return replay.lookup(self, key, message)
end

-- Everything the plugin printed or logged, one line per call.
---@return string
function Harness:output()
    local lines = {}
    for i, line in ipairs(self.console) do
        lines[i] = line.text
    end
    return table.concat(lines, "\n")
end

---------------------------------------------------------------------------
-- World builder (h.world)
---------------------------------------------------------------------------

-- Turn one world change into the event the client would fire.
---@param h table
---@param change table
local function fireChange(h, change)
    local e = change.event
    if e == "VarTransmit" then
        h:fire(e, {
            var = vars.proxy(h, change.domain, change.id),
            oldValue = change.old,
            newValue = change.new,
        })
    elseif e == "InventoryAdded" or e == "InventoryRemoved" then
        h:fire(e, { inv = inventory.invType(h, change.inv) })
    elseif e == "InventoryUpdated" then
        h:fire(e, { inv = inventory.invType(h, change.inv), slotsUpdated = change.slots })
    elseif e == "OptionalPermissionChanged" then
        h:fire(e, { permissionName = change.permission, enabled = change.enabled })
    elseif e == "ChatMessage" then
        chat.deliver(h, change.message, change.chatType or chat.ChatType.GENERAL, change.sender)
    else
        error("no event mapping for world change " .. tostring(e))
    end
end

-- Apply a world op (see world.lua) and fire its events.
---@param op table
function Builder:apply(op)
    for _, change in ipairs(world.apply(self.state, op)) do
        fireChange(self.h, change)
    end
end

-- Set a var by name or ID; fires VarTransmit.
---@param domain string "VarPlayer" or "VarClient"
---@param key string|integer
---@param value any
function Builder:setVar(domain, key, value)
    local op = { op = "setVar", domain = domain, value = value }
    op[type(key) == "number" and "id" or "name"] = key
    self:apply(op)
end

---@param displayName string
function Builder:login(displayName)
    assert(type(displayName) == "string", "login needs a displayName")
    self:apply({ op = "login", displayName = displayName })
end

function Builder:logout()
    self:apply({ op = "logout" })
end

-- Put the player on world tile (x, z) of `level` (default 0); fires nothing.
---@param x integer
---@param z integer
---@param level integer?
function Builder:setPosition(x, z, level)
    self:apply({ op = "setPosition", x = x, z = z, level = level or 0 })
end

-- Set a skill's level and XP. `levels` = { level, xp, gameplay?, capped?, xpCapped? }; the
-- optional ones default to level / xp.
---@param skill integer a SkillType value (harness.enums.SkillType)
---@param levels table
function Builder:setSkill(skill, levels)
    local op = { op = "setSkill", skill = skill }
    for k, v in pairs(levels) do
        op[k] = v
    end
    self:apply(op)
end

-- Give an obj the ObjType fields a test needs (name, category...).
---@param obj string|integer config name or ID
---@param fields table
function Builder:defineObj(obj, fields)
    self:apply({ op = "defineObj", obj = obj, fields = fields })
end

-- Replace an inventory's contents; fires InventoryAdded the first time, InventoryUpdated
-- (with the changed slots) after. `slots` = { [index] = { obj = "LOGS", count = 5 } }.
---@param inv string|integer config name or ID, e.g. "INV" for the backpack
---@param slots table
---@param size integer? slot count; defaults to the previous size or the highest slot given
function Builder:setInventory(inv, slots, size)
    self:apply({ op = "setInventory", inv = inv, slots = slots, size = size })
end

-- Fires InventoryRemoved; Inv objects for it become invalid.
---@param inv string|integer
function Builder:removeInventory(inv)
    self:apply({ op = "removeInventory", inv = inv })
end

-- Grant or revoke a permission the manifest requests (`ppe` / `ppd`); fires
-- OptionalPermissionChanged when it changes.
---@param permission string
function Builder:grant(permission)
    self:apply({ op = "setPermission", permission = permission, enabled = true })
end

---@param permission string
function Builder:revoke(permission)
    self:apply({ op = "setPermission", permission = permission, enabled = false })
end

-- A chat message from the server; fires ChatMessage if chatAccess is granted.
---@param message string
---@param opts table? { chatType = ChatType value (default GENERAL), sender = "Name" }
function Builder:chat(message, opts)
    opts = opts or {}
    self:apply({ op = "chat", message = message, chatType = opts.chatType, sender = opts.sender })
end

return M
