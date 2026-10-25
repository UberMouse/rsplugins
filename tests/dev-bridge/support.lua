-- Shared helpers for the dev bridge's specs. Its modules require paths relative to the plugin
-- root (docs/plugin-anatomy.md), so the plugin root goes first on the module path; dev/ is
-- found through lib/ (.busted).

local dkjson = require("dkjson")
local harness = require("tests.harness")

local root = "./plugins/dev-bridge/?.lua;"
if package.path:sub(1, #root) ~= root then package.path = root .. package.path end

local M = {}

M.SYNC_URL = "http://127.0.0.1:8766/bridge/sync"

-- The globals the bridge reports in hello.env that the sandbox doesn't provide. Whether the
-- client has them is what the report is for; these specs model a client without them.
M.ABSENT = { "load", "loadstring", "debug", "os", "io" }

-- plugins/dev-bridge, not yet loaded, with `grant` (default both of its permissions).
---@param grant string[]?
---@return table h
function M.new(grant)
    return harness.new(
        "dev-bridge",
        { grant = grant or { "httpAccess", "chatAccess" }, absent = M.ABSENT }
    )
end

-- M.new, loaded.
---@param grant string[]?
---@return table h
function M.load(grant)
    local h = M.new(grant)
    h:load()
    return h
end

-- The bridge's sync requests, in order.
---@param h table
---@return table[]
function M.syncs(h)
    local out = {}
    for _, record in ipairs(h.requests) do
        if record.url == M.SYNC_URL then out[#out + 1] = record end
    end
    return out
end

-- The sync requests not yet answered.
---@param h table
---@return table[]
function M.open(h)
    local out = {}
    for _, record in ipairs(M.syncs(h)) do
        if not record.response then out[#out + 1] = record end
    end
    return out
end

-- A sync's body, decoded.
---@param record table
---@return table
function M.body(record)
    return assert(dkjson.decode(record.body), "sync body is not JSON")
end

-- The latest sync, decoded.
---@param h table
---@return table
function M.last(h)
    local all = M.syncs(h)
    return M.body(assert(all[#all], "no sync started"))
end

-- Answer the one open sync with `response` (a 200 with an empty body by default), then step
-- once so it is delivered.
---@param h table
---@param response table?
function M.answer(h, response)
    local open = M.open(h)
    assert(#open == 1, "expected one open sync, found " .. #open)
    h:respond(open[1], response or { status = 200, body = "" })
    h:step()
end

-- A reply body line, escaped the way scripts/rsdev.py's escape_arg does.
---@param id string
---@param kind string
---@param arg string
---@return string
function M.line(id, kind, arg)
    local escaped = arg:gsub("\\", "\\\\"):gsub("\t", "\\t"):gsub("\n", "\\n"):gsub("\r", "\\r")
    return id .. "\t" .. kind .. "\t" .. escaped .. "\n"
end

-- How many console lines contain `text`.
---@param h table
---@param text string
---@return integer
function M.lines(h, text)
    local n = 0
    for _, line in ipairs(h.console) do
        if line.text:find(text, 1, true) then n = n + 1 end
    end
    return n
end

-- The console commands run so far after the three self-grant ones.
---@param h table
---@return string[]
function M.ran(h)
    return { table.unpack(h.consoleCommands, 4) }
end

return M
