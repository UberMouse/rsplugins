-- The Chore Tracker's window through the harness and its PrettyUI fake: the views, ticking,
-- and the collapse button.

local harness = require("tests.harness")

-- 2026-10-25 01:43 UTC, a Sunday.
local NOW = 29881543

---@return table h
local function loaded()
    local h = harness.new("chore-tracker")
    h.world:setVar("VarPlayer", "CLOCK_TIME_DATE_MINUTES", NOW)
    h:load()
    return h
end

-- The one visible list row (of its normal and dimmed copies) for a chore name.
---@param h table
---@param name string
---@return table
local function row(h, name)
    return h.ui:get("CheckboxButton", { text = name, visible = true })
end

-- Open settings, pick the chores whose ids are given, and go back to the list.
---@param h table
---@param ids string[]
local function pick(h, ids)
    assert.is_true(h.ui:click(h.ui:get("SpriteButton", { sprite = "SETTINGS" })))
    h:advance(20)
    for _, id in ipairs(ids) do
        local group
        for _, cb in ipairs(h.ui:find("CheckboxButton")) do
            for _, choice in ipairs(h.ui:choices(cb)) do
                if choice.value == id then group = cb end
            end
        end
        assert.is_true(h.ui:click(assert(group, id), id))
    end
    assert.is_true(h.ui:click(h.ui:get("SpriteButton", { sprite = "BACK" })))
    h:advance(20)
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

    it("lists every chore in settings, shop ones suffixed, in three groups", function()
        local h = loaded()
        h.ui:click(h.ui:get("SpriteButton", { sprite = "SETTINGS" }))
        h:advance(20)
        local total, shop = 0, 0
        local groups = h.ui:find("CheckboxButton")
        for _, cb in ipairs(groups) do
            for _, choice in ipairs(h.ui:choices(cb)) do
                total = total + 1
                if choice.text:find(" %(shop%)$") then shop = shop + 1 end
            end
        end
        assert.are.equal(3, #groups)
        assert.are.equal(67, total)
        assert.is_true(shop > 0)
    end)

    it("shows picked chores and ticks them in place, dimmed, keeping the window put", function()
        local h = loaded()
        local before = h.ui:layout(h.ui:get("Window", { text = "Chores" }))
        pick(h, { "daily-challenge", "player-owned-farm" })
        local win = h.ui:get("Window", { text = "Chores" })
        local after = h.ui:layout(win)
        assert.are.same({ before.x, before.y, before.width, before.height }, {
            after.x,
            after.y,
            after.width,
            after.height,
        })
        h.ui:get("Title", { text = "Daily  0/2" })

        local _, colour = h.ui:choices(row(h, "Daily Challenge"))
        assert.is_true(h.ui:click(row(h, "Daily Challenge"), "daily-challenge"))
        h.ui:get("Title", { text = "Daily  1/2" })
        local done = row(h, "Daily Challenge")
        local choices, dimmed = h.ui:choices(done)
        assert.is_true(choices[1].selected)
        assert.are_not.equal(colour, dimmed)
        assert.matches("runescape.wiki", choices[1].tooltip.text)

        assert.is_true(h.ui:click(done, "daily-challenge"))
        h.ui:get("Title", { text = "Daily  0/2" })
        assert.is_false(h.ui:choices(row(h, "Daily Challenge"))[1].selected)
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
end)
