-- One chore's row in the list or settings view, hand-built from plain components inside the
-- window's content: the chore's icon at the left, its text, and a tick box at the right edge.
-- A list row also has a drag grip left of the icon (shell/grips.lua takes the presses on it).
-- The row layer takes the clicks; the icon, text and box let them through to it. While the
-- mouse is over the row it shows the hyperlink hand, and its box shows a hovered sprite. A
-- row is changed in place (colour, dimming, tick, text, tooltip) and goes when its window is
-- destroyed. A name too long for its row is cut short with "..." (ui.Text can't
-- clip), and its tooltip then leads with the full text.
-- PrettyUI 1.2.0's CheckboxButton can neither show an icon nor be recoloured or retexted, so
-- neither view uses it for chore rows.

local fit = require("core/fit")
local listlayout = require("core/listlayout")

local M = {}

-- Pixel sizes: the row, its icon and tick box, and where the text starts (6 px after the
-- icon). The row is inset from the content's sides by PrettyUI 1.2.0's flow padding, like its
-- own rows.
local PADDING = listlayout.FLOW_PADDING
local ROW_HEIGHT = listlayout.ROW_HEIGHT
local ICON_SIZE = 24
local BOX_SIZE = 16
local TEXT_X = ICON_SIZE + 6
-- A list row's grip: 16 px, at the row's left edge, centred vertically, with 4 px before the
-- icon. Shared with shell/grips.lua, which docks a press target over it.
M.GRIP_SIZE = 16
M.GRIP_Y = (ROW_HEIGHT - M.GRIP_SIZE) // 2
local GRIP_WIDTH = M.GRIP_SIZE + 4
-- Space kept between the end of a label and the tick box.
local LABEL_GAP = 6

-- Text colours (0xRRGGBBAA): PrettyUI 1.2.0's default text colour, and a dimmed one for done
-- rows. A done row's icon is drawn at half opacity.
local TEXT_COLOUR = 0xE7D7B0FF
local DONE_COLOUR = 0x7A7262FF
local DONE_ALPHA = 0.5

-- The box's sprite by state. This is the full RS3_BTN_CHECKBOX set rather than the SMALL one
-- PrettyUI 1.2.0 uses: the SMALL set has no ticked-and-hovered sprite, RS3_BTN_CHECKBOX_3 is one.
local BOX_EMPTY = id.Sprite.RS3_BTN_CHECKBOX_0
local BOX_EMPTY_HOVERED = id.Sprite.RS3_BTN_CHECKBOX_1
local BOX_TICKED = id.Sprite.RS3_BTN_CHECKBOX_2
local BOX_TICKED_HOVERED = id.Sprite.RS3_BTN_CHECKBOX_3
-- The grip's sprite, the user's pick from a sprite probe (docs/api-concepts.md).
local GRIP_SPRITE = id.Sprite.HAMBURGER_MENU_ICON

-- The cursor over a row. The user chose it among eight in a probe (docs/api-concepts.md).
local ROW_CURSOR = id.Cursor.CURSOR_HYPERLINK_HAND

local FONT_NAME = "MUSEO_SANS_15PT_REGULAR"

local say = nil ---@type fun(...)?
-- Whether a failed measurement has been reported (once per load).
local measureReported = false
-- Icon names already reported missing, so each is logged once per load.
local reported = {} ---@type table<string, boolean>

-- PrettyUI 1.2.0's window wheel handler (types/prettyui.lua, Window._onScrollWheel).
---@alias ChoreWheelHandler fun(component: ui.Component, delta: number): boolean

---@class ChoreRowView
---@field layer ui.Layer
---@field icon ui.Sprite? nil when the icon's name didn't resolve
---@field label ui.Text
---@field box ui.Sprite
---@field textX integer where the label starts in the row
---@field text string? the row's full text
---@field availWidth integer? the label width `text` was last fitted to
---@field shortened boolean whether the label shows less than `text`
---@field content ui.Layer? the layer that owns the tooltip, once it has one
---@field baseTooltip { text: string, maxWidth: integer }? the tooltip as given to setTooltip
---@field ticked boolean? whether the box is ticked
---@field dimmed boolean? whether the icon and text are dimmed
---@field hovered boolean whether the mouse is over the row
---@field tooltipText string?
---@field tooltip prettyui.TooltipAttachment?

-- Where log lines go. Call once at load.
---@param opts { say: fun(...) }
function M.init(opts)
    say, reported, measureReported = opts.say, {}, false
end

-- The id behind an icon's constant name, or nil when this client has no such name (a game
-- update renamed it, say), which is logged once.
---@param icon ChoreIcon
---@return integer?
local function resolve(icon)
    assert(say, "rows.init sets say first")
    local domain, name = icon.obj and "Obj" or "Sprite", icon.obj or icon.sprite
    -- Whether the client gives nil or raises for a name it lacks is unprobed: handle both.
    local ok, found = pcall(function()
        return id[domain][name]
    end)
    if ok and type(found) == "number" then return found end
    local key = domain .. "." .. tostring(name)
    if not reported[key] then
        reported[key] = true
        say("unknown icon id." .. key .. "; its rows show no icon")
    end
    return nil
end

-- Show the box for the row's tick and hover state.
---@param row ChoreRowView
local function drawBox(row)
    if row.ticked == nil then return end
    if row.ticked then
        row.box.spriteID = row.hovered and BOX_TICKED_HOVERED or BOX_TICKED
    else
        row.box.spriteID = row.hovered and BOX_EMPTY_HOVERED or BOX_EMPTY
    end
end

-- Clear the row's hover. For a row about to be hidden, whose mouse-leave the client won't send.
---@param row ChoreRowView
function M.unhover(row)
    row.hovered = false
    drawBox(row)
end

-- Show `cursor` while the mouse is over `layer`. Both settings are made: whether
-- mouseOverCursor alone is enough is unsettled (docs/api-concepts.md).
---@param layer ui.Layer
---@param cursor integer an id.Cursor member
function M.setCursor(layer, cursor)
    layer.cursorConfig.mouseOverCursor = cursor
    layer.opConfig:SetOpCursor(0, cursor)
end

-- Make a row at content height `y` under `content`, showing `icon` (nothing if its name doesn't
-- resolve). `onClick` runs on a press anywhere on the row: on ONCLICK, since a quick click can
-- arrive release-first in the client (docs/api-concepts.md, "Pointer hooks on a plain
-- `ui.Layer`"). `opts.wheel`, when given, takes the mouse wheel over the row, which the row
-- would otherwise swallow. With `opts.grip`, the row gets a drag grip at its left and the rest
-- moves right to make room. Call M.show to give it its text and state.
---@param content ui.Layer
---@param y integer
---@param icon ChoreIcon
---@param onClick fun()
---@param opts { wheel: ChoreWheelHandler?, grip: boolean? }
---@return ChoreRowView
function M.new(content, y, icon, onClick, opts)
    local layer = ui.Layer.new(content)
    layer:SetPos(PADDING, y)
    layer:SetSize(-PADDING * 2, ROW_HEIGHT, 1.0, 0)
    layer.clickthrough = false
    M.setCursor(layer, ROW_CURSOR)
    layer:Subscribe(ui.Hook.ONCLICK, function()
        onClick()
    end)
    if opts.wheel then layer:Subscribe(ui.Hook.ONSCROLLWHEEL, opts.wheel) end

    local left = 0
    if opts.grip then
        local gripSprite = ui.Sprite.new(layer)
        gripSprite:SetPos(0, M.GRIP_Y)
        gripSprite:SetSize(M.GRIP_SIZE, M.GRIP_SIZE)
        gripSprite.clickthrough = true
        gripSprite.spriteID = GRIP_SPRITE
        left = GRIP_WIDTH
    end

    local sprite = nil ---@type ui.Sprite?
    local found = resolve(icon)
    if found then
        sprite = ui.Sprite.new(layer)
        sprite:SetPos(left, (ROW_HEIGHT - ICON_SIZE) // 2)
        sprite:SetSize(ICON_SIZE, ICON_SIZE)
        sprite.clickthrough = true
        if icon.obj then
            sprite:SetAssociatedObject(found)
        else
            sprite.spriteID = found
        end
    end

    -- At the same x whether or not there is an icon, so the names line up.
    local textX = left + TEXT_X
    local label = ui.Text.new(layer)
    label:SetPos(textX, 0)
    label:SetSize(-(textX + BOX_SIZE + LABEL_GAP), ROW_HEIGHT, 1.0, 0)
    label.font = id.Font.MUSEO_SANS_15PT_REGULAR
    label:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)
    label.clickthrough = true

    local box = ui.Sprite.new(layer)
    box:SetPos(-BOX_SIZE, (ROW_HEIGHT - BOX_SIZE) // 2, 1.0, 0)
    box:SetSize(BOX_SIZE, BOX_SIZE)
    box.clickthrough = true

    local row = ---@type ChoreRowView
        {
            layer = layer,
            icon = sprite,
            label = label,
            box = box,
            textX = textX,
            shortened = false,
            hovered = false,
        }
    -- Under the default id: Tooltip.attach subscribes the same hooks under its own id
    -- (PrettyUI 1.2.0, src/tooltip.lua), so the two don't replace each other.
    layer:Subscribe(ui.Hook.ONMOUSEOVER, function()
        row.hovered = true
        drawBox(row)
    end)
    layer:Subscribe(ui.Hook.ONMOUSELEAVE, function()
        M.unhover(row)
    end)
    return row
end

-- The client font's pixel width of `text`, tags parsed (ignoreTags false: only the text
-- between them counts, as measured in the beta client). Raises when the font can't measure.
---@param text string
---@return number
local function measure(text)
    local width = config.Font[FONT_NAME]:GetStringWidth(text, false)
    assert(type(width) == "number", "GetStringWidth gave " .. type(width))
    return width
end

-- The tooltip the row should hold: the given one, led by the full text when the label is cut.
---@param row ChoreRowView
---@return { text: string, maxWidth: integer }
local function tooltipOf(row)
    assert(row.baseTooltip, "tooltipOf is only asked once a tooltip was given")
    if not row.shortened then return row.baseTooltip end
    return {
        text = row.text .. "<br>" .. row.baseTooltip.text,
        maxWidth = row.baseTooltip.maxWidth,
    }
end

-- Put the row's tooltip in place. A changed one replaces the old attachment, whose Destroy
-- also takes it down if it is showing (PrettyUI 1.2.0, src/tooltip.lua), so no tooltip stays
-- up with old text.
---@param row ChoreRowView
local function applyTooltip(row)
    if not (row.content and row.baseTooltip) then return end
    local tooltip = tooltipOf(row)
    if row.tooltipText == tooltip.text then return end
    if row.tooltip then row.tooltip:Destroy() end
    row.tooltip = prettyui.Tooltip.attach(row.layer, row.content, tooltip)
    row.tooltipText = tooltip.text
end

-- Show the row's text cut to the label's width, leaving the tooltip to the caller. Does
-- nothing when that width hasn't changed since the text was last fitted, so it is cheap to
-- call for every row. Until the row has a width the full text shows, and the next call tries
-- again; once it has one, a width with no room for any of the text gives just "...". A font
-- that can't measure leaves the full text, logged once.
---@param row ChoreRowView
local function fitLabel(row)
    assert(say, "rows.init sets say first")
    local text = row.text
    assert(text, "a row is fitted after show gave it text")
    if row.layer.width <= 0 then return end
    local avail = row.layer.width - row.textX - BOX_SIZE - LABEL_GAP
    if avail == row.availWidth then return end
    local ok, shown, shortened = pcall(fit.fit, text, avail, measure)
    if not ok then
        if not measureReported then
            measureReported = true
            say("cannot measure text with the client font; names stay unshortened: " .. shown)
        end
        shown, shortened = text, false
    end
    row.availWidth = avail
    row.label.content = shown
    row.shortened = shortened
end

-- Re-fit the row's label to its current width (a resize), and its tooltip when the label
-- went from whole to cut or back. Same cost and width rules as fitLabel.
---@param row ChoreRowView
function M.fit(row)
    local was = row.shortened
    fitLabel(row)
    if row.shortened ~= was then applyTooltip(row) end
end

-- Show `text` and the row's state: `ticked` fills the box, `dimmed` mutes the icon and text.
-- Only what changed is touched. The tooltip is left to setTooltip, which the caller runs
-- next, so one refresh replaces it once.
---@param row ChoreRowView
---@param text string
---@param ticked boolean
---@param dimmed boolean
local function apply(row, text, ticked, dimmed)
    if row.text ~= text then
        row.text = text
        -- Shown whole first, so a width that is still unknown leaves the full text.
        row.label.content = text
        row.shortened, row.availWidth = false, nil
        fitLabel(row)
    end
    if row.dimmed ~= dimmed then
        row.dimmed = dimmed
        row.label.rgba = dimmed and DONE_COLOUR or TEXT_COLOUR
        if row.icon then row.icon.alpha = dimmed and DONE_ALPHA or 1 end
    end
    if row.ticked ~= ticked then
        row.ticked = ticked
        drawBox(row)
    end
end

-- List view: show `text`, and the row as done (dimmed icon, muted text, ticked box) or not.
---@param row ChoreRowView
---@param text string
---@param done boolean
function M.show(row, text, done)
    apply(row, text, done, done)
end

-- Settings view: show `text`, and the box ticked when the chore is picked. Never dimmed.
---@param row ChoreRowView
---@param text string
---@param picked boolean
function M.showPick(row, text, picked)
    apply(row, text, picked, false)
end

-- Give the row `tooltip`, drawn by the window that owns `content` (so destroying the window
-- destroys it). While the label is cut short the tooltip leads with the full text.
---@param row ChoreRowView
---@param content ui.Layer
---@param tooltip { text: string, maxWidth: integer }
function M.setTooltip(row, content, tooltip)
    row.content, row.baseTooltip = content, tooltip
    applyTooltip(row)
end

return M
