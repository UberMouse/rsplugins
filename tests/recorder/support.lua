-- Shared helpers for the dev recorder's specs: inline test plugins that carry lib/dev/ as
-- their dev/ folder, and reading back the batches the recorder POSTed.

local devplugin = require("tests.support.devplugin")
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
    return devplugin.inlinePlugin(main, manifest or M.MANIFEST)
end

-- plugins/recorder-demo with a world it can read: vars set before load (so VarTransmit has an
-- oldValue), logged in, a backpack. The demo's probe reads os and io, hence the opt-in.
---@param opts table? { grant = string[] (default httpAccess and chatAccess), clock = integer
---  (CLOCK_TIME_DATE_MINUTES, default 5), db = table (PersistentDB entries set before load) }
---@return table h
function M.demo(opts)
    opts = opts or {}
    local h = harness.new("recorder-demo", {
        grant = opts.grant or { "httpAccess", "chatAccess" },
        stdlib = { os = true, io = true },
    })
    for key, entry in pairs(opts.db or {}) do
        h.db[key] = entry
    end
    h.world:setVar("VarPlayer", "QP", 10)
    h.world:setVar("VarPlayer", "OPTION_RUN", 0)
    h.world:setVar("VarPlayer", "CLOCK_TIME_DATE_MINUTES", opts.clock or 5)
    h.world:login("Zezima")
    h.world:setInventory("INV", { [1] = { obj = "LOGS", count = 5 } }, 28)
    h:load()
    return h
end

-- plugins/recorder-demo without dev/, so it runs unrecorded: for replaying its recordings.
---@return table # inline files for harness.new
function M.demoFiles()
    local files = {}
    for _, name in ipairs({ "main.lua", "envprobe.lua", "plugin.json" }) do
        files[name] = assert(paths.read(paths.repo("plugins/recorder-demo/" .. name)))
    end
    return files
end

-- The recorder's requests, in order.
---@param h table
---@return table[]
function M.posts(h)
    return h:requestsTo(M.RECORDER_URL)
end

-- Every batch POSTed so far, decoded.
---@param h table
---@return table[]
function M.batches(h)
    local out = {}
    for i, record in ipairs(M.posts(h)) do
        out[i] = harness.decodeJson(record.body, "batch body")
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
    h:answerAll(M.RECORDER_URL, response)
end

return M
