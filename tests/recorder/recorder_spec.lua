-- The dev recorder's stand-ins (lib/dev/recorder.lua), with small inline plugins: how reads
-- are named and deduplicated, events, PersistentDB, permission checks, the plugin's own HTTP
-- requests, and the pass-through cases.

local harness = require("tests.harness")
local support = require("tests.recorder.support")

describe("dev recorder", function()
    it("names a config the same however it was reached, and keeps stand-ins comparable", function()
        local h = harness.new(
            support.plugin(support.INSTALL .. [[
            local byId = var.VarPlayer.FromID(463)
            sameStandIn = rawequal(byId, var.VarPlayer.OPTION_RUN)
            local value = byId.value
            Event.VarTransmit.Subscribe("a", function(ev)
                matched = ev.var == var.VarPlayer.OPTION_RUN
                local v = ev.var.value
            end)
        ]]),
            { grant = { "httpAccess" } }
        )
        h.world:setVar("VarPlayer", "OPTION_RUN", 0)
        h:load()
        h.world:setVar("VarPlayer", "OPTION_RUN", 1)
        h:step()
        local entries = support.entries(h)

        assert.is_true(h.env.sameStandIn)
        assert.is_true(h.env.matched)
        assert.are.same(
            { config = "OPTION_RUN", id = 463, type = "VarPlayer" },
            support.where(entries, { path = "var.VarPlayer.FromID(463)" })[1].v
        )
        local reads = support.where(entries, { path = "var.VarPlayer.OPTION_RUN.value" })
        assert.are.same({ 0, 1 }, { reads[1].v, reads[2].v })
    end)

    it("records a read again only when its value changes", function()
        local h = harness.new(
            support.plugin(support.INSTALL .. [[
            Event.Logic.Subscribe("poll", function() local qp = var.VarPlayer.QP.value end)
        ]]),
            { grant = { "httpAccess" } }
        )
        h.world:setVar("VarPlayer", "QP", 10)
        h:load()
        h:advance(400) -- 20 reads
        h.world:setVar("VarPlayer", "QP", 11)
        h:advance(1200) -- the next batch is due 50 ticks after the first
        support.answer(h)
        h:advance(1200)
        local reads = support.where(support.entries(h), { path = "var.VarPlayer.QP.value" })
        assert.are.equal(2, #reads)
        assert.are.same({ 10, 11 }, { reads[1].v, reads[2].v })
        assert.is_true(reads[2].t > reads[1].t)
    end)

    it("records a read again after its entry is dropped, and only then", function()
        local h = harness.new(
            support.plugin(support.INSTALL .. [[
            Event.Logic.Subscribe("poll", function() local qp = var.VarPlayer.QP.value end)
            Event.VarTransmit.Subscribe("filler", function() end)
        ]]),
            { grant = {} } -- nothing is sent, so only the buffer limit drops entries
        )
        h.world:setVar("VarPlayer", "QP", 10)
        h.world:setVar("VarPlayer", "OPTION_RUN", 0)
        h:load()
        h.env.require("dev/recorder").limits.bufferBytes = 2000
        h:step() -- tick 1: QP recorded
        for i = 1, 20 do
            h.world:setVar("VarPlayer", "OPTION_RUN", i % 2) -- pushes the tick 1 read out
        end
        h:step() -- tick 2: QP recorded again
        h.world:setVar("VarPlayer", "OPTION_RUN", 1)
        h.world:setVar("VarPlayer", "OPTION_RUN", 0) -- drops older entries, not the tick 2 read
        h:step() -- tick 3: QP unchanged and its entry still there, so not recorded
        h.world:grant("httpAccess")
        h:advance(1200)

        local batch = support.batches(h)[1]
        assert.is_true(batch.dropped > 0)
        local reads = support.where(batch.entries, { path = "var.VarPlayer.QP.value" })
        assert.are.same({ { k = "read", path = "var.VarPlayer.QP.value", v = 10, t = 2 } }, reads)
    end)

    it("deduplicates reads of objects handed out fresh on each call", function()
        -- Stands in for the client's Inventory, whose Find returns a new userdata per call,
        -- each with its own address in its tostring() text.
        local fakeInventory = [[
            local made = 0
            Inventory = { Find = function()
                made = made + 1
                return setmetatable({}, { __tostring = function()
                    return string.format("sol.jag::InventoryProxy: 0x%x", 0x591cbdbce258 + made)
                end })
            end }
        ]]
        local h = harness.new(
            support.plugin(fakeInventory .. support.INSTALL .. [[
            for _ = 1, 3 do local inv = Inventory.Find(config.Inv.INV) end
        ]]),
            { grant = { "httpAccess" } }
        )
        h:load()
        h:step()
        assert.are.same({
            {
                k = "read",
                path = "Inventory.Find(config.Inv.INV)",
                v = "sol.jag::InventoryProxy",
                t = 0,
            },
        }, support.where(support.entries(h), { path = "Inventory.Find(config.Inv.INV)" }))
    end)

    it("records each delivery once, whatever the number of subscribers", function()
        local h = harness.new(
            support.plugin(support.INSTALL .. [[
            calls = { a = 0, b = 0 }
            Event.VarTransmit.Subscribe("a", function() calls.a = calls.a + 1 end)
            Event.VarTransmit.Subscribe("b", function() calls.b = calls.b + 1 end)
            Event.VarTransmit.Unsubscribe("a")
        ]]),
            { grant = { "httpAccess" } }
        )
        h.world:setVar("VarPlayer", "QP", 10)
        h:load()
        h.world:setVar("VarPlayer", "QP", 11)
        h.world:setVar("VarPlayer", "QP", 12)
        h:step()
        assert.are.same({ a = 0, b = 2 }, h.env.calls)
        local events = support.where(support.entries(h), { k = "event", name = "VarTransmit" })
        assert.are.equal(2, #events)
        assert.are.same(
            { op = "setVar", domain = "VarPlayer", name = "QP", id = 1297, value = 12 },
            events[2].op
        )
    end)

    it("records every slot of an inventory, empty ones as obj -1 x0", function()
        local h = harness.new(
            support.plugin(support.INSTALL .. [[
            local slots = Inventory.Find(config.Inv.INV):GetSlots()
            Event.InventoryUpdated.Subscribe("inv", function() end)
        ]]),
            { grant = { "httpAccess" } }
        )
        local slots = {}
        for _, i in ipairs({ 1, 2, 4 }) do
            slots[i] = { obj = "LOGS", count = i }
        end
        h.world:setInventory("INV", slots, 5)
        h:load()
        slots[4].count = 40
        h.world:setInventory("INV", slots)
        h:step()
        local entries = support.entries(h)

        local logs = { config = "LOGS", id = 1511, type = "Obj" }
        local empty = { obj = { config = "UNKNOWN", id = -1, type = "Obj" }, count = 0 }
        assert.are.same({
            { obj = logs, count = 1 },
            { obj = logs, count = 2 },
            empty,
            { obj = logs, count = 4 },
            empty,
        }, support.where(entries, { path = "Inventory.Find(config.Inv.INV):GetSlots()" })[1].v)
        local event = support.where(entries, { k = "event", name = "InventoryUpdated" })[1]
        assert.are.same({
            { obj = 1511, count = 1 },
            { obj = 1511, count = 2 },
            { obj = -1, count = 0 },
            { obj = 1511, count = 40 },
            { obj = -1, count = 0 },
        }, event.op.slots)
    end)

    it("passes subscriber edits and return values through", function()
        local h = harness.new(
            support.plugin(
                support.INSTALL
                    .. [[
            Event.ChatMessage.Subscribe("shout", function(ev) ev.chatMessage = ev.chatMessage:upper() end)
        ]],
                [[{ "name": "T", "version": "0.0.1", "contactEmailAddress": "t@example.com",
                    "optionalPermissions": [ "httpAccess", "chatAccess" ],
                    "urls": { "recorder": "http://127.0.0.1:8766" } }]]
            ),
            { grant = { "httpAccess", "chatAccess" } }
        )
        h:load()
        h.world:chat("hello", { sender = "Bob" })
        h:step()
        assert.are.equal("HELLO", h.chatLog[1].message)
        local event = support.where(support.entries(h), { k = "event", name = "ChatMessage" })[1]
        -- Recorded as delivered, before any subscriber's edit.
        assert.are.equal("hello", event.payload.chatMessage)
        assert.are.same({ op = "chat", message = "hello", chatType = 0, sender = "Bob" }, event.op)
    end)

    it("records PersistentDB calls and permission checks", function()
        local h = harness.new(
            support.plugin(support.INSTALL .. [[
            local n = PersistentDB:Get("n")
            PersistentDB:Set("n", { count = 1, tags = { "a" } })
            for _ = 1, 3 do granted = Plugin.HasPermission(PluginPermissions.httpAccess) end
        ]]),
            { grant = { "httpAccess" } }
        )
        h:load()
        h:step()
        local entries = support.entries(h)
        assert.are.same(
            { k = "db", op = "Get", key = "n", t = 0 },
            support.where(entries, { op = "Get" })[1]
        )
        assert.are.same({
            k = "db",
            op = "Set",
            key = "n",
            value = { count = 1, tags = { "a" } },
            v = true,
            t = 0,
        }, support.where(entries, { op = "Set" })[1])
        -- Checked three times, recorded once: the answer didn't change.
        assert.are.same(
            { { k = "perm", permission = "httpAccess", v = true, t = 0 } },
            support.where(entries, { k = "perm" })
        )
    end)

    it("records a stored false as the value false", function()
        local h = harness.new(
            support.plugin(support.INSTALL .. 'PersistentDB:SetBool("on", false)'),
            { grant = { "httpAccess" } }
        )
        h:load()
        h:step()
        assert.are.same(
            { { k = "db", op = "SetBool", key = "on", value = false, v = true, t = 0 } },
            support.where(support.entries(h), { k = "db" })
        )
    end)

    it("still sends what it recorded before an internal error, and nothing after", function()
        -- An Inventory whose objects raise from tostring(), so recording a Find fails.
        local faultyInventory = [[
            Inventory = { Find = function()
                return setmetatable({}, { __tostring = function() error("boom") end })
            end }
        ]]
        local h = harness.new(
            support.plugin(faultyInventory .. support.INSTALL .. [[
            local qp = var.VarPlayer.QP.value
            local inv = Inventory.Find(1)
            Event.Logic.Subscribe("poll", function() local run = var.VarPlayer.OPTION_RUN.value end)
        ]]),
            { grant = { "httpAccess" } }
        )
        h.world:setVar("VarPlayer", "QP", 10)
        h.world:setVar("VarPlayer", "OPTION_RUN", 0)
        h:load()
        h:advance(2000)
        local entries = support.entries(h)
        assert.are.equal(1, #support.where(entries, { path = "var.VarPlayer.QP.value" }))
        assert.are.equal(0, #support.where(entries, { path = "var.VarPlayer.OPTION_RUN.value" }))
        assert.are.equal(1, support.lines(h, "[RECORDER] recording stopped after an error"))
    end)

    it("stops sending, once, when building a batch fails", function()
        local h = harness.new(
            support.plugin(
                support.INSTALL
                    .. "local qp = var.VarPlayer.QP.value\n"
                    .. "local run = var.VarPlayer.OPTION_RUN.value"
            ),
            { grant = { "httpAccess" } }
        )
        h.world:setVar("VarPlayer", "QP", 10)
        h.world:setVar("VarPlayer", "OPTION_RUN", 0)
        h:load()
        -- Comparing a number with a string raises in the batch builder, not in starting a request.
        h.env.require("dev/recorder").limits.batchBytes = "many"
        h:advance(2000)
        assert.are.equal(0, #h.requests)
        assert.are.equal(
            1,
            support.lines(h, "[RECORDER] recording and sending stopped after an error")
        )
    end)

    -- A plugin whose HTTPRequest.new raises while `failStart` is set, as the client may refuse
    -- a request.
    local FAILING_NEW = [[
        local real = HTTPRequest
        HTTPRequest = setmetatable({ new = function(...)
            if failStart then error("no requests") end
            return real.new(...)
        end }, { __index = real })
    ]]

    it("drops a batch whose request fails to start, and keeps sending", function()
        local h = harness.new(
            support.plugin(
                FAILING_NEW
                    .. support.INSTALL
                    .. 'Event.Logic.Subscribe("read", function() local _ = var.VarPlayer.QP.value end)'
            ),
            { grant = { "httpAccess" } }
        )
        h.world:setVar("VarPlayer", "QP", 10)
        h:load()
        h.env.failStart = true
        h:advance(100)
        assert.are.equal(0, #h.requests)
        assert.are.equal(1, support.lines(h, "[RECORDER] dropping the oldest entries"))
        assert.matches("starting the request failed", h:output())
        assert.is_nil(h:output():find("sending stopped", 1, true))

        -- The next batch is still sent once the retry wait is over, and counts what was lost.
        h.env.failStart = false
        h.world:setVar("VarPlayer", "QP", 11)
        h:advance(6000)
        local batches = support.batches(h)
        assert.are.equal(1, #batches)
        assert.is_true(batches[1].dropped > 0)
        assert.are.equal(1, support.lines(h, "[RECORDER] dropping"))
    end)

    it("ignores a batch completing after shutdown, and cancels the request in flight", function()
        local h = harness.new(
            support.plugin(support.INSTALL .. "local qp = var.VarPlayer.QP.value"),
            { grant = { "httpAccess" } }
        )
        h.world:setVar("VarPlayer", "QP", 10)
        h:load()
        h:step()
        local posts = support.posts(h)
        assert.are.equal(1, #posts)
        local recorder = h.env.require("dev/recorder")
        recorder.shutdown()
        assert.are.same({}, h.instance.subs.Logic)
        assert.is_true(posts[1].request.cancelled)

        -- Later ticks send nothing and log nothing (no drop, no fault).
        h:advance(3000)
        assert.are.equal(1, #support.posts(h))
        assert.are.equal(0, support.lines(h, "[RECORDER]"))
        recorder.shutdown() -- twice is fine
    end)

    it("shuts down as a no-op without urls.recorder", function()
        local h = harness.new(
            support.plugin(
                support.INSTALL .. "require('dev/recorder').shutdown()",
                '{ "name": "T", "version": "0.0.1", "contactEmailAddress": "t@example.com", '
                    .. '"optionalPermissions": [ "httpAccess" ] }'
            ),
            { grant = { "httpAccess" } }
        )
        h:load()
        assert.are.equal(1, support.lines(h, "[RECORDER] no urls.recorder"))
        h:unload()
    end)

    it("records the plugin's own HTTP requests, but not its batches", function()
        local h = harness.new(
            support.plugin(support.INSTALL .. [[
            Event.Logic.Subscribe("fetch", function(ev)
                if ev.logicTick ~= 2 then return end
                local request = HTTPRequest.new(Plugin.urls.api, "/thing")
                request:AddHeader("Accept", "text/plain")
                request:Get(function(finished)
                    sameRequest = finished == request
                    body = finished.data
                end)
            end)
        ]]),
            { grant = { "httpAccess" } }
        )
        h:load()
        h:advance(40) -- the plugin's GET goes out on tick 2
        local get = h.requests[1]
        assert.are.equal("http://127.0.0.1:9000/thing", get.url)
        h:respond(get, { status = 200, body = "hi" })
        h:advance(1200)
        support.answer(h)
        h:advance(1200)

        assert.is_true(h.env.sameRequest)
        assert.are.equal("hi", h.env.body)
        local http = support.where(support.entries(h), { k = "http" })
        assert.are.equal(2, #http)
        assert.are.same({
            k = "http",
            id = 1,
            phase = "start",
            method = "GET",
            url = "http://127.0.0.1:9000/thing",
            headers = { Accept = "text/plain" },
            t = 2,
        }, http[1])
        assert.are.equal("done", http[2].phase)
        assert.is_true(http[2].successful)
        assert.are.equal(200, http[2].responseCode)
        assert.are.equal("hi", http[2].data)
    end)

    it("changes nothing without urls.recorder in the manifest", function()
        local h = harness.load(
            support.plugin(
                support.INSTALL .. "available = Player.IsAvailable()",
                [[{ "name": "T", "version": "0.0.1", "contactEmailAddress": "t@example.com",
                    "optionalPermissions": [ "httpAccess" ] }]]
            ),
            { grant = { "httpAccess" } }
        )
        h:advance(2000)
        assert.are.equal("[RECORDER] no urls.recorder in plugin.json, so not recording", h:output())
        assert.is_false(h.env.available)
        -- Still the harness's own Player, not a stand-in.
        assert.are.equal("Player", getmetatable(h.env.Player).__name)
        assert.are.equal(0, #h.requests)
    end)

    it("finds urls.recorder by indexing when Plugin.urls iterates to nothing", function()
        -- Stands in for a client whose urls answer through __index but can't be listed.
        local hidePairs =
            "getmetatable(Plugin.urls).__pairs = function() return next, {}, nil end\n"
        local h = harness.load(
            support.plugin(hidePairs .. support.INSTALL .. "local up = Player.IsAvailable()"),
            { grant = { "httpAccess" } }
        )
        assert.are.equal("", h:output())
        h:step()
        assert.are.equal(1, #support.posts(h))
    end)

    it("leaves a plugin without dev/ running unrecorded", function()
        local h = harness.load({
            ["main.lua"] = [[
                local recorder = require("dev/recorder")
                if recorder then recorder.install(_ENV, "t") end
                loaded = recorder ~= nil
            ]],
            ["plugin.json"] = support.MANIFEST,
        }, { grant = { "httpAccess" } })
        h:advance(2000)
        assert.is_false(h.env.loaded)
        assert.are.equal("", h:output())
        assert.are.equal(0, #h.requests)
    end)
end)
