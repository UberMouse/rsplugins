-- plugins/recorder-demo with the dev recorder: what its batches contain, when they are sent,
-- what happens while the receiver is down, and the pass-through without httpAccess.

local harness = require("tests.harness")
local paths = require("tests.harness.paths")
local support = require("tests.recorder.support")

---@param list table[]
---@param fields table
---@return table
local function one(list, fields)
    local found = support.where(list, fields)
    assert.are.equal(1, #found, "expected one entry matching the fields")
    return found[1]
end

describe("plugins/recorder-demo with the recorder", function()
    it("logs one environment probe line", function()
        local h = support.demo()
        assert.are.equal(1, support.lines(h, "[RECDEMO] probe:"))
        assert.matches(
            "_VERSION=Lua 5.4 os=true io=true .* recorder=true moduleSharesEnv=true "
                .. "moduleSeesSameEvent=true",
            h:output()
        )
        assert.matches("%[RECDEMO%] enabled 1 times", h:output())
        assert.are.equal(0, support.lines(h, "[RECORDER]"))
    end)

    it("records reads, events with their world ops, and PersistentDB", function()
        local h = support.demo()
        h.world:setVar("VarPlayer", "OPTION_RUN", 1)
        h.world:setInventory("INV", { [1] = { obj = "LOGS", count = 6 } })
        h.world:chat("hello")
        h:advance(20) -- batch 1: everything so far
        support.answer(h)
        h:advance(1200) -- batch 2, 50 ticks on: the ServerLogic at tick 30
        local entries = support.entries(h)

        assert.are.equal("Zezima", one(entries, { path = "Player.GetEntity().displayName" }).v)
        assert.are.equal(10, one(entries, { path = "var.VarPlayer.QP.value" }).v)
        assert.are.equal(
            1,
            one(entries, { path = "Inventory.Find(config.Inv.INV).usedSlotCount" }).v
        )
        local slots = one(entries, { path = "Inventory.Find(config.Inv.INV):GetSlots()" }).v
        assert.are.equal(28, #slots)
        assert.are.same({ obj = { config = "LOGS", id = 1511, type = "Obj" }, count = 6 }, slots[1])
        assert.are.same(
            { obj = { config = "UNKNOWN", id = -1, type = "Obj" }, count = 0 },
            slots[2]
        )
        assert.are.same(
            { { k = "db", op = "GetInt", key = "enables", t = 0 } },
            support.where(entries, { op = "GetInt" })
        )
        assert.are.equal(1, one(entries, { op = "SetInt" }).value)

        local transmit = one(entries, { k = "event", name = "VarTransmit" })
        assert.are.same({
            var = { config = "OPTION_RUN", id = 463, type = "VarPlayer" },
            oldValue = 0,
            newValue = 1,
        }, transmit.payload)
        assert.are.equal("setVar", transmit.op.op)
        local op = one(entries, { k = "event", name = "InventoryUpdated" }).op
        assert.are.same({ "setInventory", 93, 28 }, { op.op, op.inv, op.size })
        assert.are.equal(28, #op.slots)
        assert.are.same(
            { { obj = 1511, count = 6 }, { obj = -1, count = 0 } },
            { op.slots[1], op.slots[2] }
        )
        assert.are.equal(
            "hello",
            one(entries, { k = "event", name = "ChatMessage" }).payload.chatMessage
        )
        -- Logic deliveries aren't recorded; ServerLogic ones are, at their tick.
        assert.are.same({}, support.where(entries, { name = "Logic" }))
        assert.are.equal(30, one(entries, { name = "ServerLogic" }).t)
    end)

    it("posts only from Logic, one batch at a time", function()
        local h = support.demo()
        assert.are.equal(0, #h.requests)
        -- Events and a ServerLogic outside a logic step never post.
        h.world:setVar("VarPlayer", "OPTION_RUN", 1)
        h.world:chat("hi")
        h:fire("ServerLogic")
        assert.are.equal(0, #h.requests)

        h:step()
        assert.are.equal(1, #support.posts(h))
        h.world:setVar("VarPlayer", "OPTION_RUN", 0)
        h:advance(3000) -- due again, but the first is still in flight
        assert.are.equal(1, #support.posts(h))

        -- Answered: delivered at the start of a step, and the next batch goes from that step's
        -- Logic. (The harness fails the test if a request starts inside the callback.)
        support.answer(h)
        h:step()
        assert.are.equal(2, #support.posts(h))
        local batches = support.batches(h)
        assert.are.same({ 1, 2 }, { batches[1].seq, batches[2].seq })
        assert.are.equal(batches[1].session, batches[2].session)
        assert.are.equal("recorder-demo", batches[1].plugin)
        assert.are.equal(1, batches[1].schema)
    end)

    it(
        "drops the oldest entries while the receiver is down, says so once, and carries on",
        function()
            local h = support.demo()
            local limits = h.env.require("dev/recorder").limits
            limits.bufferBytes, limits.retryTicks = 2000, 10
            h:step() -- batch 1 goes out
            local first = support.batches(h)[1]
            support.answer(h, { error = "connection refused", errorCode = 7 })
            h:step() -- it fails: its entries are lost
            for i = 1, 40 do
                h.world:setVar("VarPlayer", "OPTION_RUN", i % 2) -- overflows the 2000-byte buffer
            end
            h:advance(400) -- the retry
            assert.are.equal(2, #support.posts(h))
            support.answer(h)
            h:step()

            local second = support.batches(h)[2]
            assert.is_true(second.dropped > #first.entries)
            assert.are.equal(0, first.dropped)
            -- What's left is the newest: the last VarTransmit (OPTION_RUN back to 0) is there.
            local events = support.where(second.entries, { k = "event", name = "VarTransmit" })
            assert.are.equal(0, events[#events].payload.newValue)
            assert.are.equal(1, support.lines(h, "[RECORDER] dropping the oldest entries"))
            assert.matches("connection refused", h:output())

            -- The plugin and the recorder carry on.
            h.world:setVar("VarPlayer", "QP", 11)
            h:advance(1200)
            local last = support.batches(h)[3]
            assert.are.equal(
                11,
                one(last.entries, { k = "event", name = "VarTransmit" }).payload.newValue
            )
            assert.are.equal(1, support.lines(h, "[RECORDER] dropping"))
        end
    )

    it("without httpAccess sends nothing until it is granted, then sends the buffer", function()
        local h = support.demo({ "chatAccess" })
        assert.are.equal(1, support.lines(h, "[RECORDER]"))
        assert.matches(
            "%[RECORDER%] waiting for httpAccess %(`ppe recorder%-demo httpAccess`%)",
            h:output()
        )
        assert.matches("%[RECDEMO%] enabled 1 times", h:output())
        h:advance(3000)
        assert.are.equal(0, #h.requests)

        h.world:grant("httpAccess")
        h:advance(1200)
        local entries = support.entries(h)
        assert.are.equal(1, #support.posts(h))
        -- Startup reads from before the grant are in the first batch.
        assert.are.equal(0, one(entries, { path = "Player.GetEntity().displayName" }).t)
    end)

    it("runs without dev/", function()
        local files = {}
        for _, name in ipairs({ "main.lua", "envprobe.lua", "plugin.json" }) do
            files[name] = paths.read(paths.repo("plugins/recorder-demo/" .. name))
        end
        local h =
            harness.new(files, { grant = { "httpAccess" }, stdlib = { os = true, io = true } })
        h.world:login("Zezima")
        h.world:setVar("VarPlayer", "QP", 10)
        h.world:setVar("VarPlayer", "OPTION_RUN", 0)
        h.world:setVar("VarPlayer", "CLOCK_TIME_DATE_MINUTES", 5)
        h:load()
        h:advance(7000)
        assert.matches("recorder=false", h:output())
        assert.are.equal(0, #h.requests)
    end)
end)
