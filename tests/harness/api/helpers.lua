-- The global helpers: clamp, lerp and random (math/index.html), and utils.CalcTextWidth
-- (undocumented; declared in docs/api/types.lua).
--
-- Live (dev-bridge eval, 2026-10-26; docs/api-concepts.md): clamp and random return floats
-- (`random(1, 10)` gave 4.27), and random with no arguments raises. Only the Float forms are
-- mocked: lerp of a Vector2/3/4 or Matrix33 faults as unmocked, and slerp, which takes only
-- Vector3 or Quaternion, isn't provided at all. random draws from a generator seeded per
-- harness (opts.randomSeed), so a test sees the same numbers every run. CalcTextWidth needs a
-- font's metrics, which the harness lacks: the test supplies them (opts.textWidth).

local strict = require("tests.harness.strict")

local M = {}

-- Fault unless every argument is a number, naming the call's signature.
---@param signature string e.g. "clamp(value: Float, min: Float, max: Float)"
---@param ... any
local function numbers(signature, ...)
    local n = select("#", ...)
    for i = 1, n do
        if type((select(i, ...))) ~= "number" then
            local which = type((select(i, ...))) == "table" and "unmocked API: " or ""
            strict.fault(
                which .. signature .. ": argument " .. i .. " is " .. type((select(i, ...)))
            )
        end
    end
end

-- The next float in [0, 1) from a 32-bit LCG (Numerical Recipes' constants): plenty for tests,
-- and the same sequence for the same seed.
---@param h table
---@return number
local function nextUniform(h)
    h.randomState = (h.randomState * 1664525 + 1013904223) % 4294967296
    return h.randomState / 4294967296
end

---@param h table the harness
---@param env table the sandbox being built
function M.install(h, env)
    env.clamp = function(...)
        if select("#", ...) < 3 then strict.fault("clamp(value: Float, min: Float, max: Float)") end
        numbers("clamp(value: Float, min: Float, max: Float)", ...)
        local value, min, max = ...
        return math.max(min, math.min(value, max)) + 0.0
    end
    env.lerp = function(...)
        if select("#", ...) < 3 then strict.fault("lerp(start: Float, final: Float, t: Float)") end
        numbers("lerp(start: Float, final: Float, t: Float)", ...)
        local start, final, t = ...
        return start + (final - start) * t + 0.0
    end
    env.random = function(...)
        if select("#", ...) < 2 then
            strict.fault(
                "random(min: Float, max: Float): the client raises without both (stack index 1, "
                    .. "expected number, received no value)"
            )
        end
        numbers("random(min: Float, max: Float)", ...)
        local min, max = ...
        return min + (max - min) * nextUniform(h) + 0.0
    end

    local Utils = strict.class("_global.utils", {
        fields = {
            CalcTextWidth = function()
                return function(fontID, text)
                    if math.type(fontID) ~= "integer" or type(text) ~= "string" then
                        strict.fault("utils.CalcTextWidth(fontID: Int, text: string)")
                    end
                    if not h.textWidth then
                        strict.fault(
                            "unmocked state: utils.CalcTextWidth needs the font's metrics "
                                .. "(opts.textWidth)"
                        )
                    end
                    local width = h.textWidth(fontID, text)
                    assert(math.type(width) == "integer", "opts.textWidth must return an integer")
                    return width
                end
            end,
        },
    })
    env.utils = Utils.new({})
end

return M
