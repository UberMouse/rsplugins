-- The collapsed strip's content, inside the panel shell/window.lua makes: the next chore's row
-- (a shell/rows.lua row, so it looks and ticks like a list row) or, when there is no chore to
-- show, a message in its place. Both are made with the panel on a collapse and changed in place
-- after, so ticking the row only retexts it to the next chore. The row has no tooltip: the
-- panel clips one to its own bounds (docs/api-concepts.md, "PrettyUI in the client").

local layout = require("core/layout")
local rows = require("shell/rows")

local M = {}

-- The row's width when the client font can't measure the texts.
local FALLBACK_WIDTH = 220

---@class ChoreStripView
---@field row ChoreRowView
---@field message ui.Text
---@field id string? the chore the row shows; nil while the message shows

-- The row width the strip needs to show `content`'s texts uncut.
---@param content ChoreStrip
---@return integer
function M.rowWidth(content)
    return rows.widthFor(content.texts) or FALLBACK_WIDTH
end

-- Make the row and message on `root`, the strip panel's root, left of its button. A click on
-- the row calls `onTick` with the chore it shows. Call M.show to give them their content.
---@param root ui.Layer
---@param onTick fun(id: string)
---@return ChoreStripView
function M.new(root, onTick)
    local strip = nil ---@type ChoreStripView?
    local margins = {
        left = layout.STRIP_INSET,
        right = -layout.STRIP_BUTTON_X + layout.STRIP_GAP,
    }
    local row = rows.new(root, layout.STRIP_INSET, nil, function()
        assert(strip, "the row is only clicked once new has returned")
        if strip.id then onTick(strip.id) end
    end, { margins = margins })
    local message = rows.newText(root)
    message:SetPos(margins.left, layout.STRIP_INSET)
    message:SetSize(-(margins.left + margins.right), row.layer.height, 1.0, 0)
    message.hidden = true
    strip = { row = row, message = message }
    return strip
end

-- Show `content`: its chore in the row, or its message with the row hidden.
---@param strip ChoreStripView
---@param content ChoreStrip
function M.show(strip, content)
    local row = strip.row
    if content.id then
        if content.id ~= strip.id then rows.setIcon(row, content.icon) end
        rows.show(row, content.text, false)
        -- The strip may have been resized since the text was set.
        rows.fit(row)
        row.layer.hidden = false
        strip.message.hidden = true
    else
        if not row.layer.hidden then
            -- A hidden row gets no mouse-leave, so drop its hover first.
            rows.unhover(row)
            row.layer.hidden = true
        end
        strip.message.content = content.text
        strip.message.hidden = false
    end
    strip.id = content.id
end

return M
