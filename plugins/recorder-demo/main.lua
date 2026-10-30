-- Recorder Demo: a dev plugin (not for submission) that exercises the dev recorder
-- (dev/recorder.lua, a symlink to lib/dev/) in the real client. It touches each kind of API
-- traffic the recorder captures (events, vars, the player, an inventory, PersistentDB), and
-- logs one probe line about the client's Lua environment, which the docs don't describe.

-- First, before anything else can capture the API globals: install the recorder. require
-- gives nil if dev/ isn't there, and then the plugin runs unrecorded.
local recorder = require("dev/recorder")
if recorder then recorder.install(_ENV, "recorder-demo") end

-- The event subscriptions this plugin makes: event name -> subscription name. Subscribing
-- and unsubscribing both read this table, so they can't drift apart.
local SUBS = {
    VarTransmit = "recdemoVars",
    InventoryUpdated = "recdemoInventory",
    ChatMessage = "recdemoChat",
    ServerLogic = "recdemoTick",
}

-- Defined before anything below can fail, so a failing load still unsubscribes. Direct
-- Unsubscribe calls, never an API function handed to pcall (docs/api-concepts.md).
function PluginShutdown()
    for event, name in pairs(SUBS) do
        Event[event].Unsubscribe(name)
    end
    if recorder then recorder.shutdown() end
end

-- Every console line from this plugin carries this tag, so it's easy to grep.
local function say(...)
    log("[RECDEMO]", ...)
end

---------------------------------------------------------------------------
-- Environment probe
---------------------------------------------------------------------------

-- The result of `fn` as text, or "error" if it raises (a stripped library, say).
---@param fn function
---@return string
local function try(fn)
    local ok, value = pcall(fn)
    return ok and tostring(value) or "error"
end

-- One line saying what the client gives a plugin: the Lua version, whether os and io exist
-- (and what the clock functions return), and whether a required module sees the same
-- globals as main.lua. That last one decides whether dev/recorder also records what the
-- plugin's other modules do: install() swaps the globals of the environment it is given.
local function probe()
    local hasOs = try(function()
        return os ~= nil
    end)
    local module = require("envprobe")
    say(
        "probe:",
        "_VERSION=" .. tostring(_VERSION),
        "os=" .. hasOs,
        "io=" .. try(function()
            return io ~= nil
        end),
        "os.time=" .. try(function()
            return os.time()
        end),
        "os.date=" .. try(function()
            return os.date("%Y-%m-%d %H:%M:%S")
        end),
        "os.clock=" .. try(function()
            return os.clock()
        end),
        "recorder=" .. tostring(recorder ~= nil),
        "moduleSharesEnv=" .. tostring(module ~= nil and module.env == _ENV),
        "moduleSeesSameEvent=" .. tostring(module ~= nil and module.event == Event)
    )
end

---------------------------------------------------------------------------
-- API traffic for the recorder to capture
---------------------------------------------------------------------------

-- VarPlayer vars any account has: quest points, the run toggle and the in-game clock's
-- minutes (changes every minute, so there is always something to record).
local VARS = { "QP", "OPTION_RUN", "CLOCK_TIME_DATE_MINUTES" }
local WATCHED = {}
for _, name in ipairs(VARS) do
    WATCHED[name] = true
end

-- The latest values read. Nothing uses them: the point of reading is that the recorder
-- sees the reads.
local state = {}

-- Read the vars, the player's name and how full the backpack is.
local function readState()
    if not Player.IsAvailable() then return end
    state.name = Player.GetEntity().displayName
    for _, name in ipairs(VARS) do
        state[name] = var.VarPlayer[name].value
    end
    -- Find returns an Inv, per game/inventory.html#findinvtype (the stub says Inv[]).
    local backpack = Inventory.Find(config.Inv.INV) --[[@as Inv?]]
    -- isValid, per game/inventory.html#properties (the stub says `valid`).
    ---@diagnostic disable-next-line: undefined-field
    if backpack and backpack.isValid then state.backpackUsed = backpack.usedSlotCount end
end

-- A watched var changed: re-read it through the event's VarType.
local function onVarTransmit(ev)
    local name = ev.var.configName
    if WATCHED[name] then state[name] = ev.var.value end
end

-- The backpack changed: count what's in it, slot by slot.
local function onInventoryUpdated(ev)
    if ev.inv ~= config.Inv.INV then return end
    local backpack = Inventory.Find(ev.inv) --[[@as Inv?]]
    -- isValid, per game/inventory.html#properties (the stub says `valid`).
    ---@diagnostic disable-next-line: undefined-field
    if not (backpack and backpack.isValid) then return end
    local slots = backpack:GetSlots() -- "Returns nil on failure"
    if not slots then return end
    local items = 0
    for _, slot in pairs(slots) do
        items = items + slot.count
    end
    state.backpackItems = items
end

-- Subscribed only so chat lines (with chatAccess) show up in the recording.
local function onChatMessage(_) end

-- Re-read everything every 10 server ticks (about 6 s).
local serverTicks = 0
local function onServerLogic()
    serverTicks = serverTicks + 1
    if serverTicks % 10 == 0 then readState() end
end

---------------------------------------------------------------------------
-- Start up
---------------------------------------------------------------------------

probe()

-- A PersistentDB counter: how many times this plugin has been enabled.
local enables = (PersistentDB:GetInt("enables") or 0) + 1
PersistentDB:SetInt("enables", enables)
say("enabled", enables, "times")

Event.VarTransmit.Subscribe(SUBS.VarTransmit, onVarTransmit)
Event.InventoryUpdated.Subscribe(SUBS.InventoryUpdated, onInventoryUpdated)
Event.ChatMessage.Subscribe(SUBS.ChatMessage, onChatMessage)
Event.ServerLogic.Subscribe(SUBS.ServerLogic, onServerLogic)
readState()
