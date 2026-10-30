-- Where the window and its collapsed button are, as plain data: the defaults, reading a
-- stored layout back, and keeping one inside the plugin layer. Pure: the shell reads the
-- live components and the parent's size, and passes them in.

local M = {}

-- The persisted shape's version. fromStored ignores any other.
local VERSION = 1

---@class ChoreLayout
---@field x integer the window's position in the plugin layer
---@field y integer
---@field width integer
---@field height integer
---@field collapsed boolean
---@field buttonX integer the collapsed button's position in the plugin layer
---@field buttonY integer

-- PrettyUI's close X is 20 px square and sits 28 px left of the window's right edge and 7 px
-- down; the hamburger takes that slot, so an open window's button is there.
M.BUTTON_SIZE = 20
M.SLOT_X, M.SLOT_Y = -28, 7

local DEFAULT_X, DEFAULT_Y, DEFAULT_WIDTH, DEFAULT_HEIGHT = 600, 300, 320, 420

-- The smallest the window can be resized to.
M.MIN_WIDTH, M.MIN_HEIGHT = 240, 160

-- Where the window first opens: open, with its button in its slot.
---@return ChoreLayout
function M.default()
    return {
        x = DEFAULT_X,
        y = DEFAULT_Y,
        width = DEFAULT_WIDTH,
        height = DEFAULT_HEIGHT,
        collapsed = false,
        buttonX = DEFAULT_X + DEFAULT_WIDTH + M.SLOT_X,
        buttonY = DEFAULT_Y + M.SLOT_Y,
    }
end

local FIELDS = { "x", "y", "width", "height", "buttonX", "buttonY" }

-- A layout from a stored value, or the default when it is missing or malformed. Every
-- number must be whole (a whole float is accepted, in case the store hands integers back
-- as floats).
---@param value any
---@return ChoreLayout
function M.fromStored(value)
    if type(value) ~= "table" or value.version ~= VERSION then return M.default() end
    if type(value.collapsed) ~= "boolean" then return M.default() end
    local out = { collapsed = value.collapsed }
    for _, field in ipairs(FIELDS) do
        local n = value[field]
        n = type(n) == "number" and math.tointeger(n) or nil
        if n == nil then return M.default() end
        out[field] = n
    end
    return out
end

-- The table to store in PersistentDB: integers and a boolean, both types it keeps.
---@param layout ChoreLayout
---@return table
function M.serialise(layout)
    local out = { version = VERSION, collapsed = layout.collapsed }
    for _, field in ipairs(FIELDS) do
        out[field] = layout[field]
    end
    return out
end

---@param a ChoreLayout
---@param b ChoreLayout
---@return boolean
function M.same(a, b)
    if a.collapsed ~= b.collapsed then return false end
    for _, field in ipairs(FIELDS) do
        if a[field] ~= b[field] then return false end
    end
    return true
end

---@param v integer
---@param lo integer
---@param hi integer
---@return integer
local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

-- `pos` moved to keep a `size` span inside 0..`parentSize`; a span bigger than the parent
-- sits at 0.
---@param pos integer
---@param size integer
---@param parentSize integer
---@return integer
local function within(pos, size, parentSize)
    return clamp(pos, 0, math.max(0, parentSize - size))
end

-- `saved` moved and shrunk to fit a parent of `parentWidth` x `parentHeight`, e.g. one saved at a
-- bigger window size. The window stays at least MIN_WIDTH x MIN_HEIGHT; the BUTTON_SIZE button
-- is moved fully inside the parent (pinned at 0 if the parent is smaller).
---@param saved ChoreLayout
---@param parentWidth integer
---@param parentHeight integer
---@return ChoreLayout
function M.keepInside(saved, parentWidth, parentHeight)
    local width = clamp(saved.width, M.MIN_WIDTH, math.max(M.MIN_WIDTH, parentWidth))
    local height = clamp(saved.height, M.MIN_HEIGHT, math.max(M.MIN_HEIGHT, parentHeight))
    return {
        x = within(saved.x, width, parentWidth),
        y = within(saved.y, height, parentHeight),
        width = width,
        height = height,
        collapsed = saved.collapsed,
        buttonX = within(saved.buttonX, M.BUTTON_SIZE, parentWidth),
        buttonY = within(saved.buttonY, M.BUTTON_SIZE, parentHeight),
    }
end

-- Where a `width` x `height` window goes so its button's slot lands on (`buttonX`,
-- `buttonY`), kept inside a `parentWidth` x `parentHeight` parent: near an edge it shifts,
-- off the button's spot. A parent smaller than the window pins it at 0.
---@param buttonX integer
---@param buttonY integer
---@param width integer
---@param height integer
---@param parentWidth integer
---@param parentHeight integer
---@return integer x
---@return integer y
function M.windowForButton(buttonX, buttonY, width, height, parentWidth, parentHeight)
    return within(buttonX - (width + M.SLOT_X), width, parentWidth),
        within(buttonY - M.SLOT_Y, height, parentHeight)
end

return M
