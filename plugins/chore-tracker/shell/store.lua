-- PersistentDB for the tracker: one entry per character for picks and ticks, keyed by the
-- character's display name, and one global entry each for the window's layout and the
-- celebration settings. Each write happens only when the caller has a change to save.

local layout = require("core/layout")
local settings = require("core/settings")
local state = require("core/state")

local M = {}

local LAYOUT_KEY = "layout"
local SETTINGS_KEY = "celebrations"

-- The entry for a character's state. The name is only ever used as this key, never logged.
---@param name string
---@return string
local function stateKey(name)
    return "state:" .. name
end

---@param name string
---@param chores Chore[] the list to keep stored ids from
---@return ChoreState
function M.loadState(name, chores)
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

-- The saved celebration settings (all characters), or the defaults on first run.
---@return ChoreSettings
function M.loadSettings()
    return settings.fromStored(PersistentDB:Get(SETTINGS_KEY))
end

---@param s ChoreSettings
function M.saveSettings(s)
    PersistentDB:Set(SETTINGS_KEY, settings.serialise(s))
end

return M
