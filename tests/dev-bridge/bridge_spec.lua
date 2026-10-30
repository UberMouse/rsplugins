-- plugins/dev-bridge against the harness: self-granting, the sync loop's pacing, running the
-- daemon's commands, forwarding events, the buffer cap, the daemon being down, and shutdown.

local support = require("tests.dev-bridge.support")

-- The forwarded events, in the order main.lua subscribes them (protocol.LOAD_EVENTS order).
local FORWARDED = {
    "ChatMessage",
    "VarTransmit",
    "InventoryUpdated",
    "MiniMenuEntrySelected",
    "GameStateChanged",
}

describe("dev-bridge", function()
    it("subscribes the six load events at load, in order, as devBridge<Event>", function()
        -- PluginShutdown and the reload path unsubscribe by these exact names. The other
        -- probe-able events are subscribed only once a probe needs them.
        local h = support.new()
        local calls = support.spyEvent(h, true)
        h:load()
        assert.are.same({
            "Subscribe Logic devBridgeLogic",
            "Subscribe ChatMessage devBridgeChatMessage",
            "Subscribe VarTransmit devBridgeVarTransmit",
            "Subscribe InventoryUpdated devBridgeInventoryUpdated",
            "Subscribe MiniMenuEntrySelected devBridgeMiniMenuEntrySelected",
            "Subscribe GameStateChanged devBridgeGameStateChanged",
        }, calls)
        local protocol = h.env.require("protocol")
        local loaded = {}
        for _, event in ipairs(protocol.LOAD_EVENTS) do
            loaded[event] = true
            local subs = h.instance.subs[event]
            assert.are.same({ "devBridge" .. event }, { subs[1].name, subs[2] }, event)
        end
        for event, subs in pairs(h.instance.subs) do
            if not loaded[event] then assert.are.same({}, subs, event) end
        end
    end)

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
        support.ticks(h, 100)
        assert.are.equal(0, #h.requests)
        assert.are.equal(1, h:consoleCount("[BRIDGE] waiting for httpAccess"))
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
            support.ticks(h, 50) -- unanswered: nothing more starts
            assert.are.equal(1, #support.syncs(h))

            support.answer(h)
            local finished = h.tick
            support.ticks(h, support.limits(h).syncEveryTicks - 1)
            assert.are.equal(1, #support.syncs(h))
            h:step()
            assert.are.equal(finished + 10, support.syncs(h)[2].startTick)

            support.answer(h, { status = 500 })
            local failed = h.tick
            support.ticks(h, support.limits(h).retryTicks - 1)
            assert.are.equal(2, #support.syncs(h))
            h:step()
            assert.are.equal(failed + 250, support.syncs(h)[3].startTick)
        end
    )

    it("sends the session, seq and hello with the environment on every sync", function()
        local h = support.load()
        h:step()
        local first = support.last(h)
        local second = support.cycle(h)

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

            support.ticks(h, 8)
            assert.are.same({
                { id = "c1", ok = true },
                { id = "c2", ok = true },
                { id = "c3", ok = true },
            }, support.last(h).results)
            assert.are.same({}, support.cycle(h).results) -- each result is sent once
        end
    )

    it(
        "answers unknown kinds, self-disabling commands and failing commands with ok=false",
        function()
            local h = support.load()
            h.onConsoleCommand = function(command)
                if command == "boom" then error("no such command") end
            end
            h:step()
            local results = support.cycle(h, {
                status = 200,
                body = support.line("k1", "bogus", "1 + 1")
                    .. support.line("k2", "exec", "  POFF  dev-bridge")
                    .. support.line("k3", "exec", "plugins_setenabled dev-bridge true")
                    .. support.line("k4", "exec", "boom")
                    .. support.line("k5", "exec", "prl dev-bridge"),
            }).results
            assert.are.same({ id = "k1", ok = false, error = "unknown kind bogus" }, results[1])
            assert.is_false(results[2].ok)
            assert.matches("client console", results[2].error)
            assert.is_false(results[3].ok)
            assert.is_false(results[4].ok)
            assert.matches("no such command", results[4].error)
            -- The refused ones never ran; a self-reload is not refused.
            assert.are.same({ "boom", "prl dev-bridge" }, support.ran(h))
            assert.is_true(results[5].ok)
        end
    )

    it("starts nothing once a command has shut the plugin down", function()
        local h = support.load()
        h.onConsoleCommand = function(command)
            -- A self-reload runs PluginShutdown before the command returns.
            if command == "prl dev-bridge" then h:unload() end
        end
        h:step()
        -- Ten fillers put the reload on the tick the next sync is due.
        local body = ""
        for i = 1, 10 do
            body = body .. support.line("f" .. i, "exec", "plist")
        end
        support.answer(
            h,
            { status = 200, body = body .. support.line("r1", "exec", "prl dev-bridge") }
        )
        local requests = #h.requests
        support.ticks(h, 30)
        assert.are.equal(1, #support.syncs(h))
        assert.are.equal(requests, #h.requests)
        assert.are.same({}, h.instance.subs.Logic)
    end)

    it("skips malformed reply lines, logging them once per sync", function()
        local h = support.load()
        h:step()
        support.answer(h, {
            status = 200,
            body = "garbage\n" .. "bad id!\texec\tplist\n" .. support.line("g1", "exec", "plist"),
        })
        assert.are.same({ "plist" }, support.ran(h))
        assert.are.equal(1, h:consoleCount("skipped 2 malformed reply line(s)"))
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
        h:fire("MiniMenuEntrySelected", { entry = { verbText = "Walk here", actionType = 23 } })
        h:fire("GameStateChanged", { oldState = 30, newState = 10 })
        local events = support.forwarded(support.cycle(h))
        local names = {}
        for i, e in ipairs(events) do
            names[i] = e.name
            assert.are.equal(1, e.t, e.name)
        end
        assert.are.same(FORWARDED, names)
        assert.are.same({
            chatMessage = "hello",
            senderNameUnfiltered = "",
            senderNameFiltered = "",
            senderNameSimple = "",
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
        assert.are.same({ entry = { verbText = "Walk here", actionType = 23 } }, events[4].payload)
        assert.are.same({ oldState = 30, newState = 10 }, events[5].payload)
    end)

    it("forwards the player's own and system chat, never another player's", function()
        local h = support.new()
        h.world:login("UberMouse894")
        h:load()
        h:step()
        h.world:chat("a dwarf smith", { chatType = 0 })
        h.world:chat("Test", { chatType = 2, sender = "<img=11>ubermouse894" })
        h.world:chat("hi from bob", { chatType = 2, sender = "Bob" })
        h.world:chat("bob whispers", { chatType = 3, sender = "Bob" })
        h.world:chat("News: Farmer Hampe has done a feat", { chatType = 138 })
        h.world:chat("Bob has logged in.", { chatType = 5 })
        local body = support.cycle(h)
        local texts = {}
        for _, e in ipairs(support.forwarded(body)) do
            texts[#texts + 1] = e.payload.chatMessage
        end
        assert.are.same({ "a dwarf smith", "Test" }, texts)
        assert.are.equal(0, body.dropped) -- filtered, not lost
    end)

    it("drops speech while the player's name can't be read", function()
        local h = support.load() -- not logged in
        h:step()
        h.world:chat("Test", { chatType = 2, sender = "UberMouse894" })
        h.world:chat("system", { chatType = 0 })
        local events = support.forwarded(support.cycle(h))
        assert.are.equal(1, #events)
        assert.are.equal("system", events[1].payload.chatMessage)
    end)

    it("redacts the name of a player targeted by a selected menu entry", function()
        local h = support.load()
        h:step()
        h:fire("MiniMenuEntrySelected", {
            entry = {
                verbText = "Trade with",
                subjectText = "Bob",
                fullText = "Trade with Bob",
                overrideText = "",
                actionType = 46,
                actionEntryType = 7,
                playerData = {},
            },
        })
        local entry = support.forwarded(support.cycle(h))[1].payload.entry
        assert.are.equal("Trade with", entry.verbText)
        assert.are.equal("<player>", entry.subjectText)
        assert.are.equal("<player>", entry.fullText)
        assert.is_nil(entry.playerData)
    end)

    -- Fires one selection through the shell and returns the forwarded entry.
    local function forwardedEntry(entry)
        local h = support.load()
        h:step()
        h:fire("MiniMenuEntrySelected", { entry = entry })
        return support.forwarded(support.cycle(h))[1].payload.entry
    end

    it("forwards a Walk here entry with its text intact", function()
        local entry = forwardedEntry({
            verbText = "Walk here",
            fullText = "Walk here",
            actionEntryType = 0,
            actionType = 23,
        })
        assert.are.equal("Walk here", entry.fullText)
    end)

    it("forwards an NPC entry with its text intact", function()
        local entry = forwardedEntry({
            verbText = "Talk-to",
            subjectText = "Guard",
            fullText = "Talk-to Guard",
            actionEntryType = 4,
            actionType = 9,
            npcData = {},
        })
        assert.are.equal("Guard", entry.subjectText)
        assert.are.equal("Talk-to Guard", entry.fullText)
    end)

    it("redacts an entry whose playerData cannot be read", function()
        local entry = forwardedEntry(setmetatable({
            verbText = "Cast",
            subjectText = "Bob",
            fullText = "Cast Bob",
            actionEntryType = 1,
            actionType = 57,
        }, {
            __index = function(_, key)
                if key == "playerData" then error("unreadable") end
            end,
        }))
        assert.are.equal("<player>", entry.subjectText)
        assert.are.equal("<player>", entry.fullText)
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
        -- The 40 chat lines, and the bridge's "enabled" and "losing events" Log events.
        assert.are.equal(42, body.dropped + #body.events)
        assert.are.equal("message 40", body.events[#body.events].payload.chatMessage)
        assert.are.equal(1, h:consoleCount("[BRIDGE] losing events"))
    end)

    it("sends at most syncBytes of events per sync", function()
        local h = support.load({ "chatAccess" })
        h.env.require("protocol").limits.syncBytes = 400
        for i = 1, 6 do
            h.world:chat("message " .. i)
        end
        h.world:grant("httpAccess")
        h:step()
        local sent = #support.forwarded(support.last(h))
        assert.is_true(sent >= 1 and sent < 6)
        local next = support.forwarded(support.cycle(h))[1]
        assert.are.equal("message " .. (sent + 1), next.payload.chatMessage)
    end)

    it("backs off while the daemon is down, logging once, and resends results", function()
        local h = support.load()
        h:step()
        support.cycle(h, { status = 200, body = support.line("r1", "exec", "plist") })
        h.world:chat("lost")
        support.cycle(h, { error = "connection refused", errorCode = 7 })
        support.cycle(h, { timedOut = true })

        assert.are.equal(4, #support.syncs(h))
        assert.are.equal(1, h:consoleCount("[BRIDGE] sync failed"))
        local body = support.last(h)
        assert.are.same({ { id = "r1", ok = true } }, body.results) -- still unsent, so again
        -- The chat line, and the four Log events of the bridge's own lines that the two failed
        -- syncs carried ("connected", "exec r1", "losing events", "sync failed").
        assert.are.equal(5, body.dropped)

        support.answer(h)
        assert.are.equal(2, h:consoleCount("[BRIDGE] connected to rsdev"))
    end)

    it("treats a reply cut short as a failed sync whose events arrived", function()
        local h = support.load()
        h.world:chat("kept") -- in the first sync, which the daemon takes
        h:step()
        support.answer(h, { status = 200, body = "c1\texec\tplist" })
        assert.are.same({}, support.ran(h))
        assert.are.equal(1, h:consoleCount("[BRIDGE] sync failed (reply does not end"))
        support.untilRetry(h)
        assert.are.equal(0, support.last(h).dropped)
    end)

    it("drops a sync the daemon refuses with 400 and sends later results", function()
        local h = support.load()
        h:step()
        support.cycle(h, { status = 200, body = support.line("r1", "exec", "plist") })
        h.world:chat("refused")
        -- The sync that is refused carries r1's result and the chat.
        local body = support.cycle(h, { status = 400, body = "bad" })
        assert.are.equal(1, h:consoleCount("[BRIDGE] sync failed"))
        assert.are.same({}, body.results)
        assert.is_true(body.dropped >= 1)
        support.answer(h)
        assert.are.equal(1, h:consoleCount("[BRIDGE] sync failed"))
    end)

    it("keeps the bridge running when a 200 reply has no body", function()
        local h = support.load()
        h:step()
        support.answer(h, { status = 200, noBody = true })
        assert.are.equal(1, h:consoleCount("[BRIDGE] sync failed (reply had no body"))
        assert.are.equal(0, h:consoleCount("[BRIDGE] stopped after an error"))
        support.untilRetry(h)
        support.answer(h)
        assert.are.equal(1, h:consoleCount("[BRIDGE] connected to rsdev"))
    end)

    it("cancels the sync in flight when an internal error stops it", function()
        local h = support.load()
        h:step()
        local body = ""
        for i = 1, 14 do -- still queued when the second sync starts
            body = body .. support.line("c" .. i, "exec", "plist")
        end
        support.cycle(h, { status = 200, body = body })
        local open = support.open(h)
        assert.are.equal(1, #open)
        h.env.require("protocol").refusal = function()
            error("boom")
        end
        h:step()
        assert.is_true(open[1].state.fields.cancelled)
        assert.are.equal(1, h:consoleCount("[BRIDGE] stopped after an error"))
        -- Stopped from inside Logic, so made a no-op, not unsubscribed (stopping makes no
        -- client call; PluginShutdown unsubscribes): still subscribed, and doing nothing.
        assert.are.same("devBridgeLogic", h.instance.subs.Logic[1].name)
        local requests = #h.requests
        h.world:chat("ignored")
        support.ticks(h, 300)
        assert.are.equal(requests, #h.requests)
        assert.are.equal(1, h:consoleCount("[BRIDGE] stopped after an error"))
        h:unload()
    end)

    it("counts an event whose payload can't be read as dropped and says so once", function()
        local h = support.load()
        h:step()
        local unreadable = setmetatable({}, {
            __index = function()
                error("unreadable", 0)
            end,
        })
        h.instance.subs.GameStateChanged[1].fn(unreadable)
        local body = support.cycle(h)
        assert.are.equal(1, body.dropped)
        assert.are.equal(0, #support.payloads(body, "GameStateChanged"))
        assert.are.equal(
            1,
            h:consoleCount("[BRIDGE] could not forward a GameStateChanged event: unreadable")
        )
    end)

    it("without urls.rsdev starts no request, says so once and keeps retrying", function()
        local h = support.new()
        h.manifest.urls = nil
        h:load()
        -- Every sync attempt, started or not, takes the pending results first.
        local attempts = 0
        local protocol = h.env.require("protocol")
        local takeResults = protocol.takeResults
        protocol.takeResults = function(...)
            attempts = attempts + 1
            return takeResults(...)
        end
        h:step()
        assert.are.equal(1, attempts)
        local failed =
            "[BRIDGE] sync failed (could not start the request: the manifest has no urls.rsdev)"
        assert.are.equal(1, h:consoleCount(failed))
        assert.are.equal(1, h:consoleCount("is scripts/rsdev.py running? Retrying every 5 s"))
        support.untilRetry(h)
        assert.are.equal(2, attempts)
        assert.are.equal(0, #h.requests)
        assert.are.equal(1, h:consoleCount(failed)) -- once per outage, not per retry
    end)

    it("logs a self-grant command that raises and carries on with the rest", function()
        local h = support.new()
        h.onConsoleCommand = function(command)
            if command:find("^ppr ") then error("no such plugin", 0) end
        end
        h:load()
        assert.are.equal(1, h:consoleCount("[BRIDGE] `ppr dev-bridge` failed: no such plugin"))
        assert.are.same({
            "ppr dev-bridge",
            "ppe dev-bridge httpAccess",
            "ppe dev-bridge chatAccess",
        }, h.consoleCommands)
        h:step()
        assert.are.equal(1, #support.syncs(h)) -- loaded and syncing regardless
    end)

    it("sends results over several syncs when they exceed resultBytes, losing none", function()
        local h = support.loadEval()
        local commands = {}
        for _, id in ipairs({ "e1", "e2", "e3" }) do
            commands[#commands + 1] = support.line(id, "eval", "1")
        end
        local entry = #h.env.require("protocol").resultEntry({
            id = "e1",
            ok = true,
            values = { 1 },
            nvalues = 1,
            output = { lines = {}, truncated = false },
        })
        h.env.require("protocol").limits.resultBytes = entry * 2 + 1 -- room for two, not three
        local first = support.cycle(h, { status = 200, body = table.concat(commands) })
        local second = support.cycle(h)
        local ids = {}
        for _, body in ipairs({ first, second }) do
            for _, result in ipairs(body.results) do
                assert.is_true(result.ok)
                ids[#ids + 1] = result.id
            end
        end
        assert.are.same({ "e1", "e2" }, { first.results[1].id, first.results[2].id })
        assert.are.same({ "e3" }, { second.results[1].id })
        assert.are.same({ "e1", "e2", "e3" }, ids)
        assert.are.same({}, support.cycle(h).results)
    end)

    it("unsubscribes everything and cancels the sync in flight on shutdown", function()
        local h = support.load()
        h:step()
        local open = support.open(h)[1]
        h:unload()
        assert.is_true(open.state.fields.cancelled)
    end)
end)
