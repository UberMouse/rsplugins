-- config.Font: GetStringWidth on a named font, and nothing else.

local harness = require("tests.harness")
local support = require("tests.harness.spec_support")

---@param main string
---@return table h
local function load(main)
    return harness.load(support.inline(main))
end

describe("config.Font fake", function()
    it("measures strings as integers, tags parsed unless ignoreTags is true", function()
        local h = load([[
            font = config.Font.MUSEO_SANS_15PT_REGULAR
            w = font:GetStringWidth("W", false)
            dots = font:GetStringWidth("...")
            tagged = font:GetStringWidth("<col=ff0000>red</col>", false)
            raw = font:GetStringWidth("<col=ff0000>red</col>", true)
            same = font == config.Font.MUSEO_SANS_15PT_REGULAR
            name = font.configName
        ]])
        assert.are.equal(14, h.env.w)
        assert.are.equal(12, h.env.dots)
        assert.is_true(h.env.raw > h.env.tagged)
        assert.are.equal("integer", math.type(h.env.tagged))
        assert.is_true(h.env.same)
        assert.are.equal("MUSEO_SANS_15PT_REGULAR", h.env.name)
    end)

    it("faults on an unknown font, FromID, other methods and bad arguments", function()
        local function attempt(code)
            return harness.errorOf(
                load,
                "local font = config.Font.MUSEO_SANS_15PT_REGULAR\n" .. code
            )
        end
        assert.matches("unknown font", harness.errorOf(load, "local _ = config.Font.NOPE"))
        assert.matches("unmocked API", attempt("config.Font.FromID(30)"))
        assert.matches("unmocked API", attempt("font:GetStringLineCount('a', 10)"))
        assert.matches("GetStringWidth", attempt("font:GetStringWidth(5)"))
        assert.matches("GetStringWidth", attempt("font.GetStringWidth('a')"))
    end)
end)
