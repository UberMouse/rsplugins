-- Minimal JSON encoder for the dev tools (the plugin API has no JSON library), shared by
-- the recorder, the log tee, dev-bridge and var-dump through their dev/ symlinks.
-- Handles nil, booleans, numbers, strings and tables. A table with keys 1..n becomes an array,
-- any other table becomes an object. Anything else is written as its tostring() text.

local json = {}

-- Characters that must be escaped inside a JSON string.
-- stylua: ignore
local escapes = {
    ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
    ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function encodeString(s)
    -- Escape quotes, backslashes and control characters; leave other bytes as-is.
    return '"'
        .. s:gsub('[%c"\\]', function(c)
            return escapes[c] or string.format("\\u%04x", c:byte())
        end)
        .. '"'
end

local function encodeNumber(n)
    if math.type(n) == "integer" then return string.format("%d", n) end
    -- JSON has no NaN or infinity.
    if n ~= n or n == math.huge or n == -math.huge then return "null" end
    return string.format("%.17g", n)
end

-- n if the table's keys are exactly 1..n (an empty table counts, with n = 0), else nil.
-- `#t` can't decide it: on a table with holes (an inventory's empty slots) it may return any
-- border, so a gapped table would pass as a shorter array and lose entries.
---@param t table
---@return integer?
local function arrayLength(t)
    local count = 0
    for _ in pairs(t) do
        count = count + 1
    end
    for i = 1, count do
        if t[i] == nil then return nil end
    end
    return count
end

local encodeValue

---@param t table
---@return string
local function encodeTable(t)
    local parts = {}
    local n = arrayLength(t)
    if n then
        for i = 1, n do
            parts[i] = encodeValue(t[i])
        end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    for k, v in pairs(t) do
        parts[#parts + 1] = encodeString(tostring(k)) .. ":" .. encodeValue(v)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

encodeValue = function(v)
    local kind = type(v)
    if kind == "nil" then return "null" end
    if kind == "boolean" then return tostring(v) end
    if kind == "number" then return encodeNumber(v) end
    if kind == "string" then return encodeString(v) end
    if kind == "table" then return encodeTable(v) end
    return encodeString(tostring(v))
end

json.encode = encodeValue

return json
