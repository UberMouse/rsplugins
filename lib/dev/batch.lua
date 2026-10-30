-- The batch transport the dev tools share (the recorder, the log tee and the dev bridge): the
-- bounded buffer of encoded entries, a batch's POST body, JSON splicing, byte capping, and the
-- small helpers around a manifest url, a session id and console text. Pure: nothing here calls
-- the API or keeps state of its own.

local json = require("dev/json")

local batch = {}

-- The manifest url called `name` (Plugin.urls), or nil. The client's urls iterate with pairs
-- (their values are opaque userdata) and read nil for a missing name; iterating first, and
-- indexing under pcall, guard against a client where either raises.
---@param urls any
---@param name string
---@return PluginURL?
function batch.manifestUrl(urls, name)
    local ok, found = pcall(function()
        for key, value in pairs(urls) do
            if key == name then return value end
        end
        return nil
    end)
    if ok and found then return found end
    local indexed, value = pcall(function()
        return urls[name]
    end)
    return indexed and value or nil
end

-- Any value as text, never raising: tostring() can, through a bad __tostring.
---@param v any
---@return string
function batch.text(v)
    if type(v) == "string" then return v end
    local ok, text = pcall(tostring, v)
    if ok then return text end
    return "<a " .. type(v) .. " that tostring() fails on>"
end

-- print's and log's text: their arguments separated by a space (docs/api/generated/core.lua).
---@param ... any
---@return string
function batch.joined(...)
    local parts = table.pack(...)
    for i = 1, parts.n do
        parts[i] = batch.text(parts[i])
    end
    return table.concat(parts, " ", 1, parts.n)
end

-- An id telling one enable's batches apart from another's: six hex digits of a fresh table's
-- address (differs between runs even if math.random is seeded the same) then four random ones.
-- The random part is always there, so the id is never empty and is hex only, which the
-- daemon's session pattern accepts.
---@return string
function batch.newSession()
    return (tostring({}):match("(%x+)$") or ""):sub(-6)
        .. string.format("%04x", math.random(0, 0xffff))
end

---------------------------------------------------------------------------
-- The entry buffer: encoded entries waiting to be sent, oldest first
---------------------------------------------------------------------------

-- Entries sit at buffer[first..last]. An entry keeps its index until it leaves, and leaving
-- is normally from the front, so everything below `first` has been taken or dropped. A
-- failed batch goes back in front of `first` (requeue).
---@return table
function batch.newBuffer()
    return { first = 1, last = 0, bytes = 0 }
end

---@param buffer table
---@return integer
function batch.count(buffer)
    return buffer.last - buffer.first + 1
end

-- Drop the oldest entries until at most `maxBytes` bytes and, if given, `maxLines` entries
-- remain (always keeping the newest). Returns how many were dropped.
---@param buffer table
---@param maxBytes integer
---@param maxLines integer?
---@return integer
local function trim(buffer, maxBytes, maxLines)
    local dropped = 0
    while
        buffer.first < buffer.last
        and (buffer.bytes > maxBytes or (maxLines and batch.count(buffer) > maxLines))
    do
        buffer.bytes = buffer.bytes - #buffer[buffer.first]
        buffer[buffer.first] = nil
        buffer.first = buffer.first + 1
        dropped = dropped + 1
    end
    return dropped
end

-- Add an encoded entry, then trim to `maxBytes` (and `maxLines` if given). Returns how many
-- were dropped.
---@param buffer table
---@param entry string
---@param maxBytes integer
---@param maxLines integer?
---@return integer
function batch.push(buffer, entry, maxBytes, maxLines)
    buffer.last = buffer.last + 1
    buffer[buffer.last] = entry
    buffer.bytes = buffer.bytes + #entry
    return trim(buffer, maxBytes, maxLines)
end

-- Remove and return the oldest entries, up to `maxBytes` in all and `maxLines` entries if
-- given (at least one, however big).
---@param buffer table
---@param maxBytes integer
---@param maxLines integer?
---@return string[]
function batch.take(buffer, maxBytes, maxLines)
    local out, bytes = {}, 0
    while buffer.first <= buffer.last do
        local entry = buffer[buffer.first]
        if #out > 0 and (bytes + #entry > maxBytes or (maxLines and #out >= maxLines)) then
            break
        end
        out[#out + 1] = entry
        bytes = bytes + #entry
        buffer[buffer.first] = nil
        buffer.first = buffer.first + 1
        buffer.bytes = buffer.bytes - #entry
    end
    return out
end

-- Put entries taken earlier back in front, oldest first, then trim: a batch that failed to
-- send keeps its entries unless the caps say otherwise. Returns how many were dropped.
---@param buffer table
---@param items string[]
---@param maxBytes integer
---@param maxLines integer?
---@return integer
function batch.requeue(buffer, items, maxBytes, maxLines)
    if #items == 0 then return 0 end
    for i = #items, 1, -1 do
        buffer.first = buffer.first - 1
        buffer[buffer.first] = items[i]
        buffer.bytes = buffer.bytes + #items[i]
    end
    return trim(buffer, maxBytes, maxLines)
end

-- `objectJson` (an encoded object) with `key` added, its value the already-encoded
-- `valueJson`, so a large value isn't encoded twice. `{}` takes the field without a comma.
---@param objectJson string
---@param key string
---@param valueJson string
---@return string
function batch.withField(objectJson, key, valueJson)
    local field = json.encode(key) .. ":" .. valueJson
    if objectJson == "{}" then return "{" .. field .. "}" end
    return objectJson:sub(1, -2) .. "," .. field .. "}"
end

-- `text` cut to at most `max` bytes followed by "<+N bytes>" (N = bytes cut), and whether it
-- was cut. The cut is by byte, so it can split a UTF-8 character.
---@param text string
---@param max integer
---@return string
---@return boolean
function batch.cap(text, max)
    if #text <= max then return text, false end
    return text:sub(1, max) .. string.format("<+%d bytes>", #text - max), true
end

-- A batch's POST body: `meta` (schema, plugin, session...) plus the already-encoded entries,
-- spliced in as "<key>": [...] (key "entries" unless given) so they aren't encoded twice.
---@param meta table
---@param entries string[]
---@param key string?
---@return string
function batch.batchBody(meta, entries, key)
    return batch.withField(
        json.encode(meta),
        key or "entries",
        "[" .. table.concat(entries, ",") .. "]"
    )
end

return batch
