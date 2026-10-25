-- plugins/dev-bridge against the harness: self-granting, the sync loop's pacing, running the
-- daemon's commands, forwarding events, the buffer cap, the daemon being down, and shutdown.

local support = require("tests.dev-bridge.support")

-- The forwarded events' subscription names, as main.lua makes them.
local FORWARDED = {
    "ChatMessage",
    "VarTransmit",
    "InventoryUpdated",
    "MiniMenuEntrySelected",
    "GameStateChanged",
}

describe("dev-bridge", function()
    it("grants itself its permissions on load, ppr first", function()
        local h = support.load()
        assert.are.same({
            "ppr dev-bridge",
            "ppe dev-bridge httpAccess",
            "ppe dev-bridge chatAccess",
        }, h.consoleCommands)
    end)

    it("starts no request until httpAccess is granted, and says so once", function()
        local h = support.load({})
        h:advance(2000) -- 100 ticks
        assert.are.equal(0, #h.requests)
        assert.are.equal(1, support.lines(h, "[BRIDGE] waiting for httpAccess"))
        h.world:grant("httpAccess")
        h:step()
        assert.are.equal(1, #support.syncs(h))
    end)

    it(
        "keeps one sync in flight, and waits 10 ticks after one finishes, 250 after a failure",
        function()
            local h = support.load()
            h:step()
            assert.are.equal(1, #support.syncs(h))
            h:advance(1000) -- unanswered: nothing more starts
            assert.are.equal(1, #support.syncs(h))

            support.answer(h)
            local finished = h.tick
            h:advance(20 * 9)
            assert.are.equal(1, #support.syncs(h))
            h:step()
            assert.are.equal(finished + 10, support.syncs(h)[2].startTick)

            support.answer(h, { status = 500 })
            local failed = h.tick
            h:advance(20 * 249)
            assert.are.equal(2, #support.syncs(h))
            h:step()
            assert.are.equal(failed + 250, support.syncs(h)[3].startTick)
        end
    )

    it("sends the session, seq and hello with the environment on every sync", function()
        local h = support.load()
        h:step()
        local first = support.last(h)
        support.answer(h)
        h:advance(20 * 10)
        local second = support.last(h)

        assert.are.equal(1, first.schema)
        assert.are.equal("dev-bridge", first.plugin)
        assert.matches("^[%w][%w._-]*$", first.session)
        assert.are.same({ 1, 2 }, { first.seq, second.seq })
        assert.are.equal(first.session, second.session)
        local hello = {
            version = _VERSION,
            env = {
                load = "nil",
                loadstring = "nil",
                debug = "nil",
                os = "nil",
                io = "nil",
                require = "function",
                ExecuteConsoleCommand = "function",
                coroutine = "table",
            },
        }
        assert.are.same(hello, first.hello)
        assert.are.same(hello, second.hello)
    end)

    it(
        "runs a reply's commands one per tick, unescaped, and reports them on the next sync",
        function()
            local h = support.load()
            h:step()
            local tricky = "say a\tb\nc\\d\re"
            support.answer(h, {
                status = 200,
                body = support.line("c1", "exec", "plist")
                    .. support.line("c2", "exec", "pon debug-plugin")
                    .. support.line("c3", "exec", tricky),
            })
            assert.are.same({ "plist" }, support.ran(h))
            h:step()
            assert.are.same({ "plist", "pon debug-plugin" }, support.ran(h))
            h:step()
            assert.are.same({ "plist", "pon debug-plugin", tricky }, support.ran(h))

            h:advance(20 * 8)
            assert.are.same({
                { id = "c1", ok = true },
                { id = "c2", ok = true },
                { id = "c3", ok = true },
            }, support.last(h).results)
            support.answer(h)
            h:advance(20 * 10)
            assert.are.same({}, support.last(h).results) -- each result is sent once
        end
    )

    it(
        "answers unknown kinds, self-targeting commands and failing commands with ok=false",
        function()
            local h = support.load()
            h.onConsoleCommand = function(command)
                if command == "boom" then error("no such command") end
            end
            h:step()
            support.answer(h, {
                status = 200,
                body = support.line("k1", "eval", "1 + 1")
                    .. support.line("k2", "exec", "  PRL  dev-bridge")
                    .. support.line("k3", "exec", "plugins_setenabled dev-bridge true")
                    .. support.line("k4", "exec", "boom"),
            })
            h:advance(20 * 10)
            local results = support.last(h).results
            assert.are.same({ id = "k1", ok = false, error = "unknown kind eval" }, results[1])
            assert.is_false(results[2].ok)
            assert.matches("client console", results[2].error)
            assert.is_false(results[3].ok)
            assert.is_false(results[4].ok)
            assert.matches("no such command", results[4].error)
            assert.are.same({ "boom" }, support.ran(h)) -- the refused ones never ran
        end
    )

    it("skips malformed reply lines, logging them once per sync", function()
        local h = support.load()
        h:step()
        support.answer(h, {
            status = 200,
            body = "garbage\n" .. "bad id!\texec\tplist\n" .. support.line("g1", "exec", "plist"),
        })
        assert.are.same({ "plist" }, support.ran(h))
        assert.are.equal(1, support.lines(h, "skipped 2 malformed reply line(s)"))
    end)

    it("forwards each watched event with its Logic tick", function()
        local h = support.new()
        h.world:setVar("VarPlayer", "QP", 10)
        h.world:setInventory("INV", { [1] = { obj = "LOGS", count = 1 } }, 28)
        h:load()
        h:step() -- tick 1, which starts the first sync
        h.world:chat("hello", { sender = "Bob" })
        h.world:setVar("VarPlayer", "QP", 11)
        h.world:setInventory("INV", { [1] = { obj = "LOGS", count = 2 } })
        h:fire("MiniMenuEntrySelected", { entry = { verbText = "Walk here" } })
        h:fire("GameStateChanged", { oldState = 30, newState = 10 })
        support.answer(h)
        h:advance(20 * 10)

        local events = support.last(h).events
        local names = {}
        for i, e in ipairs(events) do
            names[i] = e.name
            assert.are.equal(1, e.t, e.name)
        end
        assert.are.same(FORWARDED, names)
        assert.are.same({
            chatMessage = "hello",
            senderNameUnfiltered = "Bob",
            senderNameFiltered = "Bob",
            senderNameSimple = "Bob",
            chatType = 0,
            timestamp = events[1].payload.timestamp,
        }, events[1].payload)
        assert.are.same({
            var = { config = "QP", id = 1297, type = "VarPlayer" },
            oldValue = 10,
            newValue = 11,
        }, events[2].payload)
        assert.are.same({ config = "INV", id = 93, type = "Inv" }, events[3].payload.inv)
        assert.are.same({ 1 }, events[3].payload.slotsUpdated)
        assert.are.same({ entry = { verbText = "Walk here" } }, events[4].payload)
        assert.are.same({ oldState = 30, newState = 10 }, events[5].payload)
    end)

    it("drops the oldest events past the buffer cap and counts them", function()
        local h = support.load({ "chatAccess" }) -- no httpAccess yet, so nothing is sent
        h.env.require("protocol").limits.bufferBytes = 1000
        for i = 1, 40 do
            h.world:chat("message " .. i)
        end
        h.world:grant("httpAccess")
        h:step()
        local body = support.last(h)
        assert.is_true(body.dropped > 0)
        assert.are.equal(40, body.dropped + #body.events)
        assert.are.equal("message 40", body.events[#body.events].payload.chatMessage)
        assert.are.equal(1, support.lines(h, "[BRIDGE] losing events"))
    end)

    it("sends at most syncBytes of events per sync", function()
        local h = support.load({ "chatAccess" })
        h.env.require("protocol").limits.syncBytes = 400
        for i = 1, 6 do
            h.world:chat("message " .. i)
        end
        h.world:grant("httpAccess")
        h:step()
        local sent = #support.last(h).events
        assert.is_true(sent >= 1 and sent < 6)
        support.answer(h)
        h:advance(20 * 10)
        assert.are.equal("message " .. (sent + 1), support.last(h).events[1].payload.chatMessage)
    end)

    it("backs off while the daemon is down, logging once, and resends results", function()
        local h = support.load()
        h:step()
        support.answer(h, { status = 200, body = support.line("r1", "exec", "plist") })
        h:advance(20 * 10)
        h.world:chat("lost")
        support.answer(h, { error = "connection refused", errorCode = 7 })
        h:advance(20 * 250)
        support.answer(h, { timedOut = true })
        h:advance(20 * 250)

        assert.are.equal(4, #support.syncs(h))
        assert.are.equal(1, support.lines(h, "[BRIDGE] sync failed"))
        local body = support.last(h)
        assert.are.same({ { id = "r1", ok = true } }, body.results) -- still unsent, so again
        assert.are.equal(1, body.dropped) -- the chat line, lost with the failed sync

        support.answer(h)
        assert.are.equal(2, support.lines(h, "[BRIDGE] connected to rsdev"))
    end)

    it("treats a reply cut short as a failed sync whose events arrived", function()
        local h = support.load()
        h.world:chat("kept") -- in the first sync, which the daemon takes
        h:step()
        support.answer(h, { status = 200, body = "c1\texec\tplist" })
        assert.are.same({}, support.ran(h))
        assert.are.equal(1, support.lines(h, "[BRIDGE] sync failed (reply does not end"))
        h:advance(20 * 250)
        assert.are.equal(0, support.last(h).dropped)
    end)

    it("unsubscribes everything and cancels the sync in flight on shutdown", function()
        local h = support.load()
        h:step()
        local open = support.open(h)[1]
        h:unload()
        assert.is_true(open.state.fields.cancelled)
        for _, event in ipairs({ "Logic", table.unpack(FORWARDED) }) do
            assert.are.same({}, h.instance.subs[event], event)
        end
    end)
end)
