-- A settings line that sets a number: a name at the left, cut with "..." to stop short of the
-- buttons, and "[-] N of M [+]" at the right edge (the How many to do block: how many of a
-- chore's parts tick it), with a tooltip over the name saying what the number counts. PrettyUI 1.2.0's SpriteButton has a PLUS sprite but no minus
-- (tests/harness/api/prettyui/internal.lua), so both buttons are hand-built as a matched pair.
-- The texts sit straight in the content, not in a layer, so the line is never taken for a
-- chore row; the tooltip hangs on an empty layer under the name.

local listlayout = require("core/listlayout")
local rows = require("shell/rows")

local M = {}

-- Pixel sizes: each button, and the field between them that centres the value. The line is
-- a chore row's height, inset from the content's sides by PrettyUI 1.2.0's flow padding.
local PADDING = listlayout.FLOW_PADDING
local ROW_HEIGHT = listlayout.ROW_HEIGHT
local BUTTON_SIZE = 20
local VALUE_WIDTH = 64
local STEPPER_WIDTH = BUTTON_SIZE + VALUE_WIDTH + BUTTON_SIZE
-- The content width that is not the name's: both side paddings, the stepper and a gap.
local NAME_INSET = PADDING * 2 + STEPPER_WIDTH + rows.LABEL_GAP

-- The client's own RS3 minus and plus pair, picked from the sprite list
-- (docs/api/consts/Sprite.lua); seen drawing in the client (docs/api-concepts.md).
local MINUS_SPRITE = id.Sprite.RS3_CONTEXTUAL_INPUT_MINUS
local PLUS_SPRITE = id.Sprite.RS3_CONTEXTUAL_INPUT_PLUS

---@class ChoreStepperView
---@field content ui.Layer
---@field label ui.Text
---@field name string the full name, which the label shows cut to fit
---@field nameWidth number? the width the name was last fitted to
---@field value ui.Text

-- A button at `x` from the content's right edge (negative: leftwards) on the line at `y`,
-- showing `sprite`, that runs `onClick` on a press. ONCLICK, as for the rows: a quick click
-- can arrive release-first in the client (docs/api-concepts.md).
---@param content ui.Layer
---@param x integer
---@param y integer
---@param sprite integer an id.Sprite member
---@param onClick fun()
---@param wheel ChoreWheelHandler?
local function newButton(content, x, y, sprite, onClick, wheel)
    local layer = ui.Layer.new(content)
    layer:SetPos(x, y + (ROW_HEIGHT - BUTTON_SIZE) // 2, 1.0, 0)
    layer:SetSize(BUTTON_SIZE, BUTTON_SIZE)
    layer.clickthrough = false
    rows.setCursor(layer, rows.ROW_CURSOR)
    layer:Subscribe(ui.Hook.ONCLICK, function()
        onClick()
    end)
    -- The button would otherwise swallow the wheel over it.
    if wheel then layer:Subscribe(ui.Hook.ONSCROLLWHEEL, wheel) end
    local icon = ui.Sprite.new(layer)
    icon:SetSize(BUTTON_SIZE, BUTTON_SIZE)
    icon.clickthrough = true
    icon.spriteID = sprite
end

-- Show the name cut to the room left of the minus button, which ui.Text can't clip. Does
-- nothing when that room hasn't changed since the last fit, so it is cheap to call on each
-- poll; until the content has a width the full name shows.
---@param stepper ChoreStepperView
function M.fit(stepper)
    local width = stepper.content.width
    if width <= 0 then return end
    local avail = width - NAME_INSET
    if avail == stepper.nameWidth then return end
    stepper.nameWidth = avail
    stepper.label.content = (rows.fitText(stepper.name, avail))
end

-- Make a line at content height `y` under `content`: `name`, then the stepper showing
-- `valueText`. `onStep` gets -1 or +1 on a click of the minus or plus button, and this line;
-- the caller decides what that changes and calls M.show with the result. `tooltip` shows over
-- the name. `wheel`, when given, takes the mouse wheel over the name and the buttons.
---@param content ui.Layer
---@param y integer
---@param name string
---@param valueText string
---@param onStep fun(delta: integer, stepper: ChoreStepperView)
---@param tooltip ChoreTooltip
---@param wheel ChoreWheelHandler?
---@return ChoreStepperView
function M.new(content, y, name, valueText, onStep, tooltip, wheel)
    -- Under the name, taking the mouse for the tooltip; made first, so the text draws over it.
    local hover = ui.Layer.new(content)
    hover:SetPos(PADDING, y)
    hover:SetSize(-NAME_INSET, ROW_HEIGHT, 1.0, 0)
    hover.clickthrough = false
    if wheel then hover:Subscribe(ui.Hook.ONSCROLLWHEEL, wheel) end
    prettyui.Tooltip.attach(hover, content, tooltip)

    local label = rows.newText(content)
    label:SetPos(PADDING, y)
    label:SetSize(-NAME_INSET, ROW_HEIGHT, 1.0, 0)
    label.content = name

    local right = -(PADDING + STEPPER_WIDTH)
    local value = rows.newText(content)
    value:AlignTo(ui.AlignMode.CENTRE, ui.AlignMode.CENTRE)
    value:SetPos(right + BUTTON_SIZE, y, 1.0, 0)
    value:SetSize(VALUE_WIDTH, ROW_HEIGHT)

    ---@type ChoreStepperView
    local stepper = { content = content, label = label, name = name, value = value }
    newButton(content, right, y, MINUS_SPRITE, function()
        onStep(-1, stepper)
    end, wheel)
    newButton(content, -(PADDING + BUTTON_SIZE), y, PLUS_SPRITE, function()
        onStep(1, stepper)
    end, wheel)
    M.show(stepper, valueText)
    M.fit(stepper)
    return stepper
end

-- Show `valueText` as the stepper's value.
---@param stepper ChoreStepperView
---@param valueText string
function M.show(stepper, valueText)
    stepper.value.content = valueText
end

return M
