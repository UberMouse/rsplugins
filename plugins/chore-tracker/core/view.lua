-- What the window shows, as plain data: one section per period that has selected chores.

local period = require("core/period")
local state = require("core/state")

local M = {}

-- Each period's heading.
M.TITLES = { daily = "Daily", weekly = "Weekly", monthly = "Monthly" }

-- Each period as a word for "this <word>".
M.PERIOD_WORDS = { daily = "day", weekly = "week", monthly = "month" }

---@class ChoreShopLine
---@field name string
---@field bought boolean bought from this period

---@class ChoreRow
---@field id string
---@field name string
---@field desc string
---@field url string
---@field links string[]
---@field shop boolean
---@field done boolean
---@field shops ChoreShopLine[] the chore's listed shops, in list order; empty if it has none
---@field bought integer how many of `shops` were bought from this period

---@class ChoreSection
---@field period ChorePeriod
---@field title string
---@field rows ChoreRow[] selected chores of this period, in chore-list order
---@field done integer how many rows are done
---@field total integer how many rows there are

---@class ChoreGroup
---@field period ChorePeriod
---@field title string
---@field chores Chore[] in chore-list order

-- `chores` grouped by period in the order Daily, Weekly, Monthly. A period with no chores
-- has no group.
---@param chores Chore[]
---@return ChoreGroup[]
function M.byPeriod(chores)
    local groups = {}
    for _, p in ipairs(period.PERIODS) do
        local group = { period = p, title = M.TITLES[p], chores = {} }
        for _, chore in ipairs(chores) do
            if chore.period == p then group.chores[#group.chores + 1] = chore end
        end
        if #group.chores > 0 then groups[#groups + 1] = group end
    end
    return groups
end

-- A chore's listed shops and whether each was bought from this period (none without a
-- clock), and how many were.
---@param s ChoreState
---@param chore Chore
---@param listed ChoreShop[]
---@param now integer?
---@return ChoreShopLine[]
---@return integer bought
local function shopLines(s, chore, listed, now)
    local lines, bought = {}, 0
    for i, shop in ipairs(listed) do
        local yes = now ~= nil and state.shopBought(s, chore, shop.inv, now)
        lines[i] = { name = shop.name, bought = yes }
        if yes then bought = bought + 1 end
    end
    return lines, bought
end

-- The sections in the order Daily, Weekly, Monthly, each holding only its selected chores
-- (shop chores included). A period with nothing selected has no section. Without a clock
-- (`now` nil: logged out or loading) nothing shows done or bought, since no period can be
-- placed.
---@param s ChoreState
---@param chores Chore[]
---@param now integer? epoch minutes
---@param shops table<string, ChoreShop[]>? chore id -> its listed shops
---@return ChoreSection[]
function M.view(s, chores, now, shops)
    local sections = {}
    for _, group in ipairs(M.byPeriod(chores)) do
        local section =
            { period = group.period, title = group.title, rows = {}, done = 0, total = 0 }
        for _, chore in ipairs(group.chores) do
            if state.isSelected(s, chore.id) then
                local done = now ~= nil and state.isDone(s, chore, now)
                local lines, bought = shopLines(s, chore, shops and shops[chore.id] or {}, now)
                section.rows[#section.rows + 1] = {
                    id = chore.id,
                    name = chore.name,
                    desc = chore.desc,
                    url = chore.url,
                    links = chore.links,
                    shop = chore.shop,
                    done = done,
                    shops = lines,
                    bought = bought,
                }
                if done then section.done = section.done + 1 end
            end
        end
        section.total = #section.rows
        if section.total > 0 then sections[#sections + 1] = section end
    end
    return sections
end

-- A list row's text: the chore's name, and for a chore with more than one shop, how many
-- were bought from this period, as "Feather Shop Run (1/4)".
---@param row ChoreRow
---@return string
function M.rowText(row)
    if #row.shops <= 1 then return row.name end
    return string.format("%s (%d/%d)", row.name, row.bought, #row.shops)
end

-- The tooltip lines for a row's shops: a heading, then each shop as bought or not yet. None
-- for a chore without shops.
---@param row ChoreRow
---@param p ChorePeriod the row's period
---@return string[]
function M.shopTooltip(row, p)
    if #row.shops == 0 then return {} end
    local lines = {
        string.format("Shops this %s (%d/%d):", M.PERIOD_WORDS[p], row.bought, #row.shops),
    }
    for _, shop in ipairs(row.shops) do
        lines[#lines + 1] = (shop.bought and "bought  " or "not yet  ") .. shop.name
    end
    return lines
end

return M
