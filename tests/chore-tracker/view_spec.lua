-- core/view: the sections the window shows.

local support = require("tests.chore-tracker.support")
local state = require("core/state")
local view = require("core/view")
local M = support.MINUTES

describe("chore-tracker view", function()
    local chores, byId
    before_each(function()
        chores = support.chores()
        byId = support.byId(chores)
    end)

    it("groups chores by period in display order, omitting an empty period", function()
        ---@param groups table[]
        ---@return table[]
        local function summary(groups)
            local out = {}
            for i, group in ipairs(groups) do
                local ids = {}
                for j, chore in ipairs(group.chores) do
                    ids[j] = chore.id
                end
                out[i] = { group.period, group.title, ids }
            end
            return out
        end
        assert.are.same({
            { "daily", "Daily", { "d1", "d2", "dshop" } },
            { "weekly", "Weekly", { "w1", "wshop" } },
            { "monthly", "Monthly", { "m1" } },
        }, summary(view.byPeriod(chores)))
        assert.are.same(
            { { "daily", "Daily", { "d1" } }, { "monthly", "Monthly", { "m1" } } },
            summary(view.byPeriod({ byId.m1, byId.d1 }))
        )
        assert.are.same({}, view.byPeriod({}))
    end)

    it("shows nothing when nothing is selected", function()
        assert.are.same({}, view.view(state.new(), chores, 0))
    end)

    it("orders sections Daily, Weekly, Monthly and rows in the player's order", function()
        local s = support.stateWith(chores, { "m1", "w1", "d2", "d1" })
        local sections = view.view(s, chores, 0)
        local titles, rows = {}, {}
        for i, section in ipairs(sections) do
            titles[i] = section.title
            for _, row in ipairs(section.rows) do
                rows[#rows + 1] = row.id
            end
        end
        assert.are.same({ "Daily", "Weekly", "Monthly" }, titles)
        assert.are.same({ "d2", "d1", "w1", "m1" }, rows)
    end)

    it("omits a period with nothing selected", function()
        local sections = view.view(support.stateWith(chores, { "m1", "d1" }), chores, 0)
        assert.are.equal(2, #sections)
        assert.are.equal("daily", sections[1].period)
        assert.are.equal("monthly", sections[2].period)
    end)

    it("puts shop chores in their period's section", function()
        local sections = view.view(support.stateWith(chores, { "dshop", "wshop", "w1" }), chores, 0)
        assert.are.equal("daily", sections[1].period)
        assert.are.equal("dshop", sections[1].rows[1].id)
        assert.is_true(sections[1].rows[1].shop)
        assert.are.equal("weekly", sections[2].period)
        assert.are.same({ "wshop", "w1" }, { sections[2].rows[1].id, sections[2].rows[2].id })
    end)

    it("gives each row the chore's fields and whether it is done now", function()
        local now = M["2026-10-25 01:43"]
        local s = state.mark(support.stateWith(chores, { "d1", "d2" }), "d1", now)
        local section = view.view(s, chores, now)[1]
        assert.are.same({
            id = "d1",
            name = "D1",
            desc = "about d1",
            url = "https://example.test/d1",
            links = {},
            shop = false,
            done = true,
            shops = {},
            bought = 0,
        }, section.rows[1])
        assert.is_false(section.rows[2].done)
        assert.are.equal(1, section.done)
        assert.are.equal(2, section.total)
    end)

    it("reads a completion from an earlier period as not done", function()
        local s = state.mark(support.stateWith(chores, { "d1", "w1" }), "d1", M["2026-10-27 23:59"])
        s = state.mark(s, "w1", M["2026-10-27 23:59"])
        local sections = view.view(s, chores, M["2026-10-28"])
        assert.are.equal(0, sections[1].done)
        assert.are.equal(0, sections[2].done)
    end)

    describe("shops", function()
        local listed = {
            wshop = {
                { name = "Shop A", invs = { "SHOP_A" }, proven = true },
                { name = "Shop B", invs = { "SHOP_B", "SHOP_B2" }, proven = true },
            },
            dshop = { { name = "Only Shop", invs = { "SHOP_C" }, proven = true } },
        }
        local now = M["2026-10-25 01:43"]

        it("lists each row's shops, bought this period or not, and counts them", function()
            local s = state.recordPurchase(
                support.stateWith(chores, { "wshop" }),
                byId.wshop,
                "SHOP_B",
                now
            )
            local row = view.view(s, chores, now, listed)[1].rows[1]
            assert.are.same(
                { { name = "Shop A", bought = false }, { name = "Shop B", bought = true } },
                row.shops
            )
            assert.are.equal(1, row.bought)
            assert.is_true(row.done)
        end)

        it("counts a shop bought from in any of its inventories once", function()
            local s = state.recordPurchase(
                support.stateWith(chores, { "wshop" }),
                byId.wshop,
                "SHOP_B2",
                now
            )
            local row = view.view(s, chores, now, listed)[1].rows[1]
            assert.are.equal(1, row.bought)
            s = state.recordPurchase(s, byId.wshop, "SHOP_B", now)
            assert.are.equal(1, view.view(s, chores, now, listed)[1].rows[1].bought)
        end)

        it("counts no shop bought after the reset or without a clock", function()
            local s = state.recordPurchase(
                support.stateWith(chores, { "wshop" }),
                byId.wshop,
                "SHOP_B",
                now
            )
            assert.are.equal(0, view.view(s, chores, M["2026-10-28"], listed)[1].rows[1].bought)
            assert.are.equal(0, view.view(s, chores, nil, listed)[1].rows[1].bought)
        end)

        it("counts a multi-shop row in its text, and leaves a single-shop row's alone", function()
            local s = state.recordPurchase(
                support.stateWith(chores, { "wshop", "dshop" }),
                byId.wshop,
                "SHOP_A",
                now
            )
            local sections = view.view(s, chores, now, listed)
            assert.are.equal("DSHOP", view.rowText(sections[1].rows[1]))
            assert.are.equal("WSHOP (1/2)", view.rowText(sections[2].rows[1]))
            assert.are.equal(
                "D1",
                view.rowText(view.view(support.stateWith(chores, { "d1" }), chores, now)[1].rows[1])
            )
        end)

        it("gives tooltip lines headed with the period and the count", function()
            local s = state.recordPurchase(
                support.stateWith(chores, { "wshop", "dshop" }),
                byId.wshop,
                "SHOP_A",
                now
            )
            local sections = view.view(s, chores, now, listed)
            assert.are.same(
                { "Shops this day (0/1):", "not yet  Only Shop" },
                view.shopTooltip(sections[1].rows[1], "daily")
            )
            assert.are.same(
                { "Shops this week (1/2):", "bought  Shop A", "not yet  Shop B" },
                view.shopTooltip(sections[2].rows[1], "weekly")
            )
            local plain =
                view.view(support.stateWith(chores, { "d1" }), chores, now, listed)[1].rows[1]
            assert.are.same({}, view.shopTooltip(plain, "daily"))
        end)
    end)

    it("shows nothing done without a clock, keeping the rows", function()
        local s = state.mark(support.stateWith(chores, { "d1", "w1" }), "d1", M["2026-10-25 01:43"])
        local sections = view.view(s, chores, nil)
        assert.are.equal(2, #sections)
        assert.are.equal(0, sections[1].done)
        assert.is_false(sections[1].rows[1].done)
    end)
end)
