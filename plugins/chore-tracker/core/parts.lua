-- A chore's parts: the things it can be done at (shops, herb patches, bloodwood trees,
-- penguins...) when it has several, and how many of them tick it. Built once at load from the
-- data files: a shop run's parts are its shops (data/shops.lua), and a var chore's the `part`
-- keys its rules name (data/vars.lua). The Invention machines have none: a collect from any
-- one ticks them (the user's call, 2026-10-31). core/state.lua records each part done this
-- period, by any of its keys, and ticks the chore once the player's count of them is done.
--
-- data/counts.lua gives every chore whose parts aren't shops a noun, a default count and the
-- help for its settings line; a shop run needs all its shops until the player sets fewer.

local M = {}

---@class ChorePart
---@field name string? listed in the row's tooltip; only shops have one, since which var is which
---patch or penguin isn't known
---@field keys string[] what marks it done: a shop's inventories, or a var rule's `part`

---@class ChoreParts
---@field noun string the tooltip heading's word for them, as "Patches"
---@field word string how a done part reads in the tooltip, as "bought"
---@field list ChorePart[]
---@field default integer? how many tick the chore until the player sets a count; nil for all
---@field fixed boolean? the count is always `default`, with no settings line
---@field help string? what the count counts, for its settings line's tooltip; nil when fixed

---@class ChoreCount
---@field noun string
---@field default integer? nil for all of them
---@field fixed boolean?
---@field help string? required unless `fixed`

-- What a shop run's count counts.
local SHOP_HELP = "How many of its shops you buy from"

-- Each chore's parts, by chore id. A chore whose parts aren't shops takes its noun, default,
-- fixedness and help from `counts`; one missing there fails naming it, as does a counts entry
-- for a chore with no parts, or one with neither help nor a fixed count. A var part key named
-- by several rules is one part.
---@param shops table<string, ChoreShop[]>
---@param rules ChoreVarRule[]
---@param counts table<string, ChoreCount>
---@return table<string, ChoreParts>
function M.build(shops, rules, counts)
    local out = {}
    for id, listed in pairs(shops) do
        local list = {}
        for i, shop in ipairs(listed) do
            list[i] = { name = shop.name, keys = shop.invs }
        end
        out[id] = { noun = "Shops", word = "bought", list = list, help = SHOP_HELP }
    end
    -- Non-shop parts, in data order, each key once per chore.
    local seen = {}
    ---@param id string
    ---@param key string
    local function add(id, key)
        if out[id] == nil then
            local count = counts[id]
            assert(count, "data/counts.lua lacks " .. id .. ", which has parts")
            assert(count.fixed or count.help, "data/counts.lua gives " .. id .. " no help")
            out[id] = {
                noun = count.noun,
                word = "done",
                list = {},
                default = count.default,
                fixed = count.fixed,
                help = count.help,
            }
            seen[id] = {}
        end
        assert(seen[id], id .. " has both shops and other parts")
        if not seen[id][key] then
            seen[id][key] = true
            table.insert(out[id].list, { keys = { key } })
        end
    end
    for _, rule in ipairs(rules) do
        if rule.part then add(rule.chore, rule.part) end
    end
    for id in pairs(counts) do
        assert(seen[id], "data/counts.lua names " .. id .. ", which has no parts")
    end
    return out
end

return M
