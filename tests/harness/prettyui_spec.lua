-- The PrettyUI fake (api/prettyui.lua), its dependency global and the h.ui driver. Every
-- behaviour here comes from the installed 1.2.0 source or the beta-client probe of
-- 2026-10-25 (docs/testing.md, fidelity ledger).

local harness = require("tests.harness")
local ui = require("tests.harness.api.ui")

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

    it("raises its root on a title-bar press", function()
        local h = load(WINDOW .. [[
other = ui.Layer.new(parent)
]])
        local root = h.instance.uiRoot
        local win = h.env.win
        local title = assert(win.titleDrag, "a titled window has a title-bar drag layer")
        local rootState = ui.stateOf(win.root)
        local titleState = assert(ui.stateOf(title), "a fake component")
        -- On the window's parent, after the root; a layer made later is drawn over both.
        assert.are.equal(root, titleState.parent)
        assert.are.equal(ui.stateOf(h.env.other), root.children[#root.children])
        for _, press in ipairs({ "dragTitle", "clickTitle" }) do
            h.env.other:MoveToFront()
            if press == "dragTitle" then
                h.ui:dragTitle(win, 0, 0)
            else
                h.ui:clickTitle(win)
            end
            -- 1.2.0's ONCLICK there: the root to the front, then the drag layer over it.
            assert.are.same(
                { rootState, titleState },
                { table.unpack(root.children, #root.children - 1) }
            )
        end
    end)

    -- A sentinel overlay counting its layout() calls, shown while `visible`.
    local OVERLAY = WINDOW
        .. [[
overlay = ui.Layer.new(parent)
overlay:SetSize(1, 1)
overlay.clickthrough = true
syncs, visible = 0, true
win:_RegisterOverlay(overlay, function() return visible end, function() syncs = syncs + 1 end)
]]

    it(
        "syncs its overlays when a title-bar press ends: after a drag's raise, before a click's",
        function()
            local h = load(OVERLAY)
            local root = h.instance.uiRoot
            local win, overlay = h.env.win, ui.stateOf(h.env.overlay)
            local rootState, titleState = ui.stateOf(win.root), ui.stateOf(win.titleDrag)
            h.ui:dragTitle(win, 10, 10)
            assert.are.equal(1, h.env.syncs)
            -- Raised by the press, then the release's sync raises the shown overlay over them.
            assert.are.same(
                { rootState, titleState, overlay },
                { table.unpack(root.children, #root.children - 2) }
            )
            -- A quick click arrives release-first: the sync, then the press's raise over it.
            h.ui:clickTitle(win)
            assert.are.equal(2, h.env.syncs)
            assert.are.same(
                { overlay, rootState, titleState },
                { table.unpack(root.children, #root.children - 2) }
            )
        end
    )

    it(
        "syncs its overlays on Show, a scroll, SetSize and a resize, hidden as isVisible says",
        function()
            local h = load(OVERLAY)
            local win, overlay = h.env.win, h.env.overlay
            local function syncs(act)
                local before = h.env.syncs
                act()
                return h.env.syncs - before
            end
            assert.are.equal(
                1,
                syncs(function()
                    win:Show()
                end)
            )
            assert.is_false(overlay.hidden)
            h.env.visible = false
            assert.are.equal(
                1,
                syncs(function()
                    win:SetScrollPosition(0)
                end)
            )
            assert.is_true(overlay.hidden)
            h.env.visible = true
            -- 1.2.0's SetSize syncs after the scroll it re-clamps does.
            assert.are.equal(
                2,
                syncs(function()
                    win:SetSize(320, 220)
                end)
            )
            assert.is_false(overlay.hidden)
            -- The resize's press ends any title press and shows the window, raising its root,
            -- then sets its size.
            assert.are.equal(
                4,
                syncs(function()
                    h.ui:resize(win, 10, 10)
                end)
            )
            local root = h.instance.uiRoot
            assert.are.same(
                { ui.stateOf(win.root), ui.stateOf(win.titleDrag), ui.stateOf(overlay) },
                { table.unpack(root.children, #root.children - 2) }
            )
            -- The wheel scrolls through SetScrollPosition, so it syncs too, while the content
            -- overflows.
            win:SetContentHeight(1000)
            assert.are.equal(
                1,
                syncs(function()
                    win._onScrollWheel(win.content, 1)
                end)
            )
        end
    )

    it("syncs on each move of a held resize, without showing the window again", function()
        local h = load(OVERLAY)
        local win = h.env.win
        h.ui:resize(win, 10, 10)
        local syncs, raised = h.env.syncs, ui.stateOf(win.root).frontCalls
        h.ui:resize(win, 10, 10, true)
        -- 1.2.0's SetSize: the scroll's sync, then its own.
        assert.are.equal(syncs + 2, h.env.syncs)
        assert.are.equal(raised, ui.stateOf(win.root).frontCalls)
        assert.are.equal(320, h.ui:layout(win.root).width)
    end)

    it(
        "lists the overlays registered, and makes windows without the internals on request",
        function()
            local h = load(OVERLAY)
            local win, prettyui, parent = h.env.win, h.env.prettyui, h.env.parent
            assert.are.same({ h.env.overlay }, h.ui:overlays(win))
            h.ui:overlayInternals(false)
            local bare = prettyui.Window.new(parent, { title = "Bare" })
            assert.is_nil(bare._RegisterOverlay)
            assert.is_nil(bare._UnregisterOverlay)
            -- A window made before keeps them.
            assert.are.equal("function", type(win._RegisterOverlay))
            h.ui:overlayInternals(true)
            assert.are.equal(
                "function",
                type(prettyui.Window.new(parent, { title = "Again" })._RegisterOverlay)
            )
        end
    )

    it(
        "hides its overlays on Close without laying them out, beyond its title press ending",
        function()
            local h = load(OVERLAY)
            local win, overlay = h.env.win, h.env.overlay
            win:Close()
            -- 1.2.0's Close ends any title press first, which syncs shown, then syncs hidden.
            assert.are.equal(1, h.env.syncs)
            assert.is_true(overlay.hidden)
            h.env.visible = true
            win:SetScrollPosition(0)
            assert.are.equal(1, h.env.syncs)
            assert.is_true(overlay.hidden)
        end
    )

    it("stops syncing an overlay once unregistered, and all of them once destroyed", function()
        local h = load(OVERLAY)
        local win, overlay = h.env.win, h.env.overlay
        win:_UnregisterOverlay(overlay)
        win:Show()
        assert.are.equal(0, h.env.syncs)
        win:_RegisterOverlay(overlay, nil, function()
            h.env.syncs = h.env.syncs + 1
        end)
        win:Destroy()
        -- Destroy's own title-press end syncs it once, then it is forgotten.
        assert.are.equal(1, h.env.syncs)
        assert.is_true(overlay.hidden)
    end)

    it("faults syncing an overlay destroyed while still registered", function()
        local h = load(OVERLAY)
        h.env.overlay:Destroy()
        assert.matches(
            "used after Destroy",
            harness.errorOf(function()
                h.env.win:Show()
            end)
        )
    end)

    it("faults closing an untitled window whose registered overlay was destroyed", function()
        local h = load([[
            w = prettyui.Window.new(parent, {})
            overlay = ui.Layer.new(parent)
            w:_RegisterOverlay(overlay, nil, function() end)
            overlay:Destroy()
        ]])
        assert.matches("used after Destroy", harness.errorOf(h.env.w.Close, h.env.w))
    end)

    it("hides its title-bar drag layer on Close, and Show raises the root then it", function()
        local h = load(WINDOW .. [[
other = ui.Layer.new(parent)
]])
        local root = h.instance.uiRoot
        local win = h.env.win
        local title = win.titleDrag
        win:Close()
        assert.is_true(title.hidden)
        win:Show()
        assert.is_false(title.hidden)
        assert.are.same(
            { ui.stateOf(win.root), ui.stateOf(title) },
            { table.unpack(root.children, #root.children - 1) }
        )
        win:Destroy()
        assert.is_true(ui.stateOf(title).destroyed)
        assert.is_nil(win.titleDrag)
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

    it("clamps SetScrollPosition to its content, and reads it back from _scroll", function()
        local h = load([[
            w = prettyui.Window.new(parent, { title = "t", x = 0, y = 0, width = 300, height = 200 })
            w:AddTitle("Dailies")
            w:AddCheckboxButton({ "1", "2", "3", "4", "5", "6", "7", "8", "9", "10" }, {})
        ]])
        local w = h.env.w
        local function scrolledTo(position)
            w:SetScrollPosition(position)
            return w._scroll.scrollY
        end
        assert.are.equal(0, w._scroll.scrollY)
        -- Content 282 (the boxes' bottom at 268, plus 14) in a 160 px viewport (200 - 32 - 8).
        assert.are.equal(50, scrolledTo(50.7))
        assert.are.equal(122, scrolledTo(1000))
        assert.are.equal(0, scrolledTo(-5))
        assert.are.equal(0, scrolledTo(nil))
        -- A taller window re-clamps it; a row placed at a y grows the content too.
        scrolledTo(122)
        w:SetSize(300, 300)
        assert.are.equal(22, w._scroll.scrollY)
        w:AddCheckboxButton({ "low" }, { y = 400 })
        assert.are.equal(436 - 260, scrolledTo(1000))
        w:Destroy()
        assert.is_nil(w._scroll)
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

    it("reads nil on the fields 1.2.0 clears and faults on the rest after Destroy", function()
        local h = load(WINDOW .. "win:Destroy()")
        local win = h.env.win
        for _, key in ipairs({ "root", "content", "viewport", "_scroll", "titleDrag", "resize" }) do
            assert.is_nil(win[key])
        end
        for _, key in ipairs({
            "closeButton",
            "_onScrollWheel",
            "_RegisterOverlay",
            "_UnregisterOverlay",
        }) do
            assert.matches(
                "used after Destroy",
                harness.errorOf(function()
                    return win[key]
                end)
            )
        end
    end)

    it("faults on an unmodelled key of _scroll, and reads its scrollY", function()
        local h = load(WINDOW)
        assert.are.equal(0, h.env.win._scroll.scrollY)
        assert.matches(
            "unmocked API",
            harness.errorOf(function()
                return h.env.win._scroll.scrollPosition
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

    it("reads root as nil and faults on width and height after Destroy", function()
        local h = load(MAIN .. "holder:Destroy()")
        local holder = h.env.holder
        assert.is_nil(holder.root)
        for _, key in ipairs({ "width", "height" }) do
            assert.matches(
                "used after Destroy",
                harness.errorOf(function()
                    return holder[key]
                end)
            )
        end
    end)

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

describe("prettyui AchievementPopup", function()
    -- A popup made by show, with an onComplete counter.
    local MAIN = [[
        completed = 0
        popup = prettyui.AchievementPopup.show({
            parent = parent,
            title = "T",
            text = "body",
            width = 200,
            height = 80,
            x = -100,
            xAnchor = 0.5,
            y = -40,
            yAnchor = 1 / 3,
            soundID = id.Sound.LEAGUE2_HARD_TASK_COMPLETE,
            onComplete = function(p) completed = completed + 1; done = p end,
        })
    ]]

    it("records its options, sound and place in the parent", function()
        local h = load(MAIN)
        local p = h.ui:popups()[1]
        assert.are.same({ "T", "body", 200, 80 }, { p.title, p.text, p.width, p.height })
        assert.are.equal(60041, p.played)
        assert.are.same({ 3836 / 2 - 100, math.floor(2121 / 3 - 40 + 0.5) }, { p.root.x, p.root.y })
        assert.are.equal(h.env.popup, p.proxy)
    end)

    it("takes the 1.2.0 defaults: 300x92, its sound, centred 20 down", function()
        local h = load("popup = prettyui.AchievementPopup.show({ parent = parent })")
        local p = h.ui:popups()[1]
        assert.are.same({ "ACHIEVEMENT COMPLETE", 300, 92 }, { p.title, p.width, p.height })
        assert.are.equal(48145, p.played)
        assert.are.same({ 3836 / 2 - 150, 20 }, { p.root.x, p.root.y })
        local muted = load("prettyui.AchievementPopup.show({ parent = parent, sound = false })")
        assert.is_nil(muted.ui:popups()[1].played)
    end)

    it("ends itself on the 201st Logic tick, then calls onComplete with itself", function()
        local h = load(MAIN)
        local p = h.ui:popups()[1]
        h:advance(200 * 20)
        assert.is_false(p.destroyed)
        assert.are.equal(0, h.env.completed)
        h:advance(20)
        assert.is_true(p.destroyed)
        assert.are.equal(1, h.env.completed)
        assert.are.equal(h.env.popup, h.env.done)
        assert.are.equal(0, #h.instance.subs.Logic)
    end)

    it("subscribes its own Logic callback, and Destroy removes it without onComplete", function()
        local h = load(MAIN)
        assert.are.equal("prettyui_achievement_popup_1", h.instance.subs.Logic[1].name)
        h.env.popup:Destroy()
        assert.are.equal(0, #h.instance.subs.Logic)
        h:advance(400 * 20)
        assert.are.equal(0, h.env.completed)
        assert.is_true(h.ui:popups()[1].destroyed)
    end)

    it("returns nil from show when the client has no parent for it", function()
        local h = load("popup = prettyui.AchievementPopup.show({ parent = parent })")
        h.ui:popupsFail(true)
        local show = h.env.prettyui.AchievementPopup.show
        assert.is_nil(show({ parent = h.env.parent }))
        assert.are.equal(1, #h.ui:popups())
    end)

    it(
        "faults on options 1.2.0 doesn't read, accepts those it does, and on show without a parent",
        function()
            assert.matches(
                "option 'titel'",
                harness.errorOf(
                    load,
                    "prettyui.AchievementPopup.show({ parent = parent, titel = 1 })"
                )
            )
            local h = load(
                "popup = prettyui.AchievementPopup.show({ parent = parent, item = 1, shadowed = false })"
            )
            assert.is_not_nil(h.env.popup)
            assert.matches(
                "without options.parent",
                harness.errorOf(load, "prettyui.AchievementPopup.show({})")
            )
        end
    )
end)

-- A window of hand-built rows, as the Row Probe built them (2026-10-29): 10 rows of 28 px at
-- explicit y, an icon and a text clickthrough inside each, and the content height set to
-- cover them. The window is 300x200 titled, so its view is 200 - 32 - 8 = 160 px: the rows
-- reach 280, so it scrolls 120 px.
local ROWS = [[
w = prettyui.Window.new(parent, { title = "Rows", x = 100, y = 100, width = 300, height = 200 })
clicks, wheels, rows = {}, {}, {}
for i = 1, 10 do
    local row = ui.Layer.new(w.content)
    row:SetPos(0, (i - 1) * 28)
    row:SetSize(-16, 28, 1.0)
    row.clickthrough = false
    row:Subscribe(ui.Hook.ONCLICK, function(c, x, y)
        clicks[#clicks + 1] = { "click", i, x, y, c == row }
    end)
    row:Subscribe(ui.Hook.ONRELEASE, function(_, x, y)
        clicks[#clicks + 1] = { "release", i, x, y }
    end)
    local icon = ui.Sprite.new(row)
    icon:SetSize(24, 24)
    icon:SetPos(2, 2)
    icon.clickthrough = true
    local text = ui.Text.new(row)
    text:SetPos(30, 0)
    text:SetSize(100, 28)
    text.clickthrough = true
    rows[i] = { row = row, icon = icon, text = text }
end
w:SetContentHeight(280)
]]

-- The same rows, each handing the wheel to the window's handler.
local WHEEL_ROWS = ROWS:gsub(
    "local icon = ",
    "row:Subscribe(ui.Hook.ONSCROLLWHEEL, w._onScrollWheel)\n    local icon = ",
    1
)

describe("prettyui Window content for hand-built rows", function()
    it("is a live ui.Layer a plugin parents components to, and goes with the window", function()
        local h = load(ROWS)
        local row = h.env.rows[3].row
        -- The viewport is the view inside the frame; the content is as tall as the rows.
        assert.are.same({ 8, 32, 284, 160 }, {
            h.env.w.viewport.xyGlobal.x - 100,
            h.env.w.viewport.xyGlobal.y - 100,
            h.env.w.viewport.width,
            h.env.w.viewport.height,
        })
        assert.are.same({ 8, 32, 284, 280 }, {
            h.env.w.content.xyGlobal.x - 100,
            h.env.w.content.xyGlobal.y - 100,
            h.env.w.content.width,
            h.env.w.content.height,
        })
        assert.are.same({ 0, 56, 268, 28 }, { row.x, row.y, row.width, row.height })
        h.env.w:Destroy()
        assert.matches(
            "used after Destroy",
            harness.errorOf(function()
                return row.x
            end)
        )
        assert.is_nil(h.env.w.content)
    end)

    it("sets the scrollable height, and clamps SetScrollPosition and the wheel to it", function()
        local h = load(ROWS)
        local w = h.env.w
        w:SetScrollPosition(1000)
        assert.are.equal(120, w._scroll.scrollY)
        w:SetContentHeight(200)
        assert.are.equal(40, w._scroll.scrollY)
        w:SetContentHeight(100.9)
        assert.are.equal(0, w._scroll.scrollY)
        w:SetScrollPosition(50)
        assert.are.equal(0, w._scroll.scrollY)
        assert.matches("needs a number", harness.errorOf(w.SetContentHeight, w, "tall"))
    end)

    it(
        "scrolls by delta * 32 through _onScrollWheel, false while it moves, true at the end",
        function()
            local h = load(ROWS)
            local w = h.env.w
            assert.are.equal(w._onScrollWheel, w._onScrollWheel)
            assert.are.equal("function", type(w._onScrollWheel))
            assert.is_false(w._onScrollWheel(h.env.rows[1].row, 2))
            assert.are.equal(64, w._scroll.scrollY)
            assert.is_false(w._onScrollWheel(h.env.rows[1].row, 5))
            assert.are.equal(120, w._scroll.scrollY)
            assert.is_true(w._onScrollWheel(h.env.rows[1].row, 1))
            assert.is_false(w._onScrollWheel(h.env.rows[1].row, -1))
            assert.are.equal(88, w._scroll.scrollY)
        end
    )

    it("returns true, and doesn't scroll, when the content fits", function()
        local h = load(ROWS)
        h.env.w:SetContentHeight(100)
        assert.is_true(h.env.w._onScrollWheel(h.env.rows[1].row, 1))
        assert.are.equal(0, h.env.w._scroll.scrollY)
    end)

    it("faults on _onScrollWheel and SetContentHeight after Destroy", function()
        local h = load(ROWS)
        local w, handler = h.env.w, h.env.w._onScrollWheel
        w:Destroy()
        assert.matches("used after Destroy", harness.errorOf(handler, nil, 1))
        assert.matches("used after Destroy", harness.errorOf(w.SetContentHeight, w, 10))
    end)

    it("places AddTitle and AddText at an absolute y, outside the flow", function()
        local h = load([[
            w = prettyui.Window.new(parent, { title = "T", x = 0, y = 0, width = 300, height = 200 })
            a = w:AddText("first")
            heading = w:AddTitle({ text = "Heading", y = 300 })
            note = w:AddText({ text = "note", y = 400 })
            b = w:AddText("second")
        ]])
        local env = h.env
        assert.are.same({ 14, 12 }, { env.a.x, env.a.y })
        assert.are.same({ 14, 300, 28 }, { env.heading.x, env.heading.y, env.heading.height })
        assert.are.equal(400, env.note.y)
        -- The flow carried on from the first row, as if neither had been added.
        assert.are.same({ 14, 12 + 24 + 2 }, { env.b.x, env.b.y })
        env.w:SetScrollPosition(10000)
        assert.are.equal(400 + 24 + 14 - 160, env.w._scroll.scrollY)
    end)

    it("faults on a text option that isn't modelled", function()
        assert.matches(
            "unmocked API: prettyui Text option 'colour'",
            harness.errorOf(
                load,
                [[
                w = prettyui.Window.new(parent, { title = "T" })
                w:AddTitle({ text = "x", colour = 1 })
            ]]
            )
        )
    end)
end)

describe("prettyui driver on hand-built rows", function()
    it(
        "clicks a row: ONCLICK then ONRELEASE with the press point in the row's coordinates",
        function()
            local h = load(ROWS)
            assert.is_true(h.ui:click(h.env.rows[2].row))
            -- Row 2 is 268 x 28 (the content is 284 wide, less 16); its centre is (134, 14).
            assert.are.same({
                { "click", 2, 134, 14, true },
                { "release", 2, 134, 14 },
            }, h.env.clicks)
        end
    )

    it("gives a click on a clickthrough child to the row, at the child's centre", function()
        local h = load(ROWS)
        assert.is_true(h.ui:click(h.env.rows[1].icon))
        assert.is_true(h.ui:click(h.env.rows[1].text))
        assert.are.same({ "click", 1, 14, 14, true }, h.env.clicks[1])
        assert.are.same({ "click", 1, 80, 14, true }, h.env.clicks[3])
    end)

    it("lands nowhere, with a reason, on a hidden row or one under a hidden window", function()
        local h = load(ROWS)
        h.env.rows[1].row.hidden = true
        assert.are.same({ false, "hidden" }, { h.ui:click(h.env.rows[1].row) })
        assert.are.same({ false, "hidden" }, { h.ui:click(h.env.rows[1].icon) })
        h.env.rows[1].row.hidden = false
        h.env.w:Close()
        assert.are.same({ false, "hidden" }, { h.ui:click(h.env.rows[2].row) })
        assert.are.same({}, h.env.clicks)
    end)

    it("faults on a destroyed component", function()
        local h = load(ROWS)
        local row = h.env.rows[1].row
        row:Destroy()
        assert.matches("used after Destroy", harness.errorOf(h.ui.click, h.ui, row))
        assert.matches("used after Destroy", harness.errorOf(h.ui.hover, h.ui, row))
        assert.matches("used after Destroy", harness.errorOf(h.ui.wheel, h.ui, row, 1))
    end)

    it("lands nowhere when the component and everything above it is clickthrough", function()
        local h = load([[
            top = ui.Layer.new(parent)
            top:SetSize(50, 50)
            top.clickthrough = true
            inner = ui.Sprite.new(top)
            inner:SetSize(10, 10)
            inner.clickthrough = true
        ]])
        for _, target in ipairs({ h.env.top, h.env.inner }) do
            local ok, why = h.ui:click(target)
            assert.is_false(ok)
            assert.matches("^clickthrough", why)
            assert.matches("^clickthrough", select(2, h.ui:hover(target)))
            assert.matches("^clickthrough", select(2, h.ui:wheel(target, 1)))
        end
    end)

    it("gives a clickthrough row's click to the window content under it", function()
        local h = load(ROWS)
        h.env.rows[1].row.clickthrough = true
        assert.is_true(h.ui:click(h.env.rows[1].row))
        assert.are.same({}, h.env.clicks)
    end)

    it("faults on a component whose clickthrough was never set", function()
        local h = load([[
            w = prettyui.Window.new(parent, { title = "T" })
            bare = ui.Layer.new(parent)
            bare:SetSize(10, 10)
        ]])
        assert.matches("never had clickthrough set", harness.errorOf(h.ui.click, h.ui, h.env.bare))
    end)

    it("clips a PrettyUI button scrolled out of the window's view, for click and hover", function()
        local h = load(ROWS .. [[
            far = prettyui.SpriteButton.new(w.content, "MENU", function() end,
                { x = 10, y = 250, size = 20 })
        ]])
        local ok, why = h.ui:hover(h.env.far)
        assert.is_false(ok)
        assert.matches("^clipped", why)
        assert.matches("^clipped", select(2, h.ui:click(h.env.far)))
        h.env.w:SetScrollPosition(120)
        assert.is_true(h.ui:hover(h.env.far))
    end)

    it("clips a row scrolled outside the window's view, for click, hover and wheel", function()
        local h = load(WHEEL_ROWS)
        local rows = h.env.rows
        -- Row 6's centre is at 154 of 160; row 7's at 182.
        assert.is_true(h.ui:click(rows[6].row))
        local ok, why = h.ui:click(rows[7].row)
        assert.is_false(ok)
        assert.matches("^clipped", why)
        assert.matches("^clipped", select(2, h.ui:hover(rows[7].icon)))
        assert.matches("^clipped", select(2, h.ui:wheel(rows[7].row, 1)))
        assert.are.equal(1, #h.env.clicks / 2)
        h.env.w:SetScrollPosition(64)
        assert.is_true(h.ui:click(rows[7].row))
        assert.matches("^clipped", select(2, h.ui:click(rows[1].row)))
        assert.matches("^clipped", select(2, h.ui:click(rows[1].text)))
        assert.are.equal(2, #h.env.clicks / 2)
        -- The positions the components report don't move with the scroll.
        assert.are.equal(168, rows[7].row.y)
    end)

    it(
        "scrolls the window on a wheel over a row that hands the wheel to the window's handler",
        function()
            local h = load(WHEEL_ROWS)
            local ok, ran = h.ui:wheel(h.env.rows[2].icon, 1)
            assert.is_true(ok)
            assert.are.equal(1, ran)
            assert.are.equal(32, h.env.w._scroll.scrollY)
        end
    )

    it("swallows a wheel over a row with no wheel listener: the window doesn't scroll", function()
        local h = load(ROWS)
        local ok, ran = h.ui:wheel(h.env.rows[2].row, 1)
        assert.is_true(ok)
        assert.are.equal(0, ran)
        assert.are.equal(0, h.env.w._scroll.scrollY)
        ok, ran = h.ui:wheel(h.env.rows[2].text, 1)
        assert.are.same({ true, 0 }, { ok, ran })
    end)

    it("scrolls the window on a wheel over its bare content, and passes the delta on", function()
        local h = load(ROWS)
        -- Row 6 (y 140-168) covers the content's centre (y 140); without it, it is bare.
        assert.matches("^covered", select(2, h.ui:wheel(h.env.w.content, 2)))
        h.env.rows[6].row.hidden = true
        assert.are.same({ true, 1 }, { h.ui:wheel(h.env.w.content, 2) })
        assert.are.equal(64, h.env.w._scroll.scrollY)
    end)

    it("calls a wheel listener as (component, delta), until one returns false", function()
        local h = load([[
            w = prettyui.Window.new(parent, { title = "T" })
            seen = {}
            row = ui.Layer.new(w.content)
            row:SetSize(100, 20)
            row.clickthrough = false
            row:Subscribe(ui.Hook.ONSCROLLWHEEL, function(c, d)
                seen[#seen + 1] = { "a", c == row, d }
                return false
            end)
            row:Subscribe(ui.Hook.ONSCROLLWHEEL, "b", function() seen[#seen + 1] = { "b" } end)
        ]])
        assert.are.same({ true, 1 }, { h.ui:wheel(h.env.row, -3) })
        assert.are.same({ { "a", true, -3 } }, h.env.seen)
    end)

    it("runs the callbacks under the runtime budget", function()
        local h = load([[
            w = prettyui.Window.new(parent, { title = "T" })
            row = ui.Layer.new(w.content)
            row:SetSize(100, 20)
            row.clickthrough = false
            row:Subscribe(ui.Hook.ONCLICK, function() while true do end end)
        ]])
        h.budgetMs = 50
        assert.matches(
            "Maximum function execution time",
            harness.errorOf(h.ui.click, h.ui, h.env.row)
        )
    end)

    it("fires ONMOUSEOVER and ONMOUSELEAVE as the pointer moves between rows", function()
        local h = load([[
            w = prettyui.Window.new(parent, { title = "T", width = 300, height = 200 })
            log, rows = {}, {}
            for i = 1, 2 do
                local row = ui.Layer.new(w.content)
                row:SetPos(0, (i - 1) * 28)
                row:SetSize(-16, 28, 1.0)
                row.clickthrough = false
                row:Subscribe(ui.Hook.ONMOUSEOVER, function(_, x, y)
                    log[#log + 1] = { "over", i, x, y, row.isMouseOver }
                end)
                row:Subscribe(ui.Hook.ONMOUSELEAVE, function(c)
                    log[#log + 1] = { "leave", i, c == row, row.isMouseOver }
                end)
                local icon = ui.Sprite.new(row)
                icon:SetSize(24, 24)
                icon.clickthrough = true
                rows[i] = { row = row, icon = icon }
            end
        ]])
        local rows = h.env.rows
        assert.is_true(h.ui:hover(rows[1].icon))
        assert.is_true(h.ui:hover(rows[1].row)) -- still on row 1
        assert.is_true(h.ui:hover(rows[2].row))
        assert.is_false(rows[1].row.isMouseOver)
        assert.is_true(rows[2].row.isMouseOver)
        h.ui:leave()
        assert.is_false(rows[2].row.isMouseOver)
        assert.are.same({
            { "over", 1, 12, 12, true },
            { "leave", 1, true, false },
            { "over", 2, 134, 14, true },
            { "leave", 2, true, false },
        }, h.env.log)
    end)

    it("returns false from hover, leaving the pointer, when the row is hidden", function()
        local h = load(ROWS)
        assert.is_true(h.ui:hover(h.env.rows[1].row))
        h.env.rows[2].row.hidden = true
        assert.are.same({ false, "hidden" }, { h.ui:hover(h.env.rows[2].row) })
        assert.is_true(h.env.rows[1].row.isMouseOver)
    end)
end)

-- A bar that follows the pointer as the drag probe's v1 bar did: each ONHOLD moves it by how
-- far the pointer is from where it was grabbed.
local BAR = [[
bar = ui.Layer.new(parent)
bar:SetPos(100, 500)
bar:SetSize(200, 28)
bar.clickthrough = false
log = {}
bar:Subscribe(ui.Hook.ONCLICK, function(_, x, y)
    log[#log + 1] = { "click", x, y }
    grabY = y
end)
bar:Subscribe(ui.Hook.ONHOLD, function(_, x, y)
    log[#log + 1] = { "hold", x, y }
    bar:SetPos(100, bar.y + y - grabY)
end)
bar:Subscribe(ui.Hook.ONRELEASE, function(_, x, y) log[#log + 1] = { "release", x, y } end)
]]

-- The pattern that held the press in the probe's v3 (PrettyUI's scroll-thumb drag): a capture
-- layer on the plugin layer, docked over a row's grip; the first ONHOLD stretches it over the
-- whole plugin layer and brings it to the front, and ONRELEASE docks it back.
local CAPTURE = [[
w = prettyui.Window.new(parent, { title = "Rows", x = 100, y = 100, width = 300, height = 200 })
row = ui.Layer.new(w.content)
row:SetPos(0, 28)
row:SetSize(-16, 28, 1.0)
row.clickthrough = false
w:SetContentHeight(400)
capture = ui.Layer.new(parent)
capture.clickthrough = false
-- The row's drawn spot from the viewport and the scroll: xyGlobal leaves the scroll out.
function dock()
    local at = w.viewport.xyGlobal
    capture:SetPos(at.x + row.x, at.y + row.y - w._scroll.scrollY)
    capture:SetSize(24, 28)
end
dock()
log, stretched = {}, false
capture:Subscribe(ui.Hook.ONCLICK, function(_, x, y) log[#log + 1] = { "click", x, y } end)
capture:Subscribe(ui.Hook.ONHOLD, function(_, x, y)
    log[#log + 1] = { "hold", x, y }
    if not stretched then
        stretched = true
        capture:SetPos(0, 0)
        capture:SetSize(0, 0, 1.0, 1.0)
        capture:MoveToFront()
    end
end)
capture:Subscribe(ui.Hook.ONRELEASE, function(_, x, y)
    log[#log + 1] = { "release", x, y }
    stretched = false
    dock()
end)
]]

describe("prettyui driver press, hold and release", function()
    it("gives ONCLICK on press, and ONHOLD per move relative to where the layer is now", function()
        local h = load(BAR)
        assert.is_true(h.ui:press(h.env.bar)) -- at its centre, (200, 514)
        assert.are.same({ { "click", 100, 14 } }, h.env.log)
        assert.is_true(h.ui:moveTo(200, 524)) -- 10 below the grab: the bar follows to 510
        assert.is_true(h.ui:moveTo(200, 524)) -- the mouse still: back at the grab point
        assert.is_true(h.ui:moveTo(200, 534))
        assert.are.same({
            { "click", 100, 14 },
            { "hold", 100, 24 },
            { "hold", 100, 14 },
            { "hold", 100, 24 },
        }, h.env.log)
        assert.are.equal(520, h.env.bar.y)
    end)

    it("ends the press as soon as the pointer leaves the layer, button still down", function()
        local h = load(BAR)
        h.ui:press(h.env.bar)
        assert.are.same(
            { false, "released: the pointer left the pressed layer's hit area" },
            { h.ui:moveTo(200, 528) } -- the bar is 500-527
        )
        assert.are.same({ "release", 100, 28 }, h.env.log[2])
        assert.are.same({ false, "no press held" }, { h.ui:release() })
        assert.are.equal(2, #h.env.log)
    end)

    it("ends the press when the pointer leaves a parent the layer is stretched past", function()
        local h = load([[
            panel = ui.Layer.new(parent)
            panel:SetPos(400, 500)
            panel:SetSize(320, 400)
            panel.clickthrough = true
            grip = ui.Layer.new(panel)
            grip:SetPos(10, 10)
            grip:SetSize(24, 24)
            grip.clickthrough = false
            log = {}
            grip:Subscribe(ui.Hook.ONHOLD, function(_, x, y)
                log[#log + 1] = { "hold", x, y }
                grip:SetPos(-1000, -1000)
                grip:SetSize(5000, 5000)
            end)
            grip:Subscribe(ui.Hook.ONRELEASE, function(_, x, y) log[#log + 1] = { "release", x, y } end)
        ]])
        assert.is_true(h.ui:press(h.env.grip)) -- (422, 522)
        assert.is_true(h.ui:moveTo(422, 522))
        assert.is_true(h.ui:moveTo(700, 890)) -- inside the panel, far outside the 24 px grip
        local ok, why = h.ui:moveTo(700, 499) -- one pixel above the panel
        assert.is_false(ok)
        assert.matches("^released", why)
        assert.are.same({
            { "hold", 12, 12 },
            { "hold", 1300, 1390 },
            { "release", 1300, 999 },
        }, h.env.log)
    end)

    it(
        "keeps the press of a capture stretched over the plugin layer, overshoot and back",
        function()
            local h = load(CAPTURE)
            local capture = h.env.capture
            -- Docked over the row: the window's root (100, 100), its viewport (8, 32), row y 28.
            assert.are.same(
                { 108, 160, 24 },
                { capture.xyGlobal.x, capture.xyGlobal.y, capture.width }
            )
            assert.is_true(h.ui:press(capture))
            -- Still docked: the first ONHOLD, which stretches it, comes with the first move.
            assert.are.equal(24, capture.width)
            assert.is_true(h.ui:moveTo(120, 174))
            assert.are.same(
                { 0, 0, 3836, 2121 },
                { capture.x, capture.y, capture.width, capture.height }
            )
            assert.is_true(h.ui:moveTo(120, 40)) -- above the window
            assert.is_true(h.ui:moveTo(120, 2000)) -- far below it
            assert.is_true(h.ui:moveTo(120, 200)) -- back over the list
            assert.is_true(h.ui:release())
            assert.are.same({
                { "click", 12, 14 },
                { "hold", 12, 14 },
                { "hold", 120, 40 },
                { "hold", 120, 2000 },
                { "hold", 120, 200 },
                { "release", 120, 200 },
            }, h.env.log)
            assert.are.same(
                { 108, 160, 24 },
                { capture.xyGlobal.x, capture.xyGlobal.y, capture.width }
            )
        end
    )

    it("draws a scrolled window's content higher, but leaves xyGlobal unscrolled", function()
        local h = load(CAPTURE)
        local w, row = h.env.w, h.env.row
        w:SetScrollPosition(20)
        -- As in the client (dev-bridge probe, 2026-10-29): the scroll moves neither the row's
        -- xyGlobal nor the content's; only where they draw and take the pointer.
        assert.are.same({ 108, 160, 28 }, { row.xyGlobal.x, row.xyGlobal.y, row.y })
        assert.are.same({ 132, 132 }, { w.viewport.xyGlobal.y, w.content.xyGlobal.y })
        assert.are.equal(140, h.ui:layout(row).globalY)
        row:Subscribe(h.env.ui.Hook.ONSCROLLWHEEL, w._onScrollWheel)
        assert.are.same({ true, 1 }, { h.ui:wheel(row, 1) })
        assert.are.equal(52, w._scroll.scrollY)
        assert.are.equal(160, row.xyGlobal.y)
        assert.are.equal(108, h.ui:layout(row).globalY)
        -- Docked again from the viewport and the scroll, the capture lands over the row's new
        -- place.
        h.env.dock()
        assert.is_true(h.ui:press(h.env.capture))
        assert.are.same({ "click", 12, 14 }, h.env.log[1])
    end)

    it(
        "doesn't press through a window drawn over the target, until it comes to the front",
        function()
            local h = load([[
            target = ui.Layer.new(parent)
            target:SetPos(150, 150)
            target:SetSize(24, 24)
            target.clickthrough = false
            w = prettyui.Window.new(parent, { title = "T", x = 100, y = 100, width = 300, height = 200 })
        ]])
            local covered = { false, "covered: a ui.Layer drawn over it takes the pointer" }
            assert.are.same(covered, { h.ui:press(h.env.target) })
            h.env.target:MoveToFront()
            assert.is_true(h.ui:press(h.env.target))
            assert.is_true(h.ui:release())
            h.env.w:Show() -- brings the window to the front
            assert.are.same(covered, { h.ui:press(h.env.target) })
        end
    )

    it("fails a press that wouldn't land, with a reason, and faults on a destroyed one", function()
        local h = load(BAR)
        assert.are.same(
            { false, "clipped: the point is outside the target" },
            { h.ui:press(h.env.bar, 99, 510) }
        )
        h.env.bar.hidden = true
        assert.are.same({ false, "hidden" }, { h.ui:press(h.env.bar) })
        h.env.bar:Destroy()
        assert.matches("used after Destroy", harness.errorOf(h.ui.press, h.ui, h.env.bar))
        assert.are.same({}, h.env.log)
    end)

    it("returns false from moveTo and release with no press held", function()
        local h = load(BAR)
        assert.are.same({ false, "no press held" }, { h.ui:moveTo(200, 514) })
        assert.are.same({ false, "no press held" }, { h.ui:release() })
        assert.are.same({}, h.env.log)
    end)

    it("faults on a second press, and on a pressed layer hidden mid-press", function()
        local h = load(BAR)
        h.ui:press(h.env.bar)
        assert.matches("already held", harness.errorOf(h.ui.press, h.ui, h.env.bar))
        h.env.bar.hidden = true
        assert.matches("mid%-press", harness.errorOf(h.ui.moveTo, h.ui, 200, 514))
        assert.matches("mid%-press", harness.errorOf(h.ui.release, h.ui))
    end)

    it("runs ONHOLD under the runtime budget", function()
        -- BAR's own ONHOLD listener returns nothing, which would stop this one (ui.fire).
        local h = load(
            BAR
                .. "bar:Unsubscribe(ui.Hook.ONHOLD)\n"
                .. "bar:Subscribe(ui.Hook.ONHOLD, 'spin', function() while true do end end)"
        )
        h.budgetMs = 50
        h.ui:press(h.env.bar)
        assert.matches(
            "Maximum function execution time",
            harness.errorOf(h.ui.moveTo, h.ui, 200, 514)
        )
    end)
end)

describe("prettyui Tooltip.attach on hand-built rows", function()
    local TIPPED = ROWS
        .. [[
        tips = {}
        for i = 1, 10 do
            tips[i] = prettyui.Tooltip.attach(rows[i].row, w.content, { text = "row " .. i, maxWidth = 360 })
        end
    ]]

    it("shows on the row's hover and hides on its leave, drawn on the window's parent", function()
        local h = load(TIPPED)
        h.ui:hover(h.env.rows[3].icon)
        assert.are.same({ "row 3" }, h.ui:tooltips())
        h.ui:hover(h.env.rows[4].row)
        assert.are.same({ "row 4" }, h.ui:tooltips())
        h.ui:leave()
        assert.are.same({}, h.ui:tooltips())
    end)

    it("takes a plain string, and returns nil for a nil value", function()
        local h = load(ROWS .. [[
            tip = prettyui.Tooltip.attach(rows[1].row, w.content, "plain")
            noneIsNil = prettyui.Tooltip.attach(rows[2].row, w.content, nil) == nil
        ]])
        h.ui:hover(h.env.rows[1].row)
        assert.are.same({ "plain" }, h.ui:tooltips())
        assert.is_true(h.env.noneIsNil)
    end)

    it("is hidden by Window:Close and destroyed by Window:Destroy", function()
        local h = load(TIPPED)
        h.ui:hover(h.env.rows[1].row)
        h.env.w:Close()
        assert.are.same({}, h.ui:tooltips())
        h.env.w:Show()
        assert.are.same({}, h.ui:tooltips())
        h.ui:hover(h.env.rows[2].row)
        h.env.w:Destroy()
        assert.are.same({}, h.ui:tooltips())
        -- Destroying one the window already took is harmless.
        h.env.tips[2]:Destroy()
    end)

    it(
        "is replaced by Destroy then attach: the new one stays hidden until the next hover",
        function()
            local h = load(TIPPED .. [[
            function retip(text)
                tips[1]:Destroy()
                tips[1] = prettyui.Tooltip.attach(rows[1].row, w.content, { text = text })
            end
        ]])
            h.ui:hover(h.env.rows[1].row)
            h.env.retip("changed")
            assert.are.same({}, h.ui:tooltips())
            h.ui:leave()
            h.ui:hover(h.env.rows[1].row)
            assert.are.same({ "changed" }, h.ui:tooltips())
        end
    )

    it("makes the target take the mouse until Destroy gives clickthrough back", function()
        local h = load(ROWS .. [[
            icon = rows[1].icon
            tip = prettyui.Tooltip.attach(icon, w.content, "icon")
            now = icon.clickthrough
        ]])
        local icon = h.env.icon
        assert.is_false(h.env.now)
        -- The icon takes the click itself now, and the row gets none.
        h.ui:click(icon)
        assert.are.same({}, h.env.clicks)
        h.env.tip:Destroy()
        assert.is_true(icon.clickthrough)
        h.env.tip:Destroy()
        h.ui:click(icon)
        assert.are.equal(2, #h.env.clicks)
    end)

    it(
        "faults on a second tooltip, a destroyed target or parent, and unmodelled arguments",
        function()
            local twice = [[
            prettyui.Tooltip.attach(rows[1].row, w.content, "a")
            prettyui.Tooltip.attach(rows[1].row, w.content, "b")
        ]]
            assert.matches("already has a tooltip", harness.errorOf(load, ROWS .. twice))
            assert.matches(
                "target was destroyed",
                harness.errorOf(load, ROWS .. [[
            rows[1].row:Destroy()
            prettyui.Tooltip.attach(rows[1].row, w.content, "a")
        ]])
            )
            assert.matches(
                "parent was destroyed",
                harness.errorOf(load, ROWS .. [[
            local gone = ui.Layer.new(parent)
            gone:Destroy()
            prettyui.Tooltip.attach(rows[1].row, gone, "a")
        ]])
            )
            assert.matches(
                "target must be a ui component",
                harness.errorOf(load, ROWS .. [[
            prettyui.Tooltip.attach({}, w.content, "a")
        ]])
            )
            assert.matches(
                "unmocked API: prettyui TooltipValue option 'placement'",
                harness.errorOf(load, ROWS .. [[
            prettyui.Tooltip.attach(rows[1].row, w.content, { text = "a", placement = "left" })
        ]])
            )
            assert.matches(
                "with hover handlers",
                harness.errorOf(load, ROWS .. [[
            prettyui.Tooltip.attach(rows[1].row, w.content, "a", {})
        ]])
            )
            assert.matches(
                "called with ':'",
                harness.errorOf(load, ROWS .. [[
            prettyui.Tooltip:attach(rows[1].row, w.content, "a")
        ]])
            )
            assert.matches(
                "unmocked API: prettyui.Tooltip.set",
                harness.errorOf(
                    load,
                    [[
            local _ = prettyui.Tooltip.set
        ]]
                )
            )
            assert.matches(
                "unmocked API: prettyui.Tooltip attachment.Show",
                harness.errorOf(load, ROWS .. [[
            prettyui.Tooltip.attach(rows[1].row, w.content, "a"):Show()
        ]])
            )
        end
    )

    it(
        "draws on the parent given when it isn't a window's content, and stays out of Close",
        function()
            local h = load(ROWS .. [[
            outside = ui.Layer.new(parent)
            outside:SetSize(40, 40)
            outside.clickthrough = false
            prettyui.Tooltip.attach(outside, parent, "outside")
        ]])
            h.ui:hover(h.env.outside)
            h.env.w:Close()
            assert.are.same({ "outside" }, h.ui:tooltips())
            h.env.parent.hidden = true
            assert.are.same({}, h.ui:tooltips())
        end
    )
end)
