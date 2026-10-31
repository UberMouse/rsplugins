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

---@class ChorePartLine
---@field name string? only shops have one
---@field done boolean done this period

---@class ChoreRow
---@field id string
---@field name string
---@field desc string
---@field url string
---@field links string[]
---@field done boolean
---@field parts ChorePartLine[] the chore's parts (core/parts.lua), in list order; empty if it
---has none
---@field noun string the parts' tooltip word, as "Shops"; "" without parts
---@field word string how a done part reads, as "bought"; "" without parts
---@field partsDone integer how many of `parts` were done this period
---@field needed integer how many of `parts` tick the chore (state.partsNeeded); 0 without parts

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

-- A chore's parts and whether each was done this period, by any of its keys (none without a
-- clock, `now` nil), and how many were.
---@param s ChoreState
---@param chore Chore
---@param parts ChoreParts?
---@param now integer?
---@return ChorePartLine[]
---@return integer done
local function partLines(s, chore, parts, now)
    local lines, done = {}, 0
    for i, part in ipairs(parts and parts.list or {}) do
        local yes = now ~= nil and state.partDone(s, chore, part, now)
        lines[i] = { name = part.name, done = yes }
        if yes then done = done + 1 end
    end
    return lines, done
end

-- No parts, for a chore without them.
local NO_PARTS = { noun = "", word = "", list = {} } ---@type ChoreParts

-- The sections in the order Daily, Weekly, Monthly, each holding only its selected chores
-- (shop chores included), in the order the player arranged them. A period with nothing
-- selected has no section. Without a clock (`now` nil: logged out or loading) nothing shows
-- done, chore or part, since no period can be placed.
---@param s ChoreState
---@param chores Chore[]
---@param now integer? epoch minutes
---@param parts table<string, ChoreParts>? chore id -> its parts
---@return ChoreSection[]
function M.view(s, chores, now, parts)
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
            local own = parts and parts[id] or NO_PARTS
            local lines, partsDone = partLines(s, chore, own, now)
            section.rows[#section.rows + 1] = {
                id = id,
                name = chore.name,
                desc = chore.desc,
                url = chore.url,
                links = chore.links,
                done = done,
                parts = lines,
                noun = own.noun,
                word = own.word,
                partsDone = partsDone,
                needed = state.partsNeeded(s, chore, own),
            }
            if done then section.done = section.done + 1 end
        end
        section.total = #section.rows
        if section.total > 0 then sections[#sections + 1] = section end
    end
    return sections
end

-- Whether a chore with these parts (its part list, or a row's part lines) gives the player a
-- choice of how many to do: only then does it get a count in its row and a stepper.
---@param parts any[]
---@return boolean
function M.hasChoice(parts)
    return #parts > 1
end

-- A row's parts done this period out of those it needs, as "1/4". Done is capped at needed:
-- parts past the count add nothing to the tick.
---@param row ChoreRow
---@return string
local function partCount(row)
    return string.format("%d/%d", math.min(row.partsDone, row.needed), row.needed)
end

-- A list row's text: the chore's name, and for a chore with a choice of parts, how many of
-- the parts it needs were done this period, as "Feather Shop Run (1/4)".
---@param row ChoreRow
---@return string
function M.rowText(row)
    if not M.hasChoice(row.parts) then return row.name end
    return string.format("%s (%s)", row.name, partCount(row))
end

-- The tooltip lines for a row's parts: a heading with the count of rowText, then every named
-- part (only shops have names) as done or not yet. None for a chore without parts.
---@param row ChoreRow
---@param p ChorePeriod the row's period
---@return string[]
function M.partTooltip(row, p)
    if #row.parts == 0 then return {} end
    local lines = {
        string.format("%s this %s (%s):", row.noun, M.PERIOD_WORDS[p], partCount(row)),
    }
    for _, part in ipairs(row.parts) do
        if part.name then
            lines[#lines + 1] = (part.done and row.word or "not yet") .. "  " .. part.name
        end
    end
    return lines
end

---@class ChoreCountSetting
---@field chore Chore
---@field label string the chore's name, after its period's title (as the strip has it, so a
---cut label keeps the period) when another line shares it
---@field needed integer its current count (state.partsNeeded)
---@field total integer how many parts it has

-- The settings view's count lines: each chore with a choice of parts, picked or not, in
-- chore-list order, with how many of its parts tick it. The block has no period headings, so
-- chores of one name in two periods (Invention Machines) are told apart by their period, as
-- "Weekly: Invention Machines".
---@param s ChoreState
---@param chores Chore[]
---@param parts table<string, ChoreParts> chore id -> its parts
---@return ChoreCountSetting[]
function M.countSettings(s, chores, parts)
    local out = {}
    for _, chore in ipairs(chores) do
        local own = parts[chore.id]
        if own and M.hasChoice(own.list) then
            out[#out + 1] = {
                chore = chore,
                label = chore.name,
                needed = state.partsNeeded(s, chore, own),
                total = #own.list,
            }
        end
    end
    local named = {}
    for _, line in ipairs(out) do
        named[line.chore.name] = (named[line.chore.name] or 0) + 1
    end
    for _, line in ipairs(out) do
        if named[line.chore.name] > 1 then
            line.label = M.TITLES[line.chore.period] .. ": " .. line.chore.name
        end
    end
    return out
end

-- A count stepper's value, as "2 of 4".
---@param needed integer
---@param total integer
---@return string
function M.neededText(needed, total)
    return string.format("%d of %d", needed, total)
end

-- A chore's tooltip: its description, then `extra` lines (a list row's parts), then its wiki
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
