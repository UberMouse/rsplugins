-- Ticks chores from the player's own VarPlayer vars: the rules are in data/vars.lua, their
-- logic in core/vars.lua. A var's first value only sets its baseline. main.lua calls scan on
-- each character switch, and for SETTLE_TICKS after it every read only replaces the
-- baseline, so a chore done while the plugin was off is never ticked. main.lua forwards
-- every VarTransmit and calls tick each Logic tick; this module keeps only the last values
-- read, no chore state.

local period = require("core/period")
local state = require("core/state")
local varsCore = require("core/vars")

local M = {}

-- 10 s of Logic ticks (50 a second, docs/api-concepts.md "Tick rates"): the window in which
-- the login's burst of var updates arrives, so they aren't taken for the player doing a chore.
local SETTLE_TICKS = 500

---@class ChoreVarOptions
---@field chores Chore[]
---@field rules ChoreVarRule[]
---@field say fun(...: any)
---@field apply fun(change: ChoreChange) as ChoreDetectOptions.apply

local options = nil ---@type ChoreVarOptions?
-- The rules whose vars the client's config has all of, each with the names it reads and its
-- chore.
local watched = {} ---@type { rule: ChoreVarRule, names: string[], chore: Chore }[]
local varTypes = {} ---@type table<string, VarType>
-- Base var id -> the watched names packed in it (or the base itself, if watched).
local byBase = {} ---@type table<integer, string[]>
-- The last value read of each watched var; a var whose value isn't a whole number has none.
local values = {} ---@type table<string, integer>
-- Logic ticks left until a changed var can tick a chore.
local settling = 0

-- The base var holding `v`: itself unless it's a VarBit.
---@param v VarType
---@return VarType
local function baseOf(v)
    return v.isVarBit and v.baseVar or v
end

---@param o ChoreVarOptions
function M.init(o)
    options = o
    watched, varTypes, byBase, values, settling = {}, {}, {}, {}, 0
    -- A name the client's config lacks (a game update renamed it, say) is said once, and
    -- every rule using it is dropped, so a nil VarType is never read. The cast drops
    -- var.VarPlayer's FromID member from the type.
    local missing = {}
    for _, rule in ipairs(o.rules) do
        -- Resolved for every rule, watched or not, so a bad chore id fails at load.
        local chore = state.resolve(o.chores, rule.chore, "data/vars.lua")
        local names, complete = varsCore.names(rule), true
        for _, name in ipairs(names) do
            if not varTypes[name] and not missing[name] then
                -- The client reads nil for an unknown name, without raising
                -- (docs/api-concepts.md#configs-vs-entities).
                local v = var.VarPlayer[name] --[[@as VarType?]]
                if v then
                    varTypes[name] = v
                else
                    missing[name] = true
                    o.say("unknown var", name .. "; not watched")
                end
            end
            if missing[name] then complete = false end
        end
        if complete then watched[#watched + 1] = { rule = rule, names = names, chore = chore } end
    end
    -- Bases are matched by id, resolved once here: whether the client hands out the same
    -- VarType object for a base each time is unconfirmed.
    local listed = {}
    for _, entry in ipairs(watched) do
        for _, name in ipairs(entry.names) do
            if not listed[name] then
                listed[name] = true
                local id = baseOf(varTypes[name]).id
                byBase[id] = byBase[id] or {}
                table.insert(byBase[id], name)
            end
        end
    end
end

-- A watched var's value, or nil if it isn't a whole number.
---@param name string
---@return integer?
local function read(name)
    local value = varTypes[name].value
    return type(value) == "number" and math.tointeger(value) or nil
end

-- Read every watched var as the new baseline, and settle for SETTLE_TICKS. main.lua calls
-- it on each character switch, so one character's values are never compared with another's.
function M.scan()
    values = {}
    for _, names in pairs(byBase) do
        for _, name in ipairs(names) do
            values[name] = read(name)
        end
    end
    settling = SETTLE_TICKS
end

-- One Logic tick of the settle window.
function M.tick()
    if settling > 0 then settling = settling - 1 end
end

-- The first var of `names` in `changed`, or nil.
---@param names string[]
---@param changed table<string, true>
---@return string?
local function firstChanged(names, changed)
    for _, name in ipairs(names) do
        if changed[name] then return name end
    end
    return nil
end

-- Watched vars changed from `before` to `after`: tick each chore whose rule reads one of
-- them and whose change ticks it (core/vars.lua's ticks), if it isn't done this period,
-- logging only a tick.
---@param before table<string, integer>
---@param after table<string, integer>
---@param changed table<string, true>
local function onChanged(before, after, changed)
    assert(options, "init runs before any var event")
    local say = options.say
    options.apply(function(tracker, now)
        local day = period.runeDay(now)
        for _, entry in ipairs(watched) do
            local cause = firstChanged(entry.names, changed)
            if cause and varsCore.ticks(entry.rule, before, after, day) then
                local ticked = state.autoMark(tracker, entry.chore, now)
                if ticked ~= tracker then
                    say("seen", entry.chore.id, "done", "(" .. cause .. ")")
                end
                tracker = ticked
            end
        end
        return tracker
    end)
end

-- A var update names either its base var or the one VarBit that changed
-- (docs/api-concepts.md), so either way re-read the watched vars of that base. A var of any
-- other base returns after one table lookup.
---@param ev VarTransmitEventPayload
function M.onVarTransmit(ev)
    local base = baseOf(ev.var)
    local names = byBase[base.id]
    -- Var ids repeat across domains, so a VarClient with a watched base's id is no match.
    if not names or base.typeName ~= "VarPlayer" then return end
    -- The VarBit that moved may be unwatched, so `after` is copied only on a change.
    local before = values
    local after = nil ---@type table<string, integer>?
    local changed = nil ---@type table<string, true>?
    for _, name in ipairs(names) do
        local value = read(name)
        if value ~= before[name] then
            if not after then
                after, changed = {}, {}
                for n, v in pairs(before) do
                    after[n] = v
                end
            end
            after[name] = value
            changed[name] = true
        end
    end
    if not after or not changed then return end
    values = after
    if settling == 0 then onChanged(before, after, changed) end
end

return M
