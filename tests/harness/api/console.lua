-- ExecuteConsoleCommand. Nothing is run: each command is appended to h.consoleCommands, and if
-- the test set h.onConsoleCommand, that is called with it (raise there to model a command
-- that errors).
--
-- From https://developer.runescape.com/rs/core/index.html#executeconsolecommand:
-- `ExecuteConsoleCommand(command: String)`, no return value. What any command does in the
-- client (`ppe` granting a permission, say) isn't modelled: the test changes the world itself.

local strict = require("tests.harness.strict")

local M = {}

---@param h table the harness
---@param env table the sandbox being built
function M.install(h, env)
    env.ExecuteConsoleCommand = function(command)
        if type(command) ~= "string" then strict.fault("ExecuteConsoleCommand(command: String)") end
        h.consoleCommands[#h.consoleCommands + 1] = command
        if h.onConsoleCommand then h.onConsoleCommand(command) end
    end
end

return M
