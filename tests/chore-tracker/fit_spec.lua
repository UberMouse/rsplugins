-- core/fit: shortening a row's text with "..." to fit a width.

require("tests.chore-tracker.support")
local fit = require("core/fit")

-- Every character is 10 px wide, so "..." is 30.
---@param text string
---@return integer
local function measure(text)
    return #text * 10
end

describe("fit", function()
    it("leaves text that fits as it is", function()
        assert.are.same({ "Daily", false }, { fit.fit("Daily", 50, measure) })
        assert.are.same({ "Daily", false }, { fit.fit("Daily", 500, measure) })
    end)

    it("cuts at the longest prefix that fits with the dots", function()
        -- 10 chars of room: 7 of text and the dots.
        assert.are.same({ "Pure Es...", true }, { fit.fit("Pure Essence", 100, measure) })
    end)

    it("drops the spaces before the dots", function()
        -- The 7-char prefix is "Pure Es"; at 6 chars wide it is "Pure E", at 5 "Pure ".
        assert.are.same({ "Pure...", true }, { fit.fit("Pure Essence", 80, measure) })
    end)

    it("shows just the dots when nothing but them fits", function()
        assert.are.same({ "...", true }, { fit.fit("Pure Essence", 30, measure) })
        assert.are.same({ "...", true }, { fit.fit("Pure Essence", 5, measure) })
        assert.are.same({ "...", true }, { fit.fit("Pure Essence", -20, measure) })
    end)

    it("measures no more than once per character, plus the whole and the dots", function()
        local calls = 0
        fit.fit("Pure Essence", 0, function(s)
            calls = calls + 1
            return #s * 10
        end)
        assert.is_true(calls <= #"Pure Essence" + 2)
    end)
end)
