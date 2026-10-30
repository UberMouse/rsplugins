-- The Chore Tracker's celebration popups through the harness: when they show, the queue,
-- the two settings, and what logout and shutdown do to a popup on screen.

local helpers = require("tests.chore-tracker.helpers")
local loaded, pick, tick = helpers.loaded, helpers.pick, helpers.tick

local BERT = { name = "Sand from Bert", id = "bert-sand", flag = "HANDSAND_BUCKETS_CLAIMED_TODAY" }
local GEOFF =
    { name = "Flax from Geoffrey", id = "geoffrey-flax", flag = "ATSEER_REWARD_FLAX_GIVEN_TODAY" }
local ARCH_INFO_POPUP, LEAGUE2_HARD_TASK_COMPLETE = 48145, 60041

-- A popup lasts 200 Logic ticks and ends on the next one (20 ms each), and the plugin's login
-- poll runs every 25.
local POPUP_MS = 4020
local POLL_MS = 500
local SETTLE_MS = 10000

-- A loaded harness past the settle window that follows a load, where var ticks start.
---@param opts table?
---@return table
local function settled(opts)
    local h = loaded(opts)
    h:advance(SETTLE_MS)
    return h
end

---@param h table
---@param flag string
local function claim(h, flag)
    h.world:setVar("VarPlayer", flag, 1)
end

---@param h table
---@return string[] # oldest first
local function titles(h)
    local out = {}
    for i, p in ipairs(h.ui:popups()) do
        out[i] = p.title
    end
    return out
end

-- How many popups are on screen.
---@param h table
---@return integer
local function showing(h)
    local n = 0
    for _, p in ipairs(h.ui:popups()) do
        if not p.destroyed then n = n + 1 end
    end
    return n
end

-- Toggle one of the celebration settings in the settings view and come back to the list.
---@param h table
---@param setting string
local function toggle(h, setting)
    helpers.openSettings(h)
    assert(h.ui:click(helpers.group(h, setting), setting))
    assert(h.ui:click(h.ui:get("SpriteButton", { sprite = "BACK" })))
    h:advance(20)
end

describe("chore-tracker popups", function()
    it("celebrates a picked chore it ticked, top-middle, with the chore popup's jingle", function()
        local h = settled()
        pick(h, { BERT.id, GEOFF.id })
        claim(h, BERT.flag)
        local popups = h.ui:popups()
        assert.are.equal(1, #popups)
        local p = popups[1]
        assert.are.equal("CHORE COMPLETE", p.title)
        assert.are.equal("Sand from Bert", p.text)
        assert.are.equal(ARCH_INFO_POPUP, p.played)
        assert.is_true(p.sound ~= false)
        assert.are.equal(ARCH_INFO_POPUP, p.soundID)
        -- In the plugin layer, centred across it, its centre a third of the way down.
        local layer =
            h.env.ui.Interfaces:GetComponent(h.env.id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
        assert.are.equal(layer, p.parent)
        assert.are.equal(3836 / 2 - 150, p.root.x)
        assert.are.equal(math.floor(2121 / 3 - 46 + 0.5), p.root.y)
        assert.matches("%[CHORES%] celebrate bert%-sand", h:output())
    end)

    it("never celebrates a hand tick of a single chore", function()
        local h = settled()
        pick(h, { BERT.id, GEOFF.id })
        tick(h, BERT.name)
        assert.are.same({}, titles(h))
        tick(h, BERT.name) -- unticking
        assert.are.same({}, titles(h))
    end)

    it("never celebrates a chore that isn't picked", function()
        local h = settled()
        pick(h, { BERT.id })
        claim(h, GEOFF.flag)
        assert.are.same({}, titles(h))
    end)

    it("never celebrates a chore already done this period", function()
        local h = settled()
        pick(h, { BERT.id, GEOFF.id })
        tick(h, BERT.name)
        claim(h, BERT.flag)
        assert.are.same({}, titles(h))
    end)

    it("celebrates the last picked chore of a period, by hand or by itself", function()
        local h = settled()
        pick(h, { BERT.id, GEOFF.id })
        tick(h, BERT.name)
        tick(h, GEOFF.name)
        assert.are.same({ "WEEKLIES COMPLETE" }, titles(h))
        local p = h.ui:popups()[1]
        assert.matches("All 2 of your weekly chores done", p.text)
        assert.are.equal(LEAGUE2_HARD_TASK_COMPLETE, p.played)
        assert.is_true(p.width > 300 and p.height > 92)
        assert.matches("%[CHORES%] celebrate weekly cleared", h:output())

        local h2 = settled()
        pick(h2, { BERT.id, GEOFF.id })
        tick(h2, BERT.name)
        claim(h2, GEOFF.flag)
        -- The chore popup shows first; the period's follows it.
        assert.are.same({ "CHORE COMPLETE" }, titles(h2))
        h2:advance(POPUP_MS)
        assert.are.same({ "CHORE COMPLETE", "WEEKLIES COMPLETE" }, titles(h2))
    end)

    it("titles a cleared day as the dailies", function()
        local h = settled()
        pick(h, { "daily-challenge" })
        tick(h, "Daily Challenge")
        assert.are.same({ "DAILIES COMPLETE" }, titles(h))
        assert.matches("All 1 of your daily chore done", h.ui:popups()[1].text)
    end)

    it("celebrates a re-tick of the last chore again", function()
        local h = settled()
        pick(h, { BERT.id })
        tick(h, BERT.name)
        assert.are.equal(1, #h.ui:popups())
        h:advance(POPUP_MS)
        tick(h, BERT.name) -- unticks
        assert.are.equal(1, #h.ui:popups())
        tick(h, BERT.name)
        assert.are.equal(2, #h.ui:popups())
    end)

    it("shows one at a time, first in first out, each ending on its own", function()
        local h = settled()
        pick(h, { BERT.id, GEOFF.id })
        claim(h, BERT.flag)
        claim(h, GEOFF.flag)
        -- Bert's chore, Geoffrey's chore, then the period they clear.
        assert.are.equal(1, showing(h))
        assert.are.same({ "CHORE COMPLETE" }, titles(h))
        assert.are.equal("Sand from Bert", h.ui:popups()[1].text)
        h:advance(POPUP_MS)
        assert.are.equal("Flax from Geoffrey", h.ui:popups()[2].text)
        assert.are.equal(1, showing(h))
        assert.is_true(h.ui:popups()[1].completed)
        h:advance(POPUP_MS)
        assert.are.same({ "CHORE COMPLETE", "CHORE COMPLETE", "WEEKLIES COMPLETE" }, titles(h))
        h:advance(POPUP_MS)
        assert.are.equal(0, showing(h))
    end)

    it("shows whatever the window is doing", function()
        local h = settled()
        pick(h, { BERT.id, GEOFF.id })
        local menu = { sprite = "MENU", visible = true }
        assert.is_true(h.ui:click(h.ui:get("SpriteButton", menu))) -- collapse
        claim(h, BERT.flag)
        assert.are.equal(1, showing(h))
        h:advance(POPUP_MS)
        assert.is_true(h.ui:click(h.ui:get("SpriteButton", menu))) -- expand
        h:advance(20)
        helpers.openSettings(h)
        claim(h, GEOFF.flag)
        assert.are.equal(2, #h.ui:popups())
    end)

    it("never celebrates picking or unpicking chores", function()
        local h = settled()
        pick(h, { BERT.id, GEOFF.id })
        tick(h, BERT.name)
        -- Unpicking the undone chore leaves the period all done; picking brings it back.
        pick(h, { GEOFF.id })
        pick(h, { GEOFF.id })
        assert.are.same({}, titles(h))
    end)

    it("never celebrates a load, or stored state that is already all done", function()
        local h = settled()
        pick(h, { BERT.id })
        tick(h, BERT.name)
        h:advance(POPUP_MS)
        h:reload()
        h:advance(SETTLE_MS)
        assert.are.same({}, titles(h))
        h.world:login("Lynx Titan")
        h:advance(POLL_MS)
        h.world:login("Zezima")
        h:advance(POLL_MS)
        assert.are.same({}, titles(h))
    end)

    it("clears the queue and the popup on screen at logout and a character switch", function()
        local h = settled()
        pick(h, { BERT.id, GEOFF.id })
        claim(h, BERT.flag)
        claim(h, GEOFF.flag)
        local first = h.ui:popups()[1]
        h.world:logout()
        h:advance(POLL_MS)
        assert.is_true(first.destroyed)
        h:advance(POPUP_MS * 3)
        assert.are.equal(1, #h.ui:popups())

        h.world:login("Zezima")
        h:advance(POLL_MS)
        h:advance(SETTLE_MS)
        local n = #h.ui:popups()
        pick(h, { "coeden-logs" })
        claim(h, "ATELF_DAILY_LOGS_CLAIMED")
        local second = h.ui:popups()[n + 1]
        assert.is_not_nil(second)
        h.world:login("Lynx Titan")
        h:advance(POLL_MS)
        assert.is_true(second.destroyed)
        assert.are.equal(n + 1, #h.ui:popups())
    end)

    it("destroys the popup and its Logic subscription at shutdown", function()
        local h = settled()
        pick(h, { BERT.id, GEOFF.id })
        claim(h, BERT.flag)
        claim(h, GEOFF.flag)
        local function popupSubs()
            local n = 0
            for _, sub in ipairs(h.instance.subs.Logic) do
                if sub.name:find("^prettyui_achievement_popup_") then n = n + 1 end
            end
            return n
        end
        assert.are.equal(1, popupSubs())
        local popups = h.ui:popups()
        h:unload()
        assert.are.equal(1, #popups)
        assert.is_true(popups[1].destroyed) -- and unload found no popup subscription left
    end)

    it("skips a popup PrettyUI can't show, and the queue moves on", function()
        local h = settled()
        local COEDEN =
            { name = "Logs from Coeden", id = "coeden-logs", flag = "ATELF_DAILY_LOGS_CLAIMED" }
        pick(h, { BERT.id, GEOFF.id, COEDEN.id })
        claim(h, BERT.flag)
        claim(h, GEOFF.flag)
        claim(h, COEDEN.flag)
        -- Bert's is showing; Geoffrey's, Coeden's and the period's wait behind it.
        h.ui:popupsFail(true)
        h:advance(POPUP_MS)
        assert.are.equal(1, #h.ui:popups())
        assert.are.equal(0, showing(h))
        -- Nothing is stuck: the next celebration shows.
        h.ui:popupsFail(false)
        tick(h, COEDEN.name) -- unticks
        tick(h, COEDEN.name)
        assert.are.same({ "CHORE COMPLETE", "WEEKLIES COMPLETE" }, titles(h))
        assert.are.equal(1, showing(h))
    end)

    describe("settings", function()
        it("lists Celebrations above the chores, both on by default", function()
            local h = loaded()
            helpers.openSettings(h)
            h.ui:get("Title", { text = "Celebrations" })
            assert.is_true(helpers.picked(h, "popups"))
            assert.is_true(helpers.picked(h, "sound"))
            local texts = {}
            for _, choice in ipairs(h.ui:choices(helpers.group(h, "popups"))) do
                texts[#texts + 1] = choice.text
            end
            assert.are.same({ "Celebration popups", "Popup sound" }, texts)
        end)

        it("turning popups off destroys the showing popup and the queue, and saves it", function()
            local h = settled()
            pick(h, { BERT.id, GEOFF.id })
            claim(h, BERT.flag)
            claim(h, GEOFF.flag)
            local first = h.ui:popups()[1]
            toggle(h, "popups")
            assert.is_true(first.destroyed)
            h:advance(POPUP_MS * 3)
            assert.are.equal(1, #h.ui:popups())
            assert.is_false(h.db.celebrations.value.popups)
            assert.is_true(h.db.celebrations.value.sound)

            -- Nothing shows while off, and it stays off after a reload.
            h:reload()
            h:advance(SETTLE_MS)
            tick(h, BERT.name)
            tick(h, GEOFF.name)
            assert.are.same({}, titles(h))
            toggle(h, "popups")
            helpers.openSettings(h)
            assert.is_true(helpers.picked(h, "popups"))
        end)

        it("turning sound off shows popups without a sound, and saves it", function()
            local h = settled()
            pick(h, { BERT.id, GEOFF.id })
            toggle(h, "sound")
            assert.is_false(h.db.celebrations.value.sound)
            claim(h, BERT.flag)
            local p = h.ui:popups()[1]
            assert.are.equal(false, p.sound)
            assert.is_nil(p.played)
        end)

        it("falls back to the defaults for a malformed stored value", function()
            local h = loaded({ load = false })
            h.db.celebrations = {
                type = require("tests.harness").enums.PersistentDBType.STRUCTURED_DATA,
                value = { version = 1, popups = "no" },
            }
            h:load()
            helpers.openSettings(h)
            assert.is_true(helpers.picked(h, "popups"))
        end)
    end)
end)
