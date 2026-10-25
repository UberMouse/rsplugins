-- The shops each shop-run chore can be done at, hand-written (data/chores.lua is generated).
-- A purchase at any of a chore's shops ticks it (see main.lua).
--
-- `inv` is the shop's inventory config name (config.Inv.<inv>), which is how the client tells
-- one shop from another: every shop has its own inventory, even shops selling the same
-- thing. `proven` marks a shop whose inventory a purchase in the beta client showed
-- (docs/api-concepts.md, "Shops in the client"); one picked from the client's inventory list
-- without that check would be `proven = false`.

---@class ChoreShop
---@field name string shown in the chore's tooltip
---@field inv string the shop inventory's config name
---@field proven boolean

---@type table<string, ChoreShop[]>
return {
    ["feather-shop-run"] = {
        { name = "Gerrant, Port Sarim", inv = "FISHINGSHOP", proven = true },
        { name = "Lumbridge Fishing Supplies", inv = "FISHINGSHOP_LUM", proven = true },
        { name = "Harry, Catherby", inv = "FISHINGSHOP2", proven = true },
        { name = "Shantay Pass", inv = "SHANTAYSHOP", proven = true },
    },
    ["vial-of-water-packs"] = {
        { name = "Jatix, Taverley", inv = "OMGE_HERBLORE_SHOP", proven = true },
        { name = "Obli, Shilo Village", inv = "SHILOJUNGLESTORE", proven = true },
        { name = "Lady Meilyr, Prifddinas", inv = "ELFCITY_MEILYR_SHOP", proven = true },
        { name = "Jossik, Lighthouse", inv = "LIGHTHOUSESHOP", proven = true },
    },
    ["yak-hide"] = {
        { name = "Vanligga, Jatizso", inv = "FRISD_YAK_CONTRABAND", proven = true },
    },
    ["feathers-of-ma-at"] = {
        { name = "Feathers of Ma'at, Sophanem", inv = "MENAPHOS_SLAYER_SHOP", proven = true },
    },
    ["broad-arrowheads"] = {
        { name = "Turael, Burthorpe", inv = "OMGE_SLAYERSHOP_SMKI", proven = true },
        { name = "Sumona, Pollnivneach", inv = "SMKI_SLAYERSHOP", proven = true },
    },
    ["rune-shop-run"] = {
        { name = "Aubury, Varrock", inv = "RUNESHOP", proven = true },
        { name = "Betty, Port Sarim", inv = "MAGICSHOP", proven = true },
        { name = "Ali Morrisane, Al Kharid", inv = "FEUD_MORRISANES", proven = true },
        { name = "Carwen Essencebinder", inv = "OMGE_RUNECRAFTING_SHOP", proven = true },
    },
}
