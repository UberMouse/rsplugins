-- The plugin's one console logger: main.lua and the shell modules all log through it, so every
-- line carries [CHORES] (grep: \[CHORES\]).

---@param ... any
local function say(...)
    log("[CHORES]", ...)
end

return say
