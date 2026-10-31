-- The plugin's one console logger: main.lua and the shell modules all log through it, so every
-- line carries [CHORES] (grep: \[CHORES\]). It is a table holding the function, because the
-- client's require gives nil for a module that returns a function (docs/plugin-anatomy.md).

local M = {}

---@param ... any
function M.say(...)
    log("[CHORES]", ...)
end

return M
