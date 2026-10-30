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

    it("groups chores by period, then category, in display order, omitting empty ones", function()
        ---@param groups table[]
        ---@return table[]
        local function summary(groups)
            local out = {}
            for i, group in ipairs(groups) do
                local subs = {}
                for j, subgroup in ipairs(group.subgroups) do
                    local ids = {}
                    for k, chore in ipairs(subgroup.chores) do
                        ids[k] = chore.id
                    end
                    subs[j] = { subgroup.category or "none", ids }
                end
                out[i] = { group.period, group.title, subs }
            end
            return out
        end
        assert.are.same({
            {
                "daily",
                "Daily",
                { { "none", { "d2" } }, { "activities", { "d1" } }, { "shops", { "dshop" } } },
            },
            { "weekly", "Weekly", { { "combat", { "w1" } }, { "shops", { "wshop" } } } },
            { "monthly", "Monthly", { { "none", { "m1" } } } },
        }, summary(view.byPeriod(chores)))
        -- Categories go in CATEGORIES order whatever the list's order; chores keep list order.
        local wshop2 = { id = "wshop2", period = "weekly", category = "shops" }
        assert.are.same({
            { "daily", "Daily", { { "activities", { "d1" } }, { "shops", { "dshop" } } } },
            { "weekly", "Weekly", { { "shops", { "wshop2", "wshop" } } } },
        }, summary(view.byPeriod({ byId.dshop, wshop2, byId.d1, byId.wshop })))
        assert.are.same({}, view.byPeriod({}))
    end)

    it("titles every category", function()
        for _, c in ipairs(view.CATEGORIES) do
            assert.are.equal("string", type(view.CATEGORY_TITLES[c]), c)
        end
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

    describe("tooltip", function()
        it("gives the description, then the wiki page", function()
            local t = view.tooltip({ desc = "Do it.", url = "U", links = {} })
            assert.are.same({ text = "Do it.<br>U", maxWidth = 360 }, t)
        end)

        it("puts extra lines between the description and the links", function()
            local t = view.tooltip(
                { desc = "Do it.", url = "U", links = { "L1", "L2" } },
                { "X", "Y" }
            )
            assert.are.equal("Do it.<br>X<br>Y<br>U<br>L1<br>L2", t.text)
        end)

        it("has no blank first line for a chore without a description", function()
            local t = view.tooltip({ desc = "", url = "U", links = { "L1" } })
            assert.are.equal("U<br>L1", t.text)
        end)
    end)

    it("words a heading with its done count", function()
        local section = { period = "daily", title = "Daily", rows = {}, done = 1, total = 3 }
        assert.are.equal("Daily  1/3", view.headingText(section))
    end)

    describe("strip", function()
        local NOW = M["2026-10-25 01:43"]

        ---@param ids string[] picked, in the player's order
        ---@param done string[] marked done at NOW
        ---@param now integer?
        ---@return table[]
        local function sections(ids, done, now)
            local s = support.stateWith(chores, ids)
            for _, id in ipairs(done) do
                s = state.mark(s, id, NOW)
            end
            return view.view(s, chores, now == nil and NOW or now)
        end

        it("shows the first chore not done, in the player's order within its period", function()
            local strip = view.strip(sections({ "w1", "d2", "d1" }, {}))
            assert.are.equal("d2", strip.id)
            assert.are.equal("Daily: D2", strip.text)
            strip = view.strip(sections({ "w1", "d2", "d1" }, { "d2" }))
            assert.are.same({ "d1", "Daily: D1" }, { strip.id, strip.text })
        end)

        it("moves on to Weekly, then Monthly, once the earlier periods are done", function()
            local picks = { "m1", "w1", "d1" }
            local strip = view.strip(sections(picks, { "d1" }))
            assert.are.same({ "w1", "Weekly: W1" }, { strip.id, strip.text })
            strip = view.strip(sections(picks, { "d1", "w1" }))
            assert.are.same({ "m1", "Monthly: M1" }, { strip.id, strip.text })
        end)

        it("says so when everything is done or nothing is picked", function()
            local strip = view.strip(sections({ "d1", "m1" }, { "d1", "m1" }))
            assert.are.same({ nil, view.ALL_DONE }, { strip.id, strip.text })
            strip = view.strip(sections({}, {}))
            assert.are.same({ nil, view.NOTHING_PICKED }, { strip.id, strip.text })
            assert.are.same({ view.NOTHING_PICKED }, strip.texts)
        end)

        it("shows a notice instead of a chore when given one", function()
            local strip = view.strip(sections({ "d1" }, {}), "Waiting")
            assert.are.same({ nil, "Waiting" }, { strip.id, strip.text })
            assert.are.same({ "Daily: D1", "Waiting" }, strip.texts)
        end)

        it(
            "fits every picked chore's text, done or not, so its width holds as they tick",
            function()
                local picks = { "w1", "d1", "d2" }
                local expected = { "Daily: D1", "Daily: D2", "Weekly: W1" }
                assert.are.same(expected, view.strip(sections(picks, {})).texts)
                assert.are.same(expected, view.strip(sections(picks, { "d1", "d2" })).texts)
                table.insert(expected, view.ALL_DONE)
                assert.are.same(expected, view.strip(sections(picks, { "d1", "d2", "w1" })).texts)
            end
        )
    end)
end)
