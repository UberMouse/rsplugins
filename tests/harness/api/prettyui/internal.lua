-- Shared internals of the PrettyUI fake (see init.lua): the layout and sizing constants, the
-- option tables and the small helpers that more than one file needs, so each of objects,
-- window, popup, the driver and init can alias what it uses from the one `internal` table.
-- The window, objects and popup files add their own shared functions to it as they load.
-- Kept apart so no library file needs another's helpers just to reach a constant.

local strict = require("tests.harness.strict")
local ui = require("tests.harness.api.ui")

local internal = {}

-- Window frame: border, title bar height, the close X (20 px, 8 from the right edge, 7 down)
-- and the title-bar drag layer, which stops 34 px short of the right edge (the X's slot).
local BORDER, TITLE_HEIGHT = 8, 32
local CLOSE_SIZE, CLOSE_RIGHT, CLOSE_Y = 20, 8, 7
local DRAG_LAYER_GAP = CLOSE_SIZE + 14
local WINDOW_DEFAULTS =
    { x = 80, y = 80, width = 480, height = 340, minWidth = 220, minHeight = 140 }
-- Panel frame, and its default and smallest size.
local PANEL_BORDER, PANEL_MIN = 4, 9
local PANEL_DEFAULTS = { width = 300, height = 160 }
-- Content flow: left/right padding, first row's y, the gap under a row.
local PADDING, START_Y, ROW_GAP = 14, 12, 8
-- Text rows: body height and gap, title height, gap and the margin above a title that isn't
-- first, and the body line height for multi-line text.
local TEXT_HEIGHT, TEXT_GAP, LINE_HEIGHT = 24, 2, 18
local TITLE_HEIGHT_ROW, TITLE_GAP, TITLE_MARGIN = 28, 8, 16
local CHECKBOX_ROW = 22
local DIVIDER_HEIGHT = 60
local SPRITE_BUTTON_SIZE = 24
-- Pixels one wheel notch scrolls (the scroll controller's default scrollStep).
local SCROLL_STEP = 32

-- The names SpriteButton accepts (case-insensitive), from 1.2.0's sprite table.
local SPRITE_NAMES = {}
for name in
    ([[MENU FILTER INFO SETTINGS PAUSE STOP PLAY UNDO REFRESH BACK PIN ERASER CROSS AUDIO PENCIL
    EYE HIDE STAR LIST_LAYOUT GRID_LAYOUT CAPE SHIELD BODY AMULET LEGS BOOT OUTFIT HAND KEEPSAKE
    PYRAMID SPECIAL PLUS GRAPH IMPORT EXPORT LADDER_UP LADDER_DOWN ARROW_UP ARROW_RIGHT
    ARROW_LEFT ARROW_DOWN SEARCH CHAT DIAMOND SWAP BROADCAST LOCK TRASH]]):gmatch("%S+")
do
    SPRITE_NAMES[name] = true
end

---@param list string[]
---@return table<string, boolean>
local function set(list)
    local out = {}
    for _, k in ipairs(list) do
        out[k] = true
    end
    return out
end

local OPTIONS = {
    Window = set({
        "title",
        "x",
        "y",
        "width",
        "height",
        "resizable",
        "minWidth",
        "minHeight",
        "maxWidth",
        "maxHeight",
        "onClose",
        "tooltip",
    }),
    Panel = set({ "x", "y", "width", "height", "backgroundAlpha", "scrollable", "tooltip" }),
    SpriteButton = set({ "x", "y", "xAnchor", "yAnchor", "size", "width", "height", "tooltip" }),
    Text = set({ "text", "tooltip", "y" }),
    -- The fields of a Tooltip.attach table value; a string is the text alone.
    TooltipValue = set({ "text", "maxWidth" }),
    CheckboxButton = set({ "onChange", "selectedValues", "y", "colour", "tooltip" }),
    -- The fields a CheckboxButton choice table may have.
    Choice = set({ "text", "label", "value", "selected", "disabled", "tooltip" }),
    Divider = set({ "tooltip" }),
    AchievementPopup = set({
        "parent",
        "title",
        "text",
        "width",
        "height",
        "x",
        "y",
        "xAnchor",
        "yAnchor",
        "sound",
        "soundID",
        "onComplete",
        "titleColour",
        "textColour",
        "shadowed",
        "item",
        "quantity",
        "quantityMode",
        "itemInset",
        "outlineWidth",
        "shadowRGBA",
    }),
}

---@param v number
---@param lo number
---@param hi number?
---@return number
local function clamp(v, lo, hi)
    if hi == nil then return math.max(lo, v) end
    return math.max(lo, math.min(hi, v))
end

-- The options table, after checking every key is one the fake models.
---@param what string e.g. "Window"
---@param options any
---@return table
local function checkOptions(what, options)
    if options == nil then return {} end
    if type(options) ~= "table" then
        strict.fault("prettyui " .. what .. ": options must be a table")
    end
    for _, key in ipairs(strict.sortedKeys(options)) do
        if not OPTIONS[what][key] then
            strict.fault(
                "unmocked API: prettyui "
                    .. what
                    .. " option '"
                    .. tostring(key)
                    .. "' (not in the harness's PrettyUI subset)"
            )
        end
    end
    return options
end

-- The fake component behind a parent the plugin passed in.
---@param what string
---@param parent any
---@return table state
local function parentState(what, parent)
    local s = ui.stateOf(parent)
    -- strict.fault raises; the assert only narrows `s` for LuaLS.
    if not s then strict.fault("prettyui " .. what .. ": parent must be a ui component") end
    assert(s, "unreachable")
    if s.destroyed then strict.fault("prettyui " .. what .. ": parent was destroyed") end
    return s
end

-- Every method but Destroy, and every field but the ones 1.2.0 clears (see liveField), faults
-- once the object is destroyed. The real library ignores some calls on a destroyed object
-- (Show) and fails on others; a plugin shouldn't rely on it.
---@param s table
local function live(s)
    strict.live(s, "prettyui " .. s.kind)
end

-- Where the owner's next row goes, and move the flow past it. Rows stack top to bottom at
-- PADDING from the content's left; a title that isn't first gets TITLE_MARGIN above it.
---@param flow table
---@param height number
---@param gap number
---@param marginTop number
---@return number y
local function flowRow(flow, height, gap, marginTop)
    local y = flow.nextY + (flow.hasItems and marginTop or 0)
    flow.nextY = y + height + gap
    flow.hasItems = true
    return y
end

-- Grow the owner's content height to hold a row whose bottom is at `bottom`, plus the bottom
-- padding, as 1.2.0 does for every placed row, in the flow or not.
---@param flow table
---@param bottom number
local function grow(flow, bottom)
    flow.contentHeight = math.max(flow.contentHeight, bottom + PADDING)
    if flow.onGrow then flow.onGrow() end
end

---@param s table a Window or Panel state
local function remember(s)
    local x, y = ui.pos(s.rootState)
    s.remembered = { x = x, y = y }
end

-- The position (x, y) clamped so the root component stays inside its parent.
---@param root table component state
---@param x number
---@param y number
---@return number x
---@return number y
local function clampedPos(root, x, y)
    return clamp(x, 0, ui.width(root.parent) - ui.width(root)),
        clamp(y, 0, ui.height(root.parent) - ui.height(root))
end

-- Keep a Panel inside its parent, as PrettyUI's drag bounds do on create and SetSize.
---@param s table
local function clampIntoParent(s)
    local root = s.rootState
    local x, y = ui.pos(root)
    local nx, ny = clampedPos(root, x, y)
    if nx ~= x or ny ~= y then s.root:SetPos(nx, ny) end
    remember(s)
end

-- Whether the object was destroyed itself, or its root went with a destroyed parent.
---@param r table a record
---@return boolean
local function gone(r)
    return r.s.destroyed or (r.s.rootState ~= nil and r.s.rootState.destroyed)
end

-- Record the object as { kind, obj, s } so the driver can find it.
---@param lib table
---@param kind string
---@param obj any
---@param s table
local function track(lib, kind, obj, s)
    local record = { kind = kind, obj = obj, s = s }
    lib.records[#lib.records + 1] = record
    lib.byObj[obj] = record
end

internal.BORDER = BORDER
internal.TITLE_HEIGHT = TITLE_HEIGHT
internal.CLOSE_SIZE = CLOSE_SIZE
internal.CLOSE_RIGHT = CLOSE_RIGHT
internal.CLOSE_Y = CLOSE_Y
internal.DRAG_LAYER_GAP = DRAG_LAYER_GAP
internal.WINDOW_DEFAULTS = WINDOW_DEFAULTS
internal.PANEL_BORDER = PANEL_BORDER
internal.PANEL_MIN = PANEL_MIN
internal.PANEL_DEFAULTS = PANEL_DEFAULTS
internal.PADDING = PADDING
internal.START_Y = START_Y
internal.ROW_GAP = ROW_GAP
internal.TEXT_HEIGHT = TEXT_HEIGHT
internal.TEXT_GAP = TEXT_GAP
internal.LINE_HEIGHT = LINE_HEIGHT
internal.TITLE_HEIGHT_ROW = TITLE_HEIGHT_ROW
internal.TITLE_GAP = TITLE_GAP
internal.TITLE_MARGIN = TITLE_MARGIN
internal.CHECKBOX_ROW = CHECKBOX_ROW
internal.DIVIDER_HEIGHT = DIVIDER_HEIGHT
internal.SPRITE_BUTTON_SIZE = SPRITE_BUTTON_SIZE
internal.SCROLL_STEP = SCROLL_STEP
internal.SPRITE_NAMES = SPRITE_NAMES
internal.clamp = clamp
internal.checkOptions = checkOptions
internal.parentState = parentState
internal.live = live
internal.flowRow = flowRow
internal.grow = grow
internal.remember = remember
internal.clampedPos = clampedPos
internal.clampIntoParent = clampIntoParent
internal.gone = gone
internal.track = track

-- Load-time guard: reading a helper before the file that defines it was required fails loudly,
-- instead of leaving a nil alias that only faults when a test first calls it.
setmetatable(internal, {
    __index = function(_, k)
        error(
            "prettyui internal."
                .. tostring(k)
                .. " read before the file that defines it was required",
            2
        )
    end,
})

return internal
