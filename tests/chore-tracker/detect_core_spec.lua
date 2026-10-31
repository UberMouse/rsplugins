-- core/detect (spotting a purchase in a shop's counts) and the hand-written shop list,
-- data/shops.lua.

require("tests.chore-tracker.support")
local catalog = require("tests.harness.catalog")
local chores = require("data/chores")
local detect = require("core/detect")
local shops = require("data/shops")

describe("chore-tracker shops core", function()
    it("indexes shops by inventory, each with its chore", function()
        local a = { name = "A", invs = { "INV_A" }, proven = true }
        local b = { name = "B", invs = { "INV_B" }, proven = false }
        local c = { name = "C", invs = { "INV_C1", "INV_C2" }, proven = false }
        local index = detect.index({ two = { a, b }, one = { b }, three = { c } })
        assert.are.same({ { chore = "two", shop = a } }, index.INV_A)
        -- Each of a shop's inventories leads to the same shop.
        assert.are.same({ { chore = "three", shop = c } }, index.INV_C1)
        assert.are.same({ { chore = "three", shop = c } }, index.INV_C2)
        -- Sorted by chore id, so the order purchases apply in is fixed.
        assert.are.same({ { chore = "one", shop = b }, { chore = "two", shop = b } }, index.INV_B)
    end)

    it("sees a purchase only in a count that drops", function()
        assert.is_true(detect.dropped({ 20, 5 }, { 20, 4 }))
        assert.is_true(detect.dropped({ 20, 5 }, { 0, 5 }))
        assert.is_false(detect.dropped({ 20, 5 }, { 20, 5 }))
        assert.is_false(detect.dropped({ 20, 5 }, { 25, 6 }))
        -- A slot only one side has (a shop that grew a line) isn't compared.
        assert.is_false(detect.dropped({ 20 }, { 20, 3 }))
        assert.is_false(detect.dropped({ 20, 3 }, { 20 }))
    end)

    it("sees a collect in a total that falls, however the slots changed", function()
        assert.is_true(detect.fell({ 7500 }, { 0 }))
        -- Collecting may leave the slot out altogether.
        assert.is_true(detect.fell({ 7500 }, {}))
        assert.is_true(detect.fell({ 10, 5 }, { 12 }))
        -- A machine working (a rise) or moving goods between slots is no collect.
        assert.is_false(detect.fell({ 10 }, { 15 }))
        assert.is_false(detect.fell({ 10, 5 }, { 5, 10 }))
        assert.is_false(detect.fell({}, {}))
    end)

    it("sees a rise in any named count", function()
        local both = { "A", "B" }
        assert.is_true(detect.rose({ A = 0, B = 5 }, { A = 30, B = 5 }, both))
        assert.is_false(detect.rose({ A = 30, B = 5 }, { A = 0, B = 5 }, both))
        assert.is_false(detect.rose({ A = 3 }, { A = 3, B = 9 }, both))
        -- Only the names asked about count.
        assert.is_false(detect.rose({ A = 0, B = 5 }, { A = 30, B = 5 }, { "B" }))
    end)

    it("is near within the range on each axis, on the same plane only", function()
        local spot = { x = 2763, z = 3186, level = 0 }
        assert.is_true(detect.near({ x = 2763, z = 3186, level = 0 }, spot, 10))
        assert.is_true(detect.near({ x = 2773, z = 3176, level = 0 }, spot, 10))
        assert.is_false(detect.near({ x = 2774, z = 3186, level = 0 }, spot, 10))
        assert.is_false(detect.near({ x = 2763, z = 3175, level = 0 }, spot, 10))
        assert.is_false(detect.near({ x = 2763, z = 3186, level = 1 }, spot, 10))
    end)
end)

describe("chore-tracker shop list", function()
    it("names only chores in the chore list, each in the Shops category", function()
        for id in pairs(shops) do
            local found = nil
            for _, chore in ipairs(chores) do
                if chore.id == id then found = chore end
            end
            assert(found, "no chore " .. id)
            assert(found.category == "shops", id .. " is not a shop chore")
        end
    end)

    it("names only inventories the client has, each once", function()
        local seen = {}
        for id, list in pairs(shops) do
            assert(#list > 0, id .. " has no shops")
            for _, shop in ipairs(list) do
                assert(
                    type(shop.name) == "string" and shop.name ~= "",
                    id .. " has an unnamed shop"
                )
                assert(type(shop.proven) == "boolean", shop.name .. " has no proven flag")
                assert(#shop.invs > 0, shop.name .. " has no inventory")
                for _, inv in ipairs(shop.invs) do
                    assert(catalog.config("Inv", inv), inv .. " is not in docs/api/consts")
                    assert(seen[inv] == nil, inv .. " is listed twice")
                    seen[inv] = true
                end
            end
        end
    end)

    it("lists the shops a purchase in the client proved", function()
        local proven = {}
        for id, list in pairs(shops) do
            for _, shop in ipairs(list) do
                if shop.proven then
                    proven[id] = proven[id] or {}
                    table.insert(proven[id], table.concat(shop.invs, "+"))
                end
            end
        end
        assert.are.same({
            ["feather-shop-run"] = {
                "FISHINGSHOP",
                "FISHINGSHOP_LUM",
                "FISHINGSHOP2",
                "SHANTAYSHOP",
            },
            ["vial-of-water-packs"] = {
                "OMGE_HERBLORE_SHOP",
                "SHILOJUNGLESTORE",
                "ELFCITY_MEILYR_SHOP",
                "LIGHTHOUSESHOP",
            },
            ["yak-hide"] = { "FRISD_YAK_CONTRABAND" },
            ["feathers-of-ma-at"] = { "MENAPHOS_SLAYER_SHOP" },
            ["broad-arrowheads"] = { "OMGE_SLAYERSHOP_SMKI", "SMKI_SLAYERSHOP" },
            ["seaweed-and-pineapples"] = { "ARHEINSTORE" },
            ["rune-shop-run"] = {
                "RUNESHOP",
                "MAGICSHOP",
                "FEUD_MORRISANES",
                "OMGE_RUNECRAFTING_SHOP",
                "PEST_RUNE_STORE",
                "MAGICGUILDSHOP",
            },
        }, proven)
    end)

    it("lists the unproven shops matched from the wiki, after the proven ones", function()
        local unproven = {}
        for id, list in pairs(shops) do
            local seenUnproven = false
            for _, shop in ipairs(list) do
                if shop.proven then
                    assert(not seenUnproven, id .. " lists a proven shop after an unproven one")
                else
                    seenUnproven = true
                    unproven[id] = unproven[id] or {}
                    table.insert(unproven[id], table.concat(shop.invs, "+"))
                end
            end
        end
        assert.are.same({
            ["meat-packs"] = { "AFR_MEATSHOP" },
            ["vial-of-water-packs"] = { "PLAYER_FORT_BUILDINGS_BOTANISTS_SHOP" },
            ["razmire-planks"] = { "RAZMIREBUILDINGSTORE" },
            ["rune-shop-run"] = {
                "MM_MAGIC_SHOP",
                "MAGEARENA_RUNESHOP",
                "DINO_BASE_CAMP_RUNE_SHOP",
                "LUNAR_RUNESHOP+LUNAR_RUNESHOP_COMPL",
                "DARKRUNESHOP_CRAP+DARKRUNESHOP_UBER",
            },
        }, unproven)
    end)
end)

describe("chore-tracker collections list", function()
    local collections = require("data/collections")

    it("names chores in the chore list and banknotes the client has", function()
        local byId = {}
        for _, chore in ipairs(chores) do
            byId[chore.id] = chore
        end
        local ids = {}
        for _, c in ipairs(collections) do
            assert(byId[c.chore], "no chore " .. c.chore)
            assert(#c.notes > 0, c.chore .. " has no notes")
            for _, name in ipairs(c.notes) do
                assert(catalog.config("Obj", name), name .. " is not in docs/api/consts")
            end
            assert(type(c.proven) == "boolean", c.chore .. " has no proven flag")
            ids[#ids + 1] = c.chore
        end
        assert.are.same({ "dellmonti-pineapples", "oldman-potato-cactus" }, ids)
    end)
end)
