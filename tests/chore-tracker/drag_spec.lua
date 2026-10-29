-- Reordering the Chore Tracker's list by dragging a row's grip (shell/grips.lua): the grips and
-- their press targets, the drag with its live shift and auto-scroll, the drop and its save,
-- and what other events do to a drag in progress.

local harness = require("tests.harness")
local uiFake = require("tests.harness.api.ui")
local helpers = require("tests.chore-tracker.helpers")
local loaded, row, rows = helpers.loaded, helpers.row, helpers.rows

local ROW = 28
-- Five daily chores, two weekly and one monthly, in this stored order.
local DAILY = {
    "daily-challenge",
    "player-owned-ports",
    "player-owned-farm",
    "crystal-tree-blossom",
    "invention-machine",
}
local NAMES = {
    ["daily-challenge"] = "Daily Challenge",
    ["player-owned-ports"] = "Player Owned Ports",
    ["player-owned-farm"] = "Player Owned Farm",
    ["crystal-tree-blossom"] = "Crystal Tree Blossom",
    ["invention-machine"] = "Invention Machine",
    ["soul-reaper"] = "Soul Reaper",
    ["feather-shop-run"] = "Feather Shop Run",
    ["giant-oyster"] = "Giant Oyster",
}
local WEEKLY = { "soul-reaper", "feather-shop-run" }
local MONTHLY = { "giant-oyster" }

-- `who`'s stored picks: the lists given, concatenated in order.
---@param h table
---@param who string
---@param ... string[]
local function seed(h, who, ...)
    local selected = {}
    for _, list in ipairs({ ... }) do
        for _, id in ipairs(list) do
            selected[#selected + 1] = id
        end
    end
    h.db["state:" .. who] = {
        type = harness.enums.PersistentDBType.STRUCTURED_DATA,
        value = { version = 2, selected = selected, done = {}, shops = {} },
    }
end

-- A loaded tracker for Zezima with DAILY, WEEKLY and MONTHLY picked.
---@param opts table?
---@return table
local function ready(opts)
    local h = loaded({ load = false, login = opts and opts.login })
    seed(h, "Zezima", DAILY, WEEKLY, MONTHLY)
    h:load()
    return h
end

---@param h table
---@return table
local function window(h)
    return h.ui:get("Window", { text = "Chores" })
end

-- The press targets the plugin has on the plugin layer (live ones, shown or not): layers
-- with the grip's PUSH cursor.
---@param h table
---@return table[] component states
local function targets(h)
    local push = h.env.id.Cursor.CURSOR_PUSH
    local out = {}
    for _, child in ipairs(h.instance.uiRoot.children) do
        if
            child.class == "ui.Layer"
            and not child.destroyed
            and child.cursorState
            and child.cursorState.mouseOverCursor == push
        then
            out[#out + 1] = child
        end
    end
    return out
end

-- The shown press targets.
---@param h table
---@return table[]
local function shownTargets(h)
    local out = {}
    for _, t in ipairs(targets(h)) do
        if not t.hidden then out[#out + 1] = t end
    end
    return out
end

-- The shown target docked exactly over a chore's grip (where the grip is drawn), or nil.
---@param h table
---@param id string
---@return table? the target component
local function targetOf(h, id)
    local grip = h.ui:layout(row(h, NAMES[id]).grip)
    for _, t in ipairs(shownTargets(h)) do
        local at = h.ui:layout(t.proxy)
        if
            at.globalX == grip.globalX
            and at.globalY == grip.globalY
            and at.width == 16
            and at.height == 16
        then
            return t.proxy
        end
    end
    return nil
end

-- The chore ids of the list's rows, top to bottom by their content y.
---@param h table
---@return string[]
local function order(h)
    local byName = {}
    for id, name in pairs(NAMES) do
        byName[name] = id
    end
    local out = {}
    for _, r in ipairs(rows(h)) do
        local name = r.text:gsub(" %(%d+/%d+%)$", "")
        out[#out + 1] = byName[name] or name
    end
    return out
end

-- The stored order of `who`'s picks.
---@param h table
---@param who string?
---@return string[]
local function stored(h, who)
    return h.db["state:" .. (who or "Zezima")].value.selected
end

-- A chore row's content y.
---@param h table
---@param id string
---@return integer
local function rowY(h, id)
    return row(h, NAMES[id]).layer.y
end

-- Whether every grip wholly inside the visible list has a target docked over it and no other
-- target shows; returns how many grips are in view.
---@param h table
---@return integer
local function docked(h)
    local view = h.ui:layout(window(h).viewport)
    local inView = 0
    for id, name in pairs(NAMES) do
        local r = helpers.findRow(h, name)
        if r then
            local g = h.ui:layout(r.grip)
            local shown = g.globalY >= view.globalY and g.globalY + 16 <= view.globalY + view.height
            if shown then inView = inView + 1 end
            assert(shown == (targetOf(h, id) ~= nil), "target of " .. id)
        end
    end
    assert(inView == #shownTargets(h), "a target shown away from its grip")
    return inView
end

-- Press a chore's grip at its centre and take the first hold there; returns the pointer.
---@param h table
---@param id string
---@return number x
---@return number y
local function grab(h, id)
    local target = assert(targetOf(h, id), "no target over " .. id)
    local at = h.ui:layout(target)
    local x, y = at.globalX + 8, at.globalY + 8
    assert(h.ui:press(target, x, y))
    assert(h.ui:moveTo(x, y))
    return x, y
end

describe("chore-tracker grips", function()
    it("shows a grip at the left of each list row, and none in settings", function()
        local h = ready()
        for _, r in ipairs(rows(h)) do
            assert.are.equal(h.env.id.Sprite.HAMBURGER_MENU_ICON, r.grip.spriteID)
            local at = h.ui:layout(r.grip)
            assert.are.same({ 0, 6, 16, 16 }, { at.x, at.y, at.width, at.height })
        end
        helpers.openSettings(h)
        for _, r in ipairs(rows(h)) do
            assert.is_nil(r.grip)
        end
        assert.are.equal(0, #targets(h))
    end)

    it("docks a PUSH press target over each grip in view, hidden out of view", function()
        local h = ready()
        h.ui:resize(window(h), 0, -150)
        h:advance(20)
        local push = h.env.id.Cursor.CURSOR_PUSH
        assert.are.equal(8, #targets(h))
        local t = assert(targetOf(h, "daily-challenge"))
        assert.are.equal(push, t.cursorConfig.mouseOverCursor)
        assert.are.equal(push, t.opConfig:GetOpCursor(0))
        assert.is_false(t.clickthrough)
        -- Every grip wholly inside the visible list has its target; the rest are hidden.
        local inView = docked(h)
        assert.is_true(inView > 0 and inView < 8)
        -- The wheel over a grip still scrolls the window.
        assert.are.same({ true, 1 }, { h.ui:wheel(t, 1) })
        assert.are.equal(32, window(h)._scroll.scrollY)
    end)

    it("follows its grip within a tick when the window scrolls, moves or resizes", function()
        local h = ready()
        local win = window(h)
        h.ui:resize(win, 0, -150)
        h:advance(20)
        docked(h)
        -- The first row's grip partly scrolled out of view: its target hides.
        local scroll = rowY(h, "daily-challenge") + 6 + 8
        win:SetScrollPosition(scroll)
        h:advance(20)
        assert.are.equal(scroll, win._scroll.scrollY)
        assert.is_nil(targetOf(h, "daily-challenge"))
        assert.is_not_nil(targetOf(h, "player-owned-ports"))
        docked(h)

        h.ui:wheel(row(h, "Player Owned Farm").layer, 1)
        h:advance(20)
        assert.are.equal(scroll + 32, win._scroll.scrollY)
        docked(h)
        h.ui:dragTitle(win, -200, 40)
        h:advance(20)
        docked(h)
        h.ui:resize(win, 40, 100)
        h:advance(20)
        docked(h)
    end)

    it("hides the targets while collapsed, and brings them back over the window", function()
        local h = ready()
        h.ui:click(h.ui:get("SpriteButton", { sprite = "MENU", visible = true }))
        assert.are.equal(0, #shownTargets(h))
        h:advance(100)
        assert.are.equal(0, #shownTargets(h))
        local before = #targets(h)
        h.ui:click(h.ui:get("SpriteButton", { sprite = "MENU", visible = true }))
        h:advance(20)
        assert.are.equal(before, #targets(h))
        local t = assert(targetOf(h, "daily-challenge"))
        -- Drawn over the re-shown window: a press lands on it.
        assert.is_true(h.ui:press(t))
        assert.is_true(h.ui:release())
    end)

    it("has no targets while logged out", function()
        local h = ready()
        h.world:logout()
        h:advance(500)
        assert.are.equal(0, #targets(h))
    end)
end)

describe("chore-tracker grip clicks", function()
    it("never ticks the row; a click on the rest of the row still does", function()
        local h = ready()
        local writes = h.dbWrites
        assert.is_true(h.ui:click(assert(targetOf(h, "daily-challenge"))))
        h:advance(100)
        assert.is_false(helpers.ticked(h, "Daily Challenge"))
        assert.are.equal(writes, h.dbWrites)
        assert.are.same(DAILY, { table.unpack(order(h), 1, 5) })
        helpers.tick(h, "Daily Challenge")
        assert.is_true(helpers.ticked(h, "Daily Challenge"))
    end)

    it("moves and saves nothing on a press held still and let go", function()
        local h = ready()
        local writes = h.dbWrites
        grab(h, "player-owned-ports")
        h:advance(20)
        assert.is_true(h.ui:moveTo(h.ui.pressing.x, h.ui.pressing.y))
        assert.is_true(h.ui:release())
        assert.are.equal(writes, h.dbWrites)
        assert.are.same(DAILY, { table.unpack(order(h), 1, 5) })
        assert.is_not_nil(targetOf(h, "player-owned-ports"))
        assert.is_nil(h:output():find("moved", 1, true))
    end)

    it("leaves no drag armed after a release-first click", function()
        local h = ready()
        local t = assert(targetOf(h, "daily-challenge"))
        local s = assert(uiFake.stateOf(t))
        -- A one-tick click arrives backwards in the client: release, then click, no hold.
        uiFake.fire(s, h.env.ui.Hook.ONRELEASE, 8, 8)
        uiFake.fire(s, h.env.ui.Hook.ONCLICK, 8, 8)
        h:advance(100)
        -- A stray hold now starts nothing: the target stays docked.
        uiFake.fire(s, h.env.ui.Hook.ONHOLD, 8, 60)
        assert.are.equal(16, h.ui:layout(t).width)
        assert.are.same(DAILY, { table.unpack(order(h), 1, 5) })
        -- And the next press drags as usual.
        local x, y = grab(h, "daily-challenge")
        assert.is_true(h.ui:moveTo(x, y + 2 * ROW))
        assert.is_true(h.ui:release())
        assert.are.equal("player-owned-farm", stored(h)[2])
    end)
end)

describe("chore-tracker drag", function()
    it("moves the row with the pointer, opening a gap, and drops it there", function()
        local h = ready()
        local firstY = rowY(h, "daily-challenge")
        local weeklyY, oysterY = rowY(h, "soul-reaper"), rowY(h, "giant-oyster")
        local heading = h.ui:get("Title", { text = "Weekly" })
        local headingY = heading.y
        local writes = h.dbWrites
        local x, y = grab(h, "daily-challenge")
        -- The target now covers the plugin layer and is in front.
        local t = assert(uiFake.stateOf(h.ui.pressing.s.proxy))
        local parent = h.instance.uiRoot
        assert.are.same(
            { 0, 0, uiFake.width(parent), uiFake.height(parent) },
            { t.proxy.x, t.proxy.y, t.proxy.width, t.proxy.height }
        )
        assert.are.equal(t, parent.children[#parent.children])

        -- Down two rows and a bit: the row follows, the two below it close up, a gap at 3.
        assert.is_true(h.ui:moveTo(x + 30, y + 2 * ROW + 5))
        assert.are.equal(firstY + 2 * ROW + 5, rowY(h, "daily-challenge"))
        assert.are.equal(firstY, rowY(h, "player-owned-ports"))
        assert.are.equal(firstY + ROW, rowY(h, "player-owned-farm"))
        assert.are.equal(firstY + 3 * ROW, rowY(h, "crystal-tree-blossom"))
        assert.are.equal(firstY + 4 * ROW, rowY(h, "invention-machine"))
        -- Drawn over its neighbours.
        local content = assert(uiFake.stateOf(window(h).content))
        assert.are.equal(
            uiFake.stateOf(row(h, "Daily Challenge").layer),
            content.children[#content.children]
        )
        -- Other periods and the headings stay put.
        assert.are.same(
            { weeklyY, oysterY, headingY },
            { rowY(h, "soul-reaper"), rowY(h, "giant-oyster"), heading.y }
        )
        assert.are.equal(writes, h.dbWrites)

        h:advance(20)
        assert.is_true(h.ui:release())
        assert.are.equal(writes + 1, h.dbWrites)
        assert.are.same({
            "player-owned-ports",
            "player-owned-farm",
            "daily-challenge",
            "crystal-tree-blossom",
            "invention-machine",
            "soul-reaper",
            "feather-shop-run",
            "giant-oyster",
        }, stored(h))
        -- Settled in its slot, in place: same window, same rows.
        assert.are.equal(firstY + 2 * ROW, rowY(h, "daily-challenge"))
        assert.are.same({
            "player-owned-ports",
            "player-owned-farm",
            "daily-challenge",
            "crystal-tree-blossom",
            "invention-machine",
        }, { table.unpack(order(h), 1, 5) })
        assert.is_not_nil(targetOf(h, "daily-challenge"))
        assert.matches("%[CHORES%] moved daily%-challenge to 3 in daily", h:output())
    end)

    it("keeps the drag when the pointer leaves the window, and drops on release", function()
        local h = ready()
        local firstY = rowY(h, "invention-machine") - 4 * ROW
        local _, y = grab(h, "invention-machine")
        -- Far left of the window, still level with the list.
        assert.is_true(h.ui:moveTo(5, y - 3 * ROW))
        assert.are.equal(firstY + ROW, rowY(h, "invention-machine"))
        assert.is_true(h.ui:release())
        assert.are.equal("invention-machine", stored(h)[2])
    end)

    it("drops where it was when the press ends off the plugin layer", function()
        local h = ready()
        local x, y = grab(h, "daily-challenge")
        assert.is_true(h.ui:moveTo(x, y + ROW))
        local ok, why = h.ui:moveTo(-50, y + ROW)
        assert.is_false(ok)
        assert.matches("released", why)
        assert.are.equal("daily-challenge", stored(h)[2])
        assert.is_not_nil(targetOf(h, "daily-challenge"))
    end)

    it("keeps a row inside its period, and never moves it to another", function()
        local h = ready()
        local firstY = rowY(h, "daily-challenge")
        local weekly = { rowY(h, "soul-reaper"), rowY(h, "feather-shop-run") }
        local x, y = grab(h, "player-owned-ports")
        -- Far below the dailies (onto the weekly rows): it stops at the last daily slot.
        assert.is_true(h.ui:moveTo(x, y + 5 * ROW))
        assert.are.equal(firstY + 4 * ROW, rowY(h, "player-owned-ports"))
        assert.are.same(weekly, { rowY(h, "soul-reaper"), rowY(h, "feather-shop-run") })
        assert.is_true(h.ui:release())
        local s = stored(h)
        assert.are.same(
            { "daily-challenge", "player-owned-farm", "crystal-tree-blossom" },
            { s[1], s[2], s[3] }
        )
        assert.are.same({ "invention-machine", "player-owned-ports" }, { s[4], s[5] })
        assert.are.same(WEEKLY, { s[6], s[7] })

        -- And above the first slot, it stops at the first.
        x, y = grab(h, "crystal-tree-blossom")
        assert.is_true(h.ui:moveTo(x, y - 3 * ROW))
        assert.are.equal(firstY, rowY(h, "crystal-tree-blossom"))
        assert.is_true(h.ui:release())
        assert.are.equal("crystal-tree-blossom", stored(h)[1])
    end)

    it("moves nothing and saves nothing in a period of one row", function()
        local h = ready()
        local win = window(h)
        win:SetScrollPosition(1000)
        h:advance(20)
        local oysterY, writes = rowY(h, "giant-oyster"), h.dbWrites
        local x, y = grab(h, "giant-oyster")
        assert.is_true(h.ui:moveTo(x, y - 40))
        assert.are.equal(oysterY, rowY(h, "giant-oyster"))
        assert.is_true(h.ui:release())
        assert.are.equal(writes, h.dbWrites)
    end)

    it("scrolls the list while the pointer is past its bottom or top edge", function()
        local h = ready()
        local win = window(h)
        h.ui:resize(win, 0, -200)
        h:advance(20)
        local view = h.ui:layout(win.viewport)
        local bottom = view.globalY + view.height
        local x, _ = grab(h, "daily-challenge")
        assert.is_true(h.ui:moveTo(x, bottom + 20))
        -- The row stays under the pointer's spot at the edge (the grab was 8 px into the grip,
        -- 6 px down the row).
        assert.are.equal(view.height + 8 - 14, rowY(h, "daily-challenge"))
        local scrolls = { win._scroll.scrollY }
        for _ = 1, 2 do
            assert.is_true(h.ui:moveTo(x, bottom + 20))
            scrolls[#scrolls + 1] = win._scroll.scrollY
        end
        assert.are.same({ 8, 16, 24 }, scrolls)
        -- To the end of the content and no further.
        for _ = 1, 100 do
            h.ui:moveTo(x, bottom + 20)
        end
        local most = win._scroll.scrollY
        h.ui:moveTo(x, bottom + 20)
        assert.are.equal(most, win._scroll.scrollY)
        -- Inside the list it stops; above the top it scrolls back up.
        assert.is_true(h.ui:moveTo(x, bottom - 30))
        assert.are.equal(most, win._scroll.scrollY)
        assert.is_true(h.ui:moveTo(x, view.globalY - 5))
        assert.are.equal(most - 8, win._scroll.scrollY)
        assert.is_true(h.ui:release())
    end)

    it("ignores a hold sample with no number y", function()
        local h = ready()
        local x, y = grab(h, "daily-challenge")
        assert.is_true(h.ui:moveTo(x, y + ROW))
        local before = rowY(h, "daily-challenge")
        uiFake.fire(h.ui.pressing.s, h.env.ui.Hook.ONHOLD, x, nil)
        assert.are.equal(before, rowY(h, "daily-challenge"))
        assert.is_true(h.ui:release())
        assert.are.equal("daily-challenge", stored(h)[2])
    end)

    it("keeps a drag held still for as long as the holds keep coming", function()
        local h = ready()
        local writes = h.dbWrites
        local x, y = grab(h, "daily-challenge")
        assert.is_true(h.ui:moveTo(x, y + 2 * ROW))
        for _ = 1, 50 do
            h:advance(20)
            assert.is_true(h.ui:moveTo(x, y + 2 * ROW))
        end
        assert.are.equal(writes, h.dbWrites)
        assert.are.equal(uiFake.width(h.instance.uiRoot), h.ui.pressing.s.proxy.width)
        assert.is_true(h.ui:release())
        assert.are.equal("daily-challenge", stored(h)[3])
    end)

    it("drops a drag whose holds stop with no release, as a release would", function()
        local h = ready()
        local firstY = rowY(h, "daily-challenge")
        local writes = h.dbWrites
        local x, y = grab(h, "daily-challenge")
        assert.is_true(h.ui:moveTo(x, y + ROW))
        h:advance(20)
        assert.is_true(h.ui:moveTo(x, y + 2 * ROW))
        local target = h.ui.pressing.s.proxy
        -- A few ticks without a hold are still a drag.
        h:advance(100)
        assert.are.equal(uiFake.width(h.instance.uiRoot), target.width)
        assert.are.equal(writes, h.dbWrites)
        -- Then it drops at the slot shown, saves, and docks the target back over its grip.
        h:advance(300)
        assert.are.equal(writes + 1, h.dbWrites)
        assert.are.equal("daily-challenge", stored(h)[3])
        assert.are.equal(firstY + 2 * ROW, rowY(h, "daily-challenge"))
        assert.are.equal(target, targetOf(h, "daily-challenge"))
        assert.matches("%[CHORES%] moved daily%-challenge to 3 in daily", h:output())
        -- The fake still holds the button the client stopped reporting; end its press here.
        h.ui.pressing = nil
        -- The next click lands on its row again, and ticks it without moving anything.
        helpers.tick(h, "Invention Machine")
        assert.is_true(helpers.ticked(h, "Invention Machine"))
        assert.are.equal("invention-machine", stored(h)[5])
    end)
end)

describe("chore-tracker saved order", function()
    it("is per character, and comes back after a reload", function()
        local h = ready()
        seed(h, "Lynx Titan", { "player-owned-farm", "daily-challenge" })
        local x, y = grab(h, "invention-machine")
        assert.is_true(h.ui:moveTo(x, y - 4 * ROW))
        assert.is_true(h.ui:release())
        h:reload()
        h:advance(20)
        assert.are.same({ "invention-machine", "daily-challenge" }, { order(h)[1], order(h)[2] })

        h.world:logout()
        h.world:login("Lynx Titan")
        h:advance(500)
        assert.are.same({ "player-owned-farm", "daily-challenge" }, order(h))
        assert.are.equal("invention-machine", stored(h)[1])
    end)

    it("puts a newly picked chore last in its period", function()
        local h = ready()
        helpers.pick(h, { "divine-locations" })
        local list = order(h)
        assert.are.equal("Divine Locations", list[6])
        assert.are.equal("soul-reaper", list[7])
    end)
end)

describe("chore-tracker drag and other events", function()
    it("cancels the drag unsaved on a logout, with the targets rebuilt", function()
        local h = ready()
        local writes = h.dbWrites
        local x, y = grab(h, "daily-challenge")
        assert.is_true(h.ui:moveTo(x, y + 2 * ROW))
        local pressed = h.ui.pressing.s
        h.world:logout()
        -- The button stays down, so a hold comes every tick until the rebuild ends the press.
        for _ = 1, 25 do
            h:advance(20)
            if pressed.destroyed then break end
            assert.is_true(h.ui:moveTo(x, y + 2 * ROW))
        end
        assert.is_true(pressed.destroyed)
        h:advance(500)
        assert.are.equal(0, #targets(h))
        assert.are.equal(writes, h.dbWrites)
        assert.are.same(DAILY, { table.unpack(stored(h), 1, 5) })
        -- The client can send a destroyed layer nothing more; end the press here.
        h.ui.pressing = nil
        h.world:login("Zezima")
        h:advance(500)
        assert.are.same(DAILY, { table.unpack(order(h), 1, 5) })
        assert.are.equal(8, #targets(h))
    end)

    it("cancels the drag unsaved on a view switch", function()
        local h = ready()
        local writes = h.dbWrites
        local x, y = grab(h, "daily-challenge")
        assert.is_true(h.ui:moveTo(x, y + 2 * ROW))
        local pressed = h.ui.pressing.s
        assert.is_true(h.ui:click(h.ui:get("SpriteButton", { sprite = "SETTINGS" })))
        h:advance(20)
        assert.is_true(pressed.destroyed)
        assert.are.equal(0, #targets(h))
        assert.are.equal(writes, h.dbWrites)
        h.ui.pressing = nil
    end)

    it("drops the drag as a release would when the window collapses", function()
        local h = ready()
        local firstY = rowY(h, "daily-challenge")
        local writes = h.dbWrites
        local x, y = grab(h, "daily-challenge")
        assert.is_true(h.ui:moveTo(x, y + 2 * ROW))
        local target = h.ui.pressing.s.proxy
        -- In the client the stretched target covers the hamburger; the fake doesn't model that,
        -- so this is the one way a spec closes the window mid-drag.
        assert.is_true(h.ui:click(h.ui:get("SpriteButton", { sprite = "MENU", visible = true })))
        -- Docked back to grip size and hidden with the rest, so it takes no clicks.
        assert.are.same({ 16, 16 }, { target.width, target.height })
        assert.are.equal(0, #shownTargets(h))
        assert.are.equal(writes + 1, h.dbWrites)
        assert.are.equal("daily-challenge", stored(h)[3])
        assert.are.equal(firstY + 2 * ROW, rowY(h, "daily-challenge"))
        assert.matches("%[CHORES%] moved daily%-challenge to 3 in daily", h:output())
        -- The fake faults on a held press whose layer was hidden (unprobed in the client); end
        -- it here.
        h.ui.pressing = nil
        h.ui:click(h.ui:get("SpriteButton", { sprite = "MENU", visible = true }))
        h:advance(20)
        assert.are.equal(target, targetOf(h, "daily-challenge"))
        assert.are.equal("daily-challenge", stored(h)[3])
    end)

    it("keeps the drag through a clock tick, an auto tick and its popup", function()
        local h = ready()
        local firstY = rowY(h, "daily-challenge")
        local x, y = grab(h, "daily-challenge")
        assert.is_true(h.ui:moveTo(x, y + 2 * ROW))
        h.world:setVar("VarPlayer", "CLOCK_TIME_DATE_MINUTES", helpers.NOW + 1)
        h:advance(20)
        -- A purchase at the feather shop ticks Feather Shop Run and celebrates it.
        h.world:setInventory("FISHINGSHOP", { { obj = "FEATHER_PACK", count = 20 } }, 4)
        h.world:setInventory("FISHINGSHOP", { { obj = "FEATHER_PACK", count = 19 } }, 4)
        h:advance(20)
        assert.is_true(helpers.ticked(h, "Feather Shop Run"))
        assert.is_true(#h.ui:popups() > 0)
        -- The layout mid-drag isn't snapped back, and the drag goes on.
        assert.are.equal(firstY + 2 * ROW, rowY(h, "daily-challenge"))
        assert.are.equal(firstY, rowY(h, "player-owned-ports"))
        assert.is_true(h.ui:moveTo(x, y + 3 * ROW))
        assert.is_true(h.ui:release())
        assert.are.equal("daily-challenge", stored(h)[4])
        assert.is_not_nil(h.db["state:Zezima"].value.done["feather-shop-run"])
    end)

    it("destroys every plugin-layer component it made on shutdown mid-drag", function()
        local h = ready()
        local x, y = grab(h, "daily-challenge")
        assert.is_true(h.ui:moveTo(x, y + ROW))
        local writes = h.dbWrites
        h:unload()
        for _, child in ipairs(h.instance.uiRoot.children) do
            assert.is_true(child.destroyed)
        end
        -- Only the layout may be saved on the way out, not an order.
        assert.are.same(DAILY, { table.unpack(stored(h), 1, 5) })
        assert.is_true(h.dbWrites <= writes + 1)
    end)
end)
