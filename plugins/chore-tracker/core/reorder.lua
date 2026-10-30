-- The geometry of dragging a chore row to a new place in its period, as plain data. Pure:
-- the shell reads the pointer and moves the components; this says where they go.
-- All y values are in the window's content space, like core/listlayout's.

local listlayout = require("core/listlayout")

local M = {}

-- How far the list scrolls per tick while the pointer is past its top or bottom edge.
M.SCROLL_STEP = 8

---@class ChoreDrag
---@field slot integer the 1-based position the dragged row would drop into
---@field y integer the dragged row's top, kept inside the period's rows
---@field rows table<string, integer> every other row's y, with a gap opened at `slot`

-- Every row's y with nothing being dragged: `ids` stacked from `firstY`, `rowHeight` apart.
---@param ids string[]
---@param firstY integer
---@param rowHeight integer? defaults to the list's row height; only the specs pass another
---@return table<string, integer>
function M.settle(ids, firstY, rowHeight)
    local h = rowHeight or listlayout.ROW_HEIGHT
    local rows = {}
    for i, id in ipairs(ids) do
        rows[id] = firstY + (i - 1) * h
    end
    return rows
end

-- Where a drag of the row at `from` (1-based, in `ids`) stands when its top is at `desiredY`.
-- `ids` are the period's row ids in their current order and `firstY` is the first row's y.
-- The row drops into the slot nearest its top; the others close up around it, then shift
-- one row down from `slot` on, which is the gap.
---@param ids string[]
---@param firstY integer
---@param from integer
---@param desiredY number
---@param rowHeight integer? defaults to the list's row height; only the specs pass another
---@return ChoreDrag
function M.drag(ids, firstY, from, desiredY, rowHeight)
    local h = rowHeight or listlayout.ROW_HEIGHT
    local lastY = firstY + (#ids - 1) * h
    local y = math.max(firstY, math.min(desiredY, lastY))
    local slot = math.floor((y - firstY) / h + 0.5) + 1
    local others = {}
    for i, id in ipairs(ids) do
        if i ~= from then others[#others + 1] = id end
    end
    local rows = M.settle(others, firstY, h)
    for n = slot, #others do
        rows[others[n]] = rows[others[n]] + h
    end
    return { slot = slot, y = math.floor(y + 0.5), rows = rows }
end

-- The signed scroll per tick for a pointer at `pointerY` over a list showing `top` to
-- `bottom`: up (negative) above the top, down (positive) below the bottom, 0 inside.
---@param pointerY number
---@param top number
---@param bottom number
---@return integer
function M.scrollStep(pointerY, top, bottom)
    if pointerY < top then return -M.SCROLL_STEP end
    if pointerY > bottom then return M.SCROLL_STEP end
    return 0
end

return M
