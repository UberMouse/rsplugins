-- The Chore Tracker's window through the harness and its PrettyUI fake: the views, the list's
-- hand-built rows (ticking, updating in place, scrolling, tooltips), and the collapse button.

local helpers = require("tests.chore-tracker.helpers")
local catalog = require("tests.harness.catalog")
local chores = require("data/chores")
local loaded, row, pick, ticked = helpers.loaded, helpers.row, helpers.pick, helpers.ticked

local ELLIPSIS = require("core/fit").ELLIPSIS
local fonts = require("tests.harness.api.fonts")

local FEATHERS = { name = "Feather Shop Run", id = "feather-shop-run" }
-- shell/rows.lua's text colours for a row not done and done.
local TEXT_COLOUR, DONE_COLOUR = 0xE7D7B0FF, 0x7A7262FF

---@param h table
---@return table
local function window(h)
    return h.ui:get("Window", { text = "Chores" })
end

---@param name string
---@return integer
local function sprite(name)
    return assert(catalog.config("Sprite", name))
end

---@param name string
---@return integer
local function obj(name)
    return assert(catalog.config("Obj", name))
end

-- Buy a feather pack at open shop `inv`.
---@param h table
---@param inv string
local function buyFeathers(h, inv)
    h.world:setInventory(inv, { { obj = "FEATHER_PACK", count = 20 } }, 4)
    h.world:setInventory(inv, { { obj = "FEATHER_PACK", count = 19 } }, 4)
end

-- How many live tooltips a PrettyUI fake has on components the plugin made itself (its
-- rows' Tooltip.attach attachments).
---@param lib table
---@return integer
local function liveTips(lib)
    local n = 0
    for _, tip in ipairs(lib.tooltips) do
        if tip.target.raw and not tip.destroyed then n = n + 1 end
    end
    return n
end

-- How many of those belong to a component that was destroyed: an attachment that outlived
-- its row.
---@param lib table
---@return integer
local function liveOrphanTips(lib)
    local n = 0
    for _, tip in ipairs(lib.tooltips) do
        if tip.target.raw and not tip.destroyed and tip.target.destroyed then n = n + 1 end
    end
    return n
end

describe("chore-tracker window", function()
    it("opens titled Chores, with the hint, and logs a tagged line", function()
        local h = loaded()
        local win = h.ui:get("Window", { text = "Chores" })
        assert.is_true(h.ui:layout(win).visible)
        assert.is_true(win.closeButton.hidden)
        h.ui:get("Text", { text = "settings button" })
        assert.matches("%[CHORES%] loaded 67 chores", h:output())
    end)

    it("shows each picked chore as a row with its icon, its name and an empty box", function()
        local h = loaded()
        local before = h.ui:layout(window(h))
        pick(h, { "daily-challenge", "player-owned-ports" })
        local after = h.ui:layout(window(h))
        assert.are.same(
            { before.x, before.y, before.width, before.height },
            { after.x, after.y, after.width, after.height }
        )
        h.ui:get("Title", { text = "Daily  0/2" })

        local challenge, ports = row(h, "Daily Challenge"), row(h, "Player Owned Ports")
        -- An XP reward's sprite, and an item's own icon.
        assert.are.equal(sprite("XP_TOKEN_0"), challenge.icon.spriteID)
        assert.are.equal(obj("POP_LOG"), ports.icon.associatedObjectID)
        assert.is_false(ticked(h, "Daily Challenge"))
        assert.are.equal(1, challenge.icon.alpha)
        assert.are.equal(TEXT_COLOUR, challenge.label.rgba)

        -- The grip at the left, then the icon, the box at the right edge, the names in one
        -- column.
        local rowBox, box = h.ui:layout(challenge.layer), h.ui:layout(challenge.box)
        assert.are.equal(28, rowBox.height)
        assert.are.equal(0, h.ui:layout(challenge.grip).x)
        assert.are.equal(20, h.ui:layout(challenge.icon).x)
        assert.are.equal(rowBox.width - 16, box.x)
        assert.are.equal(h.ui:layout(challenge.label).x, h.ui:layout(ports.label).x)
        assert.is_true(rowBox.y < h.ui:layout(ports.layer).y)
    end)

    it("ticks and unticks a chore on a click anywhere on its row, in place, and saves", function()
        local h = loaded()
        pick(h, { "daily-challenge", "player-owned-farm" })
        local win, r = window(h), row(h, "Daily Challenge")
        local writes = h.dbWrites
        assert.is_true(h.ui:click(r.label))
        h.ui:get("Title", { text = "Daily  1/2" })
        assert.is_true(ticked(h, "Daily Challenge"))
        assert.are.equal(0.5, r.icon.alpha)
        assert.are.equal(DONE_COLOUR, r.label.rgba)
        assert.are.equal(writes + 1, h.dbWrites)
        assert.are.equal(win, window(h))
        assert.are.equal(r.layer, row(h, "Daily Challenge").layer)

        assert.is_true(h.ui:click(r.icon))
        h.ui:get("Title", { text = "Daily  0/2" })
        assert.is_false(ticked(h, "Daily Challenge"))
        assert.are.equal(1, r.icon.alpha)
        assert.are.equal(TEXT_COLOUR, r.label.rgba)
        assert.are.equal(writes + 2, h.dbWrites)

        assert.is_true(h.ui:click(r.box))
        assert.is_true(ticked(h, "Daily Challenge"))
        assert.is_true(h.ui:click(r.layer))
        assert.is_false(ticked(h, "Daily Challenge"))
    end)

    it("changes nothing on a click before the game clock reads", function()
        local h = loaded({ clock = 0 })
        pick(h, { "daily-challenge" })
        h.ui:get("Text", { text = "Waiting for the game clock" })
        local writes = h.dbWrites
        assert.is_true(h.ui:click(row(h, "Daily Challenge").layer))
        assert.is_false(ticked(h, "Daily Challenge"))
        h.ui:get("Title", { text = "Daily  0/1" })
        assert.are.equal(writes, h.dbWrites)
    end)

    it("ticks a row in place when the plugin sees its chore done", function()
        local h = loaded()
        pick(h, { FEATHERS.id })
        local win, r = window(h), row(h, FEATHERS.name)
        buyFeathers(h, "FISHINGSHOP")
        assert.is_true(ticked(h, FEATHERS.name))
        assert.are.equal(0.5, r.icon.alpha)
        assert.are.equal(DONE_COLOUR, r.label.rgba)
        h:advance(20)
        assert.are.equal(win, window(h))
        assert.are.equal(r.layer, row(h, FEATHERS.name).layer)
    end)

    it("changes a row's count and tooltip in place, taking a shown tooltip down", function()
        local h = loaded()
        pick(h, { FEATHERS.id })
        local win, r = window(h), row(h, FEATHERS.name)
        assert.are.equal("Feather Shop Run (0/4)", r.label.content)
        assert.is_true(h.ui:hover(r.layer))
        assert.matches("not yet  Gerrant", h.ui:tooltips()[1])

        buyFeathers(h, "FISHINGSHOP")
        h:advance(20)
        assert.are.equal("Feather Shop Run (1/4)", r.label.content)
        assert.are.equal(win, window(h))
        -- The old tooltip was destroyed with its text; the new one waits for the next hover.
        assert.are.same({}, h.ui:tooltips())
        h.ui:leave()
        assert.is_true(h.ui:hover(r.layer))
        assert.matches("bought  Gerrant", h.ui:tooltips()[1])
        assert.are.equal(0, liveOrphanTips(h.ui:lib()))
    end)

    it("unticks rows in place when their period resets", function()
        local h = loaded()
        pick(h, { "daily-challenge" })
        local win, r = window(h), row(h, "Daily Challenge")
        helpers.tick(h, "Daily Challenge")
        assert.is_true(ticked(h, "Daily Challenge"))
        h.world:setVar("VarPlayer", "CLOCK_TIME_DATE_MINUTES", helpers.NEXT_DAY)
        assert.is_false(ticked(h, "Daily Challenge"))
        assert.are.equal(1, r.icon.alpha)
        assert.are.equal(TEXT_COLOUR, r.label.rgba)
        h.ui:get("Title", { text = "Daily  0/1" })
        assert.are.equal(win, window(h))
    end)

    it("scrolls the window from the wheel over a row, down to the last row", function()
        local h = loaded()
        local daily = {}
        for _, c in ipairs(chores) do
            if c.period == "daily" then daily[#daily + 1] = c.id end
        end
        pick(h, daily)
        local list = helpers.rows(h)
        assert.are.equal(#daily, #list)
        local first, last = list[1], list[#list]
        -- The last row starts below the window's view, so it can't be clicked yet.
        assert.are.same({ false, "clipped: scrolled out of the window's view" }, {
            h.ui:click(last.label),
        })

        assert.are.same({ true, 1 }, { h.ui:wheel(first.label, 1) })
        assert.are.equal(32, window(h)._scroll.scrollY)
        for _ = 1, 40 do
            h.ui:wheel(list[#list // 2].layer, 1)
        end
        assert.is_true(h.ui:click(last.label))
        assert.is_true(ticked(h, last.text))
        assert.are.same({ false, "clipped: scrolled out of the window's view" }, {
            h.ui:click(first.label),
        })
    end)

    it("leaves no tooltip attachment behind a view switch, a rebuild or a reload", function()
        local h = loaded()
        pick(h, { FEATHERS.id, "daily-challenge" })
        assert.is_true(h.ui:hover(row(h, "Daily Challenge").layer))
        assert.are.equal(1, #h.ui:tooltips())

        helpers.openSettings(h)
        assert.are.same({}, h.ui:tooltips())
        assert.are.equal(0, liveOrphanTips(h.ui:lib()))
        h.ui:click(h.ui:get("SpriteButton", { sprite = "BACK" }))
        h:advance(20)

        -- The clock stopping rebuilds the window for "waiting".
        assert.is_true(h.ui:hover(row(h, "Daily Challenge").layer))
        h.world:setVar("VarPlayer", "CLOCK_TIME_DATE_MINUTES", 0)
        h.ui:get("Text", { text = "Waiting for the game clock" })
        assert.are.same({}, h.ui:tooltips())
        assert.are.equal(0, liveOrphanTips(h.ui:lib()))

        local lib = h.ui:lib()
        h:reload()
        assert.are.equal(0, liveTips(lib))
    end)

    it("gives a chore whose icon this client lacks a row without one, saying so once", function()
        local h = loaded()
        -- A client where POP_LOG was renamed: the name reads nil.
        local real = h.env.id
        h.env.id = {
            Obj = setmetatable({}, {
                __index = function(_, name)
                    if name == "POP_LOG" then return nil end
                    return real.Obj[name]
                end,
            }),
            Sprite = real.Sprite,
            Font = real.Font,
        }
        pick(h, { "daily-challenge", "player-owned-ports" })
        local ports = row(h, "Player Owned Ports")
        assert.is_nil(ports.icon)
        assert.are.equal(h.ui:layout(row(h, "Daily Challenge").label).x, h.ui:layout(ports.label).x)
        assert.is_true(h.ui:click(ports.layer))
        assert.is_true(ticked(h, "Player Owned Ports"))

        -- Rebuilt, still one line.
        pick(h, {})
        local _, lines = h:output():gsub("%[CHORES%] unknown icon id%.Obj%.POP_LOG", "")
        assert.are.equal(1, lines)
    end)

    it("leaves no tooltip up across a collapse and expand", function()
        local h = loaded()
        local menu = h.ui:get("SpriteButton", { sprite = "MENU" })
        assert.is_true(h.ui:hover(menu))
        h.ui:click(menu)
        h:advance(20)
        local closed = h.ui:get("SpriteButton", { sprite = "MENU", visible = true })
        assert.is_true(h.ui:hover(closed))
        h.ui:click(closed)
        h:advance(20)
        assert.are.same({}, h.ui:tooltips())
    end)

    it("leaves no tooltip up when a hovered view button switches the view", function()
        local h = loaded()
        local settings = h.ui:get("SpriteButton", { sprite = "SETTINGS" })
        assert.is_true(h.ui:hover(settings))
        h.ui:click(settings)
        h:advance(20)
        assert.are.same({}, h.ui:tooltips())
    end)

    it("collapses to a hamburger at the same spot, and expands back onto it", function()
        local h = loaded()
        local win = h.ui:get("Window", { text = "Chores" })
        h.ui:dragTitle(win, 50, 40)
        local menu = h.ui:get("SpriteButton", { sprite = "MENU" })
        local spot = h.ui:layout(menu)
        assert.is_true(h.ui:click(menu))
        h:advance(20)
        assert.is_false(h.ui:layout(win).visible)
        local closed = h.ui:get("SpriteButton", { sprite = "MENU", visible = true })
        local at = h.ui:layout(closed)
        assert.are.same({ spot.globalX, spot.globalY }, { at.globalX, at.globalY })

        h.ui:holdAlt(true)
        assert.is_true(h.ui:altDrag(h.ui:get("Panel"), -200, 100))
        h.ui:holdAlt(false)
        h:advance(20)
        at = h.ui:layout(closed)
        assert.is_true(h.ui:click(closed))
        h:advance(20)
        assert.are.same({}, h.ui:find("Panel"))
        local open = h.ui:layout(h.ui:get("SpriteButton", { sprite = "MENU" }))
        assert.is_true(open.visible)
        assert.are.same({ at.globalX, at.globalY }, { open.globalX, open.globalY })
        assert.matches("%[CHORES%] collapsed at", h:output())
        assert.matches("%[CHORES%] expanded from", h:output())
    end)

    it("leaves no collapsed panel behind after two collapses and expands in one tick", function()
        local h = loaded()
        for _ = 1, 2 do
            assert.is_true(
                h.ui:click(h.ui:get("SpriteButton", { sprite = "MENU", visible = true }))
            )
            assert.is_true(
                h.ui:click(h.ui:get("SpriteButton", { sprite = "MENU", visible = true }))
            )
        end
        h:advance(20)
        assert.are.same({}, h.ui:find("Panel"))
    end)

    it("swaps the title-bar slot for a back button in settings, and back again", function()
        local h = loaded()
        pick(h, { "daily-challenge" })
        local win = h.ui:get("Window", { text = "Chores" })
        local before = h.ui:layout(win)
        helpers.openSettings(h)
        -- One back button, in the slot where the hamburger was, and no hamburger.
        local back = h.ui:get("SpriteButton", { sprite = "BACK" })
        assert.are.same({}, h.ui:find("SpriteButton", { sprite = "MENU" }))
        local slot = h.ui:layout(back)
        assert.are.same({ before.globalX + before.width - 28, before.globalY + 7 }, {
            slot.globalX,
            slot.globalY,
        })
        h.ui:hover(back)
        assert.are.same({ "Back to the list" }, h.ui:tooltips())
        h.ui:leave()

        assert.is_true(h.ui:click(back))
        h:advance(20)
        local after = h.ui:layout(h.ui:get("Window", { text = "Chores" }))
        assert.are.same(
            { before.x, before.y, before.width, before.height },
            { after.x, after.y, after.width, after.height }
        )
        row(h, "Daily Challenge")
        assert.are.same({}, h.ui:find("SpriteButton", { sprite = "BACK" }))
        assert.are.same({}, h.ui:tooltips())

        -- In the list, the slot collapses the window as before.
        assert.is_true(h.ui:click(h.ui:get("SpriteButton", { sprite = "MENU" })))
        h:advance(20)
        assert.is_false(h.ui:layout(h.ui:get("Window", { text = "Chores" })).visible)
        h.ui:get("Panel")
    end)
end)

describe("chore-tracker long names", function()
    local CROMPERTY = "Pure Essence from Wizard Cromperty"
    -- shell/rows.lua keeps a list row's label clear of the grip (20), the icon (30), the box
    -- (16) and a 6 px gap.
    local LABEL_INSET = 72

    -- The label's text, its tooltip (by hovering), and the label width available to it.
    ---@param h table
    ---@return string shown
    ---@return string tooltip
    ---@return integer avail
    local function onlyRow(h)
        local r = helpers.rows(h)[1]
        local shown = r.label.content
        assert(h.ui:hover(r.layer))
        local tips = h.ui:tooltips()
        h.ui:leave()
        return shown, tips[1], r.layer.width - LABEL_INSET
    end

    it("cuts a long name with dots, leads its tooltip with the full name, and re-fits", function()
        local h = loaded()
        pick(h, { "cromperty-pure-essence" })
        local shown, tip, avail = onlyRow(h)
        assert.is_true(fonts.width(CROMPERTY, false) > avail)
        assert.are.equal("...", shown:sub(-3))
        assert.is_true(fonts.width(shown, false) <= avail)
        assert.are.equal(CROMPERTY .. "<br>Weekly stock", tip:sub(1, #CROMPERTY + 16))

        -- A wider window shows more of it, and all of it once it fits, with the plain tooltip.
        h.ui:resize(window(h), 60, 0)
        h:advance(600)
        local wider, _, avail2 = onlyRow(h)
        assert.is_true(#wider > #shown)
        assert.is_true(fonts.width(wider, false) <= avail2)
        h.ui:resize(window(h), 400, 0)
        h:advance(600)
        local whole, tip3 = onlyRow(h)
        assert.are.equal(CROMPERTY, whole)
        assert.are.equal("Weekly stock", tip3:sub(1, 12))

        -- And back to narrow: cut again.
        h.ui:resize(window(h), -460, 0)
        h:advance(600)
        local again, tip4 = onlyRow(h)
        assert.are.equal(shown, again)
        assert.are.equal(CROMPERTY .. "<br>", tip4:sub(1, #CROMPERTY + 4))
    end)

    it("leaves a short name and its tooltip alone", function()
        local h = loaded()
        pick(h, { "daily-challenge" })
        local shown, tip = onlyRow(h)
        assert.are.equal("Daily Challenge", shown)
        assert.is_nil(tip:find("Daily Challenge", 1, true))
    end)

    it("re-fits when a shop count changes the text", function()
        local h = loaded()
        pick(h, { FEATHERS.id })
        -- Make the window just wide enough for "(1/4)" but not "(0/4)": a digit '1' is
        -- narrower than a '0' in the fake font.
        local fits = fonts.width("Feather Shop Run (1/4)", false)
        local r = helpers.rows(h)[1]
        h.ui:resize(window(h), fits + LABEL_INSET - r.layer.width, 0)
        h:advance(600)
        local shown, tip = onlyRow(h)
        assert.are.equal("...", shown:sub(-3))
        assert.are.equal("Feather Shop Run (0/4)<br>", tip:sub(1, 26))

        buyFeathers(h, "FISHINGSHOP")
        h:advance(20)
        local after, tip2 = onlyRow(h)
        assert.are.equal("Feather Shop Run (1/4)", after)
        assert.is_nil(tip2:find("Feather Shop Run", 1, true))
    end)

    it("replaces a row's tooltip once when a refresh changes its text and cut", function()
        local h = loaded()
        pick(h, { FEATHERS.id })
        local fits = fonts.width("Feather Shop Run (1/4)", false)
        local r = helpers.rows(h)[1]
        h.ui:resize(window(h), fits + LABEL_INSET - r.layer.width, 0)
        h:advance(600)
        local lib = h.ui:lib()
        local before = #lib.tooltips
        buyFeathers(h, "FISHINGSHOP")
        h:advance(20)
        assert.are.equal(before + 1, #lib.tooltips)
    end)

    it("shows just dots when a laid-out row has no room for any text", function()
        local h = loaded()
        pick(h, { "daily-challenge" })
        local r = helpers.rows(h)[1]
        -- The window's minimum width keeps h.ui:resize from getting here, so size the row.
        r.layer:SetSize(40, 28)
        h:advance(600)
        assert.are.equal(ELLIPSIS, r.label.content)
    end)

    it("shows full names and logs once when the font can't measure", function()
        local h = loaded()
        pick(h, { "cromperty-pure-essence", "daily-challenge" })
        h.env.config = {
            Font = setmetatable({}, {
                __index = function()
                    error("no font")
                end,
            }),
        }
        h.ui:resize(window(h), 10, 0)
        h:advance(600)
        assert.are.equal(CROMPERTY, helpers.rows(h)[2].label.content)
        local _, n = h:output():gsub("%[CHORES%] cannot measure text", "")
        assert.are.equal(1, n)
    end)
end)

describe("chore-tracker resize cursors", function()
    -- The handle keys PrettyUI 1.2.0 makes, and the cursor each shows.
    local DIAG_1 = assert(catalog.config("Cursor", "TOPLEVEL_V2_SCALE_DIAG_1"))
    local DIAG_2 = assert(catalog.config("Cursor", "TOPLEVEL_V2_SCALE_DIAG_2"))
    local MOVE = assert(catalog.config("Cursor", "TOPLEVEL_V2_MOVE"))
    local EXPECTED = { nw = DIAG_1, se = DIAG_1, ne = DIAG_2, sw = DIAG_2 }
    for _, key in ipairs({ "n", "s", "e", "w" }) do
        EXPECTED[key] = MOVE
    end

    ---@param h table
    local function assertCursors(h)
        local handles = window(h).resize.handles
        for key, cursor in pairs(EXPECTED) do
            local handle = assert(handles[key], "window has no resize handle " .. key)
            assert.are.equal(cursor, handle.cursorConfig.mouseOverCursor, key)
            assert.are.equal(cursor, handle.opConfig:GetOpCursor(0), key)
        end
    end

    it("are set on the handles of the window built at load", function()
        assertCursors(loaded())
    end)

    it("are set on the handles of a window a view switch rebuilds", function()
        local h = loaded()
        local first = window(h)
        h.ui:click(h.ui:get("SpriteButton", { sprite = "SETTINGS", visible = true }))
        h:advance(40)
        assert.is_true(first.resize == nil)
        assertCursors(h)
        h.ui:click(h.ui:get("SpriteButton", { sprite = "BACK", visible = true }))
        h:advance(40)
        assertCursors(h)
    end)

    it("are skipped on a PrettyUI without the resize internals", function()
        for _, mode in ipairs({ "none", "noHandles" }) do
            local h = loaded({ load = false })
            h.ui:resizeInternals(mode)
            h:load()
            local resize = window(h).resize
            assert.is_nil(resize and resize.handles)
            h.ui:click(h.ui:get("SpriteButton", { sprite = "SETTINGS", visible = true }))
            h:advance(40)
            assert.is_true(h.ui:layout(window(h)).visible)
        end
    end)

    it("skip only a missing handle", function()
        local h = loaded({ load = false })
        h.ui:resizeInternals("noN")
        h:load()
        assert.is_true(h.ui:layout(window(h)).visible)
        local handles = window(h).resize.handles
        assert.is_nil(handles.n)
        for key, cursor in pairs(EXPECTED) do
            if key ~= "n" then
                assert.are.equal(cursor, handles[key].cursorConfig.mouseOverCursor, key)
                assert.are.equal(cursor, handles[key].opConfig:GetOpCursor(0), key)
            end
        end
    end)
end)

-- PrettyUI 1.2.0 leaves the window's resize off after a quick title-bar click (the press
-- reaches it after the release); the plugin turns it back on once the title bar isn't held.
describe("chore-tracker resize after a title-bar click", function()
    it("is turned back on a tick after a quick click", function()
        local h = loaded()
        local win = window(h)
        h.ui:clickTitle(win)
        assert.is_false(win.resize.enabled)
        h:advance(20)
        assert.is_true(win.resize.enabled)
        h.ui:resize(win, 60, 0)
    end)

    it("stays off while the title bar is held, and is on once it is let go", function()
        local h = loaded()
        local win = window(h)
        h.ui:holdTitleBar(win)
        h:advance(100)
        assert.is_false(win.resize.enabled)
        h.ui:releaseTitleBar(win)
        assert.is_true(win.resize.enabled)
        h:advance(20)
        assert.is_true(win.resize.enabled)
    end)

    it("is left alone on a window without the resize or title-bar internals", function()
        for _, mode in ipairs({ "none", "noTitleDrag" }) do
            local h = loaded({ load = false })
            h.ui:resizeInternals(mode)
            h:load()
            local win = window(h)
            h.ui:clickTitle(win)
            -- Ticking must not error, and without a titleDrag to tell a held press from the
            -- stuck state the plugin must not turn the resize back on.
            h:advance(40)
            assert.is_true(h.ui:layout(win).visible)
            if win.resize then assert.is_false(win.resize.enabled) end
        end
    end)
end)
