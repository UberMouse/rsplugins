-- The Chore Tracker's settings view and the hover state of its rows: icon rows to pick
-- chores, never dimmed, with a hand cursor and a hovered tick box in both views.

local helpers = require("tests.chore-tracker.helpers")
local catalog = require("tests.harness.catalog")
local chores = require("data/chores")
local fonts = require("tests.harness.api.fonts")
local loaded, openSettings = helpers.loaded, helpers.openSettings

local BOX_EMPTY = catalog.config("Sprite", "RS3_BTN_CHECKBOX_0")
local BOX_EMPTY_HOVERED = catalog.config("Sprite", "RS3_BTN_CHECKBOX_1")
local BOX_TICKED = catalog.config("Sprite", "RS3_BTN_CHECKBOX_2")
local BOX_TICKED_HOVERED = catalog.config("Sprite", "RS3_BTN_CHECKBOX_3")
local HAND = catalog.config("Cursor", "CURSOR_HYPERLINK_HAND")
local TEXT_COLOUR = 0xE7D7B0FF

---@param h table
---@return table
local function window(h)
    return h.ui:get("Window", { text = "Chores" })
end

describe("chore-tracker settings rows", function()
    it("lists every chore as an icon row under its period's heading, shop ones suffixed", function()
        local h = loaded()
        openSettings(h)
        -- Wide enough that no name is cut short.
        h.ui:resize(window(h), 600, 0)
        h:advance(600)
        local list = helpers.rows(h)
        assert.are.equal(#chores, #list)
        local shop = 0
        for _, group in ipairs(require("core/view").byPeriod(chores)) do
            h.ui:get("Title", { text = group.title })
            for _, chore in ipairs(group.chores) do
                local r = helpers.settingsRow(h, chore.id)
                if chore.shop then
                    assert.are.equal(chore.name, r.label.content:sub(1, #chore.name))
                    assert.are.equal(" (shop)", r.label.content:sub(#chore.name + 1))
                    shop = shop + 1
                else
                    assert.are.equal(chore.name, r.label.content)
                end
                assert.is_not_nil(r.icon)
                assert.are.equal(BOX_EMPTY, r.box.spriteID)
            end
        end
        assert.is_true(shop > 0)
        assert.are.equal(
            "Pure Essence from Wizard Cromperty (shop)",
            helpers.settingsRow(h, "cromperty-pure-essence").label.content
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
        helpers.pick(h, { "daily-challenge" })
        h.ui:get("Title", { text = "Daily  0/1" })
        openSettings(h)
        assert.is_true(helpers.picked(h, "daily-challenge"))
    end)

    it("cuts a long name with dots, with a tooltip led by the full name", function()
        local h = loaded()
        openSettings(h)
        local r = helpers.settingsRow(h, "cromperty-pure-essence")
        local full = "Pure Essence from Wizard Cromperty (shop)"
        assert.are.equal("...", r.label.content:sub(-3))
        assert.is_true(fonts.width(r.label.content, false) <= r.layer.width - 52)
        window(h):SetScrollPosition(r.layer.y - 40)
        assert.is_true(h.ui:hover(r.layer))
        assert.are.equal(full .. "<br>Weekly stock", h.ui:tooltips()[1]:sub(1, #full + 16))
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

    it("keeps the Celebrations switches working", function()
        local h = loaded()
        openSettings(h)
        assert.is_true(h.ui:click(helpers.group(h, "sound"), "sound"))
        assert.is_false(helpers.picked(h, "sound"))
        assert.is_true(helpers.picked(h, "popups"))
    end)
end)

describe("chore-tracker row hover", function()
    it("sets the hyperlink hand on list and settings rows", function()
        local h = loaded()
        helpers.pick(h, { "daily-challenge" })
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

    it("does the same in the list, where a tick dims the row", function()
        local h = loaded()
        helpers.pick(h, { "daily-challenge" })
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
        helpers.pick(h, { "daily-challenge" })
        local r = helpers.row(h, "Daily Challenge")
        assert.is_true(h.ui:hover(r.layer))
        assert.is_true(h.ui:click(r.layer))
        assert.are.equal(BOX_TICKED_HOVERED, r.box.spriteID)
        -- The client sends no mouse-leave to the hidden row, so drive the collapse without one.
        h.ui:click(h.ui:get("SpriteButton", { sprite = "MENU" }))
        h:advance(20)
        h.ui:click(h.ui:get("SpriteButton", { sprite = "MENU", visible = true }))
        h:advance(20)
        assert.are.equal(BOX_TICKED, helpers.row(h, "Daily Challenge").box.spriteID)
    end)

    it("still shows the row's tooltip while the hover hooks run", function()
        local h = loaded()
        helpers.pick(h, { "daily-challenge" })
        local r = helpers.row(h, "Daily Challenge")
        assert.is_true(h.ui:hover(r.layer))
        assert.are.equal(1, #h.ui:tooltips())
        assert.are.equal(BOX_EMPTY_HOVERED, r.box.spriteID)
    end)

    it("takes the tooltip down when the mouse leaves a list row or a settings row", function()
        local h = loaded()
        helpers.pick(h, { "daily-challenge" })
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
