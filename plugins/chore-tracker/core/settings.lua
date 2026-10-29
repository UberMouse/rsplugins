-- The tracker's settings that apply to every character, as plain data: the defaults and
-- reading a stored value back. Pure.

local M = {}

-- The persisted shape's version. fromStored ignores any other.
M.VERSION = 1

---@class ChoreSettings
---@field popups boolean show a popup for a chore ticked and a period cleared
---@field sound boolean play a jingle with each popup

---@return ChoreSettings
function M.default()
    return { popups = true, sound = true }
end

-- Settings from a stored value: the defaults when it is missing or from another version, and
-- the default for any field that isn't a boolean.
---@param value any
---@return ChoreSettings
function M.fromStored(value)
    local out = M.default()
    if type(value) ~= "table" or value.version ~= M.VERSION then return out end
    if type(value.popups) == "boolean" then out.popups = value.popups end
    if type(value.sound) == "boolean" then out.sound = value.sound end
    return out
end

-- The table to store in PersistentDB: two booleans and the version.
---@param settings ChoreSettings
---@return table
function M.serialise(settings)
    return { version = M.VERSION, popups = settings.popups, sound = settings.sound }
end

return M
