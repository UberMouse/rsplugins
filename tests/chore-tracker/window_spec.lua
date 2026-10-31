-- The Chore Tracker's window through the harness and its PrettyUI fake: the views, the list's
-- hand-built rows (ticking, updating in place, scrolling, tooltips), and the collapse button.

local helpers = require("tests.chore-tracker.helpers")
local catalog = require("tests.harness.catalog")
local chores = require("data/chores")
local layout = require("core/layout")
local listlayout = require("core/listlayout")
local view = require("core/view")
local loaded, row, togglePicks, ticked =
    helpers.loaded, helpers.row, helpers.togglePicks, helpers.ticked

local ELLIPSIS = require("core/fit").ELLIPSIS
local fonts = require("tests.harness.api.fonts")
local uiFake = require("tests.harness.api.ui")

local FEATHERS = { name = "Feather Shop Run", id = "feather-shop-run" }
local TEXT_COLOUR, DONE_COLOUR = helpers.TEXT_COLOUR, helpers.DONE_COLOUR

local window = helpers.window

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

-- Every daily chore's id: enough picks that the list scrolls.
---@return string[]
local function dailyIds()
    local ids = {}
    for _, c in ipairs(chores) do
        if c.period == "daily" then ids[#ids + 1] = c.id end
    end
    return ids
end

-- How far a window's content is scrolled, read off the fake (not through `_scroll`, which a spec
-- may have removed).
---@param h table
---@return number
local function scrollOf(h)
    return h.ui:record(window(h), "Window").s.scrollY
end

-- Scrolls the list under the not-ready notice, then the clock starting rebuilds it to the
-- list. Returns the scroll before and after.
---@param h table
---@return number before
---@return number after
local function scrollThenRebuild(h)
    assert.are.same({ true, 1 }, { h.ui:wheel(helpers.rows(h)[1].label, 1) })
    local before = scrollOf(h)
    assert.is_true(before > 0)
    helpers.setClock(h, helpers.NOW)
    h:advance(helpers.POLL_MS)
    return before, scrollOf(h)
end

describe("chore-tracker window", function()
    it("opens titled Chores, with the hint, and logs a tagged line", function()
        local h = loaded()
        local win = window(h)
        assert.is_true(h.ui:layout(win).visible)
        assert.is_true(win.closeButton.hidden)
        h.ui:get("Text", { text = "settings button" })
        assert.matches("%[CHORES%] loaded " .. #chores .. " chores", h:output())
    end)

    it("shows each picked chore as a row with its icon, its name and an empty box", function()
        local h = loaded()
        local before = h.ui:layout(window(h))
        togglePicks(h, { "daily-challenge", "player-owned-ports" })
        local after = h.ui:layout(window(h))
        assert.are.same(
            { before.x, before.y, before.width, before.height },
            { after.x, after.y, after.width, after.height }
        )
        h.ui:get("Title", { text = "Daily  0/2" })

        local challenge, ports = row(h, "Daily Challenge"), row(h, "Player-Owned Port")
        -- An XP reward's sprite, and an item's own icon.
        assert.are.equal(sprite("XP_TOKEN_0"), challenge.icon.spriteID)
        assert.are.equal(obj("POP_LOG"), ports.icon.associatedObjectID)
        assert.is_false(ticked(h, "Daily Challenge"))
        assert.are.equal(1, challenge.icon.alpha)
        assert.are.equal(TEXT_COLOUR, challenge.label.rgba)

        -- The grip at the left, then the icon, the box at the right edge, the names in one
        -- column.
        local rowBox, box = h.ui:layout(challenge.layer), h.ui:layout(challenge.box)
        assert.are.equal(listlayout.ROW_HEIGHT, rowBox.height)
        assert.are.equal(0, h.ui:layout(challenge.grip).x)
        assert.are.equal(20, h.ui:layout(challenge.icon).x)
        assert.are.equal(rowBox.width - 16, box.x)
        assert.are.equal(h.ui:layout(challenge.label).x, h.ui:layout(ports.label).x)
        assert.is_true(rowBox.y < h.ui:layout(ports.layer).y)
    end)

    it("ticks and unticks a chore on a click anywhere on its row, in place, and saves", function()
        local h = loaded()
        togglePicks(h, { "daily-challenge", "player-owned-farm" })
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
        togglePicks(h, { "daily-challenge" })
        h.ui:get("Text", { text = "Waiting for the game clock" })
        local writes = h.dbWrites
        assert.is_true(h.ui:click(row(h, "Daily Challenge").layer))
        assert.is_false(ticked(h, "Daily Challenge"))
        h.ui:get("Title", { text = "Daily  0/1" })
        assert.are.equal(writes, h.dbWrites)
    end)

    it("ticks a row in place when the plugin sees its chore done", function()
        local h = loaded()
        togglePicks(h, { FEATHERS.id })
        helpers.setNeeded(h, FEATHERS.id, 1)
        local win, r = window(h), row(h, FEATHERS.name)
        helpers.buy(h, "FISHINGSHOP", "FEATHER_PACK", 20, 19)
        assert.is_true(ticked(h, FEATHERS.name))
        assert.are.equal(0.5, r.icon.alpha)
        assert.are.equal(DONE_COLOUR, r.label.rgba)
        h:advance(20)
        assert.are.equal(win, window(h))
        assert.are.equal(r.layer, row(h, FEATHERS.name).layer)
    end)

    it("changes a row's count and tooltip in place, taking a shown tooltip down", function()
        local h = loaded()
        togglePicks(h, { FEATHERS.id })
        local win, r = window(h), row(h, FEATHERS.name)
        assert.are.equal("Feather Shop Run (0/4)", r.label.content)
        assert.is_true(h.ui:hover(r.layer))
        assert.matches("not yet  Gerrant", h.ui:tooltips()[1])

        helpers.buy(h, "FISHINGSHOP", "FEATHER_PACK", 20, 19)
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
        togglePicks(h, { "daily-challenge" })
        local win, r = window(h), row(h, "Daily Challenge")
        helpers.toggleTick(h, "Daily Challenge")
        assert.is_true(ticked(h, "Daily Challenge"))
        helpers.setClock(h, helpers.NEXT_DAY)
        assert.is_false(ticked(h, "Daily Challenge"))
        assert.are.equal(1, r.icon.alpha)
        assert.are.equal(TEXT_COLOUR, r.label.rgba)
        h.ui:get("Title", { text = "Daily  0/1" })
        assert.are.equal(win, window(h))
    end)

    it("scrolls the window from the wheel over a row, down to the last row", function()
        local h = loaded()
        local daily = dailyIds()
        togglePicks(h, daily)
        local list = helpers.rows(h)
        assert.are.equal(#daily, #list)
        local first, last = list[1], list[#list]
        -- The last row starts below the window's view, so it can't be clicked yet.
        assert.are.same({ false, "clipped: scrolled out of the window's view" }, {
            h.ui:click(last.label),
        })

        assert.are.same({ true, 1 }, { h.ui:wheel(first.label, 1) })
        assert.are.equal(32, scrollOf(h))
        for _ = 1, 40 do
            h.ui:wheel(list[#list // 2].layer, 1)
        end
        assert.is_true(h.ui:click(last.label))
        assert.is_true(ticked(h, last.text))
        assert.are.same({ false, "clipped: scrolled out of the window's view" }, {
            h.ui:click(first.label),
        })
    end)

    it("keeps the list's scroll when the clock starting rebuilds the window", function()
        local h = loaded({ load = false, clock = 0 })
        local selected = dailyIds()
        helpers.seed(h, "state:Zezima", { version = 2, selected = selected, done = {}, shops = {} })
        h:load()
        local before = window(h)
        local scrolled, kept = scrollThenRebuild(h)
        assert.are.equal(32, scrolled)
        -- The rebuild is to a taller list, at the same scroll.
        assert.are_not.equal(before, window(h))
        assert.are.equal(scrolled, kept)
    end)

    it("shows a chore's tooltip without a blank description line, links last", function()
        local h = loaded()
        togglePicks(h, { "bert-sand", "nemi-forest" })
        -- No description and no shops: the wiki page alone, with no blank line before it.
        local _, bert = helpers.rowShown(h, "Sand from Bert")
        assert.are.equal("https://runescape.wiki/w/Bert", bert)
        -- A description, the wiki page, then the extra link.
        local _, nemi = helpers.rowShown(h, "Nemi Forest")
        assert.are.equal(
            "The day's map is in the 'NemiForest' friends chat and on its subreddit<br>"
                .. "https://runescape.wiki/w/Nemi_Forest"
                .. "<br>https://www.reddit.com/r/NemiForest/new/",
            nemi
        )
    end)

    it("leaves no tooltip attachment behind a view switch, a rebuild or a reload", function()
        local h = loaded()
        togglePicks(h, { FEATHERS.id, "daily-challenge" })
        assert.is_true(h.ui:hover(row(h, "Daily Challenge").layer))
        assert.are.equal(1, #h.ui:tooltips())

        helpers.openSettings(h)
        assert.are.same({}, h.ui:tooltips())
        assert.are.equal(0, liveOrphanTips(h.ui:lib()))
        helpers.back(h)

        -- The clock stopping rebuilds the window for "waiting".
        assert.is_true(h.ui:hover(row(h, "Daily Challenge").layer))
        helpers.setClock(h, 0)
        h.ui:get("Text", { text = "Waiting for the game clock" })
        assert.are.same({}, h.ui:tooltips())
        assert.are.equal(0, liveOrphanTips(h.ui:lib()))

        local lib = h.ui:lib()
        h:reload()
        assert.are.equal(0, liveTips(lib))
    end)

    it("gives a chore whose icon this client lacks a row without one, saying so once", function()
        -- A client where POP_LOG was renamed: the name reads -1.
        local h = loaded({ absentNames = { "id.Obj.POP_LOG" } })
        togglePicks(h, { "daily-challenge", "player-owned-ports" })
        local ports = row(h, "Player-Owned Port")
        assert.is_nil(ports.icon)
        assert.are.equal(h.ui:layout(row(h, "Daily Challenge").label).x, h.ui:layout(ports.label).x)
        assert.is_true(h.ui:click(ports.layer))
        assert.is_true(ticked(h, "Player-Owned Port"))

        -- Rebuilt, still one line.
        helpers.openSettings(h)
        helpers.back(h)
        local _, lines = h:output():gsub("%[CHORES%] unknown icon id%.Obj%.POP_LOG", "")
        assert.are.equal(1, lines)
    end)

    it("leaves a shop, note or var the client lacks unwatched, saying so once", function()
        local h = loaded({
            absentNames = {
                "config.Inv.FISHINGSHOP",
                "config.Obj.CERT_PINEAPPLE",
                "var.VarPlayer.ATAR_ESS_USED",
            },
        })
        local out = h:output()
        for _, line in ipairs({
            "unknown inventory FISHINGSHOP; not watched",
            "unknown obj CERT_PINEAPPLE; not watched",
            "unknown var ATAR_ESS_USED; not watched",
        }) do
            local _, count = out:gsub("%[CHORES%] " .. line, "")
            assert.are.equal(1, count, line)
        end
        assert.is_not_nil(window(h))
    end)

    it("leaves no tooltip up across a collapse and expand", function()
        local h = loaded()
        local menu = h.ui:get("SpriteButton", { sprite = "MENU" })
        assert.is_true(h.ui:hover(menu))
        helpers.click(h, menu)
        h:advance(20)
        local closed = h.ui:get("SpriteButton", { sprite = "MENU", visible = true })
        assert.is_true(h.ui:hover(closed))
        helpers.click(h, closed)
        h:advance(20)
        assert.are.same({}, h.ui:tooltips())
    end)

    it("leaves no tooltip up when a hovered view button switches the view", function()
        local h = loaded()
        local settings = h.ui:get("SpriteButton", { sprite = "SETTINGS" })
        assert.is_true(h.ui:hover(settings))
        helpers.click(h, settings)
        h:advance(20)
        assert.are.same({}, h.ui:tooltips())
    end)

    it("collapses to a hamburger at the same spot, and expands back onto it", function()
        local h = loaded()
        local win = window(h)
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

    -- What the collapsed strip shows, read off its panel's root: the row's label and text when
    -- the row shows, else the message's text.
    ---@param h table
    ---@return { text: string, label: table? }
    local function strip(h)
        for _, proxy in ipairs(h.ui:children(h.ui:get("Panel").root)) do
            local part = assert(uiFake.stateOf(proxy))
            if part.class == "ui.Text" and not part.hidden then
                return { text = part.content }
            elseif part.class == "ui.Layer" and not part.hidden then
                for _, child in ipairs(h.ui:children(proxy)) do
                    local cs = assert(uiFake.stateOf(child))
                    if cs.class == "ui.Text" then return { text = cs.content, label = child } end
                end
            end
        end
        error("the strip shows nothing")
    end

    it("collapses to a strip of the next chore, which a click ticks and moves on from", function()
        local h = loaded()
        togglePicks(h, { "player-owned-ports", "daily-challenge", "player-owned-farm" })
        helpers.click(h, row(h, "Daily Challenge").label)
        helpers.collapse(h)
        local shown = strip(h)
        -- Both are done at several parts, so each shows its count; a hand tick marks no part.
        assert.are.equal("Daily: Player-Owned Port (0/4)", shown.text)

        local writes = h.dbWrites
        assert.is_true(h.ui:click(shown.label))
        assert.are.equal(writes + 1, h.dbWrites)
        shown = strip(h)
        assert.are.equal("Daily: Player-Owned Farm (0/1)", shown.text)
        assert.is_true(h.ui:click(shown.label))
        assert.are.same({ text = view.ALL_DONE }, strip(h))
        h:advance(20)
        assert.matches("%[CHORES%] celebrate daily cleared", h:output())

        helpers.expand(h)
        assert.is_true(ticked(h, "Player-Owned Port"))
        assert.is_true(ticked(h, "Player-Owned Farm"))
        h.ui:get("Title", { text = "Daily  3/3" })
    end)

    it("keeps the strip's width and its hamburger's spot as chores are ticked", function()
        local h = loaded()
        togglePicks(h, { "player-owned-ports", "daily-challenge" })
        local menu = h.ui:layout(h.ui:get("SpriteButton", { sprite = "MENU" }))
        helpers.collapse(h)
        local panel = h.ui:get("Panel")
        local before = h.ui:layout(panel)
        local button = h.ui:layout(h.ui:get("SpriteButton", { sprite = "MENU", visible = true }))
        assert.are.same({ menu.globalX, menu.globalY }, { button.globalX, button.globalY })
        assert.is_true(h.ui:click(assert(strip(h).label, "the strip shows a chore")))
        assert.is_true(h.ui:click(assert(strip(h).label, "the strip shows a chore")))
        assert.are.same(before, h.ui:layout(panel))
    end)

    it("shows the logged-out notice while collapsed, narrowed with its hamburger put", function()
        local h = loaded()
        -- A long name, so the notice needs a narrower strip.
        togglePicks(h, { "dellmonti-pineapples" })
        helpers.collapse(h)
        local panel = h.ui:get("Panel")
        local button = h.ui:get("SpriteButton", { sprite = "MENU", visible = true })
        local at, wide = h.ui:layout(button), h.ui:layout(panel).width
        h.world:logout()
        h:advance(helpers.POLL_MS)
        assert.are.same({ text = "Log in to see your chores" }, strip(h))
        assert.is_true(h.ui:layout(panel).width < wide)
        local now = h.ui:layout(button)
        assert.are.same({ at.globalX, at.globalY }, { now.globalX, now.globalY })
    end)

    it("swaps the title-bar slot for a back button in settings, and back again", function()
        local h = loaded()
        togglePicks(h, { "daily-challenge" })
        local win = window(h)
        local before = h.ui:layout(win)
        helpers.openSettings(h)
        -- One back button, in the slot where the hamburger was, and no hamburger.
        local back = h.ui:get("SpriteButton", { sprite = "BACK" })
        assert.are.same({}, h.ui:find("SpriteButton", { sprite = "MENU" }))
        local slot = h.ui:layout(back)
        assert.are.same(
            { before.globalX + before.width + layout.SLOT_X, before.globalY + layout.SLOT_Y },
            {
                slot.globalX,
                slot.globalY,
            }
        )
        assert.is_true(h.ui:hover(back))
        assert.are.same({ "Back to the list" }, h.ui:tooltips())
        h.ui:leave()

        assert.is_true(h.ui:click(back))
        h:advance(20)
        local after = h.ui:layout(window(h))
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
        assert.is_false(h.ui:layout(window(h)).visible)
        h.ui:get("Panel")
    end)
end)

describe("chore-tracker long names", function()
    local DELL = "Pineapples and Apples from Dell Monti"
    -- The chore's label text, its tooltip (by hovering), and the label width available to it.
    ---@param h table
    ---@param name string
    ---@return string shown
    ---@return string tooltip
    ---@return integer avail
    local function onlyRow(h, name)
        local shown, tip = helpers.rowShown(h, name)
        return shown, tip, h.ui:layout(helpers.row(h, name).label).width
    end

    it("cuts a long name with dots, leads its tooltip with the full name, and re-fits", function()
        local h = loaded()
        togglePicks(h, { "dellmonti-pineapples" })
        local shown, tip, avail = onlyRow(h, DELL)
        assert.is_true(fonts.width(DELL, false) > avail)
        assert.are.equal("...", shown:sub(-3))
        assert.is_true(fonts.width(shown, false) <= avail)
        assert.are.equal(DELL .. "<br>https://", tip:sub(1, #DELL + 12))

        -- A wider window shows more of it, and all of it once it fits, with the plain tooltip.
        h.ui:resize(window(h), 60, 0)
        h:advance(600)
        local wider, _, avail2 = onlyRow(h, DELL)
        assert.is_true(#wider > #shown)
        assert.is_true(fonts.width(wider, false) <= avail2)
        h.ui:resize(window(h), 400, 0)
        h:advance(600)
        local whole, tip3 = onlyRow(h, DELL)
        assert.are.equal(DELL, whole)
        assert.are.equal("https://", tip3:sub(1, 8))

        -- And back to narrow: cut again.
        h.ui:resize(window(h), -460, 0)
        h:advance(600)
        local again, tip4 = onlyRow(h, DELL)
        assert.are.equal(shown, again)
        assert.are.equal(DELL .. "<br>", tip4:sub(1, #DELL + 4))
    end)

    it("leaves a short name and its tooltip alone", function()
        local h = loaded()
        togglePicks(h, { "daily-challenge" })
        local shown, tip = onlyRow(h, "Daily Challenge")
        assert.are.equal("Daily Challenge", shown)
        assert.is_nil(tip:find("Daily Challenge", 1, true))
    end)

    it("re-fits when a shop count changes the text", function()
        local h = loaded()
        togglePicks(h, { FEATHERS.id })
        -- Make the window just wide enough for "(1/4)" but not "(0/4)": a digit '1' is
        -- narrower than a '0' in the fake font.
        local fits = fonts.width("Feather Shop Run (1/4)", false)
        local r = helpers.rows(h)[1]
        h.ui:resize(window(h), fits - h.ui:layout(r.label).width, 0)
        h:advance(600)
        local shown, tip = onlyRow(h, FEATHERS.name)
        assert.are.equal("...", shown:sub(-3))
        assert.are.equal("Feather Shop Run (0/4)<br>", tip:sub(1, 26))

        helpers.buy(h, "FISHINGSHOP", "FEATHER_PACK", 20, 19)
        h:advance(20)
        local after, tip2 = onlyRow(h, FEATHERS.name)
        assert.are.equal("Feather Shop Run (1/4)", after)
        assert.is_nil(tip2:find("Feather Shop Run", 1, true))
    end)

    it("replaces a row's tooltip once when a refresh changes its text and cut", function()
        local h = loaded()
        togglePicks(h, { FEATHERS.id })
        local fits = fonts.width("Feather Shop Run (1/4)", false)
        local r = helpers.rows(h)[1]
        h.ui:resize(window(h), fits - h.ui:layout(r.label).width, 0)
        h:advance(600)
        local lib = h.ui:lib()
        local before = #lib.tooltips
        helpers.buy(h, "FISHINGSHOP", "FEATHER_PACK", 20, 19)
        h:advance(20)
        assert.are.equal(before + 1, #lib.tooltips)
    end)

    it("shows just dots when a laid-out row has no room for any text", function()
        local h = loaded()
        togglePicks(h, { "daily-challenge" })
        local r = helpers.rows(h)[1]
        -- The window's minimum width keeps h.ui:resize from getting here, so size the row.
        r.layer:SetSize(40, 28)
        h:advance(600)
        assert.are.equal(ELLIPSIS, r.label.content)
    end)

    it("shows full names and logs once when the font can't measure", function()
        local h = loaded()
        togglePicks(h, { "dellmonti-pineapples", "daily-challenge" })
        h.env.config = {
            Font = setmetatable({}, {
                __index = function()
                    error("no font")
                end,
            }),
        }
        h.ui:resize(window(h), 10, 0)
        h:advance(600)
        assert.are.equal(DELL, helpers.rows(h)[2].label.content)
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
        helpers.click(h, h.ui:get("SpriteButton", { sprite = "SETTINGS", visible = true }))
        h:advance(40)
        assert.is_nil(first.resize)
        assertCursors(h)
        helpers.click(h, h.ui:get("SpriteButton", { sprite = "BACK", visible = true }))
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
            helpers.click(h, h.ui:get("SpriteButton", { sprite = "SETTINGS", visible = true }))
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

-- The plugin promises that a PrettyUI version without one of the internals it reaches into
-- loses only what that internal gave it (the header of shell/prettyui_internals.lua lists
-- them). The harness toggles stand in for such a version; nothing is probed against one.
describe("chore-tracker on a PrettyUI that lacks a scroll internal", function()
    local BERT_FLAG = "HANDSAND_BUCKETS_CLAIMED_TODAY"

    -- A tracker with every daily chore and Bert's sand picked (so the list scrolls), loaded after `setup`
    -- has toggled the fake, and past the settle window so var ticks count.
    ---@param setup fun(h: table)
    ---@param clock integer? # the game clock at load (default NOW; 0 for not ready)
    ---@return table
    local function drifted(setup, clock)
        local h = loaded({ load = false, clock = clock })
        local selected = dailyIds()
        selected[#selected + 1] = "bert-sand" -- the weekly the signal ticks
        helpers.seed(h, "state:Zezima", { version = 2, selected = selected, done = {}, shops = {} })
        setup(h)
        h:load()
        h:advance(helpers.SETTLE_MS)
        return h
    end

    -- How many live uiRoot children satisfy `pred` (all of them when it is nil).
    ---@param h table
    ---@param pred (fun(child: table): boolean)?
    ---@return integer
    local function liveChildren(h, pred)
        local n = 0
        for _, proxy in ipairs(h.ui:drawOrder()) do
            local child = assert(uiFake.stateOf(proxy))
            if not child.destroyed and (not pred or pred(child)) then n = n + 1 end
        end
        return n
    end

    -- How many grip press targets (live layers with the grip's push cursor) the plugin has.
    ---@param h table
    ---@return integer
    local function gripTargets(h)
        local push = h.env.id.Cursor.CURSOR_PUSH
        return liveChildren(h, function(child)
            return child.class == "ui.Layer"
                and child.cursorState ~= nil
                and child.cursorState.mouseOverCursor == push
        end)
    end

    -- A real chore signal ticks its row, and a view switch both ways still rebuilds the window.
    ---@param h table
    local function assertStillWorks(h)
        assert.is_false(ticked(h, "Sand from Bert"))
        h.world:setVar("VarPlayer", BERT_FLAG, 1)
        h:advance(helpers.POLL_MS)
        assert.is_true(ticked(h, "Sand from Bert"))
        helpers.openSettings(h)
        helpers.back(h)
        assert.is_true(h.ui:layout(window(h)).visible)
        assert.is_true(ticked(h, "Sand from Bert"))
    end

    it("loses only the scroll kept through a rebuild and the grips without _scroll", function()
        -- With the internal, the scroll survives the rebuild and the grips are built.
        local control = drifted(function() end, 0)
        local before, after = scrollThenRebuild(control)
        assert.are.equal(before, after)
        assert.is_true(gripTargets(control) > 0)

        local h = drifted(function(fake)
            fake.ui:scrollInternals("noScroll")
        end, 0)
        assert.is_nil(window(h)._scroll)
        before, after = scrollThenRebuild(h)
        assert.is_true(before > 0)
        assert.are.equal(0, after)
        assert.are.equal(0, gripTargets(h))
        assertStillWorks(h)
    end)

    it("loses only the grips without a viewport", function()
        local h = drifted(function(fake)
            fake.ui:scrollInternals("noViewport")
        end)
        assert.is_nil(window(h).viewport)
        assert.are.equal(0, gripTargets(h))
        assertStillWorks(h)
        assert.are.equal(0, gripTargets(h))
        -- Last, because scrolling moves the settings button (first in the content) out of the
        -- viewport and the harness refuses clicks on it, even with every internal present.
        local first = helpers.rows(h)[1]
        assert.are.same({ true, 1 }, { h.ui:wheel(first.label, 1) })
        assert.is_true(scrollOf(h) > 0)
    end)

    it("loses only the wheel over a row without _onScrollWheel", function()
        local h = drifted(function(fake)
            fake.ui:scrollInternals("noWheel")
        end)
        assert.is_nil(window(h)._onScrollWheel)
        local first = helpers.rows(h)[1]
        -- The row has no wheel listener, so it swallows the wheel.
        assert.are.same({ true, 0 }, { h.ui:wheel(first.label, 1) })
        assert.are.equal(0, scrollOf(h))
        assert.is_true(gripTargets(h) > 0)
        assertStillWorks(h)
    end)

    it("loses only the grips' raise when _RegisterOverlay raises", function()
        local control = drifted(function() end)
        local h = drifted(function(fake)
            fake.ui:overlayRaises(true)
        end)
        local win = window(h)
        -- The sentinel the plugin made was destroyed, not left over the window: one layer fewer
        -- than with the registration working.
        assert.are.equal(0, #h.ui:overlays(win))
        assert.are.equal(1, #control.ui:overlays(window(control)))
        assert.are.equal(liveChildren(control) - 1, liveChildren(h))
        -- The grips are still built, and a title-bar press (which would raise them) is harmless.
        assert.are.equal(gripTargets(control), gripTargets(h))
        h.ui:dragTitle(win, 10, 10)
        h:advance(40)
        assertStillWorks(h)
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
        -- The driver raises on a resize while the window's resize is disabled.
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
