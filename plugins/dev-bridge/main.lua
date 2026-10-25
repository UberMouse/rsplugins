-- Dev Bridge: a DEV TOOL, NEVER SUBMITTED. It runs whatever console commands and Lua
-- snippets the daemon on this machine (scripts/rsdev.py) sends it, and ExecuteConsoleCommand
-- and cheats only work on dev worlds. It lets Claude, from a terminal, drive the client
-- (`scripts/rsdev.py exec "prl chore-tracker"`), read game state and install probes
-- (`scripts/rsdev.py eval ...`, eval.lua) and watch what happens (`scripts/rsdev.py events
-- --follow`, `logs`) while you play. See README.md and docs/dev-environment.md ("Dev bridge").
--
-- Every Logic-paced sync POSTs the events seen since the last one and the results of the
-- commands run, and the reply carries new commands (exec, eval, reset), which run one per
-- Logic tick. Requests start only from Logic, never from a completion callback (that crashed
-- the client; docs/api-concepts.md). The protocol itself is in protocol.lua, the pure core.
--
-- Chat forwarding is limited to the player's own lines, system messages and senderless SPAM
-- (protocol.lua). System text is forwarded as-is, so it can still name other players. These
-- filters cover only the events forwarded here, not what an eval snippet returns or emits.

local protocol = require("protocol")
-- dev/ is a symlink to lib/dev (the dev recorder's modules); require gives nil without it.
local recording = assert(require("dev/recording"), "dev/ (a link to lib/dev) is missing")
local payloads = assert(require("dev/payloads"), "dev/ (a link to lib/dev) is missing")
local eval = assert(require("eval"), "eval.lua is missing")

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
-- Tells this enable's syncs apart from another's.
local session = recording.newSession()

local tick = 0 -- the last Logic tick seen; events are stamped with it
local seq = 0 -- syncs started
local nextSync = 0 -- the tick the next sync may start at
local buffer = recording.newBuffer() -- encoded events waiting to be sent
local dropped = 0 -- events lost so far: buffer full, or in a sync the daemon never got
local queue = {} -- commands from the daemon not yet run, oldest first
local results = {} -- results not yet sent, encoded (protocol.resultEntry)
local inFlight = nil ---@type { request: HTTPRequest?, body: string, count: integer, results: string[], done: boolean }?
local stopped = false

-- So the console isn't flooded: each of these is logged once (failing, once per outage).
local warned = { waiting = false, dropped = false, forward = false }
local failing = false
local connected = false

local say ---@type fun(...) -- defined below push: say and noteDropped call each other

---@param count integer
---@param why string
local function noteDropped(count, why)
    dropped = dropped + count
    -- Set before saying, since saying buffers a Log event that may itself drop one.
    if not warned.dropped then
        warned.dropped = true
        say("losing events (" .. why .. "); the daemon sees how many as `dropped`")
    end
end

-- Buffer an encoded event for the next sync. Once the bridge has stopped, nothing will send
-- it, so it is dropped silently (a probe's Log or Emit during teardown, say).
---@param entry string
local function push(entry)
    if stopped then return end
    local lost = recording.push(buffer, entry, protocol.limits.bufferBytes)
    if lost > 0 then noteDropped(lost, "buffer full") end
end

-- Log a tagged console line, and send it to the daemon as a Log event too.
say = function(...)
    log(protocol.TAG, ...)
    push(protocol.logEntry(tick, "log", protocol.joinText(...)))
end

local evaluator = eval.new({
    push = push,
    tick = function()
        return tick
    end,
})

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

-- The local player's display name, read each time it's needed (chat is rare), or nil when
-- the player isn't available or the read fails.
---@return string?
local function ownName()
    local ok, name = pcall(function()
        if not Player.IsAvailable() then return nil end
        return Player.GetEntity().displayName
    end)
    if ok and type(name) == "string" then return name end
    return nil
end

-- The MiniMenuEntry's fields as plain data. The entry is client userdata that serialises as
-- "sol.jag::MiniMenuEntry" (seen in the client), so each field is read by name under pcall;
-- a field that raises is left out. An unreadable playerData counts as a player target.
---@param entry any
---@return table
local function entryData(entry)
    local fields = {}
    for _, field in ipairs(protocol.ENTRY_FIELDS) do
        local ok, value = pcall(function()
            return entry[field]
        end)
        if ok and (type(value) == "string" or type(value) == "number") then
            fields[field] = value
        end
    end
    local ok, hasPlayer = pcall(function()
        return entry.playerData ~= nil
    end)
    -- `ok and hasPlayer or nil` would turn a readable "no player" (false) into nil, which
    -- entryView treats as unreadable and redacts.
    if not ok then hasPlayer = nil end
    return protocol.entryView(fields, hasPlayer)
end

-- What to buffer for an event, or nil to drop it (other players' chat).
---@param name string
---@param payload any
---@return table?
local function eventData(name, payload)
    if name == "ChatMessage" then
        local data = payloadData(name, payload)
        return data and protocol.chatView(data, ownName())
    elseif name == "MiniMenuEntrySelected" then
        return payload and { entry = payload.entry ~= nil and entryData(payload.entry) or nil }
    end
    return payloadData(name, payload)
end

---@param name string
---@param payload any
local function forward(name, payload)
    local data = eventData(name, payload)
    if data == nil and name == "ChatMessage" then return end -- filtered out, not lost
    push(protocol.eventEntry(tick, name, data))
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
    local result = { ok = true }
    local refused = protocol.refusal(command)
    if refused then
        result.ok, result.error = false, refused
    elseif command.kind == "reset" then
        say("reset " .. command.id .. ": probes unsubscribed, fresh scratch env")
        evaluator.reset()
    else
        if command.kind == "eval" then
            say("eval " .. command.id)
            result = evaluator.run(command.arg)
        else
            say("exec " .. command.id .. ": " .. command.arg)
            local ok, err = pcall(ExecuteConsoleCommand, command.arg)
            if not ok then
                result.ok, result.error = false, err
            end
        end
        -- A command like `prl dev-bridge` (an exec, or ExecuteConsoleCommand in a snippet) can
        -- run PluginShutdown before it returns; the new session reports instead, so this
        -- result is never sent.
        if stopped then return end
    end
    result.id = command.id
    if not result.ok then
        say("command " .. command.id .. " failed: " .. protocol.text(result.error))
    end
    results[#results + 1] = protocol.resultEntry(result)
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

-- Start a sync: the oldest buffered events (up to syncBytes) and results (up to resultBytes).
local function startSync()
    local events = recording.take(buffer, protocol.limits.syncBytes)
    local sending, rest = protocol.takeResults(results, protocol.limits.resultBytes)
    results = rest
    seq = seq + 1
    local body = protocol.syncBody({
        session = session,
        seq = seq,
        dropped = dropped,
        hello = HELLO,
    }, events, sending)
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
    if stopped then return end
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

-- Stop everything: no more callbacks, and any sync in flight is cancelled. Safe to call twice
-- (an error stop, then PluginShutdown). Cancel runs under pcall so a raise can't skip the
-- "stopped after an error" message that follows the call. Probes go first (evaluator.stop
-- pcalls each), so they can't outlive the bridge if its own unsubscribe raises.
local function teardown()
    if stopped then return end
    stopped = true
    evaluator.stop()
    unsubscribeAll()
    if inFlight and inFlight.request then pcall(inFlight.request.Cancel, inFlight.request) end
    inFlight = nil
end

-- A bug in the bridge would otherwise raise on every tick and flood the console, so the
-- first error stops it.
local function guardedLogic(ev)
    if stopped then return end
    local ok, err = pcall(onLogic, ev)
    if ok then return end
    teardown()
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
    teardown()
end
