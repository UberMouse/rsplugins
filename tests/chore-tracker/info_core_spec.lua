-- core/info: each chore's auto-tick status from the data files, the status groups, their
-- headings and the info view's row names.

require("tests.chore-tracker.support")
local info = require("core/info")
local chores = require("data/chores")
local shops = require("data/shops")
local collections = require("data/collections")
local machines = require("data/machines")
local varRules = require("data/vars")

-- A chore's status from the real data files.
---@param id string
---@return string
local function statusOf(id)
    return info.status(id, shops, collections, varRules, machines)
end

describe("chore-tracker info status", function()
    it("calls a chore with a proven source automatic", function()
        assert.are.equal("automatic", statusOf("feather-shop-run")) -- every shop proven
        assert.are.equal("automatic", statusOf("dellmonti-pineapples")) -- a proven collection
        assert.are.equal("automatic", statusOf("bert-sand")) -- a proven var rule
    end)

    it("calls a chore with some proven and some unproven shops automatic", function()
        assert.are.equal("automatic", statusOf("rune-shop-run"))
        assert.are.equal("automatic", statusOf("vial-of-water-packs"))
        local mixed = { x = { { proven = false }, { proven = true } } }
        assert.are.equal("automatic", info.status("x", mixed, {}, {}, {}))
    end)

    it("calls a chore whose sources are all unproven unproven", function()
        assert.are.equal("unproven", statusOf("meat-packs")) -- an unproven shop
        assert.are.equal("unproven", statusOf("oldman-potato-cactus")) -- an unproven collection
        assert.are.equal("unproven", statusOf("advance-time")) -- an unproven var rule
    end)

    it("calls a chore with no sources manual", function()
        assert.are.equal("manual", statusOf("nemi-forest"))
        assert.are.equal("manual", info.status("x", {}, {}, {}, {}))
    end)

    it("follows the proven flags, so proving a source moves its chore", function()
        local rules = { { chore = "x", done = {}, proven = false } }
        assert.are.equal("unproven", info.status("x", {}, {}, rules, {}))
        rules[1].proven = true
        assert.are.equal("automatic", info.status("x", {}, {}, rules, {}))
    end)
end)

describe("chore-tracker info groups", function()
    it("puts every chore in one group, in status order and chore-list order", function()
        local groups = info.byStatus(chores, shops, collections, varRules, machines)
        assert.are.same(
            { "automatic", "unproven", "manual" },
            { groups[1].status, groups[2].status, groups[3].status }
        )
        assert.are.same({ 35, 23, 10 }, { #groups[1].chores, #groups[2].chores, #groups[3].chores })
        local place = {}
        for i, chore in ipairs(chores) do
            place[chore] = i
        end
        local seen = 0
        for _, group in ipairs(groups) do
            for i, chore in ipairs(group.chores) do
                assert.are.equal(group.status, statusOf(chore.id))
                if i > 1 then assert.is_true(place[group.chores[i - 1]] < place[chore]) end
                seen = seen + 1
            end
        end
        assert.are.equal(#chores, seen)
    end)

    it("keeps an empty status's group, and heads each with its count", function()
        local groups = info.byStatus({ chores[1] }, {}, {}, {}, {})
        assert.are.same({ "Automatic (0)", "Unproven (0)", "Manual (1)" }, {
            info.headingText(groups[1]),
            info.headingText(groups[2]),
            info.headingText(groups[3]),
        })
    end)
end)

describe("chore-tracker info row names", function()
    it("adds the period to a name another chore shares, and only then", function()
        local byId = {}
        for _, chore in ipairs(chores) do
            byId[chore.id] = chore
        end
        assert.are.equal(
            "Dream of Iaia XP (weekly)",
            info.rowName(byId["dream-of-iaia-xp-weekly"], chores)
        )
        assert.are.equal(
            "Dream of Iaia XP (monthly)",
            info.rowName(byId["dream-of-iaia-xp"], chores)
        )
        assert.are.equal("Daily Challenge", info.rowName(byId["daily-challenge"], chores))
        local suffixed = {}
        for _, chore in ipairs(chores) do
            if info.rowName(chore, chores) ~= chore.name then
                suffixed[#suffixed + 1] = chore.name
            end
        end
        -- Dream of Iaia Resources, Dream of Iaia XP, Miscellania and Invention Machines, twice each.
        assert.are.equal(8, #suffixed)
    end)
end)
