-- Inline test plugins that carry lib/dev/ as their dev/ folder, for the specs of the dev tools
-- (recorder, tee). One list of modules: they require each other, so every inline plugin gets
-- all of them, and a new lib/dev module is added here once.

local paths = require("tests.harness.paths")

local M = {}

M.MODULES = { "json", "payloads", "recorder", "recording", "tee", "teelog" }

-- The files table for harness.new: main.lua, plugin.json and lib/dev/ as dev/.
---@param main string
---@param manifest string
---@return table
function M.inlinePlugin(main, manifest)
    local files = { ["main.lua"] = main, ["plugin.json"] = manifest }
    for _, name in ipairs(M.MODULES) do
        files["dev/" .. name .. ".lua"] =
            assert(paths.read(paths.repo("lib/dev/" .. name .. ".lua")))
    end
    return files
end

return M
