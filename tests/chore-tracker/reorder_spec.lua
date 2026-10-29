-- core/reorder: drop slot, shifted row positions and auto-scroll for dragging a row.

require("tests.chore-tracker.support")
local reorder = require("core/reorder")

describe("chore-tracker reorder", function()
    local ids = { "a", "b", "c" }
    -- Rows 28 high from y = 100: a at 100, b at 128, c at 156.

    it("drops a row at its own slot when it has not moved", function()
        local d = reorder.drag(ids, 100, 2, 128)
        assert.are.equal(2, d.slot)
        assert.are.equal(128, d.y)
        assert.are.same({ a = 100, c = 156 }, d.rows)
    end)

    it("opens the gap at the nearest slot, switching at the half-row boundary", function()
        assert.are.equal(1, reorder.drag(ids, 100, 3, 113).slot) -- 13 below slot 1: still 1
        assert.are.equal(2, reorder.drag(ids, 100, 3, 114).slot) -- 14 = half a row: rounds up
        local d = reorder.drag(ids, 100, 3, 110)
        assert.are.same({ a = 128, b = 156 }, d.rows) -- gap at the top
    end)

    it("shifts the rows after the gap down and closes up the one it left", function()
        local d = reorder.drag(ids, 100, 1, 160)
        assert.are.equal(3, d.slot)
        assert.are.same({ b = 100, c = 128 }, d.rows)
    end)

    it("clamps the dragged row to the period's span", function()
        local top = reorder.drag(ids, 100, 2, 20)
        assert.are.equal(100, top.y)
        assert.are.equal(1, top.slot)
        local bottom = reorder.drag(ids, 100, 2, 999)
        assert.are.equal(156, bottom.y)
        assert.are.equal(3, bottom.slot)
    end)

    it("takes a row height", function()
        local d = reorder.drag(ids, 0, 1, 40, 20)
        assert.are.equal(3, d.slot)
        assert.are.same({ b = 0, c = 20 }, d.rows)
    end)

    it("handles a one-row period", function()
        local d = reorder.drag({ "a" }, 100, 1, 300)
        assert.are.equal(1, d.slot)
        assert.are.equal(100, d.y)
        assert.are.same({}, d.rows)
    end)

    it("scrolls up above the list, down below it, and not at all inside", function()
        assert.are.equal(-reorder.SCROLL_STEP, reorder.scrollStep(10, 50, 300))
        assert.are.equal(reorder.SCROLL_STEP, reorder.scrollStep(301, 50, 300))
        assert.are.equal(0, reorder.scrollStep(50, 50, 300))
        assert.are.equal(0, reorder.scrollStep(300, 50, 300))
        assert.are.equal(8, reorder.SCROLL_STEP)
    end)

    it("settles rows one row height apart from the first y", function()
        assert.are.same({ a = 100, b = 128, c = 156 }, reorder.settle(ids, 100))
        assert.are.same({ a = 10, b = 20, c = 30 }, reorder.settle(ids, 10, 10))
        assert.are.same({}, reorder.settle({}, 100))
    end)
end)
