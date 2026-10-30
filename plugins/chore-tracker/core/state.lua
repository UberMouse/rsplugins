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

-- The persisted shape's version. Version 1 had no shop progress; fromStored reads both and
-- ignores any other.
local VERSION = 2

---@class Chore
---@field id string dailyscape's key
---@field name string
---@field period ChorePeriod
---@field shop boolean
---@field url string
---@field desc string plain text; `<br>` is its only markup
---@field links string[]

---@class ChoreState
---@field selected string[] picked chore ids, in the player's own order (new picks last)
---@field done table<string, integer> chore id -> epoch minute it was marked done
---chore id -> shop inventory name -> epoch minute of the last purchase there
---@field shops table<string, table<string, integer>>

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

-- A copy of a key -> epoch minute map (`done`, or one chore's shops), each minute passed
-- through `convert` if given; a nil from it leaves that key out.
---@param minutes table<string, integer>
---@param convert (fun(minute: integer): integer?)?
---@return table<string, integer>
local function copyMinutes(minutes, convert)
    local out = {}
    for key, minute in pairs(minutes) do
        local kept = minute ---@type integer?
        if convert then kept = convert(minute) end
        out[key] = kept
    end
    return out
end

---@param shops table<string, table<string, integer>>
---@param convert (fun(minute: integer): integer?)?
---@return table<string, table<string, integer>>
local function copyShops(shops, convert)
    local out = {}
    for id, minutes in pairs(shops) do
        out[id] = copyMinutes(minutes, convert)
    end
    return out
end

-- A copy of `state`, so callers can change it without touching the original.
---@param state ChoreState
---@return ChoreState
local function copy(state)
    return {
        selected = copySelected(state.selected),
        done = copyMinutes(state.done),
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

-- The chore with this id; a miss fails naming `source` (the data file that holds the id) and
-- the id, since the data files name only chores in data/chores.lua.
---@param chores Chore[]
---@param id string
---@param source string
---@return Chore
function M.resolve(chores, id, source)
    local found = M.find(chores, id)
    assert(found, source .. " names a chore that data/chores.lua lacks: " .. id)
    return found
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

-- `state` with `id` selected, last in `selected` so it shows last in its period. An id that
-- isn't in `chores` changes nothing.
---@param state ChoreState
---@param chores Chore[]
---@param id string
---@return ChoreState
function M.select(state, chores, id)
    if not M.find(chores, id) or M.isSelected(state, id) then return state end
    local out = copy(state)
    out.selected[#out.selected + 1] = id
    return out
end

-- The ids selected in period `which`, in the player's order, and where in `selected` each sits.
-- Ids no chore in the list has are skipped. Shared by the view and `move` so the rows drawn
-- and the slots reordered always agree.
---@param state ChoreState
---@param chores Chore[]
---@param which ChorePeriod
---@return string[] ids
---@return integer[] slots
function M.selectedIn(state, chores, which)
    local wanted = {}
    for _, chore in ipairs(chores) do
        if chore.period == which then wanted[chore.id] = true end
    end
    local ids, slots = {}, {}
    for i, id in ipairs(state.selected) do
        if wanted[id] then
            ids[#ids + 1] = id
            slots[#slots + 1] = i
        end
    end
    return ids, slots
end

-- `state` with `id` moved to position `index` among the selected chores of its own period
-- (1 = first), clamped to that period's range. Other chores keep their relative order, and
-- a chore never changes period, so the other periods' rows stay put. Gives back `state`
-- itself when `id` isn't selected or already sits there.
---@param state ChoreState
---@param chores Chore[]
---@param id string
---@param index integer
---@return ChoreState
function M.move(state, chores, id, index)
    local chore = M.find(chores, id)
    if not chore or not M.isSelected(state, id) then return state end
    local ids, slots = M.selectedIn(state, chores, chore.period)
    local from = 0
    for k, other in ipairs(ids) do
        if other == id then from = k end
    end
    local to = math.max(1, math.min(index, #ids))
    if to == from then return state end
    table.remove(ids, from)
    table.insert(ids, to, id)
    local out = copy(state)
    for k, slot in ipairs(slots) do
        out.selected[slot] = ids[k]
    end
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

-- Whether `minute` (nil: never) falls in `chore`'s current period at `now`.
---@param minute integer?
---@param chore Chore
---@param now integer
---@return boolean
local function inPeriod(minute, chore, now)
    return minute ~= nil and minute >= period.periodStart(chore.period, now)
end

-- Whether `chore` is done at `now`: marked at or after the start of its current period.
---@param state ChoreState
---@param chore Chore
---@param now integer
---@return boolean
function M.isDone(state, chore, now)
    return inPeriod(state.done[chore.id], chore, now)
end

-- `state` with `chore` marked done at `now` unless it already is this period, for a chore
-- the plugin saw done: an earlier tick, by hand or detected, keeps its minute. A chore
-- already done gives back `state` itself, so the caller can tell nothing changed.
---@param state ChoreState
---@param chore Chore
---@param now integer
---@return ChoreState
function M.autoMark(state, chore, now)
    if M.isDone(state, chore, now) then return state end
    return M.mark(state, chore.id, now)
end

-- `state` after a purchase at shop inventory `inv` for `chore` at `now`: the inventory
-- recorded as bought at `now`, and the chore auto-marked. When both already hold this
-- period it gives back `state` itself: only period membership is ever read, so a later
-- minute would change nothing shown, and the caller then writes nothing.
---@param state ChoreState
---@param chore Chore
---@param inv string the shop inventory's config name
---@param now integer
---@return ChoreState
function M.recordPurchase(state, chore, inv, now)
    if M.isDone(state, chore, now) and M.shopBought(state, chore, inv, now) then return state end
    local out = copy(M.autoMark(state, chore, now))
    out.shops[chore.id] = out.shops[chore.id] or {}
    out.shops[chore.id][inv] = now
    return out
end

-- Whether shop inventory `inv` was bought from for `chore` in its current period at `now`.
---@param state ChoreState
---@param chore Chore
---@param inv string
---@param now integer
---@return boolean
function M.shopBought(state, chore, inv, now)
    local minutes = state.shops[chore.id]
    return inPeriod(minutes and minutes[inv], chore, now)
end

-- Whether any of `invs` (one shop's inventories, as data/shops.lua lists them) was bought
-- from for `chore` in its current period at `now`.
---@param state ChoreState
---@param chore Chore
---@param invs string[]
---@param now integer
---@return boolean
function M.shopBoughtAny(state, chore, invs, now)
    for _, inv in ipairs(invs) do
        if M.shopBought(state, chore, inv, now) then return true end
    end
    return false
end

-- The table to store in PersistentDB. It holds only strings, integers and tables, all types
-- PersistentDB stores (it drops table fields of other types). A minute that isn't a whole
-- number is left out rather than stored as a float.
---@param state ChoreState
---@return table
function M.serialise(state)
    return {
        version = VERSION,
        selected = copySelected(state.selected),
        done = copyMinutes(state.done, math.tointeger),
        shops = copyShops(state.shops, math.tointeger),
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
function M.fromStored(value, chores)
    local state = M.new()
    if type(value) ~= "table" or (value.version ~= 1 and value.version ~= VERSION) then
        return state
    end

    if type(value.selected) == "table" then
        -- ipairs, not pairs: the stored order is the player's order, and pairs would visit
        -- the ids in no fixed order. A list with a hole loads only the ids before the gap.
        local seen = {}
        for _, id in ipairs(value.selected) do
            if type(id) == "string" and not seen[id] and M.find(chores, id) then
                seen[id] = true
                state.selected[#state.selected + 1] = id
            end
        end
    end

    if type(value.done) == "table" then
        for id, minute in pairs(value.done) do
            local whole = asMinute(minute)
            if whole and M.find(chores, id) then state.done[id] = whole end
        end
    end

    if value.version == VERSION and type(value.shops) == "table" then
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
