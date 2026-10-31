-- The plugin layer's component tree, for `rsdev.py click`/`move`/`drag` (scripts/rsdev.py,
-- "input"): every component under the plugin layer, so the CLI can find one by its text, clip
-- each rect by its ancestors and check that a point it is about to click is plugin UI. It only
-- reads.
--
-- Not part of the plugin: an eval snippet the CLI sends (`rsdev.py eval --file` runs it too).
-- It returns the interface scale, whether the walk was cut short, then the nodes as lines of
-- tab-separated fields: parent index (0 for the plugin layer itself), type, global x, y,
-- width, height, flags (c clickthrough, e enabled, v visible) and the text or label.
--
-- Two eval caps shape the reply. Eval's serialiser cuts any string past 4096 bytes
-- (recording.MAX_STRING in lib/dev/recording.lua), so the lines come in strings of at most
-- CHUNK_BYTES. And eval drops all of a result's values once their encoded total passes 64 KB
-- (valueBytes, command.resultEntry in lib/dev/command.lua), so the walk stops before
-- VALUE_BUDGET, which leaves room for the scale, the flag and the JSON punctuation. That
-- budget holds about 1500 components; a walk of 1600 fit in one eval call, under the
-- client's 1000 ms per-call limit (docs/api-concepts.md).

local CHUNK_BYTES = 4000
local VALUE_BUDGET = 60 * 1024
local MAX_TEXT = 80

-- Component types that hold children (ui.ComponentCollection). Enums are numbers in the
-- client and strings in the stubs; naming the members works for both.
local CONTAINERS = {
    [ui.ComponentType.LAYER] = true,
    [ui.ComponentType.PANEL] = true,
    [ui.ComponentType.GRID] = true,
    [ui.ComponentType.PAGED_LAYER] = true,
    [ui.ComponentType.GROUP_BOX] = true,
}

-- What a component shows as text, if it is a label or a button. Control characters would break
-- the line format (tab, newline) or cost six bytes each once JSON-escaped, so they become spaces.
---@param c ui.Component
---@return string
local function textOf(c)
    local text = ""
    if c.type == ui.ComponentType.LABEL then
        text = (c --[[@as ui.Text]]).content
    elseif c.type == ui.ComponentType.BUTTON then
        text = (c --[[@as ui.Button]]).label
    end
    return (tostring(text or ""):gsub("%c", " "):sub(1, MAX_TEXT))
end

-- A line's share of the encoded values: its bytes and its newline, plus one for each byte JSON
-- escapes (the tabs, the newline, and quotes or backslashes in the text).
---@param line string
---@return integer
local function encodedCost(line)
    local _, escaped = line:gsub('[\t"\\]', "")
    return #line + 2 + escaped
end

local chunks, current, chunkBytes = {}, {}, 0
local count, budget = 0, VALUE_BUDGET
local truncated = false

---@param line string
---@return boolean added false once the budget is spent
local function addLine(line)
    local cost = encodedCost(line)
    if cost > budget then return false end
    budget = budget - cost
    if chunkBytes + #line + 1 > CHUNK_BYTES then
        chunks[#chunks + 1] = table.concat(current, "\n")
        current, chunkBytes = {}, 0
    end
    current[#current + 1] = line
    chunkBytes = chunkBytes + #line + 1
    count = count + 1
    return true
end

---@param c ui.Component
---@param parent integer
local function add(c, parent)
    local flags = (c.clickthrough and "c" or "")
        .. (c.enabled and "e" or "")
        .. (c.visibleGlobal and "v" or "")
    local g = c.xyGlobal
    local line = string.format(
        "%d\t%d\t%.0f\t%.0f\t%.0f\t%.0f\t%s\t%s",
        parent,
        c.type,
        g.x,
        g.y,
        c.width,
        c.height,
        flags,
        textOf(c)
    )
    if not addLine(line) then
        truncated = true
        return
    end
    local index = count
    if CONTAINERS[c.type] then
        -- A callback that returns true stops the iteration (docs/api-concepts.md), which ends
        -- the walk once the budget is spent.
        (c --[[@as ui.ComponentCollection]]):IterateDynamicComponents(function(child)
            add(child, index)
            return truncated
        end)
    end
end

local root = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
assert(root, "the plugin layer should exist once a plugin runs")
add(root, 0)
chunks[#chunks + 1] = table.concat(current, "\n")

-- Each option is game.options.<option name>, per core/clientoptions.html#example (the stub types
-- game.options as one option). The page names no options: InterfaceScale is from a live read
-- (docs/api-concepts.md).
---@diagnostic disable-next-line: undefined-field
return game.options.InterfaceScale.setting, truncated, table.unpack(chunks)
