-- Whether a chore's done rule (data/vars.lua) holds on a set of var values, as plain data.
-- shell/vars.lua reads the vars and asks `ticks` whether a change ticks a chore; nothing
-- here touches the game.
--
-- A rule is a list of conditions that must all hold (an empty list always holds). Each
-- condition compares two operands with "==", ">" or ">=". An operand is a var's name (its
-- value), a number, or `{ runeDay = true }` (today's RuneDay, the game's day number). A
-- condition with an operand it can't work out (a var with no value, or the RuneDay without a
-- clock) doesn't hold. A condition may instead be `{ any = { <condition>, ... } }`, which
-- holds when at least one of its member conditions does (an OR; members are plain
-- conditions, not further groups, and an empty group never holds). A rule may also name, as
-- `rises`, a var whose going up is what ticks its chore, or, as `falls`, a list of vars whose
-- going down does: it ticks only on a change where its conditions turned from false to true
-- and at least one of those vars went down. A rule has `rises` or `falls`, not both. A rule
-- may also name a tile it must be seen `near` (core/detect.lua's near): it ticks only while
-- the player stands within range of it, for a var that other places move too. A rule naming
-- a `part` marks that part done rather than the chore (shell/vars.lua).
--
-- data/vars.lua is typed `---@type ChoreVarRule[]`, so LuaLS checks its operators and
-- operands against the class below.

local detect = require("core/detect")

local M = {}

---@class ChoreVarToday
---@field runeDay true

---@alias ChoreVarOperand string|integer|ChoreVarToday
---@alias ChoreVarCompare "=="|">"|">="
---@alias ChoreVarComparison { [1]: ChoreVarOperand, [2]: ChoreVarCompare, [3]: ChoreVarOperand }

---@class ChoreVarAny
---@field any ChoreVarComparison[] at least one must hold

---@alias ChoreVarCondition ChoreVarComparison|ChoreVarAny

---@class ChoreVarRule
---@field chore string the chore id
---@field done ChoreVarCondition[] all must hold for the chore to be done
---@field rises string? a var whose rise in a change ticks the chore
---@field falls string[]? vars of which a fall, in a change that makes the conditions hold, ticks the chore
---@field near ChoreVarNear? where the player must stand for a change to tick the chore
---@field part string? for a chore done at several parts (core/parts.lua): the part this rule
---sees done, so a change counts towards the chore's count instead of ticking it
---@field proven boolean

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
    for _, condition in ipairs(rule.done) do
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

-- Whether one comparison holds; false if an operand can't be worked out.
---@param condition ChoreVarComparison
---@param values table<string, integer>
---@param day integer?
---@return boolean
local function comparisonHolds(condition, values, day)
    local a, b = valueOf(condition[1], values, day), valueOf(condition[3], values, day)
    return a ~= nil and b ~= nil and compares(a, condition[2], b)
end

-- Whether one condition holds: at least one of its members does.
---@param condition ChoreVarCondition
---@param values table<string, integer>
---@param day integer?
---@return boolean
local function conditionHolds(condition, values, day)
    for _, member in ipairs(members(condition)) do
        if comparisonHolds(member, values, day) then return true end
    end
    return false
end

-- Whether every condition of `rule` holds, given var name -> value and today's RuneDay
-- (nil without a clock).
---@param rule ChoreVarRule
---@param values table<string, integer>
---@param day integer?
---@return boolean
function M.holds(rule, values, day)
    for _, condition in ipairs(rule.done) do
        if not conditionHolds(condition, values, day) then return false end
    end
    return true
end

-- Whether a change of var values from `before` to `after` ticks the rule's chore. A rule
-- with a `rises` var ticks when that var went up and its conditions hold on `after`; one
-- without ticks when its conditions turned from false to true. Either way every var it reads
-- must have had a value before: a var with none is read for the first time, which is a
-- baseline, not a change. A rule with `falls` ticks when its conditions turned from false to
-- true and one of its `falls` vars went down. A rule with `near` ticks only with the player's
-- `tile` within its range (never without a tile).
---@param rule ChoreVarRule
---@param before table<string, integer>
---@param after table<string, integer>
---@param day integer?
---@param tile ChoreTile? the player's tile
---@return boolean
function M.ticks(rule, before, after, day, tile)
    local near = rule.near
    if near and not (tile and detect.near(tile, near, near.range)) then return false end
    for _, name in ipairs(M.names(rule)) do
        if before[name] == nil then return false end
    end
    if rule.rises then
        local new = after[rule.rises]
        return new ~= nil and new > before[rule.rises] and M.holds(rule, after, day)
    end
    if not M.holds(rule, after, day) or M.holds(rule, before, day) then return false end
    if not rule.falls then return true end
    for _, name in ipairs(rule.falls) do
        if after[name] ~= nil and after[name] < before[name] then return true end
    end
    return false
end

return M
