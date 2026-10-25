-- Dev Bridge: a DEV TOOL, NEVER SUBMITTED. It runs whatever console commands the daemon on
-- this machine (scripts/rsdev.py) sends it, and ExecuteConsoleCommand and cheats only work on
-- dev worlds. It lets Claude, from a terminal, drive the client (`scripts/rsdev.py exec
-- "prl chore-tracker"`) and watch what happens (`scripts/rsdev.py events --follow`) while you
-- play. See README.md and docs/dev-environment.md ("Dev bridge").
--
-- Every Logic-paced sync POSTs the events seen since the last one and the results of the
-- commands run, and the reply carries new commands, which run one per Logic tick. Requests
-- start only from Logic, never from a completion callback (that crashed the client;
-- docs/api-concepts.md). The protocol itself is in protocol.lua, the pure core.

local protocol = require("protocol")
-- dev/ is a symlink to lib/dev (the dev recorder's modules); require gives nil without it.
local recording = assert(require("dev/recording"), "dev/ (a link to lib/dev) is missing")
local payloads = assert(require("dev/payloads"), "dev/ (a link to lib/dev) is missing")

-- Every console line from this plugin carries this tag, so it's easy to grep.
local function say(...)
    log("[BRIDGE]", ...)
end

local SYNC_PATH = "/bridge/sync"
local LOGIC_NAME = "devBridgeLogic"
-- The events forwarded to the daemon, each under the subscription name "devBridge<Event>".
local FORWARDED = {
    "ChatMessage",
    "VarTransmit",
    "InventoryUpdated",
    "MiniMenuEntrySelected",
    "GameStateChanged",
}

---------------------------------------------------------------------------
-- State (one per enable: the client runs main.lua afresh each time)
---------------------------------------------------------------------------

local url = Plugin.urls.rsdev
-- Tells this enable's syncs apart from another's: a fresh table's address differs between
-- runs even if math.random is seeded the same (the dev recorder does the same).
local session = (tostring({}):match("(%x+)$") or ""):sub(-6)
    .. string.format("%04x", math.random(0, 0xffff))

local tick = 0 -- the last Logic tick seen; events are stamped with it
local seq = 0 -- syncs started
local nextSync = 0 -- the tick the next sync may start at
local buffer = recording.newBuffer() -- encoded events waiting to be sent
local dropped = 0 -- events lost so far: buffer full, or in a sync the daemon never got
local queue = {} -- commands from the daemon not yet run, oldest first
local results = {} -- results not yet sent: { id, ok, error? }
local inFlight = nil ---@type { request: HTTPRequest?, body: string, count: integer, results: table[], done: boolean }?
local stopped = false

-- So the console isn't flooded: each of these is logged once (failing, once per outage).
local warned = { waiting = false, dropped = false, forward = false }
local failing = false
local connected = false

---@param count integer
---@param why string
local function noteDropped(count, why)
    dropped = dropped + count
    if not warned.dropped then
        warned.dropped = true
        say("losing events (" .. why .. "); the daemon sees how many as `dropped`")
    end
end

---------------------------------------------------------------------------
-- The client's Lua environment, reported in every sync's hello
---------------------------------------------------------------------------

-- type() of each global in protocol.ENV_NAMES, or "error" if reading it raises.
---@return table<string, string>
local function probeEnv()
    local env = {}
    for _, name in ipairs(protocol.ENV_NAMES) do
        local ok, value = pcall(function()
            return _ENV[name]
        end)
        env[name] = ok and type(value) or "error"
    end
    return env
end

local HELLO = { version = _VERSION, env = probeEnv() }

---------------------------------------------------------------------------
-- Forwarding events
---------------------------------------------------------------------------

-- The payload as plain data: its fields by name (dev/payloads), each serialised the way the
-- dev recorder does, with API objects as { config, id, type } or their tostring() text.
---@param name string
---@param payload any
---@return table?
local function payloadData(name, payload)
    if payload == nil then return nil end
    local out = {}
    for _, field in ipairs(assert(payloads[name], "dev/payloads lists every forwarded event")) do
        out[field] = recording.serialise(payload[field], recording.objectData)
    end
    return out
end

---@param name string
---@param payload any
local function forward(name, payload)
    local entry = protocol.eventEntry(tick, name, payloadData(name, payload))
    local lost = recording.push(buffer, entry, protocol.limits.bufferBytes)
    if lost > 0 then noteDropped(lost, "buffer full") end
end

-- A subscriber that buffers `name` events. A failure loses that one event, counted as
-- dropped, rather than raising in every delivery.
---@param name string
---@return fun(payload: any)
local function forwarder(name)
    return function(payload)
        local ok, err = pcall(forward, name, payload)
        if ok then return end
        noteDropped(1, "an event could not be serialised")
        if not warned.forward then
            warned.forward = true
            say("could not forward a " .. name .. " event:", err)
        end
    end
end

---------------------------------------------------------------------------
-- Running commands
---------------------------------------------------------------------------

-- Run the oldest queued command, if any, and keep its result for the next sync.
local function runOne()
    local command = table.remove(queue, 1)
    if not command then return end
    local result = { id = command.id, ok = true }
    local refused = protocol.refusal(command)
    if refused then
        result.ok, result.error = false, refused
    else
        say("exec " .. command.id .. ": " .. command.arg)
        local ok, err = pcall(ExecuteConsoleCommand, command.arg)
        if not ok then
            result.ok, result.error = false, tostring(err)
        end
    end
    if not result.ok then say("command " .. command.id .. " failed: " .. result.error) end
    results[#results + 1] = result
end

---------------------------------------------------------------------------
-- Syncing with the daemon
---------------------------------------------------------------------------

-- A sync that failed. Unless the daemon took it (`delivered`: a 200 with an unreadable
-- reply), its events count as dropped and its results go back to be sent again.
---@param sent table
---@param why string
---@param delivered boolean
local function syncFailed(sent, why, delivered)
    if not delivered then
        if sent.count > 0 then noteDropped(sent.count, "sync failed") end
        local again = sent.results
        for _, result in ipairs(results) do
            again[#again + 1] = result
        end
        results = again
    end
    nextSync = tick + protocol.limits.retryTicks
    if not failing then
        failing = true
        say(
            string.format(
                "sync failed (%s); is scripts/rsdev.py running? Retrying every %g s",
                why,
                protocol.limits.retryTicks / 50
            )
        )
    end
end

-- Handle the sync whose request has finished: queue the reply's commands, schedule the next.
local function finishSync()
    local sent = assert(inFlight, "a sync is in flight")
    inFlight = nil -- the request has finished, so its body may go
    local request = assert(sent.request, "a sync in flight has a request")
    if not (request.successful and request.responseCode == 200) then
        local why = request.timedOut and "timed out"
            or string.format(
                "response %s, error %s %s",
                tostring(request.responseCode),
                tostring(request.errorCode),
                tostring(request.errorInfo)
            )
        return syncFailed(sent, why, false)
    end
    local commands, problem = protocol.parseReply(request.data)
    if not commands then return syncFailed(sent, tostring(problem), true) end
    local malformed = problem --[[@as string[] ]]
    if #malformed > 0 then
        say(
            string.format(
                "skipped %d malformed reply line(s), the first: %q",
                #malformed,
                malformed[1]
            )
        )
    end
    for _, command in ipairs(commands) do
        queue[#queue + 1] = command
    end
    if failing or not connected then say("connected to rsdev, session " .. session) end
    failing, connected = false, true
    nextSync = tick + protocol.limits.syncEveryTicks
end

-- Start a sync: the oldest buffered events (up to syncBytes) and every result not yet sent.
local function startSync()
    local events = recording.take(buffer, protocol.limits.syncBytes)
    local sending = results
    results = {}
    seq = seq + 1
    local body = protocol.syncBody({
        session = session,
        seq = seq,
        dropped = dropped,
        hello = HELLO,
        results = sending,
    }, events)
    -- Kept referenced until the request finishes, body included, in case the client doesn't
    -- copy it (docs/api-concepts.md). The callback only marks it done; Logic handles it.
    local pending = { body = body, count = #events, results = sending, done = false }
    local ok, err = pcall(function()
        local request = HTTPRequest.new(url, SYNC_PATH)
        request:AddHeader("Content-Type", "application/json")
        pending.request = request
        request:Post(body, function()
            pending.done = true
        end)
    end)
    if ok then
        inFlight = pending
    else
        syncFailed(pending, "could not start the request: " .. tostring(err), false)
    end
end

local function onLogic(ev)
    tick = ev.logicTick
    if inFlight and inFlight.done then finishSync() end
    runOne()
    if inFlight or tick < nextSync then return end
    if not Plugin.HasPermission(PluginPermissions.httpAccess) then
        if not warned.waiting then
            warned.waiting = true
            say("waiting for httpAccess (`ppr dev-bridge`, then `ppe dev-bridge httpAccess`)")
        end
        return
    end
    startSync()
end

---------------------------------------------------------------------------
-- Start and stop
---------------------------------------------------------------------------

local function unsubscribeAll()
    Event.Logic.Unsubscribe(LOGIC_NAME)
    for _, name in ipairs(FORWARDED) do
        Event[name].Unsubscribe("devBridge" .. name)
    end
end

-- A bug in the bridge would otherwise raise on every tick and flood the console, so the
-- first error stops it.
local function guardedLogic(ev)
    if stopped then return end
    local ok, err = pcall(onLogic, ev)
    if ok then return end
    stopped = true
    unsubscribeAll()
    say("stopped after an error (`prl dev-bridge` from the console restarts it):", err)
end

-- Grant our own permissions (the debug-plugin does the same): ppr first, since ppe on a
-- permission the plugin hasn't requested silently does nothing (docs/plugin-anatomy.md).
for _, command in ipairs({
    "ppr " .. protocol.PLUGIN,
    "ppe " .. protocol.PLUGIN .. " httpAccess",
    "ppe " .. protocol.PLUGIN .. " chatAccess",
}) do
    local ok, err = pcall(ExecuteConsoleCommand, command)
    if not ok then say("`" .. command .. "` failed:", err) end
end

Event.Logic.Subscribe(LOGIC_NAME, guardedLogic)
for _, name in ipairs(FORWARDED) do
    Event[name].Subscribe("devBridge" .. name, forwarder(name))
end
say("enabled, session " .. session)

function PluginShutdown()
    stopped = true
    unsubscribeAll()
    if inFlight and inFlight.request then inFlight.request:Cancel() end
    inFlight = nil
end
