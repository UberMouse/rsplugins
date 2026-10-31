-- The Chore Tracker's settings view and the hover state of its rows: icon rows to pick
-- chores, never dimmed, with a hand cursor and a hovered tick box in both views.

local helpers = require("tests.chore-tracker.helpers")
local catalog = require("tests.harness.catalog")
local chores = require("data/chores")
local fonts = require("tests.harness.api.fonts")
local listlayout = require("core/listlayout")
local view = require("core/view")
local loaded, openSettings = helpers.loaded, helpers.openSettings

local BOX_EMPTY, BOX_EMPTY_HOVERED = helpers.BOX_EMPTY, helpers.BOX_EMPTY_HOVERED
local BOX_TICKED, BOX_TICKED_HOVERED = helpers.BOX_TICKED, helpers.BOX_TICKED_HOVERED
local HAND = catalog.config("Cursor", "CURSOR_HYPERLINK_HAND")
local TEXT_COLOUR = helpers.TEXT_COLOUR

local window = helpers.window

describe("chore-tracker settings rows", function()
    it("lists every chore as an icon row under its period's heading and category", function()
        local h = loaded()
        openSettings(h)
        -- Wide enough that no name is cut short.
        h.ui:resize(window(h), 600, 0)
        h:advance(600)
        local list = helpers.rows(h)
        assert.are.equal(#chores, #list)
        local expected = {} ---@type { text: string, y: number }[]
        for _, group in ipairs(view.byPeriod(chores)) do
            local heading = h.ui:get("Title", { text = group.title })
            for _, subgroup in ipairs(group.subgroups) do
                local first = helpers.settingsRow(h, subgroup.chores[1].id)
                if subgroup.category then
                    -- Its subheading sits just above its first row, below the period's title.
                    local y = first.layer.y - listlayout.SUBHEADING_HEIGHT
                    assert.is_true(y > heading.y)
                    expected[#expected + 1] =
                        { text = view.CATEGORY_TITLES[subgroup.category], y = y }
                end
                for _, chore in ipairs(subgroup.chores) do
                    local r = helpers.settingsRow(h, chore.id)
                    assert.are.equal(chore.name, r.label.content)
                    assert.is_not_nil(r.icon)
                    assert.are.equal(BOX_EMPTY, r.box.spriteID)
                end
            end
        end
        assert.are.same(expected, helpers.subheadings(h))
        local texts = {}
        for i, sub in ipairs(helpers.subheadings(h)) do
            texts[i] = sub.text
        end
        -- Monthly has no categories, so its rows come straight after its title.
        assert.are.same({
            "Activities",
            "Skilling",
            "Upkeep",
            "Activities",
            "Combat",
            "Upkeep",
            "Free supplies",
            "Shops",
        }, texts)
        local monthly = h.ui:get("Title", { text = "Monthly" })
        assert.are.equal(
            monthly.y + listlayout.HEADING_HEIGHT + listlayout.AFTER_HEADING,
            helpers.settingsRow(h, "dream-of-iaia-xp").layer.y
        )
        -- The Celebrations switches stay in PrettyUI's flow, above the rows.
        local switches = h.ui:find("CheckboxButton")
        assert.are.equal(1, #switches)
        assert.is_true(helpers.picked(h, "popups"))
        assert.is_true(switches[1].root.y + switches[1].root.height <= list[1].layer.y)
    end)

    it(
        "picks and unpicks on a click anywhere on a row, saving, in place and never dimmed",
        function()
            local h = loaded()
            openSettings(h)
            local win, r = window(h), helpers.settingsRow(h, "daily-challenge")
            local writes = h.dbWrites
            win:SetScrollPosition(r.layer.y - 40)
            assert.is_true(h.ui:click(r.label))
            assert.is_true(helpers.picked(h, "daily-challenge"))
            assert.are.equal(BOX_TICKED, r.box.spriteID)
            assert.are.equal(1, r.icon.alpha)
            assert.are.equal(TEXT_COLOUR, r.label.rgba)
            assert.are.equal(writes + 1, h.dbWrites)
            -- The same window and row: nothing was rebuilt, and no celebration came up.
            assert.are.equal(win, window(h))
            assert.are.equal(r.layer, helpers.settingsRow(h, "daily-challenge").layer)
            assert.are.same({}, h.ui:popups())

            assert.is_true(h.ui:click(r.box))
            assert.is_false(helpers.picked(h, "daily-challenge"))
            assert.are.equal(writes + 2, h.dbWrites)
            assert.is_true(h.ui:click(r.icon))
            assert.is_true(helpers.picked(h, "daily-challenge"))
        end
    )

    it("lists a pick in the list view and remembers it when settings reopen", function()
        local h = loaded()
        helpers.togglePicks(h, { "daily-challenge" })
        h.ui:get("Title", { text = "Daily  0/1" })
        openSettings(h)
        assert.is_true(helpers.picked(h, "daily-challenge"))
    end)

    it("cuts a long name with dots, with a tooltip led by the full name", function()
        local h = loaded()
        openSettings(h)
        local r = helpers.settingsRow(h, "dellmonti-pineapples")
        local full = "Pineapples and Apples from Dell Monti"
        assert.are.equal("...", r.label.content:sub(-3))
        assert.is_true(fonts.width(r.label.content, false) <= h.ui:layout(r.label).width)
        window(h):SetScrollPosition(r.layer.y - 40)
        assert.is_true(h.ui:hover(r.layer))
        assert.are.equal(full .. "<br>https://", h.ui:tooltips()[1]:sub(1, #full + 12))
        h.ui:leave()
        -- A wider window re-fits the settings rows too.
        local before = #r.label.content
        h.ui:resize(window(h), 400, 0)
        h:advance(600)
        assert.is_true(#r.label.content > before)
    end)

    it("scrolls the window from the wheel over a row", function()
        local h = loaded()
        openSettings(h)
        local r = helpers.settingsRow(h, "daily-challenge")
        window(h):SetScrollPosition(r.layer.y - 40)
        local before = window(h)._scroll.scrollY
        assert.are.same({ true, 1 }, { h.ui:wheel(r.label, 1) })
        assert.are.equal(before + 32, window(h)._scroll.scrollY)
    end)
end)

describe("chore-tracker count settings", function()
    -- Every chore with a count, in data/chores.lua's order, at its default: all of a shop run's
    -- shops, else data/counts.lua's.
    local COUNTS = {
        { id = "bloodwood-tree", value = "1 of 8" },
        { id = "herb-run", value = "8 of 11" },
        { id = "player-owned-farm", value = "1 of 7" },
        { id = "penguin-hide-and-seek", value = "10 of 13" },
        { id = "shattered-worlds", value = "3 of 3" },
        { id = "broad-arrowheads", value = "2 of 2" },
        { id = "feather-shop-run", value = "4 of 4" },
        { id = "rune-shop-run", value = "11 of 11" },
        { id = "thalmunds-wares", value = "4 of 4" },
        { id = "vial-of-water-packs", value = "5 of 5" },
    }
    -- Picked chores with no count line: a single shop, a fixed count (the port's four voyages),
    -- no parts (any Invention machine collect ticks), and rules that are alternatives.
    local NO_COUNT = {
        "yak-hide",
        "player-owned-ports",
        "invention-machine",
        "invention-machine-weekly",
        "fort-forinthry-bonus-xp",
    }

    -- The settings window's scroll.
    ---@param h table
    ---@return number
    local function prettyuiScroll(h)
        -- PrettyUI 1.2.0's internal scroll, as shell/prettyui_internals.lua reads it.
        return assert(window(h)._scroll.scrollY, "no scroll")
    end

    ---@param h table
    ---@return table? the How many to do help text, if shown
    local function countsHelp(h)
        for _, text in ipairs(h.ui:find("Text")) do
            if text.content:gsub("<br>", " ") == view.NO_COUNTS then return text end
        end
        return nil
    end

    it("shows help instead of lines while no picked chore has a count", function()
        local h = loaded()
        helpers.togglePicks(h, NO_COUNT)
        openSettings(h)
        local title = h.ui:get("Title", { text = "How many to do" })
        local help = assert(countsHelp(h), "no help")
        assert.is_true(help.y >= title.y + title.height)
        assert.is_true(help.y + help.height <= h.ui:get("Title", { text = "Daily" }).y)
        for _, id in ipairs(NO_COUNT) do
            assert.has_error(function()
                helpers.stepper(h, id)
            end)
        end
    end)

    it(
        "shows a stepper per picked chore with a count, in list order, at its default, above the list",
        function()
            local h = loaded()
            local ids = {}
            for i, count in ipairs(COUNTS) do
                ids[i] = count.id
            end
            helpers.togglePicks(h, ids)
            openSettings(h)
            assert.is_nil(countsHelp(h))
            local title = h.ui:get("Title", { text = "How many to do" })
            local switches = h.ui:find("CheckboxButton")[1]
            assert.is_true(switches.root.y + switches.root.height <= title.y)
            local lastY = title.y
            for _, count in ipairs(COUNTS) do
                local line = helpers.stepper(h, count.id)
                assert(line.label.y > lastY, count.id .. " is out of order")
                lastY = line.label.y
                assert.are.equal(count.value, line.value.content, count.id)
                assert.are.equal(HAND, line.minus.cursorConfig.mouseOverCursor)
            end
            -- The lists' layout starts below the block.
            assert.is_true(lastY + listlayout.ROW_HEIGHT <= h.ui:get("Title", { text = "Daily" }).y)
        end
    )

    it(
        "adds a picked chore's line and drops an unpicked one's, keeping the row in place",
        function()
            local h = loaded()
            helpers.togglePicks(h, { "rune-shop-run" })
            openSettings(h)
            local row = helpers.settingsRow(h, "herb-run")
            window(h):SetScrollPosition(row.layer.y - 100)
            local shownAt = row.layer.y - prettyuiScroll(h)
            helpers.click(h, row.label)
            h:advance(20)
            helpers.stepper(h, "herb-run")
            row = helpers.settingsRow(h, "herb-run")
            assert.are.equal(BOX_TICKED, row.box.spriteID)
            assert.are.equal(shownAt, row.layer.y - prettyuiScroll(h))
            helpers.click(h, row.label)
            h:advance(20)
            assert.has_error(function()
                helpers.stepper(h, "herb-run")
            end)
            row = helpers.settingsRow(h, "herb-run")
            assert.are.equal(shownAt, row.layer.y - prettyuiScroll(h))
            -- Unpicking the last chore with a count brings the help back.
            local runes = helpers.settingsRow(h, "rune-shop-run")
            window(h):SetScrollPosition(runes.layer.y - 40)
            helpers.click(h, runes.label)
            h:advance(20)
            assert.is_not_nil(countsHelp(h))
        end
    )

    it("says what a count counts, and per when, in its line's tooltip", function()
        local h = loaded()
        helpers.togglePicks(h, { "player-owned-farm", "feather-shop-run" })
        openSettings(h)
        for id, want in pairs({
            ["player-owned-farm"] = "Player-Owned Farm<br>How many pens you feed, the breeding pen "
                .. "included each day.",
            ["feather-shop-run"] = "Feather Shop Run<br>How many of its shops you buy from each "
                .. "week.",
        }) do
            local line = helpers.stepper(h, id)
            window(h):SetScrollPosition(line.label.y - 40)
            assert(h.ui:hover(line.hover))
            assert.are.same({ want }, h.ui:tooltips())
            h.ui:leave()
        end
    end)

    it("steps a count in place, saving and logging, with no-ops at either end", function()
        local h = loaded()
        helpers.togglePicks(h, { "broad-arrowheads" })
        openSettings(h)
        local win, line = window(h), helpers.stepper(h, "broad-arrowheads")
        win:SetScrollPosition(line.label.y - 40)
        local writes = h.dbWrites
        -- At 2 of 2, plus changes nothing.
        assert.is_true(h.ui:click(line.plus))
        assert.are.equal(writes, h.dbWrites)
        assert.is_true(h.ui:click(line.minus))
        assert.are.equal("1 of 2", line.value.content)
        assert.are.equal(writes + 1, h.dbWrites)
        assert.are.same({ ["broad-arrowheads"] = 1 }, helpers.stored(h).needed)
        assert.matches("%[CHORES%] needed broad%-arrowheads 1", h:output())
        -- At 1, minus changes nothing.
        assert.is_true(h.ui:click(line.minus))
        assert.are.equal(writes + 1, h.dbWrites)
        local _, lines = h:output():gsub("%] needed ", "")
        assert.are.equal(1, lines)
        assert.are.equal(win, window(h))
        -- Back to all shops, the default, nothing is held for it.
        assert.is_true(h.ui:click(line.plus))
        assert.are.equal("2 of 2", line.value.content)
        assert.are.same({}, helpers.stored(h).needed)
    end)

    it(
        "cuts a long name with dots short of the minus button, and re-fits it on a resize",
        function()
            local h = loaded()
            helpers.togglePicks(h, { "broad-arrowheads" })
            openSettings(h)
            -- Down to the window's least width.
            h.ui:resize(window(h), -1000, 0)
            h:advance(helpers.POLL_MS)
            local line = helpers.stepper(h, "broad-arrowheads")
            local shown = line.label.content
            assert.are.equal("...", shown:sub(-3))
            assert.is_true(line.label.x + fonts.width(shown, false) < line.minus.x)
            h.ui:resize(window(h), 400, 0)
            h:advance(helpers.POLL_MS)
            assert.are.equal("Broad Arrowhead Shop Run", line.label.content)
        end
    )

    it("keeps a count per character, across reloads", function()
        local h = loaded()
        helpers.setNeeded(h, "feather-shop-run", 2)
        h:reload()
        openSettings(h)
        assert.are.equal("2 of 4", helpers.stepper(h, "feather-shop-run").value.content)
        helpers.back(h)
        h.world:logout()
        h.world:login("Lynx Titan")
        h:advance(helpers.POLL_MS)
        helpers.togglePicks(h, { "feather-shop-run" })
        openSettings(h)
        assert.are.equal("4 of 4", helpers.stepper(h, "feather-shop-run").value.content)
    end)

    it("never ticks or unticks on a count change", function()
        local h = loaded()
        helpers.togglePicks(h, { "feather-shop-run" })
        helpers.buy(h, "FISHINGSHOP", "FEATHER_PACK", 20, 19)
        -- Lowered to the one shop bought: still unticked, until the next purchase.
        helpers.setNeeded(h, "feather-shop-run", 1)
        assert.is_false(helpers.ticked(h, "Feather Shop Run"))
        helpers.stock(h, "FISHINGSHOP", "FEATHER_PACK", 15)
        assert.is_true(helpers.ticked(h, "Feather Shop Run"))
        -- Raised above it: the tick stays.
        helpers.setNeeded(h, "feather-shop-run", 3)
        assert.is_true(helpers.ticked(h, "Feather Shop Run"))
        assert.are.equal("Feather Shop Run (1/3)", (helpers.rowShown(h, "Feather Shop Run")))
    end)

    it("loads a version 2 state with every chore at its default count", function()
        local h = loaded({ load = false })
        helpers.seed(
            h,
            "state:Zezima",
            { version = 2, selected = { "rune-shop-run" }, done = {}, shops = {} }
        )
        h:load()
        openSettings(h)
        assert.are.equal("11 of 11", helpers.stepper(h, "rune-shop-run").value.content)
    end)
end)

describe("chore-tracker row hover", function()
    it("sets the hyperlink hand on list and settings rows", function()
        local h = loaded()
        helpers.togglePicks(h, { "daily-challenge" })
        local r = helpers.row(h, "Daily Challenge")
        assert.are.equal(HAND, r.layer.cursorConfig.mouseOverCursor)
        assert.are.equal(HAND, r.layer.opConfig:GetOpCursor(0))
        openSettings(h)
        local s = helpers.settingsRow(h, "daily-challenge")
        assert.are.equal(HAND, s.layer.cursorConfig.mouseOverCursor)
        assert.are.equal(HAND, s.layer.opConfig:GetOpCursor(0))
    end)

    it("draws all four box states on a settings row", function()
        local h = loaded()
        openSettings(h)
        local r = helpers.settingsRow(h, "daily-challenge")
        window(h):SetScrollPosition(r.layer.y - 40)
        assert.are.equal(BOX_EMPTY, r.box.spriteID)
        assert.is_true(h.ui:hover(r.layer))
        assert.are.equal(BOX_EMPTY_HOVERED, r.box.spriteID)
        -- A tick while hovered shows the ticked-hovered sprite, and an untick the empty-hovered.
        assert.is_true(h.ui:click(r.layer))
        assert.are.equal(BOX_TICKED_HOVERED, r.box.spriteID)
        assert.is_true(h.ui:click(r.layer))
        assert.are.equal(BOX_EMPTY_HOVERED, r.box.spriteID)
        h.ui:leave()
        assert.are.equal(BOX_EMPTY, r.box.spriteID)
        assert.is_true(h.ui:click(r.layer))
        h.ui:leave()
        assert.are.equal(BOX_TICKED, r.box.spriteID)
        assert.is_true(h.ui:hover(r.layer))
        assert.are.equal(BOX_TICKED_HOVERED, r.box.spriteID)
        h.ui:leave()
        assert.are.equal(BOX_TICKED, r.box.spriteID)
    end)

    it("reads a hovered ticked row as ticked, and a hovered empty one as not", function()
        local h = loaded()
        helpers.togglePicks(h, { "daily-challenge" })
        local r = helpers.row(h, "Daily Challenge")
        assert.is_true(h.ui:hover(r.layer))
        assert.is_true(h.ui:click(r.layer))
        assert.are.equal(BOX_TICKED_HOVERED, r.box.spriteID)
        assert.is_true(helpers.ticked(h, "Daily Challenge"))
        assert.is_true(h.ui:click(r.layer))
        assert.are.equal(BOX_EMPTY_HOVERED, r.box.spriteID)
        assert.is_false(helpers.ticked(h, "Daily Challenge"))
        h.ui:leave()
    end)

    it("does the same in the list, where a tick dims the row", function()
        local h = loaded()
        helpers.togglePicks(h, { "daily-challenge" })
        local r = helpers.row(h, "Daily Challenge")
        assert.are.equal(BOX_EMPTY, r.box.spriteID)
        assert.is_true(h.ui:hover(r.layer))
        assert.are.equal(BOX_EMPTY_HOVERED, r.box.spriteID)
        assert.is_true(h.ui:click(r.layer))
        assert.are.equal(BOX_TICKED_HOVERED, r.box.spriteID)
        assert.are.equal(0.5, r.icon.alpha)
        assert.is_true(h.ui:click(r.layer))
        assert.are.equal(BOX_EMPTY_HOVERED, r.box.spriteID)
        assert.are.equal(1, r.icon.alpha)
        assert.is_true(h.ui:click(r.layer))
        h.ui:leave()
        assert.are.equal(BOX_TICKED, r.box.spriteID)
        assert.is_true(h.ui:click(r.layer))
        h.ui:leave()
        assert.are.equal(BOX_EMPTY, r.box.spriteID)
    end)

    it("shows the non-hovered box after a collapse and expand with a row hovered", function()
        local h = loaded()
        helpers.togglePicks(h, { "daily-challenge" })
        local r = helpers.row(h, "Daily Challenge")
        assert.is_true(h.ui:hover(r.layer))
        assert.is_true(h.ui:click(r.layer))
        assert.are.equal(BOX_TICKED_HOVERED, r.box.spriteID)
        -- The client sends no mouse-leave to the hidden row, so drive the collapse without one.
        helpers.collapse(h)
        helpers.expand(h)
        assert.are.equal(BOX_TICKED, helpers.row(h, "Daily Challenge").box.spriteID)
    end)

    it("still shows the row's tooltip while the hover hooks run", function()
        local h = loaded()
        helpers.togglePicks(h, { "daily-challenge" })
        local r = helpers.row(h, "Daily Challenge")
        assert.is_true(h.ui:hover(r.layer))
        assert.are.equal(1, #h.ui:tooltips())
        assert.are.equal(BOX_EMPTY_HOVERED, r.box.spriteID)
    end)

    it("takes the tooltip down when the mouse leaves a list row or a settings row", function()
        local h = loaded()
        helpers.togglePicks(h, { "daily-challenge" })
        local r = helpers.row(h, "Daily Challenge")
        assert.is_true(h.ui:hover(r.layer))
        h.ui:leave()
        assert.are.equal(0, #h.ui:tooltips())
        openSettings(h)
        local s = helpers.settingsRow(h, "daily-challenge")
        window(h):SetScrollPosition(s.layer.y - 40)
        assert.is_true(h.ui:hover(s.layer))
        assert.are.equal(1, #h.ui:tooltips())
        h.ui:leave()
        assert.are.equal(0, #h.ui:tooltips())
    end)
end)
