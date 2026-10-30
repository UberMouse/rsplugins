-- Shared helpers for the dev log tee's specs: inline test plugins that carry lib/dev/ as their
-- dev/ folder, and reading back the batches the tee POSTed.

local devplugin = require("tests.support.devplugin")
local harness = require("tests.harness")

local M = {}

M.URL = "http://127.0.0.1:8766/tee"

-- A manifest with the tee's url and permission.
M.MANIFEST = [[{
    "name": "T", "version": "0.0.1", "contactEmailAddress": "t@example.com",
    "optionalPermissions": [ "httpAccess" ],
    "urls": { "rsdev": "http://127.0.0.1:8766" }
}]]

-- What every tee test plugin starts with.
M.INSTALL = 'local tee = require("dev/tee")\ntee.install(_ENV, "t")\n'

-- An inline plugin: main.lua, a manifest (M.MANIFEST by default) and lib/dev/ as dev/.
---@param main string
---@param manifest string?
---@return table
function M.plugin(main, manifest)
    return devplugin.inlinePlugin(main, manifest or M.MANIFEST)
end

-- The tee's requests, in order.
---@param h table
---@return table[]
function M.posts(h)
    return h:requestsTo(M.URL)
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

-- Every line in every batch so far, in order.
---@param h table
---@return table[]
function M.batchLines(h)
    local out = {}
    for _, batch in ipairs(M.batches(h)) do
        for _, line in ipairs(batch.lines) do
            out[#out + 1] = line
        end
    end
    return out
end

-- The text of every batch line, in order.
---@param h table
---@return string[]
function M.batchTexts(h)
    local out = {}
    for i, line in ipairs(M.batchLines(h)) do
        out[i] = line.text
    end
    return out
end

-- Answer every tee request not yet answered.
---@param h table
---@param response table?
function M.answer(h, response)
    h:answerAll(M.URL, response)
end

return M
