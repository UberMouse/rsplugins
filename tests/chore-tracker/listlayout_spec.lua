-- core/listlayout: where the list's headings and rows go in the window's content.

require("tests.chore-tracker.support")
local listlayout = require("core/listlayout")

---@param period string
---@param ids string[]
---@return table section
local function section(period, ids)
    return { period = period, ids = ids }
end

describe("chore-tracker list layout", function()
    it("stacks each heading over its rows, one row height apart, from the top given", function()
        local l =
            listlayout.place({ section("daily", { "d1", "d2" }), section("weekly", { "w1" }) }, 40)
        -- 40 + 8 = 48 for the heading; 48 + 28 + 4 = 80 for the first row.
        -- d2 ends at 136, so the next heading is at 144 and its row at 144 + 28 + 4.
        assert.are.same({ daily = 48, weekly = 144 }, l.headings)
        assert.are.same({ d1 = 80, d2 = 108, w1 = 176 }, l.rows)
        -- The last row ends at 204; the bottom padding follows.
        assert.are.equal(204 + 14, l.height)
    end)

    it("holds just the padding with no sections", function()
        local l = listlayout.place({}, 40)
        assert.are.same({}, l.headings)
        assert.are.same({}, l.rows)
        assert.are.equal(54, l.height)
    end)

    it("leaves no gap between a section's rows", function()
        local l = listlayout.place({ section("daily", { "a", "b", "c" }) }, 0)
        assert.are.equal(listlayout.ROW_HEIGHT, l.rows.b - l.rows.a)
        assert.are.equal(listlayout.ROW_HEIGHT, l.rows.c - l.rows.b)
    end)
end)
