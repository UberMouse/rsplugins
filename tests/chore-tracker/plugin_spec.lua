-- The Chore Tracker against the game through the harness: saving per character, the clock
-- and its resets, being logged out or waiting for the clock, and the saved layout.

local helpers = require("tests.chore-tracker.helpers")
local loaded, row, ticked, tick, pick =
    helpers.loaded, helpers.row, helpers.ticked, helpers.tick, helpers.pick

local DAILY = { name = "Daily Challenge", id = "daily-challenge" }
local WEEKLY = { name = "Soul Reaper", id = "soul-reaper" }
local MONTHLY = { name = "Giant Oyster", id = "giant-oyster" }

-- Half a second: long enough for the plugin's login and layout poll (every 25 Logic ticks).
local POLL_MS = 500

---@param h table
---@param minutes integer
local function setClock(h, minutes)
    h.world:setVar("VarPlayer", "CLOCK_TIME_DATE_MINUTES", minutes)
end

---@param h table
---@return table
local function window(h)
    return h.ui:get("Window", { text = "Chores" })
end

---@param h table
---@return integer[]
local function geometry(h)
    local l = h.ui:layout(window(h))
    return { l.x, l.y, l.width, l.height }
end

describe("chore-tracker saving", function()
    it("keeps a tick across a reload, written when it is made", function()
        local h = loaded()
        pick(h, { DAILY.id })
        local writes = h.dbWrites
        tick(h, DAILY.name)
        assert.are.equal(writes + 1, h.dbWrites)
        h:reload()
        assert.is_true(ticked(h, DAILY.name))
        h.ui:get("Title", { text = "Daily  1/1" })
    end)

    it("shows and hides rows as chores are picked and unpicked, and keeps the picks", function()
        local h = loaded()
        pick(h, { DAILY.id, WEEKLY.id })
        row(h, DAILY.name)
        row(h, WEEKLY.name)
        pick(h, { DAILY.id })
        assert.is_nil(helpers.findRow(h, DAILY.name))
        row(h, WEEKLY.name)
        h:reload()
        assert.is_nil(helpers.findRow(h, DAILY.name))
        row(h, WEEKLY.name)
        helpers.openSettings(h)
        assert.is_false(helpers.picked(h, DAILY.id))
        assert.is_true(helpers.picked(h, WEEKLY.id))
    end)

    it("writes nothing while nothing changes, and the layout once when it does", function()
        local h = loaded()
        pick(h, { DAILY.id })
        local writes = h.dbWrites
        h:advance(5000)
        setClock(h, helpers.NOW + 1)
        h:advance(5000)
        assert.are.equal(writes, h.dbWrites)
        h.ui:dragTitle(window(h), 30, 20)
        h:advance(POLL_MS)
        assert.are.equal(writes + 1, h.dbWrites)
        h:advance(5000)
        assert.are.equal(writes + 1, h.dbWrites)
    end)
end)

describe("chore-tracker clock", function()
    it("unticks each period's chores as the clock crosses its reset, in place", function()
        local h = loaded()
        pick(h, { DAILY.id, WEEKLY.id, MONTHLY.id })
        for _, chore in ipairs({ DAILY, WEEKLY, MONTHLY }) do
            tick(h, chore.name)
        end
        local win, at = window(h), geometry(h)

        setClock(h, helpers.NEXT_DAY - 1)
        assert.is_true(ticked(h, DAILY.name))
        setClock(h, helpers.NEXT_DAY)
        assert.is_false(ticked(h, DAILY.name))
        assert.is_true(ticked(h, WEEKLY.name))
        assert.is_true(ticked(h, MONTHLY.name))
        h.ui:get("Title", { text = "Daily  0/1" })

        setClock(h, helpers.WEDNESDAY)
        assert.is_false(ticked(h, WEEKLY.name))
        assert.is_true(ticked(h, MONTHLY.name))
        h.ui:get("Title", { text = "Weekly  0/1" })

        setClock(h, helpers.NEXT_MONTH)
        assert.is_false(ticked(h, MONTHLY.name))
        h.ui:get("Title", { text = "Monthly  0/1" })

        assert.are.equal(win, window(h))
        assert.are.same(at, geometry(h))
    end)

    it("waits for the clock: no ticks, nothing marked, one log line", function()
        local h = loaded()
        pick(h, { DAILY.id })
        tick(h, DAILY.name)
        setClock(h, 0)
        setClock(h, 0)
        h.ui:get("Text", { text = "Waiting for the game clock" })
        assert.is_false(ticked(h, DAILY.name))
        local writes = h.dbWrites
        tick(h, DAILY.name)
        assert.is_false(ticked(h, DAILY.name))
        assert.are.equal(writes, h.dbWrites)
        local _, waits = h:output():gsub("waiting for the game clock", "")
        assert.are.equal(1, waits)

        setClock(h, helpers.NOW + 5)
        assert.are.same({}, h.ui:find("Text", { text = "Waiting" }))
        assert.is_true(ticked(h, DAILY.name))
    end)

    it("waits for the clock when it doesn't read at load", function()
        local h = loaded({ clock = 0 })
        h.ui:get("Text", { text = "Waiting for the game clock" })
        assert.matches("%[CHORES%] waiting for the game clock", h:output())
    end)
end)

describe("chore-tracker login", function()
    it("asks to log in while logged out, with nothing to tick, and follows a login", function()
        local h = loaded({ login = false })
        h.ui:get("Text", { text = "Log in to see your chores" })
        assert.are.same({}, helpers.rows(h))
        assert.are.same({}, h.ui:find("SpriteButton", { sprite = "SETTINGS" }))

        h.world:login("Zezima")
        h:advance(POLL_MS)
        h.ui:get("SpriteButton", { sprite = "SETTINGS" })
        h.world:logout()
        h:advance(POLL_MS)
        h.ui:get("Text", { text = "Log in to see your chores" })
    end)

    it("keeps each character's picks and ticks apart, and never logs a name", function()
        local h = loaded()
        pick(h, { DAILY.id })
        tick(h, DAILY.name)

        h.world:logout()
        h.world:login("Lynx Titan")
        h:advance(POLL_MS)
        h.ui:get("Text", { text = "No chores picked yet" })
        pick(h, { WEEKLY.id })
        assert.is_nil(helpers.findRow(h, DAILY.name))

        h.world:logout()
        h.world:login("Zezima")
        h:advance(POLL_MS)
        assert.is_true(ticked(h, DAILY.name))
        assert.is_nil(helpers.findRow(h, WEEKLY.name))

        assert.is_nil(h:output():find("Zezima", 1, true))
        assert.is_nil(h:output():find("Lynx", 1, true))
    end)

    it("drops a view switch clicked just before a logout", function()
        local h = loaded()
        h.ui:click(h.ui:get("SpriteButton", { sprite = "SETTINGS" }))
        -- The logout is seen (here through the clock's VarTransmit) before the next Logic
        -- tick applies the switch.
        h.world:logout()
        setClock(h, helpers.NOW + 1)
        h:advance(20)
        h.ui:get("Text", { text = "Log in to see your chores" })
        h.world:login("Zezima")
        h:advance(POLL_MS)
        h.ui:get("SpriteButton", { sprite = "SETTINGS" })
        assert.are.same({}, h.ui:find("SpriteButton", { sprite = "BACK" }))
    end)

    it("shows the new character straight from the settings view", function()
        local h = loaded()
        pick(h, { DAILY.id })
        helpers.openSettings(h)
        h.world:logout()
        h.world:login("Lynx Titan")
        h:advance(POLL_MS)
        assert.is_false(helpers.picked(h, DAILY.id))
    end)
end)

describe("chore-tracker layout", function()
    it("opens at a fixed spot on the first run, open", function()
        local h = loaded()
        assert.are.same({ 600, 300, 320, 420 }, geometry(h))
        assert.are.same({}, h.ui:find("Panel"))
    end)

    it("restores the window's position and size after a reload", function()
        local h = loaded()
        h.ui:dragTitle(window(h), -100, 60)
        h.ui:resize(window(h), 40, -100)
        local at = geometry(h)
        h:reload()
        assert.are.same(at, geometry(h))
    end)

    it("restores a collapsed button where it was Alt-dragged", function()
        local h = loaded()
        h.ui:click(h.ui:get("SpriteButton", { sprite = "MENU" }))
        h:advance(20)
        h.ui:holdAlt(true)
        h.ui:altDrag(h.ui:get("Panel"), 300, 200)
        h.ui:holdAlt(false)
        local spot = h.ui:layout(h.ui:get("SpriteButton", { sprite = "MENU", visible = true }))
        h:reload()
        assert.is_false(h.ui:layout(window(h)).visible)
        local now = h.ui:layout(h.ui:get("SpriteButton", { sprite = "MENU", visible = true }))
        assert.are.same({ spot.globalX, spot.globalY }, { now.globalX, now.globalY })

        h.ui:click(h.ui:get("SpriteButton", { sprite = "MENU", visible = true }))
        h:advance(20)
        local open = h.ui:layout(h.ui:get("SpriteButton", { sprite = "MENU" }))
        assert.are.same({ spot.globalX, spot.globalY }, { open.globalX, open.globalY })
    end)

    it("moves a saved layout that no longer fits back inside the plugin layer", function()
        local h = loaded()
        h.ui:dragTitle(window(h), 10, 10)
        h:unload()
        local stored = h.db.layout.value
        stored.x, stored.y, stored.width, stored.height = 5000, -40, 9000, 300
        h:load()
        assert.are.same({ 0, 0, 3836, 300 }, geometry(h))
        h:advance(POLL_MS)
        assert.are.same(0, h.db.layout.value.x)
    end)
end)
