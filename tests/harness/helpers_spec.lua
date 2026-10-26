-- Self-tests: the global helpers clamp, lerp, random and utils.CalcTextWidth.

local harness = require("tests.harness")

local function plugin(main)
    return { ["main.lua"] = main }
end

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
            assert.matches(
                pattern,
                harness.errorOf(function()
                    harness.load(plugin("local x = " .. code))
                end)
            )
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
            harness.errorOf(function()
                harness.load(plugin("local w = utils.CalcTextWidth(494, 'abc')"))
            end)
        )
    end)
end)
