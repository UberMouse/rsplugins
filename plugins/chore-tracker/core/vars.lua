-- Whether a chore's done rule (data/vars.lua) holds on a set of var values, as plain data.
-- shell/vars.lua reads the vars and asks `ticks` whether a change ticks a chore; nothing
-- here touches the game.
--
-- A rule is a list of conditions that must all hold (an empty list always holds). Each
-- condition compares two operands with "==", ">" or ">=". An operand is a var's name (its
-- value), a number, or `{ runeDay = true }` (today's RuneDay, the game's day number). A
-- condition with an operand it can't work out (a var with no value, or the RuneDay without a
-- clock) doesn't hold. A rule may also name, as `rises`, a var whose going up is what ticks
-- its chore.

local M = {}

---@class ChoreVarToday
---@field runeDay true

---@alias ChoreVarOperand string|integer|ChoreVarToday
---@alias ChoreVarCompare "=="|">"|">="
---@alias ChoreVarCondition { [1]: ChoreVarOperand, [2]: ChoreVarCompare, [3]: ChoreVarOperand }

---@class ChoreVarRule
---@field chore string the chore id
---@field done ChoreVarCondition[] all must hold for the chore to be done
---@field rises string? a var whose rise in a change ticks the chore
---@field proven boolean

-- The var names a rule reads, each once, in the order its conditions name them, then its
-- `rises` var.
---@param rule ChoreVarRule
---@return string[]
function M.names(rule)
    local out, seen = {}, {}
    ---@param name string
    local function add(name)
        if not seen[name] then
            seen[name] = true
            out[#out + 1] = name
        end
    end
    for _, condition in ipairs(rule.done) do
        for _, operand in ipairs({ condition[1], condition[3] }) do
            if type(operand) == "string" then add(operand) end
        end
    end
    if rule.rises then add(rule.rises) end
    return out
end

-- An operand's value, or nil if a var it needs has none or it needs the RuneDay and there
-- is none.
---@param operand ChoreVarOperand
---@param values table<string, integer>
---@param day integer?
---@return integer?
local function valueOf(operand, values, day)
    if type(operand) == "string" then return values[operand] end
    if type(operand) == "number" then return operand end
    return day
end

---@param a integer
---@param compare ChoreVarCompare
---@param b integer
---@return boolean
local function compares(a, compare, b)
    if compare == "==" then return a == b end
    if compare == ">" then return a > b end
    if compare == ">=" then return a >= b end
    error("unknown comparison " .. tostring(compare), 2)
end

-- Whether every condition of `rule` holds, given var name -> value and today's RuneDay
-- (nil without a clock).
---@param rule ChoreVarRule
---@param values table<string, integer>
---@param day integer?
---@return boolean
function M.holds(rule, values, day)
    for _, condition in ipairs(rule.done) do
        local a, b = valueOf(condition[1], values, day), valueOf(condition[3], values, day)
        if a == nil or b == nil or not compares(a, condition[2], b) then return false end
    end
    return true
end

-- Whether a change of var values from `before` to `after` ticks the rule's chore. A rule
-- with a `rises` var ticks when that var went up and its conditions hold on `after`; one
-- without ticks when its conditions turned from false to true. Either way every var it reads
-- must have had a value before: a var with none is read for the first time, which is a
-- baseline, not a change.
---@param rule ChoreVarRule
---@param before table<string, integer>
---@param after table<string, integer>
---@param day integer?
---@return boolean
function M.ticks(rule, before, after, day)
    for _, name in ipairs(M.names(rule)) do
        if before[name] == nil then return false end
    end
    if rule.rises then
        local new = after[rule.rises]
        return new ~= nil and new > before[rule.rises] and M.holds(rule, after, day)
    end
    return not M.holds(rule, before, day) and M.holds(rule, after, day)
end

return M
