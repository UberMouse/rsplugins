-- The ui root fake: ui.Interfaces:GetComponent for the plugin layer, id.Component for its
-- name, a plugin's own ui.Layer/Sprite/Text, ui.Hook, ui.AlignMode and the
-- id.Sound/Font/Sprite/Obj names, and nothing else.

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
        assert.matches("unmocked API: _global.id.Inv", harness.errorOf(load, "local _ = id.Inv"))
        assert.matches("unmocked API: ui.Button", harness.errorOf(load, "local _ = ui.Button"))
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
            "unmocked API: ui.ComponentCursorConfig.targetValidCursor",
            harness.errorOf(
                load,
                "local _ = ui.Interfaces:GetComponent(96797567).cursorConfig.targetValidCursor"
            )
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

    it("stay where they are on MoveToFront while hidden, and count the calls", function()
        local _, rootState = ui.create("Component", nil)
        local a = ui.create("Layer", rootState)
        ui.create("Layer", rootState)
        a.hidden = true
        a:MoveToFront()
        assert.are.equal(ui.stateOf(a), rootState.children[1])
        a.hidden = false
        a:MoveToFront()
        assert.are.equal(ui.stateOf(a), rootState.children[2])
        assert.are.equal(2, ui.stateOf(a).frontCalls)
    end)

    it("fault on isClicked, unless the fake models it", function()
        local _, rootState = ui.create("Component", nil)
        local layer = ui.create("Layer", rootState)
        assert.matches(
            "isClicked read before it was set",
            harness.errorOf(function()
                return layer.isClicked
            end)
        )
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

-- A plugin's own components. `root` is the plugin layer, `row` a layer under it. The manifest
-- lists PrettyUI so the h.ui driver is there.
local MANIFEST = [[{ "name": "t", "version": "1", "contactEmailAddress": "t@example.com",
    "requiredDependencies": { "prettyui": 6398181 } }]]

local PRELUDE = [[
root = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
row = ui.Layer.new(root)
]]

---@param main string
---@return table h
local function loadRows(main)
    return harness.load({ ["main.lua"] = PRELUDE .. main, ["plugin.json"] = MANIFEST })
end

describe("a plugin's own components", function()
    it(
        "construct under the plugin layer, a layer or another component, and place like any",
        function()
            local h = loadRows([[
            row:SetPos(10, 20)
            row:SetSize(-16, 28, 1.0)
            icon = ui.Sprite.new(row)
            icon:SetSize(24, 24)
            icon:SetPos(4, 2)
            text = ui.Text.new(row)
            shape = { row.x, row.y, row.width, row.height, icon.xyGlobal.x, icon.xyGlobal.y,
                text.content }
        ]])
            assert.are.same({ 10, 20, 3820, 28, 14, 22, "" }, h.env.shape)
            assert.are.equal(h.env.row.xyGlobal.x, 10)
        end
    )

    it(
        "fault on a missing, destroyed or non-collection parent, and on unmocked arguments",
        function()
            assert.matches("parent must be", harness.errorOf(loadRows, "ui.Layer.new(nil)"))
            assert.matches("parent must be", harness.errorOf(loadRows, "ui.Sprite.new({})"))
            assert.matches(
                "parent was destroyed",
                harness.errorOf(
                    loadRows,
                    [[
            row:Destroy()
            ui.Text.new(row)
        ]]
                )
            )
            assert.matches(
                "not a ui.ComponentCollection",
                harness.errorOf(loadRows, "ui.Layer.new(ui.Sprite.new(row))")
            )
            assert.matches(
                "unmocked API: ui.Layer.new with a categoryID or dynamicID",
                harness.errorOf(loadRows, "ui.Layer.new(row, 1)")
            )
            assert.matches(
                "unmocked API: ui.Text.new with a categoryID or dynamicID",
                harness.errorOf(loadRows, "ui.Text.new(row, nil, 2)")
            )
            assert.matches("called with ':'", harness.errorOf(loadRows, "ui.Layer:new(row)"))
        end
    )

    it("read and write clickthrough, alpha and rgba, and fault on a read before a write", function()
        local h = loadRows([[
            row.clickthrough = false
            icon = ui.Sprite.new(row)
            icon.alpha = 0.5
            icon.rgba = 0xE7D7B0FF
            vals = { row.clickthrough, icon.alpha, icon.rgba, icon.isMouseOver }
        ]])
        assert.are.same({ false, 0.5, 0xE7D7B0FF, false }, h.env.vals)
        for _, member in ipairs({ "clickthrough", "alpha", "rgba" }) do
            assert.matches(
                member .. " read before it was set",
                harness.errorOf(loadRows, "local _ = row." .. member)
            )
        end
    end)

    it("fault on a wrongly typed write, and on writing isMouseOver", function()
        assert.matches(
            "clickthrough must be a boolean",
            harness.errorOf(loadRows, "row.clickthrough = 1")
        )
        assert.matches("alpha must be a number", harness.errorOf(loadRows, "row.alpha = '1'"))
        assert.matches("rgba must be an integer", harness.errorOf(loadRows, "row.rgba = 1.5"))
        assert.matches(
            "rgba must be an integer",
            harness.errorOf(loadRows, "row.rgba = 0x100000000")
        )
        assert.matches(
            "isMouseOver is read%-only",
            harness.errorOf(loadRows, "row.isMouseOver = true")
        )
    end)

    it("fault on every member once destroyed, reads and writes alike", function()
        for _, code in ipairs({
            "local _ = row.clickthrough",
            "row.clickthrough = false",
            "row.alpha = 1",
            "local _ = row.isMouseOver",
            "row:Subscribe(ui.Hook.ONCLICK, function() end)",
            "row:Unsubscribe(ui.Hook.ONCLICK)",
        }) do
            assert.matches(
                "used after Destroy",
                harness.errorOf(loadRows, "row.clickthrough = true; row:Destroy()\n" .. code)
            )
        end
    end)

    it("give a sprite spriteID and an associated object from docs/api/consts/Obj.lua", function()
        local h = loadRows([[
            box = ui.Sprite.new(row)
            box.spriteID = id.Sprite.RS3_BTN_CHECKBOX_SMALL_2
            before = box.associatedObjectID
            box:SetAssociatedObject(995)
            after = box.associatedObjectID
            box:SetAssociatedObject(995, 5)
            shape = { box.spriteID }
        ]])
        assert.are.same({ 20326 }, h.env.shape)
        assert.are.same({ -1, 995 }, { h.env.before, h.env.after })
        assert.matches(
            "no object with id 99999999",
            harness.errorOf(
                loadRows,
                [[
            ui.Sprite.new(row):SetAssociatedObject(99999999)
        ]]
            )
        )
        assert.matches(
            "no object with id",
            harness.errorOf(
                loadRows,
                [[
            ui.Sprite.new(row):SetAssociatedObject(-1)
        ]]
            )
        )
        assert.matches(
            "quantity must be a count",
            harness.errorOf(
                loadRows,
                [[
            ui.Sprite.new(row):SetAssociatedObject(995, -3)
        ]]
            )
        )
        assert.matches(
            "spriteID read before",
            harness.errorOf(loadRows, "local _ = ui.Sprite.new(row).spriteID")
        )
        assert.matches(
            "spriteID must be an integer",
            harness.errorOf(loadRows, "ui.Sprite.new(row).spriteID = 'x'")
        )
        assert.matches(
            "associatedObjectID is read%-only",
            harness.errorOf(loadRows, "ui.Sprite.new(row).associatedObjectID = 5")
        )
    end)

    it("give a text a font and AlignTo with ui.AlignMode members", function()
        local h = loadRows([[
            text = ui.Text.new(row)
            text.font = id.Font.MUSEO_SANS_15PT_REGULAR
            text:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)
            text:AlignTo(ui.AlignMode.CENTRE)
            font = text.font
        ]])
        assert.are.equal(30, h.env.font)
        assert.matches(
            "takes ui.AlignMode members",
            harness.errorOf(loadRows, "ui.Text.new(row):AlignTo('TOPLEFT')")
        )
        assert.matches(
            "font read before",
            harness.errorOf(loadRows, "local _ = ui.Text.new(row).font")
        )
        assert.matches(
            "unmocked API: ui.Sprite.AlignTo",
            harness.errorOf(loadRows, "local _ = ui.Sprite.new(row).AlignTo")
        )
    end)

    it("serve id.Font and id.Sprite names from the consts, and fault on others", function()
        local h =
            loadRows("f = id.Font.MUSEO_SANS_15PT_REGULAR; s = id.Sprite.RS3_BTN_CHECKBOX_SMALL_0")
        assert.are.same({ 30, 20268 }, { h.env.f, h.env.s })
        assert.matches(
            "unknown font: id.Font.NOPE",
            harness.errorOf(loadRows, "local _ = id.Font.NOPE")
        )
        assert.matches(
            "unknown sprite: id.Sprite.NOPE",
            harness.errorOf(loadRows, "local _ = id.Sprite.NOPE")
        )
        assert.matches(
            "unmocked API: id.Font.FromID",
            harness.errorOf(loadRows, "local _ = id.Font.FromID")
        )
    end)

    it("serve id.Obj names from docs/api/consts/Obj.lua, and fault on others", function()
        local h = loadRows("o = id.Obj.FEATHER; ui.Sprite.new(row):SetAssociatedObject(o)")
        assert.are.equal(314, h.env.o)
        assert.matches(
            "unknown object: id.Obj.NOPE",
            harness.errorOf(loadRows, "local _ = id.Obj.NOPE")
        )
        assert.matches(
            "unmocked API: id.Obj.FromID",
            harness.errorOf(loadRows, "local _ = id.Obj.FromID")
        )
    end)

    it("expose ui.Hook and ui.AlignMode members as numbers, and fault on others", function()
        local h = loadRows([[
            vals = { ui.Hook.ONCLICK, ui.Hook.ONSCROLLWHEEL, ui.AlignMode.TOPLEFT }
            kinds = { type(vals[1]), type(vals[2]), type(vals[3]) }
            distinct = vals[1] ~= vals[2]
        ]])
        assert.are.same({ "number", "number", "number" }, h.env.kinds)
        assert.is_true(h.env.distinct)
        assert.matches(
            "unmocked API: ui.Hook.ONNOPE",
            harness.errorOf(loadRows, "local _ = ui.Hook.ONNOPE")
        )
        assert.matches(
            "unmocked API: ui.AlignMode.LEFT",
            harness.errorOf(loadRows, "local _ = ui.AlignMode.LEFT")
        )
        assert.matches("read%-only", harness.errorOf(loadRows, "ui.Hook.ONCLICK = 1"))
    end)

    it("subscribe with and without an id, and unsubscribe the same way", function()
        local h = loadRows([[
            log = {}
            row:SetSize(100, 28)
            row.clickthrough = false
            row:Subscribe(ui.Hook.ONCLICK, function(c, x, y) log[#log + 1] = "default" end)
            row:Subscribe(ui.Hook.ONCLICK, "extra", function() log[#log + 1] = "extra" end)
            row:Unsubscribe(ui.Hook.ONCLICK, "extra")
            function dropDefault()
                row:Unsubscribe(ui.Hook.ONCLICK)
            end
        ]])
        h.ui:click(h.env.row)
        assert.are.same({ "default" }, h.env.log)
        h.env.dropDefault()
        h.ui:click(h.env.row)
        assert.are.same({ "default" }, h.env.log)
    end)

    -- The hook probe's boxes A to D (docs/api-concepts.md, hook listener returns).
    it("run the next listener only after one that returns true", function()
        -- Each case's listeners, in subscription order: the id (nil for the default) and the
        -- listener's return.
        local cases = {
            A = { { nil, "nil" }, { "named", "true" } },
            B = { { nil, "true" }, { "named", "true" } },
            C = { { "named", "true" } },
            D = { { "named", "true" }, { nil, "nil" } },
        }
        local fired = {}
        for case, listeners in pairs(cases) do
            local lines = { "log = {}", "row:SetSize(100, 28)", "row.clickthrough = false" }
            for _, l in ipairs(listeners) do
                local id, result = l[1], l[2]
                local fn = string.format(
                    "function() log[#log + 1] = %q; return %s end",
                    id or "default",
                    result
                )
                lines[#lines + 1] = id
                        and string.format("row:Subscribe(ui.Hook.ONCLICK, %q, %s)", id, fn)
                    or string.format("row:Subscribe(ui.Hook.ONCLICK, %s)", fn)
            end
            local h = loadRows(table.concat(lines, "\n"))
            h.ui:click(h.env.row)
            fired[case] = h.env.log
        end
        assert.are.same({
            A = { "default" },
            B = { "default", "named" },
            C = { "named" },
            D = { "named", "default" },
        }, fired)
    end)

    it(
        "fault on a bad hook, a bad callback, a repeated id and an Unsubscribe of nothing",
        function()
            assert.matches(
                "must be a ui.Hook member",
                harness.errorOf(loadRows, "row:Subscribe('ONCLICK', function() end)")
            )
            assert.matches(
                "Subscribe%(hook, callback%)",
                harness.errorOf(loadRows, "row:Subscribe(ui.Hook.ONCLICK, 5)")
            )
            assert.matches(
                "Subscribe%(hook, callback%)",
                harness.errorOf(loadRows, "row:Subscribe(ui.Hook.ONCLICK, 'id')")
            )
            assert.matches(
                "already has a listener under that id",
                harness.errorOf(
                    loadRows,
                    [[
            row:Subscribe(ui.Hook.ONCLICK, function() end)
            row:Subscribe(ui.Hook.ONCLICK, function() end)
        ]]
                )
            )
            assert.matches(
                "no ONCLICK listener under that id",
                harness.errorOf(loadRows, "row:Unsubscribe(ui.Hook.ONCLICK)")
            )
            assert.matches(
                "no ONCLICK listener",
                harness.errorOf(
                    loadRows,
                    [[
            row:Subscribe(ui.Hook.ONCLICK, function() end)
            row:Unsubscribe(ui.Hook.ONCLICK, "other")
        ]]
                )
            )
        end
    )
end)
