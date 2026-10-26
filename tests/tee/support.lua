-- Shared helpers for the dev log tee's specs: inline test plugins that carry lib/dev/ as their
-- dev/ folder, and reading back the batches the tee POSTed.

local dkjson = require("dkjson")
local paths = require("tests.harness.paths")

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
    local files = { ["main.lua"] = main, ["plugin.json"] = manifest or M.MANIFEST }
    for _, name in ipairs({ "tee", "teelog", "recorder", "recording", "json", "payloads" }) do
        files["dev/" .. name .. ".lua"] =
            assert(paths.read(paths.repo("lib/dev/" .. name .. ".lua")))
    end
    return files
end

-- The tee's requests, in order.
---@param h table
---@param url string?
---@return table[]
function M.posts(h, url)
    local out = {}
    for _, record in ipairs(h.requests) do
        if record.url == (url or M.URL) then out[#out + 1] = record end
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

-- Every line in every batch so far, in order.
---@param h table
---@return table[]
function M.lines(h)
    local out = {}
    for _, batch in ipairs(M.batches(h)) do
        for _, line in ipairs(batch.lines) do
            out[#out + 1] = line
        end
    end
    return out
end

-- The text of every line, in order.
---@param h table
---@return string[]
function M.texts(h)
    local out = {}
    for i, line in ipairs(M.lines(h)) do
        out[i] = line.text
    end
    return out
end

-- Answer every tee request not yet answered.
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
function M.count(h, text)
    local n = 0
    for _, line in ipairs(h.console) do
        if line.text:find(text, 1, true) then n = n + 1 end
    end
    return n
end

return M
