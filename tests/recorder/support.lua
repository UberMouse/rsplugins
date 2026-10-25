-- Shared helpers for the dev recorder's specs: inline test plugins that carry lib/dev/ as
-- their dev/ folder, and reading back the batches the recorder POSTed.

local dkjson = require("dkjson")
local harness = require("tests.harness")
local paths = require("tests.harness.paths")

local M = {}

M.RECORDER_URL = "http://127.0.0.1:8766/record"

-- A manifest with the recorder's url and permission, plus an `api` url for the plugin's own
-- requests.
M.MANIFEST = [[{
    "name": "T", "version": "0.0.1", "contactEmailAddress": "t@example.com",
    "optionalPermissions": [ "httpAccess" ],
    "urls": { "recorder": "http://127.0.0.1:8766", "api": "http://127.0.0.1:9000" }
}]]

-- What every recording test plugin starts with.
M.INSTALL = 'local recorder = require("dev/recorder")\nrecorder.install(_ENV, "t")\n'

-- An inline plugin: main.lua, a manifest (M.MANIFEST by default) and lib/dev/ as dev/.
---@param main string
---@param manifest string?
---@return table
function M.plugin(main, manifest)
    local files = { ["main.lua"] = main, ["plugin.json"] = manifest or M.MANIFEST }
    for _, name in ipairs({ "recorder", "recording", "json", "payloads" }) do
        files["dev/" .. name .. ".lua"] =
            assert(paths.read(paths.repo("lib/dev/" .. name .. ".lua")))
    end
    return files
end

-- plugins/recorder-demo with a world it can read: vars set before load (so VarTransmit has an
-- oldValue), logged in, a backpack. The demo's probe reads os and io, hence the opt-in.
---@param grant string[]?
---@return table h
function M.demo(grant)
    local h = harness.new("recorder-demo", {
        grant = grant or { "httpAccess", "chatAccess" },
        stdlib = { os = true, io = true },
    })
    h.world:setVar("VarPlayer", "QP", 10)
    h.world:setVar("VarPlayer", "OPTION_RUN", 0)
    h.world:setVar("VarPlayer", "CLOCK_TIME_DATE_MINUTES", 5)
    h.world:login("Zezima")
    h.world:setInventory("INV", { [1] = { obj = "LOGS", count = 5 } }, 28)
    h:load()
    return h
end

-- The recorder's requests, in order.
---@param h table
---@return table[]
function M.posts(h)
    local out = {}
    for _, record in ipairs(h.requests) do
        if record.url == M.RECORDER_URL then out[#out + 1] = record end
    end
    return out
end

-- Every batch POSTed so far, decoded.
---@param h table
---@return table[]
function M.batches(h)
    local out = {}
    for i, record in ipairs(M.posts(h)) do
        out[i] = assert(dkjson.decode(record.body), "batch body is not JSON")
    end
    return out
end

-- Every entry in every batch so far, in order.
---@param h table
---@return table[]
function M.entries(h)
    local out = {}
    for _, batch in ipairs(M.batches(h)) do
        for _, entry in ipairs(batch.entries) do
            out[#out + 1] = entry
        end
    end
    return out
end

-- The entries whose fields include all of `fields`.
---@param list table[]
---@param fields table
---@return table[]
function M.where(list, fields)
    local out = {}
    for _, entry in ipairs(list) do
        local match = true
        for k, v in pairs(fields) do
            match = match and entry[k] == v
        end
        if match then out[#out + 1] = entry end
    end
    return out
end

-- Answer every recorder request not yet answered.
---@param h table
---@param response table?
function M.answer(h, response)
    for _, record in ipairs(M.posts(h)) do
        if not record.response then h:respond(record, response or { status = 200 }) end
    end
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

return M
