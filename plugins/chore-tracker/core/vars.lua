-- Whether a chore's done rule (data/vars.lua) holds on a set of var values, and whether a change
-- of them ticks its chore. Pure: shell/vars.lua reads the vars and asks `ticks`.
--
-- The rule shapes, by example:
--   { chore = "x", done = { { "A", "==", 1 } } }      ticks when A becomes 1
--   { chore = "x", done = { { "A", ">=", "B" } } }    an operand is a var's name or a number
--   { chore = "x", rises = "A" }                      ticks when A goes up (and `done` holds)
--   { chore = "x", done = { ... }, falls = { "A" } }  ticks when `done` turns true as A falls
--   done = { { any = { <comparison>, ... } } }        a condition that is an OR of comparisons
--   near = { x = .., z = .., level = .., range = .. } ticks only with the player that close
--   part = "KEY"                                      marks that part of the chore done instead
--
-- Every condition in `done` must hold (no `done` always holds); a comparison naming a var with
-- no value fails, and an empty `any` never holds. A rule has `rises` or `falls`, not both. A
-- rule without either ticks only when its conditions go from false to true. Every var a rule
-- reads must have had a value before the change: a var's first read is a baseline, never a
-- change.

local detect = require("core/detect")

local M = {}

---@alias ChoreVarOperand string|integer
---@alias ChoreVarCompare "=="|">"|">="
---@alias ChoreVarComparison { [1]: ChoreVarOperand, [2]: ChoreVarCompare, [3]: ChoreVarOperand }

---@class ChoreVarAny
---@field any ChoreVarComparison[] at least one must hold

---@alias ChoreVarCondition ChoreVarComparison|ChoreVarAny

---@class ChoreVarRule
---@field chore string the chore id
---@field done ChoreVarCondition[]? all must hold; none always holds
---@field rises string? a var whose rise ticks the chore
---@field falls string[]? vars of which one falling, as `done` turns true, ticks the chore
---@field near ChoreVarNear? where the player must stand for a change to tick the chore
---@field part string? the part (core/parts.lua) this rule marks done, instead of the chore
---@field proven boolean checked in game (data/vars.lua's header says how)

---@class ChoreVarNear: ChoreTile
---@field range integer tiles from it in each direction

-- A condition's comparisons, any one of which satisfies it: a group's members, or a plain
-- comparison as a group of one.
---@param condition ChoreVarCondition
---@return ChoreVarComparison[]
local function members(condition)
    if condition.any then return condition.any end
    return { condition }
end

-- The var names a rule reads, each once, in the order its conditions name them, then its
-- `rises` var, then its `falls` vars.
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
    ---@param condition ChoreVarComparison
    local function addOperands(condition)
        for _, operand in ipairs({ condition[1], condition[3] }) do
            if type(operand) == "string" then add(operand) end
        end
    end
    for _, condition in ipairs(rule.done or {}) do
        for _, member in ipairs(members(condition)) do
            addOperands(member)
        end
    end
    if rule.rises then add(rule.rises) end
    for _, name in ipairs(rule.falls or {}) do
        add(name)
    end
    return out
end

-- An operand's value, or nil for a var with none.
---@param operand ChoreVarOperand
---@param values table<string, integer>
---@return integer?
local function valueOf(operand, values)
    if type(operand) == "string" then return values[operand] end
    return operand
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

-- Whether one comparison holds; false if an operand can't be worked out.
---@param condition ChoreVarComparison
---@param values table<string, integer>
---@return boolean
local function comparisonHolds(condition, values)
    local a, b = valueOf(condition[1], values), valueOf(condition[3], values)
    return a ~= nil and b ~= nil and compares(a, condition[2], b)
end

-- Whether one condition holds: at least one of its members does.
---@param condition ChoreVarCondition
---@param values table<string, integer>
---@return boolean
local function conditionHolds(condition, values)
    for _, member in ipairs(members(condition)) do
        if comparisonHolds(member, values) then return true end
    end
    return false
end

-- Whether every condition of `rule` holds, given var name -> value.
---@param rule ChoreVarRule
---@param values table<string, integer>
---@return boolean
function M.holds(rule, values)
    for _, condition in ipairs(rule.done or {}) do
        if not conditionHolds(condition, values) then return false end
    end
    return true
end

-- Whether a change of var values from `before` to `after` ticks the rule's chore, as the
-- header describes. A rule with `near` never ticks without the player's `tile`.
---@param rule ChoreVarRule
---@param names string[] the vars the rule reads, as `names` gives them
---@param before table<string, integer>
---@param after table<string, integer>
---@param tile ChoreTile? the player's tile
---@return boolean
function M.ticks(rule, names, before, after, tile)
    local near = rule.near
    if near and not (tile and detect.near(tile, near, near.range)) then return false end
    for _, name in ipairs(names) do
        if before[name] == nil then return false end
    end
    if rule.rises then
        local new = after[rule.rises]
        return new ~= nil and new > before[rule.rises] and M.holds(rule, after)
    end
    if not M.holds(rule, after) or M.holds(rule, before) then return false end
    if not rule.falls then return true end
    for _, name in ipairs(rule.falls) do
        if after[name] ~= nil and after[name] < before[name] then return true end
    end
    return false
end

return M
