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
