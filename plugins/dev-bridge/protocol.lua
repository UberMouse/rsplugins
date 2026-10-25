-- The dev bridge's pure core: the sync body the plugin POSTs, parsing the daemon's reply into
-- commands, and deciding which commands the bridge refuses. Nothing here calls the API or
-- keeps state; main.lua (the shell) does both. The protocol is documented in
-- docs/dev-environment.md ("Dev bridge") and served by scripts/rsdev.py.

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
}

-- Globals whose type() every sync reports in hello.env, so the host can see what this client
-- gives a plugin (stage 2 of the bridge needs to know whether `load` exists).
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
-- carry no player speech and pass whatever their sender. Examines were seen arriving as
-- GENERAL (0) in the client; the *_EXAMINE types stay in case they are used.
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
    SPAM = 109,
}

-- Player speech: forwarded only when the local player is the sender. Anything in neither
-- table is dropped, which is deliberate: BROADCAST_WORLD (138) carries News lines naming
-- other players with an empty sender, so a missing sender doesn't make text safe.
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
-- local player, everything else never. `ownName` is nil when the player's name can't be read.
---@param chatType any
---@param senderSimple any the payload's senderNameSimple
---@param ownName any
---@return boolean
function protocol.chatAllowed(chatType, senderSimple, ownName)
    if SYSTEM_SET[chatType] then return true end
    if SPEECH_SET[chatType] then return protocol.isOwnName(senderSimple, ownName) end
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

-- Text fields that hold a targeted player's name.
local ENTRY_NAME_FIELDS = { "subjectText", "fullText", "overrideText" }
local ENTRY_TYPE_PLAYER = 7 -- MiniMenuEntryType.PLAYER
-- MiniMenuActionType: TGT_PLAYER, OP_PLAYER1..10 and their low-priority twins.
---@param action any
---@return boolean
local function playerAction(action)
    if type(action) ~= "number" then return false end
    return action == 15 or (action >= 44 and action <= 53) or (action >= 2044 and action <= 2053)
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
        or out.actionEntryType == ENTRY_TYPE_PLAYER
        or playerAction(out.actionType)
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

-- The POST body of one sync. `fields` holds session, seq, dropped, hello and results;
-- `events` are entries from eventEntry, spliced in so they aren't encoded twice.
---@param fields table
---@param events string[]
---@return string
function protocol.syncBody(fields, events)
    return recording.batchBody({
        schema = protocol.SCHEMA,
        plugin = protocol.PLUGIN,
        session = fields.session,
        seq = fields.seq,
        dropped = fields.dropped,
        hello = fields.hello,
        results = fields.results,
    }, events, "events")
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
-- argument: telling a re-enable from a disable isn't worth the risk of getting it wrong.
-- Reloading (prl, plugins_reload) is deliberately absent: probed 2026-10-26, a plugin can reload
-- itself from its own Logic callback (docs/api-concepts.md), which is how the conductor restarts
-- the bridge.
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

-- Why the bridge won't run `command`, or nil if it will (an `exec` of any other console
-- command; the user allowed every command but these).
---@param command { kind: string, arg: string }
---@return string?
function protocol.refusal(command)
    if command.kind ~= "exec" then return "unknown kind " .. command.kind end
    if protocol.isSelfDisable(command.arg) then
        return "refused: this would disable dev-bridge, cutting the only channel that could "
            .. "re-enable it; run it from the client console instead"
    end
    return nil
end

return protocol
