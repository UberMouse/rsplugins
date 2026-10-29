-- One chore's row in the list view, hand-built from plain components inside the window's
-- content: the chore's icon at the left, its text, and a tick box at the right edge. The row
-- layer takes the clicks; the icon, text and box let them through to it. A row is changed in
-- place (colour, dimming, tick, text, tooltip) and goes when its window is destroyed.
-- PrettyUI 1.2.0's CheckboxButton can neither show an icon nor be recoloured or retexted, so
-- the list doesn't use it.

local M = {}

-- Pixel sizes: the row, its icon and tick box, and where the text starts (6 px after the
-- icon). The row is inset from the content's sides by PrettyUI 1.2.0's flow padding, like its
-- own rows.
local PADDING = 14
local ROW_HEIGHT = 28
local ICON_SIZE = 24
local BOX_SIZE = 16
local TEXT_X = ICON_SIZE + 6

-- Text colours (0xRRGGBBAA): PrettyUI 1.2.0's default text colour, and a dimmed one for done
-- rows. A done row's icon is drawn at half opacity.
local TEXT_COLOUR = 0xE7D7B0FF
local DONE_COLOUR = 0x7A7262FF
local DONE_ALPHA = 0.5

local say = nil ---@type fun(...)?
-- Icon names already reported missing, so each is logged once per load.
local reported = {} ---@type table<string, boolean>

-- PrettyUI 1.2.0's window wheel handler (types/prettyui.lua, Window._onScrollWheel).
---@alias ChoreWheelHandler fun(component: ui.Component, delta: number): boolean

---@class ChoreRowView
---@field layer ui.Layer
---@field icon ui.Sprite? nil when the icon's name didn't resolve
---@field label ui.Text
---@field box ui.Sprite
---@field text string?
---@field done boolean?
---@field tooltipText string?
---@field tooltip prettyui.TooltipAttachment?

-- Where log lines go. Call once at load.
---@param opts { say: fun(...) }
function M.init(opts)
    say, reported = opts.say, {}
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
    if ok and math.type(found) == "integer" then return found end
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
    label:SetSize(-(TEXT_X + BOX_SIZE + 6), ROW_HEIGHT, 1.0, 0)
    label.font = id.Font.MUSEO_SANS_15PT_REGULAR
    label:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)
    label.clickthrough = true

    local box = ui.Sprite.new(layer)
    box:SetPos(-BOX_SIZE, (ROW_HEIGHT - BOX_SIZE) // 2, 1.0, 0)
    box:SetSize(BOX_SIZE, BOX_SIZE)
    box.clickthrough = true

    return { layer = layer, icon = sprite, label = label, box = box }
end

-- Show `text`, and the row as done (dimmed icon, muted text, ticked box) or not. Only what
-- changed is touched.
---@param row ChoreRowView
---@param text string
---@param done boolean
function M.show(row, text, done)
    if row.text ~= text then
        row.text = text
        row.label.content = text
    end
    if row.done == done then return end
    row.done = done
    row.label.rgba = done and DONE_COLOUR or TEXT_COLOUR
    if row.icon then row.icon.alpha = done and DONE_ALPHA or 1 end
    row.box.spriteID = done and id.Sprite.RS3_BTN_CHECKBOX_SMALL_2
        or id.Sprite.RS3_BTN_CHECKBOX_SMALL_0
end

-- Give the row `tooltip`, drawn by the window that owns `content` (so destroying the window
-- destroys it). A changed one replaces the old attachment, whose Destroy also takes it down if
-- it is showing (PrettyUI 1.2.0, src/tooltip.lua), so no tooltip stays up with old text.
---@param row ChoreRowView
---@param content ui.Layer
---@param tooltip { text: string, maxWidth: integer }
function M.setTooltip(row, content, tooltip)
    if row.tooltipText == tooltip.text then return end
    if row.tooltip then row.tooltip:Destroy() end
    row.tooltip = prettyui.Tooltip.attach(row.layer, content, tooltip)
    row.tooltipText = tooltip.text
end

return M
