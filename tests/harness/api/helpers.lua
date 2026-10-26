-- The global helpers: clamp, lerp and random (math/index.html), and utils.CalcTextWidth
-- (undocumented; declared in docs/api/types.lua).
--
-- Live (dev-bridge eval, 2026-10-26; docs/api-concepts.md): clamp and random return floats
-- (`random(1, 10)` gave 4.27), and random with no arguments raises. Only the Float forms are
-- mocked: lerp of a Vector2/3/4 or Matrix33 faults as unmocked, and slerp, which takes only
-- Vector3 or Quaternion, isn't provided at all. random draws from a generator seeded per
-- harness (opts.randomSeed), so a test sees the same numbers every run. CalcTextWidth needs a
-- font's metrics, which the harness lacks: the test supplies them (opts.textWidth).
--
-- formatStr (core/string.html) is fmtlib underneath. The fake does what a live probe showed
-- (dev-bridge eval, 2026-10-26; the cases are in helpers_spec.lua): `{}`, `{N}`, `{{`/`}}`, and
-- specs of fill, `<>^` alignment, `0`, width, `.N` and `f`. Every number is a double first, so
-- 1 prints "1" and 2^53+1 prints 9007199254740992; a spec fmtlib refuses (`d`/`x` on a number,
-- an unknown type, too few arguments) makes the result nil, not an error. Anything the probe
-- didn't cover faults as unmocked.

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

-- Integer presentation types: fmtlib refuses them for a double, so formatStr gives nil.
local INTEGER_TYPES = { d = true, x = true, X = true, b = true, B = true, o = true, c = true }

-- A Lua value as formatStr's `{}` prints it, or nil and why the fake can't say.
---@param v any
---@return string?
---@return string? unmocked
local function plain(v)
    local t = type(v)
    if t == "string" then return v end
    if t == "boolean" or t == "nil" then return tostring(v) end
    if t == "number" then
        v = v + 0.0
        if v ~= v then return "nan" end
        if v == math.huge then return "inf" end
        if v == -math.huge then return "-inf" end
        if v == math.floor(v) and math.abs(v) < 1e16 then return string.format("%.0f", v) end
        for digits = 1, 17 do
            local text = string.format("%." .. digits .. "g", v)
            if tonumber(text) == v then
                if text:find("e") then return nil, "a number in exponent form" end
                return text
            end
        end
    end
    if t == "table" and getmetatable(v) and rawget(getmetatable(v), "__name") then
        return nil, "an API object (userdata in the client)"
    end
    if t == "table" or t == "function" then return t end
    return nil, "a " .. t
end

-- One replacement field's text under `spec` (the part after `:`), nil if fmtlib would refuse
-- the spec, or faults for a spec the probe didn't cover.
---@param v any
---@param spec string
---@return string?
local function field(v, spec)
    if spec == "" then
        local text, unmocked = plain(v)
        if not text then strict.fault("unmocked API: formatStr of " .. unmocked) end
        return text
    end
    local fill, align, rest = " ", "", spec
    if rest:match("^.[<>^]") then
        fill, align, rest = rest:sub(1, 1), rest:sub(2, 2), rest:sub(3)
    elseif rest:match("^[<>^]") then
        align, rest = rest:sub(1, 1), rest:sub(2)
    end
    local zero, width, precision, kind = rest:match("^(0?)(%d*)(%.?%d*)(%a?)$")
    -- A sign, `#`, or an unknown type: fmtlib refuses some for a double (`{:+d}`, `{:q}`);
    -- the rest weren't probed.
    if not zero or (kind ~= "" and kind ~= "f") then
        local last = spec:sub(-1)
        if (type(v) == "number" and INTEGER_TYPES[last]) or last == "q" then return nil end
        strict.fault("unmocked API: formatStr spec {:" .. spec .. "}")
    end
    local text
    if type(v) == "number" then
        if precision ~= "" then
            text = string.format("%" .. precision .. "f", v + 0.0)
        elseif kind == "f" then
            text = string.format("%f", v + 0.0)
        else
            text = field(v, "")
        end
    elseif type(v) == "string" and precision == "" and kind == "" and zero == "" then
        text = v
    else
        strict.fault("unmocked API: formatStr spec {:" .. spec .. "} of a " .. type(v))
    end
    ---@cast text string
    local pad = (tonumber(width) or 0) - #text
    if pad <= 0 then return text end
    if zero == "0" and align == "" and type(v) == "number" then
        local sign, digits = text:match("^([-+]?)(.*)$")
        return sign .. string.rep("0", pad) .. digits
    end
    if align == "" then align = type(v) == "number" and ">" or "<" end
    if align == "<" then return text .. string.rep(fill, pad) end
    if align == ">" then return string.rep(fill, pad) .. text end
    local left = pad // 2
    return string.rep(fill, left) .. text .. string.rep(fill, pad - left)
end

-- formatStr(format, ...): nil where fmtlib would throw a format error.
---@param format any
---@param ... any
---@return string?
local function formatStr(format, ...)
    if type(format) ~= "string" then
        strict.fault(
            "formatStr: stack index 1, expected string, received "
                .. type(format)
                .. " (the client raises)"
        )
    end
    local args = table.pack(...)
    local out, i, nextArg = {}, 1, 1
    while i <= #format do
        local c = format:sub(i, i)
        local two = format:sub(i, i + 1)
        if two == "{{" or two == "}}" then
            out[#out + 1], i = c, i + 2
        elseif c == "{" then
            local close = format:find("}", i, true)
            if not close then strict.fault("unmocked API: formatStr with an unclosed {") end
            local index, spec = format:sub(i + 1, close - 1):match("^(%d*):?(.*)$")
            if not index then
                strict.fault("unmocked API: formatStr field " .. format:sub(i, close))
            end
            local n
            if index == "" then
                n, nextArg = nextArg, nextArg + 1
            else
                n = tonumber(index) + 1
            end
            if n > args.n then return nil end -- too few arguments
            local text = field(args[n], spec)
            if text == nil then return nil end
            out[#out + 1], i = text, close + 1
        else
            out[#out + 1], i = c, i + 1
        end
    end
    return table.concat(out)
end

---@param h table the harness
---@param env table the sandbox being built
function M.install(h, env)
    env.formatStr = formatStr
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
