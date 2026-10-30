-- The Chore Tracker's settings view and the hover state of its rows: icon rows to pick
-- chores, never dimmed, with a hand cursor and a hovered tick box in both views.

local helpers = require("tests.chore-tracker.helpers")
local catalog = require("tests.harness.catalog")
local chores = require("data/chores")
local fonts = require("tests.harness.api.fonts")
local listlayout = require("core/listlayout")
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
        local view = require("core/view")
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
        assert.are.same({ true, 1 }, { h.ui:wheel(r.label, 1) })
        assert.are.equal(32, window(h)._scroll.scrollY)
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
        assert.is_true(h.ui:hover(s.layer))
        assert.are.equal(1, #h.ui:tooltips())
        h.ui:leave()
        assert.are.equal(0, #h.ui:tooltips())
    end)
end)
