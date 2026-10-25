-- core/shops (spotting a purchase in a shop's counts) and the hand-written shop list,
-- data/shops.lua.

require("tests.chore-tracker.support")
local catalog = require("tests.harness.catalog")
local chores = require("data/chores")
local shopCore = require("core/shops")
local shops = require("data/shops")

describe("chore-tracker shops core", function()
    it("indexes shops by inventory, each with its chore", function()
        local a = { name = "A", inv = "INV_A", proven = true }
        local b = { name = "B", inv = "INV_B", proven = false }
        local index = shopCore.index({ two = { a, b }, one = { b } })
        assert.are.same({ { chore = "two", shop = a } }, index.INV_A)
        -- Sorted by chore id, so the order purchases apply in is fixed.
        assert.are.same({ { chore = "one", shop = b }, { chore = "two", shop = b } }, index.INV_B)
    end)

    it("sees a purchase only in a count that drops", function()
        assert.is_true(shopCore.dropped({ 20, 5 }, { 20, 4 }))
        assert.is_true(shopCore.dropped({ 20, 5 }, { 0, 5 }))
        assert.is_false(shopCore.dropped({ 20, 5 }, { 20, 5 }))
        assert.is_false(shopCore.dropped({ 20, 5 }, { 25, 6 }))
        -- A slot only one side has (a shop that grew a line) isn't compared.
        assert.is_false(shopCore.dropped({ 20 }, { 20, 3 }))
        assert.is_false(shopCore.dropped({ 20, 3 }, { 20 }))
    end)
end)

describe("chore-tracker shop list", function()
    it("names only chores in the chore list, each a shop chore", function()
        for id in pairs(shops) do
            local found = nil
            for _, chore in ipairs(chores) do
                if chore.id == id then found = chore end
            end
            assert(found, "no chore " .. id)
            assert(found.shop, id .. " is not a shop chore")
        end
    end)

    it("names only inventories the client has, each once", function()
        local seen = {}
        for id, list in pairs(shops) do
            assert(#list > 0, id .. " has no shops")
            for _, shop in ipairs(list) do
                assert(catalog.config("Inv", shop.inv), shop.inv .. " is not in docs/api/consts")
                assert(type(shop.name) == "string" and shop.name ~= "", shop.inv .. " unnamed")
                assert(type(shop.proven) == "boolean", shop.inv .. " has no proven flag")
                assert(seen[shop.inv] == nil, shop.inv .. " is listed twice")
                seen[shop.inv] = true
            end
        end
    end)

    it("lists the shops a purchase in the client proved", function()
        local proven = {}
        for id, list in pairs(shops) do
            for _, shop in ipairs(list) do
                if shop.proven then
                    proven[id] = proven[id] or {}
                    table.insert(proven[id], shop.inv)
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
            ["rune-shop-run"] = {
                "RUNESHOP",
                "MAGICSHOP",
                "FEUD_MORRISANES",
                "OMGE_RUNECRAFTING_SHOP",
            },
        }, proven)
    end)
end)
