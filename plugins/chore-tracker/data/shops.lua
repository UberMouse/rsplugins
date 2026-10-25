-- The shops each shop-run chore can be done at, hand-written (data/chores.lua is generated).
-- A purchase at any of a chore's shops ticks it (see shell/detect.lua).
--
-- `invs` are the shop's inventory config names (config.Inv.<name>), which is how the client
-- tells one shop from another: every shop has its own inventory, even shops selling the
-- same thing. A shop with two, one before a quest and one after, counts as bought on a
-- purchase in either. `proven` marks a shop where a purchase was seen in the beta client
-- (docs/api-concepts.md, "Shops in the client"). An unproven one (`proven = false`) is a
-- shop from the wiki matched by name to inventories in the client's own list (`pan Inv`);
-- it ticks the same way, but no purchase there has been seen yet.

---@class ChoreShop
---@field name string shown in the chore's tooltip
---@field invs string[] the shop's inventory config names
---@field proven boolean

---@type table<string, ChoreShop[]>
return {
    ["meat-packs"] = {
        -- As a First Resort is the quest that opens Chargurr's shop.
        { name = "Chargurr, Oo'glog", invs = { "AFR_MEATSHOP" }, proven = false },
    },
    ["feather-shop-run"] = {
        { name = "Gerrant, Port Sarim", invs = { "FISHINGSHOP" }, proven = true },
        { name = "Lumbridge Fishing Supplies", invs = { "FISHINGSHOP_LUM" }, proven = true },
        { name = "Harry, Catherby", invs = { "FISHINGSHOP2" }, proven = true },
        { name = "Shantay Pass", invs = { "SHANTAYSHOP" }, proven = true },
    },
    ["vial-of-water-packs"] = {
        { name = "Jatix, Taverley", invs = { "OMGE_HERBLORE_SHOP" }, proven = true },
        { name = "Obli, Shilo Village", invs = { "SHILOJUNGLESTORE" }, proven = true },
        { name = "Lady Meilyr, Prifddinas", invs = { "ELFCITY_MEILYR_SHOP" }, proven = true },
        { name = "Jossik, Lighthouse", invs = { "LIGHTHOUSESHOP" }, proven = true },
        -- The Botanist's Workbench, a Fort Forinthry building.
        {
            name = "Granny Rowan, Fort Forinthry",
            invs = { "PLAYER_FORT_BUILDINGS_BOTANISTS_SHOP" },
            proven = false,
        },
    },
    ["yak-hide"] = {
        { name = "Vanligga, Jatizso", invs = { "FRISD_YAK_CONTRABAND" }, proven = true },
    },
    ["feathers-of-ma-at"] = {
        {
            name = "Feathers of Ma'at, Sophanem",
            invs = { "MENAPHOS_SLAYER_SHOP" },
            proven = true,
        },
    },
    ["broad-arrowheads"] = {
        { name = "Turael, Burthorpe", invs = { "OMGE_SLAYERSHOP_SMKI" }, proven = true },
        { name = "Sumona, Pollnivneach", invs = { "SMKI_SLAYERSHOP" }, proven = true },
    },
    ["razmire-planks"] = {
        -- Razmire runs two shops; the planks are in the Builders' Merchants.
        {
            name = "Razmire Keelgan, Mort'ton",
            invs = { "RAZMIREBUILDINGSTORE" },
            proven = false,
        },
    },
    ["rune-shop-run"] = {
        { name = "Aubury, Varrock", invs = { "RUNESHOP" }, proven = true },
        { name = "Betty, Port Sarim", invs = { "MAGICSHOP" }, proven = true },
        { name = "Ali Morrisane, Al Kharid", invs = { "FEUD_MORRISANES" }, proven = true },
        { name = "Carwen Essencebinder", invs = { "OMGE_RUNECRAFTING_SHOP" }, proven = true },
        { name = "Void Knight Magic Store", invs = { "PEST_RUNE_STORE" }, proven = true },
        -- The guild's runes and staves store. The other, MAGICGUILDSHOP2, has Magic
        -- skillcape variants, so it is taken to be the robe store, which sells the cape.
        { name = "Magic Guild, Yanille", invs = { "MAGICGUILDSHOP" }, proven = true },
        -- Ape Atoll is Monkey Madness's island.
        { name = "Tutab, Ape Atoll", invs = { "MM_MAGIC_SHOP" }, proven = false },
        { name = "Lundail, Mage Arena", invs = { "MAGEARENA_RUNESHOP" }, proven = false },
        -- Anachronia's base camp.
        {
            name = "Rune store, Anachronia",
            invs = { "DINO_BASE_CAMP_RUNE_SHOP" },
            proven = false,
        },
        -- The wiki gives both shops a stock before their quest (Lunar Diplomacy; Enter the
        -- Abyss) and one after, which reads as the two inventories each.
        {
            name = "Baba Yaga, Lunar Isle",
            invs = { "LUNAR_RUNESHOP", "LUNAR_RUNESHOP_COMPL" },
            proven = false,
        },
        {
            name = "Mage of Zamorak, Wilderness",
            invs = { "DARKRUNESHOP_CRAP", "DARKRUNESHOP_UBER" },
            proven = false,
        },
    },
}
