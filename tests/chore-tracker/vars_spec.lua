-- core/vars (whether a var rule holds) and the hand-written rule list, data/vars.lua.

local catalog = require("tests.harness.catalog")
local chores = require("data/chores")
local varsCore = require("core/vars")
local varRules = require("data/vars")

-- The rule for chore `id` in data/vars.lua.
---@param id string
---@return table
local function ruleFor(id)
    for _, rule in ipairs(varRules) do
        if rule.chore == id then return rule end
    end
    error("no rule for " .. id)
end

-- Every var a rule reads, at 0.
---@param rule table
---@return table<string, integer>
local function zeros(rule)
    local values = {}
    for _, name in ipairs(varsCore.names(rule)) do
        values[name] = 0
    end
    return values
end

describe("chore-tracker vars core", function()
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
        assert.are.same({ "A", "S1", "B", "C" }, varsCore.names(rule))
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
        assert.is_true(varsCore.holds(rule, values, 9006))
        assert.is_false(varsCore.holds(rule, values, 9007))
        -- Without a clock, a rule needing the RuneDay doesn't hold.
        assert.is_false(varsCore.holds(rule, values, nil))
        values.C = 5
        assert.is_false(varsCore.holds(rule, values, 9006))
    end)

    it("doesn't hold with a var missing", function()
        local rule = { chore = "x", done = { { "A", ">=", "B" } }, proven = true }
        assert.is_false(varsCore.holds(rule, { A = 3 }, 1))
        assert.is_false(varsCore.holds(rule, { B = 0 }, 1))
        assert.is_true(varsCore.holds(rule, { A = 0, B = 0 }, 1))
    end)

    it("ticks on a change from false to true, with every var read before", function()
        local rule = { chore = "x", done = { { "A", "==", 1 }, { "B", "==", 0 } }, proven = true }
        assert.is_true(varsCore.ticks(rule, { A = 0, B = 0 }, { A = 1, B = 0 }, nil))
        -- Already true before, or still false after.
        assert.is_false(varsCore.ticks(rule, { A = 1, B = 0 }, { A = 1, B = 0 }, nil))
        assert.is_false(varsCore.ticks(rule, { A = 0, B = 0 }, { A = 2, B = 0 }, nil))
        -- A first read (no value before) only sets the baseline.
        assert.is_false(varsCore.ticks(rule, { B = 0 }, { A = 1, B = 0 }, nil))
    end)

    it("ticks a rule with only a rises var on a rise", function()
        local rule = { chore = "x", done = {}, rises = "N", proven = true }
        assert.are.same({ "N" }, varsCore.names(rule))
        assert.is_true(varsCore.ticks(rule, { N = 0 }, { N = 1 }, nil))
        assert.is_true(varsCore.ticks(rule, { N = 500 }, { N = 501 }, nil))
        -- Again on a later rise: whether its chore is already done is the caller's concern.
        assert.is_true(varsCore.ticks(rule, { N = 1 }, { N = 3 }, nil))
        assert.is_false(varsCore.ticks(rule, { N = 3 }, { N = 3 }, nil))
        assert.is_false(varsCore.ticks(rule, { N = 3 }, { N = 0 }, nil))
        -- A first read (no value before) only sets the baseline.
        assert.is_false(varsCore.ticks(rule, {}, { N = 1 }, nil))
    end)

    it("ticks a rises rule with conditions on a rise while they hold after", function()
        local rule = { chore = "x", done = { { "S", ">", 0 } }, rises = "N", proven = true }
        assert.are.same({ "S", "N" }, varsCore.names(rule))
        -- The conditions needn't have been false before.
        assert.is_true(varsCore.ticks(rule, { N = 2, S = 1 }, { N = 3, S = 1 }, nil))
        assert.is_true(varsCore.ticks(rule, { N = 2, S = 0 }, { N = 3, S = 1 }, nil))
        assert.is_false(varsCore.ticks(rule, { N = 2, S = 1 }, { N = 3, S = 0 }, nil))
        -- The conditions turning true without a rise don't tick it.
        assert.is_false(varsCore.ticks(rule, { N = 3, S = 0 }, { N = 3, S = 1 }, nil))
        -- A condition var read for the first time only sets the baseline.
        assert.is_false(varsCore.ticks(rule, { N = 2 }, { N = 3, S = 1 }, nil))
    end)

    -- A rule without conditions holds on any values, so it's checked to have a rises var
    -- instead: only a rise ticks it, never all-zero values as such.
    it("holds no rule with conditions on all-zero vars but Advance Time's", function()
        for _, rule in ipairs(varRules) do
            if #rule.done == 0 then
                assert(rule.rises, rule.chore .. " has neither conditions nor a rises var")
            else
                local holds = varsCore.holds(rule, zeros(rule), 9006)
                assert.are.equal(rule.chore == "advance-time", holds, rule.chore)
            end
        end
    end)

    it("holds an any group when a member does, never when it is empty or unreadable", function()
        local rule = {
            chore = "x",
            done = { { any = { { "A", "==", 1 }, { "B", "==", 1 } } } },
            proven = true,
        }
        assert.is_true(varsCore.holds(rule, { A = 0, B = 1 }, nil))
        assert.is_false(varsCore.holds(rule, { A = 0, B = 0 }, nil))
        -- A member with no value doesn't hold, but another can.
        assert.is_true(varsCore.holds(rule, { B = 1 }, nil))
        assert.is_false(varsCore.holds(rule, {}, nil))
        local clock = {
            chore = "x",
            done = { { any = { { "A", "==", { runeDay = true } } } } },
            proven = true,
        }
        assert.is_false(varsCore.holds(clock, { A = 5 }, nil))
        assert.is_false(
            varsCore.holds({ chore = "x", done = { { any = {} } }, proven = true }, {}, nil)
        )
    end)

    it("names the vars in any groups and falls once, in order", function()
        local rule = {
            chore = "x",
            done = { { "A", ">", 0 }, { any = { { "B", "==", 0 }, { "A", "==", "C" } } } },
            falls = { "D", "B" },
            proven = true,
        }
        assert.are.same({ "A", "B", "C", "D" }, varsCore.names(rule))
    end)

    it("ticks a falls rule only when it turns true and a listed var went down", function()
        local rule = {
            chore = "x",
            done = { { "W", ">", 0 }, { "S", "==", 0 } },
            falls = { "S" },
            proven = true,
        }
        assert.is_true(varsCore.ticks(rule, { W = 1, S = 5 }, { W = 1, S = 0 }, nil))
        -- The conditions turned true without a fall (workers moved).
        assert.is_false(varsCore.ticks(rule, { W = 1, S = 0 }, { W = 1, S = 0 }, nil))
        assert.is_false(varsCore.ticks(rule, { W = 0, S = 0 }, { W = 1, S = 0 }, nil))
        -- A rise, or a first read, never ticks.
        assert.is_false(varsCore.ticks(rule, { W = 1, S = 0 }, { W = 1, S = 4 }, nil))
        assert.is_false(varsCore.ticks(rule, { W = 1 }, { W = 1, S = 0 }, nil))
    end)

    it("gives no rule both rises and falls", function()
        for _, rule in ipairs(varRules) do
            assert(not (rule.rises and rule.falls), rule.chore)
        end
    end)

    for _, kind in ipairs({ "resource", "xp" }) do
        describe("Dream of Iaia " .. kind, function()
            local stations = {
                WOOD = "FLETCHING",
                VINES = "HUNTER",
                LEAVES = "HERBLORE",
                PELTS = "CRAFTING",
                STONE = "CONSTRUCTION",
                CLAY = "FISHING",
            }
            local order = { "WOOD", "VINES", "LEAVES", "PELTS", "STONE", "CLAY" }
            local rule = ruleFor("dream-of-iaia-" .. kind)

            -- The stock var drained for resource R.
            local function stockName(r)
                if kind == "resource" then return "DINO_BASE_CAMP_RESOURCE_" .. r end
                return "QUEST_EGW_FINALE_REWARD_STATION_XP_" .. stations[r]
            end

            -- Values with `workers` (resource -> count) set and every stock at 100.
            local function world(workers)
                local v = {}
                for _, r in ipairs(order) do
                    v["DINO_BASE_CAMP_WORKER_ASSIGNED_" .. r] = workers[r] or 0
                    v[stockName(r)] = 100
                end
                return v
            end

            local function with(v, changes)
                local out = {}
                for k, x in pairs(v) do
                    out[k] = x
                end
                for k, x in pairs(changes) do
                    out[k] = x
                end
                return out
            end

            it("is shared by the chore's other period", function()
                local other = ruleFor(
                    kind == "resource" and "dream-of-iaia-resource-daily"
                        or "dream-of-iaia-xp-weekly"
                )
                assert.are.equal(rule.done, other.done)
                assert.are.equal(rule.falls, other.falls)
            end)

            it("never holds with no workers", function()
                local v = world({})
                for _, r in ipairs(order) do
                    v[stockName(r)] = 0
                end
                assert.is_false(varsCore.holds(rule, v, nil))
            end)

            it("doesn't tick while one worked station is still above 0", function()
                local before = world({ STONE = 40, WOOD = 30 })
                local after = with(before, { [stockName("STONE")] = 0 })
                assert.is_false(varsCore.ticks(rule, before, after, nil))
            end)

            it("ticks when the last worked station is drained, ignoring unworked ones", function()
                local before = world({ STONE = 40, WOOD = 30 })
                before[stockName("WOOD")] = 0
                local after = with(before, { [stockName("STONE")] = 0 })
                assert.is_true(varsCore.ticks(rule, before, after, nil))
            end)

            it("doesn't tick when workers move so every worked station reads 0", function()
                local before = world({ STONE = 70 })
                before[stockName("CLAY")] = 0
                local after = with(before, {
                    DINO_BASE_CAMP_WORKER_ASSIGNED_STONE = 0,
                    DINO_BASE_CAMP_WORKER_ASSIGNED_CLAY = 70,
                })
                assert.is_true(varsCore.holds(rule, after, nil))
                assert.is_false(varsCore.ticks(rule, before, after, nil))
            end)

            it("doesn't tick on draining an unworked station once the worked ones are 0", function()
                local before = world({ STONE = 70 })
                before[stockName("STONE")] = 0
                local after = with(before, { [stockName("WOOD")] = 0 })
                assert.is_false(varsCore.ticks(rule, before, after, nil))
            end)

            it("doesn't tick when a worked station rises", function()
                local before = world({ STONE = 70 })
                before[stockName("STONE")] = 0
                local after = with(before, { [stockName("STONE")] = 50 })
                assert.is_false(varsCore.ticks(rule, before, after, nil))
            end)

            it("treats a var's first read as a baseline", function()
                local after = world({ STONE = 70 })
                after[stockName("STONE")] = 0
                local before = with(world({ STONE = 70 }), {})
                before[stockName("STONE")] = nil
                assert.is_false(varsCore.ticks(rule, before, after, nil))
            end)
        end)
    end

    it("ticks the Daily Challenge when the claimed count rises", function()
        local rule = ruleFor("daily-challenge")
        assert.are.same({ "CHALLENGE_TOTAL_COMPLETED" }, varsCore.names(rule))
        local before = { CHALLENGE_TOTAL_COMPLETED = 0 }
        assert.is_true(varsCore.ticks(rule, before, { CHALLENGE_TOTAL_COMPLETED = 2 }, nil))
    end)

    it("holds a freebie on its flag, and Divine Locations on a reached limit", function()
        local bert = ruleFor("bert-sand")
        assert.is_true(varsCore.holds(bert, { HANDSAND_BUCKETS_CLAIMED_TODAY = 1 }, nil))
        local div = ruleFor("divine-locations")
        assert.is_false(varsCore.holds(div, { DIV_GATHER_LIMIT = 20, DIV_GATHERED = 19 }, nil))
        assert.is_true(varsCore.holds(div, { DIV_GATHER_LIMIT = 20, DIV_GATHERED = 20 }, nil))
        assert.is_true(varsCore.holds(div, { DIV_GATHER_LIMIT = 20, DIV_GATHERED = 25 }, nil))
    end)

    it("holds the Crystal Tree Blossom on today's RuneDay only", function()
        local rule = ruleFor("crystal-tree-blossom")
        local values = { ELFCITY_CRYSTAL_BLOSSOMS_LAST_DATE = 9006 }
        assert.is_true(varsCore.holds(rule, values, 9006))
        assert.is_false(varsCore.holds(rule, values, 9007))
        assert.is_false(varsCore.holds(rule, values, nil))
    end)

    it("holds Thalmund's Wares with every slot bought up to a limit above 0", function()
        local rule = ruleFor("thalmunds-wares")
        local values = {}
        for n = 1, 4 do
            values["NECRO_HUB_THALMUND_SLOT_" .. n .. "_MAX"] = 5
            values["NECRO_HUB_THALMUND_SLOT_" .. n .. "_BOUGHT"] = 5
        end
        assert.is_true(varsCore.holds(rule, values, nil))
        values.NECRO_HUB_THALMUND_SLOT_3_BOUGHT = 4
        assert.is_false(varsCore.holds(rule, values, nil))
        values.NECRO_HUB_THALMUND_SLOT_3_BOUGHT = 5
        -- A slot with no limit isn't bought out at 0 >= 0.
        values.NECRO_HUB_THALMUND_SLOT_2_MAX = 0
        values.NECRO_HUB_THALMUND_SLOT_2_BOUGHT = 0
        assert.is_false(varsCore.holds(rule, values, nil))
    end)

    it("holds Shattered Worlds only with all three reward challenges", function()
        local rule = ruleFor("shattered-worlds")
        local values = {
            SWORLDS_REWARD_CHALLENGE_BRONZE_COMPLETE = 1,
            SWORLDS_REWARD_CHALLENGE_SILVER_COMPLETE = 1,
            SWORLDS_REWARD_CHALLENGE_GOLD_COMPLETE = 0,
        }
        assert.is_false(varsCore.holds(rule, values, nil))
        values.SWORLDS_REWARD_CHALLENGE_GOLD_COMPLETE = 1
        assert.is_true(varsCore.holds(rule, values, nil))
    end)
end)

describe("chore-tracker var list", function()
    it("lists exactly the var chores, each in the chore list", function()
        local ids, byId = {}, {}
        for _, chore in ipairs(chores) do
            byId[chore.id] = chore
        end
        for _, rule in ipairs(varRules) do
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
            "dream-of-iaia-resource-daily",
            "dream-of-iaia-resource",
            "dream-of-iaia-xp-weekly",
            "dream-of-iaia-xp",
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
        for _, rule in ipairs(varRules) do
            for _, name in ipairs(varsCore.names(rule)) do
                assert(catalog.var("VarPlayer", name), name .. " is not in docs/vars/vars.csv")
                assert(name ~= "GODSS_PLAYER", "GODSS_PLAYER is another player's id")
                assert(not name:find("PENG"), name .. ": penguins are out of scope")
            end
        end
    end)
end)
