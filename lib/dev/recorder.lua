-- Dev recorder (a dev tool, not for submission): records what a plugin does with the Client
-- Plugin API in the real client, and streams it to scripts/rsdev.py on this machine.
-- A recording shows what went wrong in the client, and is what the test harness learns from
-- (docs/testing.md, "Recordings").
--
-- A plugin opts in from the first lines of its main.lua, before it requires anything else:
--
--     local recorder = require("dev/recorder") -- nil when dev/ isn't there
--     if recorder then recorder.install(_ENV, "my-plugin") end
--     function PluginShutdown()
--         -- the plugin's own Unsubscribes, then:
--         if recorder then recorder.shutdown() end
--     end
--
-- and lists "httpAccess" in optionalPermissions and "rsdev": "http://127.0.0.1:8766" in
-- urls. install() swaps the API globals in that environment for stand-ins that forward every
-- use to the real API and note what came back: events delivered to the plugin's
-- subscriptions, reads (vars, player, inventories, configs), PersistentDB calls, permission
-- checks and the plugin's own HTTP requests. Entries are buffered and POSTed in batches from
-- the Logic event, never from an HTTP callback (starting a request in one crashed the client;
-- docs/api-concepts.md). With the receiver down, a failed batch goes back in front of the
-- buffer and is resent after a wait; once the buffer is full the oldest entries are dropped and
-- counted, and the plugin carries on.
--
-- recorder.shutdown() stops the recorder's flush and cancels a batch in flight.
--
-- The stand-ins are Lua tables, so `type()` of an API object is "table" while recording.

local json = require("dev/json")
local payloads = require("dev/payloads")
local recording = require("dev/recording")
local batch = require("dev/batch")
local post = require("dev/post")

local recorder = {}

-- Tunables, read on each use so a test can shrink them.
recorder.limits = {
    postEveryTicks = 50, -- Logic ticks (50 a second) between batches
    retryTicks = 250, -- wait after a failed POST before trying again
    batchBytes = 256 * 1024, -- encoded entries per POST
    bufferBytes = 8 * 1024 * 1024, -- encoded entries kept while they can't be sent
}

-- The manifest url the batches go to: urls.rsdev in plugin.json, the key the tee and bridge
-- use too (one daemon).
local URL_NAME = "rsdev"
local PATH = "/record"
local FLUSH_NAME = "devRecorderFlush" -- the recorder's own Logic subscription

-- Deliveries not recorded: they fire every tick or frame. Entries carry the Logic tick
-- count instead (`t`), which is all a replay needs to place them in time.
local UNLOGGED = { Logic = true, Draw = true, EntityDraw = true }

-- The real API, taken when this module loads: install() replaces these globals, and the
-- recorder's own requests and subscriptions must not record themselves.
local realEvent, realPlugin, realHTTP, realInventory = Event, Plugin, HTTPRequest, Inventory
local realLog = log

local function say(...)
    realLog("[RECORDER]", ...)
end

---------------------------------------------------------------------------
-- Recorder state (one per plugin enable: the client loads modules afresh each time)
---------------------------------------------------------------------------

local installed = false
local active = false -- install() finished subscribing the flush; cleared by shutdown()
local stopped = false -- set after an internal error; the stand-ins keep forwarding
local sendFailed = false -- set if flush raised outside starting a request; nothing more is sent
local url = nil ---@type PluginURL?
local pluginName, session = "", ""
local tick = 0 -- Logic ticks since install
local buffer = batch.newBuffer()
local dropped = 0 -- entries lost so far (buffer full while the receiver was unreachable)
local warnedDrop = false
local warnedFail = false -- whether this failure streak has had its console line
local seq = 0 -- batches sent, so the receiver can tell a new enable from a late batch
local nextPost = 0
local inFlight = nil ---@type { post: { request: HTTPRequest, body: string }, entries: string[] }?
local httpCount = 0 -- the plugin's own requests, numbered for their start/done entries

-- Encoded value last recorded per read path (and per permission), so a value the plugin
-- reads every tick is recorded only when it changes. A replay serves each read the latest
-- recorded value, so nothing is lost, unless that entry was dropped: `recordedAt` holds each
-- one's buffer index, and anything at or below `lostThrough` may have been dropped, so a read
-- deduplicated against it is recorded again. An index is the entry's place when recorded; a
-- requeued batch can land at higher ones after a drop, which also raises `lostThrough` past
-- them, so the worst case is re-recording an unchanged read, never skipping a changed one.
local lastRecorded, recordedAt = {}, {}
local lostThrough = 0

-- Recorder failures must not break the plugin: the first is logged and recording stops
-- (onLogic still sends what was buffered).
---@param fn function
local function guard(fn, ...)
    if stopped then return end
    local ok, err = pcall(fn, ...)
    if not ok then
        stopped = true
        say("recording stopped after an error (what was recorded before it is still sent):", err)
    end
end

-- One console line the first time anything is dropped, so the console isn't flooded.
---@param count integer
---@param why string
local function noteDropped(count, why)
    dropped = dropped + count
    -- Drops are always the oldest entries (the buffer's front, or a batch taken from it), so
    -- everything below the buffer's first entry counts as lost. That includes entries sent
    -- fine or still in flight, which only costs re-recording a few unchanged reads.
    lostThrough = buffer.first - 1
    if not warnedDrop then
        warnedDrop = true
        say("dropping the oldest entries (" .. why .. "); is scripts/rsdev.py running?")
    end
end

---@param entry table
local function push(entry)
    entry.t = tick
    local lost = batch.push(buffer, json.encode(entry), recorder.limits.bufferBytes)
    if lost > 0 then noteDropped(lost, "buffer full") end
end

-- Push `entry` unless `v` is what was last recorded under `key` and that entry wasn't lost.
-- scripts/recording-sanitise.py (dedup_reads) applies this rule to reads; change the two together.
---@param key string
---@param v any already serialised
---@param entry table
local function pushIfChanged(key, v, entry)
    local text = json.encode(v)
    if lastRecorded[key] == text and recordedAt[key] > lostThrough then return end
    push(entry)
    lastRecorded[key], recordedAt[key] = text, buffer.last
end

---------------------------------------------------------------------------
-- Stand-ins for API objects
---------------------------------------------------------------------------

-- Stand-in -> { real = the API object, class = a CLASSES name, path = how the plugin reached
-- it }. Weak keys, so neither table keeps an object alive.
local standInInfo = setmetatable({}, { __mode = "k" })
-- Real object -> its stand-in, so the same object always gets the same stand-in (plugins
-- compare them, and use them as table keys).
local standIns = setmetatable({}, { __mode = "k" })

---@param v any
---@return any
local function realOf(v)
    local info = standInInfo[v]
    if info then return info.real end
    return v
end

---@param v any
---@return string?
local function pathOf(v)
    local info = standInInfo[v]
    return info and info.path
end

-- What each member of a read-surface class returns, when it is an API object to wrap in
-- turn (by member name; "*" = any other non-function member). Members not listed return
-- plain values, which are recorded as reads. This covers what the test harness mocks.
local CLASSES = {
    var = { ["*"] = "VarDomain" },
    VarDomain = { ["*"] = "VarType", FromID = "VarType" },
    VarType = { baseVar = "VarType" },
    config = { ["*"] = "ConfigDomain" },
    ConfigDomain = { ["*"] = "Config", FromID = "Config" },
    Config = {},
    Player = { GetEntity = "PlayerEntity" },
    PlayerEntity = {},
    Inventory = { Find = "Inv" },
    Inv = { config = "Config", GetSlot = "InvSlot", GetSlots = "InvSlot[]" },
    InvSlot = { obj = "Config" },
    -- Event payloads: recorded whole on delivery, so reading their fields isn't recorded.
    -- Config fields still get stand-ins, so `ev.var.value` is recorded like any var read.
    Payload = {
        var = "VarType",
        inv = "Config",
        objType = "Config",
        config = "Config",
        animation = "Config",
    },
}
local QUIET = { Payload = true }

-- Configs are named the same way however the plugin reached them (var.VarPlayer.FromID(463)
-- and ev.var are both var.VarPlayer.OPTION_RUN), so a replay can serve every read of one
-- config from one key.
local CONFIG_ROOT = { VarType = "var", Config = "config" }

-- How an API object is written in an entry, given its stand-in (or the object itself).
---@param v any
---@return any
local function objectForm(v)
    local info = standInInfo[v]
    local real = info and info.real or v
    local class = info and info.class
    if CONFIG_ROOT[class] then return recording.objectData(real) end
    if class == "InvSlot" then
        return { obj = recording.objectData(real.obj), count = real.count }
    end
    -- In the client, API objects are userdata; there a config is found by its configName.
    -- (The harness's objects are tables, which faults on probing a member they lack.)
    if type(real) == "userdata" then return recording.objectData(real) end
    return recording.objectText(real)
end

---@param value any
---@return any
local function serialise(value)
    return recording.serialise(value, objectForm)
end

---@param path string
---@param value any
local function recordRead(path, value)
    local v = serialise(value)
    pushIfChanged("read:" .. path, v, { k = "read", path = path, v = v })
end

local ReadProxy = {}

-- A stand-in for `real`, an object of `class` reached by `path`. Plain values pass through.
---@param real any
---@param class string
---@param path string
---@return any
local function standIn(real, class, path)
    local kind = type(real)
    if kind ~= "table" and kind ~= "userdata" then return real end
    local existing = standIns[real]
    if existing then return existing end
    local root = CONFIG_ROOT[class]
    if root then
        local ok, canonical = pcall(function()
            return recording.configPath(root, real.typeName, real.configName)
        end)
        if ok then path = canonical end
    end
    local proxy = setmetatable({}, ReadProxy)
    standInInfo[proxy] = { real = real, class = class, path = path }
    standIns[real] = proxy
    return proxy
end

-- GetSlots(): a table of InvSlots keyed by slot, each given a stand-in; the whole list is
-- recorded as one read.
---@param slots any
---@param path string
---@return any
local function slotList(slots, path)
    if type(slots) ~= "table" then
        guard(recordRead, path, slots)
        return slots
    end
    local out = {}
    for i, slot in pairs(slots) do
        out[i] = standIn(slot, "InvSlot", recording.indexPath(path, i))
    end
    guard(recordRead, path, out)
    return out
end

-- A function member, wrapped so its result is recorded under the call's path. Called with ':'
-- (the stand-in as self) it calls the real method, otherwise the real static function; a
-- wrong call form reaches the API, which reports it.
---@param proxy table
---@param info table
---@param key any
---@param fn function
---@param class string? what the result is, if an API object
---@return function
local function wrapCall(proxy, info, key, fn, class)
    return function(...)
        local args = table.pack(...)
        local isMethod = args.n > 0 and rawequal(args[1], proxy)
        local path = recording.callPath(
            info.path,
            isMethod,
            tostring(key),
            args,
            isMethod and 2 or 1,
            pathOf
        )
        for i = 1, args.n do
            args[i] = realOf(args[i])
        end
        -- API functions return one value.
        local result = fn(table.unpack(args, 1, args.n))
        if class == "InvSlot[]" then return slotList(result, path) end
        if class then result = standIn(result, class, path) end
        if not QUIET[info.class] then guard(recordRead, path, result) end
        return result
    end
end

function ReadProxy.__index(proxy, key)
    local info = standInInfo[proxy]
    local value = info.real[key]
    local members = CLASSES[info.class]
    if type(value) == "function" then return wrapCall(proxy, info, key, value, members[key]) end
    local path = recording.memberPath(info.path, key)
    local class = members[key] or members["*"]
    -- Reaching an object (var.VarPlayer.QP) isn't recorded; reading from it is.
    if class then return standIn(value, class, path) end
    if not QUIET[info.class] then guard(recordRead, path, value) end
    return value
end

function ReadProxy.__newindex(proxy, key, value)
    standInInfo[proxy].real[key] = realOf(value)
end

function ReadProxy.__eq(a, b)
    return realOf(a) == realOf(b)
end

function ReadProxy.__tostring(proxy)
    return tostring(standInInfo[proxy].real)
end

function ReadProxy.__len(proxy)
    return #standInInfo[proxy].real
end

function ReadProxy.__pairs(proxy)
    return pairs(standInInfo[proxy].real)
end

-- Register a hand-written stand-in, so it unwraps when passed back to the API.
---@param wrapper table
---@param real any
---@param path string
---@return table
local function register(wrapper, real, path)
    standInInfo[wrapper] = { real = real, path = path }
    return wrapper
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

-- The plugin's subscription names per event, in subscription order. Only the first one's
-- deliveries are recorded, so an event with several subscribers is recorded once.
local subscribers = {}

-- An inventory's contents, read when it is added or updated: the payload only lists the
-- changed slots, and a replay needs the whole inventory to apply setInventory.
---@param invType any
---@return table?
local function inventoryContents(invType)
    -- Find returns an Inv, per game/inventory.html#findinvtype (the stub says Inv[]).
    local inv = realInventory.Find(invType) --[[@as Inv?]]
    -- isValid, per game/inventory.html#properties (the stub says `valid`).
    ---@diagnostic disable-next-line: undefined-field
    if not (inv and inv.isValid) then return nil end
    local all = inv:GetSlots() -- "Returns nil on failure"
    if not all then return nil end
    local slots = {}
    for i, slot in pairs(all) do
        slots[i] = { obj = slot.obj.id, count = slot.count }
    end
    return { size = inv.slotCount, slots = slots }
end

---@param event string
---@param payload any
local function recordEvent(event, payload)
    local data = nil
    if payload ~= nil then
        local fields = payloads[event]
        if fields then
            data = {}
            for _, field in ipairs(fields) do
                local v = payload[field]
                data[field] = (v ~= nil and CLASSES.Payload[field]) and recording.objectData(v)
                    or serialise(v)
            end
        else
            data = serialise(payload)
        end
    end
    local contents = nil
    if payload ~= nil and (event == "InventoryAdded" or event == "InventoryUpdated") then
        contents = inventoryContents(payload.inv)
    end
    push({
        k = "event",
        name = event,
        payload = data,
        op = recording.eventOp(event, data, contents),
    })
end

---@param event string
---@param name string
---@param callback function
---@return function
local function subscriber(event, name, callback)
    if UNLOGGED[event] then return callback end
    return function(payload)
        local order = subscribers[event]
        if order and order[1] == name then guard(recordEvent, event, payload) end
        return callback(standIn(payload, "Payload", "Event." .. event))
    end
end

-- Event.<Name>.Subscribe / Unsubscribe, with each callback wrapped to record deliveries.
---@param real any the real Event table
---@return table
local function wrapEvent(real)
    local handles = {}
    return register(
        setmetatable({}, {
            __index = function(_, event)
                if handles[event] then return handles[event] end
                local sub = real[event]
                if sub == nil then return nil end
                local handle = {
                    Subscribe = function(name, callback, ...)
                        if type(name) ~= "string" or type(callback) ~= "function" then
                            return sub.Subscribe(name, callback, ...) -- the API reports it
                        end
                        local result = sub.Subscribe(name, subscriber(event, name, callback), ...)
                        local order = subscribers[event] or {}
                        subscribers[event] = order
                        local known = false
                        for _, n in ipairs(order) do
                            known = known or n == name
                        end
                        if not known then order[#order + 1] = name end
                        return result
                    end,
                    Unsubscribe = function(name, ...)
                        local result = sub.Unsubscribe(name, ...)
                        for i, n in ipairs(subscribers[event] or {}) do
                            if n == name then
                                table.remove(subscribers[event], i)
                                break
                            end
                        end
                        return result
                    end,
                }
                handles[event] = register(handle, sub, "Event." .. tostring(event))
                return handle
            end,
        }),
        real,
        "Event"
    )
end

---------------------------------------------------------------------------
-- PersistentDB, permissions and the plugin's own HTTP requests
---------------------------------------------------------------------------

-- Every PersistentDB method, recorded as { k = "db", op, key, value, v }.
---@param db any the real PersistentDB
---@return table
local function wrapPersistentDB(db)
    local wrapper = {}
    return register(
        setmetatable(wrapper, {
            __index = function(_, method)
                local fn = db[method]
                if type(fn) ~= "function" then return fn end
                return function(self, ...)
                    -- Called with '.': pass it on unchanged, so the API reports it.
                    if not rawequal(self, wrapper) then return fn(self, ...) end
                    -- Pass exactly the arguments given: the client may pick an overload by
                    -- how many there are, so no trailing nils.
                    local args = table.pack(...)
                    for i = 1, args.n do
                        args[i] = realOf(args[i])
                    end
                    local result = fn(db, table.unpack(args, 1, args.n))
                    local key, value = args[1], args[2]
                    guard(function()
                        local entry = {
                            k = "db",
                            op = method,
                            key = type(key) == "string" and key or nil,
                            v = serialise(result),
                        }
                        if type(value) ~= "function" then entry.value = serialise(value) end
                        push(entry)
                    end)
                    return result
                end
            end,
        }),
        db,
        "PersistentDB"
    )
end

-- A permission's name, as OptionalPermissionChanged and the harness give it. Live, a
-- PluginPermissions value is a userdata whose tostring is a pointer (docs/api-concepts.md), so
-- the name comes from the table.
---@param permission any
---@return string
local function permissionName(permission)
    for name, value in pairs(PluginPermissions) do
        if rawequal(value, permission) then return name end
    end
    return batch.text(permission)
end

-- Plugin, with HasPermission recorded as { k = "perm", permission, v } when its answer changes.
---@param plugin any the real Plugin
---@return table
local function wrapPlugin(plugin)
    return register(
        setmetatable({}, {
            __index = function(_, key)
                local value = plugin[key]
                if key ~= "HasPermission" or type(value) ~= "function" then return value end
                return function(permission, ...)
                    local granted = value(permission, ...)
                    guard(function()
                        local name = permissionName(permission)
                        pushIfChanged(
                            "perm:" .. name,
                            granted,
                            { k = "perm", permission = name, v = granted }
                        )
                    end)
                    return granted
                end
            end,
        }),
        plugin,
        "Plugin"
    )
end

-- What a finished request came back with.
---@param id integer
---@param request any
local function recordResponse(id, request)
    push({
        k = "http",
        id = id,
        phase = "done",
        successful = request.successful,
        failed = request.failed,
        timedOut = request.timedOut,
        cancelled = request.cancelled,
        responseCode = request.responseCode,
        errorCode = request.errorCode,
        errorInfo = request.errorInfo,
        header = serialise(request.header),
        data = serialise(request.data),
    })
end

-- One of the plugin's HTTPRequests: Get/Post are recorded as { k = "http", phase = "start" },
-- and the completion callback adds a "done" entry. Callbacks get the stand-in, so a plugin
-- that compares it with its own request still finds it equal.
---@param request any the real request
---@return any
local function requestStandIn(request)
    if request == nil then return nil end
    httpCount = httpCount + 1
    local id, headers, wrapper = httpCount, {}, {}
    setmetatable(wrapper, {
        __index = function(_, key)
            local value = request[key]
            if type(value) ~= "function" then return value end
            return function(self, ...)
                if not rawequal(self, wrapper) then return value(self, ...) end
                local args = table.pack(...)
                if key == "AddHeader" then headers[tostring(args[1])] = args[2] end
                local isRequest = key == "Get" or key == "Post"
                if isRequest then
                    -- Get(onDone, onProgress) / Post(data, onDone, onProgress)
                    local first = key == "Post" and 2 or 1
                    for i = first, args.n do
                        local callback = args[i]
                        if type(callback) == "function" then
                            local isCompletion = i == first
                            args[i] = function()
                                if isCompletion then guard(recordResponse, id, request) end
                                return callback(wrapper)
                            end
                        end
                    end
                end
                local result = value(request, table.unpack(args, 1, args.n))
                if isRequest then
                    guard(function()
                        local entry = {
                            k = "http",
                            id = id,
                            phase = "start",
                            method = string.upper(key),
                            url = request.url,
                            headers = headers,
                        }
                        if key == "Post" then entry.body = serialise(args[1]) end
                        push(entry)
                    end)
                end
                return result
            end
        end,
    })
    return register(wrapper, request, "HTTPRequest")
end

---@param http any the real HTTPRequest table
---@return table
local function wrapHTTP(http)
    return register(
        setmetatable({}, {
            __index = function(_, key)
                local value = http[key]
                if key ~= "new" or type(value) ~= "function" then return value end
                return function(...)
                    return requestStandIn(value(...))
                end
            end,
        }),
        http,
        "HTTPRequest"
    )
end

---------------------------------------------------------------------------
-- Sending batches
---------------------------------------------------------------------------

-- Put a batch that was not delivered back in front of the buffer, oldest first. The buffer cap
-- still applies and what it drops (the oldest, never the newest) is counted.
---@param entries string[]
---@param why string
local function giveBack(entries, why)
    local lost = batch.requeue(buffer, entries, recorder.limits.bufferBytes)
    if lost > 0 then noteDropped(lost, why) end
    nextPost = tick + recorder.limits.retryTicks
end

-- One console line the first time a failure streak starts, so the console isn't flooded.
---@param why string
local function warnFailed(why)
    if warnedFail then return end
    warnedFail = true
    say(why .. "; resending when the receiver is back (is scripts/rsdev.py running?)")
end

-- The HTTP completion callback for a batch. It must not start a request (that crashed the
-- client), so a failure only requeues the batch; the next Logic tick posts again.
---@param finished HTTPRequest
local function onPosted(finished)
    if not active then return end -- shutdown() cancelled the request; a late completion is ignored
    local sent = assert(inFlight, "a batch is in flight")
    inFlight = nil -- the request has finished, so its body may go
    if finished.successful and finished.responseCode == 200 then
        warnedFail = false
        return
    end
    local why = "POST failed: " .. batch.failureText(finished)
    giveBack(sent.entries, why)
    warnFailed(why)
end

-- Called every Logic tick: send the next batch when one is due and none is in flight.
local function flush()
    assert(url, "install() found urls.rsdev")
    if inFlight or tick < nextPost or batch.count(buffer) == 0 then return end
    nextPost = tick + recorder.limits.postEveryTicks
    if not realPlugin.HasPermission(PluginPermissions.httpAccess) then return end
    local entries = batch.take(buffer, recorder.limits.batchBytes)
    seq = seq + 1
    local body = batch.batchBody({
        schema = recording.SCHEMA,
        plugin = pluginName,
        session = session,
        seq = seq,
        dropped = dropped,
    }, entries)
    -- Starting the request is the one step that can fail without the recorder being broken (say
    -- the client refuses a new request): that batch is requeued like a failed POST, and sending
    -- continues. Any other error in flush still reaches onLogic's pcall and stops sending.
    -- realHTTP is nil if the client only provides HTTPRequest once httpAccess is granted
    -- (undocumented); the global is there by now.
    local pending, err = post.startPost(realHTTP or HTTPRequest, url, PATH, body, onPosted)
    if pending then
        inFlight = { post = pending, entries = entries }
        return
    end
    local why = "starting the request failed: " .. tostring(err)
    giveBack(entries, why)
    warnFailed(why)
end

-- Not guard(flush): the entries just before a recording error are what explain it, so the
-- buffer keeps draining after recording stops. Only an unexpected error in flush stops sending;
-- a request that fails to start just requeues its batch.
local function onLogic()
    if not active then return end
    tick = tick + 1
    if sendFailed then return end
    local ok, err = pcall(flush)
    if not ok then
        sendFailed, stopped = true, true
        say("recording and sending stopped after an error:", err)
    end
end

---------------------------------------------------------------------------
-- Install
---------------------------------------------------------------------------

-- The globals install() replaces, and how.
local WRAPPERS = {
    Event = wrapEvent,
    Plugin = wrapPlugin,
    PersistentDB = wrapPersistentDB,
    HTTPRequest = wrapHTTP,
}
for _, name in ipairs({ "var", "config", "Player", "Inventory" }) do
    WRAPPERS[name] = function(real)
        return standIn(real, name, name)
    end
end

-- Start recording the plugin whose global environment is `env` (pass `_ENV` from main.lua,
-- before requiring anything else). `plugin` names its recordings folder. Without urls.rsdev
-- in the manifest it logs once and changes nothing. Without httpAccess it records into the
-- buffer and sends nothing until the permission is granted.
---@param env table
---@param plugin string
function recorder.install(env, plugin)
    if installed then return end
    installed = true
    url = batch.manifestUrl(realPlugin.urls, URL_NAME)
    if not url then
        say("no urls." .. URL_NAME .. " in plugin.json, so not recording")
        return
    end
    pluginName = plugin
    session = batch.newSession()
    if not realPlugin.HasPermission(PluginPermissions.httpAccess) then
        say(
            "waiting for httpAccess "
                .. batch.permissionHint(plugin)
                .. "; recording into a buffer until then"
        )
    end
    realEvent.Logic.Subscribe(FLUSH_NAME, onLogic)
    active = true
    for name, wrap in pairs(WRAPPERS) do
        local real = env[name]
        if real ~= nil then env[name] = wrap(real) end
    end
end

-- Stop recording: unsubscribe the flush and cancel a batch in flight, so a completion can't
-- reach a dead Lua state. The stand-ins keep forwarding (the plugin is unloading anyway).
-- Safe to call twice, and a no-op if install() didn't finish. Call it from the plugin's
-- PluginShutdown, after its own Unsubscribes.
function recorder.shutdown()
    if not active then return end
    active = false
    -- A plain call statement: not passed to pcall and not a tail call (docs/api-concepts.md).
    realEvent.Logic.Unsubscribe(FLUSH_NAME)
    local sent = inFlight
    inFlight = nil
    if sent then post.cancel(sent.post) end
end

return recorder
