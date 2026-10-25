-- The dev bridge's pure core: the sync body the plugin POSTs, parsing the daemon's reply into
-- commands, and deciding which commands the bridge refuses. It also holds the privacy filters
-- deciding which chat messages and menu entries may leave the client (chatView, entryView),
-- the shape and caps of eval results and of the Log and Emit events, and which events the
-- bridge subscribes to and eval probes may use (PROBE_EVENTS).
-- Nothing here calls the API or keeps state; main.lua and eval.lua (the shell) do both. The
-- protocol is documented in docs/dev-environment.md ("Dev bridge") and served by
-- scripts/rsdev.py.

local json = require("dev/json")
local recording = require("dev/recording")

local protocol = {}

protocol.SCHEMA = 1
protocol.PLUGIN = "dev-bridge"

-- Tunables, read on each use so a test can shrink them. Ticks are Logic ticks (50 a second).
protocol.limits = {
    syncEveryTicks = 10, -- wait after a sync finishes before starting the next
    retryTicks = 250, -- wait after a failed sync
    syncBytes = 256 * 1024, -- encoded events per sync
    bufferBytes = 1024 * 1024, -- encoded events kept while they can't be sent
    -- Encoded results per sync, and the most one result takes (resultEntry). With syncBytes
    -- of events, this keeps a sync under the daemon's 2 MB body cap (rsdev.py MAX_BODY): the
    -- results of a refused sync would be resent, and refused, forever.
    resultBytes = 1024 * 1024,
    valueBytes = 64 * 1024, -- encoded values of one eval result, or one Emit's value
    outputLines = 200, -- print/log lines one eval result keeps
    lineBytes = 2 * 1024, -- one output line, Log text, error or Emit tag
    -- Live probes per session (eval.lua). A probe is a table entry, so removing one frees
    -- its slot at once; the cap bounds what one event's fan-out can cost.
    probes = 32,
}

-- Every console line from the bridge carries this tag, so it's easy to grep.
protocol.TAG = "[BRIDGE]"

-- Globals whose type() every sync reports in hello.env, so the host can see what this client
-- gives a plugin, e.g. whether `load` exists, which eval needs.
protocol.ENV_NAMES = {
    "load",
    "loadstring",
    "debug",
    "os",
    "io",
    "require",
    "ExecuteConsoleCommand",
    "coroutine",
}

---------------------------------------------------------------------------
-- Privacy: which chat and menu data may leave the client. CLAUDE.md forbids exporting other
-- players' info, and the daemon writes what it receives to disk, so both filters fail closed.
---------------------------------------------------------------------------

-- ChatType values (core/events.lua), by name; a spec checks them against the stub. These
-- carry no player speech and pass whatever their sender (SPAM, below, is not one of them).
-- Examines were seen arriving as GENERAL (0) in the client; the *_EXAMINE types stay in case
-- they are used.
protocol.SYSTEM_CHAT = {
    GENERAL = 0,
    ENGINE = 4,
    SNAPSHOT_FEEDBACK = 26,
    OBJ_EXAMINE = 27,
    NPC_EXAMINE = 28,
    LOC_EXAMINE = 29,
    PLUGIN = 33,
    CONSOLE_ERROR = 96,
    CONSOLE_BUFFER_REPLACE = 98,
    CONSOLE = 99,
}

-- SPAM is undocumented: neither the stub nor developer.runescape.com describes it. It might
-- carry game messages (which have no sender) or other players' chat the game filtered as spam,
-- so it is forwarded only with an empty sender or the local player's own name.
protocol.SPAM = 109

-- Player speech: forwarded only when the local player is the sender. Anything in neither
-- table (SPAM aside) is dropped, which is deliberate: BROADCAST_WORLD (138) carries News
-- lines naming other players with an empty sender, so a missing sender doesn't make text safe.
protocol.SPEECH_CHAT = {
    MOD = 1,
    PUBLIC = 2,
    PRIVATE_INCOMING = 3,
    PRIVATE_OUTGOING = 6, -- its sender may be the recipient, which then fails the match
    MOD_PRIVATE_INCOMING = 7,
    FRIEND_CHAT = 9,
    QUICKCHAT_PUBLIC = 17,
    QUICKCHAT_PRIVATE_INCOMING = 18,
    QUICKCHAT_PRIVATE_OUTGOING = 19,
    QUICKCHAT_FRIEND_CHAT = 20,
    GROUP_SAME_TEAM = 22,
    QUICKCHAT_GROUP_SAME_TEAM = 23,
    GROUP_ALL = 24,
    QUICKCHAT_GROUP_ALL = 25,
    CLANCHANNEL_AFFINED_CHAT = 41,
    CLANCHANNEL_AFFINED_QUICKCHAT = 42,
    CLANCHANNEL_GUEST_CHAT = 44,
    CLANCHANNEL_GUEST_QUICKCHAT = 45,
}

---@param set table<string, integer>
---@return table<integer, true>
local function valueSet(set)
    local out = {}
    for _, value in pairs(set) do
        out[value] = true
    end
    return out
end

local SYSTEM_SET = valueSet(protocol.SYSTEM_CHAT)
local SPEECH_SET = valueSet(protocol.SPEECH_CHAT)

-- A name as comparable text: markup tags like <img=11> dropped, case folded, underscores and
-- non-breaking spaces as spaces (the game treats them alike), spaces trimmed and collapsed.
---@param name any
---@return string
function protocol.normaliseName(name)
    if type(name) ~= "string" then return "" end
    local text = name:gsub("<[^>]*>", ""):gsub("\194\160", " "):gsub("_", " "):lower()
    return (text:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

-- Whether `name` is `ownName`; false when either is missing or empty.
---@param name any
---@param ownName any
---@return boolean
function protocol.isOwnName(name, ownName)
    local own = protocol.normaliseName(ownName)
    return own ~= "" and protocol.normaliseName(name) == own
end

-- Whether a chat message may be forwarded: system types always, speech types only from the
-- local player, SPAM only when senderless or the local player's, everything else never.
-- `ownName` is nil when the player's name can't be read.
---@param chatType any
---@param senderSimple any the payload's senderNameSimple
---@param ownName any
---@return boolean
function protocol.chatAllowed(chatType, senderSimple, ownName)
    if SYSTEM_SET[chatType] then return true end
    if SPEECH_SET[chatType] then return protocol.isOwnName(senderSimple, ownName) end
    if chatType == protocol.SPAM then
        return protocol.normaliseName(senderSimple) == ""
            or protocol.isOwnName(senderSimple, ownName)
    end
    return false
end

-- The serialised ChatMessage fields to forward, or nil to drop the message. A system
-- message that names some other sender has the sender fields blanked.
---@param data table the serialised payload
---@param ownName any
---@return table?
function protocol.chatView(data, ownName)
    if not protocol.chatAllowed(data.chatType, data.senderNameSimple, ownName) then return nil end
    if SYSTEM_SET[data.chatType] and not protocol.isOwnName(data.senderNameSimple, ownName) then
        data.senderNameUnfiltered, data.senderNameFiltered, data.senderNameSimple = "", "", ""
    end
    return data
end

-- MiniMenuEntry fields forwarded (game/minimenu.lua). The entry itself is client userdata that
-- serialises as the useless text "sol.jag::MiniMenuEntry", so the shell reads these by name.
protocol.ENTRY_FIELDS = {
    "verbText",
    "subjectText",
    "extraText",
    "fullText",
    "overrideText",
    "actionType",
    "actionEntryType",
    "actionVerbType",
    "subjectHash",
}

-- Text fields that hold a targeted player's name. fullText is verb + subject + extra, so
-- extraText may carry the name of a player-targeting entry too. verbText is left alone: it is
-- the action word ("Trade with").
local ENTRY_NAME_FIELDS = { "subjectText", "extraText", "fullText", "overrideText" }

-- MiniMenuEntryType.PLAYER (docs/api/generated/game/minimenu.lua).
protocol.ENTRY_TYPE_PLAYER = 7

-- MiniMenuActionType values that target a player (docs/api/generated/game/minimenu.lua):
-- TGT_PLAYER, OP_PLAYER1..10, and the low-priority twins of OP_PLAYER1..10.
local ACTION_TGT_PLAYER = 15
local ACTION_OP_PLAYER_FIRST, ACTION_OP_PLAYER_LAST = 44, 53
local ACTION_OP_PLAYER_LOW_FIRST, ACTION_OP_PLAYER_LOW_LAST = 2044, 2053

-- Whether a MiniMenuActionType is TGT_PLAYER, OP_PLAYER1..10 or their low-priority twins.
---@param action any
---@return boolean
function protocol.playerAction(action)
    if type(action) ~= "number" then return false end
    return action == ACTION_TGT_PLAYER
        or (action >= ACTION_OP_PLAYER_FIRST and action <= ACTION_OP_PLAYER_LAST)
        or (action >= ACTION_OP_PLAYER_LOW_FIRST and action <= ACTION_OP_PLAYER_LOW_LAST)
end

-- The entry's fields with a targeted player's name blanked. It counts as targeting a player
-- when `hasPlayerData` isn't false (nil: the read failed), or its entry or action type says so.
---@param fields table the entry's fields read by name
---@param hasPlayerData boolean? whether entry.playerData ~= nil
---@return table
function protocol.entryView(fields, hasPlayerData)
    local out = {}
    for _, name in ipairs(protocol.ENTRY_FIELDS) do
        out[name] = fields[name]
    end
    if
        hasPlayerData ~= false
        or out.actionEntryType == protocol.ENTRY_TYPE_PLAYER
        or protocol.playerAction(out.actionType)
    then
        for _, name in ipairs(ENTRY_NAME_FIELDS) do
            if out[name] ~= nil then out[name] = "<player>" end
        end
    end
    return out
end

-- One forwarded event, encoded once when it arrives so the buffer can count its bytes.
---@param t integer the Logic tick it arrived after
---@param name string the event name
---@param payload any already serialised
---@return string
function protocol.eventEntry(t, name, payload)
    return json.encode({ t = t, name = name, payload = payload })
end

-- The POST body of one sync. `fields` holds session, seq, dropped and hello; `events` are
-- entries from eventEntry and `results` entries from resultEntry, both spliced in so they
-- aren't encoded twice.
---@param fields table
---@param events string[]
---@param results string[]
---@return string
function protocol.syncBody(fields, events, results)
    local body = recording.batchBody({
        schema = protocol.SCHEMA,
        plugin = protocol.PLUGIN,
        session = fields.session,
        seq = fields.seq,
        dropped = fields.dropped,
        hello = fields.hello,
    }, events, "events")
    return body:sub(1, -2) .. ',"results":[' .. table.concat(results, ",") .. "]}"
end

-- The oldest results whose bytes fit in `maxBytes` (at least one, however big), and the rest.
---@param results string[]
---@param maxBytes integer
---@return string[] taken
---@return string[] rest
function protocol.takeResults(results, maxBytes)
    local taken, rest, bytes = {}, {}, 0
    for _, result in ipairs(results) do
        if #rest == 0 and (#taken == 0 or bytes + #result <= maxBytes) then
            taken[#taken + 1] = result
            bytes = bytes + #result
        else
            rest[#rest + 1] = result
        end
    end
    return taken, rest
end

---------------------------------------------------------------------------
-- Eval results and the Log and Emit events
---------------------------------------------------------------------------

-- Any value as text, never raising: tostring() can, through a bad __tostring.
---@param v any
---@return string
function protocol.text(v)
    if type(v) == "string" then return v end
    local ok, text = pcall(tostring, v)
    if ok then return text end
    return "<a " .. type(v) .. " that tostring() fails on>"
end

-- print's and log's text: their arguments separated by a space (docs/api/generated/core.lua).
---@return string
function protocol.joinText(...)
    local parts = table.pack(...)
    for i = 1, parts.n do
        parts[i] = protocol.text(parts[i])
    end
    return table.concat(parts, " ", 1, parts.n)
end

-- `text` cut to lineBytes, ending in "<+N bytes>" when cut, and whether it was.
---@param text string
---@return string
---@return boolean
local function capText(text)
    local max = protocol.limits.lineBytes
    if #text <= max then return text, false end
    return text:sub(1, max) .. string.format("<+%d bytes>", #text - max), true
end

-- What one eval has printed so far: at most outputLines lines of at most lineBytes each.
---@return { lines: string[], truncated: boolean }
function protocol.newOutput()
    return { lines = {}, truncated = false }
end

---@param output { lines: string[], truncated: boolean }
---@param text string
function protocol.addOutput(output, text)
    if #output.lines >= protocol.limits.outputLines then
        output.truncated = true
        return
    end
    local max = protocol.limits.lineBytes
    if #text > max then
        text, output.truncated = text:sub(1, max), true
    end
    output.lines[#output.lines + 1] = text
end

-- One command's result, encoded for syncBody. `r.error` (any value) is set when `r.ok` is
-- false. An eval adds `output`, and on success `values` (each already serialised, with
-- `nvalues` of them, nils included). The values go as a JSON array of exactly nvalues
-- elements, nils as null (dev/json would write a table with a nil hole as an object). Past
-- valueBytes they are dropped; a result still over resultBytes loses its output; either sets
-- truncated, as does a cut error or output line.
---@param r { id: string, ok: boolean, error: any, values: any[]?, nvalues: integer?, output: { lines: string[], truncated: boolean }? }
---@return string
function protocol.resultEntry(r)
    local meta = { id = r.id, ok = r.ok }
    local truncated = r.output ~= nil and r.output.truncated
    if not r.ok then
        local cut
        meta.error, cut = capText(protocol.text(r.error))
        truncated = truncated or cut
    end
    meta.output = r.output and r.output.lines
    local values = nil ---@type string[]?
    if r.nvalues then
        meta.nvalues = r.nvalues
        local parts, bytes = {}, 0
        for i = 1, r.nvalues do
            parts[i] = json.encode((r.values or {})[i])
            bytes = bytes + #parts[i] + 1
        end
        if bytes > protocol.limits.valueBytes then
            parts, truncated = {}, true
        end
        values = parts
    end
    local function encode()
        meta.truncated = truncated or nil
        if not values then return json.encode(meta) end
        return recording.batchBody(meta, values, "values")
    end
    local entry = encode()
    if #entry > protocol.limits.resultBytes and meta.output then
        meta.output, truncated = {}, true
        entry = encode()
    end
    return entry
end

-- A Log event: a line the bridge logged, or (source "eval") one a probe printed or an error
-- that stopped a probe. Its text is cut to lineBytes.
---@param t integer the Logic tick
---@param level "print"|"log"|"error"
---@param text string
---@param source string?
---@return string
function protocol.logEntry(t, level, text, source)
    return protocol.eventEntry(t, "Log", {
        plugin = protocol.PLUGIN,
        level = level,
        text = (capText(text)),
        source = source,
    })
end

-- `objectJson` (an encoded, non-empty object) with `key` added, its value the already-encoded
-- `valueJson`.
---@param objectJson string
---@param key string
---@param valueJson string
---@return string
local function withField(objectJson, key, valueJson)
    return objectJson:sub(1, -2) .. "," .. json.encode(key) .. ":" .. valueJson .. "}"
end

-- An Emit event from a snippet's emit(tag, value). `value` is already serialised; past
-- valueBytes encoded it is left out and the payload says truncated. The value is encoded
-- once, for both the size check and the entry: a probe may emit a large table every tick,
-- inside the client's 1000 ms limit on one call.
---@param t integer
---@param tag any
---@param value any
---@return string
function protocol.emitEntry(t, tag, value)
    local payload = { tag = (capText(protocol.text(tag))) }
    local encoded = value ~= nil and json.encode(value) or nil
    if encoded and #encoded > protocol.limits.valueBytes then
        payload.truncated, encoded = true, nil
    end
    local payloadJson = json.encode(payload)
    if encoded then payloadJson = withField(payloadJson, "value", encoded) end
    return withField(json.encode({ t = t, name = "Emit" }), "payload", payloadJson)
end

---------------------------------------------------------------------------
-- The events the bridge subscribes to, and probes
---------------------------------------------------------------------------

-- Every event the bridge subscribes to, each once, at load, as "devBridge<Event>" (main.lua),
-- and so the events an eval probe may use: a probe is an entry in eval.lua's table that the
-- bridge's handler calls, never a client subscription of its own. Four client aborts
-- (docs/api-concepts.md, "Runtime limits we've hit") showed that a subscription made inside a
-- callback can never be unsubscribed safely, so nothing is subscribed after load.
-- The stub's Event table (docs/api/generated/core/events.lua) in its order, less
-- PROBE_EXCLUDED; a spec checks the two cover it exactly.
protocol.PROBE_EVENTS = {
    "Logic",
    "ServerLogic",
    "OptionalDependencyChanged",
    "OptionalPermissionChanged",
    "KeyUp",
    "KeyDown",
    "KeyTyped",
    "VarTransmit",
    "ChatMessage",
    "PlayerEntityAdded",
    "PlayerEntityRemoved",
    "NPCEntityAdded",
    "NPCEntityRemoved",
    "ObjStackEntityAdded",
    "ObjStackEntityRemoved",
    "ObjStackEntityChanged",
    "WindowFocusChanged",
    "GameStateChanged",
    "WindowSizeChanged",
    "SkillTransmit",
    "RunEnergyTransmit",
    "RunWeightTransmit",
    "MiniMenuOpened",
    "MiniMenuClosed",
    "MiniMenuReady",
    "MiniMenuEntryAdded",
    "MiniMenuEntrySelected",
    "LocAdded",
    "LocRemoved",
    "LocCustomised",
    "LocAnimation",
    "InventoryAdded",
    "InventoryUpdated",
    "InventoryRemoved",
    "GrandExchangeOfferUpdated",
    "WorldCreated",
    "WorldUpdated",
    "RegionCreated",
    "RegionUpdated",
}

-- The stub's events the bridge does not subscribe to, and why: a subscription can't be added
-- later, so leaving one out means no probe can ever use it.
protocol.PROBE_EXCLUDED = {
    Draw = "it fires every rendered frame, so a handler there would cost frame time for the "
        .. "whole session",
    EntityDraw = "it fires for every entity on every frame, and its subscribers' boolean "
        .. "return decides whether the entity is drawn, which a handler must not touch",
    SettingsLayerReady = "it needs hasSettingsIcon in the manifest, which dev-bridge lacks, so "
        .. "it never fires for the bridge",
    ContentLayerReady = "it needs hasRibbonIcon in the manifest, which dev-bridge lacks, so it "
        .. "never fires for the bridge",
}

local PROBE_SET = {}
for _, event in ipairs(protocol.PROBE_EVENTS) do
    PROBE_SET[event] = true
end

-- Why a snippet can't probe `event` (Event.<event>.Subscribe/Unsubscribe in eval), or nil if
-- it can.
---@param event any
---@return string?
function protocol.probeEventError(event)
    if PROBE_SET[event] then return nil end
    local name = "Event." .. protocol.text(event)
    local why = protocol.PROBE_EXCLUDED[event]
    if why then return name .. " is not probe-able: " .. why end
    return name .. " is not probe-able: no such event (dev-bridge's README lists the ones that are)"
end

-- The error for a snippet adding a probe when `count` are live, or nil if there is room.
---@param count integer
---@return string?
function protocol.probeCapError(count)
    if count < protocol.limits.probes then return nil end
    return string.format(
        "at most %d probes per bridge session; Event.<Name>.Unsubscribe one, or "
            .. "`rsdev.py eval --reset` clears them all",
        protocol.limits.probes
    )
end

-- The Log text for a probe removed after its first error.
---@param event string
---@param name string the name the snippet subscribed with
---@param err any
---@return string
function protocol.probeErrorText(event, name, err)
    return string.format(
        "probe Event.%s %q removed after an error: %s",
        event,
        name,
        protocol.text(err)
    )
end

-- The daemon escapes `\`, tab, newline and CR in an arg (rsdev.py escape_arg). Any other
-- escape is left as written, as rsdev.py's unescape_arg does.
local UNESCAPES = { ["\\"] = "\\", t = "\t", n = "\n", r = "\r" }

---@param text string
---@return string
function protocol.unescape(text)
    return (text:gsub("\\(.)", function(c)
        return UNESCAPES[c] or ("\\" .. c)
    end))
end

-- The commands in a sync reply: zero or more `<id>\t<kind>\t<arg>` lines, each ending in a
-- newline. Returns the commands ({ id, kind, arg }, arg unescaped) and the malformed lines,
-- which can't be answered because they have no usable id. A non-empty body that doesn't end
-- in a newline was cut short, so the whole reply is refused: returns nil and why.
---@param body string
---@return { id: string, kind: string, arg: string }[]?
---@return string[] | string
function protocol.parseReply(body)
    if body ~= "" and body:sub(-1) ~= "\n" then return nil, "reply does not end in a newline" end
    local commands, malformed = {}, {}
    for line in body:gmatch("([^\n]*)\n") do
        local id, kind, arg = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)$")
        local idOk = id ~= nil and #id <= 32 and id:match("^[%w_-]+$") ~= nil
        if idOk and kind ~= "" then
            commands[#commands + 1] = { id = id, kind = kind, arg = protocol.unescape(arg) }
        else
            malformed[#malformed + 1] = line
        end
    end
    return commands, malformed
end

-- Console commands that disable the plugin named as their first argument, or revoke one of its
-- permissions, short and long forms. plugins_setenabled is refused whatever its true/false
-- argument, since telling a re-enable from a disable is error-prone. Reloading (prl,
-- plugins_reload) is allowed: a plugin can reload itself from its own Logic callback
-- (docs/api-concepts.md), which is how the daemon side restarts the bridge.
local DISABLING = {
    poff = true,
    plugins_disable = true,
    plugins_setenabled = true,
    ppd = true,
    plugins_permissions_disable = true,
}

-- Whether `command` would disable the bridge, or revoke one of its permissions. That would cut
-- the only channel the daemon has to the client, and nothing on the daemon side could undo it.
---@param command string
---@return boolean
function protocol.isSelfDisable(command)
    local word, target = command:match("^%s*(%S+)%s+(%S+)")
    if not word then return false end
    return DISABLING[word:lower()] == true and target:lower() == protocol.PLUGIN
end

-- Why the bridge won't run console command `command`, sent by exec or from an eval snippet,
-- or nil if it will.
---@param command string
---@return string?
function protocol.consoleRefusal(command)
    if protocol.isSelfDisable(command) then
        return "refused: this would disable dev-bridge, cutting the only channel that could "
            .. "re-enable it; run it from the client console instead"
    end
    return nil
end

local KINDS = { exec = true, eval = true, reset = true }

-- Why the bridge won't run `command`, or nil if it will: an unknown kind, a self-disabling
-- exec, or an eval without source (the daemon never sends one).
---@param command { kind: string, arg: string }
---@return string?
function protocol.refusal(command)
    if not KINDS[command.kind] then return "unknown kind " .. command.kind end
    if command.kind == "exec" then return protocol.consoleRefusal(command.arg) end
    if command.kind == "eval" and command.arg == "" then return "eval has no Lua source" end
    return nil
end

return protocol
