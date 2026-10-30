-- Self-tests: Event subscriptions, the simulated clock, fire(), and the client limits the
-- runtime enforces (callback errors, the time budget).

local harness = require("tests.harness")

local function plugin(main)
    return { ["main.lua"] = main }
end

describe("Event subscriptions", function()
    it("calls subscribers in subscription order", function()
        local h = harness.load(plugin([[
            Event.WindowFocusChanged.Subscribe("a", function() print("a") end)
            Event.WindowFocusChanged.Subscribe("b", function() print("b") end)
        ]]))
        h:fire("WindowFocusChanged", { hasFocus = true })
        assert.are.equal("a\nb", h:output())
    end)

    it("ignores a Subscribe that reuses a name, as the client does", function()
        local h = harness.load(plugin([[
            Event.WindowFocusChanged.Subscribe("x", function() print("old") end)
            Event.WindowFocusChanged.Subscribe("z", function() print("z") end)
            Event.KeyTyped.Subscribe("x", function() print("other event") end)
            Event.WindowFocusChanged.Subscribe("x", function() print("new") end)
        ]]))
        h:fire("WindowFocusChanged", { hasFocus = true })
        h:fire("KeyTyped", { char = 65, modifiers = 0, timestamp = 0 })
        assert.are.equal("old\nz\nother event", h:output())
    end)

    it(
        "puts a name subscribed again after Unsubscribe last, and reports what it removed",
        function()
            local h = harness.load(plugin([[
            Event.WindowFocusChanged.Subscribe("x", function() print("x") end)
            Event.WindowFocusChanged.Subscribe("z", function() print("z") end)
            removed = { Event.WindowFocusChanged.Unsubscribe("x"), Event.WindowFocusChanged.Unsubscribe("x") }
            Event.WindowFocusChanged.Subscribe("x", function() print("x again") end)
        ]]))
            h:fire("WindowFocusChanged", { hasFocus = true })
            assert.are.equal("z\nx again", h:output())
            assert.are.same({ true, false }, h.env.removed)
        end
    )

    it("stops calling an unsubscribed callback", function()
        local h = harness.load(plugin([[
            Event.WindowFocusChanged.Subscribe("x", function() print("x") end)
            Event.WindowFocusChanged.Unsubscribe("x")
        ]]))
        h:fire("WindowFocusChanged", { hasFocus = true })
        assert.are.equal("", h:output())
    end)

    it("faults on Unsubscribe passed straight to pcall or xpcall, wherever it runs", function()
        -- Top level: the fault fails the load, though the plugin's pcall caught it.
        assert.matches(
            "Event.KeyTyped.Unsubscribe passed straight to pcall: the client aborts %(SIGABRT%)",
            harness.errorOf(function()
                harness.load(plugin([[
                    Event.KeyTyped.Subscribe("x", function() end)
                    pcall(Event.KeyTyped.Unsubscribe, "x")
                ]]))
            end)
        )
        local h = harness.load(plugin([[
            Event.KeyTyped.Subscribe("x", function() end)
            Event.WindowFocusChanged.Subscribe("y", function()
                xpcall(Event.KeyTyped.Unsubscribe, print, "x")
            end)
            function PluginShutdown() pcall(Event.KeyTyped.Unsubscribe, "x") end
        ]]))
        assert.matches(
            "Event.KeyTyped.Unsubscribe passed straight to pcall",
            harness.errorOf(function()
                h:fire("WindowFocusChanged", { hasFocus = true })
            end)
        )
        assert.matches(
            "Event.KeyTyped.Unsubscribe passed straight to pcall",
            harness.errorOf(function()
                h:unload()
            end)
        )
    end)

    it("allows a direct Unsubscribe in a callback, of a subscription made in one", function()
        -- The live-proven shape: made inside Logic, removed directly from inside Logic.
        local h = harness.load(plugin([[
            n, step = 0, 0
            Event.WindowFocusChanged.Subscribe("y", function()
                step = step + 1
                if step == 1 then
                    Event.KeyTyped.Subscribe("x", function() n = n + 1 end)
                else
                    Event.KeyTyped.Unsubscribe("x")
                end
            end)
        ]]))
        local key = { char = 65, modifiers = 0, timestamp = 0 }
        h:fire("WindowFocusChanged", { hasFocus = true })
        h:fire("KeyTyped", key)
        h:fire("WindowFocusChanged", { hasFocus = true })
        h:fire("KeyTyped", key)
        assert.are.equal(1, h.env.n)
        assert.are.same({}, h.instance.subs.KeyTyped)
    end)

    it("allows Unsubscribe from a closure, or tail-called, under pcall (both live)", function()
        local h = harness.load(plugin([[
            Event.KeyTyped.Subscribe("x", function() end)
            Event.WindowFocusChanged.Subscribe("y", function()
                pcall(function() Event.KeyTyped.Unsubscribe("x") end)
            end)
            Event.KeyTyped.Subscribe("t", function() end)
            local function drop(k) return Event.KeyTyped.Unsubscribe(k) end
            Event.ServerLogic.Subscribe("y", function() ok, removed = pcall(drop, "t") end)
        ]]))
        h:fire("WindowFocusChanged", { hasFocus = true })
        assert.are.equal(1, #h.instance.subs.KeyTyped)
        h:fire("ServerLogic")
        assert.are.same({}, h.instance.subs.KeyTyped)
        assert.are.same({ true, true }, { h.env.ok, h.env.removed })
    end)

    it("allows Unsubscribe in PluginShutdown from a self-reload mid-dispatch", function()
        local h = harness.load(plugin([[
            Event.KeyTyped.Subscribe("x", function() end)
            function PluginShutdown()
                Event.KeyTyped.Unsubscribe("x")
                Event.WindowFocusChanged.Unsubscribe("y")
            end
            Event.WindowFocusChanged.Subscribe("y", function() ExecuteConsoleCommand("prl me") end)
        ]]))
        h.onConsoleCommand = function()
            h:unload()
        end
        h:fire("WindowFocusChanged", { hasFocus = true })
        assert.are.same({}, h.instance.subs.KeyTyped)
    end)

    it("allows a direct Unsubscribe inside an HTTP completion callback", function()
        local h = harness.load({
            ["main.lua"] = [[
                local started = false
                Event.KeyTyped.Subscribe("x", function() end)
                Event.Logic.Subscribe("go", function()
                    if started then return end
                    started = true
                    HTTPRequest.new(Plugin.urls.sink):Get(function()
                        Event.KeyTyped.Unsubscribe("x")
                    end)
                end)
            ]],
            ["plugin.json"] = [[{ "name": "T", "version": "0.0.1",
                "contactEmailAddress": "t@example.com", "optionalPermissions": [ "httpAccess" ],
                "urls": { "sink": "http://127.0.0.1:8765" } }]],
        }, { grant = { "httpAccess" } })
        h:step()
        h:respond(h.requests[1], { status = 200 })
        h:step()
        assert.are.same({}, h.instance.subs.KeyTyped)
    end)

    it("passes the payload's stub fields, and faults on one the stub lacks", function()
        local h = harness.load(plugin([[
            Event.WindowFocusChanged.Subscribe("x", function(ev) print(ev.hasFocus) end)
            Event.KeyTyped.Subscribe("y", function(ev) return ev.key end)
        ]]))
        h:fire("WindowFocusChanged", { hasFocus = false })
        assert.are.equal("false", h:output())
        assert.matches(
            "unmocked API: KeyTypedEventPayload.key",
            harness.errorOf(function()
                h:fire("KeyTyped", { char = 65, modifiers = 0, timestamp = 0 })
            end)
        )
        assert.has_error(function()
            h:fire("WindowFocusChanged", { focus = true })
        end)
    end)

    it("faults on an event the stubs don't have", function()
        assert.matches(
            "unmocked API: Event.Teleported",
            harness.errorOf(function()
                harness.load(plugin("Event.Teleported.Subscribe('x', print)"))
            end)
        )
    end)
end)

describe("the clock", function()
    it("fires Logic at 50 Hz with logicTick, and ServerLogic every 600 ms", function()
        local h = harness.load(plugin([[
            logic, server, lastTick = 0, 0, nil
            Event.Logic.Subscribe("l", function(ev) logic = logic + 1 lastTick = ev.logicTick end)
            Event.ServerLogic.Subscribe("s", function(ev) server = server + 1 noPayload = ev == nil end)
        ]]))
        h:advance(1200)
        assert.are.equal(60, h.env.logic)
        assert.are.equal(60, h.env.lastTick)
        assert.are.equal(2, h.env.server)
        assert.is_true(h.env.noPayload)
    end)

    it("carries part of a tick over to the next advance", function()
        local h = harness.load(plugin("n = 0 Event.Logic.Subscribe('l', function() n = n + 1 end)"))
        h:advance(30)
        assert.are.equal(1, h.env.n)
        h:advance(10)
        assert.are.equal(2, h.env.n)
    end)
end)

describe("client limits", function()
    it("fails the test when a subscriber errors, naming the event and subscriber", function()
        local h = harness.load(plugin([[
            Event.Logic.Subscribe("boom", function() error("kaboom") end)
        ]]))
        assert.matches(
            "^Event.Logic subscriber 'boom': inline/main.lua:1: kaboom",
            harness.errorOf(function()
                h:advance(20)
            end)
        )
    end)

    it("aborts a callback that runs past the time budget", function()
        local h = harness.load(
            plugin([[
            Event.Logic.Subscribe("spin", function()
                -- A pcall can't rescue the call once the budget is spent.
                pcall(function() while true do end end)
                while true do end
            end)
        ]]),
            { budgetMs = 50 }
        )
        assert.matches(
            "Event.Logic subscriber 'spin': Maximum function execution time of 50 ms exceeded",
            harness.errorOf(function()
                h:advance(20)
            end)
        )
    end)

    it("aborts a runaway loop inside a coroutine", function()
        local h = harness.new(plugin("coroutine.wrap(function() while true do end end)()"))
        h.budgetMs = 50
        assert.matches(
            "main.lua: Maximum function execution time of 50 ms exceeded",
            harness.errorOf(function()
                h:load()
            end)
        )
    end)

    it("charges a coroutine to the callback that resumes it", function()
        local h = harness.load(
            plugin([[
            local co = coroutine.create(function() coroutine.yield() while true do end end)
            coroutine.resume(co)
            Event.Logic.Subscribe("resume", function() coroutine.resume(co) end)
        ]]),
            { budgetMs = 50 }
        )
        assert.matches(
            "Event.Logic subscriber 'resume': Maximum function execution time of 50 ms exceeded",
            harness.errorOf(function()
                h:advance(20)
            end)
        )
    end)

    it("applies the budget to main.lua too, defaulting to the client's 1000 ms", function()
        local h = harness.new(plugin("while true do end"))
        assert.are.equal(1000, h.budgetMs)
        h.budgetMs = 30
        assert.matches(
            "main.lua: Maximum function execution time of 30 ms exceeded",
            harness.errorOf(function()
                h:load()
            end)
        )
    end)
end)
