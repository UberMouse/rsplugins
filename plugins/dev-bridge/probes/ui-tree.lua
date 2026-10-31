-- The plugin layer's component tree, for `rsdev.py click`/`move`/`drag` (scripts/rsdev.py,
-- "input"): every component under the plugin layer, so the CLI can find one by its text, clip
-- each rect by its ancestors and check that a point it is about to click is plugin UI. It only
-- reads.
--
-- Not part of the plugin: an eval snippet the CLI sends (`rsdev.py eval --file` runs it too).
-- It returns the interface scale, whether the walk was cut short, then the nodes as lines of
-- tab-separated fields: parent index (0 for the plugin layer itself), type, global x, y,
-- width, height, flags (c clickthrough, e enabled, v visible) and the text or label. The lines
-- come in chunks, because eval drops any single value over 64 KB.

local MAX_NODES = 4000 -- keeps the walk well inside the client's 1000 ms per-call limit
local CHUNK_BYTES = 48 * 1024
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

-- What a component shows as text, if it is a label or a button; tabs and newlines would break
-- the line format, so they become spaces.
---@param c ui.Component
---@return string
local function textOf(c)
    local text = ""
    if c.type == ui.ComponentType.LABEL then
        text = (c --[[@as ui.Text]]).content
    elseif c.type == ui.ComponentType.BUTTON then
        text = (c --[[@as ui.Button]]).label
    end
    return (tostring(text or ""):gsub("[\t\r\n]", " "):sub(1, MAX_TEXT))
end

local lines = {}
local truncated = false

---@param c ui.Component
---@param parent integer
local function add(c, parent)
    if #lines >= MAX_NODES then
        truncated = true
        return
    end
    local flags = (c.clickthrough and "c" or "")
        .. (c.enabled and "e" or "")
        .. (c.visibleGlobal and "v" or "")
    local g = c.xyGlobal
    lines[#lines + 1] = string.format(
        "%d\t%d\t%.0f\t%.0f\t%d\t%d\t%s\t%s",
        parent,
        c.type,
        g.x,
        g.y,
        c.width,
        c.height,
        flags,
        textOf(c)
    )
    local index = #lines
    if CONTAINERS[c.type] then
        -- A callback that returns true stops the iteration (docs/api-concepts.md).
        (c --[[@as ui.ComponentCollection]]):IterateDynamicComponents(function(child)
            add(child, index)
            return false
        end)
    end
end

local root = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
assert(root, "the plugin layer should exist once a plugin runs")
add(root, 0)

local chunks, size, current = {}, 0, {}
for _, line in ipairs(lines) do
    if size + #line + 1 > CHUNK_BYTES then
        chunks[#chunks + 1] = table.concat(current, "\n")
        current, size = {}, 0
    end
    current[#current + 1] = line
    size = size + #line + 1
end
chunks[#chunks + 1] = table.concat(current, "\n")

-- Each option is game.options.<option name>, per core/clientoptions.html#example (the stub types
-- game.options as one option).
---@diagnostic disable-next-line: undefined-field
return game.options.InterfaceScale.setting, truncated, table.unpack(chunks)
