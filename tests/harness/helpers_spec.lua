-- Self-tests: the global helpers clamp, lerp, random and utils.CalcTextWidth.

local harness = require("tests.harness")
local support = require("tests.harness.spec_support")

local plugin = support.inline

describe("helpers", function()
    it("clamp and lerp return floats, as the client's do", function()
        local h = harness.load(plugin([[
            out = { clamp(5, 0, 3), clamp(-1, 0, 3), lerp(0, 10, 0.25), math.type(clamp(5, 0, 3)) }
        ]]))
        assert.are.same({ 3.0, 0.0, 2.5, "float" }, h.env.out)
    end)

    it("random gives floats in range, the same for the same seed", function()
        local main = [[
            out = {}
            for i = 1, 5 do out[i] = random(1, 10) end
        ]]
        local a, b = harness.load(plugin(main)), harness.load(plugin(main))
        assert.are.same(a.env.out, b.env.out)
        for _, v in ipairs(a.env.out) do
            assert.is_true(math.type(v) == "float" and v >= 1 and v < 10)
        end
        local c = harness.load(plugin(main), { randomSeed = 7 })
        assert.are_not.same(a.env.out, c.env.out)
    end)

    it("faults where the client raises or the harness lacks a form", function()
        local cases = {
            ["random()"] = "the client raises without both",
            ["lerp({}, {}, 0.5)"] = "unmocked API: lerp",
            ["slerp(1, 2, 0.5)"] = "unmocked API: slerp",
            ["clamp('a', 0, 1)"] = "clamp%(value: Float",
        }
        for code, pattern in pairs(cases) do
            assert.matches(pattern, harness.errorOf(harness.load, plugin("local x = " .. code)))
        end
    end)

    -- What the client's formatStr returned for each case (dev-bridge eval, 2026-10-26); nil
    -- where it returned nil.
    local GOLDEN = {
        { "1", "{}", 1 },
        { "1", "{}", 1.0 },
        { "1.5", "{}", 1.5 },
        { "-3", "{}", -3 },
        { "9007199254740992", "{}", 2 ^ 53 },
        { "9007199254740992", "{}", 9007199254740993 },
        { "inf", "{}", math.huge },
        { "nan", "{}", 0 / 0 },
        { "true", "{}", true },
        { "false", "{}", false },
        { "s", "{}", "s" },
        { "table", "{}", {} },
        { "function", "{}", print },
        { "a b a", "{0} {1} {0}", "a", "b" },
        { "{} 1", "{{}} {}", 1 },
        { "3.14", "{:.2f}", 3.14159 },
        { "   42|", "{:5}|", 42 },
        { "ab   |", "{:<5}|", "ab" },
        { "   ab|", "{:>5}|", "ab" },
        { " ab  |", "{:^5}|", "ab" },
        { nil, "{:x}", 255 },
        { "0003.142", "{:08.3f}", 3.14159 },
        { nil, "{:d}", 3 },
        { nil, "{:d}", 3.0 },
        { nil, "{:+d}", 5 },
        { "2.0", "{:.1f}", 2 },
        { nil, "{} {}", 1 },
        { "1", "{}", 1, 2 },
        { nil, "{:q}", 1 },
        { "no braces", "no braces" },
    }

    it("formatStr gives what the client's did", function()
        local h = harness.load(plugin("function fmt(...) return formatStr(...) end"))
        for _, case in ipairs(GOLDEN) do
            assert.are.equal(case[1], h.env.fmt(table.unpack(case, 2)), case[2])
        end
        assert.are.equal("nil|1", h.env.fmt("{}|{}", nil, 1))
    end)

    it("formatStr faults where the client raises or the probe didn't look", function()
        local cases = {
            ["formatStr(5)"] = "expected string, received number",
            ["formatStr('{}', 1e300)"] = "unmocked API: formatStr of a number in exponent form",
            ["formatStr('{:+f}', 1)"] = "unmocked API: formatStr spec {:%+f}",
            ["formatStr('{:5}', true)"] = "of a boolean",
            ["formatStr('{}', Player)"] = "an API object",
        }
        for code, pattern in pairs(cases) do
            assert.matches(pattern, harness.errorOf(harness.load, plugin("local x = " .. code)))
        end
    end)

    it("measures text with the metrics the test gives, and faults without them", function()
        local h = harness.load(plugin("w = utils.CalcTextWidth(494, 'abc')"), {
            textWidth = function(fontID, text)
                return fontID == 494 and 7 * #text or 0
            end,
        })
        assert.are.equal(21, h.env.w)
        assert.matches(
            "unmocked state: utils.CalcTextWidth needs the font's metrics",
            harness.errorOf(harness.load, plugin("local w = utils.CalcTextWidth(494, 'abc')"))
        )
    end)
end)
