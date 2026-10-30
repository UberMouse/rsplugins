-- Where the list view's headings and chore rows go in the window's content, as plain data.
-- Pure: the shell gives the sections and the bottom of what PrettyUI already placed at the top
-- (the settings button and any notice), and makes the components at these spots.

local M = {}

-- A chore row: room for its 24 px icon with a little space above and below.
M.ROW_HEIGHT = 28
-- A heading is a PrettyUI 1.2.0 title, whose row is 28 px.
M.HEADING_HEIGHT = 28
-- Space above each heading (from the button above the first, or the last row of the section
-- before), and below each heading.
M.HEADING_GAP = 8
M.AFTER_HEADING = 4
-- PrettyUI 1.2.0's flow padding: the margin at the content's sides for its own rows, so the
-- shell insets chore rows by it, and under the last row, so the list ends with the same margin.
M.FLOW_PADDING = 14

---@class ChoreListLayout
---@field headings table<ChorePeriod, integer> each section's heading y, by period
---@field rows table<string, integer> each row's y, by chore id
---@field height integer the content height that holds them all, padding included

---@class ChoreSectionIds
---@field period ChorePeriod
---@field ids string[] the chore ids of its rows, top to bottom

-- The y of each heading and row of `sections`, top to bottom from `top` (the bottom of what is
-- above the list), and the content height that holds them.
---@param sections ChoreSectionIds[]
---@param top integer
---@return ChoreListLayout
function M.place(sections, top)
    local out = { headings = {}, rows = {} }
    local y = top
    for _, section in ipairs(sections) do
        y = y + M.HEADING_GAP
        out.headings[section.period] = y
        y = y + M.HEADING_HEIGHT + M.AFTER_HEADING
        for _, rowId in ipairs(section.ids) do
            out.rows[rowId] = y
            y = y + M.ROW_HEIGHT
        end
    end
    out.height = y + M.FLOW_PADDING
    return out
end

return M
