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

-- Console commands that would disable, reload or revoke a permission of the plugin named as
-- their first argument, short and long forms. plugins_setenabled is refused whatever its
-- true/false argument: telling a re-enable from a disable isn't worth the risk of getting it
-- wrong.
local SELF_TARGETING = {
    prl = true,
    plugins_reload = true,
    poff = true,
    plugins_disable = true,
    plugins_setenabled = true,
    ppd = true,
    plugins_permissions_disable = true,
}

-- Whether `command` would disable or reload the bridge itself (or revoke one of its
-- permissions). The bridge runs commands from inside its own Logic callback, and what the
-- client does when a plugin disables itself there is unprobed, so these are refused.
---@param command string
---@return boolean
function protocol.isSelfTarget(command)
    local word, target = command:match("^%s*(%S+)%s+(%S+)")
    if not word then return false end
    return SELF_TARGETING[word:lower()] == true and target:lower() == protocol.PLUGIN
end

-- Why the bridge won't run `command`, or nil if it will (an `exec` of any other console
-- command; the user allowed every command but these).
---@param command { kind: string, arg: string }
---@return string?
function protocol.refusal(command)
    if command.kind ~= "exec" then return "unknown kind " .. command.kind end
    if protocol.isSelfTarget(command.arg) then
        return "refused: this would disable or reload dev-bridge from inside its own callback, "
            .. "which is unprobed in the client; run it from the client console instead"
    end
    return nil
end

return protocol
