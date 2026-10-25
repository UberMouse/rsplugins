-- PersistentDB for the tracker: one entry per character for picks and ticks, keyed by the
-- character's display name, and one global entry for the window's layout. Each write
-- happens only when the caller has a change to save.

local chores = require("data/chores")
local layout = require("core/layout")
local state = require("core/state")

local M = {}

local LAYOUT_KEY = "layout"

-- The entry for a character's state. The name is only ever used as this key, never logged.
---@param name string
---@return string
local function stateKey(name)
    return "state:" .. name
end

---@param name string
---@return ChoreState
function M.loadState(name)
    return state.deserialise(PersistentDB:Get(stateKey(name)), chores)
end

---@param name string
---@param s ChoreState
function M.saveState(name, s)
    PersistentDB:Set(stateKey(name), state.serialise(s))
end

-- The saved layout, or the default on first run.
---@return ChoreLayout
function M.loadLayout()
    return layout.fromStored(PersistentDB:Get(LAYOUT_KEY))
end

---@param l ChoreLayout
function M.saveLayout(l)
    PersistentDB:Set(LAYOUT_KEY, layout.serialise(l))
end

return M
