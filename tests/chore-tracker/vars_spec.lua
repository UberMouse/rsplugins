-- core/vars (whether a var rule holds) and the hand-written rule list, data/vars.lua.

local support = require("tests.chore-tracker.support")
local catalog = require("tests.harness.catalog")
local chores = require("data/chores")
local varCore = require("core/vars")
local rules = require("data/vars")

-- The rule for chore `id` in data/vars.lua.
---@param id string
---@return table
local function ruleFor(id)
    for _, rule in ipairs(rules) do
        if rule.chore == id then return rule end
    end
    error("no rule for " .. id)
end

-- Every var a rule reads, at 0.
---@param rule table
---@return table<string, integer>
local function zeros(rule)
    local values = {}
    for _, name in ipairs(varCore.names(rule)) do
        values[name] = 0
    end
    return values
end

describe("chore-tracker vars core", function()
    it("counts RuneDays from 2002-02-27", function()
        -- PENG_SPY_PL_DAY read 9002 on Wednesday 2026-10-21.
        assert.are.equal(9002, varCore.runeDay(support.MINUTES["2026-10-21"]))
        assert.are.equal(9002, varCore.runeDay(support.MINUTES["2026-10-21"] + 1439))
        assert.are.equal(9006, varCore.runeDay(support.MINUTES["2026-10-25 01:43"]))
        assert.are.equal(0, varCore.runeDay(11745 * 1440))
    end)

    it("names each var a rule reads once, in order", function()
        local rule = {
            chore = "x",
            done = {
                { "A", ">=", 2 },
                { 0, ">", "S1" },
                { "B", "==", "A" },
                { "C", "==", { runeDay = true } },
            },
            proven = false,
        }
        assert.are.same({ "A", "S1", "B", "C" }, varCore.names(rule))
    end)

    it("compares a var with a number, another var or the RuneDay", function()
        local rule = {
            chore = "x",
            done = {
                { "A", "==", 1 },
                { "B", ">=", "C" },
                { "D", ">", 1 },
                { "E", "==", { runeDay = true } },
            },
            proven = false,
        }
        local values = { A = 1, B = 4, C = 4, D = 2, E = 9006 }
        assert.is_true(varCore.holds(rule, values, 9006))
        assert.is_false(varCore.holds(rule, values, 9007))
        -- Without a clock, a rule needing the RuneDay doesn't hold.
        assert.is_false(varCore.holds(rule, values, nil))
        values.C = 5
        assert.is_false(varCore.holds(rule, values, 9006))
    end)

    it("doesn't hold with a var missing", function()
        local rule = { chore = "x", done = { { "A", ">=", "B" } }, proven = true }
        assert.is_false(varCore.holds(rule, { A = 3 }, 1))
        assert.is_false(varCore.holds(rule, { B = 0 }, 1))
        assert.is_true(varCore.holds(rule, { A = 0, B = 0 }, 1))
    end)

    it("ticks on a change from false to true, with every var read before", function()
        local rule = { chore = "x", done = { { "A", "==", 1 }, { "B", "==", 0 } }, proven = true }
        assert.is_true(varCore.ticks(rule, { A = 0, B = 0 }, { A = 1, B = 0 }, nil))
        -- Already true before, or still false after.
        assert.is_false(varCore.ticks(rule, { A = 1, B = 0 }, { A = 1, B = 0 }, nil))
        assert.is_false(varCore.ticks(rule, { A = 0, B = 0 }, { A = 2, B = 0 }, nil))
        -- A first read (no value before) only sets the baseline.
        assert.is_false(varCore.ticks(rule, { B = 0 }, { A = 1, B = 0 }, nil))
    end)

    it("ticks a rule with only a rises var on a rise", function()
        local rule = { chore = "x", done = {}, rises = "N", proven = true }
        assert.are.same({ "N" }, varCore.names(rule))
        assert.is_true(varCore.ticks(rule, { N = 0 }, { N = 1 }, nil))
        assert.is_true(varCore.ticks(rule, { N = 500 }, { N = 501 }, nil))
        -- Again on a later rise: whether its chore is already done is the caller's concern.
        assert.is_true(varCore.ticks(rule, { N = 1 }, { N = 3 }, nil))
        assert.is_false(varCore.ticks(rule, { N = 3 }, { N = 3 }, nil))
        assert.is_false(varCore.ticks(rule, { N = 3 }, { N = 0 }, nil))
        -- A first read (no value before) only sets the baseline.
        assert.is_false(varCore.ticks(rule, {}, { N = 1 }, nil))
    end)

    it("ticks a rises rule with conditions on a rise while they hold after", function()
        local rule = { chore = "x", done = { { "S", ">", 0 } }, rises = "N", proven = true }
        assert.are.same({ "S", "N" }, varCore.names(rule))
        -- The conditions needn't have been false before.
        assert.is_true(varCore.ticks(rule, { N = 2, S = 1 }, { N = 3, S = 1 }, nil))
        assert.is_true(varCore.ticks(rule, { N = 2, S = 0 }, { N = 3, S = 1 }, nil))
        assert.is_false(varCore.ticks(rule, { N = 2, S = 1 }, { N = 3, S = 0 }, nil))
        -- The conditions turning true without a rise don't tick it.
        assert.is_false(varCore.ticks(rule, { N = 3, S = 0 }, { N = 3, S = 1 }, nil))
        -- A condition var read for the first time only sets the baseline.
        assert.is_false(varCore.ticks(rule, { N = 2 }, { N = 3, S = 1 }, nil))
    end)

    -- A rule without conditions holds on any values, so it's checked to have a rises var
    -- instead: only a rise ticks it, never all-zero values as such.
    it("holds no rule with conditions on all-zero vars but Advance Time's", function()
        for _, rule in ipairs(rules) do
            if #rule.done == 0 then
                assert(rule.rises, rule.chore .. " has neither conditions nor a rises var")
            else
                local holds = varCore.holds(rule, zeros(rule), 9006)
                assert.are.equal(rule.chore == "advance-time", holds, rule.chore)
            end
        end
    end)

    it("ticks the Daily Challenge when the claimed count rises", function()
        local rule = ruleFor("daily-challenge")
        assert.are.same({ "CHALLENGE_TOTAL_COMPLETED" }, varCore.names(rule))
        local before = { CHALLENGE_TOTAL_COMPLETED = 0 }
        assert.is_true(varCore.ticks(rule, before, { CHALLENGE_TOTAL_COMPLETED = 2 }, nil))
    end)

    it("holds a freebie on its flag, and Divine Locations on a reached limit", function()
        local bert = ruleFor("bert-sand")
        assert.is_true(varCore.holds(bert, { HANDSAND_BUCKETS_CLAIMED_TODAY = 1 }, nil))
        local div = ruleFor("divine-locations")
        assert.is_false(varCore.holds(div, { DIV_GATHER_LIMIT = 20, DIV_GATHERED = 19 }, nil))
        assert.is_true(varCore.holds(div, { DIV_GATHER_LIMIT = 20, DIV_GATHERED = 20 }, nil))
        assert.is_true(varCore.holds(div, { DIV_GATHER_LIMIT = 20, DIV_GATHERED = 25 }, nil))
    end)

    it("holds the Crystal Tree Blossom on today's RuneDay only", function()
        local rule = ruleFor("crystal-tree-blossom")
        local values = { ELFCITY_CRYSTAL_BLOSSOMS_LAST_DATE = 9006 }
        assert.is_true(varCore.holds(rule, values, 9006))
        assert.is_false(varCore.holds(rule, values, 9007))
        assert.is_false(varCore.holds(rule, values, nil))
    end)

    it("holds Thalmund's Wares with every slot bought up to a limit above 0", function()
        local rule = ruleFor("thalmunds-wares")
        local values = {}
        for n = 1, 4 do
            values["NECRO_HUB_THALMUND_SLOT_" .. n .. "_MAX"] = 5
            values["NECRO_HUB_THALMUND_SLOT_" .. n .. "_BOUGHT"] = 5
        end
        assert.is_true(varCore.holds(rule, values, nil))
        values.NECRO_HUB_THALMUND_SLOT_3_BOUGHT = 4
        assert.is_false(varCore.holds(rule, values, nil))
        values.NECRO_HUB_THALMUND_SLOT_3_BOUGHT = 5
        -- A slot with no limit isn't bought out at 0 >= 0.
        values.NECRO_HUB_THALMUND_SLOT_2_MAX = 0
        values.NECRO_HUB_THALMUND_SLOT_2_BOUGHT = 0
        assert.is_false(varCore.holds(rule, values, nil))
    end)

    it("holds Shattered Worlds only with all three reward challenges", function()
        local rule = ruleFor("shattered-worlds")
        local values = {
            SWORLDS_REWARD_CHALLENGE_BRONZE_COMPLETE = 1,
            SWORLDS_REWARD_CHALLENGE_SILVER_COMPLETE = 1,
            SWORLDS_REWARD_CHALLENGE_GOLD_COMPLETE = 0,
        }
        assert.is_false(varCore.holds(rule, values, nil))
        values.SWORLDS_REWARD_CHALLENGE_GOLD_COMPLETE = 1
        assert.is_true(varCore.holds(rule, values, nil))
    end)
end)

describe("chore-tracker var list", function()
    it("lists exactly the var chores, each in the chore list", function()
        local ids, byId = {}, {}
        for _, chore in ipairs(chores) do
            byId[chore.id] = chore
        end
        for _, rule in ipairs(rules) do
            assert(byId[rule.chore], "no chore " .. rule.chore)
            assert(type(rule.proven) == "boolean", rule.chore .. " has no proven flag")
            ids[#ids + 1] = rule.chore .. (rule.proven and "" or " (unproven)")
        end
        assert.are.same({
            "bert-sand",
            "geoffrey-flax",
            "cromperty-pure-essence",
            "coeden-logs",
            "daily-challenge",
            "advance-time (unproven)",
            "divine-locations (unproven)",
            "crystal-tree-blossom (unproven)",
            "sinkholes (unproven)",
            "big-chinchompa (unproven)",
            "fixate (unproven)",
            "runesphere (unproven)",
            "soul-reaper (unproven)",
            "thalmunds-wares (unproven)",
            "tears-of-guthix (unproven)",
            "herby-werby (unproven)",
            "wisps-of-the-grove (unproven)",
            "shattered-worlds (unproven)",
            "aquarium-treasure-chest (unproven)",
            "agoroth (unproven)",
            "broken-home (unproven)",
            "lupe (unproven)",
            "effigy-incubator (unproven)",
        }, ids)
    end)

    it("names only VarPlayer vars in the catalog, and none it must not read", function()
        for _, rule in ipairs(rules) do
            for _, name in ipairs(varCore.names(rule)) do
                assert(catalog.var("VarPlayer", name), name .. " is not in docs/vars/vars.csv")
                assert(name ~= "GODSS_PLAYER", "GODSS_PLAYER is another player's id")
                assert(not name:find("PENG"), name .. ": penguins are out of scope")
            end
        end
    end)
end)
