-- What the info view shows, as plain data: a few paragraphs of help, and every chore sorted by
-- whether it ticks itself. Pure: the shell gives the data files and makes the components.

local M = {}

-- The help, one paragraph per entry, unwrapped (the shell wraps each to the window, see
-- core/fit.lua's wrap). "<br>" breaks a line and "<col=ffd700>...</col>" colours text gold.
M.HELP = {
    "Pick the chores you do with the settings button, then click a chore's row to tick it.",
    "Ticks clear at the game's resets (UTC): daily at 00:00, weekly on Wednesday, monthly on the 1st.",
    "Drag a row by its grip to reorder it. In the list, the button at the top right folds the"
        .. " window into a strip showing your next chore.",
    "Some chores tick themselves, but only on a change seen while the plugin runs. A chore done"
        .. " while it was off, or before you logged in, needs a tick by hand.",
    "<col=ffd700>Automatic</col>: ticks itself, checked in game.<br>"
        .. "<col=ffd700>Unproven</col>: should tick itself, not yet checked in game.<br>"
        .. "<col=ffd700>Manual</col>: tick it by hand.",
}

---@alias ChoreStatus "automatic"|"unproven"|"manual"

-- The statuses in the order the info view lists them, and their headings.
M.STATUSES = { "automatic", "unproven", "manual" } ---@type ChoreStatus[]
M.STATUS_TITLES = { automatic = "Automatic", unproven = "Unproven", manual = "Manual" }

-- Whether chore `id` ticks itself: "automatic" when any source the plugin watches for it (a
-- shop, a collection, a machine or a var rule) has `proven` set, "unproven" when it has
-- sources but none is proven, "manual" when it has none.
---@param id string
---@param shops table<string, ChoreShop[]> chore id -> its listed shops
---@param collections ChoreCollection[]
---@param rules ChoreVarRule[]
---@param machines ChoreMachine[]
---@return ChoreStatus
function M.status(id, shops, collections, rules, machines)
    local sources = {} ---@type { proven: boolean }[]
    for _, shop in ipairs(shops[id] or {}) do
        sources[#sources + 1] = shop
    end
    for _, collection in ipairs(collections) do
        if collection.chore == id then sources[#sources + 1] = collection end
    end
    for _, rule in ipairs(rules) do
        if rule.chore == id then sources[#sources + 1] = rule end
    end
    for _, machine in ipairs(machines) do
        if machine.chore == id then sources[#sources + 1] = machine end
    end
    if #sources == 0 then return "manual" end
    for _, source in ipairs(sources) do
        if source.proven then return "automatic" end
    end
    return "unproven"
end

---@class ChoreStatusGroup
---@field status ChoreStatus
---@field chores Chore[] in chore-list order

-- Every chore grouped by status, in STATUSES order, each group in chore-list order. A status
-- with no chores still has its (empty) group, so the view always shows all three headings.
---@param chores Chore[]
---@param shops table<string, ChoreShop[]>
---@param collections ChoreCollection[]
---@param rules ChoreVarRule[]
---@param machines ChoreMachine[]
---@return ChoreStatusGroup[]
function M.byStatus(chores, shops, collections, rules, machines)
    local groups, byStatus = {}, {} ---@type ChoreStatusGroup[], table<ChoreStatus, Chore[]>
    for i, s in ipairs(M.STATUSES) do
        groups[i] = { status = s, chores = {} }
        byStatus[s] = groups[i].chores
    end
    for _, chore in ipairs(chores) do
        local into = byStatus[M.status(chore.id, shops, collections, rules, machines)]
        into[#into + 1] = chore
    end
    return groups
end

-- A status group's heading, with its count: "Automatic (17)".
---@param group ChoreStatusGroup
---@return string
function M.headingText(group)
    return string.format("%s (%d)", M.STATUS_TITLES[group.status], #group.chores)
end

-- A chore's name in the info view. The view lists every period together, so a name another
-- chore shares (one chore offered in two periods) gets its period: "Dream of Iaia XP
-- (weekly)".
---@param chore Chore
---@param chores Chore[]
---@return string
function M.rowName(chore, chores)
    for _, other in ipairs(chores) do
        if other ~= chore and other.name == chore.name then
            return string.format("%s (%s)", chore.name, chore.period)
        end
    end
    return chore.name
end

return M
