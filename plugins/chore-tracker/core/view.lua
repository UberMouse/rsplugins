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

-- The settings view's subheadings within a period, in display order, and their text.
M.CATEGORIES = { "activities", "combat", "skilling", "upkeep", "supplies", "shops" } ---@type ChoreCategory[]
M.CATEGORY_TITLES = {
    activities = "Activities",
    combat = "Combat",
    skilling = "Skilling",
    upkeep = "Upkeep",
    supplies = "Free supplies",
    shops = "Shops",
}

---@class ChoreSubgroup
---@field category ChoreCategory? nil for the period's chores without one, which get no subheading
---@field chores Chore[] in chore-list order

---@class ChoreGroup
---@field period ChorePeriod
---@field title string
---@field subgroups ChoreSubgroup[] uncategorised chores first, then by CATEGORIES

-- `chores` grouped by period in the order Daily, Weekly, Monthly, and within a period by
-- category, for the settings view. A period or category with no chores has no group.
---@param chores Chore[]
---@return ChoreGroup[]
function M.byPeriod(chores)
    local groups = {}
    for _, p in ipairs(period.PERIODS) do
        local byCategory, loose = {}, {} ---@type table<ChoreCategory, Chore[]>, Chore[]
        for _, chore in ipairs(chores) do
            if chore.period == p then
                local into = loose
                if chore.category then
                    into = byCategory[chore.category] or {}
                    byCategory[chore.category] = into
                end
                into[#into + 1] = chore
            end
        end
        local subgroups = {} ---@type ChoreSubgroup[]
        if #loose > 0 then subgroups[1] = { chores = loose } end
        for _, c in ipairs(M.CATEGORIES) do
            if byCategory[c] then
                subgroups[#subgroups + 1] = { category = c, chores = byCategory[c] }
            end
        end
        if #subgroups > 0 then
            groups[#groups + 1] = { period = p, title = M.TITLES[p], subgroups = subgroups }
        end
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

-- The collapsed strip's messages, for when it has no chore to show.
M.NOTHING_PICKED = "No chores picked"
M.ALL_DONE = "All chores done"

---@class ChoreStrip
---@field id string? the chore shown; nil when `text` is a message
---@field text string
---@field texts string[] every text the strip should fit uncut, for its width
---@field icon ChoreIcon? the chore's icon, added by the shell

-- A row's text in the collapsed strip: its period's title, then its list text.
---@param section ChoreSection
---@param row ChoreRow
---@return string
function M.stripText(section, row)
    return section.title .. ": " .. M.rowText(row)
end

-- What the collapsed strip shows: the first chore not done, Daily first, then Weekly, then
-- Monthly, each in the player's order; else `notice` when given (logged out, waiting for the
-- clock), or a message when nothing is picked or everything is done. Its `texts` hold every
-- picked chore's strip text, done or not, and any message shown, so the strip can be wide
-- enough for all of them and keep its width while the chores are ticked off.
---@param sections ChoreSection[]
---@param notice string?
---@return ChoreStrip
function M.strip(sections, notice)
    local texts, first = {}, nil ---@type string[], ChoreStrip?
    for _, section in ipairs(sections) do
        for _, row in ipairs(section.rows) do
            local text = M.stripText(section, row)
            texts[#texts + 1] = text
            if first == nil and not row.done then
                first = { id = row.id, text = text, texts = texts }
            end
        end
    end
    if notice == nil and first then return first end
    local message = notice or (#texts == 0 and M.NOTHING_PICKED or M.ALL_DONE)
    texts[#texts + 1] = message
    return { text = message, texts = texts }
end

return M
