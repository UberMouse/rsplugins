-- A chore's parts: the things it can be done at (shops, herb patches, bloodwood trees,
-- Invention machines...) when it has several, and how many of them tick it. Built once at load
-- from the data files: a shop run's parts are its shops (data/shops.lua), a machine chore's
-- its output inventories (data/machines.lua), and a var chore's the `part` keys its rules name
-- (data/vars.lua). core/state.lua records each part done this period, by any of its keys, and
-- ticks the chore once the player's count of them is done.
--
-- data/counts.lua gives every chore whose parts aren't shops a noun and a default count; a
-- shop run needs all its shops until the player sets fewer.

local M = {}

---@class ChorePart
---@field name string? listed in the row's tooltip; only shops have one, since which var is which
---patch or penguin isn't known
---@field keys string[] what marks it done: a shop's inventories, a machine's output inventory,
---or a var rule's `part`

---@class ChoreParts
---@field noun string the tooltip heading's word for them, as "Patches"
---@field word string how a done part reads in the tooltip, as "bought"
---@field list ChorePart[]
---@field default integer? how many tick the chore until the player sets a count; nil for all

---@class ChoreCount
---@field noun string
---@field default integer? nil for all of them

-- Each chore's parts, by chore id. A chore whose parts aren't shops takes its noun and
-- default from `counts`; one missing there fails naming it, as does a counts entry for a
-- chore with no parts. A var part key named by several rules is one part.
---@param shops table<string, ChoreShop[]>
---@param rules ChoreVarRule[]
---@param machines ChoreMachine[]
---@param counts table<string, ChoreCount>
---@return table<string, ChoreParts>
function M.build(shops, rules, machines, counts)
    local out = {}
    for id, listed in pairs(shops) do
        local list = {}
        for i, shop in ipairs(listed) do
            list[i] = { name = shop.name, keys = shop.invs }
        end
        out[id] = { noun = "Shops", word = "bought", list = list }
    end
    -- Non-shop parts, in data order, each key once per chore.
    local seen = {}
    ---@param id string
    ---@param key string
    local function add(id, key)
        if out[id] == nil then
            local count = counts[id]
            assert(count, "data/counts.lua lacks " .. id .. ", which has parts")
            out[id] = { noun = count.noun, word = "done", list = {}, default = count.default }
            seen[id] = {}
        end
        assert(seen[id], id .. " has both shops and other parts")
        if not seen[id][key] then
            seen[id][key] = true
            table.insert(out[id].list, { keys = { key } })
        end
    end
    for _, machine in ipairs(machines) do
        for _, inv in ipairs(machine.invs) do
            add(machine.chore, inv)
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
