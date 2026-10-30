-- Spotting a chore done from what the client shows, as plain data.
--
-- Shops: the client sends a shop's inventory only while that shop is open, and stock is per
-- character, so a line whose count drops is the player buying from it. Counts that rise (a
-- restock, or the player selling) are not.
--
-- Collections (data/collections.lua) are no shops: the goods arrive as banknotes in the
-- backpack, so such a chore is a rise in those notes while the player stands near the giver.

local M = {}

---@class ChoreShopEntry
---@field chore string the chore id
---@field shop ChoreShop

-- The shop data turned round: shop inventory name -> the chores and shops it serves, so an
-- inventory event is matched by one lookup. Entries keep the chore ids' sorted order, so
-- the order a purchase is applied in doesn't depend on table iteration.
---@param shops table<string, ChoreShop[]> chore id -> its shops
---@return table<string, ChoreShopEntry[]>
function M.index(shops)
    local ids = {}
    for id in pairs(shops) do
        ids[#ids + 1] = id
    end
    table.sort(ids)
    local out = {}
    for _, id in ipairs(ids) do
        for _, shop in ipairs(shops[id]) do
            for _, inv in ipairs(shop.invs) do
                out[inv] = out[inv] or {}
                table.insert(out[inv], { chore = id, shop = shop })
            end
        end
    end
    return out
end

-- Whether any slot's count is lower in `after` than in `before` (both slot -> count). A
-- slot missing from either side is not compared.
---@param before integer[]
---@param after integer[]
---@return boolean
function M.dropped(before, after)
    for i, count in pairs(after) do
        local was = before[i]
        if was and count < was then return true end
    end
    return false
end

-- Whether any of `names` has a higher count in `after` than in `before` (both name ->
-- count). A name missing from either side is not compared.
---@param before table<string, integer>
---@param after table<string, integer>
---@param names string[]
---@return boolean
function M.rose(before, after, names)
    for _, name in ipairs(names) do
        local was, count = before[name], after[name]
        if was and count and count > was then return true end
    end
    return false
end

-- Whether tiles `a` and `b` are on the same plane and at most `range` tiles apart in each
-- direction (Chebyshev distance, so the area is a square).
---@param a ChoreTile
---@param b ChoreTile
---@param range integer
---@return boolean
function M.near(a, b, range)
    return a.level == b.level and math.abs(a.x - b.x) <= range and math.abs(a.z - b.z) <= range
end

return M
