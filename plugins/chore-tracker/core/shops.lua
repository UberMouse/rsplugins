-- Spotting a purchase in a shop's stock, as plain data. The client sends a shop's inventory
-- only while that shop is open, and stock is per character, so a line whose count drops is
-- the player buying from it. Counts that rise (a restock, or the player selling) are not.

local M = {}

---@class ChoreShopEntry
---@field chore string the chore id
---@field shop ChoreShop

-- The shop data turned round: shop inventory name -> the chores it serves, so an inventory
-- event is matched by one lookup. Entries keep the chore ids' sorted order, so the order a
-- purchase is applied in doesn't depend on table iteration.
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
            out[shop.inv] = out[shop.inv] or {}
            table.insert(out[shop.inv], { chore = id, shop = shop })
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

return M
