-- core/parts (each chore's parts, built from the data files) and data/counts.lua.

require("tests.chore-tracker.support")
local chores = require("data/chores")
local counts = require("data/counts")
local machines = require("data/machines")
local parts = require("core/parts")
local shops = require("data/shops")
local state = require("core/state")
local varRules = require("data/vars")

describe("chore-tracker parts", function()
    local built = parts.build(shops, varRules, machines, counts)

    it("gives each chore with a choice its parts and default, as the user set them", function()
        local got = {}
        for id, own in pairs(built) do
            if #own.list > 1 then
                local chore = assert(state.find(chores, id), id)
                got[id] = { #own.list, state.partsNeeded(state.new(), chore, own), own.noun }
            end
        end
        assert.are.same({
            ["herb-run"] = { 11, 8, "Patches" },
            ["bloodwood-tree"] = { 8, 1, "Trees" },
            ["player-owned-farm"] = { 7, 1, "Troughs" },
            ["penguin-hide-and-seek"] = { 13, 10, "Penguins" },
            ["player-owned-ports"] = { 4, 1, "Voyages" },
            ["invention-machine"] = { 6, 2, "Machines" },
            ["invention-machine-weekly"] = { 6, 2, "Machines" },
            ["thalmunds-wares"] = { 4, 4, "Slots" },
            ["shattered-worlds"] = { 3, 3, "Challenges" },
            ["broad-arrowheads"] = { 2, 2, "Shops" },
            ["feather-shop-run"] = { 4, 4, "Shops" },
            ["rune-shop-run"] = { 11, 11, "Shops" },
            ["vial-of-water-packs"] = { 5, 5, "Shops" },
        }, got)
    end)

    it("makes a shop's inventories one part, named, and other parts unnamed", function()
        local runes = built["rune-shop-run"]
        assert.are.equal("bought", runes.word)
        assert.are.same(
            { name = "Baba Yaga, Lunar Isle", keys = { "LUNAR_RUNESHOP", "LUNAR_RUNESHOP_COMPL" } },
            runes.list[10]
        )
        assert.are.equal("done", built["herb-run"].word)
        for _, part in ipairs(built["herb-run"].list) do
            assert.is_nil(part.name)
        end
        assert.are.same(
            { keys = { "INVENT_MACHINE_GUILD_1_OUTPUT" } },
            built["invention-machine"].list[1]
        )
    end)

    it(
        "leaves the port's market rule out of its parts, and chores whose rules are alternatives",
        function()
            for _, part in ipairs(built["player-owned-ports"].list) do
                assert.matches("^POP_VOYAGE_%d_DONE$", part.keys[1])
            end
            assert.is_nil(built["fort-forinthry-bonus-xp"])
            assert.is_nil(built["arc-contracts"])
        end
    )

    it("fails naming a chore with parts that counts lacks, or a count for one without", function()
        local rule = { chore = "x", done = {}, part = "A", proven = true }
        assert.has_error(function()
            parts.build({}, { rule }, {}, {})
        end, "data/counts.lua lacks x, which has parts")
        assert.has_error(function()
            parts.build({}, {}, {}, { y = { noun = "Ys" } })
        end, "data/counts.lua names y, which has no parts")
        -- A key named by two rules is one part.
        local twice = parts.build({}, { rule, rule }, {}, { x = { noun = "Xs" } })
        assert.are.equal(1, #twice.x.list)
    end)

    it("keeps every default within its chore's parts", function()
        for id, count in pairs(counts) do
            if count.default then
                assert(count.default >= 1 and count.default <= #built[id].list, id)
            end
        end
    end)
end)
