-- core/view: the sections the window shows.

local support = require("tests.chore-tracker.support")
local state = require("core/state")
local view = require("core/view")
local M = support.MINUTES

describe("chore-tracker view", function()
    local chores
    before_each(function()
        chores = support.chores()
    end)

    ---@param ids string[]
    ---@return table
    local function selecting(ids)
        local s = state.new()
        for _, id in ipairs(ids) do
            s = state.select(s, chores, id)
        end
        return s
    end

    it("shows nothing when nothing is selected", function()
        assert.are.same({}, view.view(state.new(), chores, 0))
    end)

    it("orders sections Daily, Weekly, Monthly and rows in chore-list order", function()
        local s = selecting({ "m1", "w1", "d2", "d1" })
        local sections = view.view(s, chores, 0)
        local titles, rows = {}, {}
        for i, section in ipairs(sections) do
            titles[i] = section.title
            for _, row in ipairs(section.rows) do
                rows[#rows + 1] = row.id
            end
        end
        assert.are.same({ "Daily", "Weekly", "Monthly" }, titles)
        assert.are.same({ "d1", "d2", "w1", "m1" }, rows)
    end)

    it("omits a period with nothing selected", function()
        local sections = view.view(selecting({ "m1", "d1" }), chores, 0)
        assert.are.equal(2, #sections)
        assert.are.equal("daily", sections[1].period)
        assert.are.equal("monthly", sections[2].period)
    end)

    it("puts shop chores in their period's section", function()
        local sections = view.view(selecting({ "dshop", "wshop", "w1" }), chores, 0)
        assert.are.equal("daily", sections[1].period)
        assert.are.equal("dshop", sections[1].rows[1].id)
        assert.is_true(sections[1].rows[1].shop)
        assert.are.equal("weekly", sections[2].period)
        assert.are.same({ "w1", "wshop" }, { sections[2].rows[1].id, sections[2].rows[2].id })
    end)

    it("gives each row the chore's fields and whether it is done now", function()
        local now = M["2026-10-25 01:43"]
        local s = state.mark(selecting({ "d1", "d2" }), "d1", now)
        local section = view.view(s, chores, now)[1]
        assert.are.same({
            id = "d1",
            name = "D1",
            desc = "about d1",
            url = "https://example.test/d1",
            links = {},
            shop = false,
            done = true,
        }, section.rows[1])
        assert.is_false(section.rows[2].done)
        assert.are.equal(1, section.done)
        assert.are.equal(2, section.total)
    end)

    it("reads a completion from an earlier period as not done", function()
        local s = state.mark(selecting({ "d1", "w1" }), "d1", M["2026-10-27 23:59"])
        s = state.mark(s, "w1", M["2026-10-27 23:59"])
        local sections = view.view(s, chores, M["2026-10-28"])
        assert.are.equal(0, sections[1].done)
        assert.are.equal(0, sections[2].done)
    end)

    it("shows nothing done without a clock, keeping the rows", function()
        local s = state.mark(selecting({ "d1", "w1" }), "d1", M["2026-10-25 01:43"])
        local sections = view.view(s, chores, nil)
        assert.are.equal(2, #sections)
        assert.are.equal(0, sections[1].done)
        assert.is_false(sections[1].rows[1].done)
    end)
end)
