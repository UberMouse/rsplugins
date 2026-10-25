-- The tracker's state: which chores the player picked, and when each was last marked done.
-- The functions are pure: those that change the state return a new one and leave the one
-- they were given untouched.
-- The chore list is passed in (not required here), so tests can use small hand-made lists.
--
-- A completion is stored as the epoch minute it was marked. It counts as done while that
-- minute is inside the chore's current period, so a reset needs no timer or explicit step:
-- once the period rolls over, the old minute is simply before its start. Sub-daily chores
-- ("Every 6H", "2x a day") keep dailyscape's daily period.
--
-- Shop runs also keep, per shop, the epoch minute of the last purchase there, so the window
-- can show how many of a chore's shops were bought from this period, by the same rule.

local period = require("core/period")

local M = {}

-- The persisted shape's version. Version 1 had no shop progress; deserialise reads both and
-- ignores any other.
M.VERSION = 2

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
---@field shops table<string, table<string, integer>> chore id -> shop inv name -> epoch minute of the last purchase there

-- An empty state: nothing selected, nothing done, nothing bought.
---@return ChoreState
function M.new()
    return { selected = {}, done = {}, shops = {} }
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

---@param shops table<string, table<string, integer>>
---@return table<string, table<string, integer>>
local function copyShops(shops)
    local out = {}
    for id, minutes in pairs(shops) do
        out[id] = copyDone(minutes)
    end
    return out
end

-- A copy of `state`, so callers can change it without touching the original.
---@param state ChoreState
---@return ChoreState
local function copy(state)
    return {
        selected = copySelected(state.selected),
        done = copyDone(state.done),
        shops = copyShops(state.shops),
    }
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
    local out = copy(state)
    out.selected = inListOrder(chores, function(c)
        return c == id or M.isSelected(state, c)
    end)
    return out
end

-- `state` without `id` selected. Its completion and shop progress are kept, so re-selecting
-- it within the same period shows them again.
---@param state ChoreState
---@param id string
---@return ChoreState
function M.deselect(state, id)
    if not M.isSelected(state, id) then return state end
    local out = copy(state)
    out.selected = {}
    for _, other in ipairs(state.selected) do
        if other ~= id then out.selected[#out.selected + 1] = other end
    end
    return out
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

-- `state` with `id` no longer marked done. Its shop progress is kept: unticking by hand says
-- nothing about what was bought.
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

-- `state` after a purchase at shop `inv` for `chore` at `now`: the shop recorded as bought
-- at `now`, and the chore marked done at `now` unless it already is this period (an earlier
-- tick, by hand or by another of its shops, keeps its minute).
---@param state ChoreState
---@param chore Chore
---@param inv string the shop inventory's config name
---@param now integer
---@return ChoreState
function M.recordPurchase(state, chore, inv, now)
    local out = copy(state)
    out.shops[chore.id] = out.shops[chore.id] or {}
    out.shops[chore.id][inv] = now
    if not M.isDone(state, chore, now) then out.done[chore.id] = now end
    return out
end

-- Whether shop `inv` was bought from for `chore` in its current period at `now`.
---@param state ChoreState
---@param chore Chore
---@param inv string
---@param now integer
---@return boolean
function M.shopBought(state, chore, inv, now)
    local minute = state.shops[chore.id] and state.shops[chore.id][inv]
    return minute ~= nil and minute >= period.periodStart(chore.period, now)
end

-- The table to store in PersistentDB. It holds only strings, integers and tables, all types
-- PersistentDB stores (it drops table fields of other types). A minute that isn't a whole
-- number is left out rather than stored as a float.
---@param minutes table<string, integer>
---@return table<string, integer>
local function wholeMinutes(minutes)
    local out = {}
    for key, minute in pairs(minutes) do
        out[key] = math.tointeger(minute)
    end
    return out
end

---@param state ChoreState
---@return table
function M.serialise(state)
    local shops = {}
    for id, minutes in pairs(state.shops) do
        shops[id] = wholeMinutes(minutes)
    end
    return {
        version = M.VERSION,
        selected = copySelected(state.selected),
        done = wholeMinutes(state.done),
        shops = shops,
    }
end

-- A whole-number minute, or nil. A whole-number float is accepted too, in case the store
-- hands integers back as floats.
---@param minute any
---@return integer?
local function asMinute(minute)
    return type(minute) == "number" and math.tointeger(minute) or nil
end

-- A state from a stored value. Anything malformed (not a table, a missing or unknown
-- version, entries of the wrong type, ids not in `chores`) is left out, so this never
-- errors: a damaged store costs the bad entries, not the plugin. An unknown version's shape
-- can't be trusted, so it gives an empty state. Version 1 has no shop progress.
---@param value any
---@param chores Chore[]
---@return ChoreState
function M.deserialise(value, chores)
    local state = M.new()
    if type(value) ~= "table" or (value.version ~= 1 and value.version ~= M.VERSION) then
        return state
    end

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
            local whole = asMinute(minute)
            if whole and M.find(chores, id) then state.done[id] = whole end
        end
    end

    if value.version == M.VERSION and type(value.shops) == "table" then
        for id, minutes in pairs(value.shops) do
            if type(minutes) == "table" and M.find(chores, id) then
                local kept = {}
                for inv, minute in pairs(minutes) do
                    local whole = asMinute(minute)
                    if type(inv) == "string" and whole then kept[inv] = whole end
                end
                if next(kept) then state.shops[id] = kept end
            end
        end
    end
    return state
end

return M
