-- The Chore Tracker's info view through the harness: the info button beside the settings
-- button, the help, the status headings and their display-only rows, and the way back.

local helpers = require("tests.chore-tracker.helpers")
local chores = require("data/chores")
local shops = require("data/shops")
local collections = require("data/collections")
local machines = require("data/machines")
local varRules = require("data/vars")
local fonts = require("tests.harness.api.fonts")
local fit = require("core/fit")
local info = require("core/info")
local layout = require("core/layout")
local view = require("core/view")
local loaded, openInfo, window = helpers.loaded, helpers.openInfo, helpers.window

-- The help's lines wider than `maxWidth` in the rows' font, and the widest line's width.
---@param h table
---@param maxWidth integer
---@return string[] tooWide
---@return number widest
local function helpLines(h, maxWidth)
    local tooWide, widest = {}, 0
    for _, text in ipairs(h.ui:find("Text")) do
        for line in (text.content .. fit.BREAK):gmatch("(.-)" .. fit.BREAK) do
            local width = fonts.width(line, false)
            widest = math.max(widest, width)
            if width > maxWidth then tooWide[#tooWide + 1] = line end
        end
    end
    return tooWide, widest
end

-- The info view's row for chore `id`, found by position: the rows are in byStatus order.
---@param h table
---@param id string
---@return table
local function infoRow(h, id)
    local list, n = helpers.rows(h), 0
    for _, group in ipairs(info.byStatus(chores, shops, collections, varRules, machines)) do
        for _, chore in ipairs(group.chores) do
            n = n + 1
            if chore.id == id then return assert(list[n], "no info row " .. id) end
        end
    end
    error("no chore " .. id)
end

describe("chore-tracker info button", function()
    it("sits beside the settings button, the same size, with its tooltip", function()
        local h = loaded()
        local settings = h.ui:layout(h.ui:get("SpriteButton", { sprite = "SETTINGS" }))
        local button = h.ui:get("SpriteButton", { sprite = "INFO" })
        local at = h.ui:layout(button)
        assert.are.equal(settings.y, at.y)
        assert.are.same({ settings.width, settings.height }, { at.width, at.height })
        assert.is_true(at.x >= settings.x + settings.width)
        assert.is_true(h.ui:hover(button))
        assert.are.same({ "About Chore Tracker" }, h.ui:tooltips())
        h.ui:leave()
    end)

    it("shows while waiting for the clock, but not logged out", function()
        local waiting = loaded({ clock = 0 })
        waiting.ui:get("SpriteButton", { sprite = "INFO" })
        local out = loaded({ login = false })
        assert.are.same({}, out.ui:find("SpriteButton", { sprite = "INFO" }))
    end)
end)

describe("chore-tracker info view", function()
    it("opens on the next tick with the back button in the slot", function()
        local h = loaded()
        helpers.click(h, h.ui:get("SpriteButton", { sprite = "INFO" }))
        h.ui:get("SpriteButton", { sprite = "SETTINGS" })
        h:advance(20)
        assert.are.same({}, h.ui:find("SpriteButton", { sprite = "SETTINGS" }))
        local back = h.ui:get("SpriteButton", { sprite = "BACK" })
        assert.is_true(h.ui:hover(back))
        assert.are.same({ "Back to the list" }, h.ui:tooltips())
        h.ui:leave()
    end)

    it("shows the help, wrapped to the window's width, above the three status headings", function()
        local h = loaded()
        openInfo(h)
        local texts = h.ui:find("Text")
        assert.are.equal(#info.HELP, #texts)
        local tooWide, widest = helpLines(h, layout.helpTextWidth(window(h).root.width))
        assert.are.same({}, tooWide)
        -- The default window is wider than the narrowest, and the help uses that room.
        assert.is_true(widest > layout.helpTextWidth(layout.MIN_WIDTH))
        h.ui:get("Text", { text = "Drag a row by its grip" })
        local titles = h.ui:find("Title")
        assert.are.same(
            { "Automatic (41)", "Unproven (21)", "Manual (6)" },
            { titles[1].content, titles[2].content, titles[3].content }
        )
        local last = texts[#texts]
        assert.is_true(titles[1].y >= last.y + last.height)
    end)

    it("lists every chore as a display-only icon row, with its tooltip", function()
        local h = loaded()
        openInfo(h)
        assert.are.equal(#chores, #helpers.rows(h))
        local r = infoRow(h, "dream-of-iaia-xp-weekly")
        assert.are.equal("Dream of Iaia XP (weekly)", r.text)
        assert.is_nil(r.box)
        assert.is_nil(r.grip)
        assert.is_not_nil(r.icon)
        local feathers = infoRow(h, "feather-shop-run")
        assert.are.equal("Feather Shop Run", feathers.text)
        window(h):SetScrollPosition(feathers.layer.y - 40)
        assert.is_true(h.ui:hover(feathers.layer))
        local chore = assert(require("core/state").find(chores, "feather-shop-run"))
        assert.are.same({ view.tooltip(chore).text }, h.ui:tooltips())
        h.ui:leave()
    end)

    it("ticks and picks nothing on a click, and scrolls on the wheel", function()
        local h = loaded()
        openInfo(h)
        local r = infoRow(h, "daily-challenge")
        window(h):SetScrollPosition(r.layer.y - 40)
        assert.is_true(h.ui:click(r.label))
        h:advance(20)
        assert.is_nil(helpers.stored(h))
        local before = window(h)._scroll.scrollY
        assert.are.same({ true, 1 }, { h.ui:wheel(r.label, 1) })
        assert.are.equal(before + 32, window(h)._scroll.scrollY)
    end)

    it("cuts a long name with dots and refits it when the window widens", function()
        local h = loaded()
        openInfo(h)
        local r = infoRow(h, "dellmonti-pineapples")
        assert.are.equal("...", r.label.content:sub(-3))
        assert.is_true(fonts.width(r.label.content, false) <= h.ui:layout(r.label).width)
        h.ui:resize(window(h), 400, 0)
        -- One poll: the width has only just changed, so the view isn't re-laid yet.
        h:advance(helpers.POLL_MS)
        assert.are.equal("Pineapples and Apples from Dell Monti", r.label.content)
    end)

    it("re-wraps the help for a new width once it settles, keeping the scroll", function()
        local h = loaded()
        openInfo(h)
        window(h):SetScrollPosition(100)
        local first = h.ui:find("Text")[1]
        h.ui:resize(window(h), -80, 0)
        h:advance(helpers.POLL_MS)
        -- The width changed since the last poll: still settling, so nothing is rebuilt.
        assert.are.equal(first, h.ui:find("Text")[1])
        h:advance(helpers.POLL_MS)
        assert.are_not.equal(first, h.ui:find("Text")[1])
        assert.are.equal(layout.MIN_WIDTH, window(h).root.width)
        assert.are.same({}, (helpLines(h, layout.helpTextWidth(layout.MIN_WIDTH))))
        assert.are.equal(100, window(h)._scroll.scrollY)
        h.ui:get("SpriteButton", { sprite = "BACK" })
    end)

    it("waits while the width keeps changing between polls", function()
        local h = loaded()
        openInfo(h)
        local before = window(h)
        h.ui:resize(before, -40, 0)
        h:advance(helpers.POLL_MS)
        h.ui:resize(before, -40, 0)
        h:advance(helpers.POLL_MS)
        assert.are.equal(before, window(h))
        h:advance(helpers.POLL_MS)
        assert.are_not.equal(before, window(h))
    end)

    it("waits for a held resize to be let go, even with the width settled", function()
        local h = loaded()
        openInfo(h)
        local before = window(h)
        h.ui:holdResize(before)
        h.ui:resize(before, -80, 0, true)
        h:advance(3 * helpers.POLL_MS)
        assert.are.equal(before, window(h))
        h.ui:releaseResize(before)
        h:advance(helpers.POLL_MS)
        assert.are_not.equal(before, window(h))
    end)

    it("rebuilds nothing on a height-only resize", function()
        local h = loaded()
        openInfo(h)
        local before = window(h)
        h.ui:resize(before, 0, 100)
        h:advance(3 * helpers.POLL_MS)
        assert.are.equal(before, window(h))
    end)

    it("leaves the list and settings views alone on a resize", function()
        local h = loaded()
        -- A picked chore with a count, so settings shows its line rather than help to re-lay.
        helpers.togglePicks(h, { "herb-run" })
        local list = window(h)
        h.ui:resize(list, -80, 0)
        h:advance(3 * helpers.POLL_MS)
        assert.are.equal(list, window(h))
        helpers.openSettings(h)
        local settings = window(h)
        h.ui:resize(settings, 80, 0)
        h:advance(3 * helpers.POLL_MS)
        assert.are.equal(settings, window(h))
    end)

    it("re-lays the settings' How many to do help on a resize", function()
        local h = loaded()
        helpers.openSettings(h)
        local settings = window(h)
        ---@return string? the help, its line breaks taken back out
        local function shownHelp()
            for _, text in ipairs(h.ui:find("Text")) do
                local joined = text.content:gsub(fit.BREAK, " ")
                if joined == view.NO_COUNTS then return text.content end
            end
            return nil
        end
        local before = assert(shownHelp(), "no How many to do help")
        h.ui:resize(settings, 160, 0)
        h:advance(3 * helpers.POLL_MS)
        assert.are_not.equal(settings, window(h))
        assert.are_not.equal(before, shownHelp())
    end)

    it("goes back to the list", function()
        local h = loaded()
        openInfo(h)
        helpers.back(h)
        h.ui:get("SpriteButton", { sprite = "INFO" })
        h.ui:get("SpriteButton", { sprite = "MENU" })
        assert.are.same({}, h.ui:find("SpriteButton", { sprite = "BACK" }))
    end)

    it("returns to the logged-out notice on a logout, and to the list on the next login", function()
        local h = loaded()
        openInfo(h)
        h.world:logout()
        h:advance(helpers.POLL_MS)
        h.ui:get("Text", { text = "Log in to see your chores" })
        assert.are.same({}, h.ui:find("SpriteButton", { sprite = "BACK" }))
        h.world:login("Zezima")
        h:advance(helpers.POLL_MS)
        h.ui:get("SpriteButton", { sprite = "INFO" })
        assert.are.same({}, h.ui:find("SpriteButton", { sprite = "BACK" }))
    end)

    it("drops an info switch clicked just before a logout", function()
        local h = loaded()
        helpers.click(h, h.ui:get("SpriteButton", { sprite = "INFO" }))
        -- The logout is seen through the clock's VarTransmit before the next Logic tick.
        h.world:logout()
        helpers.setClock(h, helpers.NOW + 1)
        h:advance(20)
        h.ui:get("Text", { text = "Log in to see your chores" })
        h.world:login("Zezima")
        h:advance(helpers.POLL_MS)
        assert.are.same({}, h.ui:find("SpriteButton", { sprite = "BACK" }))
    end)
end)
