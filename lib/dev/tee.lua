-- Dev log tee (a dev tool, not for submission): sends a plugin's own console output (print and
-- log) and the errors its event callbacks raise to scripts/rsdev.py on this machine, so
-- `rsdev.py logs --plugin <name>` can show them. The client delivers console output only to
-- the console, not as a ChatMessage (docs/api-concepts.md), so a plugin has to forward it.
--
-- A plugin opts in from the first lines of its main.lua:
--
--     local tee = require("dev/tee") -- nil when dev/ isn't there
--     if tee then tee.install(_ENV, "my-plugin") end
--
-- and `if tee then tee.shutdown() end` in its PluginShutdown (see below),
-- and lists "httpAccess" in optionalPermissions and "rsdev": "http://127.0.0.1:8766" in urls.
-- install() swaps `print`, `log` and `Event` in that environment for stand-ins. print and
-- log still reach the console, and each call is also queued as a line. Event.<X>.Subscribe
-- wraps the callback: an error is queued as an `error` line and then raised again unchanged,
-- so the client reports it as it would have. Lines are POSTed in batches from the Logic event
-- only, never from an HTTP callback (starting a request in one crashed the client). With the
-- daemon down lines stay queued up to a cap (the oldest are dropped and counted) and the tee
-- retries with a growing wait; a timed-out POST is resent, so its lines can show twice in logs.
--
-- The plugin must call tee.shutdown() from its PluginShutdown, after its own Unsubscribes. It
-- unsubscribes the tee's devTeeFlush Logic subscription and cancels a request in flight. A
-- subscription left registered at unload is the suspected cause of a client segfault on
-- `prl` (docs/api-concepts.md, crash 8; unconfirmed).
--
-- Without urls.rsdev or httpAccess it logs one [TEE] line and changes nothing. A permission
-- granted later does nothing until the plugin is reloaded (`prl <name>`).
--
-- dev/remote (in-plugin eval) rides on the tee: tee.attach(run) makes it post every
-- remoteEveryTicks even with no lines, say `remote: true`, carry command results, and hand the
-- commands in the daemon's reply to `run`, one per Logic tick.
--
-- With the dev recorder too, require both modules first, then call tee.install, then
-- recorder.install: the tee wraps the real API and the recorder wraps the tee's stand-ins, so
-- the recorder still records every delivery and the tee still catches callback errors. The
-- other order would make the tee's own POSTs show up in the recording.

local teelog = require("dev/teelog")
local batch = require("dev/batch")
local post = require("dev/post")
local command = require("dev/command")

local tee = {}

-- Tunables, read on each use so a test can shrink them.
tee.limits = {
    postEveryTicks = 50, -- Logic ticks (50 a second) between batches
    retryTicks = 250, -- wait after the first failed POST; doubles with each failure in a row
    maxRetryTicks = 3000, -- ... up to this
    batchLines = 200, -- lines per POST
    batchBytes = 256 * 1024, -- encoded lines per POST (the daemon accepts 2 MB)
    bufferLines = 500, -- lines kept while they can't be sent
    bufferBytes = 256 * 1024, -- encoded lines kept while they can't be sent
    remoteEveryTicks = 25, -- Logic ticks between posts while dev/remote is attached
    resultBytes = 1024 * 1024, -- encoded results per POST; with batchBytes, under the 2 MB cap
}

-- The manifest url the batches go to: urls.rsdev in plugin.json.
local URL_NAME = "rsdev"
local PATH = "/tee"
local FLUSH_NAME = "devTeeFlush" -- the tee's own Logic subscription

-- The console function the tee's own lines use. install() points it at the real `log`, taken
-- before it is swapped, so the tee's lines are never queued themselves.
local realLog = log

local function say(...)
    realLog("[TEE]", ...)
end

---------------------------------------------------------------------------
-- State (one per plugin enable: the client loads modules afresh each time)
---------------------------------------------------------------------------

local installed = false
local active = false -- install() finished and shutdown() hasn't run
local realEvent = nil ---@type table? the real Event table, taken at install
local url = nil ---@type PluginURL?
local pluginName, session = "", ""
local http = nil ---@type table? the HTTPRequest table, taken at install
local tick = 0 -- Logic ticks since install
local queue = batch.newBuffer()
local dropped = 0 -- lines lost so far (queue full, or a batch the daemon refused)
local seq = 0 -- POSTs so far
local nextPost = 0
local failures = 0 -- POSTs in a row that failed
local warned = false -- whether this failure streak has had its console line
local inFlight = nil ---@type { post: { request: HTTPRequest, body: string }, lines: string[], results: string[] }?
-- dev/remote, when attached: runs one command, returning its encoded result.
local runner = nil ---@type (fun(cmd: { id: string, kind: string, arg: string }): string)?
local commands = {} ---@type { id: string, kind: string, arg: string }[] received, not yet run
local outbox = {} ---@type string[] encoded results not yet sent

---@param level string
---@param text string
local function push(level, text)
    local lost = batch.push(
        queue,
        teelog.encode(tick, level, text),
        tee.limits.bufferBytes,
        tee.limits.bufferLines
    )
    dropped = dropped + lost
end

-- One console line the first time a failure streak starts, so the console isn't flooded.
---@param why string
local function warnOnce(why)
    if warned then return end
    warned = true
    say(why .. "; is scripts/rsdev.py running?")
end

---------------------------------------------------------------------------
-- Stand-ins
---------------------------------------------------------------------------

-- A print/log replacement: the real call first, so the console always gets the line, then the
-- line is queued. Queueing can't fail the caller's print.
---@param level string
---@param real function
---@return function
local function consoleStandIn(level, real)
    return function(...)
        real(...)
        pcall(function(...)
            push(level, batch.joined(...))
        end, ...)
    end
end

-- `callback` wrapped to queue the error it raises and raise it again unchanged (position and
-- all: error(err, 0) adds none). What it returns passes through. The pcall'd function is a
-- Lua closure, never `callback` itself, in case that is an API function (docs/api-concepts.md).
---@param event string
---@param name string
---@param callback function
---@return function
local function guarded(event, name, callback)
    local function call(...)
        return callback(...)
    end
    return function(...)
        local results = table.pack(pcall(call, ...))
        if results[1] then return table.unpack(results, 2, results.n) end
        local err = results[2]
        pcall(function()
            push("error", string.format("Event.%s subscriber '%s': %s", event, name, tostring(err)))
        end)
        error(err, 0)
    end
end

-- Event.<Name>, with Subscribe wrapped by guarded() and the calls passed on to the real API
-- (Unsubscribe especially is never handed to pcall: that aborts the client).
---@param real any the real Event table
---@return table
local function wrapEvent(real)
    local handles = {}
    return setmetatable({}, {
        __index = function(_, event)
            if handles[event] then return handles[event] end
            local sub = real[event]
            if sub == nil then return nil end
            local handle = {
                Subscribe = function(name, callback, ...)
                    -- Plain calls, not tail calls: tail calls were seen to be safe
                    -- (docs/api-concepts.md), but nothing needs them.
                    -- A bad name or callback is passed on as given: the API reports it.
                    if type(name) == "string" and type(callback) == "function" then
                        callback = guarded(event, name, callback)
                    end
                    local r = table.pack(sub.Subscribe(name, callback, ...))
                    return table.unpack(r, 1, r.n)
                end,
                Unsubscribe = function(name, ...)
                    local r = table.pack(sub.Unsubscribe(name, ...))
                    return table.unpack(r, 1, r.n)
                end,
            }
            handles[event] = handle
            return handle
        end,
    })
end

---------------------------------------------------------------------------
-- Sending batches
---------------------------------------------------------------------------

-- Count a failure and wait longer before the next POST.
local function backOff()
    failures = failures + 1
    nextPost = tick + teelog.backoff(failures, tee.limits.retryTicks, tee.limits.maxRetryTicks)
end

-- Put a batch's lines and results that were not delivered back in front of anything queued
-- since. The line cap still applies, and what it drops is counted.
---@param lines string[]
---@param results string[]
local function giveBack(lines, results)
    dropped = dropped + batch.requeue(queue, lines, tee.limits.bufferBytes, tee.limits.bufferLines)
    table.move(outbox, 1, #outbox, #results + 1, results)
    outbox = results
end

-- Queue the commands in a reply for dev/remote. A reply cut short is dropped whole: its
-- commands count as delivered at the daemon, so `rsdev.py eval --plugin` waits them out and
-- reports no result.
---@param data any the reply body
local function takeCommands(data)
    if not runner or type(data) ~= "string" then return end
    local parsed, problem = command.parseReply(data)
    if not parsed then
        say("bad reply from the daemon: " .. tostring(problem))
        return
    end
    for _, cmd in ipairs(parsed) do
        commands[#commands + 1] = cmd
    end
    local malformed = problem --[[@as string[] ]]
    if #malformed > 0 then
        say(string.format("skipped %d malformed command line(s)", #malformed))
    end
end

-- The completion callback for a batch. It must not start a request (that crashed the client),
-- so it only settles the books; the next Logic tick posts again.
---@param finished HTTPRequest
local function onPosted(finished)
    if not active then return end -- shutdown() cancelled the batch
    local sent = assert(inFlight, "a batch is in flight")
    inFlight = nil -- the request has finished, so its body may go
    if finished.successful and finished.responseCode == 200 then
        failures, warned = 0, false
        takeCommands(finished.data)
        return
    end
    backOff()
    -- A 400 arrives failed, with responseCode 400 (live, docs/api-concepts.md).
    if finished.responseCode == 400 then
        -- The daemon applied nothing and would refuse the same lines again, so they go, and the
        -- results with them (their eval calls time out).
        dropped = dropped + #sent.lines
        warnOnce(string.format("daemon refused a batch (400), dropped %d lines", #sent.lines))
        return
    end
    giveBack(sent.lines, sent.results)
    warnOnce("POST failed: " .. batch.failureText(finished))
end

-- Send the next batch when one is due and none is in flight.
local function flush()
    assert(url and http, "install() found urls.rsdev and took HTTPRequest")
    if not active or inFlight or tick < nextPost then return end
    -- With dev/remote attached, post even with nothing to say: the reply carries its commands.
    if batch.count(queue) == 0 and not runner then return end
    nextPost = tick + (runner and tee.limits.remoteEveryTicks or tee.limits.postEveryTicks)
    if not Plugin.HasPermission(PluginPermissions.httpAccess) then return end
    local lines = batch.take(queue, tee.limits.batchBytes, tee.limits.batchLines)
    local sending = {} ---@type string[]
    if runner then
        sending, outbox = command.takeResults(outbox, tee.limits.resultBytes)
    end
    seq = seq + 1
    local body = teelog.body({
        schema = teelog.SCHEMA,
        plugin = pluginName,
        session = session,
        seq = seq,
        dropped = dropped,
    }, lines)
    if runner then
        body = batch.withField(body, "remote", "true")
        body = batch.withField(body, "results", "[" .. table.concat(sending, ",") .. "]")
    end
    -- Starting is the one step that can fail without the tee being broken; the request and body
    -- stay referenced in inFlight until it finishes (dev/post.lua).
    local pending, err = post.startPost(http, url, PATH, body, onPosted)
    if pending then
        inFlight = { post = pending, lines = lines, results = sending }
        return
    end
    -- The request never started, so no completion callback will come: free the slot, keep the
    -- lines and results for a later tick and wait out a retry.
    giveBack(lines, sending)
    backOff()
    warnOnce("could not start a POST: " .. tostring(err))
end

-- Run the oldest command dev/remote was sent, if any: one per tick, so a burst can't stack up
-- against the client's per-call time limit.
local function runCommand()
    local cmd = table.remove(commands, 1)
    if not (cmd and runner) then return end
    local ok, entry = pcall(runner, cmd)
    if ok and type(entry) == "string" then
        outbox[#outbox + 1] = entry
    else
        -- dev/remote answers its own failures with an error result, so only a broken runner
        -- gets here, and the CLI waits out this command.
        say("remote command " .. cmd.id .. " failed: " .. tostring(entry))
    end
end

local function onLogic()
    tick = tick + 1
    if not active then return end -- after shutdown() nothing may start
    runCommand()
    -- A failure here must not break the plugin's Logic event (and it would repeat every tick),
    -- so it waits out a retry. (A failed request start puts its own lines back, in flush.)
    local ok, err = pcall(flush)
    if not ok then
        nextPost = tick + tee.limits.maxRetryTicks
        warnOnce("sending failed: " .. tostring(err))
    end
end

---------------------------------------------------------------------------
-- Install and shutdown
---------------------------------------------------------------------------

-- Start teeing the plugin whose global environment is `env` (pass `_ENV` from main.lua, in its
-- first lines). `plugin` names its logs. Without urls.rsdev in the manifest, or without the
-- httpAccess permission, it logs once and changes nothing.
---@param env table
---@param plugin string
function tee.install(env, plugin)
    if installed then return end
    installed = true
    url = batch.manifestUrl(Plugin.urls, URL_NAME)
    if not url then
        say("no urls." .. URL_NAME .. " in plugin.json, so not teeing")
        return
    end
    if not Plugin.HasPermission(PluginPermissions.httpAccess) then
        say(
            "httpAccess not granted "
                .. batch.permissionHint(plugin, "`prl " .. plugin .. "`")
                .. ", so not teeing"
        )
        return
    end
    pluginName = plugin
    session = batch.newSession()
    http = env.HTTPRequest
    realLog = env.log
    realEvent = env.Event
    -- Subscribed through the real Event, so the flush isn't wrapped (and can't tee itself).
    realEvent.Logic.Subscribe(FLUSH_NAME, onLogic)
    active = true
    env.print = consoleStandIn("print", env.print)
    env.log = consoleStandIn("log", env.log)
    env.Event = wrapEvent(realEvent)
    -- Names the manifest key, not the url: a Plugin.urls value is opaque and can't be concatenated.
    say("sending this plugin's console output to urls." .. URL_NAME .. " as session " .. session)
end

-- Let dev/remote run commands over the tee's channel: `run(cmd)` runs one command
-- ({ id, kind, arg }) and returns its encoded result (dev/command.lua's resultEntry). Returns
-- false, changing nothing, when the tee isn't sending (no urls.rsdev or no httpAccess).
---@param run fun(cmd: { id: string, kind: string, arg: string }): string
---@return boolean
function tee.attach(run)
    if not active then return false end
    runner = run
    nextPost = tick -- start polling now, not after the current wait
    return true
end

-- Stop teeing: unsubscribe the tee's own Logic subscription, cancel a request in flight, and
-- drop dev/remote's runner, queued commands and unsent results (their eval calls get no
-- result). Safe to call twice, and a no-op if install() didn't finish. Call it from the plugin's
-- PluginShutdown, after its own Unsubscribes.
function tee.shutdown()
    if not active then return end
    active = false
    runner, commands, outbox = nil, {}, {}
    assert(realEvent, "install() took the real Event")
    -- A plain call statement: not passed to pcall and not a tail call (docs/api-concepts.md).
    realEvent.Logic.Unsubscribe(FLUSH_NAME)
    local sent = inFlight
    inFlight = nil
    if sent then post.cancel(sent.post) end
end

return tee
