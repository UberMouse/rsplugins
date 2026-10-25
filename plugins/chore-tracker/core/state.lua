-- The tracker's state: which chores the player picked, and when each was last marked done.
-- The functions are pure: those that change the state return a new one and leave the one
-- they were given untouched.
-- The chore list is passed in (not required here), so tests can use small hand-made lists.
--
-- A completion is stored as the epoch minute it was marked. It counts as done while that
-- minute is inside the chore's current period, so a reset needs no timer or explicit step:
-- once the period rolls over, the old minute is simply before its start. Sub-daily chores
-- ("Every 6H", "2x a day") keep dailyscape's daily period.

local period = require("core/period")

local M = {}

-- The persisted shape's version. deserialise ignores any other.
M.VERSION = 1

---@class Chore
---@field id string dailyscape's key
---@field name string
---@field period ChorePeriod
---@field shop boolean
---@field url string
---@field desc string plain text; `<br>` is its only markup
---@field links string[]

---@class ChoreState
---@field selected string[] picked chore ids, in chore-list order
---@field done table<string, integer> chore id -> epoch minute it was marked done

-- An empty state: nothing selected, nothing done.
---@return ChoreState
function M.new()
    return { selected = {}, done = {} }
end

---@param selected string[]
---@return string[]
local function copySelected(selected)
    return table.move(selected, 1, #selected, 1, {})
end

---@param done table<string, integer>
---@return table<string, integer>
local function copyDone(done)
    local out = {}
    for id, minute in pairs(done) do
        out[id] = minute
    end
    return out
end

-- A copy of `state`, so callers can change it without touching the original.
---@param state ChoreState
---@return ChoreState
local function copy(state)
    return { selected = copySelected(state.selected), done = copyDone(state.done) }
end

-- The chore with this id, or nil if the list has none.
---@param chores Chore[]
---@param id any
---@return Chore?
function M.find(chores, id)
    for _, chore in ipairs(chores) do
        if chore.id == id then return chore end
    end
    return nil
end

-- The ids in `chores` that pass `keep`, in chore-list order.
---@param chores Chore[]
---@param keep fun(id: string): boolean
---@return string[]
local function inListOrder(chores, keep)
    local out = {}
    for _, chore in ipairs(chores) do
        if keep(chore.id) then out[#out + 1] = chore.id end
    end
    return out
end

---@param state ChoreState
---@param id string
---@return boolean
function M.isSelected(state, id)
    for _, selected in ipairs(state.selected) do
        if selected == id then return true end
    end
    return false
end

-- `state` with `id` selected. An id that isn't in `chores` changes nothing.
---@param state ChoreState
---@param chores Chore[]
---@param id string
---@return ChoreState
function M.select(state, chores, id)
    if not M.find(chores, id) or M.isSelected(state, id) then return state end
    local selected = inListOrder(chores, function(c)
        return c == id or M.isSelected(state, c)
    end)
    return { selected = selected, done = copyDone(state.done) }
end

-- `state` without `id` selected. Its completion is kept, so re-selecting it within the same
-- period shows it done again.
---@param state ChoreState
---@param id string
---@return ChoreState
function M.deselect(state, id)
    if not M.isSelected(state, id) then return state end
    local selected = {}
    for _, other in ipairs(state.selected) do
        if other ~= id then selected[#selected + 1] = other end
    end
    return { selected = selected, done = copyDone(state.done) }
end

-- `state` with `id` marked done at `now` (epoch minutes).
---@param state ChoreState
---@param id string
---@param now integer
---@return ChoreState
function M.mark(state, id, now)
    local out = copy(state)
    out.done[id] = now
    return out
end

-- `state` with `id` no longer marked done.
---@param state ChoreState
---@param id string
---@return ChoreState
function M.unmark(state, id)
    local out = copy(state)
    out.done[id] = nil
    return out
end

-- Whether `chore` is done at `now`: marked at or after the start of its current period.
---@param state ChoreState
---@param chore Chore
---@param now integer
---@return boolean
function M.isDone(state, chore, now)
    local minute = state.done[chore.id]
    return minute ~= nil and minute >= period.periodStart(chore.period, now)
end

-- The table to store in PersistentDB. It holds only strings, integers and tables, all types
-- PersistentDB stores (it drops table fields of other types). A minute that isn't a whole
-- number is left out rather than stored as a float.
---@param state ChoreState
---@return table
function M.serialise(state)
    local done = {}
    for id, minute in pairs(state.done) do
        done[id] = math.tointeger(minute)
    end
    return { version = M.VERSION, selected = copySelected(state.selected), done = done }
end

-- A state from a stored value. Anything malformed (not a table, a missing or unknown
-- version, entries of the wrong type, ids not in `chores`) is left out, so this never
-- errors: a damaged store costs the bad entries, not the plugin. An unknown version's shape
-- can't be trusted, so it gives an empty state.
---@param value any
---@param chores Chore[]
---@return ChoreState
function M.deserialise(value, chores)
    local state = M.new()
    if type(value) ~= "table" or value.version ~= M.VERSION then return state end

    if type(value.selected) == "table" then
        local stored = {}
        for _, id in pairs(value.selected) do
            if type(id) == "string" then stored[id] = true end
        end
        state.selected = inListOrder(chores, function(id)
            return stored[id] == true
        end)
    end

    if type(value.done) == "table" then
        for id, minute in pairs(value.done) do
            -- A whole-number float is accepted too, in case the store hands integers back as
            -- floats.
            local whole = type(minute) == "number" and math.tointeger(minute) or nil
            if whole and M.find(chores, id) then state.done[id] = whole end
        end
    end
    return state
end

return M
