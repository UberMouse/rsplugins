-- The dev log tee's pure core: shaping a console line, the bounded queue of encoded lines
-- waiting to be sent, a batch's body, and the retry backoff. Nothing here calls the API or
-- keeps state of its own; dev/tee.lua (the shell) does both. The wire format is
-- docs/dev-environment.md ("Log tee").

local json = require("dev/json")
local recording = require("dev/recording")

local teelog = {}

-- The tee protocol's version (scripts/rsdev.py accepts only this).
teelog.SCHEMA = 1

-- A line's text is cut to this many bytes, so one huge print can't fill a batch.
teelog.MAX_TEXT = 2048

local CUT_MARK = "...[cut]"

-- The text of a print/log call's arguments: each tostring'd, joined with a space.
---@param ... any
---@return string
function teelog.joined(...)
    local parts = table.pack(...)
    for i = 1, parts.n do
        parts[i] = tostring(parts[i])
    end
    return table.concat(parts, " ", 1, parts.n)
end

-- How many bytes the UTF-8 sequence starting at byte `i` of `s` takes, or nil if the bytes
-- there are not a valid one (a stray continuation byte, an overlong form, a surrogate, a
-- code point past U+10FFFF, or a truncated sequence). The client has no `utf8` library
-- (docs/api-concepts.md), so this checks by hand.
---@param s string
---@param i integer
---@return integer?
local function sequenceLength(s, i)
    local lead = s:byte(i)
    if lead < 0x80 then return 1 end
    if lead < 0xC2 then return nil end -- continuation byte, or an overlong 2-byte lead
    local length
    if lead < 0xE0 then
        length = 2
    elseif lead < 0xF0 then
        length = 3
    elseif lead <= 0xF4 then
        length = 4
    else
        return nil
    end
    -- The second byte's range excludes overlongs (E0, F0), surrogates (ED) and > U+10FFFF (F4).
    local low, high = 0x80, 0xBF
    if lead == 0xE0 then
        low = 0xA0
    elseif lead == 0xED then
        high = 0x9F
    elseif lead == 0xF0 then
        low = 0x90
    elseif lead == 0xF4 then
        high = 0x8F
    end
    local second = s:byte(i + 1)
    if not second or second < low or second > high then return nil end
    for k = 2, length - 1 do
        local follow = s:byte(i + k)
        if not follow or follow < 0x80 or follow > 0xBF then return nil end
    end
    return length
end

-- `text` with every byte that is not part of a valid UTF-8 sequence replaced by "?".
---@param text string
---@return string
local function sanitize(text)
    local out, i, n = {}, 1, #text
    while i <= n do
        local length = sequenceLength(text, i)
        if length then
            out[#out + 1] = text:sub(i, i + length - 1)
            i = i + length
        else
            out[#out + 1] = "?"
            i = i + 1
        end
    end
    return table.concat(out)
end

-- `text` without a character a byte cut left unfinished at its end: a lead byte in the last
-- 3 bytes that wants more continuation bytes than follow it.
---@param text string
---@return string
local function dropPartialEnd(text)
    local n = #text
    for back = 1, math.min(3, n) do
        local byte = text:byte(n - back + 1)
        if byte < 0x80 then return text end
        if byte >= 0xC0 then
            local want = byte >= 0xF0 and 4 or byte >= 0xE0 and 3 or 2
            return want > back and text:sub(1, n - back) or text
        end
    end
    return text
end

-- `text` cut to at most `max` bytes plus a marker, and valid UTF-8 whatever it held: the
-- daemon rejects a body that isn't, and a byte cut can split a character. Bytes that were
-- never UTF-8 (the console takes any) become "?". The work is bounded by `max`.
---@param text string
---@param max integer
---@return string
function teelog.cut(text, max)
    local cut = #text > max
    if cut then text = dropPartialEnd(text:sub(1, max)) end
    text = sanitize(text)
    return cut and (text .. CUT_MARK) or text
end

-- One line, encoded for a batch: `tick` is Logic ticks since the tee installed.
---@param tick integer
---@param level string "print", "log" or "error"
---@param text string
---@return string
function teelog.encode(tick, level, text)
    return json.encode({ t = tick, level = level, text = teelog.cut(text, teelog.MAX_TEXT) })
end

---------------------------------------------------------------------------
-- The queue: encoded lines waiting to be sent, oldest first
---------------------------------------------------------------------------

-- Lines sit at queue[first..last]; a failed batch goes back in front of `first`.
---@return table
function teelog.newQueue()
    return { first = 1, last = 0, bytes = 0 }
end

---@param queue table
---@return integer
function teelog.count(queue)
    return queue.last - queue.first + 1
end

-- Drop the oldest lines until at most `maxLines` lines and `maxBytes` bytes remain (always
-- keeping the newest). Returns how many were dropped.
---@param queue table
---@param maxLines integer
---@param maxBytes integer
---@return integer
local function trim(queue, maxLines, maxBytes)
    local dropped = 0
    while queue.first < queue.last and (teelog.count(queue) > maxLines or queue.bytes > maxBytes) do
        queue.bytes = queue.bytes - #queue[queue.first]
        queue[queue.first] = nil
        queue.first = queue.first + 1
        dropped = dropped + 1
    end
    return dropped
end

-- Add an encoded line, then trim. Returns how many lines were dropped.
---@param queue table
---@param line string
---@param maxLines integer
---@param maxBytes integer
---@return integer
function teelog.push(queue, line, maxLines, maxBytes)
    queue.last = queue.last + 1
    queue[queue.last] = line
    queue.bytes = queue.bytes + #line
    return trim(queue, maxLines, maxBytes)
end

-- Remove and return the oldest lines, at most `maxLines` and `maxBytes` bytes (at least one).
---@param queue table
---@param maxLines integer
---@param maxBytes integer
---@return string[]
function teelog.take(queue, maxLines, maxBytes)
    local out, bytes = {}, 0
    while queue.first <= queue.last do
        local line = queue[queue.first]
        if #out > 0 and (#out >= maxLines or bytes + #line > maxBytes) then break end
        out[#out + 1] = line
        bytes = bytes + #line
        queue[queue.first] = nil
        queue.first = queue.first + 1
        queue.bytes = queue.bytes - #line
    end
    return out
end

-- Put lines taken earlier back in front, oldest first, then trim: a batch that failed to send
-- keeps its lines unless the cap says otherwise. Returns how many lines were dropped.
---@param queue table
---@param lines string[]
---@param maxLines integer
---@param maxBytes integer
---@return integer
function teelog.requeue(queue, lines, maxLines, maxBytes)
    if #lines == 0 then return 0 end
    for i = #lines, 1, -1 do
        queue.first = queue.first - 1
        queue[queue.first] = lines[i]
        queue.bytes = queue.bytes + #lines[i]
    end
    return trim(queue, maxLines, maxBytes)
end

---------------------------------------------------------------------------
-- Batches and retries
---------------------------------------------------------------------------

-- A batch's POST body: `meta` (schema, plugin, session, seq, dropped) plus the encoded lines.
---@param meta table
---@param lines string[]
---@return string
function teelog.body(meta, lines)
    return recording.batchBody(meta, lines, "lines")
end

-- Ticks to wait after the `failures`-th failure in a row: `base`, doubling each time, up to `max`.
---@param failures integer
---@param base integer
---@param max integer
---@return integer
function teelog.backoff(failures, base, max)
    local wait = base
    for _ = 2, failures do
        wait = wait * 2
        if wait >= max then return max end
    end
    return math.min(wait, max)
end

return teelog
