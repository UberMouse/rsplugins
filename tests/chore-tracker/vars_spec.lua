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
                { "A", ">=", { nonZero = { "S1", "S2" } } },
                { { nonZero = { "S1", "S2" } }, ">", 0 },
                { "B", "==", "A" },
                { "C", "==", { runeDay = true } },
            },
            proven = false,
        }
        assert.are.same({ "A", "S1", "S2", "B", "C" }, varCore.names(rule))
    end)

    it("compares a var with a number, another var, a count or the RuneDay", function()
        local rule = {
            chore = "x",
            done = {
                { "A", "==", 1 },
                { "B", ">=", "C" },
                { "D", ">", { nonZero = { "S1", "S2" } } },
                { "E", "==", { runeDay = true } },
            },
            proven = false,
        }
        local values = { A = 1, B = 4, C = 4, D = 2, S1 = 7, S2 = 0, E = 9006 }
        assert.is_true(varCore.holds(rule, values, 9006))
        assert.is_false(varCore.holds(rule, values, 9007))
        -- Without a clock, a rule needing the RuneDay doesn't hold.
        assert.is_false(varCore.holds(rule, values, nil))
        values.S2 = 3
        assert.is_false(varCore.holds(rule, values, 9006))
    end)

    it("doesn't hold with a var missing", function()
        local rule =
            { chore = "x", done = { { "A", ">=", { nonZero = { "S1" } } } }, proven = true }
        assert.is_false(varCore.holds(rule, { A = 3 }, 1))
        assert.is_false(varCore.holds(rule, { S1 = 0 }, 1))
        assert.is_true(varCore.holds(rule, { A = 0, S1 = 0 }, 1))
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

    it("ticks a rule with a rises var only when that var went up", function()
        local rule = {
            chore = "x",
            done = { { "N", ">=", "S" }, { "S", ">", 0 } },
            rises = "N",
            proven = true,
        }
        assert.are.same({ "N", "S" }, varCore.names(rule))
        assert.is_true(varCore.ticks(rule, { N = 2, S = 3 }, { N = 3, S = 3 }, nil))
        -- True again on S refilling, but N stayed put or fell.
        assert.is_false(varCore.ticks(rule, { N = 3, S = 0 }, { N = 3, S = 3 }, nil))
        assert.is_false(varCore.ticks(rule, { N = 5, S = 0 }, { N = 4, S = 3 }, nil))
        -- A rises var not otherwise read is still named.
        local only = { chore = "x", done = { { "S", ">", 0 } }, rises = "N", proven = true }
        assert.are.same({ "S", "N" }, varCore.names(only))
    end)

    it("holds no rule on all-zero vars but Advance Time's", function()
        for _, rule in ipairs(rules) do
            local holds = varCore.holds(rule, zeros(rule), 9006)
            assert.are.equal(rule.chore == "advance-time", holds, rule.chore)
        end
    end)

    it("holds the Daily Challenge when every filled slot is finished", function()
        local rule = ruleFor("daily-challenge")
        local values = zeros(rule)
        values.OMGE_CHALLENGE_CURRENT_ID_1 = 2
        values.OMGE_CHALLENGE_CURRENT_ID_2 = 2
        values.OMGE_CHALLENGE_CURRENT_ID_3 = 3
        values.INTERN_NOTES_DAILY_CHALLENGES_COMPLETE = 2
        assert.is_false(varCore.holds(rule, values, nil))
        values.INTERN_NOTES_DAILY_CHALLENGES_COMPLETE = 3
        assert.is_true(varCore.holds(rule, values, nil))
        values.OMGE_CHALLENGE_CURRENT_ID_4 = 5
        assert.is_false(varCore.holds(rule, values, nil))
        values.INTERN_NOTES_DAILY_CHALLENGES_COMPLETE = 4
        assert.is_true(varCore.holds(rule, values, nil))
    end)

    it("holds a freebie on its flag, and Divine Locations on a reached limit", function()
        local bert = ruleFor("bert-sand")
        assert.is_true(varCore.holds(bert, { HANDSAND_BUCKETS_CLAIMED_TODAY = 1 }, nil))
        local div = ruleFor("divine-locations")
        assert.is_false(varCore.holds(div, { DIV_GATHER_LIMIT = 20, DIV_GATHERED = 19 }, nil))
        assert.is_true(varCore.holds(div, { DIV_GATHER_LIMIT = 20, DIV_GATHERED = 20 }, nil))
        assert.is_true(varCore.holds(div, { DIV_GATHER_LIMIT = 20, DIV_GATHERED = 25 }, nil))
    end)
end)

describe("chore-tracker var list", function()
    it("lists exactly the stage-1 chores, each in the chore list", function()
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
