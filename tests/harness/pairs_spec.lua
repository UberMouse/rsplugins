-- Self-tests: what pairs() and # do over API values. Only what the client was probed to do
-- iterates; everything else faults as unprobed rather than silently walking nothing
-- (docs/testing.md, fidelity ledger).

local harness = require("tests.harness")
local support = require("tests.harness.spec_support")

local plugin = support.inline

-- The fault from running `body` in a plugin's main.lua (fails the spec if it loaded).
---@param body string
---@param manifest string?
---@return string
local function fault(body, manifest)
    local err = harness.errorOf(harness.load, plugin(body, { manifest = manifest }))
    assert(err, "the plugin loaded without a fault")
    return err
end

describe("pairs() and # over API values", function()
    it("iterates PluginPermissions and the manifest's Plugin.urls (both probed)", function()
        local h = harness.load(plugin(
            [[
            perms, urls = {}, {}
            for name in pairs(PluginPermissions) do perms[#perms + 1] = name end
            for name in pairs(Plugin.urls) do urls[#urls + 1] = name end
            table.sort(perms)
        ]],
            { manifest = support.HTTP_MANIFEST }
        ))
        assert.are.same({ "chatAccess", "httpAccess", "trackingAccess" }, h.env.perms)
        assert.are.same({ "sink" }, h.env.urls)
    end)

    it("faults on pairs over PersistentDBType, citing the probed refusal", function()
        assert.matches(
            "pairs over PersistentDBType: not recognized as a container",
            fault("for _ in pairs(PersistentDBType) do end")
        )
    end)

    it("faults on pairs over an enum nobody probed", function()
        assert.matches("pairs over SkillType: unprobed", fault("for _ in pairs(SkillType) do end"))
    end)

    it("faults on pairs and # over a client userdata", function()
        assert.matches(
            "pairs over a client userdata: unprobed",
            fault("for _ in pairs(ui.Interfaces) do end")
        )
        assert.matches("# over a client userdata: unprobed", fault("n = #ui.Interfaces"))
    end)

    it("faults on pairs over a lookup table that wasn't marked iterable", function()
        assert.matches(
            "pairs over a lookup table: unprobed",
            fault("for _ in pairs(ui.Hook) do end")
        )
    end)

    it("faults even when the plugin wraps the pairs in pcall", function()
        assert.matches("unprobed", fault("pcall(function() for _ in pairs(SkillType) do end end)"))
    end)
end)

describe("the raw pointer driver without PrettyUI", function()
    it("clicks, presses, hovers and wheels a plugin's own layer", function()
        local h = harness.load(plugin(support.pluginLayer("root") .. [[
            row = ui.Layer.new(root)
            row:SetSize(100, 20)
            row.clickthrough = false
            log = {}
            row:Subscribe(ui.Hook.ONCLICK, function() log[#log + 1] = "click" end)
            row:Subscribe(ui.Hook.ONMOUSEOVER, function() log[#log + 1] = "over" end)
        ]]))
        assert.is_true(h.ui:hover(h.env.row))
        assert.is_true(h.ui:click(h.env.row))
        assert.are.same({ "over", "click" }, h.env.log)
        assert.are.same({}, h.ui:records())
        assert.is_true(h.ui:press(h.env.row))
        h.ui:release()
        h:unload()
    end)
end)
