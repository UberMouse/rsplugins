-- A recording from the dev recorder (docs/testing.md, "Recordings") turned into a timeline the
-- harness can replay (replay.lua). Pure: it parses and groups entries, and never touches a
-- harness or the world.
--
-- Entries are grouped by tick `t`. Within a tick, the reads before the first event were made
-- from Logic (or from main.lua, at t = 0), so they apply before Logic fires. Every other read
-- was made by the callback of the event just before it, so it applies before that event
-- fires: the plugin sees the value it saw in the client.

local dkjson = require("dkjson")
local stubs = require("tests.harness.stubs")

local M = {}

-- The recording format this harness replays (lib/dev/recording.lua's SCHEMA).
M.SCHEMA = 1

local PLUGIN_CHAT = stubs.value("core/events.lua", "ChatType").PLUGIN

-- One JSON value per line, decoded without dkjson's marker metatables.
---@param text string the contents of a .jsonl recording
---@return table[] entries
function M.parse(text)
    local entries, n = {}, 0
    for line in text:gmatch("[^\n]+") do
        n = n + 1
        if line:find("%S") then
            local entry, _, err = dkjson.decode(line, 1, nil, nil, nil)
            if type(entry) ~= "table" then
                error(string.format("recording line %d is not a JSON object: %s", n, tostring(err)))
            end
            entries[#entries + 1] = entry
        end
    end
    return entries
end

-- A copy of `t` with its digit-string keys ("1", "5") as integers. A JSON object can only
-- have string keys, so a slot table with holes comes back keyed "1", "5"...
---@param t any
---@return any
local function integerKeys(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do
        if type(k) == "string" and k:match("^%d+$") then k = assert(math.tointeger(tonumber(k))) end
        out[k] = v
    end
    return out
end

-- The first entry per key that a replay seeds the world from, if it says what was there
-- before the plugin changed anything: a PersistentDB key's first call, when it is a Get
-- (Get, GetInt...) that found a value, and a permission's first check.
---@param tl table the timeline being built
---@param entry table
local function noteStart(tl, entry)
    if entry.k == "db" and type(entry.key) == "string" and not tl.dbKeys[entry.key] then
        tl.dbKeys[entry.key] = true
        if entry.op:match("^Get") and entry.v ~= nil then
            tl.db[entry.key] = { op = entry.op, v = entry.v }
        end
    elseif entry.k == "perm" and tl.grants[entry.permission] == nil then
        tl.grants[entry.permission] = entry.v == true
    end
end

-- Group `entries` (a recording's lines, or a list of entries as the recorder POSTs them) into
-- a timeline:
--   ticks[t] = { leading = { read... }, events = { { entry, reads = { read... }, skip } } }
--   lastTick, the highest t; serverLogic, whether any ServerLogic was recorded;
--   dropped, the entries the recording says it lost, and gaps = { { t, n } } where;
--   grants[permission] = bool and db[key] = { op, v }, the starting state (noteStart);
--   dbKeys[key] = true for every PersistentDB key the recording touched.
-- `skip` marks a ChatMessage of ChatType.PLUGIN: the plugin's own Chat.AddMessage coming back,
-- which the harness delivers itself.
---@param entries table[]
---@return table timeline
function M.build(entries)
    local tl = {
        ticks = {},
        lastTick = 0,
        serverLogic = false,
        dropped = 0,
        gaps = {},
        grants = {},
        db = {},
        dbKeys = {},
    }
    local lastT = 0
    for i, entry in ipairs(entries) do
        local k, t = entry.k, entry.t
        if k == "session" then
            if entry.schema ~= M.SCHEMA then
                error(
                    string.format(
                        "recording schema %s; the harness replays schema %d",
                        tostring(entry.schema),
                        M.SCHEMA
                    )
                )
            end
        elseif k == "dropped" then
            assert(
                math.type(t) == "integer",
                "recording entry " .. i .. " (dropped) has no integer t"
            )
            tl.dropped = tl.dropped + (entry.n or 0)
            tl.gaps[#tl.gaps + 1] = { t = t, n = entry.n }
        else
            assert(math.type(t) == "integer", "recording entry " .. i .. " has no integer t")
            assert(t >= lastT, "recording entry " .. i .. " goes back in time")
            lastT, tl.lastTick = t, t
            local group = tl.ticks[t] or { leading = {}, events = {} }
            tl.ticks[t] = group
            if k == "read" then
                local read = entry
                if entry.path:match(":GetSlots%(%)$") then
                    read = { k = "read", t = t, path = entry.path, v = integerKeys(entry.v) }
                end
                local event = group.events[#group.events]
                table.insert(event and event.reads or group.leading, read)
            elseif k == "event" then
                local op = entry.op
                if op and op.op == "setInventory" then
                    op = { op = op.op, inv = op.inv, size = op.size, slots = integerKeys(op.slots) }
                end
                local payload = entry.payload or {}
                local skip = entry.name == "ChatMessage" and payload.chatType == PLUGIN_CHAT
                tl.serverLogic = tl.serverLogic or entry.name == "ServerLogic"
                group.events[#group.events + 1] = {
                    entry = { name = entry.name, payload = payload, op = op },
                    reads = {},
                    skip = skip,
                }
            elseif k == "db" or k == "perm" then
                noteStart(tl, entry)
            elseif k ~= "http" then
                error("recording entry " .. i .. " has an unknown kind: " .. tostring(k))
            end
        end
    end
    return tl
end

return M
