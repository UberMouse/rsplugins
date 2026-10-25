-- The shops each shop-run chore can be done at, hand-written (data/chores.lua is generated).
-- A purchase at any of a chore's shops ticks it (see main.lua).
--
-- `inv` is the shop's inventory config name (config.Inv.<inv>), which is how the client tells
-- one shop from another: every shop has its own inventory, even shops selling the same
-- thing. `proven` marks a shop whose inventory a purchase in the beta client showed
-- (docs/api-concepts.md, "Shops in the client"). An unproven one (`proven = false`) is a
-- shop from the wiki matched by name to an inventory in the client's own list (`pan Inv`);
-- it ticks the same way, but no purchase there has been seen yet.

---@class ChoreShop
---@field name string shown in the chore's tooltip
---@field inv string the shop inventory's config name
---@field proven boolean

---@type table<string, ChoreShop[]>
return {
    ["meat-packs"] = {
        -- As a First Resort is the quest that opens Chargurr's shop.
        { name = "Chargurr, Oo'glog", inv = "AFR_MEATSHOP", proven = false },
    },
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
        -- The Botanist's Workbench, a Fort Forinthry building.
        {
            name = "Granny Rowan, Fort Forinthry",
            inv = "PLAYER_FORT_BUILDINGS_BOTANISTS_SHOP",
            proven = false,
        },
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
    ["razmire-planks"] = {
        -- Razmire runs two shops; the planks are in the Builders' Merchants.
        { name = "Razmire Keelgan, Mort'ton", inv = "RAZMIREBUILDINGSTORE", proven = false },
    },
    ["rune-shop-run"] = {
        { name = "Aubury, Varrock", inv = "RUNESHOP", proven = true },
        { name = "Betty, Port Sarim", inv = "MAGICSHOP", proven = true },
        { name = "Ali Morrisane, Al Kharid", inv = "FEUD_MORRISANES", proven = true },
        { name = "Carwen Essencebinder", inv = "OMGE_RUNECRAFTING_SHOP", proven = true },
        -- The Void Knights' Outpost is Pest Control's island.
        { name = "Void Knight Magic Store", inv = "PEST_RUNE_STORE", proven = false },
        -- The guild's runes and staves store. The other, MAGICGUILDSHOP2, has Magic
        -- skillcape variants, so it is taken to be the robe store, which sells the cape.
        { name = "Magic Guild, Yanille", inv = "MAGICGUILDSHOP", proven = false },
        -- Ape Atoll is Monkey Madness's island.
        { name = "Tutab, Ape Atoll", inv = "MM_MAGIC_SHOP", proven = false },
        { name = "Lundail, Mage Arena", inv = "MAGEARENA_RUNESHOP", proven = false },
        -- Anachronia's base camp.
        { name = "Rune store, Anachronia", inv = "DINO_BASE_CAMP_RUNE_SHOP", proven = false },
    },
}
