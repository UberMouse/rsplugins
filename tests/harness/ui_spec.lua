-- The ui root fake: ui.Interfaces:GetComponent for the plugin layer, id.Component for its
-- name, and nothing else.

local harness = require("tests.harness")
local paths = require("tests.harness.paths")
local ui = require("tests.harness.api.ui")

---@param main string
---@return table h
local function load(main)
    return harness.load({ ["main.lua"] = main })
end

describe("ui root fake", function()
    it("gives the plugin layer at 0,0, 3836x2121", function()
        local h = load([[
            root = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
            shape = { root.x, root.y, root.width, root.height, root.xyGlobal.x, root.xyGlobal.y,
                root.hidden }
        ]])
        assert.are.same({ 0, 0, 3836, 2121, 0, 0, false }, h.env.shape)
    end)

    it("uses the plugin layer's ID from docs/api/consts", function()
        local line = ""
        for l in io.lines(paths.repo("docs/api/consts/Component.lua")) do
            if l:find(ui.PLUGIN_LAYER_NAME .. " =", 1, true) then
                line = l
                break
            end
        end
        assert.matches(ui.PLUGIN_LAYER_NAME .. " = " .. ui.PLUGIN_LAYER_ID .. ",", line)
    end)

    it("faults on any other id.Component name, id table or ui member", function()
        assert.matches(
            "unmocked API: id.Component.TOPLEVEL_V2__GAME_AREA",
            harness.errorOf(load, "local _ = id.Component.TOPLEVEL_V2__GAME_AREA")
        )
        assert.matches("unmocked API: _global.id.Font", harness.errorOf(load, "local _ = id.Font"))
        assert.matches("unmocked API: ui.Layer", harness.errorOf(load, "local _ = ui.Layer"))
        assert.matches(
            "only id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP is modelled",
            harness.errorOf(load, "ui.Interfaces:GetComponent(12345)")
        )
    end)

    it("serves id.Sound names from docs/api/consts/Sound.lua, and faults on others", function()
        local h = load("sound = id.Sound.ARCH_INFO_POPUP")
        assert.are.equal(48145, h.env.sound)
        assert.are.equal(60041, load("sound = id.Sound.LEAGUE2_HARD_TASK_COMPLETE").env.sound)
        assert.matches(
            "unknown sound: id.Sound.NOT_A_SOUND",
            harness.errorOf(load, "local _ = id.Sound.NOT_A_SOUND")
        )
    end)

    it("faults on the wrong call form and unmodelled component members", function()
        assert.matches(
            "called with '%.'",
            harness.errorOf(load, "ui.Interfaces.GetComponent(96797567)")
        )
        assert.matches(
            "unmocked API: ui.Component.Subscribe",
            harness.errorOf(load, "local _ = ui.Interfaces:GetComponent(96797567).Subscribe")
        )
    end)

    it("refuses to move or destroy the client's root layer", function()
        assert.matches(
            "the plugin root layer is the client's",
            harness.errorOf(load, "ui.Interfaces:GetComponent(96797567):SetPos(1, 1)")
        )
        assert.matches(
            "the plugin root layer is the client's",
            harness.errorOf(load, "ui.Interfaces:GetComponent(96797567):Destroy()")
        )
    end)
end)

describe("fake ui components", function()
    -- The PrettyUI fake builds these; a plugin can't create ui.* components itself.
    it("place a child from its parent's size, and follow the parent", function()
        local _, rootState = ui.create("Component", nil)
        local parent = ui.create("Layer", rootState)
        parent:SetPos(100, 50)
        parent:SetSize(300, 200)
        local child = ui.create("Sprite", ui.stateOf(parent))
        child:SetPos(-28, 7, 1.0)
        child:SetSize(20, 20)
        assert.are.same(
            { 272, 7, 372, 57 },
            { child.x, child.y, child.xyGlobal.x, child.xyGlobal.y }
        )
        parent:SetPos(10, 10)
        parent:SetSize(400, 200)
        assert.are.same(
            { 372, 7, 382, 17 },
            { child.x, child.y, child.xyGlobal.x, child.xyGlobal.y }
        )
    end)

    it("size relative to the parent with the 4-argument SetSize", function()
        local _, rootState = ui.create("Component", nil)
        local layer = ui.create("Layer", rootState)
        layer:SetSize(-16, 10, 1.0, 0.5)
        assert.are.same({ 3820, 1071 }, { layer.width, layer.height })
    end)

    it("move to the front of their siblings, and fault once destroyed", function()
        local _, rootState = ui.create("Component", nil)
        local a = ui.create("Layer", rootState)
        local b = ui.create("Layer", rootState)
        a:MoveToFront()
        assert.are.equal(ui.stateOf(a), rootState.children[2])
        local child = ui.create("Text", ui.stateOf(a))
        a:Destroy()
        assert.matches(
            "ui.Text used after Destroy",
            harness.errorOf(function()
                return child.x
            end)
        )
        assert.are.equal(1, #rootState.children)
        assert.are.equal(ui.stateOf(b), rootState.children[1])
    end)

    it("fault on SetPos's self-percentage arguments", function()
        local _, rootState = ui.create("Component", nil)
        local layer = ui.create("Layer", rootState)
        assert.matches(
            "self%-percentage",
            harness.errorOf(function()
                layer:SetPos(0, 0, 0, 0, 0.5, 0.5)
            end)
        )
    end)
end)
