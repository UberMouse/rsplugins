-- The PrettyUI fake's library objects: tooltips, SpriteButton, Divider, CheckboxButton and the
-- window-content builders (AddSpriteButton/AddText/AddCheckboxButton/AddDivider). A separate
-- file because windows and panels only use them (window.lua requires this one, never the
-- reverse), and the popup builds on libraryObject. Part of the library, not the driver.

local strict = require("tests.harness.strict")
local ui = require("tests.harness.api.ui")
local internal = require("tests.harness.api.prettyui.internal")

local PADDING = internal.PADDING
local ROW_GAP = internal.ROW_GAP
local TEXT_HEIGHT = internal.TEXT_HEIGHT
local TEXT_GAP = internal.TEXT_GAP
local LINE_HEIGHT = internal.LINE_HEIGHT
local TITLE_HEIGHT_ROW = internal.TITLE_HEIGHT_ROW
local TITLE_GAP = internal.TITLE_GAP
local TITLE_MARGIN = internal.TITLE_MARGIN
local CHECKBOX_ROW = internal.CHECKBOX_ROW
local DIVIDER_HEIGHT = internal.DIVIDER_HEIGHT
local SPRITE_BUTTON_SIZE = internal.SPRITE_BUTTON_SIZE
local SPRITE_NAMES = internal.SPRITE_NAMES
local checkOptions = internal.checkOptions
local parentState = internal.parentState
local live = internal.live
local flowRow = internal.flowRow
local grow = internal.grow
local gone = internal.gone
local track = internal.track

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

-- The hook id Tooltip.attach subscribes its target's mouse-over and mouse-leave under (1.2.0,
-- src/tooltip.lua).
local TOOLTIP_HOOK_ID = "prettyui_tooltip"

-- Destroy on an attachment from Tooltip.attach: gives the target's clickthrough back and
-- drops its listeners, as 1.2.0 does, and leaves its window's context. Calling it again does
-- nothing.
---@param tip table
local function destroyAttachment(tip)
    if tip.destroyed then return end
    destroyTip(tip)
    tip.shown = false
    local lib = tip.lib
    if lib.rawTips[tip.target] == tip then lib.rawTips[tip.target] = nil end
    if not tip.target.destroyed then
        tip.target.clickthrough = tip.priorClickthrough
        ui.removeListener(tip.target, ui.Hook.ONMOUSEOVER, TOOLTIP_HOOK_ID)
        ui.removeListener(tip.target, ui.Hook.ONMOUSELEAVE, TOOLTIP_HOOK_ID)
    end
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
    -- Shown and hidden by listeners under 1.2.0's own id, so a listener before them that
    -- stops the rest (ui.fire) keeps the tooltip from showing, as in the client.
    ui.addListener(ts, ui.Hook.ONMOUSEOVER, TOOLTIP_HOOK_ID, function()
        tip.shown = true
        return true
    end)
    ui.addListener(ts, ui.Hook.ONMOUSELEAVE, TOOLTIP_HOOK_ID, function()
        tip.shown = false
        return true
    end)
    lib.rawTips[ts] = tip
    return TooltipAttachment.new(tip)
end

-- A library object's class: `def` as for strict.class, plus a `root` field and an idempotent
-- Destroy. Destroy marks the object destroyed, runs `teardown(s)` for what the object owns,
-- then destroys and forgets the root.
---@param name string
---@param def table
---@param teardown fun(s: table)
---@return table class
local function libraryObject(name, def, teardown)
    def.undeclared = true
    def.fields = def.fields or {}
    def.fields.root = "root"
    def.methods = def.methods or {}
    def.methods.Destroy = function(s)
        if s.destroyed then return end
        s.destroyed = true
        teardown(s)
        s.root:Destroy()
        s.root = nil
    end
    return strict.class(name, def)
end

local SpriteButton = libraryObject("prettyui.SpriteButton instance", {
    methods = {
        -- A string changes the text; a table or nil replaces it (hidden), as 1.2.0 does.
        SetTooltip = function(s, value)
            live(s)
            s.tip = replaceTip(s.lib, s.tip, value, s.rootState, s.tipParent, s.context)
            return true
        end,
    },
}, function(s)
    destroyTip(s.tip)
end)

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

local Divider = libraryObject("prettyui.Divider instance", {}, function(s)
    destroyTip(s.tip)
end)

local Checkbox = libraryObject("prettyui.CheckboxButton instance", {
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
    },
}, function(s)
    destroyTip(s.tip)
    for _, item in ipairs(s.items) do
        destroyTip(item.tip)
    end
end)

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

internal.attachTip = attachTip
internal.destroyTip = destroyTip
internal.newContext = newContext
internal.attachRawTooltip = attachRawTooltip
internal.libraryObject = libraryObject
internal.newSpriteButton = newSpriteButton
internal.addSpriteButton = addSpriteButton
internal.addText = addText
internal.addCheckbox = addCheckbox
internal.addDivider = addDivider
