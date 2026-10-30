-- core/layout: the window's saved layout, read back and kept inside the plugin layer.

require("tests.chore-tracker.support")
local layout = require("core/layout")

describe("chore-tracker layout", function()
    it("defaults to an open window with its button in the close X's slot", function()
        local l = layout.default()
        assert.is_false(l.collapsed)
        assert.are.same(
            { l.x + l.width + layout.SLOT_X, l.y + layout.SLOT_Y },
            { l.buttonX, l.buttonY }
        )
    end)

    -- Pins SLOT_X/SLOT_Y so the other specs here and window_spec use them symbolically.
    it("puts the close X's slot 28 px left of the right edge and 7 px down", function()
        assert.are.same({ -28, 7 }, { layout.SLOT_X, layout.SLOT_Y })
    end)

    it("round-trips through serialise and fromStored", function()
        local l = layout.default()
        l.x, l.collapsed, l.buttonY = 10, true, 99
        local back = layout.fromStored(layout.serialise(l))
        assert.are.same(l, back)
        assert.is_true(layout.same(l, back))
    end)

    it("accepts whole floats, and falls back to the default on anything malformed", function()
        local stored = layout.serialise(layout.default())
        stored.x = 600.0
        assert.are.equal(600, layout.fromStored(stored).x)
        assert.is_true(math.type(layout.fromStored(stored).x) == "integer")
        for _, bad in ipairs({
            { x = 1.5 },
            { width = "wide" },
            { collapsed = 1 },
            { version = 2 },
        }) do
            local value = layout.serialise(layout.default())
            value.x = 1
            for k, v in pairs(bad) do
                value[k] = v
            end
            assert.are.same(layout.default(), layout.fromStored(value))
        end
        assert.are.same(layout.default(), layout.fromStored(nil))
        assert.are.same(layout.default(), layout.fromStored("layout"))
    end)

    it("tells layouts apart by any field", function()
        local a, b = layout.default(), layout.default()
        assert.is_true(layout.same(a, b))
        b.buttonX = b.buttonX + 1
        assert.is_false(layout.same(a, b))
        b = layout.default()
        b.collapsed = true
        assert.is_false(layout.same(a, b))
    end)

    it("moves and shrinks a layout that no longer fits its parent", function()
        local l = {
            x = 3000,
            y = -50,
            width = 900,
            height = 5000,
            collapsed = true,
            buttonX = 4000,
            buttonY = -3,
        }
        local c = layout.keepInside(l, 1000, 800)
        assert.are.same({
            x = 100,
            y = 0,
            width = 900,
            height = 800,
            collapsed = true,
            buttonX = 1000 - layout.BUTTON_SIZE,
            buttonY = 0,
        }, c)
        -- A button past the bottom edge stops at the last y that keeps it whole.
        local low = layout.default()
        low.buttonY = 900
        assert.are.equal(800 - layout.BUTTON_SIZE, layout.keepInside(low, 1000, 800).buttonY)
        local fits = layout.default()
        assert.are.same(fits, layout.keepInside(fits, 3836, 2121))
    end)

    it("keeps the minimum size even in a parent smaller than it", function()
        local c = layout.keepInside(layout.default(), 100, 100)
        assert.are.same(
            { 0, 0, layout.MIN_WIDTH, layout.MIN_HEIGHT },
            { c.x, c.y, c.width, c.height }
        )
    end)

    describe("stripForButton", function()
        local ROW = 200
        local FULL = 2 * layout.STRIP_INSET + ROW + layout.STRIP_GAP + layout.BUTTON_SIZE

        -- Where the strip's button lands for a panel at `box`.
        ---@param box table a ChoreStripBox
        ---@return integer[]
        local function button(box)
            return {
                box.x + box.width + layout.STRIP_BUTTON_X,
                box.y + layout.STRIP_BUTTON_Y,
            }
        end

        it("puts the button on its spot, with the row to its left", function()
            local box = layout.stripForButton(500, 300, ROW, 1000, 800)
            assert.are.same({ 500, 300 }, button(box))
            assert.are.same({ FULL, layout.STRIP_HEIGHT }, { box.width, box.height })
            assert.is_true(box.x < 500 - ROW)
        end)

        it("shifts the strip in near the left and top edges", function()
            local box = layout.stripForButton(50, 0, ROW, 1000, 800)
            assert.are.same({ 0, 0 }, { box.x, box.y })
            assert.are.same({ FULL + layout.STRIP_BUTTON_X, layout.STRIP_BUTTON_Y }, button(box))
        end)

        it("narrows the strip to a parent narrower than it", function()
            local box = layout.stripForButton(100, 300, ROW, 150, 800)
            assert.are.same({ 0, 150 }, { box.x, box.width })
        end)
    end)

    describe("windowForButton", function()
        it("puts the window's button slot on the button", function()
            local x, y = layout.windowForButton(500, 300, 320, 420, 1000, 800)
            assert.are.same({ 500, 300 }, { x + 320 + layout.SLOT_X, y + layout.SLOT_Y })
        end)

        it("shifts the window in near the left edge", function()
            assert.are.same({ 0, 293 }, { layout.windowForButton(100, 300, 320, 420, 1000, 800) })
        end)

        it("shifts the window up near the bottom edge", function()
            assert.are.same({ 208, 380 }, { layout.windowForButton(500, 700, 320, 420, 1000, 800) })
        end)

        it("pins the window at 0 in a parent smaller than it", function()
            assert.are.same({ 0, 0 }, { layout.windowForButton(900, 300, 320, 420, 200, 100) })
        end)
    end)
end)
