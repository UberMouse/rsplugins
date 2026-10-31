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
    -- instead: only a rise ticks it, never all-zero values as such. A falls rule may hold on
    -- zeros (God Statues' months since built), since only a var going down ticks it.
    it("holds no rule with conditions on all-zero vars but Advance Time's", function()
        for _, rule in ipairs(varRules) do
            if #rule.done == 0 then
                assert(rule.rises, rule.chore .. " has neither conditions nor a rises var")
            elseif not rule.falls then
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

    -- Chore `id`'s rules by the part each marks.
    ---@param id string
    ---@return table<string, table>
    local function partRules(id)
        local out = {}
        for _, rule in ipairs(varRules) do
            if rule.chore == id then
                out[assert(rule.part, id .. " has a rule without a part")] = rule
            end
        end
        return out
    end

    it("holds each Thalmund slot bought up to its own limit above 0", function()
        local rules = partRules("thalmunds-wares")
        local slot = "NECRO_HUB_THALMUND_SLOT_3"
        local rule = assert(rules[slot], slot)
        assert.are.same({ slot .. "_MAX", slot .. "_BOUGHT" }, varsCore.names(rule))
        assert.is_true(varsCore.holds(rule, { [slot .. "_MAX"] = 5, [slot .. "_BOUGHT"] = 5 }))
        assert.is_false(varsCore.holds(rule, { [slot .. "_MAX"] = 5, [slot .. "_BOUGHT"] = 4 }))
        -- A slot with no limit isn't bought out at 0 >= 0.
        assert.is_false(varsCore.holds(rule, { [slot .. "_MAX"] = 0, [slot .. "_BOUGHT"] = 0 }))
        local count = 0
        for _ in pairs(rules) do
            count = count + 1
        end
        assert.are.equal(4, count)
    end)

    it("holds each Shattered Worlds challenge on its own flag", function()
        local rules = partRules("shattered-worlds")
        for _, tier in ipairs({ "BRONZE", "SILVER", "GOLD" }) do
            local name = "SWORLDS_REWARD_CHALLENGE_" .. tier .. "_COMPLETE"
            local rule = assert(rules[name], tier)
            assert.are.same({ name }, varsCore.names(rule))
            assert.is_true(varsCore.holds(rule, { [name] = 1 }))
            assert.is_false(varsCore.holds(rule, { [name] = 0 }))
        end
    end)

    -- Whether any of chore `id`'s rules ticks on the change from `before` to `after`.
    ---@param id string
    ---@param before table<string, integer>
    ---@param after table<string, integer>
    ---@return boolean
    local function anyTicks(id, before, after)
        for _, rule in ipairs(varRules) do
            if rule.chore == id and varsCore.ticks(rule, before, after, nil) then return true end
        end
        return false
    end

    it("ticks Arc Contracts at the day's limit, 3 plus the upgrades bought", function()
        local function step(bought, from, to)
            return anyTicks(
                "arc-contracts",
                { PGC_PER_DAY_INCREASE = bought, PGC_TALLY = from },
                { PGC_PER_DAY_INCREASE = bought, PGC_TALLY = to }
            )
        end
        assert.is_true(step(4, 6, 7))
        assert.is_false(step(4, 2, 3))
        assert.is_true(step(0, 2, 3))
        assert.is_true(step(2, 4, 5))
    end)

    it("ticks a tree, trough or patch chore from any one of its vars", function()
        assert.is_true(
            anyTicks("bloodwood-tree", { SNIPER_BLOODTREE_5 = 1 }, { SNIPER_BLOODTREE_5 = 2 })
        )
        -- A felled tree growing back is no tick.
        assert.is_false(
            anyTicks("bloodwood-tree", { SNIPER_BLOODTREE_5 = 2 }, { SNIPER_BLOODTREE_5 = 1 })
        )
        local trough = "POF_FEEDING_TROUGH_BREEDING_GENERAL_AMOUNT"
        assert.is_true(anyTicks("player-owned-farm", { [trough] = 0 }, { [trough] = 3 }))
        assert.is_false(anyTicks("player-owned-farm", { [trough] = 3 }, { [trough] = 2 }))
        local patch = "FARMING_SEEDS_PLANTED_HERB_PATCH_DRUID"
        assert.is_true(anyTicks("herb-run", { [patch] = 0 }, { [patch] = 7 }))
        assert.is_false(anyTicks("herb-run", { [patch] = 7 }, { [patch] = 0 }))
    end)

    it("ticks God Statues only on the months since built falling to 0", function()
        local name = "GODSS_MONTHS_SINCE_USED"
        assert.is_true(anyTicks("god-statues", { [name] = 3 }, { [name] = 0 }))
        assert.is_false(anyTicks("god-statues", { [name] = 0 }, { [name] = 1 }))
    end)

    it("ticks Fort Forinthry Bonus XP on a bonus XP rise only beside Aster", function()
        local function rises(tile)
            for _, rule in ipairs(varRules) do
                if
                    rule.chore == "fort-forinthry-bonus-xp"
                    and varsCore.ticks(
                        rule,
                        { BONUSXP_AGILITY = 0 },
                        { BONUSXP_AGILITY = 1596975 },
                        nil,
                        tile
                    )
                then
                    return true
                end
            end
            return false
        end
        -- The tile the claim of 2026-10-31 was made from.
        assert.is_true(rises({ x = 3302, z = 3571, level = 0 }))
        assert.is_false(rises({ x = 3013, z = 3225, level = 0 }))
        assert.is_false(rises({ x = 3302, z = 3571, level = 1 }))
        assert.is_false(rises(nil))
    end)

    it("ticks Meg's Questions on her leaving, not on her return", function()
        local name = "POP_MEG_ONMISSION"
        assert.is_true(anyTicks("meg", { [name] = 0 }, { [name] = 1 }))
        assert.is_false(anyTicks("meg", { [name] = 1 }, { [name] = 0 }))
        -- Any value for away or back: a move between two non-zero values is no tick.
        assert.is_false(anyTicks("meg", { [name] = 1 }, { [name] = 2 }))
    end)
end)

describe("chore-tracker var list", function()
    -- A chore with a rule per var (a tree, a trough, a patch) shows once, as "<id> xN".
    it("lists exactly the var chores, each in the chore list", function()
        local ids, byId = {}, {}
        for _, chore in ipairs(chores) do
            byId[chore.id] = chore
        end
        local last, run = nil, 0
        for _, rule in ipairs(varRules) do
            assert(byId[rule.chore], "no chore " .. rule.chore)
            assert(type(rule.proven) == "boolean", rule.chore .. " has no proven flag")
            local id = rule.chore .. (rule.proven and "" or " (unproven)")
            if id == last then
                run = run + 1
                ids[#ids] = id .. " x" .. run
            else
                last, run = id, 1
                ids[#ids + 1] = id
            end
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
            "archaeology-research",
            "miscellania",
            "miscellania-weekly",
            "crystal-tree-blossom (unproven)",
            "sinkholes (unproven)",
            "big-chinchompa (unproven)",
            "fixate (unproven)",
            "runesphere (unproven)",
            "soul-reaper (unproven)",
            "tears-of-guthix (unproven)",
            "herby-werby (unproven)",
            "wisps-of-the-grove (unproven)",
            "aquarium-treasure-chest (unproven)",
            "agoroth (unproven)",
            "broken-home (unproven)",
            "lupe (unproven)",
            "effigy-incubator (unproven)",
            "god-statues",
            "troll-invasion",
            "menaphos-obelisk",
            "goebie-bands",
            "gwd2-bounties",
            "capping-clan-citadel",
            "rush-of-blood",
            "meg",
            "water-filtration",
            "arc-supplies",
            "giant-oyster",
            "thalmunds-wares (unproven) x4",
            "shattered-worlds (unproven) x3",
            "arc-contracts x5",
            "bloodwood-tree x8",
            "player-owned-farm x7",
            "herb-run x11",
            "fort-forinthry-bonus-xp x29",
            "penguin-hide-and-seek x13",
            "player-owned-ports x4",
            "player-owned-ports (unproven)",
        }, ids)
    end)

    it("names only VarPlayer vars in the catalog, and none it must not read", function()
        for _, rule in ipairs(varRules) do
            for _, name in ipairs(varsCore.names(rule)) do
                assert(catalog.var("VarPlayer", name), name .. " is not in docs/vars/vars.csv")
                assert(name ~= "GODSS_PLAYER", "GODSS_PLAYER is another player's id")
            end
        end
    end)
end)
