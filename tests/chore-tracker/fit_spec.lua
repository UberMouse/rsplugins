-- core/fit: shortening a row's text with "..." to fit a width.

require("tests.chore-tracker.support")
local fit = require("core/fit")

-- Every character is 10 px wide, so "..." is 30.
---@param text string
---@return integer
local function measure(text)
    return #text * 10
end

describe("chore-tracker fit", function()
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

describe("chore-tracker wrap", function()
    it("breaks between words before a line would pass the width", function()
        -- 10 px a character: 9 fit on a line.
        assert.are.equal(
            "Pick the<br>chores<br>you do",
            fit.wrap("Pick the chores you do", 90, measure)
        )
    end)

    it("leaves text that fits on one line whole", function()
        assert.are.equal("Pick chores", fit.wrap("Pick chores", 110, measure))
    end)

    it("keeps a break already in the text, and wraps each part", function()
        assert.are.equal("ab<br>cd ef<br>gh", fit.wrap("ab<br>cd ef gh", 50, measure))
        assert.are.equal("ab<br>", fit.wrap("ab<br>", 50, measure))
    end)

    it("gives a word wider than the width a line of its own, unsplit", function()
        assert.are.equal("a<br>Miscellania<br>b", fit.wrap("a Miscellania b", 50, measure))
    end)

    it("measures with the tags left in, so a tag-aware measure ignores them", function()
        local function tagless(s)
            return #s:gsub("<[^>]*>", "") * 10
        end
        local text = "<col=ffd700>Manual</col>: by hand"
        assert.are.equal("<col=ffd700>Manual</col>: by<br>hand", fit.wrap(text, 100, tagless))
    end)
end)
