-- What the window shows, as plain data: one section per period that has selected chores.

local period = require("core/period")
local state = require("core/state")

local M = {}

-- Each period's heading.
M.TITLES = { daily = "Daily", weekly = "Weekly", monthly = "Monthly" }

---@class ChoreRow
---@field id string
---@field name string
---@field desc string
---@field url string
---@field links string[]
---@field shop boolean
---@field done boolean

---@class ChoreSection
---@field period "daily"|"weekly"|"monthly"
---@field title string
---@field rows ChoreRow[] selected chores of this period, in chore-list order
---@field done integer how many rows are done
---@field total integer how many rows there are

-- The sections in the order Daily, Weekly, Monthly, each holding only its selected chores
-- (shop chores included). A period with nothing selected has no section. Without a clock
-- (`now` nil: logged out or loading) nothing shows done, since no period can be placed.
---@param s ChoreState
---@param chores Chore[]
---@param now integer? epoch minutes
---@return ChoreSection[]
function M.view(s, chores, now)
    local sections = {}
    for _, p in ipairs(period.PERIODS) do
        local section = { period = p, title = M.TITLES[p], rows = {}, done = 0, total = 0 }
        for _, chore in ipairs(chores) do
            if chore.period == p and state.isSelected(s, chore.id) then
                local done = now ~= nil and state.isDone(s, chore, now)
                section.rows[#section.rows + 1] = {
                    id = chore.id,
                    name = chore.name,
                    desc = chore.desc,
                    url = chore.url,
                    links = chore.links,
                    shop = chore.shop,
                    done = done,
                }
                if done then section.done = section.done + 1 end
            end
        end
        section.total = #section.rows
        if section.total > 0 then sections[#sections + 1] = section end
    end
    return sections
end

return M
