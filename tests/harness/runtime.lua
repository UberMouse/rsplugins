-- Runs plugin code the way the client does, and turns client failures into test failures.
--
--   * Time budget: the client aborts any Lua call that runs past 1000 ms with "Maximum
--     function execution time of 1000 ms exceeded" (docs/api-concepts.md, "Runtime limits we've
--     hit"). A count hook checks the wall clock every HOOK_INTERVAL VM instructions and raises
--     the same message, so a runaway loop fails fast instead of hanging the suite.
--   * Errors: the client logs a callback's error to its console; a test should fail instead, so
--     the error is re-raised with `label` (e.g. "Event.Logic subscriber 'tick'") in front.
--   * Swallowed faults: if the plugin pcall'd an API call and so hid a harness fault (an
--     unmocked API, say), the fault is raised once the call returns.

local system = require("system")
local strict = require("tests.harness.strict")

local M = {}

-- How many VM instructions run between budget checks.
local HOOK_INTERVAL = 10000

-- Whether a plugin call is already running. Nested calls (require inside main.lua) run inside
-- the outer call's budget.
local running = false

---@param budgetMs number
---@return string
local function budgetMessage(budgetMs)
    return string.format("Maximum function execution time of %d ms exceeded", budgetMs)
end

-- Call plugin function `fn` with the client's limits; returns whatever it returns.
---@param budgetMs number
---@param label string what is being called, for the failure message
---@param fn function
---@return any ...
function M.call(budgetMs, label, fn, ...)
    if running then return fn(...) end

    local limit = budgetMs / 1000
    local start = system.monotime()
    local faults = #strict.faults
    local expired = false
    local oldHook, oldMask, oldCount = debug.gethook()
    -- Once expired, keep raising at every check so a pcall in the plugin can't swallow it.
    debug.sethook(function()
        if expired or system.monotime() - start > limit then
            expired = true
            error(budgetMessage(budgetMs), 2)
        end
    end, "", HOOK_INTERVAL)
    running = true
    local results = table.pack(xpcall(fn, debug.traceback, ...))
    running = false
    debug.sethook(oldHook, oldMask, oldCount)

    -- Time spent inside one C call (a huge string.rep, say) never reaches the hook.
    if expired or system.monotime() - start > limit then
        error(label .. ": " .. budgetMessage(budgetMs), 0)
    end
    if not results[1] then error(label .. ": " .. tostring(results[2]), 0) end
    if #strict.faults > faults then
        error(
            label
                .. ": the plugin caught a harness error (pcall?) and carried on: "
                .. strict.faults[faults + 1],
            0
        )
    end
    return table.unpack(results, 2, results.n)
end

return M
