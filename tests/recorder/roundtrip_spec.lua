-- Round trip: plugins/recorder-demo recorded by the dev recorder in a scripted harness world,
-- then that recording replayed into a fresh harness without the recorder. The replayed plugin
-- must answer every read from the recording (an unanswerable one fails the test) and end in
-- the same observable state: console lines, chat window and PersistentDB.

local harness = require("tests.harness")
local paths = require("tests.harness.paths")
local support = require("tests.recorder.support")

local ChatType = harness.enums.ChatType

-- The demo's console lines, without the probe line: that one names the recorder and prints
-- os.clock(), so it differs between any two runs.
---@param h table
---@return string[]
local function demoLines(h)
    local out = {}
    for line in h:output():gmatch("[^\n]+") do
        if not line:find("[RECDEMO] probe:", 1, true) then out[#out + 1] = line end
    end
    return out
end

describe("plugins/recorder-demo round trip", function()
    it("replayed without the recorder, reaches the state it reached recorded", function()
        -- Recorded: an enable with a stored counter, then a few minutes of world changes.
        local recorded = harness.new("recorder-demo", {
            grant = { "httpAccess", "chatAccess" },
            stdlib = { os = true, io = true },
        })
        recorded.db.enables = { type = harness.enums.PersistentDBType.INT, value = 4 }
        recorded.world:setVar("VarPlayer", "QP", 10)
        recorded.world:setVar("VarPlayer", "OPTION_RUN", 0)
        recorded.world:setVar("VarPlayer", "CLOCK_TIME_DATE_MINUTES", 29881543)
        recorded.world:login("Zezima")
        recorded.world:setInventory("INV", { [1] = { obj = "LOGS", count = 5 } }, 28)
        recorded:load()
        recorded.world:setVar("VarPlayer", "OPTION_RUN", 1)
        recorded:advance(3000)
        recorded.world:setInventory(
            "INV",
            { { obj = "LOGS", count = 5 }, { obj = "COINS", count = 3 } }
        )
        recorded.world:chat("You pick the target's pocket.", { chatType = ChatType.SPAM })
        recorded.world:chat("hello", { chatType = ChatType.PUBLIC, sender = "Bob" })
        recorded:advance(4000) -- past the demo's re-read every 10 server ticks
        recorded.world:setVar("VarPlayer", "CLOCK_TIME_DATE_MINUTES", 29881544)
        recorded.world:setInventory("INV", { { obj = "LOGS", count = 4 } })
        recorded:advance(2000)
        for _ = 1, 3 do -- send what's buffered
            support.answer(recorded)
            recorded:advance(1200)
        end
        local entries = support.entries(recorded)

        -- Replayed: the same plugin without dev/, in a world the recording alone describes.
        local files = {}
        for _, name in ipairs({ "main.lua", "envprobe.lua", "plugin.json" }) do
            files[name] = paths.read(paths.repo("plugins/recorder-demo/" .. name))
        end
        local replayed =
            harness.new(files, { grant = { "chatAccess" }, stdlib = { os = true, io = true } })
        replayed:useRecording(entries)
        replayed:load()
        replayed:playRecording()

        assert.are.same({ "[RECDEMO] enabled 5 times" }, demoLines(recorded))
        assert.are.same(demoLines(recorded), demoLines(replayed))
        assert.matches("recorder=false", replayed:output())
        assert.are.same(recorded.db, replayed.db)
        assert.are.same(recorded.chatLog, replayed.chatLog)
        -- The world the plugin read, rebuilt from its reads and the recorded events: logged in
        -- under the same name, with the vars and backpack it saw.
        local function seen(h)
            local state = h.world.state
            return {
                player = { state.player.loggedIn, state.player.displayName },
                vars = state.vars,
                backpack = state.invs[93].slots,
            }
        end
        assert.are.same(seen(recorded), seen(replayed))
        assert.are.same({}, replayed.replay.skipped)
    end)
end)
