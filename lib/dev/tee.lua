-- TEMP [TEE-DBG]: diagnostic logging for the chore-tracker live check; remove once answered.
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
-- and lists "httpAccess" in optionalPermissions and "rsdev": "http://127.0.0.1:8766" in urls.
-- install() swaps `print`, `log` and `Event` in that environment for stand-ins. print and
-- log still reach the console, and each call is also queued as a line. Event.<X>.Subscribe
-- wraps the callback: an error is queued as an `error` line and then raised again unchanged,
-- so the client reports it as it would have. Lines are POSTed in batches from the Logic event
-- only, never from an HTTP callback (starting a request in one crashed the client). With the
-- daemon down the lines stay queued, up to a cap (the oldest are dropped and counted), and
-- the tee retries with a growing wait.
--
-- Without urls.rsdev or httpAccess it logs one [TEE] line and changes nothing. A permission
-- granted later does nothing until the plugin is reloaded (`prl <name>`), which keeps the
-- tee free of subscriptions made at runtime.
--
-- With the dev recorder too, require both modules first, then call tee.install, then
-- recorder.install: the tee wraps the real API and the recorder wraps the tee's stand-ins, so
-- the recorder still records every delivery and the tee still catches callback errors. The
-- other order would make the tee's own POSTs show up in the recording.

local teelog = require("dev/teelog")
local recording = require("dev/recording")

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

-- TEMP [TEE-DBG]: real log only, so a debug line is never queued or POSTed.
---@param text string
local function dbg(text)
    realLog("[TEE-DBG] " .. text)
end

---------------------------------------------------------------------------
-- State (one per plugin enable: the client loads modules afresh each time)
---------------------------------------------------------------------------

local installed = false
local url = nil ---@type string?
local pluginName, session = "", ""
local http = nil ---@type table? the HTTPRequest table, taken at install
local tick = 0 -- Logic ticks since install
local queue = teelog.newQueue()
local dropped = 0 -- lines lost so far (queue full, or a batch the daemon refused)
local seq = 0 -- POSTs so far
local nextPost = 0
local failures = 0 -- POSTs in a row that failed
local warned = false -- whether this failure streak has had its console line
local inFlight = nil ---@type { request: HTTPRequest, body: string, lines: string[] }?

---@param level string
---@param text string
local function push(level, text)
    local lost = teelog.push(
        queue,
        teelog.encode(tick, level, text),
        tee.limits.bufferLines,
        tee.limits.bufferBytes
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
            push(level, teelog.joined(...))
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

-- Event.<Name>, with Subscribe wrapped by guarded() and everything else passed to the real
-- API directly (Unsubscribe especially: handing it to pcall aborts the client).
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
                    if type(name) ~= "string" or type(callback) ~= "function" then
                        return sub.Subscribe(name, callback, ...) -- the API reports it
                    end
                    return sub.Subscribe(name, guarded(event, name, callback), ...)
                end,
                Unsubscribe = function(name, ...)
                    return sub.Unsubscribe(name, ...)
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

-- Put lines that were not delivered back in front of anything queued since; the cap still
-- applies, and what it drops is counted.
---@param lines string[]
local function giveBack(lines)
    dropped = dropped + teelog.requeue(queue, lines, tee.limits.bufferLines, tee.limits.bufferBytes)
end

-- The completion callback for a batch. It must not start a request (that crashed the client),
-- so it only settles the books; the next Logic tick posts again.
---@param finished HTTPRequest
local function onPosted(finished)
    -- TEMP [TEE-DBG]
    pcall(function()
        dbg(
            string.format(
                "POST done code=%s ok=%s timedOut=%s err=%s %s",
                tostring(finished.responseCode),
                tostring(finished.successful),
                tostring(finished.timedOut),
                tostring(finished.errorCode),
                tostring(finished.errorInfo)
            )
        )
    end)
    local sent = assert(inFlight, "a batch is in flight")
    inFlight = nil -- the request has finished, so its body may go
    if finished.successful and finished.responseCode == 200 then
        failures, warned = 0, false
        return
    end
    backOff()
    -- Not gated on `successful`: the docs don't say what it holds for a non-2xx reply.
    if finished.responseCode == 400 then
        -- The daemon applied nothing and would refuse the same lines again, so they go.
        dropped = dropped + #sent.lines
        warnOnce(string.format("daemon refused a batch (400), dropped %d lines", #sent.lines))
        return
    end
    giveBack(sent.lines)
    warnOnce(
        finished.timedOut and "POST timed out"
            or string.format(
                "POST failed: %s %s, response %s",
                tostring(finished.errorCode),
                tostring(finished.errorInfo),
                tostring(finished.responseCode)
            )
    )
end

-- Send the next batch when one is due and none is in flight.
local function flush()
    assert(url and http, "install() found urls.rsdev and took HTTPRequest")
    if inFlight or tick < nextPost or teelog.count(queue) == 0 then return end
    nextPost = tick + tee.limits.postEveryTicks
    if not Plugin.HasPermission(PluginPermissions.httpAccess) then return end
    local lines = teelog.take(queue, tee.limits.batchLines, tee.limits.batchBytes)
    seq = seq + 1
    local body = teelog.body({
        schema = teelog.SCHEMA,
        plugin = pluginName,
        session = session,
        seq = seq,
        dropped = dropped,
    }, lines)
    dbg(string.format("POST start seq=%s lines=%s bytes=%s", seq, #lines, #body)) -- TEMP [TEE-DBG]
    -- A closure, never an API function straight to pcall (that aborts the client).
    local started, err = pcall(function()
        local request = http.new(url, PATH)
        request:AddHeader("Content-Type", "application/json")
        -- Keep the request and its body referenced until it finishes, in case the client
        -- doesn't copy the body (docs/api-concepts.md).
        inFlight = { request = request, body = body, lines = lines }
        request:Post(body, onPosted)
    end)
    dbg(string.format("POST started=%s err=%s", tostring(started), tostring(err))) -- TEMP [TEE-DBG]
    if started then return end
    -- The request never started, so no completion callback will come: free the slot, keep the
    -- lines for a later tick and wait out a retry.
    inFlight = nil
    giveBack(lines)
    backOff()
    warnOnce("could not start a POST: " .. tostring(err))
end

local function onLogic()
    tick = tick + 1
    -- TEMP [TEE-DBG]
    if tick == 1 then dbg("first Logic tick") end
    if tick % 250 == 0 then
        dbg(
            string.format(
                "tick=%s queued=%s inFlight=%s nextPost=%s failures=%s seq=%s",
                tick,
                teelog.count(queue),
                tostring(inFlight ~= nil),
                nextPost,
                failures,
                seq
            )
        )
    end
    -- A failure here must not break the plugin's Logic event (and it would repeat every tick),
    -- so it waits out a retry. (A failed request start puts its own lines back, in flush.)
    local ok, err = pcall(flush)
    if not ok then
        dbg("flush raised: " .. tostring(err)) -- TEMP [TEE-DBG]
        nextPost = tick + tee.limits.maxRetryTicks
        warnOnce("sending failed: " .. tostring(err))
    end
end

---------------------------------------------------------------------------
-- Install
---------------------------------------------------------------------------

-- Start teeing the plugin whose global environment is `env` (pass `_ENV` from main.lua, in its
-- first lines). `plugin` names its logs. Without urls.rsdev in the manifest, or without the
-- httpAccess permission, it logs once and changes nothing.
---@param env table
---@param plugin string
function tee.install(env, plugin)
    if installed then return end
    installed = true
    url = recording.manifestUrl(Plugin.urls, URL_NAME)
    if not url then
        say("no urls." .. URL_NAME .. " in plugin.json, so not teeing")
        return
    end
    if not Plugin.HasPermission(PluginPermissions.httpAccess) then
        -- ppr first: ppe on a permission the plugin hasn't requested silently does nothing.
        say(
            string.format(
                "httpAccess not granted (`ppr %s`, `ppe %s httpAccess`, then `prl %s`), "
                    .. "so not teeing",
                plugin,
                plugin,
                plugin
            )
        )
        return
    end
    pluginName = plugin
    session = recording.newSession()
    http = env.HTTPRequest
    realLog = env.log
    local realEvent = env.Event
    -- Subscribed through the real Event, so the flush isn't wrapped (and can't tee itself).
    realEvent.Logic.Subscribe(FLUSH_NAME, onLogic)
    dbg("subscribed devTeeFlush") -- TEMP [TEE-DBG]
    env.print = consoleStandIn("print", env.print)
    env.log = consoleStandIn("log", env.log)
    env.Event = wrapEvent(realEvent)
    -- Names the manifest key, not the url: a Plugin.urls value is opaque and can't be concatenated.
    say("sending this plugin's console output to urls." .. URL_NAME .. " as session " .. session)
end

return tee
