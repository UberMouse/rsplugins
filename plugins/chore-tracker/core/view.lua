-- What the window shows, as plain data: one section per period that has selected chores, plus the
-- text for its tooltips, headings and settings rows.

local period = require("core/period")
local state = require("core/state")

local M = {}

-- Each period's heading.
M.TITLES = { daily = "Daily", weekly = "Weekly", monthly = "Monthly" }

-- Tooltips wrap at this width; wiki URLs are long.
local TOOLTIP_WIDTH = 360

-- Each period as a word for "this <word>".
M.PERIOD_WORDS = { daily = "day", weekly = "week", monthly = "month" }

---@alias ChoreTooltip { text: string, maxWidth: integer }

---@class ChoreShopLine
---@field name string
---@field bought boolean bought from this period

---@class ChoreRow
---@field id string
---@field name string
---@field desc string
---@field url string
---@field links string[]
---@field done boolean
---@field shops ChoreShopLine[] the chore's listed shops, in list order; empty if it has none
---@field bought integer how many of `shops` were bought from this period

---@class ChoreSection
---@field period ChorePeriod
---@field title string
---@field rows ChoreRow[] selected chores of this period, in the player's order
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

-- A chore's listed shops and whether each was bought from this period, in any of its
-- inventories (none without a clock, `now` nil), and how many were.
---@param s ChoreState
---@param chore Chore
---@param listed ChoreShop[]
---@param now integer?
---@return ChoreShopLine[]
---@return integer bought
local function shopLines(s, chore, listed, now)
    local lines, bought = {}, 0
    for i, shop in ipairs(listed) do
        local yes = now ~= nil and state.shopBoughtAny(s, chore, shop.invs, now)
        lines[i] = { name = shop.name, bought = yes }
        if yes then bought = bought + 1 end
    end
    return lines, bought
end

-- The sections in the order Daily, Weekly, Monthly, each holding only its selected chores
-- (shop chores included), in the order the player arranged them. A period with nothing
-- selected has no section. Without a clock (`now` nil: logged out or loading) nothing shows
-- done or bought, since no period can be placed.
---@param s ChoreState
---@param chores Chore[]
---@param now integer? epoch minutes
---@param shops table<string, ChoreShop[]>? chore id -> its listed shops
---@return ChoreSection[]
function M.view(s, chores, now, shops)
    local byId = {}
    for _, chore in ipairs(chores) do
        byId[chore.id] = chore
    end
    local sections = {}
    for _, p in ipairs(period.PERIODS) do
        local section = { period = p, title = M.TITLES[p], rows = {}, done = 0, total = 0 }
        for _, id in ipairs((state.selectedIn(s, chores, p))) do
            local chore = byId[id]
            local done = now ~= nil and state.isDone(s, chore, now)
            local lines, bought = shopLines(s, chore, shops and shops[id] or {}, now)
            section.rows[#section.rows + 1] = {
                id = id,
                name = chore.name,
                desc = chore.desc,
                url = chore.url,
                links = chore.links,
                done = done,
                shops = lines,
                bought = bought,
            }
            if done then section.done = section.done + 1 end
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

-- A chore's tooltip: its description, then `extra` lines (a list row's shops), then its wiki
-- page and any other links, as text; "<br>" is the tooltip's line-break tag. Takes a Chore or a
-- ChoreRow, which share these fields.
---@param chore { desc: string, url: string, links: string[] }
---@param extra string[]?
---@return ChoreTooltip
function M.tooltip(chore, extra)
    local lines = {}
    if chore.desc ~= "" then lines[#lines + 1] = chore.desc end
    for _, line in ipairs(extra or {}) do
        lines[#lines + 1] = line
    end
    lines[#lines + 1] = chore.url
    for _, link in ipairs(chore.links) do
        lines[#lines + 1] = link
    end
    return { text = table.concat(lines, "<br>"), maxWidth = TOOLTIP_WIDTH }
end

-- A section's heading: its period's title and how many of its rows are done.
---@param section ChoreSection
---@return string
function M.headingText(section)
    return string.format("%s  %d/%d", section.title, section.done, section.total)
end

-- A settings row's text: the chore's name, marked when it is a shop run.
---@param chore Chore
---@return string
function M.pickText(chore)
    return chore.shop and chore.name .. " (shop)" or chore.name
end

return M
