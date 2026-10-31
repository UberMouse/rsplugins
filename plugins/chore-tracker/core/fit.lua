-- Cutting a row's text short with "..." so it fits a width, and breaking a paragraph into
-- lines that fit one (the info view's help). Pure: the shell gives `measure`
-- (the client font's pixel width of a string), so nothing here calls the API.

local M = {}

M.ELLIPSIS = "..."

-- `text` as is when `measure(text)` is within `maxWidth`; otherwise its longest prefix that
-- fits together with "...", with the spaces before the dots dropped. When not even "..." fits,
-- just "...": a label is never blank. Returns the text to show and whether it was cut. It
-- measures at most #text + 1 strings. Names are ASCII, so it cuts between bytes.
---@param text string
---@param maxWidth number
---@param measure fun(text: string): number
---@return string shown
---@return boolean shortened
function M.fit(text, maxWidth, measure)
    if measure(text) <= maxWidth then return text, false end
    local budget = maxWidth - measure(M.ELLIPSIS)
    for n = #text - 1, 1, -1 do
        local prefix = text:sub(1, n)
        if measure(prefix) <= budget then return (prefix:gsub("%s+$", "")) .. M.ELLIPSIS, true end
    end
    return M.ELLIPSIS, true
end

-- The line-break tag the client's text takes.
M.BREAK = "<br>"

-- `text` with a "<br>" put between words wherever the next word would take a line past
-- `maxWidth`, so the client never has to wrap it itself. A "<br>" already in `text` stays a
-- break. A word wider than `maxWidth` gets a line of its own and is not split. Words are split
-- at spaces only, so a tag such as "<col=ffd700>" must not contain one.
---@param text string
---@param maxWidth number
---@param measure fun(text: string): number
---@return string
function M.wrap(text, maxWidth, measure)
    local out = {}
    -- A trailing break makes the last piece "" too, so a text ending in "<br>" keeps it.
    for piece in (text .. M.BREAK):gmatch("(.-)" .. M.BREAK) do
        local line = nil ---@type string?
        for word in piece:gmatch("%S+") do
            local longer = line and (line .. " " .. word) or word
            if line and measure(longer) > maxWidth then
                out[#out + 1] = line
                line = word
            else
                line = longer
            end
        end
        out[#out + 1] = line or ""
    end
    return table.concat(out, M.BREAK)
end

return M
