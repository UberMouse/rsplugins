-- The tracker's state: which chores the player picked, and when each was last marked done.
-- The functions are pure: those that change the state return a new one and leave the one
-- they were given untouched.
-- The chore list is passed in (not required here), so tests can use small hand-made lists.
--
-- A completion is stored as the epoch minute it was marked. It counts as done while that
-- minute is inside the chore's current period, so a reset needs no timer or explicit step:
-- once the period rolls over, the old minute is simply before its start. Sub-daily chores
-- ("every 6 hours", "twice a day") keep a daily period.
--
-- A chore done at parts (shops, herb patches, machines...; core/parts.lua) also keeps, per
-- part key, the epoch minute it was last seen done, so the window can show how many of its
-- parts were done this period, by the same rule. A chore with several parts ticks once a set
-- number of them were done this period: its default (all of them for a shop run), or the
-- count the player set in settings (they may do only some). A chore's parts are passed in
-- like the chore list.

local period = require("core/period")

local M = {}

-- The persisted shape's version. Version 1 had no shop progress, version 2 no shops-needed
-- counts, and versions 2 and 3 held only shops' progress, as `shops`, keyed by inventory as
-- `parts` is; fromStored reads all four and ignores any other.
local VERSION = 4

---@alias ChoreCategory "activities"|"combat"|"skilling"|"upkeep"|"supplies"|"shops"

---@class Chore
---@field id string fixed for good: saved state and the other data files are keyed by it
---@field name string
---@field period ChorePeriod
---@field category ChoreCategory? its settings subheading; none sits straight under the period
---@field url string
---@field desc string plain text; `<br>` is its only markup
---@field links string[]

---@class ChoreState
---@field selected string[] picked chore ids, in the player's own order (new picks last)
---@field done table<string, integer> chore id -> epoch minute it was marked done
---chore id -> part key -> epoch minute it was last seen done
---@field parts table<string, table<string, integer>>
---chore id -> how many of its parts tick it, held only when the player set one other than its
---default; read it through partsNeeded, which clamps it to the current list
---@field needed table<string, integer>

-- An empty state: nothing selected, nothing done, no part done.
---@return ChoreState
function M.new()
    return { selected = {}, done = {}, parts = {}, needed = {} }
end

---@param selected string[]
---@return string[]
local function copySelected(selected)
    return table.move(selected, 1, #selected, 1, {})
end

-- A copy of a key -> integer map (`done` minutes, one chore's part minutes, or the needed
-- counts), each value passed through `convert` if given; a nil from it leaves
-- that key out.
---@param map table<string, integer>
---@param convert (fun(value: integer): integer?)?
---@return table<string, integer>
local function copyIntegers(map, convert)
    local out = {}
    for key, value in pairs(map) do
        local kept = value ---@type integer?
        if convert then kept = convert(value) end
        out[key] = kept
    end
    return out
end

---@param parts table<string, table<string, integer>>
---@param convert (fun(value: integer): integer?)?
---@return table<string, table<string, integer>>
local function copyParts(parts, convert)
    local out = {}
    for id, minutes in pairs(parts) do
        out[id] = copyIntegers(minutes, convert)
    end
    return out
end

-- A copy of `state`, so callers can change it without touching the original.
---@param state ChoreState
---@return ChoreState
local function copy(state)
    return {
        selected = copySelected(state.selected),
        done = copyIntegers(state.done),
        parts = copyParts(state.parts),
        needed = copyIntegers(state.needed),
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

-- `state` without `id` selected. Its completion and part progress are kept, so re-selecting
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

-- `state` with `id` no longer marked done. Its part progress is kept: unticking by hand says
-- nothing about which parts were done.
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

-- Whether the part key `key` was done for `chore` in its current period at `now`.
---@param state ChoreState
---@param chore Chore
---@param key string
---@param now integer
---@return boolean
function M.keyDone(state, chore, key, now)
    local minutes = state.parts[chore.id]
    return inPeriod(minutes and minutes[key], chore, now)
end

-- Whether `part` was done for `chore` in its current period at `now`, by any of its keys.
---@param state ChoreState
---@param chore Chore
---@param part ChorePart
---@param now integer
---@return boolean
function M.partDone(state, chore, part, now)
    for _, key in ipairs(part.keys) do
        if M.keyDone(state, chore, key, now) then return true end
    end
    return false
end

-- How many of `parts` were done for `chore` in its current period at `now`. A part counts
-- once, whichever of its keys was done.
---@param state ChoreState
---@param chore Chore
---@param parts ChoreParts
---@param now integer
---@return integer
function M.partsDone(state, chore, parts, now)
    local done = 0
    for _, part in ipairs(parts.list) do
        if M.partDone(state, chore, part, now) then done = done + 1 end
    end
    return done
end

-- How many of `parts` must be done in a period to tick `chore`: the player's count, else the
-- parts' default, else all of them; at least 1 and at most #parts.list (the list may have
-- shrunk since it was set). 0 when the list is empty.
---@param state ChoreState
---@param chore Chore
---@param parts ChoreParts
---@return integer
function M.partsNeeded(state, chore, parts)
    local total = #parts.list
    local set = state.needed[chore.id] or parts.default
    if set == nil then return total end
    return math.min(math.max(set, 1), total)
end

-- `state` with `chore` needing `count` of `parts`, clamped to 1..#parts.list. Gives back
-- `state` itself when that is already its count, so the caller can tell nothing changed.
-- It never ticks or unticks: only a part the plugin sees done does that (recordPart).
---@param state ChoreState
---@param chore Chore
---@param parts ChoreParts
---@param count integer
---@return ChoreState
function M.setPartsNeeded(state, chore, parts, count)
    local clamped = math.max(1, math.min(count, #parts.list))
    if clamped == M.partsNeeded(state, chore, parts) then return state end
    local out = copy(state)
    -- The default isn't held, so a change to it (or, for all of them, a part added to the
    -- list) reaches the player who never set one.
    local default = math.min(parts.default or #parts.list, #parts.list)
    out.needed[chore.id] = clamped ~= default and clamped or nil
    return out
end

-- `state` after part key `key` (one of `parts`) was seen done for `chore` at `now`: the key
-- recorded as done, and the chore auto-marked if it isn't done and at least partsNeeded of its
-- parts were done this period. Recorded whether or not the chore is picked. A repeat keeps its
-- first minute (only period membership is read) but is still judged for the tick. Gives back
-- `state` itself when nothing changes, so the caller writes nothing.
---@param state ChoreState
---@param chore Chore
---@param parts ChoreParts
---@param key string a shop's inventory, a machine's output inventory or a var rule's part
---@param now integer
---@return ChoreState
function M.recordPart(state, chore, parts, key, now)
    local out = state
    if not M.keyDone(state, chore, key, now) then
        out = copy(state)
        out.parts[chore.id] = out.parts[chore.id] or {}
        out.parts[chore.id][key] = now
    end
    if M.partsDone(out, chore, parts, now) >= M.partsNeeded(out, chore, parts) then
        out = M.autoMark(out, chore, now)
    end
    return out
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
        done = copyIntegers(state.done, math.tointeger),
        parts = copyParts(state.parts, math.tointeger),
        needed = copyIntegers(state.needed),
    }
end

-- A whole number (a minute or a count), or nil. A whole-number float is accepted too, in case
-- the store hands integers back as floats.
---@param value any
---@return integer?
local function asWhole(value)
    return type(value) == "number" and math.tointeger(value) or nil
end

-- A state from a stored value. Anything malformed (not a table, a missing or unknown
-- version, entries of the wrong type, ids not in `chores`) is left out, so this never
-- errors: a damaged store costs the bad entries, not the plugin. An unknown version's shape
-- can't be trusted, so it gives an empty state. Version 1 has no shop progress, and versions
-- 1 and 2 no needed counts, so every chore gets its default. A count below 1 is left out (the
-- default); one above its chore's part count is clamped where it is read.
---@param value any
---@param chores Chore[]
---@return ChoreState
function M.fromStored(value, chores)
    local state = M.new()
    if
        type(value) ~= "table"
        or not (
            value.version == 1
            or value.version == 2
            or value.version == 3
            or value.version == VERSION
        )
    then
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
            local whole = asWhole(minute)
            if whole and M.find(chores, id) then state.done[id] = whole end
        end
    end

    -- Shop progress was stored as `shops`, keyed by inventory as parts are.
    local stored = value.shops
    if value.version == VERSION then stored = value.parts end
    if value.version ~= 1 and type(stored) == "table" then
        for id, minutes in pairs(stored) do
            if type(minutes) == "table" and M.find(chores, id) then
                local kept = {}
                for key, minute in pairs(minutes) do
                    local whole = asWhole(minute)
                    if type(key) == "string" and whole then kept[key] = whole end
                end
                if next(kept) then state.parts[id] = kept end
            end
        end
    end

    if (value.version == 3 or value.version == VERSION) and type(value.needed) == "table" then
        for id, count in pairs(value.needed) do
            local whole = asWhole(count)
            if whole and whole >= 1 and M.find(chores, id) then state.needed[id] = whole end
        end
    end
    return state
end

return M
