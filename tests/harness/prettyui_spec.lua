-- The PrettyUI fake (api/prettyui.lua), its dependency global and the h.ui driver. Every
-- behaviour here comes from the installed 1.2.0 source or the beta-client probe of
-- 2026-10-25 (docs/testing.md, fidelity ledger).

local harness = require("tests.harness")

local MANIFEST = [[{ "name": "t", "version": "1", "contactEmailAddress": "t@example.com",
    "requiredDependencies": { "prettyui": 6398181 } }]]

-- Runs before the test's main.lua: the plugin layer as `parent`.
local PRELUDE = [[
parent = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
]]

-- `text` as a Lua pattern that matches it literally.
---@param text string
---@return string
local function literal(text)
    return (text:gsub("%p", "%%%0"))
end

---@param main string
---@param manifest string?
---@return table h
local function load(main, manifest)
    return harness.load({ ["main.lua"] = PRELUDE .. main, ["plugin.json"] = manifest or MANIFEST })
end

-- The probe's window: 600,300, 300x200, titled and resizable, with a MENU button in the X's
-- slot as a child of its root.
local WINDOW = [[
calls = {}
win = prettyui.Window.new(parent, {
    title = "Chores", x = 600, y = 300, width = 300, height = 200, resizable = true,
    onClose = function(w) calls[#calls + 1] = { "close", w == win, w.root.hidden } end,
})
win.closeButton.hidden = true
menu = prettyui.SpriteButton.new(win.root, "MENU", function(button, enabled)
    calls[#calls + 1] = { "menu", button == menu, enabled }
end, { x = -28, y = 7, xAnchor = 1.0, size = 20 })
]]

describe("prettyui dependency global", function()
    it("is the fake, for the object form keyed by the global's name", function()
        local h = load("v = prettyui.version")
        assert.are.equal("1.2.0", h.env.v)
    end)

    it("is the fake under any key, and for optionalDependencies", function()
        local alias = [[{ "requiredDependencies": { "P": 6398181 } }]]
        assert.are.equal("1.2.0", load("v = P.version", alias).env.v)
        local optional = [[{ "optionalDependencies": { "pui": 6398181 } }]]
        assert.are.equal("1.2.0", load("v = pui.version", optional).env.v)
    end)

    -- Only the object form with the numeric ID was probed; the rest may give no global in
    -- the client, so the harness refuses them (docs/testing.md, harness choices).
    it("fails the load for the forms unconfirmed in the client", function()
        for _, manifest in ipairs({
            [[{ "requiredDependencies": ["prettyui"] }]],
            [[{ "optionalDependencies": ["6398181"] }]],
            [[{ "requiredDependencies": { "prettyui": "6398181" } }]],
            [[{ "requiredDependencies": { "prettyui": "prettyui" } }]],
        }) do
            local err = harness.errorOf(load, "", manifest)
            assert.matches("form unconfirmed in the client", err)
            assert.matches(literal("use the object form with the numeric mod.io ID"), err)
        end
        assert.matches(
            literal('"prettyui": "6398181" names a faked dependency'),
            harness.errorOf(load, "", [[{ "requiredDependencies": { "prettyui": "6398181" } }]])
        )
        -- The suggestion keeps the global the plugin uses now.
        assert.matches(
            literal(
                '["prettyui"] names a faked dependency in a form unconfirmed in the client; use '
                    .. 'the object form with the numeric mod.io ID, e.g. { "prettyui": 6398181 }'
            ),
            harness.errorOf(load, "", [[{ "requiredDependencies": ["prettyui"] }]])
        )
    end)

    it("is absent for a plugin that lists no dependency", function()
        assert.matches(
            "unmocked API: prettyui",
            harness.errorOf(load, "local _ = prettyui", [[{ "name": "t" }]])
        )
    end)

    it("fails the load for a dependency the harness has no fake for, naming it", function()
        assert.matches(
            "no fake for dependency 1234 %(global graph%)",
            harness.errorOf(load, "", [[{ "requiredDependencies": { "graph": 1234 } }]])
        )
        assert.matches(
            "no fake for dependency 2!GraphLib %(global _2_GraphLib%)",
            harness.errorOf(load, "", [[{ "optionalDependencies": ["2!GraphLib"] }]])
        )
        -- Several bad ones: always the first in key order.
        assert.matches(
            "dependency 1 %(global a%)",
            harness.errorOf(load, "", [[{ "requiredDependencies": { "b": 2, "c": 3, "a": 1 } }]])
        )
    end)

    it("faults on members, methods and options outside the modelled subset", function()
        assert.matches(
            "unmocked API: prettyui.Slider",
            harness.errorOf(load, "local _ = prettyui.Slider")
        )
        assert.matches(
            "option 'xAnchor'",
            harness.errorOf(load, "prettyui.Window.new(parent, { xAnchor = 1 })")
        )
        assert.matches(
            "option 'titel'",
            harness.errorOf(load, "prettyui.Window.new(parent, { zz = 1, titel = 't', yy = 2 })")
        )
        assert.matches(
            "unmocked API: prettyui.Window instance.AddSlider",
            harness.errorOf(load, "prettyui.Window.new(parent, {}):AddSlider({})")
        )
        assert.matches("called with ':'", harness.errorOf(load, "prettyui.Window:new(parent, {})"))
    end)
end)

describe("prettyui Window", function()
    it("puts the close X and a slot button at (width-28, 7), as in the probe", function()
        local h = load(WINDOW)
        local menu = h.ui:layout(h.env.menu)
        assert.are.same({ 872, 307 }, { menu.globalX, menu.globalY })
        local x = h.ui:layout(h.env.win.closeButton)
        assert.are.same({ 272, 7, 20, 20 }, { x.x, x.y, x.width, x.height })
    end)

    it("drags by its title bar, clamped inside its parent", function()
        local h = load(WINDOW)
        h.ui:dragTitle(h.env.win, 404, 713)
        local r = h.ui:layout(h.env.win)
        assert.are.same({ 1004, 1013 }, { r.x, r.y })
        h.ui:dragTitle(h.env.win, 10000, -10000)
        r = h.ui:layout(h.env.win)
        assert.are.same({ 3836 - 300, 0 }, { r.x, r.y })
        -- The plugin reads the new spot back from root.
        assert.are.same({ 3536, 0 }, { h.env.win.root.x, h.env.win.root.y })
    end)

    it("moves a child of its root in the same step", function()
        local h = load(WINDOW)
        h.ui:dragTitle(h.env.win, 100, 50)
        local menu = h.ui:layout(h.env.menu)
        assert.are.same({ 972, 357 }, { menu.globalX, menu.globalY })
    end)

    it("resizes from its corner, clamped to min and max, and the slot button follows", function()
        local h = load(WINDOW)
        h.ui:resize(h.env.win, 100, -1000)
        assert.are.same({ 400, 140 }, { h.env.win.root.width, h.env.win.root.height })
        assert.are.equal(600 + 400 - 28, h.ui:layout(h.env.menu).globalX)
        h.env.win:SetSize(10, 10000)
        assert.are.same({ 220, 10000 }, { h.env.win.root.width, h.env.win.root.height })
    end)

    it("clamps SetSize to the min and max it was given", function()
        local h = load([[
            w = prettyui.Window.new(parent, { title = "t", minWidth = 250, maxWidth = 260,
                maxHeight = 150 })
            w:SetSize(100, 400)
        ]])
        assert.are.same({ 250, 150 }, { h.env.w.root.width, h.env.w.root.height })
    end)

    it("reverts a bare root:SetPos at the next step", function()
        local h = load(WINDOW .. "win.root:SetPos(10, 20)")
        assert.are.same({ 10, 20 }, { h.env.win.root.x, h.env.win.root.y })
        h:advance(20)
        assert.are.same({ 600, 300 }, { h.env.win.root.x, h.env.win.root.y })
    end)

    it("keeps a root:SetPos followed by SetSize", function()
        local h =
            load(WINDOW .. "win.root:SetPos(10, 20); win:SetSize(win.root.width, win.root.height)")
        h:advance(100)
        assert.are.same({ 10, 20 }, { h.env.win.root.x, h.env.win.root.y })
    end)

    it("closes from its close button: onClose(window), then hidden", function()
        local h = load([[
            calls = {}
            win = prettyui.Window.new(parent, { title = "t",
                onClose = function(w) calls[#calls + 1] = { w == win, w.root.hidden } end })
        ]])
        assert.is_true(h.ui:click(h.env.win.closeButton))
        assert.are.same({ { true, false } }, h.env.calls)
        assert.is_true(h.env.win.root.hidden)
    end)

    it("can't be closed from a hidden close button", function()
        local h = load(WINDOW)
        local ok, why = h.ui:click(h.env.win.closeButton)
        assert.is_false(ok)
        assert.are.equal("hidden", why)
        assert.are.same({}, h.env.calls)
    end)

    it("shows again after Close, and hides its children with it", function()
        local h = load(WINDOW .. "win:Close()")
        assert.is_false(h.ui:layout(h.env.menu).visible)
        assert.is_false((h.ui:click(h.env.menu)))
        h.env.win:Show()
        assert.is_false(h.env.win.root.hidden)
        assert.is_true(h.ui:click(h.env.menu))
    end)

    it("gives a title-bar button left of the X's slot no clicks", function()
        local h = load(WINDOW .. [[
            covered = prettyui.SpriteButton.new(win.root, "INFO", function() end,
                { x = -60, y = 7, xAnchor = 1.0, size = 20 })
        ]])
        local ok, why = h.ui:click(h.env.covered)
        assert.is_false(ok)
        assert.matches("title%-bar drag layer", why)
        assert.is_true(h.ui:click(h.env.menu))
    end)

    it("flows AddTitle, AddText, AddCheckboxButton and AddDivider down its content", function()
        local h = load([[
            w = prettyui.Window.new(parent, { title = "t", x = 0, y = 0, width = 300, height = 400 })
            title = w:AddTitle("Dailies")
            text = w:AddText("one<br>two")
            box = w:AddCheckboxButton({ "a", "b" }, {})
            div = w:AddDivider()
            title2 = w:AddTitle("Weeklies")
        ]])
        local function y(c)
            return h.ui:layout(c).globalY
        end
        -- Content sits at (8, 32) in a titled window; rows flow from (14, 12) inside it.
        assert.are.equal(44, y(h.env.title))
        assert.are.equal(22, h.ui:layout(h.env.title).globalX)
        assert.are.equal(44 + 28 + 8, y(h.env.text))
        assert.are.equal(80 + 42 + 2, y(h.env.box.root))
        assert.are.equal(124 + 44 + 8, y(h.env.div.root))
        assert.are.equal(176 + 60 + 8 + 16, y(h.env.title2))
        assert.are.equal(300 - 16 - 28, h.ui:layout(h.env.text).width)
    end)

    it("lets the plugin set a text's content, and finds it by text", function()
        local h = load([[
            w = prettyui.Window.new(parent, { title = "Chores" })
            t = w:AddText("before")
            t.content = "after"
        ]])
        assert.are.equal(h.env.t, h.ui:get("Text", { text = "after" }))
        assert.are.same({}, h.ui:find("Text", { text = "before" }))
        assert.are.equal(h.env.w, h.ui:get("Window", { text = "Chores" }))
    end)

    it("faults on use after Destroy, and is no longer found", function()
        local h = load(WINDOW .. "win:Destroy()")
        assert.is_nil(h.env.win.root)
        assert.are.same({}, h.ui:find("Window"))
        assert.are.same({}, h.ui:find("SpriteButton"))
        assert.matches(
            "used after Destroy",
            harness.errorOf(function()
                h.env.win:Show()
            end)
        )
    end)

    it("faults when the driver clicks a destroyed button or close X", function()
        local h = load(WINDOW .. "x = win.closeButton; win:Destroy()")
        for _, target in ipairs({ h.env.menu, h.env.x }) do
            assert.matches(
                "used after Destroy",
                harness.errorOf(function()
                    h.ui:click(target)
                end)
            )
        end
    end)
end)

describe("prettyui CheckboxButton", function()
    local MAIN = [[
        changes = {}
        w = prettyui.Window.new(parent, { title = "t" })
        box = w:AddCheckboxButton({ "a", { text = "Bee", value = "b" }, { text = "c", disabled = true } }, {
            selectedValues = { "b" },
            onChange = function(group, values, value, selected)
                changes[#changes + 1] = { group == box, values, value, selected }
            end,
        })
    ]]

    it("fires onChange(group, values, value, selected) on a click", function()
        local h = load(MAIN)
        assert.is_true(h.ui:click(h.env.box, "a"))
        assert.are.same({ { true, { "a", "b" }, "a", true } }, h.env.changes)
        h.ui:click(h.env.box, "b")
        assert.are.same({ true, { "a" }, "b", false }, h.env.changes[2])
        assert.is_true(h.env.box:IsSelected("a"))
        assert.are.same({ "a" }, h.env.box:GetSelectedValues())
    end)

    it("ignores a disabled choice, and SetSelected with notify false is silent", function()
        local h = load(MAIN)
        assert.is_false((h.ui:click(h.env.box, "c")))
        assert.is_true(h.env.box:SetSelected("a", true, false))
        assert.is_false(h.env.box:SetSelected("zzz", true))
        assert.are.same({}, h.env.changes)
        assert.are.equal(h.env.box, h.ui:get("CheckboxButton", { text = "Bee" }))
    end)
end)

describe("prettyui SpriteButton", function()
    it("errors on an unknown sprite name like the real one, catchably", function()
        assert.matches(
            "Unknown SpriteButton sprite: NOPE",
            harness.errorOf(load, [[prettyui.SpriteButton.new(parent, "NOPE", nil, {})]])
        )
        local h = load([[ok, err = pcall(prettyui.SpriteButton.new, parent, "nope", nil, {})]])
        assert.is_false(h.env.ok)
        assert.matches("Unknown SpriteButton sprite: nope", h.env.err)
    end)

    it("takes a sprite name in any case, and is found by it", function()
        local h = load(
            WINDOW .. [[b = prettyui.SpriteButton.new(parent, "trash", nil, { tooltip = "Bin" })]]
        )
        assert.are.equal(h.env.b, h.ui:get("SpriteButton", { sprite = "TRASH" }))
        assert.are.equal(h.env.menu, h.ui:get("SpriteButton", { sprite = "menu" }))
    end)

    it("calls its action as action(button, true)", function()
        local h = load(WINDOW)
        h.ui:click(h.env.menu)
        assert.are.same({ { "menu", true, true } }, h.env.calls)
    end)
end)

describe("prettyui Panel", function()
    -- The probe's collapsed holder: a 44x44 panel holding one MENU button.
    local MAIN = [[
        clicks = 0
        holder = prettyui.Panel.new(parent, { x = 0, y = 0, width = 44, height = 44,
            backgroundAlpha = 0 })
        btn = holder:AddSpriteButton("MENU", function() clicks = clicks + 1 end, { size = 20 })
    ]]

    it("puts its first child at +18,+16 (probe)", function()
        local h = load(
            MAIN .. "holder.root:SetPos(500, 400); holder:SetSize(holder.width, holder.height)"
        )
        local b = h.ui:layout(h.env.btn)
        assert.are.same({ 518, 416, 20, 20 }, { b.globalX, b.globalY, b.width, b.height })
    end)

    it("snaps a bare root:SetPos back (probe: it stayed at 0,0)", function()
        local h = load(MAIN .. "holder.root:SetPos(1593, 571)")
        h:advance(20)
        assert.are.same({ 0, 0 }, { h.env.holder.root.x, h.env.holder.root.y })
    end)

    it("keeps root:SetPos followed by SetSize, clamped inside the parent", function()
        local h = load(
            MAIN .. "holder.root:SetPos(1593, 571); holder:SetSize(holder.width, holder.height)"
        )
        h:advance(100)
        assert.are.same({ 1593, 571 }, { h.env.holder.root.x, h.env.holder.root.y })
        h.env.holder.root:SetPos(5000, -3)
        h.env.holder:SetSize(4, 60)
        assert.are.same({ 9, 60 }, { h.env.holder.width, h.env.holder.height })
        assert.are.same({ 3836 - 9, 0 }, { h.env.holder.root.x, h.env.holder.root.y })
    end)

    it("Alt-drags only while Alt is held, clamped inside its parent", function()
        local h = load(MAIN)
        assert.is_false(h.ui:altDrag(h.env.holder, 100, 100))
        assert.are.same({ 0, 0 }, { h.env.holder.root.x, h.env.holder.root.y })
        h.ui:holdAlt(true)
        assert.is_true(h.ui:altDrag(h.env.holder, 100, 100))
        h:advance(20) -- a drag is remembered, so it isn't snapped back
        assert.are.same({ 100, 100 }, { h.env.holder.root.x, h.env.holder.root.y })
        h.ui:altDrag(h.env.holder, -500, 99999)
        assert.are.same({ 0, 2121 - 44 }, { h.env.holder.root.x, h.env.holder.root.y })
    end)

    it("gives its button the click unless Alt is held", function()
        local h = load(MAIN)
        h.ui:holdAlt(true)
        local ok, why = h.ui:click(h.env.btn)
        assert.is_false(ok)
        assert.matches("Alt is held", why)
        h.ui:holdAlt(false)
        assert.is_true(h.ui:click(h.env.btn))
        assert.are.equal(1, h.env.clicks)
    end)

    it("doesn't keep Alt held across a reload", function()
        local h = load(MAIN)
        h.ui:holdAlt(true)
        h:reload()
        assert.is_false(h.ui:altDrag(h.env.holder, 100, 100))
        assert.is_true(h.ui:click(h.env.btn))
    end)
end)

describe("the probe's collapse and expand", function()
    -- The layout the beta client was probed with and Chore Tracker uses: a MENU button in the
    -- X's slot collapses the window into a panel holding a second MENU button at the same
    -- screen spot, which reopens the window over it.
    local MAIN = [[
        win = prettyui.Window.new(parent, { title = "Chores", x = 600, y = 300, width = 300,
            height = 200, resizable = true })
        win.closeButton.hidden = true
        holder = prettyui.Panel.new(parent, { x = 0, y = 0, width = 44, height = 44,
            backgroundAlpha = 0 })
        holder.root.hidden = true
        local function g(c) return c.xyGlobal.x, c.xyGlobal.y end
        local function collapse()
            local x, y = g(menu.root)
            win:Close()
            holder.root:SetPos(x - 18, y - 16)
            holder:SetSize(holder.width, holder.height)
            holder.root.hidden = false
            holder.root:MoveToFront()
        end
        local function expand()
            local x, y = g(closed.root)
            win.root:SetPos(x - (win.root.width - 28), y - 7)
            win:SetSize(win.root.width, win.root.height)
            holder.root.hidden = true
            win:Show()
        end
        menu = prettyui.SpriteButton.new(win.root, "MENU", collapse,
            { x = -28, y = 7, xAnchor = 1.0, size = 20 })
        closed = holder:AddSpriteButton("MENU", expand, { size = 20 })
    ]]

    it("lines the two buttons up both ways, through a drag and an Alt-drag", function()
        local h = load(MAIN)
        assert.are.equal(2, #h.ui:find("SpriteButton", { sprite = "MENU" }))
        h.ui:dragTitle(h.env.win, 50, 50)
        assert.is_true(h.ui:click(h.env.menu))
        h:advance(20)
        local open, closed = h.ui:layout(h.env.menu), h.ui:layout(h.env.closed)
        assert.is_false(open.visible)
        assert.are.same({ open.globalX, open.globalY }, { closed.globalX, closed.globalY })

        h.ui:holdAlt(true)
        h.ui:altDrag(h.env.holder, -200, 100)
        h.ui:holdAlt(false)
        assert.is_true(h.ui:click(h.env.closed))
        h:advance(20)
        open, closed = h.ui:layout(h.env.menu), h.ui:layout(h.env.closed)
        assert.is_true(open.visible)
        assert.are.same({ 922 - 200, 357 + 100 }, { open.globalX, open.globalY })
        assert.are.same({ closed.globalX, closed.globalY }, { open.globalX, open.globalY })
    end)
end)
