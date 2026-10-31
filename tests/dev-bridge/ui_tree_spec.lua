-- plugins/dev-bridge/probes/ui-tree.lua run against a hand-built component tree (the harness
-- models neither IterateDynamicComponents nor game.options): the line format, and a big
-- layer's reply fitting eval's caps, each string under 4096 bytes and all values under 64 KB.

local json = require("dev/json")

local PROBE = "plugins/dev-bridge/probes/ui-tree.lua"
local TYPES =
    { LABEL = 2, BUTTON = 9, LAYER = 20, PANEL = 21, GRID = 22, PAGED_LAYER = 23, GROUP_BOX = 24 }

-- A component as the probe reads it; `children` makes it iterable.
---@param t table
---@return table
local function component(t)
    t.xyGlobal = { x = t.x or 0, y = t.y or 0 }
    t.width, t.height = t.width or 10, t.height or 10
    t.visibleGlobal = t.visibleGlobal ~= false
    function t:IterateDynamicComponents(fn)
        for _, child in ipairs(self.children or {}) do
            if fn(child) then return end
        end
    end
    return t
end

-- The probe's return values, walking `root` as the plugin layer.
---@param root table
---@return table
local function walk(root)
    local env = setmetatable({
        ui = {
            ComponentType = TYPES,
            Interfaces = {
                GetComponent = function()
                    return root
                end,
            },
        },
        id = { Component = { TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP = 1 } },
        game = { options = { InterfaceScale = { setting = 100 } } },
    }, { __index = _G })
    -- selene: allow(incorrect_standard_library_use) -- its std has the pre-5.2 load/loadfile
    return table.pack(assert(loadfile(PROBE, "t", env))())
end

describe("ui-tree probe", function()
    it("writes one line per component, parents by line index, text cleaned", function()
        local root =
            component({ type = TYPES.LAYER, clickthrough = true, width = 800, height = 600 })
        local panel = component({ type = TYPES.PANEL, x = 10.4, y = 20, enabled = true })
        root.children = {
            panel,
            component({ type = TYPES.BUTTON, label = "Go", visibleGlobal = false }),
        }
        panel.children = { component({ type = TYPES.LABEL, content = 'a\tb\n"c"', width = 5.5 }) }
        local r = walk(root)
        assert.are.same({ 100, false, 3 }, { r[1], r[2], r.n })
        assert.are.same(
            {
                "0\t20\t0\t0\t800\t600\tcv\t",
                "1\t21\t10\t20\t10\t10\tev\t",
                '2\t2\t0\t0\t6\t10\tv\ta b "c"',
                "1\t9\t0\t0\t10\t10\t\tGo",
            },
            (function()
                local lines = {}
                for line in r[3]:gmatch("[^\n]+") do
                    lines[#lines + 1] = line
                end
                return lines
            end)()
        )
    end)

    it("cuts a big layer short within eval's string and value caps", function()
        local root = component({ type = TYPES.LAYER })
        root.children = {}
        for i = 1, 3000 do
            local text = string.rep('"', 10) .. string.rep("x", 60) .. i
            root.children[i] = component({ type = TYPES.LABEL, content = text })
        end
        local r = walk(root)
        assert.is_true(r[2])
        local encoded, lines = 0, 0
        for i = 1, r.n do
            encoded = encoded + #json.encode(r[i]) + 1
            if i >= 3 then
                assert.is_true(#r[i] <= 4096)
                lines = lines + select(2, r[i]:gsub("\n", "")) + 1
            end
        end
        assert.is_true(encoded <= 64 * 1024)
        assert.is_true(encoded > 56 * 1024) -- the budget is nearly used
        assert.is_true(lines > 500 and lines < 3001)
    end)
end)
