-- A settings line that sets a number: a name at the left, and "[-] N of M [+]" at the right
-- edge, hand-built from plain components inside the window's content (the Shop runs block:
-- how many of a chore's shops tick it). PrettyUI 1.2.0's SpriteButton has a PLUS sprite but
-- no minus (its sprite names, as the test harness's PrettyUI copies them in
-- tests/harness/api/prettyui/internal.lua), so both buttons are built here as a matched pair,
-- like the rows of shell/rows.lua: a layer that takes the click and shows the rows' hand
-- cursor, holding a sprite that lets it through. The texts sit straight in the content rather
-- than in a layer of their own, so the line is never taken for a chore row. The value changes
-- in place; the line goes when its window is destroyed.

local listlayout = require("core/listlayout")
local rows = require("shell/rows")
local view = require("core/view")

local M = {}

-- Pixel sizes: each button, and the field between them that centres the value. The line is
-- a chore row's height, inset from the content's sides by PrettyUI 1.2.0's flow padding.
local PADDING = listlayout.FLOW_PADDING
local ROW_HEIGHT = listlayout.ROW_HEIGHT
local BUTTON_SIZE = 20
local VALUE_WIDTH = 64
local STEPPER_WIDTH = BUTTON_SIZE + VALUE_WIDTH + BUTTON_SIZE

-- The buttons' sprites: the client's own RS3 minus and plus pair, picked by name from the
-- sprite list (docs/api/consts/Sprite.lua); how they draw is not yet seen in the client.
local MINUS_SPRITE = id.Sprite.RS3_CONTEXTUAL_INPUT_MINUS
local PLUS_SPRITE = id.Sprite.RS3_CONTEXTUAL_INPUT_PLUS

---@class ChoreStepperView
---@field value ui.Text
---@field total integer

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

-- Make a line at content height `y` under `content`: `name`, then the stepper showing
-- `needed` of `total`. `onStep` gets -1 or +1 on a click of the minus or plus button; the
-- caller decides what that changes and calls M.show with the result. `wheel`, when given,
-- takes the mouse wheel over the buttons; the texts let it through to the window.
---@param content ui.Layer
---@param y integer
---@param name string
---@param needed integer
---@param total integer
---@param onStep fun(delta: integer)
---@param wheel ChoreWheelHandler?
---@return ChoreStepperView
function M.new(content, y, name, needed, total, onStep, wheel)
    local label = rows.newText(content)
    label:SetPos(PADDING, y)
    label:SetSize(-(PADDING * 2 + STEPPER_WIDTH), ROW_HEIGHT, 1.0, 0)
    label.content = name

    local right = -(PADDING + STEPPER_WIDTH)
    newButton(content, right, y, MINUS_SPRITE, function()
        onStep(-1)
    end, wheel)
    local value = rows.newText(content)
    value:AlignTo(ui.AlignMode.CENTRE, ui.AlignMode.CENTRE)
    value:SetPos(right + BUTTON_SIZE, y, 1.0, 0)
    value:SetSize(VALUE_WIDTH, ROW_HEIGHT)
    newButton(content, -(PADDING + BUTTON_SIZE), y, PLUS_SPRITE, function()
        onStep(1)
    end, wheel)

    local stepper = { value = value, total = total } ---@type ChoreStepperView
    M.show(stepper, needed)
    return stepper
end

-- Show `needed` as the stepper's value.
---@param stepper ChoreStepperView
---@param needed integer
function M.show(stepper, needed)
    stepper.value.content = view.neededText(needed, stepper.total)
end

return M
