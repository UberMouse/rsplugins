-- A fake of the part of PrettyUI 1.2.0 (https://prettyui.j3.gg, mod.io 6398181) the Chore
-- Tracker uses, served as the dependency global a manifest asks for, and the test driver
-- (h.ui) that clicks, drags and resizes it. It is the harness's own code: PrettyUI ships
-- without a licence, so none of its source is copied. The numbers below (sizes, offsets,
-- defaults) were read from the installed 1.2.0 source and checked against a beta-client
-- probe on 2026-10-25; docs/testing.md's fidelity ledger says which is which.
--
-- Modelled: Window (titled, resizable, close button, AddText/AddTitle/AddCheckboxButton/
-- AddDivider/AddSpriteButton, SetScrollPosition and the `_scroll.scrollY` it sets, the
-- `content` layer for a plugin's own components and the `viewport` it scrolls in,
-- SetContentHeight, the wheel handler, the title-bar drag layer `titleDrag`'s stacking, and the
-- overlays registered with the internal `_RegisterOverlay` and when they are synced),
-- standalone Panel (AddSpriteButton, Alt-drag), SpriteButton and Tooltip.attach. Any other library member,
-- method or option faults as unmocked; extend the fake, with a ledger row, when a plugin
-- needs more.

local runtime = require("tests.harness.runtime")
local strict = require("tests.harness.strict")
local ui = require("tests.harness.api.ui")

local M = {}

M.MOD_ID = 6398181
M.VERSION = "1.2.0"

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

-- Every method but Destroy faults once the object is destroyed. The real library ignores
-- some calls on a destroyed object (Show) and fails on others; a plugin shouldn't rely on it.
---@param s table
local function live(s)
    if s.destroyed then strict.fault("prettyui " .. s.kind .. " used after Destroy()") end
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

-- Keep a Panel inside its parent, as PrettyUI's drag bounds do on create and SetSize.
---@param s table
local function clampIntoParent(s)
    local root = s.rootState
    local x, y = ui.pos(root)
    local nx = clamp(x, 0, ui.width(root.parent) - ui.width(root))
    local ny = clamp(y, 0, ui.height(root.parent) - ui.height(root))
    if nx ~= x or ny ~= y then s.root:SetPos(nx, ny) end
    remember(s)
end

---------------------------------------------------------------------------
-- Library objects
---------------------------------------------------------------------------

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

---------------------------------------------------------------------------
-- Tooltips as 1.2.0 attaches them (src/tooltip.lua): shown on the target's mouse-over, hidden
-- only on that target's mouse-leave, so hiding the target leaves it up. A Window/Panel's
-- content tooltips are drawn on the host's parent (Close hides, Destroy destroys them); a
-- SpriteButton made on another component draws inside it.
---------------------------------------------------------------------------

-- A new, hidden tooltip, or nil for no tooltip.
---@param lib table
---@param target table the hovered component's state
---@param parent table the state of the component it is drawn in
---@param value any a string or { text, ... }; nil for none
---@param context table? the host's content tooltip context
---@return table?
local function attachTip(lib, target, parent, value, context)
    if value == nil then return nil end
    local text = type(value) == "table" and value.text or value
    local tip = { target = target, parent = parent, text = tostring(text or ""), shown = false }
    tip.context = context
    lib.tooltips[#lib.tooltips + 1] = tip
    if context then context.tips[#context.tips + 1] = tip end
    return tip
end

---@param tip table?
local function destroyTip(tip)
    if tip then tip.destroyed = true end
end

-- SetTooltip / SetOptionTooltip: a string on an existing tooltip only changes its text (a
-- shown one stays shown); anything else destroys the old one and attaches a new, hidden one.
---@param lib table
---@param old table?
---@param value any
---@param target table
---@param parent table
---@param context table?
---@return table?
local function replaceTip(lib, old, value, target, parent, context)
    if old and value ~= nil and type(value) ~= "table" then
        old.text = tostring(value)
        return old
    end
    destroyTip(old)
    return attachTip(lib, target, parent, value, context)
end

-- A host's content tooltip context: tooltips drawn on `parent` (the host's parent).
---@param parent table
---@return table
local function newContext(parent)
    return { parent = parent, tips = {} }
end

-- Destroy on an attachment from Tooltip.attach: gives the target's clickthrough back, as
-- 1.2.0 does, and leaves its window's context. Calling it again does nothing.
---@param tip table
local function destroyAttachment(tip)
    if tip.destroyed then return end
    destroyTip(tip)
    tip.shown = false
    local lib = tip.lib
    if lib.rawTips[tip.target] == tip then lib.rawTips[tip.target] = nil end
    if not tip.target.destroyed then tip.target.clickthrough = tip.priorClickthrough end
    if tip.context then
        for i, member in ipairs(tip.context.tips) do
            if member == tip then
                table.remove(tip.context.tips, i)
                break
            end
        end
    end
end

local TooltipAttachment = strict.class("prettyui.Tooltip attachment", {
    undeclared = true,
    methods = {
        Destroy = function(tip)
            destroyAttachment(tip)
        end,
    },
})

-- Tooltip.attach(target, parent, value) (src/tooltip.lua) for a plugin's own component: the
-- same tooltip record as every other, shown by the driver's hover on `target` and hidden on
-- its leave. Like 1.2.0 it makes `target` take the mouse (clickthrough false). When `parent`
-- is a Window's content, the tooltip joins that window's context: drawn on the window's
-- parent, hidden by Close, destroyed by Destroy.
---@param lib table
---@param target any
---@param parent any
---@param value any a string, or { text, maxWidth }; nil attaches nothing
---@param ... any
---@return table? # the attachment, or nil for a nil value
local function attachRawTooltip(lib, target, parent, value, ...)
    if select("#", ...) > 0 then
        strict.fault("unmocked API: prettyui Tooltip.attach with hover handlers")
    end
    local ts = ui.stateOf(target)
    if not ts then strict.fault("prettyui Tooltip.attach: target must be a ui component") end
    assert(ts, "unreachable")
    if ts.destroyed then strict.fault("prettyui Tooltip.attach: target was destroyed") end
    local ps = parentState("Tooltip.attach", parent)
    if value == nil then return nil end
    if type(value) == "table" then checkOptions("TooltipValue", value) end
    local old = lib.rawTips[ts]
    if old and not old.destroyed then
        strict.fault(
            "prettyui Tooltip.attach: the target already has a tooltip (whether 1.2.0 stacks "
                .. "or replaces them is unprobed): Destroy it first"
        )
    end
    local context = nil
    for _, r in ipairs(lib.records) do
        if r.kind == "Window" and r.s.contentState == ps and not gone(r) then context = r.s.tips end
    end
    local tip = attachTip(lib, ts, context and context.parent or ps, value, context)
    assert(tip, "a non-nil value always attaches")
    tip.lib = lib
    tip.priorClickthrough = ts.clickthrough
    ts.clickthrough = false
    lib.rawTips[ts] = tip
    return TooltipAttachment.new(tip)
end

local SpriteButton = strict.class("prettyui.SpriteButton instance", {
    undeclared = true,
    fields = {
        root = function(s)
            return s.root
        end,
    },
    methods = {
        -- A string changes the text; a table or nil replaces it (hidden), as 1.2.0 does.
        SetTooltip = function(s, value)
            live(s)
            s.tip = replaceTip(s.lib, s.tip, value, s.rootState, s.tipParent, s.context)
            return true
        end,
        Destroy = function(s)
            if s.destroyed then return end
            s.destroyed = true
            destroyTip(s.tip)
            s.root:Destroy()
            s.root = nil
        end,
    },
})

---@param lib table
---@param parent table parent state
---@param name any
---@param action any
---@param options table already checked
---@param context table? the host's tooltip context, for a button added to a host's content
---@return table
local function newSpriteButton(lib, parent, name, action, options, context)
    -- The real library raises these as plain Lua errors; a plugin may catch them.
    if type(name) ~= "string" then
        strict.fault("SpriteButton sprite name must be a string", true)
    end
    if not SPRITE_NAMES[name:upper()] then
        strict.fault("Unknown SpriteButton sprite: " .. name, true)
    end
    if action ~= nil and type(action) ~= "function" then
        strict.fault("prettyui SpriteButton: action must be a function")
    end
    local s = {
        kind = "SpriteButton",
        lib = lib,
        spriteName = name:upper(),
        action = action,
        context = context,
        tipParent = context and context.parent or parent,
    }
    s.root, s.rootState = ui.create("Sprite", parent)
    s.root:SetPos(options.x or 0, options.y or 0, options.xAnchor or 0, options.yAnchor or 0)
    s.root:SetSize(
        options.width or options.size or SPRITE_BUTTON_SIZE,
        options.height or options.size or SPRITE_BUTTON_SIZE
    )
    s.tip = attachTip(lib, s.rootState, s.tipParent, options.tooltip, context)
    local obj = SpriteButton.new(s)
    s.proxy = obj
    track(lib, "SpriteButton", obj, s)
    return obj
end

local Divider = strict.class("prettyui.Divider instance", {
    undeclared = true,
    fields = {
        root = function(s)
            return s.root
        end,
    },
    methods = {
        Destroy = function(s)
            if s.destroyed then return end
            s.destroyed = true
            destroyTip(s.tip)
            s.root:Destroy()
            s.root = nil
        end,
    },
})

local Checkbox = strict.class("prettyui.CheckboxButton instance", {
    undeclared = true,
    fields = {
        root = function(s)
            return s.root
        end,
    },
    methods = {
        -- The checked values, in choice order (a copy).
        GetSelectedValues = function(s)
            live(s)
            local values = {}
            for _, item in ipairs(s.items) do
                if item.selected then values[#values + 1] = item.value end
            end
            return values
        end,
        IsSelected = function(s, value)
            live(s)
            for _, item in ipairs(s.items) do
                if item.value == value then return item.selected end
            end
            return false
        end,
        -- false for an unknown value; onChange(group, values, value, selected) fires only on
        -- a change, and not when notify is false.
        SetSelected = function(s, value, selected, notify)
            live(s)
            for _, item in ipairs(s.items) do
                if item.value == value then
                    selected = selected == true
                    if item.selected == selected then return true end
                    item.selected = selected
                    if notify ~= false and s.onChange then
                        s.onChange(s.proxy, s.proxy:GetSelectedValues(), value, selected)
                    end
                    return true
                end
            end
            return false
        end,
        -- Replace one choice's tooltip (SetTooltip's rules); false if no choice has `value`.
        SetOptionTooltip = function(s, value, tooltip)
            live(s)
            for _, item in ipairs(s.items) do
                if item.value == value then
                    item.tooltip = tooltip
                    item.tip = replaceTip(
                        s.lib,
                        item.tip,
                        tooltip,
                        item.rowState,
                        s.context.parent,
                        s.context
                    )
                    return true
                end
            end
            return false
        end,
        Destroy = function(s)
            if s.destroyed then return end
            s.destroyed = true
            destroyTip(s.tip)
            for _, item in ipairs(s.items) do
                destroyTip(item.tip)
            end
            s.root:Destroy()
            s.root = nil
        end,
    },
})

-- AddSpriteButton on a Window or Panel: a button in the content flow. Given a y, the button
-- is placed there and the flow doesn't move.
---@param s table the owner state
---@param spriteName any
---@param action any
---@param options any
---@return table
local function addSpriteButton(s, spriteName, action, options)
    live(s)
    options = checkOptions("SpriteButton", options)
    local placed = {}
    for k, v in pairs(options) do
        placed[k] = v
    end
    local height = options.height or options.size or SPRITE_BUTTON_SIZE
    placed.x = options.x or PADDING
    if options.y == nil then placed.y = flowRow(s.flow, height, ROW_GAP, 0) end
    grow(s.flow, placed.y + height)
    return newSpriteButton(s.lib, s.contentState, spriteName, action, placed, s.tips)
end

-- AddText / AddTitle: a ui.Text row the plugin can set .content on. The fake can't measure
-- fonts, so text doesn't wrap: a body row is one line per <br>-separated part.
---@param lib table
---@param s table the owner (Window) state
---@param value any a string, or { text, tooltip, y }
---@param isTitle boolean
---@return table
local function addText(lib, s, value, isTitle)
    live(s)
    local options = type(value) == "table" and checkOptions("Text", value) or { text = value }
    local text = tostring(options.text or "")
    local _, breaks = text:gsub("<br>", "")
    local height = isTitle and TITLE_HEIGHT_ROW
        or math.max(TEXT_HEIGHT, (breaks + 1) * LINE_HEIGHT + 6)
    -- Given a y, 1.2.0 places the row there (absolute) and the flow doesn't move.
    local y = options.y
        or flowRow(s.flow, height, isTitle and TITLE_GAP or TEXT_GAP, isTitle and TITLE_MARGIN or 0)
    grow(s.flow, y + height)
    local label, ls = ui.create("Text", s.contentState)
    label:SetPos(PADDING, y)
    label:SetSize(-PADDING * 2, height, 1.0)
    ls.content = text
    ls.tip = attachTip(lib, ls, s.tips.parent, options.tooltip, s.tips)
    track(lib, isTitle and "Title" or "Text", label, ls)
    return label
end

---@param lib table
---@param s table
---@param choices any
---@param options any
---@return table
local function addCheckbox(lib, s, choices, options)
    live(s)
    options = checkOptions("CheckboxButton", options)
    if type(choices) ~= "table" or #choices == 0 then
        strict.fault("Selection button choices must be a non-empty array", true)
    end
    local preset = {}
    for k, v in pairs(options.selectedValues or {}) do
        if type(k) == "number" then
            preset[v] = true
        else
            preset[k] = v == true
        end
    end
    local cs = {
        kind = "CheckboxButton",
        lib = lib,
        items = {},
        onChange = options.onChange,
        colour = options.colour,
        context = s.tips,
    }
    local height = #choices * CHECKBOX_ROW
    -- Given a y, 1.2.0 places it there (absolute) and the flow doesn't move.
    local y = options.y or flowRow(s.flow, height, ROW_GAP, 0)
    grow(s.flow, y + height)
    cs.root, cs.rootState = ui.create("Layer", s.contentState)
    cs.root:SetPos(PADDING, y)
    cs.root:SetSize(-PADDING * 2, height, 1.0)
    for i, choice in ipairs(choices) do
        local item
        if type(choice) == "table" then
            checkOptions("Choice", choice)
            local text = choice.text or choice.label
            if text == nil then text = choice.value end
            item = {
                text = tostring(text or ""),
                value = choice.value,
                selected = choice.selected == true,
                disabled = choice.disabled == true,
                tooltip = choice.tooltip,
            }
            if item.value == nil then item.value = item.text end
        else
            item = { text = tostring(choice), value = choice, selected = false, disabled = false }
        end
        item.selected = item.selected or preset[item.value] == true
        local row, rowState = ui.create("Layer", cs.rootState)
        row:SetPos(0, (i - 1) * CHECKBOX_ROW)
        row:SetSize(0, CHECKBOX_ROW, 1.0)
        item.rowState = rowState
        item.tip = attachTip(lib, rowState, s.tips.parent, item.tooltip, s.tips)
        cs.items[i] = item
    end
    cs.tip = attachTip(lib, cs.rootState, s.tips.parent, options.tooltip, s.tips)
    local obj = Checkbox.new(cs)
    cs.proxy = obj
    track(lib, "CheckboxButton", obj, cs)
    return obj
end

---@param lib table
---@param s table
---@param options any
---@return table
local function addDivider(lib, s, options)
    live(s)
    options = checkOptions("Divider", options)
    local ds = { kind = "Divider" }
    local y = flowRow(s.flow, DIVIDER_HEIGHT, ROW_GAP, 0)
    grow(s.flow, y + DIVIDER_HEIGHT)
    ds.root, ds.rootState = ui.create("Sprite", s.contentState)
    ds.root:SetPos(0, y)
    ds.root:SetSize(0, DIVIDER_HEIGHT, 1.0)
    ds.tip = attachTip(lib, ds.rootState, s.tips.parent, options.tooltip, s.tips)
    local obj = Divider.new(ds)
    track(lib, "Divider", obj, ds)
    return obj
end

-- The viewport's height: the window inside its frame.
---@param s table
---@return integer
local function viewportHeight(s)
    return math.max(1, ui.height(s.viewportState))
end

-- Size the content to the scroll height (the content height, or the viewport's if that is
-- taller) and scroll the viewport over it, as 1.2.0's `_Layout` and `SetScrollPosition` do
-- (content:SetSize, viewport:SetScrollPos). The content and everything on it move up by the
-- scroll; their own x, y don't change.
---@param s table
local function syncContent(s)
    s.content:SetSize(0, math.max(s.flow.contentHeight, viewportHeight(s)), 1.0)
    s.viewportState.scrollY = s.scrollY
end

-- 1.2.0's Window:_SyncOverlays(hidden) (src/window.lua): unless `hidden`, each registered
-- overlay's layout() runs; then the overlay is hidden if `hidden` or its isVisible() returns
-- false, and raised if not. 1.2.0 skips an overlay only when its interface is gone, which a
-- plugin-layer component shares with the window, so a destroyed one still registered is
-- touched: here that faults, as any use of a destroyed component does.
---@param s table
---@param hidden boolean
local function syncOverlays(s, hidden)
    -- A layout() may register or unregister; go over the ones registered now.
    for _, overlay in ipairs(table.move(s.overlays, 1, #s.overlays, 1, {})) do
        if not hidden and overlay.layout then overlay.layout() end
        local hide = hidden or (overlay.isVisible ~= nil and not overlay.isVisible())
        overlay.component.hidden = hide
        if not hide then overlay.component:MoveToFront() end
    end
end

-- Whether the window's root is hidden, as 1.2.0 passes it to _SyncOverlays after a scroll or a
-- resize.
---@param s table
---@return boolean
local function rootHidden(s)
    return s.rootState.hidden == true
end

-- Window:SetScrollPosition: the content's scroll, clamped to 0..(content height less the
-- viewport's), as 1.2.0 does on every scroll and resize; then the overlays sync, moved or not
-- (src/core/scroll.lua, SetScrollPosition).
---@param s table
---@param position number?
local function windowScrollTo(s, position)
    if position ~= nil and type(position) ~= "number" then
        strict.fault("prettyui Window:SetScrollPosition(position) needs a number")
    end
    local most = math.max(0, s.flow.contentHeight - viewportHeight(s))
    s.scrollY = clamp(math.floor(position or 0), 0, most)
    syncContent(s)
    syncOverlays(s, rootHidden(s))
end

-- Window:SetContentHeight(height): the scrollable height, floored and at least 0. It replaces
-- the height the rows grew it to (a later row placed lower grows it again), and re-clamps
-- the scroll.
---@param s table
---@param height number
local function windowSetContentHeight(s, height)
    live(s)
    if type(height) ~= "number" then
        strict.fault("prettyui Window:SetContentHeight(height) needs a number")
    end
    s.flow.contentHeight = math.max(0, math.floor(height))
    windowScrollTo(s, s.scrollY)
end

-- The window's wheel handler (its scroll controller's `_onScrollWheel`), as 1.2.0 binds it
-- to the content: while the content overflows it scrolls by delta * 32 px and returns false
-- if the position moved; otherwise it returns true. A top-level window has no parent
-- handler to pass the wheel on to.
---@param s table
---@param delta number
---@return boolean
local function windowWheel(s, delta)
    live(s)
    if s.flow.contentHeight > viewportHeight(s) then
        local before = s.scrollY
        windowScrollTo(s, before + delta * SCROLL_STEP)
        if s.scrollY ~= before then return false end
    end
    return true
end

-- Window:SetSize, clamped to the window's min/max; it also makes the current position the
-- one a stray root:SetPos snaps back to, and re-clamps the scroll. 1.2.0 syncs the overlays
-- again after the scroll's sync (src/window.lua, SetSize).
---@param s table
---@param width number
---@param height number
local function windowSetSize(s, width, height)
    s.root:SetSize(
        clamp(math.floor(width), s.minWidth, s.maxWidth),
        clamp(math.floor(height), s.minHeight, s.maxHeight)
    )
    if s.bounded then remember(s) end
    windowScrollTo(s, s.scrollY)
    syncOverlays(s, rootHidden(s))
end

-- The end of a title-bar press (1.2.0's stopDrag, src/window.lua), on its release and on every
-- Close, Destroy and resize: it syncs the overlays, shown. Only a titled window has it.
---@param s table
local function stopTitleDrag(s)
    if s.title then syncOverlays(s, false) end
end

-- Window:Show: the root, then the title-bar drag layer, to the front, then the overlays sync
-- (src/window.lua, Show).
---@param s table
local function windowShow(s)
    s.root.hidden = false
    s.root:MoveToFront()
    if s.titleDrag then
        s.titleDrag.hidden = false
        s.titleDrag:MoveToFront()
    end
    syncOverlays(s, false)
end

-- Hide (Close) or destroy (Destroy) every tooltip of a host's content context.
---@param context table
---@param destroy boolean
local function clearContext(context, destroy)
    for _, tip in ipairs(context.tips) do
        tip.shown = false
        if destroy then tip.destroyed = true end
    end
end

-- Close: end any title-bar press, hide the content's tooltips, call onClose(window), then
-- hide and sync the overlays hidden (the 1.2.0 order).
---@param s table
local function windowClose(s)
    live(s)
    stopTitleDrag(s)
    clearContext(s.tips, false)
    if s.onClose then s.onClose(s.proxy) end
    if not s.destroyed then
        s.root.hidden = true
        if s.titleDrag then s.titleDrag.hidden = true end
        syncOverlays(s, true)
    end
end

-- 1.2.0's internal overlay registry (src/window.lua): `component` is synced with the window
-- (syncOverlays) until unregistered or the window is destroyed. Registering one again
-- replaces its callbacks.
---@param s table
---@param component any
---@param isVisible any
---@param layout any
local function registerOverlay(s, component, isVisible, layout)
    live(s)
    if ui.stateOf(component) == nil then
        strict.fault("prettyui Window:_RegisterOverlay(component, ...) needs a component")
    end
    for _, fn in ipairs({ isVisible or false, layout or false }) do
        if fn and type(fn) ~= "function" then
            strict.fault("prettyui Window:_RegisterOverlay: isVisible and layout are functions")
        end
    end
    local entry = { component = component, isVisible = isVisible, layout = layout }
    for i, overlay in ipairs(s.overlays) do
        if overlay.component == component then
            s.overlays[i] = entry
            return
        end
    end
    s.overlays[#s.overlays + 1] = entry
end

---@param s table
---@param component any
local function unregisterOverlay(s, component)
    for i, overlay in ipairs(s.overlays) do
        if overlay.component == component then
            table.remove(s.overlays, i)
            return
        end
    end
end

-- An overlay-registry method served as a field, so a window made after
-- `h.ui:overlayInternals(false)` reads it as nil, standing in for a PrettyUI without it.
---@param s table
---@param name string
---@param fn fun(s: table, ...)
---@return function?
local function overlayMethod(s, name, fn)
    if s.noOverlayInternals then return nil end
    return function(self, ...)
        if self ~= s.proxy then
            strict.fault("prettyui Window." .. name .. " is a method: call it with ':'")
        end
        fn(s, ...)
    end
end

-- The keys of 1.2.0's eight resize handles (src/core/resize.lua).
local RESIZE_HANDLES = { "n", "s", "e", "w", "nw", "ne", "sw", "se" }

-- Stand-ins for 1.2.0's `resize` controller and its `handles` table. Stricter than 1.2.0's plain
-- table on purpose: an unknown key such as `resize.handle` or `handles.nn` faults, not reads nil.
-- `state.handles` is set for every resizable window; only the `resize` getter's `handles` field
-- reads nil under `resizeInternals("noHandles")`, and its `n` under `"noN"`.
local ResizeHandles = strict.class("prettyui.Window resize handles", {
    undeclared = true,
    fields = (function()
        local fields = {}
        for _, key in ipairs(RESIZE_HANDLES) do
            fields[key] = function(s)
                return s[key]
            end
        end
        return fields
    end)(),
})
local ResizeController = strict.class("prettyui.Window resize", {
    undeclared = true,
    fields = {
        handles = function(s)
            return s.handles and ResizeHandles.new(s.handles) or nil
        end,
    },
})

local Window = strict.class("prettyui.Window instance", {
    undeclared = true,
    fields = {
        root = function(s)
            return s.root
        end,
        closeButton = function(s)
            return s.closeButton
        end,
        -- The scrolling layer the rows live in, for a plugin's own components.
        content = function(s)
            if s.destroyed then return nil end
            return s.content
        end,
        -- The layer the content scrolls in: its rect is the part of the content on show.
        -- Public state 1.2.0's scroll controller syncs onto the window (`syncOwner`).
        viewport = function(s)
            if s.destroyed then return nil end
            return s.viewport
        end,
        -- 1.2.0's internal wheel handler (also set on the window by its scroll controller):
        -- a plugin hands it to a row's ONSCROLLWHEEL so the wheel still scrolls the window.
        _onScrollWheel = function(s)
            return s.onWheel
        end,
        -- 1.2.0's internal scroll controller; only its scrollY is modelled, as a snapshot.
        _scroll = function(s)
            if s.destroyed then return nil end
            return { scrollY = s.scrollY }
        end,
        -- 1.2.0's internal title-bar drag layer (a titled window's only), a sibling of the root
        -- on the window's parent. Only its stacking and `hidden` are modelled: its rect is left
        -- 0x0 at the origin (`lands` models the title bar it covers), and it is not one of the
        -- plugin's own layers, so it takes no pointer actions.
        titleDrag = function(s)
            return s.titleDrag
        end,
        -- 1.2.0's internal resize controller of a resizable window: only its `handles` are
        -- modelled, eight bare layers on the window's parent. A window made after
        -- `h.ui:resizeInternals("none" or "noHandles")` reads it as nil (or without handles),
        -- and after `"noN"` its `n` handle reads nil.
        resize = function(s)
            if s.destroyed or not s.handles or s.resizeMode == "none" then return nil end
            local handles = s.handles
            if s.resizeMode == "noHandles" then
                handles = nil
            elseif s.resizeMode == "noN" then
                handles = {}
                for key, handle in pairs(s.handles) do
                    if key ~= "n" then handles[key] = handle end
                end
            end
            return ResizeController.new({ handles = handles })
        end,
        _RegisterOverlay = function(s)
            return overlayMethod(s, "_RegisterOverlay", registerOverlay)
        end,
        _UnregisterOverlay = function(s)
            return overlayMethod(s, "_UnregisterOverlay", unregisterOverlay)
        end,
    },
    methods = {
        SetSize = function(s, width, height)
            live(s)
            if type(width) ~= "number" or type(height) ~= "number" then
                strict.fault("prettyui Window:SetSize(width, height) needs numbers")
            end
            windowSetSize(s, width, height)
        end,
        SetScrollPosition = function(s, position)
            live(s)
            windowScrollTo(s, position)
        end,
        SetContentHeight = windowSetContentHeight,
        Show = function(s)
            live(s)
            windowShow(s)
        end,
        Close = windowClose,
        -- 1.2.0 ends any title-bar press and syncs the overlays hidden before tearing down,
        -- then forgets them (src/window.lua, Destroy).
        Destroy = function(s)
            if s.destroyed then return end
            stopTitleDrag(s)
            syncOverlays(s, true)
            s.overlays = {}
            s.destroyed = true
            clearContext(s.tips, true)
            destroyTip(s.tip)
            if s.titleDrag then
                s.titleDrag:Destroy()
                s.titleDrag = nil
            end
            for _, handle in pairs(s.handles or {}) do
                handle:Destroy()
            end
            s.handles = nil
            s.root:Destroy()
            s.root = nil
        end,
        AddText = function(s, value)
            return addText(s.lib, s, value, false)
        end,
        AddTitle = function(s, value)
            return addText(s.lib, s, value, true)
        end,
        AddCheckboxButton = function(s, choices, options)
            return addCheckbox(s.lib, s, choices, options)
        end,
        AddDivider = function(s, options)
            return addDivider(s.lib, s, options)
        end,
        AddSpriteButton = function(s, spriteName, action, options)
            return addSpriteButton(s, spriteName, action, options)
        end,
    },
})

local Panel = strict.class("prettyui.Panel instance", {
    undeclared = true,
    fields = {
        root = function(s)
            return s.root
        end,
        width = function(s)
            return s.width
        end,
        height = function(s)
            return s.height
        end,
    },
    methods = {
        -- Clamped to at least 9x9, then kept inside the parent; also makes the current
        -- position the one a stray root:SetPos snaps back to.
        SetSize = function(s, width, height)
            live(s)
            if type(width) ~= "number" or type(height) ~= "number" then
                strict.fault("prettyui Panel:SetSize(width, height) needs numbers")
            end
            s.width = clamp(math.floor(width), PANEL_MIN)
            s.height = clamp(math.floor(height), PANEL_MIN)
            s.root:SetSize(s.width, s.height)
            clampIntoParent(s)
        end,
        -- Rows flow from (14, 12) inside the 4 px frame, so the first sits at +18,+16 (probe).
        AddSpriteButton = function(s, spriteName, action, options)
            return addSpriteButton(s, spriteName, action, options)
        end,
        Destroy = function(s)
            if s.destroyed then return end
            s.destroyed = true
            clearContext(s.tips, true)
            destroyTip(s.tip)
            s.root:Destroy()
            s.root = nil
        end,
    },
})

-- The library tables: prettyui.Window.new(...) and so on.
---@param name string
---@param new function
---@return table class
local function module(name, new)
    return strict.class("prettyui." .. name, { undeclared = true, statics = { new = new } })
end

local WindowModule = module("Window", function(lib, parent, options)
    local ps = parentState("Window.new", parent)
    options = checkOptions("Window", options)
    local s = {
        kind = "Window",
        lib = lib,
        title = options.title,
        onClose = options.onClose,
        tips = newContext(ps),
        resizable = options.resizable == true,
        minWidth = options.minWidth or WINDOW_DEFAULTS.minWidth,
        minHeight = options.minHeight or WINDOW_DEFAULTS.minHeight,
        maxWidth = options.maxWidth,
        maxHeight = options.maxHeight,
        flow = { nextY = START_Y, hasItems = false, contentHeight = 0 },
        destroyed = false,
    }
    s.root, s.rootState = ui.create("Layer", ps)
    s.root:SetPos(options.x or WINDOW_DEFAULTS.x, options.y or WINDOW_DEFAULTS.y)
    s.root:SetSize(
        clamp(options.width or WINDOW_DEFAULTS.width, s.minWidth, s.maxWidth),
        clamp(options.height or WINDOW_DEFAULTS.height, s.minHeight, s.maxHeight)
    )
    local top = s.title and TITLE_HEIGHT or BORDER
    s.scrollY = 0
    -- 1.2.0 puts the viewport at 0,0 in a scroll root inside the frame; the fake leaves out
    -- that root (same place) and the scrollbar, so the viewport is the frame's full width.
    s.viewport, s.viewportState = ui.create("Layer", s.rootState)
    s.viewport:SetPos(BORDER, top)
    s.viewport:SetSize(-BORDER * 2, -top - BORDER, 1.0, 1.0)
    s.content, s.contentState = ui.create("Layer", s.viewportState)
    -- Both take pointer input and hand the wheel to the window's handler, as the scroll
    -- controller sets them up (subscribed with no id, so it is their default ONSCROLLWHEEL
    -- listener); the h.ui driver treats them like a plugin's own layers.
    s.onWheel = function(_, delta)
        return windowWheel(s, delta)
    end
    for _, layer in ipairs({ s.viewportState, s.contentState }) do
        layer.clickthrough = false
        layer.raw = true
        ui.addListener(layer, ui.Hook.ONSCROLLWHEEL, nil, s.onWheel)
    end
    s.flow.onGrow = function()
        syncContent(s)
    end
    syncContent(s)
    s.overlays = {}
    s.noOverlayInternals = lib.h.ui.noOverlayInternals
    if s.title then s.titleDrag = ui.create("Layer", ps) end
    s.resizeMode = lib.h.ui.resizeMode
    if s.resizable then
        s.handles = {}
        for _, key in ipairs(RESIZE_HANDLES) do
            s.handles[key] = ui.create("Layer", ps)
        end
    end
    s.closeButton, s.closeState = ui.create("Sprite", s.rootState)
    s.closeButton:SetPos(-CLOSE_SIZE - CLOSE_RIGHT, CLOSE_Y, 1.0)
    s.closeButton:SetSize(CLOSE_SIZE, CLOSE_SIZE)
    s.tip = attachTip(lib, s.rootState, ps, options.tooltip, nil)
    -- Only a titled or resizable window gets PrettyUI's drag bounds, which snap a stray
    -- root:SetPos back.
    s.bounded = s.title ~= nil or s.resizable
    if s.bounded then remember(s) end
    local obj = Window.new(s)
    s.proxy = obj
    lib.closeButtons[s.closeState] = s
    track(lib, "Window", obj, s)
    return obj
end)

local PanelModule = module("Panel", function(lib, parent, options)
    local ps = parentState("Panel.new", parent)
    options = checkOptions("Panel", options)
    local s = {
        kind = "Panel",
        lib = lib,
        tips = newContext(ps),
        backgroundAlpha = options.backgroundAlpha,
        width = options.width or PANEL_DEFAULTS.width,
        height = options.height or PANEL_DEFAULTS.height,
        flow = { nextY = START_Y, hasItems = false, contentHeight = 0 },
        destroyed = false,
    }
    s.root, s.rootState = ui.create("Layer", ps)
    s.root:SetPos(options.x or 0, options.y or 0)
    s.root:SetSize(s.width, s.height)
    local content
    content, s.contentState = ui.create("Layer", s.rootState)
    content:SetPos(PANEL_BORDER, PANEL_BORDER)
    content:SetSize(-PANEL_BORDER * 2, -PANEL_BORDER * 2, 1.0, 1.0)
    s.tip = attachTip(lib, s.rootState, ps, options.tooltip, nil)
    clampIntoParent(s)
    local obj = Panel.new(s)
    s.proxy = obj
    track(lib, "Panel", obj, s)
    return obj
end)

local SpriteButtonModule = module("SpriteButton", function(lib, parent, spriteName, action, options)
    local ps = parentState("SpriteButton.new", parent)
    return newSpriteButton(lib, ps, spriteName, action, checkOptions("SpriteButton", options))
end)

-- AchievementPopup (src/achievement_popup.lua): a frame of PrettyUI's own sprites with a title
-- and a text, fading in over 15 ticks and out over the last 25, and ending itself on the 201st
-- Logic tick after it was made (elapsed ticks > 200: 15 in, 160 held, 25 out): it destroys
-- itself, then calls onComplete(popup). It subscribes its own Logic callback, named
-- prettyui_achievement_popup_<n>. The sound is not played; `played` records the id it would
-- (soundID, else ARCH_INFO_POPUP; none for sound = false).
local POPUP_DEFAULTS = { width = 300, height = 92, y = 20 }
local POPUP_TICKS = 200
local POPUP_MIN = 9
local DEFAULT_POPUP_SOUND = "ARCH_INFO_POPUP"

-- Add and remove the popup's own Logic subscription in the plugin's subscriber list. The
-- real library does this from Lua; going through the plugin's Event global would put the
-- harness's runtime (a C frame) between the call and the Unsubscribe check of events.lua.
---@param instance table
---@param name string
---@param fn function
local function subscribeLogic(instance, name, fn)
    table.insert(instance.subs.Logic, { name = name, fn = fn })
end

---@param instance table
---@param name string
local function unsubscribeLogic(instance, name)
    for i, entry in ipairs(instance.subs.Logic) do
        if entry.name == name then
            table.remove(instance.subs.Logic, i)
            entry.removed = true
            return
        end
    end
end

local AchievementPopup = strict.class("prettyui.AchievementPopup instance", {
    undeclared = true,
    fields = {
        root = function(s)
            return s.root
        end,
    },
    methods = {
        Destroy = function(s)
            if s.destroyed then return end
            s.destroyed = true
            unsubscribeLogic(s.lib.h.instance, s.eventName)
            s.root:Destroy()
            s.root = nil
            s.onComplete = nil
        end,
    },
})

-- Make a popup in `parent` and start its Logic countdown.
---@param lib table
---@param parent any
---@param options any
---@return table popup
local function newPopup(lib, parent, options)
    local ps = parentState("AchievementPopup", parent)
    options = checkOptions("AchievementPopup", options)
    lib.popupCount = lib.popupCount + 1
    local width = math.max(POPUP_MIN, options.width or POPUP_DEFAULTS.width)
    local height = math.max(POPUP_MIN, options.height or POPUP_DEFAULTS.height)
    local s = {
        kind = "AchievementPopup",
        lib = lib,
        parent = parent,
        title = tostring(options.title or "ACHIEVEMENT COMPLETE"),
        text = tostring(options.text or ""),
        width = width,
        height = height,
        sound = options.sound,
        soundID = options.soundID,
        onComplete = options.onComplete,
        eventName = "prettyui_achievement_popup_" .. lib.popupCount,
        elapsed = 0,
        completed = false,
        destroyed = false,
    }
    if options.sound ~= false then s.played = options.soundID or ui.soundId(DEFAULT_POPUP_SOUND) end
    s.root, s.rootState = ui.create("Layer", ps)
    s.root:SetPos(
        options.x or -math.floor(width / 2),
        options.y or POPUP_DEFAULTS.y,
        options.xAnchor == nil and 0.5 or options.xAnchor,
        options.yAnchor or 0
    )
    s.root:SetSize(width, height)
    local obj = AchievementPopup.new(s)
    s.proxy = obj
    track(lib, "AchievementPopup", obj, s)
    subscribeLogic(lib.h.instance, s.eventName, function()
        if s.destroyed then return end
        s.elapsed = s.elapsed + 1
        if s.elapsed > POPUP_TICKS then
            local onComplete = s.onComplete
            s.proxy:Destroy()
            s.completed = true
            if onComplete then onComplete(s.proxy) end
        end
    end)
    return obj
end

local AchievementPopupModule = strict.class("prettyui.AchievementPopup", {
    undeclared = true,
    statics = {
        new = function(lib, parent, options)
            return newPopup(lib, parent, options)
        end,
        -- nil when there is no parent, as in 1.2.0. The real one then falls back to the game
        -- area, which the harness doesn't have: a plugin must pass a parent. The driver's
        -- popupsFail() stands in for a client with nowhere to put it.
        show = function(lib, options)
            options = checkOptions("AchievementPopup", options)
            if lib.popupsFail then return nil end
            if options.parent == nil then
                strict.fault("unmocked API: AchievementPopup.show without options.parent")
            end
            return newPopup(lib, options.parent, options)
        end,
    },
})

local TooltipModule = strict.class("prettyui.Tooltip", {
    undeclared = true,
    statics = { attach = attachRawTooltip },
})

local Library = strict.class("prettyui", {
    undeclared = true,
    fields = {
        Window = function(s)
            return s.Window
        end,
        Panel = function(s)
            return s.Panel
        end,
        SpriteButton = function(s)
            return s.SpriteButton
        end,
        AchievementPopup = function(s)
            return s.AchievementPopup
        end,
        Tooltip = function(s)
            return s.Tooltip
        end,
        version = function()
            return M.VERSION
        end,
    },
})

-- Expose the fake as `env[global]`. One library per load, shared by every global that
-- names it.
---@param h table the harness
---@param env table
---@param global string
function M.install(h, env, global)
    local instance = h.instance
    if not instance.prettyui then
        local lib = {
            records = {},
            byObj = setmetatable({}, { __mode = "k" }),
            closeButtons = {},
            tooltips = {},
            rawTips = {}, -- target state -> its Tooltip.attach tooltip
            h = h,
            popupCount = 0,
        }
        lib.global = Library.new({
            Window = WindowModule.new(lib),
            Panel = PanelModule.new(lib),
            SpriteButton = SpriteButtonModule.new(lib),
            AchievementPopup = AchievementPopupModule.new(lib),
            Tooltip = TooltipModule.new(lib),
        })
        instance.prettyui = lib
    end
    env[global] = instance.prettyui.global
end

-- Once per harness step, before Logic: a Window or Panel root moved by a bare root:SetPos
-- goes back to its remembered position. The probe saw PrettyUI's drag bounds do this to a
-- Panel; when the client triggers it is unknown (docs/testing.md, fidelity ledger).
---@param h table
function M.step(h)
    local lib = h.instance and h.instance.alive and h.instance.prettyui
    if not lib then return end
    for _, r in ipairs(lib.records) do
        local s = r.s
        if (r.kind == "Window" or r.kind == "Panel") and not gone(r) and s.remembered then
            local x, y = ui.pos(s.rootState)
            if x ~= s.remembered.x or y ~= s.remembered.y then
                s.root:SetPos(s.remembered.x, s.remembered.y)
            end
        end
    end
end

---------------------------------------------------------------------------
-- The test driver: h.ui
---------------------------------------------------------------------------

local Driver = {}
Driver.__index = Driver

---@param h table
---@return table
function M.driver(h)
    return setmetatable(
        { h = h, altHeld = false, noOverlayInternals = false, resizeMode = "all" },
        Driver
    )
end

---@return table lib
function Driver:lib()
    local instance = self.h.instance
    assert(instance and instance.alive, "plugin not loaded")
    return assert(instance.prettyui, "the plugin has no prettyui dependency")
end

-- Every AchievementPopup the plugin has made, oldest first. Each is the popup's state:
-- title, text, width, height, sound, soundID, `played` (the sound id it would have played,
-- nil for none), `root`, `elapsed` Logic ticks, `destroyed` and `completed` (ended on its
-- own, so onComplete ran).
---@return table[]
function Driver:popups()
    local out = {}
    for _, r in ipairs(self:lib().records) do
        if r.kind == "AchievementPopup" then out[#out + 1] = r.s end
    end
    return out
end

-- Make every Window made from now on without (false) or with (true, the default) 1.2.0's
-- internal `_RegisterOverlay` and `_UnregisterOverlay`: without, they read nil, as on a
-- PrettyUI version that lacks them. Set it before `h:load()` for a window made at load.
---@param on boolean
function Driver:overlayInternals(on)
    self.noOverlayInternals = not on
end

-- Make every Window made from now on lack 1.2.0's internal `resize` ("none") or its `handles`
-- ("noHandles") or its `n` handle ("noN"), as on a PrettyUI version that lacks them; "all"
-- (the default) restores them. Set it before `h:load()` for a window made at load.
---@param mode "all"|"none"|"noHandles"|"noN"
function Driver:resizeInternals(mode)
    self.resizeMode = mode
end

-- The components registered as a Window's overlays, in the order registered.
---@param win table
---@return table[]
function Driver:overlays(win)
    local out = {}
    for i, overlay in ipairs(self:record(win, "Window").s.overlays) do
        out[i] = overlay.component
    end
    return out
end

-- Make AchievementPopup.show return nil from now on (true), or work again (false).
---@param on boolean
function Driver:popupsFail(on)
    self:lib().popupsFail = on
end

---@param obj any
---@param kind string?
---@return table record
function Driver:record(obj, kind)
    local r = self:lib().byObj[obj]
    assert(r, "not a PrettyUI object of this plugin: " .. tostring(obj))
    assert(kind == nil or r.kind == kind, "expected a " .. tostring(kind) .. ", got a " .. r.kind)
    return r
end

-- The text a record can be found by.
---@param r table
---@return string[]
local function texts(r)
    if r.kind == "Window" then return { r.s.title } end
    if r.kind == "Text" or r.kind == "Title" then return { r.s.content } end
    if r.kind == "CheckboxButton" then
        local out = {}
        for i, item in ipairs(r.s.items) do
            out[i] = item.text
        end
        return out
    end
    return {}
end

-- Live objects of `kind` ("Window", "Panel", "SpriteButton", "Text", "Title",
-- "CheckboxButton", "Divider"), in creation order. `filter`: { sprite = "MENU" } and/or
-- { text = "substring" } (a Window's title, a Text's content, a checkbox choice) and/or
-- { visible = true } (neither it nor an ancestor is hidden).
---@param kind string
---@param filter table?
---@return table[]
function Driver:find(kind, filter)
    filter = filter or {}
    local out = {}
    for _, r in ipairs(self:lib().records) do
        local ok = r.kind == kind and not gone(r)
        if ok and filter.sprite then ok = r.s.spriteName == filter.sprite:upper() end
        if ok and filter.visible then ok = ui.visible(r.s.rootState or r.s) end
        if ok and filter.text then
            ok = false
            for _, t in ipairs(texts(r)) do
                if t and t:find(filter.text, 1, true) then ok = true end
            end
        end
        if ok then out[#out + 1] = r.obj end
    end
    return out
end

-- The one live object matching; errors on none or several.
---@param kind string
---@param filter table?
---@return table
function Driver:get(kind, filter)
    local found = self:find(kind, filter)
    assert(#found == 1, string.format("expected one %s, found %d", kind, #found))
    return found[1]
end

-- A CheckboxButton's choices as plain data, in order: { text, value, selected, disabled,
-- tooltip }, and the group's text colour (nil for PrettyUI's default).
---@param checkbox table
---@return table[] choices
---@return integer? colour
function Driver:choices(checkbox)
    local r = self:record(checkbox, "CheckboxButton")
    local out = {}
    for i, item in ipairs(r.s.items) do
        out[i] = {
            text = item.text,
            value = item.value,
            selected = item.selected,
            disabled = item.disabled,
            tooltip = item.tooltip,
        }
    end
    return out, r.s.colour
end

-- The point the driver aims at on `cs` when a test gives none: its centre, in plugin-layer
-- coordinates.
---@param cs table component state
---@return number x
---@return number y
local function centre(cs)
    local x, y = ui.drawnPos(cs)
    return x + ui.width(cs) / 2, y + ui.height(cs) / 2
end

-- Whether a click on component `cs` at (cx, cy) (default: its centre) reaches it, and why
-- not. A destroyed one faults: a plugin that leaves a handle to it reachable has lost track of
-- its UI.
---@param cs table component state
---@param cx number?
---@param cy number?
---@return boolean
---@return string?
function Driver:lands(cs, cx, cy)
    if cs.destroyed then strict.fault("prettyui: clicked a component used after Destroy()") end
    if not ui.visible(cs) then return false, "hidden" end
    if cx == nil or cy == nil then
        cx, cy = centre(cs)
    end
    local clip = self:clipped(cs, cx, cy)
    if clip then return false, clip end
    for _, r in ipairs(self:lib().records) do
        local s = r.s
        if r.kind == "Window" and s.title and not gone(r) and ui.within(cs, s.rootState) then
            -- The title-bar drag layer sits over the window, short of the X's slot (probe).
            local wx, wy = ui.drawnPos(s.rootState)
            local right = wx + ui.width(s.rootState) - DRAG_LAYER_GAP
            if cx >= wx and cx < right and cy >= wy and cy < wy + TITLE_HEIGHT then
                return false, "covered by the window's title-bar drag layer"
            end
        end
        if r.kind == "Panel" and self.altHeld and not gone(r) and ui.within(cs, s.rootState) then
            return false, "Alt is held: the panel's drag layer takes the click"
        end
    end
    return true
end

-- Why a pointer action at (x, y) on component `cs` is clipped away, or nil if it isn't: the
-- point must lie in `cs`'s rect clipped by every ancestor's. The client clips hit-testing as
-- well as drawing: a row scrolled out of a window takes no click, and a press ends when the
-- pointer leaves the pressed layer or a parent's rect (docs/api-concepts.md, "Pointer hooks on a
-- plain `ui.Layer`" and "Pressing and dragging a plain `ui.Layer`").
---@param cs table component state
---@param x number
---@param y number
---@return string?
function Driver:clipped(cs, x, y)
    local by = ui.clipper(cs, x, y)
    if by == nil then return nil end
    for _, r in ipairs(self:lib().records) do
        if r.kind == "Window" and not gone(r) and by == r.s.viewportState then
            return "clipped: scrolled out of the window's view"
        end
    end
    if by == cs then return "clipped: the point is outside the target" end
    return "clipped: outside the " .. by.class .. " it is in"
end

-- The component on top at (x, y) among those that take the pointer there: a plugin's own (or
-- a window's content or viewport), shown, `clickthrough` false, with the point in its clipped
-- rect. Drawing order decides: children draw over their parent, later siblings over earlier
-- ones, and MoveToFront makes a component its parent's last child (ui/component.html). A
-- non-clickthrough component blocks the ones below it (the `clickthrough` field). PrettyUI's
-- own components aren't counted: the fake doesn't model their `clickthrough`. Faults on a
-- component drawn over `below` whose `clickthrough` was never set (the default is unprobed).
---@param x number
---@param y number
---@param below table the component the pointer would otherwise reach
---@return table?
function Driver:topAt(x, y, below)
    local top, pastBelow = nil, false
    local function visit(s)
        if s.hidden or s.destroyed then return end
        -- Ancestors have already passed, so the point is in the clipped rect iff in its own.
        if ui.clipper(s, x, y) == s then return end
        if s == below then pastBelow = true end
        if s.raw then
            if s.clickthrough == nil and pastBelow then
                strict.fault(
                    "prettyui: a "
                        .. s.class
                        .. " drawn over the target never had clickthrough set, and the "
                        .. "client's default is unprobed"
                )
            end
            if s.clickthrough == false then top = s end
        end
        for _, child in ipairs(s.children) do
            visit(child)
        end
    end
    visit(self.h.instance.uiRoot)
    return top
end

-- Whether a component the plugin made (or a window's content or viewport) is one the raw
-- pointer actions below apply to.
---@param cs table?
---@return boolean
local function isRaw(cs)
    return cs ~= nil and cs.raw == true
end

-- The component that takes a pointer action aimed at `cs`, at (x, y) in plugin-layer
-- coordinates (default: its centre): itself, or its nearest ancestor that isn't clickthrough
-- (the plugin root layer is the client's and takes none). Returns nil and why when the action
-- doesn't land: hidden, clipped (the point outside its clipped rect, e.g. scrolled out of a
-- window), nothing under the pointer takes it, or another component is drawn over it there
-- (see `topAt`). Faults if `cs` was destroyed, or if a component on the way never had
-- `clickthrough` set (the client's default is unprobed).
---@param cs table component state
---@param x number?
---@param y number?
---@return table? hit
---@return string? why
function Driver:reach(cs, x, y)
    if x == nil or y == nil then
        x, y = centre(cs)
    end
    local ok, why = self:lands(cs, x, y)
    if not ok then return nil, why end
    local c, hit = cs, nil
    while c.parent and not hit do
        if c.clickthrough == nil then
            strict.fault(
                "prettyui: "
                    .. c.class
                    .. " never had clickthrough set, and the client's default is unprobed"
            )
        end
        if not c.clickthrough then hit = c end
        c = c.parent
    end
    if not hit then return nil, "clickthrough: nothing under the pointer takes the click" end
    local top = self:topAt(x, y, hit)
    if top ~= hit then
        return nil, "covered: a " .. assert(top).class .. " drawn over it takes the pointer"
    end
    return hit
end

-- The point (x, y), in plugin-layer coordinates, in `hit`'s own coordinates as it sits now
-- (the pointer hooks' x, y).
---@param hit table
---@param x number
---@param y number
---@return integer x
---@return integer y
local function localPoint(hit, x, y)
    local hx, hy = ui.drawnPos(hit)
    return math.floor(x - hx), math.floor(y - hy)
end

-- Click a component the plugin made (or a window's content): the component that takes it
-- (see `reach`) gets ONCLICK and then ONRELEASE, both with the press point in its own
-- coordinates. A plugin acts on ONCLICK: a quick click can arrive release first in the client,
-- the order the fake doesn't reproduce (docs/api-concepts.md, "Pointer hooks on a plain `ui.Layer`").
---@param cs table
---@return boolean
---@return string?
function Driver:clickComponent(cs)
    local hit, why = self:reach(cs)
    if not hit then return false, why end
    local x, y = localPoint(hit, centre(cs))
    runtime.call(self.h.budgetMs, "component click", function()
        ui.fire(hit, ui.Hook.ONCLICK, x, y)
        ui.fire(hit, ui.Hook.ONRELEASE, x, y)
    end)
    return true
end

-- Press the mouse button on a component the plugin made (or a window's content) at (x, y) in
-- plugin-layer coordinates (default: its centre), and hold it. The component that takes it
-- (see `reach`) gets ONCLICK with the point in its own coordinates, and is the pressed layer
-- until the press ends. In the client the first ONHOLD comes on the same tick as ONCLICK
-- (docs/api-concepts.md, "Pointer hooks on a plain `ui.Layer`"); here it comes with the first
-- `moveTo`, so a spec can look at the plugin's UI between the two. Returns true, or false and why it didn't land (the reasons `click` gives).
---@param target any
---@param x number?
---@param y number?
---@return boolean
---@return string?
function Driver:press(target, x, y)
    assert(self.pressing == nil, "h.ui:press: a press is already held; release it first")
    local cs = ui.stateOf(target)
    assert(isRaw(cs), "h.ui:press needs a component the plugin made, or a window's content")
    assert(cs, "unreachable")
    if cs.destroyed then strict.fault("prettyui: pressed a component used after Destroy()") end
    if x == nil or y == nil then
        x, y = centre(cs)
    end
    local hit, why = self:reach(cs, x, y)
    if not hit then return false, why end
    self.pressing = { s = hit, x = x, y = y }
    local lx, ly = localPoint(hit, x, y)
    runtime.call(self.h.budgetMs, "component press", ui.fire, hit, ui.Hook.ONCLICK, lx, ly)
    return true
end

-- The held press, after checking its layer is still on show. What the client sends a pressed
-- layer that is hidden or destroyed mid-press is unprobed, so that faults.
---@param self table the driver
---@return table? # { s, x, y }, or nil when no press is held
local function heldPress(self)
    local p = self.pressing
    if p and not ui.visible(p.s) then
        strict.fault(
            "prettyui: the pressed layer was hidden or destroyed mid-press, and what the "
                .. "client sends it then is unprobed"
        )
    end
    return p
end

-- Move the held pointer to (x, y) in plugin-layer coordinates: one Logic tick of the press.
-- While the point is inside the pressed layer's rect clipped by every ancestor's, the layer
-- gets ONHOLD with the point in its own coordinates as it sits now (so after a layer moves,
-- the next ONHOLD is relative to its new place). Once the point leaves that area the press
-- ends there: ONRELEASE with the point, and false. The client fires ONHOLD every tick even
-- with the mouse still: moveTo the same point for that. The clock doesn't move: call
-- h:advance(20) between moves when the plugin's Logic matters (ONHOLD's order against Logic
-- within a tick is unprobed). Returns true, or false and why (no press held, or released).
---@param x number
---@param y number
---@return boolean
---@return string?
function Driver:moveTo(x, y)
    assert(type(x) == "number" and type(y) == "number", "h.ui:moveTo(x, y) needs numbers")
    local p = heldPress(self)
    if not p then return false, "no press held" end
    p.x, p.y = x, y
    local lx, ly = localPoint(p.s, x, y)
    if ui.clipper(p.s, x, y) then
        self.pressing = nil
        runtime.call(self.h.budgetMs, "component release", ui.fire, p.s, ui.Hook.ONRELEASE, lx, ly)
        return false, "released: the pointer left the pressed layer's hit area"
    end
    runtime.call(self.h.budgetMs, "component hold", ui.fire, p.s, ui.Hook.ONHOLD, lx, ly)
    return true
end

-- Let go of the mouse button: the pressed layer gets ONRELEASE with the pointer's last point
-- in its own coordinates. Returns true, or false and why when no press is held (none was made,
-- or a `moveTo` already ended it).
---@return boolean
---@return string?
function Driver:release()
    local p = heldPress(self)
    if not p then return false, "no press held" end
    self.pressing = nil
    local lx, ly = localPoint(p.s, p.x, p.y)
    runtime.call(self.h.budgetMs, "component release", ui.fire, p.s, ui.Hook.ONRELEASE, lx, ly)
    return true
end

-- Turn the mouse wheel by `delta` over a component the plugin made (or a window's content):
-- only the component that takes the pointer (see `reach`) gets ONSCROLLWHEEL(component, delta),
-- so one with no wheel listener swallows it and the window doesn't scroll. Returns true and
-- how many listeners ran (0: swallowed), or false and why it didn't land.
---@param target any
---@param delta number
---@return boolean
---@return string|integer
function Driver:wheel(target, delta)
    local cs = ui.stateOf(target)
    assert(isRaw(cs), "h.ui:wheel needs a component the plugin made, or a window's content")
    assert(cs, "unreachable")
    local hit, why = self:reach(cs)
    if not hit then return false, why or "did not land" end
    local ran =
        runtime.call(self.h.budgetMs, "mouse wheel", ui.fire, hit, ui.Hook.ONSCROLLWHEEL, delta)
    return true, ran
end

-- Click a SpriteButton (its action gets (button, true)), a Window's closeButton (Close), or
-- one choice of a CheckboxButton (toggles it; onChange fires), or a component the plugin made
-- (ONCLICK, ONRELEASE; see `clickComponent`). Returns false and the reason when the click
-- wouldn't reach it (hidden, under a drag layer, a disabled choice, clipped, clickthrough);
-- faults if the target was destroyed.
---@param target any
---@param value any the choice's value, for a CheckboxButton
---@return boolean
---@return string?
function Driver:click(target, value)
    local lib = self:lib()
    local h = self.h
    local cs = ui.stateOf(target)
    if cs and lib.closeButtons[cs] then
        local ok, why = self:lands(cs)
        if not ok then return false, why end
        local ws = lib.closeButtons[cs]
        runtime.call(h.budgetMs, "PrettyUI close button", windowClose, ws)
        return true
    end
    if isRaw(cs) then
        assert(cs, "unreachable")
        return self:clickComponent(cs)
    end
    local r = self:record(target)
    if r.kind == "SpriteButton" then
        local ok, why = self:lands(r.s.rootState)
        if not ok then return false, why end
        if r.s.action then
            runtime.call(h.budgetMs, "SpriteButton action", r.s.action, r.obj, true)
        end
        return true
    elseif r.kind == "CheckboxButton" then
        for _, item in ipairs(r.s.items) do
            if item.value == value then
                local ok, why = self:lands(item.rowState)
                if not ok then return false, why end
                if item.disabled then return false, "disabled choice" end
                runtime.call(h.budgetMs, "CheckboxButton click", function()
                    r.obj:SetSelected(value, not item.selected)
                end)
                return true
            end
        end
        error("no checkbox choice with value " .. tostring(value), 2)
    end
    error("can't click a " .. r.kind, 2)
end

-- 1.2.0's ONCLICK on the title bar (src/window.lua, titleDrag): the root to the front, then
-- the title-bar drag layer over it.
---@param s table
local function pressTitle(s)
    s.root:MoveToFront()
    s.titleDrag:MoveToFront()
end

-- The title bar of a shown, titled Window's record state.
---@param self table
---@param win table
---@return table
local function titled(self, win)
    local s = self:record(win, "Window").s
    assert(s.title, "only a titled Window has a title bar")
    assert(ui.visible(s.rootState), "the window is hidden")
    return s
end

-- Press a titled Window's title bar, drag it by (dx, dy) and let go, all in one step: it stays
-- inside its parent. The press raises the root and then the title-bar drag layer, and the
-- release syncs the overlays (1.2.0's stopDrag), both before the next Logic tick.
---@param win table
---@param dx number
---@param dy number
function Driver:dragTitle(win, dx, dy)
    local s = titled(self, win)
    pressTitle(s)
    local root = s.rootState
    local x, y = ui.pos(root)
    local nx = clamp(x + dx, 0, ui.width(root.parent) - ui.width(root))
    local ny = clamp(y + dy, 0, ui.height(root.parent) - ui.height(root))
    if nx ~= x or ny ~= y then
        s.root:SetPos(nx, ny)
        remember(s)
    end
    stopTitleDrag(s)
end

-- A quick click on a titled Window's title bar: press and release in one tick, which the
-- client delivers backwards (ONRELEASE, then ONCLICK; docs/api-concepts.md, "Pointer hooks on
-- a plain `ui.Layer`"). So the overlays sync first and then the root and title-bar drag layer
-- are raised over them, both before the next Logic tick.
---@param win table
function Driver:clickTitle(win)
    local s = titled(self, win)
    stopTitleDrag(s)
    pressTitle(s)
end

-- Drag a resizable Window's bottom-right corner by (dw, dh): clamped to its min/max and to
-- the parent's edge. The press ends any title-bar press and shows the window (1.2.0's
-- Resize onBegin, src/window.lua), which raises its root; each move sets its size, which
-- syncs the overlays. With `held`, it is a further move of a resize already pressed (one per
-- Logic tick a held press gets, with `h:advance(20)` between): no press, so no Show.
---@param win table
---@param dw number
---@param dh number
---@param held boolean?
function Driver:resize(win, dw, dh, held)
    local s = self:record(win, "Window").s
    assert(s.resizable, "the window isn't resizable")
    assert(ui.visible(s.rootState), "the window is hidden")
    if not held then
        stopTitleDrag(s)
        windowShow(s)
    end
    local root = s.rootState
    local function axis(pos, size, delta, extent, minimum, maximum)
        local limit = math.max(minimum, math.min(maximum or math.huge, extent))
        pos = clamp(pos, 0, extent - minimum)
        return pos, clamp(size + delta, minimum, math.max(minimum, math.min(limit, extent - pos)))
    end
    local x, y = ui.pos(root)
    local nx, w = axis(x, ui.width(root), dw, ui.width(root.parent), s.minWidth, s.maxWidth)
    local ny, hgt = axis(y, ui.height(root), dh, ui.height(root.parent), s.minHeight, s.maxHeight)
    s.root:SetPos(nx, ny)
    windowSetSize(s, w, hgt)
end

-- What a hover target is: the component the pointer is over, and a function giving its
-- current tooltip (SetTooltip / SetOptionTooltip can replace it). `value` picks a
-- CheckboxButton's choice.
---@param target any
---@param value any
---@return table component state
---@return fun(): table?
function Driver:hoverTarget(target, value)
    local r = self:lib().byObj[target]
    local cs = ui.stateOf(target)
    if r == nil and cs then
        return cs, function() end
    end -- a plain component: no tooltip
    r = self:record(target)
    if r.kind == "CheckboxButton" then
        for _, item in ipairs(r.s.items) do
            if item.value == value then
                return item.rowState,
                    function()
                        return item.tip
                    end
            end
        end
        error("no checkbox choice with value " .. tostring(value), 3)
    end
    local s = r.s
    return s.rootState or s, function()
        return s.tip
    end
end

-- Move the pointer onto `target` (a choice of a CheckboxButton by `value`). The previous
-- target gets its mouse-leave first, and this one its mouse-over, which shows its tooltip.
-- Returns false, and leaves the pointer where it was, if the target is hidden.
---@param target any
---@param value any
---@return boolean
---@return string?
function Driver:hover(target, value)
    local raw = ui.stateOf(target)
    if isRaw(raw) then
        assert(raw, "unreachable")
        return self:hoverComponent(raw)
    end
    local cs, tipOf = self:hoverTarget(target, value)
    if cs.destroyed then strict.fault("prettyui: hovered a component used after Destroy()") end
    -- Same check as a click, so the two agree on what is hidden, clipped or covered.
    local ok, why = self:lands(cs)
    if not ok then return false, why end
    self:leave()
    self.hovering = { cs = cs, tipOf = tipOf }
    local tip = tipOf()
    if tip then tip.shown = true end
    return true
end

-- Move the pointer onto a component the plugin made (or a window's content): the component
-- that takes it (see `reach`) gets ONMOUSEOVER(component, x, y), reads isMouseOver true and
-- shows its Tooltip.attach tooltip. Moving between a component and its clickthrough
-- children stays on the same component: no events. Returns false and why, leaving the pointer
-- where it was, if it doesn't land.
---@param cs table component state
---@return boolean
---@return string?
function Driver:hoverComponent(cs)
    if cs.destroyed then strict.fault("prettyui: hovered a component used after Destroy()") end
    local hit, why = self:reach(cs)
    if not hit then return false, why end
    if self.hovering and self.hovering.cs == hit then return true end
    self:leave()
    local lib = self:lib()
    local function tipOf()
        local tip = lib.rawTips[hit]
        return tip and not tip.destroyed and tip or nil
    end
    self.hovering = { cs = hit, tipOf = tipOf, raw = true }
    hit.mouseOver = true
    local tip = tipOf()
    if tip then tip.shown = true end
    local x, y = localPoint(hit, centre(cs))
    runtime.call(self.h.budgetMs, "component mouse-over", ui.fire, hit, ui.Hook.ONMOUSEOVER, x, y)
    return true
end

-- Move the pointer off whatever it is over. A target hidden (or destroyed) since it was
-- hovered gets no mouse-leave, so its tooltip stays shown: the stuck tooltips seen in the
-- client (docs/api-concepts.md, PrettyUI in the client). A component the plugin made reads
-- isMouseOver false either way, and otherwise gets ONMOUSELEAVE(component).
function Driver:leave()
    local hovering = self.hovering
    self.hovering = nil
    if hovering == nil then return end
    if hovering.raw and not hovering.cs.destroyed then hovering.cs.mouseOver = false end
    if not ui.visible(hovering.cs) then return end
    local tip = hovering.tipOf()
    if tip then tip.shown = false end
    if hovering.raw then
        runtime.call(
            self.h.budgetMs,
            "component mouse-leave",
            ui.fire,
            hovering.cs,
            ui.Hook.ONMOUSELEAVE
        )
    end
end

-- The text of every tooltip on screen: shown, not destroyed, and drawn in a visible component.
---@return string[]
function Driver:tooltips()
    local out = {}
    for _, tip in ipairs(self:lib().tooltips) do
        if tip.shown and not tip.destroyed and ui.visible(tip.parent) then
            out[#out + 1] = tip.text
        end
    end
    return out
end

-- Hold or release Alt, as PrettyUI sees it (Keyboard available, not blocked, Alt down: in the
-- client the console being open blocks the keyboard).
---@param held boolean
function Driver:holdAlt(held)
    self.altHeld = held == true
end

-- Alt-drag a standalone Panel by (dx, dy), clamped inside its parent. Returns false, leaving
-- it where it is, unless Alt is held.
---@param panel table
---@param dx number
---@param dy number
---@return boolean
function Driver:altDrag(panel, dx, dy)
    local s = self:record(panel, "Panel").s
    if not self.altHeld then return false end
    assert(ui.visible(s.rootState), "the panel is hidden")
    local root = s.rootState
    local x, y = ui.pos(root)
    local nx = clamp(x + dx, 0, ui.width(root.parent) - ui.width(root))
    local ny = clamp(y + dy, 0, ui.height(root.parent) - ui.height(root))
    s.root:SetPos(nx, ny)
    remember(s)
    return true
end

-- A component's (or a PrettyUI object's root's) layout as plain data:
-- { x, y, width, height, hidden, globalX, globalY, visible }. globalX, globalY are where it is
-- drawn, a window's scroll included, which its xyGlobal leaves out (as in the client).
---@param target any
---@return table
function Driver:layout(target)
    local cs = ui.stateOf(target)
    if not cs then
        local r = self:record(target)
        cs = assert(r.s.rootState or ui.stateOf(r.obj), "no root: destroyed?")
    end
    local x, y = ui.pos(cs)
    local gx, gy = ui.drawnPos(cs)
    return {
        x = x,
        y = y,
        width = ui.width(cs),
        height = ui.height(cs),
        hidden = cs.hidden,
        globalX = gx,
        globalY = gy,
        visible = ui.visible(cs),
    }
end

return M
