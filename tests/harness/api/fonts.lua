-- config.Font.<NAME>: a FontType whose only modelled member is GetStringWidth. The widths are
-- an approximation: the real font's glyphs vary and it kerns, which a per-character table
-- doesn't. The table below is tuned toward what the beta client measured for
-- MUSEO_SANS_15PT_REGULAR (dev bridge, 2026-10-29), listed in docs/testing.md; it is no
-- substitute for the client where an exact width matters.

local catalog = require("tests.harness.catalog")
local strict = require("tests.harness.strict")

local M = {}

-- Pixel widths for the characters measured or guessed narrow or wide; any other is DEFAULT.
local DEFAULT = 8
local WIDTHS = {
    ["W"] = 14,
    ["i"] = 4,
    ["l"] = 4,
    ["1"] = 5, -- a guess (proportional fonts draw it narrow); the measurements don't cover digits
    ["."] = 4,
    [" "] = 4,
    ["("] = 5,
    [")"] = 5,
    ["/"] = 5,
}

-- The width of `text`. With ignoreTags false the client parses `<...>` tags and counts only
-- the text between them; with true it counts them as text (measured: `<col=ff0000>red</col>`
-- 25 and 160).
---@param text string
---@param ignoreTags boolean
---@return integer
local function width(text, ignoreTags)
    if not ignoreTags then text = text:gsub("<[^>]*>", "") end
    local total = 0
    for ch in text:gmatch(".") do
        total = total + (WIDTHS[ch] or DEFAULT)
    end
    return total
end
M.width = width

local Font = strict.class("FontType", {
    fields = {
        id = "id",
        configName = "name",
        typeName = function()
            return "Font"
        end,
    },
    methods = {
        GetStringWidth = function(_, text, ignoreTags)
            if type(text) ~= "string" then
                strict.fault("Font:GetStringWidth(text: string, ...)")
            end
            if ignoreTags ~= nil and type(ignoreTags) ~= "boolean" then
                strict.fault("Font:GetStringWidth: ignoreTags is a boolean")
            end
            return width(text, ignoreTags == true)
        end,
    },
})

-- config.Font: one font object per name, the same each time. An unknown name faults.
---@return table
function M.table()
    local made = {}
    return strict.lookup("config.Font", function(name)
        local id = catalog.config("Font", name)
        if not id then strict.fault("unknown font: config.Font." .. tostring(name)) end
        ---@cast id -? -- fault() never returns
        made[name] = made[name] or Font.new({ id = id, name = name })
        return made[name]
    end, {
        extra = {
            FromID = function()
                strict.fault("unmocked API: config.Font.FromID")
            end,
        },
    })
end

return M
