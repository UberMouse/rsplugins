-- Cutting a row's text short with "..." so it fits a width. Pure: the shell gives `measure`
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

return M
