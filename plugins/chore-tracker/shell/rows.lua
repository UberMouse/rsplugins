-- One chore's row in the list view, hand-built from plain components inside the window's
-- content: the chore's icon at the left, its text, and a tick box at the right edge. The row
-- layer takes the clicks; the icon, text and box let them through to it. A row is changed in
-- place (colour, dimming, tick, text, tooltip) and goes when its window is destroyed. A name
-- too long for its row is cut short with "..." (ui.Text can't clip), and its tooltip then
-- leads with the full text.
-- PrettyUI 1.2.0's CheckboxButton can neither show an icon nor be recoloured or retexted, so
-- the list doesn't use it.

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
-- Space kept between the end of a label and the tick box.
local LABEL_GAP = 6

-- Text colours (0xRRGGBBAA): PrettyUI 1.2.0's default text colour, and a dimmed one for done
-- rows. A done row's icon is drawn at half opacity.
local TEXT_COLOUR = 0xE7D7B0FF
local DONE_COLOUR = 0x7A7262FF
local DONE_ALPHA = 0.5

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
---@field text string? the row's full text
---@field availWidth integer? the label width `text` was last fitted to
---@field shortened boolean whether the label shows less than `text`
---@field content ui.Layer? the layer that owns the tooltip, once it has one
---@field baseTooltip { text: string, maxWidth: integer }? the tooltip as given to setTooltip
---@field done boolean?
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

-- Make a row at content height `y` under `content`, showing `icon` (nothing if its name doesn't
-- resolve). `onClick` runs on a press anywhere on the row: on ONCLICK, since a quick click can
-- arrive release-first in the client (docs/api-concepts.md, "Pointer hooks on a plain
-- `ui.Layer`"). `wheel`, when given, takes the mouse wheel over the row, which the row would
-- otherwise swallow. Call M.show to give it its text and state.
---@param content ui.Layer
---@param y integer
---@param icon ChoreIcon
---@param onClick fun()
---@param wheel ChoreWheelHandler?
---@return ChoreRowView
function M.new(content, y, icon, onClick, wheel)
    local layer = ui.Layer.new(content)
    layer:SetPos(PADDING, y)
    layer:SetSize(-PADDING * 2, ROW_HEIGHT, 1.0, 0)
    layer.clickthrough = false
    layer:Subscribe(ui.Hook.ONCLICK, function()
        onClick()
    end)
    if wheel then layer:Subscribe(ui.Hook.ONSCROLLWHEEL, wheel) end

    local sprite = nil ---@type ui.Sprite?
    local found = resolve(icon)
    if found then
        sprite = ui.Sprite.new(layer)
        sprite:SetPos(0, (ROW_HEIGHT - ICON_SIZE) // 2)
        sprite:SetSize(ICON_SIZE, ICON_SIZE)
        sprite.clickthrough = true
        if icon.obj then
            sprite:SetAssociatedObject(found)
        else
            sprite.spriteID = found
        end
    end

    -- At the same x whether or not there is an icon, so the names line up.
    local label = ui.Text.new(layer)
    label:SetPos(TEXT_X, 0)
    label:SetSize(-(TEXT_X + BOX_SIZE + LABEL_GAP), ROW_HEIGHT, 1.0, 0)
    label.font = id.Font.MUSEO_SANS_15PT_REGULAR
    label:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)
    label.clickthrough = true

    local box = ui.Sprite.new(layer)
    box:SetPos(-BOX_SIZE, (ROW_HEIGHT - BOX_SIZE) // 2, 1.0, 0)
    box:SetSize(BOX_SIZE, BOX_SIZE)
    box.clickthrough = true

    return { layer = layer, icon = sprite, label = label, box = box, shortened = false }
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
    local avail = row.layer.width - TEXT_X - BOX_SIZE - LABEL_GAP
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

-- Show `text`, and the row as done (dimmed icon, muted text, ticked box) or not. Only what
-- changed is touched. The tooltip is left to setTooltip, which the caller runs next, so one
-- refresh replaces it once.
---@param row ChoreRowView
---@param text string
---@param done boolean
function M.show(row, text, done)
    if row.text ~= text then
        row.text = text
        -- Shown whole first, so a width that is still unknown leaves the full text.
        row.label.content = text
        row.shortened, row.availWidth = false, nil
        fitLabel(row)
    end
    if row.done == done then return end
    row.done = done
    row.label.rgba = done and DONE_COLOUR or TEXT_COLOUR
    if row.icon then row.icon.alpha = done and DONE_ALPHA or 1 end
    row.box.spriteID = done and id.Sprite.RS3_BTN_CHECKBOX_SMALL_2
        or id.Sprite.RS3_BTN_CHECKBOX_SMALL_0
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
