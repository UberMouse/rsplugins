-- plugins/recorder-demo replaying tests/fixtures/recorder-demo-shop.jsonl: about a minute of a
-- real beta-client session (recording 20261025-144642-8f7250b863, ticks 17250..20430),
-- sanitised by scripts/recording-sanitise.py. In it the player pickpockets into the money
-- pouch, finds Horseclan confections, gets a public chat line (redacted) and buys a shop line
-- out. The demo must answer every read from it, and the world must end as the client's did.

local harness = require("tests.harness")
local support = require("tests.recorder.support")

local ChatType = harness.enums.ChatType
local FIXTURE = "tests/fixtures/recorder-demo-shop.jsonl"

---@return table h
local function replayed()
    local h = harness.new(
        support.demoFiles(),
        { grant = { "chatAccess" }, stdlib = { os = true, io = true } }
    )
    h:useRecording(FIXTURE)
    h:load()
    h:playRecording()
    return h
end

---@param slots table a world inventory's slots
---@param i integer
---@return table?
local function slot(slots, i)
    return slots[i] and { slots[i].obj, slots[i].count }
end

describe("plugins/recorder-demo replaying a sanitised client session", function()
    it("runs to the end, with every read answered", function()
        local h = replayed()
        assert.are.equal(3176, h.tick) -- the last entry's tick
        -- The session stored enables = 1 before the window; the fixture carries that in as a
        -- GetInt at t = 0, so the replay is the demo's second enable.
        assert.matches("%[RECDEMO%] enabled 2 times", h:output())
        assert.are.same(
            { enables = { type = harness.enums.PersistentDBType.INT, value = 2 } },
            h.db
        )
        -- The two vars the catalog doesn't have yet (newer than docs/vars/vars.csv).
        local skipped = {}
        for _, s in ipairs(h.replay.skipped) do
            skipped[#skipped + 1] = s.t .. " " .. s.why
        end
        assert.are.same({
            "1677 var HALLOWEEN26_PERM_1 is not in docs/vars/vars.csv",
            "1677 var HALLOWEEN26_PERM_2 is not in docs/vars/vars.csv",
        }, skipped)
    end)

    it(
        "ends with the client's inventories: backpack, money pouch and a sold-out shop line",
        function()
            local invs = replayed().world.state.invs
            -- The backpack: four items, then ten tinderboxes (obj 590) bought into slots 7-16.
            assert.are.same({ 315, 1 }, slot(invs[93].slots, 1))
            assert.are.same({ 590, 1 }, slot(invs[93].slots, 16))
            assert.is_nil(slot(invs[93].slots, 17))
            -- MONEY_POUCH: 12 coins pickpocketed, 10 spent.
            assert.are.same({ 995, 2 }, slot(invs[623].slots, 1))
            -- GENERALSHOP1 slot 7: the tinderbox line, bought out, stays as obj 590 x0.
            assert.are.same({ 590, 0 }, slot(invs[3].slots, 7))
            assert.are.equal(40, invs[3].size)
            -- GENERALSHOP1_FREEBIES slot 4, also x0.
            assert.are.same({ 25692, 0 }, slot(invs[553].slots, 4))
        end
    )

    it("delivers the game chat, and the player's chat only redacted", function()
        local h = replayed()
        local byType = {}
        for _, line in ipairs(h.chatLog) do
            byType[line.chatType] = byType[line.chatType] or {}
            table.insert(byType[line.chatType], line.message)
        end
        assert.are.same({ "<redacted>" }, byType[ChatType.PUBLIC])
        assert.are.equal("<redacted>", h.chatLog[1].sender)
        assert.matches("Horseclan confections", byType[ChatType.GENERAL][1])
        assert.matches("pickpocket target becomes aware", byType[ChatType.GENERAL][2])
        assert.are.equal("You pick the target's pocket.", byType[ChatType.SPAM][2])
        assert.are.equal(
            "10 coins have been removed from your money pouch.",
            byType[ChatType.SPAM][#byType[ChatType.SPAM]]
        )
    end)

    it("keeps the wall clock: CLOCK_TIME_DATE_MINUTES is minutes since the Unix epoch", function()
        local h = replayed()
        -- 29881550 minutes = 2026-10-25 01:50 UTC, the minute of the session's chat timestamps.
        assert.are.equal(29881550, h.world.state.vars.VarPlayer[11489])
        assert.are.equal("Fixture Player", h.world.state.player.displayName)
    end)

    -- The demo keeps its re-read state to itself, so the asserts only read back what the test set:
    -- the point is that advance() after playRecording() doesn't fault.
    it("keeps running without a fault when a test advances past the recording's end", function()
        local h = replayed()
        h.world:setInventory("MONEY_POUCH", { { obj = "COINS", count = 5 } })
        assert.are.same({ 995, 5 }, slot(h.world.state.invs[623].slots, 1))
        h.world:setVar("VarPlayer", "CLOCK_TIME_DATE_MINUTES", 29881551)
        h:advance(600) -- 30 ticks on the harness's own clock: the demo handles them
        assert.are.equal(29881551, h.world.state.vars.VarPlayer[11489])
    end)
end)
