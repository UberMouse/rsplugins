-- The plugin's one console logger: main.lua and the shell modules all log through it, so every
-- line carries [CHORES] (grep: \[CHORES\]). It returns a table holding the function, because
-- the client's require doesn't hand back a module's function, only a table.

local M = {}

---@param ... any
function M.say(...)
    log("[CHORES]", ...)
end

return M
