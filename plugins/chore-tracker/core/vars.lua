-- Whether a chore's done rule (data/vars.lua) holds on a set of var values, as plain data.
-- shell/vars.lua reads the vars and decides when a rule turning true ticks a chore; nothing
-- here touches the game.
--
-- A rule is a list of conditions that must all hold. Each condition compares two operands
-- with "==", ">" or ">=". An operand is a var's name (its value), a number, `{ nonZero =
-- { names } }` (how many of those vars are not 0), or `{ runeDay = true }` (today's RuneDay,
-- the game's day number). A condition with an operand it can't work out (a var with no
-- value, or the RuneDay without a clock) doesn't hold.

local M = {}

---@class ChoreVarCount
---@field nonZero string[]

---@class ChoreVarToday
---@field runeDay true

---@alias ChoreVarOperand string|integer|ChoreVarCount|ChoreVarToday
---@alias ChoreVarCompare "=="|">"|">="
---@alias ChoreVarCondition { [1]: ChoreVarOperand, [2]: ChoreVarCompare, [3]: ChoreVarOperand }

---@class ChoreVarRule
---@field chore string the chore id
---@field done ChoreVarCondition[] all must hold for the chore to be done
---@field proven boolean

local MINUTES_PER_DAY = 1440
-- RuneDay 0 is 2002-02-27, day 11745 counted from 1970-01-01. Checked against the game:
-- PENG_SPY_PL_DAY read 9002 on Wednesday 2026-10-21.
local RUNEDAY_EPOCH = 11745

-- The RuneDay of an epoch minute (minutes since 1970-01-01 00:00 UTC, the clock var's unit).
---@param minutes integer
---@return integer
function M.runeDay(minutes)
    return minutes // MINUTES_PER_DAY - RUNEDAY_EPOCH
end

-- The var names a rule reads, each once, in the order it names them.
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
            if type(operand) == "string" then
                add(operand)
            elseif type(operand) == "table" and operand.nonZero then
                for _, name in ipairs(operand.nonZero) do
                    add(name)
                end
            end
        end
    end
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
    if operand.runeDay then return day end
    local count = 0
    for _, name in ipairs(operand.nonZero) do
        local value = values[name]
        if value == nil then return nil end
        if value ~= 0 then count = count + 1 end
    end
    return count
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

return M
