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
-- The bridge subscribes each event in protocol.LOAD_EVENTS once, here at load, and unsubscribes
-- them in PluginShutdown. Each handler forwards its event (the FORWARDED ones), does the
-- bridge's own work (Logic), then calls the eval probes on that event (eval.lua), which are
-- table entries. A probe on any other event in protocol.PROBE_EVENTS needs that event's
-- handler at the client. Adding the event's first probe or removing its
-- last only records whether it is wanted; the bridge's own Logic handler makes the client
-- match on its next tick (reconcileLazy), so a lazy probe receives from the next Logic tick
-- on. Every lazy Subscribe and Unsubscribe thus runs inside Logic, the only place both were
-- seen to work live, never inside another event's dispatch (a probe callback's). An internal
-- error stops the bridge by making every handler a no-op; a reset just clears the probes and
-- the scratch env.
--
-- Every Event.<X>.Subscribe and Unsubscribe here is a direct call, and no API function or
-- method is passed straight to pcall but ExecuteConsoleCommand (seen safe live). All seven
-- client aborts seen on 2026-10-26 passed Unsubscribe straight to pcall (docs/api-concepts.md,
-- "Runtime limits we've hit"), so never write `pcall(Event.X.Unsubscribe, name)`.
--
-- Chat forwarding is limited to the player's own lines, system messages and senderless SPAM
-- (protocol.lua). System text is forwarded as-is, so it can still name other players. These
-- filters cover only the events forwarded here, not what an eval snippet returns or emits.

local protocol = require("protocol")
-- dev/ is a symlink to lib/dev (the dev recorder's modules); require gives nil without it.
local recording = assert(require("dev/recording"), "dev/ (a link to lib/dev) is missing")
local batch = assert(require("dev/batch"), "dev/ (a link to lib/dev) is missing")
local post = assert(require("dev/post"), "dev/ (a link to lib/dev) is missing")
local payloads = assert(require("dev/payloads"), "dev/ (a link to lib/dev) is missing")
local eval = assert(require("eval"), "eval.lua is missing")

local SYNC_PATH = "/bridge/sync"
-- protocol.FORWARDED as a set, for the handler's lookup.
local FORWARDED = {}
for _, event in ipairs(protocol.FORWARDED) do
    FORWARDED[event] = true
end

---------------------------------------------------------------------------
-- State (one per enable: the client runs main.lua afresh each time)
---------------------------------------------------------------------------

-- An opaque userdata in the client: never concatenated or formatted.
local url = batch.manifestUrl(Plugin.urls, "rsdev") ---@type PluginURL?
-- Tells this enable's syncs apart from another's.
local session = batch.newSession()

local tick = 0 -- the last Logic tick seen; events are stamped with it
local seq = 0 -- syncs started
local nextSync = 0 -- the tick the next sync may start at
local buffer = batch.newBuffer() -- encoded events waiting to be sent
local dropped = 0 -- events lost so far: buffer full, or in a sync the daemon never got
local queue = {} -- commands from the daemon not yet run, oldest first
local results = {} -- results not yet sent, encoded (protocol.resultEntry)
local inFlight = nil ---@type { post: { request: HTTPRequest, body: string }, count: integer, results: string[], done: boolean }?
-- Set by stop(): every handler of ours does nothing from then on, so no probe runs either.
-- Stopping makes no client call; PluginShutdown unsubscribes everything.
local stopped = false

-- The lazy subscriptions, for probe-able events outside LOAD_EVENTS: lazyWanted holds those
-- with probes, lazySubscribed those whose handler is subscribed at the client. They differ only
-- until the next Logic tick (reconcileLazy). Both are sets keyed by event, so neither can grow
-- past protocol.PROBE_EVENTS.
local lazyWanted = {} ---@type table<string, true>
local lazySubscribed = {} ---@type table<string, true>
-- Set when lazyWanted changes, so a Logic tick with nothing to reconcile costs one read.
local lazyChanged = false

-- So the console isn't flooded: each of these is logged once (failing, once per outage).
local warned = { waiting = false, dropped = false, forward = false }
local failing = false
local connected = false

local say ---@type fun(...) -- defined below push: say and noteDropped call each other
-- Defined with the handlers below, which it subscribes; onLogic calls it.
local reconcileLazy ---@type fun()

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
    local lost = batch.push(buffer, entry, protocol.limits.bufferBytes)
    if lost > 0 then noteDropped(lost, "buffer full") end
end

-- Log a tagged console line, and send it to the daemon as a Log event too.
say = function(...)
    log(protocol.TAG, ...)
    push(protocol.logEntry(tick, "log", batch.joined(...)))
end

local LOAD_SET = {}
for _, event in ipairs(protocol.LOAD_EVENTS) do
    LOAD_SET[event] = true
end

-- `event` has its first probe: want its handler at the client from the next Logic tick, unless
-- it is a load-time event or the bridge has stopped. No client call here: this runs inside a
-- snippet or a probe callback, which may be inside another event's dispatch.
---@param event string
local function firstProbe(event)
    if stopped or LOAD_SET[event] then return end
    lazyWanted[event] = true
    lazyChanged = true
end

-- `event` has no probes left: stop wanting its handler. No client call here either.
---@param event string
local function noProbes(event)
    if lazyWanted[event] then
        lazyWanted[event] = nil
        lazyChanged = true
    end
end

local evaluator = eval.new({
    push = push,
    tick = function()
        return tick
    end,
    firstProbe = firstProbe,
    noProbes = noProbes,
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
        if stopped then return end
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
        say("reset " .. command.id .. ": probes and scratch env cleared")
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
        say("command " .. command.id .. " failed: " .. batch.text(result.error))
    end
    results[#results + 1] = protocol.resultEntry(result)
end

---------------------------------------------------------------------------
-- Syncing with the daemon
---------------------------------------------------------------------------

-- A sync that failed. If the daemon took it (`delivered`: a 200 with an unreadable reply), its
-- events and results are done with. If it refused it (`refused`: a 400, which applies nothing
-- and would refuse the same body again), they are dropped. Otherwise its events count as
-- dropped and its results go back to be sent again.
---@param sent table
---@param why string
---@param delivered boolean
---@param refused boolean?
local function syncFailed(sent, why, delivered, refused)
    if refused then
        if sent.count > 0 then noteDropped(sent.count, "daemon refused the sync (400)") end
    elseif not delivered then
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
    local request = sent.post.request
    if not (request.successful and request.responseCode == 200) then
        local why = batch.failureText(request)
        return syncFailed(sent, why, false, request.responseCode == 400)
    end
    if type(request.data) ~= "string" then return syncFailed(sent, "reply had no body", true) end
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
    local events = batch.take(buffer, protocol.limits.syncBytes)
    local sending, rest = protocol.takeResults(results, protocol.limits.resultBytes)
    results = rest
    seq = seq + 1
    local body = protocol.syncBody({
        session = session,
        seq = seq,
        dropped = dropped,
        hello = HELLO,
    }, events, sending)
    -- post.startPost keeps the request and body referenced in `pending.post` until the request
    -- finishes (dev/post.lua). The callback only marks it done; Logic handles it.
    local pending = { count = #events, results = sending, done = false }
    local started, err
    if url then
        started, err = post.startPost(HTTPRequest, url, SYNC_PATH, body, function()
            pending.done = true
        end)
    else
        err = "the manifest has no urls.rsdev"
    end
    if started then
        pending.post = started
        inFlight = pending
    else
        syncFailed(pending, "could not start the request: " .. tostring(err), false)
    end
end

-- The subscription name of the lazy subscription for `event`.
---@param event string
---@return string
local function probeSubscriptionName(event)
    return "devBridgeProbe" .. event
end

-- The bridge's own work each Logic tick: bring the lazy subscriptions in line with the probes
-- (before running a command, so a probe added on one tick goes live on the next), finish a
-- sync, run a command, start a sync.
local function onLogic(ev)
    tick = ev.logicTick
    if lazyChanged then reconcileLazy() end
    if inFlight and inFlight.done then finishSync() end
    runOne()
    if stopped then return end
    if inFlight or tick < nextSync then return end
    if not Plugin.HasPermission(PluginPermissions.httpAccess) then
        if not warned.waiting then
            warned.waiting = true
            say("waiting for httpAccess " .. batch.permissionHint(protocol.PLUGIN))
        end
        return
    end
    startSync()
end

---------------------------------------------------------------------------
-- Start and stop
---------------------------------------------------------------------------

-- Stop everything from inside a callback: our handlers become no-ops, the probes are
-- cleared, and any sync in flight is cancelled. Nothing is unsubscribed (clearing the probes
-- only empties lazyWanted, which a stopped onLogic never reconciles); PluginShutdown does it.
-- Safe to call twice (an error stop, then shutdown).
local function stop()
    if stopped then return end
    stopped = true
    evaluator.clear()
    -- post.cancel runs the API call from a Lua closure under pcall: an API method passed
    -- straight to pcall is the shape behind every client abort (docs/api-concepts.md, "Runtime
    -- limits we've hit"), and a raise must not skip the "stopped" message.
    post.cancel(inFlight and inFlight.post)
    inFlight = nil
end

-- A bug in the bridge would otherwise raise on every delivery and flood the console, so the
-- first error stops it.
---@param err any
local function fail(err)
    stop()
    say("stopped after an error (`prl dev-bridge` from the console restarts it):", err)
end

local probes = evaluator.probes

-- The bridge's one handler for `event`: forward it (FORWARDED), do the bridge's work (Logic),
-- then call the event's probes. With no probes on it, that last step is one table read.
---@param event string
---@return fun(payload: any)
local function handler(event)
    local forwarding = FORWARDED[event] and forwarder(event)
    local work = event == "Logic" and onLogic or nil
    return function(payload)
        if stopped then return end
        if forwarding then forwarding(payload) end
        if work then
            local ok, err = pcall(work, payload)
            if not ok then return fail(err) end
            -- A command (`prl dev-bridge`) may have shut the bridge down.
            if stopped then return end
        end
        if probes[event] == nil then return end
        local ok, err = pcall(evaluator.fanOut, event, payload)
        if not ok then fail(err) end
    end
end

-- The subscription name for a load-time `event`, the same at load and in PluginShutdown.
---@param event string
---@return string
local function subscriptionName(event)
    return "devBridge" .. event
end

-- Make the client's lazy subscriptions match lazyWanted, by direct calls in PROBE_EVENTS order.
-- Only onLogic calls this, so an event whose probes went and came back (or came and went)
-- between two ticks costs no client call. lazySubscribed is set after a Subscribe and cleared
-- before an Unsubscribe, so if one raises (stopping the bridge) PluginShutdown doesn't redo it.
reconcileLazy = function()
    lazyChanged = false
    for _, event in ipairs(protocol.PROBE_EVENTS) do
        if lazyWanted[event] and not lazySubscribed[event] then
            Event[event].Subscribe(probeSubscriptionName(event), handler(event))
            lazySubscribed[event] = true
        elseif lazySubscribed[event] and not lazyWanted[event] then
            lazySubscribed[event] = nil
            Event[event].Unsubscribe(probeSubscriptionName(event))
        end
    end
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

-- The bridge's own subscriptions, in protocol.LOAD_EVENTS order.
for _, event in ipairs(protocol.LOAD_EVENTS) do
    Event[event].Subscribe(subscriptionName(event), handler(event))
end
say("enabled, session " .. session)

-- Unsubscribe every live lazy subscription (one wanted but not yet reconciled was never made),
-- then the six load-time ones. Each is a direct call, never under pcall: Unsubscribe passed to
-- pcall aborts the client (docs/api-concepts.md). One raising skips the rest, which would mean
-- a broken client anyway.
function PluginShutdown()
    stop()
    for _, event in ipairs(protocol.PROBE_EVENTS) do
        if lazySubscribed[event] then
            lazySubscribed[event] = nil
            Event[event].Unsubscribe(probeSubscriptionName(event))
        end
    end
    for _, event in ipairs(protocol.LOAD_EVENTS) do
        Event[event].Unsubscribe(subscriptionName(event))
    end
end
