-- Runs plugin code the way the client does, and turns client failures into test failures.
--
--   * Time budget: the client aborts any Lua call that runs past 1000 ms with "Maximum
--     function execution time of 1000 ms exceeded" (docs/api-concepts.md, "Runtime limits we've
--     hit"). A count hook checks the wall clock every HOOK_INTERVAL VM instructions and raises
--     the same message, so a runaway loop fails fast instead of hanging the suite. Coroutines
--     don't inherit a hook, so the sandbox's coroutine.create/wrap put each new thread under the
--     same hook (watch); it checks whichever call is running, so a coroutine resumed from a
--     later callback counts against that callback.
--   * Errors: the client logs a callback's error to its console; a test should fail instead, so
--     the error is re-raised with `label` (e.g. "Event.Logic subscriber 'tick'") in front.
--   * Swallowed faults: if the plugin pcall'd an API call and so hid a harness fault (an
--     unmocked API, say), the fault is raised once the call returns.

local system = require("system")
local strict = require("tests.harness.strict")

local M = {}

-- How many VM instructions run between budget checks.
local HOOK_INTERVAL = 10000

-- The running plugin call's budget, nil between calls. Nested calls (require inside main.lua)
-- run inside the outer call's budget.
local budget = nil ---@type { start: number, limit: number, ms: number, expired: boolean }?

---@param budgetMs number
---@return string
local function budgetMessage(budgetMs)
    return string.format("Maximum function execution time of %d ms exceeded", budgetMs)
end

---@return boolean
local function overBudget()
    assert(budget, "only checked during a plugin call")
    return budget.expired or system.monotime() - budget.start > budget.limit
end

-- The count hook, on the main thread and on every plugin coroutine. Once expired it keeps
-- raising at every check, so a pcall or coroutine.resume in the plugin can't swallow it.
local function check()
    if budget and overBudget() then
        budget.expired = true
        error(budgetMessage(budget.ms), 2)
    end
end

-- Put a coroutine the plugin created under the time budget.
---@param thread thread
function M.watch(thread)
    debug.sethook(thread, check, "", HOOK_INTERVAL)
end

-- Call plugin function `fn` with the client's limits; returns whatever it returns.
---@param budgetMs number
---@param label string what is being called, for the failure message
---@param fn function
---@return any ...
function M.call(budgetMs, label, fn, ...)
    if budget then return fn(...) end

    budget = { start = system.monotime(), limit = budgetMs / 1000, ms = budgetMs, expired = false }
    local faults = #strict.faults
    local oldHook, oldMask, oldCount = debug.gethook()
    debug.sethook(check, "", HOOK_INTERVAL)
    local results = table.pack(xpcall(fn, debug.traceback, ...))
    debug.sethook(oldHook, oldMask, oldCount)
    -- Time spent inside one C call (a huge string.rep, say) never reaches the hook.
    local expired = overBudget()
    budget = nil

    if expired then error(label .. ": " .. budgetMessage(budgetMs), 0) end
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
