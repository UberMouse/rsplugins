-- The dev log tee's pure core: shaping a console line, a batch's body, and the retry
-- backoff. Nothing here calls the API or keeps state of its own; dev/tee.lua (the shell) does
-- both. The wire format is docs/dev-environment.md ("Log tee").

local json = require("dev/json")
local recording = require("dev/recording")

local teelog = {}

-- The tee protocol's version (scripts/rsdev.py accepts only this).
teelog.SCHEMA = 1

-- A line's text is cut to this many bytes, so one huge print can't fill a batch.
teelog.MAX_TEXT = 2048

local CUT_MARK = "...[cut]"

-- `text` cut to at most `max` bytes plus a marker. The cut is by byte, so it can split a
-- UTF-8 character; the daemon decodes request bodies with errors="replace" (scripts/rsdev.py),
-- so that costs a replacement character, not the batch.
---@param text string
---@param max integer
---@return string
function teelog.cut(text, max)
    if #text <= max then return text end
    return text:sub(1, max) .. CUT_MARK
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
