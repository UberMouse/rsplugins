-- Var Dump: a dev-only tool that sends every client-readable variable to a
-- receiver running on this machine (scripts/var-dump-receiver.py).
--
--   * On enable it takes a full snapshot of VarPlayer and VarClient (including
--     their VarBits) and POSTs it to <sink>/snapshot in parts.
--   * While enabled it records every VarTransmit event and POSTs them to
--     <sink>/changes once per server tick.
--
-- Run `prl var-dump` to take a fresh snapshot. NOT for submission: dumping all
-- vars is a research tool, not a player-facing feature.

-- The event subscriptions this plugin makes (event name -> subscription name), kept in one
-- table so Subscribe and Unsubscribe can't drift apart. Some are made only once httpAccess
-- is granted.
local SUBS = {
    OptionalPermissionChanged = "varDumpPermission",
    VarTransmit = "varDumpChanges",
    ServerLogic = "varDumpFlush",
    Logic = "varDumpSnapshot",
}

-- Requests still running, mapped to their body. Holding both stops them being
-- garbage collected before the request finishes, in case the client doesn't
-- copy the body. PluginShutdown cancels them.
local inFlight = {}

-- Defined before anything below can fail, so a failing load still unsubscribes. Unsubscribing
-- a name that was never subscribed returns false (live-probed, docs/testing.md fidelity
-- ledger), so the not-yet-granted case is fine. Event calls are direct and Cancel runs in a
-- closure, never an API function handed to pcall (docs/api-concepts.md).
function PluginShutdown()
    for event, name in pairs(SUBS) do
        Event[event].Unsubscribe(name)
    end
    -- Swap so a completion firing from Cancel clears the new table, not the one being walked,
    -- and `running` keeps every body referenced until the cancels finish.
    local running = inFlight
    inFlight = {}
    for request in pairs(running) do
        pcall(function()
            request:Cancel()
        end)
    end
end

-- dev/ is the symlink to lib/dev shared with the other dev tools, and must be present for the
-- plugin to load. If the client rejects symlinks, copy instead (docs/testing.md, "Opting a
-- plugin in").
local json = require("dev/json")
local recording = require("dev/recording")

-- Every console line from this plugin carries this tag, so it's easy to grep.
local function say(...)
    log("[VARDUMP]", ...)
end

-- Var domains the API currently exposes (others are "currently unavailable").
local DOMAINS = { "VarPlayer", "VarClient" }

-- Fallback ID range to scan if a domain's names can't be iterated with pairs().
-- VarBits have negative IDs. These bounds are guesses; widen them if the
-- console reports vars right at the edges.
local SCAN_MIN, SCAN_MAX = -70000, 20000

-- Vars per snapshot POST. Parts are sent one at a time and each takes about a
-- second to round-trip, so bigger parts finish sooner (~350 KB each).
local VARS_PER_POST = 2000

-- The client kills any Lua call that runs longer than 1000 ms, so the snapshot
-- is done a slice at a time: each Logic tick (50 a second) does at most this
-- many units of work, then returns.
local WORK_PER_TICK = 1000

-- Server ticks since the plugin was enabled; tags changes with a rough time.
local tick = 0

---------------------------------------------------------------------------
-- Reading vars
---------------------------------------------------------------------------

-- Value types the API can convert, from the ValueType table in the docs
-- (game/config/vartype). Reading a var of any other type logs an [ERROR], so
-- those are skipped.
-- stylua: ignore
local VALUE_TYPE_NAMES = {
    [131] = "ACHIEVEMENT", [16] = "AREA", [44] = "BASEANIMSET", [1] = "BOOLEAN",
    [41] = "CATEGORY", [42] = "CHAR", [29] = "CHATCAT", [24] = "CHATPHRASE",
    [9] = "COMPONENT", [22] = "COORDGRID", [5] = "CURSOR", [138] = "CUTSCENE2D",
    [129] = "DBTABLE", [74] = "DBROW", [26] = "ENUM", [25] = "FONT",
    [62] = "HITMARK", [10] = "IDKIT", [0] = "INTEGER", [39] = "INV",
    [30] = "LOC", [110] = "LONG", [59] = "MAPELEMENT", [102] = "MATERIAL",
    [31] = "MODEL", [32] = "NPC", [38] = "NPC_UID", [33] = "OBJ",
    [99] = "OVERLAYINTERFACE", [34] = "PLAYER_UID", [3] = "QUEST", [6] = "SEQ",
    [17] = "SKILL", [23] = "SPRITE", [37] = "SPOTANIM", [36] = "STRING",
    [73] = "STRUCT", [14] = "SYNTH", [209] = "VAR_INT", [57] = "VORBIS",
}

-- Turn a var's value into something JSON can hold (recording.serialise): numbers and booleans
-- are unchanged; config values (NPCType, ObjType, ...) become { config = name, id = n,
-- type = typeName }; other game types such as CoordGrid become their tostring() text; strings
-- over 4096 bytes are cut with a `<+N bytes>` suffix.
---@param value any
---@return any
local function plainValue(value)
    return recording.serialise(value, recording.objectData)
end

-- Everything we can read about one VarType, as a plain table.
local function describeVar(v)
    local entry = {
        id = v.id,
        name = v.configName,
        domain = v.typeName,
        valueType = v.valueType,
        valueTypeName = VALUE_TYPE_NAMES[v.valueType],
    }
    if v.isVarBit then
        entry.isVarBit = true
        entry.baseVar = v.baseVar and v.baseVar.configName
        entry.mask = v.varBitMask
    end
    if not entry.valueTypeName then
        entry.error = "unsupported ValueType"
        return entry
    end
    -- Reading the value can fail in other ways too, so report the error instead.
    local ok, value = pcall(function()
        return v.value
    end)
    if ok then
        entry.value = plainValue(value)
    else
        entry.error = tostring(value)
    end
    return entry
end

-- A list of found vars that also tracks the lowest and highest ID seen.
local function newFoundList()
    return { vars = {}, lo = math.huge, hi = -math.huge }
end

local function addFound(found, varId, v)
    found.vars[#found.vars + 1] = v
    found.lo = math.min(found.lo, varId)
    found.hi = math.max(found.hi, varId)
end

-- A lister finds a domain's vars one candidate at a time, so the work can be
-- spread over ticks. Calling it checks one more candidate, adding it to
-- `found` if it's a var, and returns false once there are none left.

-- Preferred: walk the id.<Domain> table and look each var up by ID. Whether
-- the ID is the key or the value isn't documented, so take whichever is an integer.
local function nameLister(domain, found)
    local iterate, state, key = pairs(id[domain])
    return function()
        local value
        key, value = iterate(state, key)
        if key == nil then return false end
        local varId = math.type(value) == "integer" and value or math.type(key) == "integer" and key
        local v = varId and var[domain].FromID(varId)
        if v then addFound(found, varId, v) end
        return true
    end
end

-- Fallback: try every ID in the scan range and keep the ones that exist.
local function scanLister(domain, found)
    local fromID = var[domain].FromID
    local varId = SCAN_MIN - 1
    return function()
        varId = varId + 1
        if varId > SCAN_MAX then return false end
        local ok, v = pcall(fromID, varId)
        if ok and v then addFound(found, varId, v) end
        return true
    end
end

---------------------------------------------------------------------------
-- Sending to the receiver
---------------------------------------------------------------------------

-- Log why a request failed, with a hint for the common case.
local function reportFailure(request)
    if request.timedOut then
        say("request to", request.url, "timed out")
    else
        say(
            "request to",
            request.url,
            "failed:",
            request.errorCode,
            request.errorInfo,
            "response",
            request.responseCode
        )
    end
    say("is scripts/var-dump-receiver.py running?")
end

-- POST a JSON body to a path on the sink, then call onDone(success).
-- onDone runs inside the HTTP callback, so it must not start another request:
-- doing that froze and then crashed the client. Record the result instead,
-- and let the next Logic tick act on it.
local function post(path, body, onDone)
    local request = HTTPRequest.new(Plugin.urls.sink, path)
    request:AddHeader("Content-Type", "application/json")
    inFlight[request] = body
    request:Post(body, function(finished)
        inFlight[request] = nil
        local success = finished.successful and finished.responseCode == 200
        if not success then reportFailure(finished) end
        if onDone then onDone(success) end
    end)
end

-- Snapshot parts are queued as they're built and sent one at a time by
-- pumpUploads(). That keeps them in order, so the receiver starts a new file
-- on part 1.
local snapshotQueue = {} -- { body = json, count = vars in it }
local uploading = false -- a part is being sent right now
local building = false -- the snapshot is still making parts
local uploadFailed = false
local reportedDone = false

-- Progress, for the console. Logic ticks run at a fixed 50 a second, so
-- counting them gives the elapsed time.
local totalVars = 0 -- set once listing is done
local varsUploaded = 0
local lastTenthReported = 0
local logicTicks = 0

local function queueSnapshotPart(body, count)
    if not uploadFailed then snapshotQueue[#snapshotQueue + 1] = { body = body, count = count } end
end

-- Log upload progress each time it passes another 10%.
local function reportUploadProgress()
    if totalVars == 0 then return end
    local tenth = varsUploaded * 10 // totalVars
    if tenth > lastTenthReported and tenth < 10 then
        lastTenthReported = tenth
        say(
            formatStr(
                "uploaded {}/{} vars ({}%)",
                varsUploaded,
                totalVars,
                varsUploaded * 100 // totalVars
            )
        )
    end
end

-- Called every Logic tick: if no part is being sent, send the next one.
local function pumpUploads()
    if uploading or uploadFailed then return end
    reportUploadProgress()
    local part = table.remove(snapshotQueue, 1)
    if part then
        uploading = true
        post("/snapshot", part.body, function(success)
            uploading = false
            if success then
                varsUploaded = varsUploaded + part.count
            else
                -- Give up on the rest; `prl var-dump` to retry.
                uploadFailed = true
                snapshotQueue = {}
            end
        end)
    elseif not building and not reportedDone then
        reportedDone = true
        say(
            formatStr(
                "snapshot upload complete: {} vars in {} s",
                varsUploaded,
                string.format("%.1f", logicTicks / 50)
            )
        )
    end
end

---------------------------------------------------------------------------
-- Snapshot, a slice per tick
---------------------------------------------------------------------------

-- The running snapshot's progress, or nil when none is running. This is plain
-- state advanced from the Logic event rather than a coroutine, to keep every
-- API call on the normal callback path (an earlier coroutine version crashed
-- the client; see docs/api-concepts.md). Functions that read it assert it
-- first, which also tells the type checker it is set from there on.
local snap = nil ---@type table?

-- Begin listing the current domain, by name if possible.
local function beginDomain()
    assert(snap, "no snapshot running")
    local domain = DOMAINS[snap.domainIndex]
    say("listing", domain, "vars...")
    snap.found = newFoundList()
    local ok, lister = pcall(nameLister, domain, snap.found)
    if ok then
        snap.lister, snap.method = lister, "pairs(id." .. domain .. ")"
    else
        say(domain, "can't iterate names:", lister)
        snap.lister = scanLister(domain, snap.found)
        snap.method = formatStr("FromID scan {}..{}", SCAN_MIN, SCAN_MAX)
    end
end

-- Switch the current domain to the ID scan (name listing failed or found nothing).
local function fallBackToScan(reason)
    assert(snap, "no snapshot running")
    local domain = DOMAINS[snap.domainIndex]
    say(domain, "name iteration failed or was empty:", reason)
    snap.found = newFoundList()
    snap.lister = scanLister(domain, snap.found)
    snap.method = formatStr("FromID scan {}..{}", SCAN_MIN, SCAN_MAX)
end

-- The current domain is fully listed: report it and move to the next domain,
-- or to describing once every domain is done.
local function finishDomain()
    assert(snap, "no snapshot running")
    local domain, found = DOMAINS[snap.domainIndex], snap.found
    say(domain, ":", #found.vars, "vars via", snap.method, "| IDs", found.lo, "to", found.hi)
    table.move(found.vars, 1, #found.vars, #snap.all + 1, snap.all)
    snap.domainIndex = snap.domainIndex + 1
    if snap.domainIndex <= #DOMAINS then
        beginDomain()
    else
        snap.stage = "describe"
        totalVars = #snap.all
        snap.totalParts = math.max(1, math.ceil(#snap.all / VARS_PER_POST))
        say("sending", #snap.all, "vars in", snap.totalParts, "parts")
    end
end

-- One unit of listing work: check one candidate in the current domain.
local function listStep()
    assert(snap, "no snapshot running")
    local ok, more = pcall(snap.lister)
    local scanning = snap.method:find("scan")
    if not ok then
        if not scanning and #snap.found.vars == 0 then
            fallBackToScan(more)
        else
            say(DOMAINS[snap.domainIndex], "listing stopped early:", more)
            finishDomain()
        end
    elseif not more then
        if not scanning and #snap.found.vars == 0 then
            fallBackToScan("0 vars")
        else
            finishDomain()
        end
    end
end

-- Encode the vars described so far as one part and queue it for upload.
-- Returns its cost in work units (about one per var).
local function flushPart()
    assert(snap, "no snapshot running")
    snap.part = snap.part + 1
    queueSnapshotPart(
        json.encode({
            part = snap.part,
            totalParts = snap.totalParts,
            totalVars = #snap.all,
            vars = snap.entries,
        }),
        #snap.entries
    )
    local cost = #snap.entries
    snap.entries = {}
    return cost
end

-- One unit of describing work: describe the next var, sending a part when full.
-- Returns the extra cost of encoding, if a part was sent.
local function describeStep()
    assert(snap, "no snapshot running")
    local v = snap.all[snap.next]
    snap.next = snap.next + 1
    if v then
        local ok, entry = pcall(describeVar, v)
        if ok then
            snap.entries[#snap.entries + 1] = entry
        else
            say("could not describe a var:", entry)
        end
    end
    local finished = snap.next > #snap.all
    if #snap.entries >= VARS_PER_POST or finished then
        local cost = flushPart()
        if finished then
            snap = nil
            building = false
        end
        return cost
    end
    return 0
end

-- Each Logic tick, send the next part if the last one is done, then do up to
-- WORK_PER_TICK units of snapshot work.
local function onLogic()
    if not reportedDone then logicTicks = logicTicks + 1 end
    pumpUploads()
    local work = 0
    while snap and work < WORK_PER_TICK do
        if snap.stage == "list" then
            listStep()
            work = work + 1
        else
            work = work + 1 + describeStep()
        end
    end
end

---------------------------------------------------------------------------
-- Change log
---------------------------------------------------------------------------

-- VarTransmit events since the last flush, and a running sequence number.
local pendingChanges = {}
local changeSeq = 0

-- Record one var update from the server. It fires even if the value didn't change.
local function onVarTransmit(ev)
    local v = ev.var
    changeSeq = changeSeq + 1
    pendingChanges[#pendingChanges + 1] = {
        seq = changeSeq,
        tick = tick,
        domain = v and v.typeName,
        id = v and v.id,
        name = v and v.configName,
        old = plainValue(ev.oldValue),
        new = plainValue(ev.newValue),
    }
end

-- Once per server tick, send whatever changes have built up.
local function onServerLogic()
    tick = tick + 1
    if #pendingChanges == 0 then return end
    local body = json.encode({ changes = pendingChanges })
    pendingChanges = {}
    post("/changes", body)
end

---------------------------------------------------------------------------
-- Start up
---------------------------------------------------------------------------

-- Start logging changes and take the snapshot. Only runs once per enable.
local started = false
local function start()
    if started then return end
    started = true
    Event.VarTransmit.Subscribe(SUBS.VarTransmit, onVarTransmit)
    Event.ServerLogic.Subscribe(SUBS.ServerLogic, onServerLogic)
    snap = { stage = "list", domainIndex = 1, all = {}, next = 1, part = 0, entries = {} }
    building = true
    beginDomain()
    Event.Logic.Subscribe(SUBS.Logic, onLogic)
end

-- httpAccess is optional, so it can be granted while the plugin is running.
-- Start as soon as it is, without needing a reload.
Event.OptionalPermissionChanged.Subscribe(SUBS.OptionalPermissionChanged, function(ev)
    if ev.enabled and Plugin.HasPermission(PluginPermissions.httpAccess) then start() end
end)

if Plugin.HasPermission(PluginPermissions.httpAccess) then
    start()
else
    say("waiting for httpAccess: run `ppr var-dump`, then `ppe var-dump httpAccess`")
end
