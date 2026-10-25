-- plugins/dev-bridge's eval (eval.lua) against the harness, with the sandbox's `load`: running
-- snippets, their values and output, the scratch env, emit, probes (table entries the
-- bridge's own handlers fan out to), the console proxy, reset and shutdown. The caps' arithmetic is in protocol_spec.lua.

local support = require("tests.dev-bridge.support")

-- The real subscription names on `event`, in order.
local function subNames(h, event)
    local names = {}
    for i, entry in ipairs(h.instance.subs[event]) do
        names[i] = entry.name
    end
    return names
end

-- Record, from now on, every real Event.<X>.Subscribe/Unsubscribe the bridge makes, as
-- "Subscribe <event> <name>" or "Unsubscribe <event> <name>".
local function spyEvent(h)
    local env = h.instance.env
    local real = env.Event
    local calls = {}
    env.Event = setmetatable({}, {
        __index = function(_, event)
            local sub = real[event]
            return {
                Subscribe = function(name, fn)
                    calls[#calls + 1] = "Subscribe " .. event .. " " .. name
                    return sub.Subscribe(name, fn)
                end,
                Unsubscribe = function(name)
                    calls[#calls + 1] = "Unsubscribe " .. event .. " " .. name
                    return sub.Unsubscribe(name)
                end,
            }
        end,
    })
    return calls
end

-- What spyEvent records for PluginShutdown: one Unsubscribe per probe-able event.
local function loadTimeUnsubscribes(h)
    local out = {}
    for i, event in ipairs(h.env.require("protocol").PROBE_EVENTS) do
        out[i] = "Unsubscribe " .. event .. " devBridge" .. event
    end
    return out
end

-- The Log payloads with source "eval" in a sync body.
local function evalLogs(body)
    local out = {}
    for _, p in ipairs(support.payloads(body, "Log")) do
        if p.source == "eval" then out[#out + 1] = p end
    end
    return out
end

-- A probe that emits a running count on every Logic tick, under subscription name `name`.
local function counter(name)
    return string.format(
        [[local n = 0
Event.Logic.Subscribe(%q, function() n = n + 1 emit(%q, n) end)]],
        name,
        name
    )
end

describe("dev-bridge eval", function()
    it("returns an expression's values, trailing nils included, with nvalues", function()
        local h = support.loadEval()
        local r = support.eval(h, "1, nil, 'x', nil")
        assert.are.same({ true, 4, {} }, { r.ok, r.nvalues, r.output })
        assert.matches('"values":%[1,null,"x",null%]', support.lastRaw(h))
        local none = support.eval(h, "do end")
        assert.are.same({ true, 0, {} }, { none.ok, none.nvalues, none.values })
    end)

    it("serialises a returned table and an API object as events are", function()
        local h = support.loadEval()
        local r = support.eval(h, "{ a = 1, b = { 2, 3 } }, config.Inv.INV")
        assert.are.same({ a = 1, b = { 2, 3 } }, r.values[1])
        assert.are.same({ config = "INV", id = 93, type = "Inv" }, r.values[2])
    end)

    it("runs statements when the expression form doesn't compile", function()
        local h = support.loadEval()
        local set = support.eval(h, "x = 41")
        assert.are.same({ true, 0 }, { set.ok, set.nvalues })
        assert.are.same({ 42 }, support.eval(h, "x + 1").values)
    end)

    it("keeps the snippets' globals in a scratch env that reads the bridge's", function()
        local h = support.loadEval()
        support.eval(h, "x = 1")
        assert.is_nil(rawget(h.env, "x"))
        assert.are.same({ _VERSION }, support.eval(h, "_VERSION").values)
        assert.are.same({ true }, support.eval(h, "_G.x == x").values)
    end)

    it("reports a compile error as ok=false with the statement form's message", function()
        local h = support.loadEval()
        local r = support.eval(h, "1 +")
        assert.is_false(r.ok)
        assert.matches("^eval:1: ", r.error)
        assert.is_nil(r.values)
    end)

    it("reports a runtime error, tostring'd, with the output printed before it", function()
        local h = support.loadEval()
        local r = support.eval(h, "print('before') error('boom')")
        assert.are.same({ false, { "before" } }, { r.ok, r.output })
        assert.matches("^eval:1: boom$", r.error)
        local t =
            support.eval(h, "error(setmetatable({}, { __tostring = function() return 'obj' end }))")
        assert.are.same({ false, "obj" }, { t.ok, t.error })
        assert.are.equal(1, support.lines(h, "[BRIDGE] command e failed: obj"))
    end)

    it("captures print and log into the result, and still writes the console", function()
        local h = support.loadEval()
        local r, body = support.eval(h, "print('a', 1, nil) log('b') return 2")
        assert.are.same({ "a 1 nil", "b" }, r.output)
        assert.are.same({ 2 }, r.values)
        assert.are.same({}, evalLogs(body)) -- output is returned, not streamed
        assert.are.equal(1, support.lines(h, "a 1 nil"))
    end)

    it("cuts output past its caps and says truncated, ok staying true", function()
        local h = support.loadEval()
        local limits = h.env.require("protocol").limits
        limits.outputLines, limits.lineBytes = 2, 3
        local r = support.eval(h, "print('abcdef') print('b') print('c')")
        assert.are.same({ true, { "abc", "b" }, true }, { r.ok, r.output, r.truncated })
    end)

    it("drops values that don't fit and keeps their count", function()
        local h = support.loadEval()
        h.env.require("protocol").limits.valueBytes = 10
        local r = support.eval(h, "string.rep('x', 100), 2")
        assert.are.same({ true, {}, 2, true }, { r.ok, r.values, r.nvalues, r.truncated })
    end)

    it("refuses an empty source", function()
        local h = support.loadEval()
        local r = support.eval(h, "")
        assert.are.same({ false, "eval has no Lua source" }, { r.ok, r.error })
    end)

    it("reports ok=false when the client has no load", function()
        local h = support.load()
        h:step()
        local r = support.eval(h, "1")
        assert.is_false(r.ok)
        assert.matches("no load%(%)", r.error)
    end)

    it("sends emit(tag, value) as an Emit event, the tag as text", function()
        local h = support.loadEval()
        local _, body = support.eval(h, "emit('n', { a = 1 }) emit(5, nil)")
        assert.are.same(
            { { tag = "n", value = { a = 1 } }, { tag = "5" } },
            support.payloads(body, "Emit")
        )
    end)

    it("runs a probe from the bridge's own handler, with no client subscription", function()
        local h = support.loadEval()
        local calls = spyEvent(h)
        local _, body = support.eval(h, counter("count"))
        local counts = {}
        for i, p in ipairs(support.payloads(body, "Emit")) do
            counts[i] = p.value
        end
        assert.is_true(#counts >= 5)
        assert.are.same({ 1, 2, 3 }, { counts[1], counts[2], counts[3] })
        -- A probe can't take over the bridge's own subscription by naming it.
        support.eval(h, counter("devBridgeLogic"))
        assert.are.same({ "devBridgeLogic" }, subNames(h, "Logic"))
        assert.are.same({}, calls)
        assert.is_true(#support.syncs(h) >= 3) -- the bridge's Logic work carries on
    end)

    it("streams a probe's print as a Log event, source eval, and writes the console", function()
        local h = support.loadEval()
        support.eval(h, "Event.Logic.Subscribe('p', function() print('probe', 1) end)")
        h:advance(20 * 30)
        support.answer(h)
        h:advance(20 * 10)
        local logs = evalLogs(support.last(h))
        assert.is_true(#logs >= 1)
        assert.are.same(
            { plugin = "dev-bridge", level = "print", text = "probe 1", source = "eval" },
            logs[1]
        )
        assert.is_true(support.lines(h, "probe 1") >= 1)
    end)

    it(
        "passes a forwarded event's payload to a probe, and returns nothing to the client",
        function()
            local h = support.loadEval()
            support.eval(
                h,
                "Event.GameStateChanged.Subscribe('g', function(ev) emit('g', ev.newState) return true end)"
            )
            local handler = h.instance.subs.GameStateChanged[1].fn
            assert.are.equal(0, select("#", handler({ oldState = 30, newState = 10 })))
            support.answer(h)
            h:advance(20 * 10)
            local body = support.last(h)
            assert.are.same({ { tag = "g", value = 10 } }, support.payloads(body, "Emit"))
            assert.are.equal(1, #support.payloads(body, "GameStateChanged")) -- still forwarded
        end
    )

    it("replaces a probe by name and removes it on Unsubscribe, as table edits", function()
        local h = support.loadEval()
        local calls = spyEvent(h)
        support.eval(h, "Event.Logic.Subscribe('p', function() emit('p', 1) end)")
        support.eval(h, "Event.Logic.Subscribe('p', function() emit('p', 2) end)")
        support.answer(h) -- the sync carrying the emits from before the replacement
        h:advance(20 * 10)
        local values = {}
        for _, p in ipairs(support.payloads(support.last(h), "Emit")) do
            values[p.value] = true
        end
        assert.are.same({ [2] = true }, values) -- only the replacement runs
        support.eval(h, "Event.Logic.Unsubscribe('p') Event.Logic.Unsubscribe('nope')")
        support.answer(h)
        h:advance(20 * 10)
        assert.are.same({}, support.payloads(support.last(h), "Emit"))
        assert.are.same({}, calls)
        assert.are.same({ "devBridgeLogic" }, subNames(h, "Logic"))
    end)

    it("skips a probe removed during the fan-out for the rest of that pass", function()
        local h = support.loadEval()
        local _, body = support.eval(
            h,
            [[Event.Logic.Subscribe('a', function() Event.Logic.Unsubscribe('b') emit('a', 1) end)
Event.Logic.Subscribe('b', function() emit('b', 1) end)
Event.Logic.Subscribe('once', function() Event.Logic.Unsubscribe('once') emit('once', 1) end)]]
        )
        local tags = {}
        for _, p in ipairs(support.payloads(body, "Emit")) do
            tags[p.tag] = (tags[p.tag] or 0) + 1
        end
        assert.is_nil(tags.b)
        assert.are.equal(1, tags.once)
        assert.is_true(tags.a >= 5)
    end)

    it("first calls a probe added or replaced during the fan-out on the next dispatch", function()
        local h = support.loadEval()
        local _, body = support.eval(
            h,
            [[local added = false
Event.Logic.Subscribe('a', function(ev)
    if added then return end
    added = true
    emit('a', ev.logicTick)
    Event.Logic.Subscribe('b', function(e) emit('b', e.logicTick) end)
    Event.Logic.Subscribe('a', function(e) emit('a2', e.logicTick) end)
end)]]
        )
        local first = {}
        for _, p in ipairs(support.payloads(body, "Emit")) do
            first[p.tag] = first[p.tag] or p.value
        end
        assert.are.equal(first.a + 1, first.b)
        assert.are.equal(first.a + 1, first.a2)
    end)

    it("removes only the probe that raised, logging its first error once", function()
        local h = support.loadEval()
        h.env.require("protocol").limits.probes = 2
        support.eval(h, counter("good"))
        local _, body =
            support.eval(h, "Event.Logic.Subscribe('bad', function() error('kaput') end)")
        local errors = {}
        for _, p in ipairs(evalLogs(body)) do
            if p.level == "error" then errors[#errors + 1] = p end
        end
        assert.are.equal(1, #errors)
        assert.are.same({ "dev-bridge", "error", "eval" }, {
            errors[1].plugin,
            errors[1].level,
            errors[1].source,
        })
        assert.matches('Event.Logic "bad" removed after an error: eval:1: kaput', errors[1].text)
        assert.is_true(#support.payloads(body, "Emit") > 0) -- good kept running
        h:advance(20 * 100)
        assert.are.equal(1, support.lines(h, '[BRIDGE] probe Event.Logic "bad"'))
        -- Its slot is free again.
        assert.is_true(support.eval(h, "Event.Logic.Subscribe('next', function() end)").ok)
    end)

    it("refuses a probe on an event the bridge doesn't subscribe to", function()
        local h = support.loadEval()
        -- A statement, so the error is placed at the snippet's line (as an expression the
        -- call is a tail call, and the error has no position).
        local draw = support.eval(h, "local x = Event.Draw.Subscribe('d', function() end)")
        assert.is_false(draw.ok)
        assert.matches(
            "^eval:1: Event.Draw is not probe%-able: it fires every rendered frame",
            draw.error
        )
        -- Probe-able before the fifth client abort; no longer subscribed at load.
        local server = support.eval(h, "local x = Event.ServerLogic.Subscribe('s', print)")
        assert.is_false(server.ok)
        assert.matches(
            "^eval:1: Event.ServerLogic is not probe%-able: not subscribed at load: a "
                .. "self%-reload from Logic with more subscriptions aborted the client",
            server.error
        )
        local nope = support.eval(h, "Event.Nope.Unsubscribe('d')")
        assert.is_false(nope.ok)
        assert.matches("Event.Nope is not probe%-able: no such event", nope.error)
    end)

    it("refuses a probe past the per-session cap, and Unsubscribe frees a slot", function()
        local h = support.loadEval()
        h.env.require("protocol").limits.probes = 2
        support.eval(h, "Event.Logic.Subscribe('a', function() end)")
        support.eval(h, "Event.ChatMessage.Subscribe('a', function() end)") -- another pair
        local r = support.eval(h, "Event.Logic.Subscribe('b', function() end)")
        assert.is_false(r.ok)
        assert.matches("at most 2 probes per bridge session", r.error)
        -- Replacing a live probe is no new one.
        assert.is_true(support.eval(h, "Event.Logic.Subscribe('a', function() end)").ok)
        support.eval(h, "Event.Logic.Unsubscribe('a')")
        assert.is_true(support.eval(h, "Event.Logic.Subscribe('b', function() end)").ok)
    end)

    it("refuses a self-disabling console command from a snippet as exec does", function()
        local h = support.loadEval()
        local r = support.eval(h, "ExecuteConsoleCommand('poff dev-bridge')")
        assert.is_false(r.ok)
        assert.matches("^refused: this would disable dev%-bridge", r.error)
        assert.are.same({ true }, { support.eval(h, "ExecuteConsoleCommand('plist')").ok })
        assert.are.same({ "plist" }, support.ran(h))
    end)

    it(
        "lets a snippet reload the bridge; its shutdown unsubscribes only the load-time names",
        function()
            local h = support.loadEval()
            h.onConsoleCommand = function(command)
                if command == "prl dev-bridge" then h:unload() end
            end
            support.eval(h, counter("count"))
            local calls = spyEvent(h)
            support.answer(h, {
                status = 200,
                body = support.line("r", "eval", "ExecuteConsoleCommand('prl dev-bridge')"),
            })
            assert.are.same({ "prl dev-bridge" }, support.ran(h))
            assert.are.same(loadTimeUnsubscribes(h), calls)
            assert.are.same({}, subNames(h, "Logic"))
            h:advance(20 * 30)
            assert.are.equal(0, #support.open(h)) -- stopped: no result, no further sync
        end
    )

    it("stops the probes when an internal error stops the bridge, without a client call", function()
        local h = support.loadEval()
        local hits = 0
        -- A bridge global, which the scratch env reads through to.
        h.instance.env.hit = function()
            hits = hits + 1
        end
        support.eval(h, "Event.Logic.Subscribe('count', function() hit() end)")
        local calls = spyEvent(h)
        h.env.require("protocol").refusal = function()
            error("boom")
        end
        support.answer(h, { status = 200, body = support.line("c", "exec", "plist") })
        assert.are.equal(1, support.lines(h, "[BRIDGE] stopped after an error"))
        local before = hits
        h:advance(20 * 10)
        assert.are.equal(before, hits)
        assert.are.same({}, calls)
        h:unload()
        assert.are.same(loadTimeUnsubscribes(h), calls)
    end)

    it("stops the bridge if a fan-out itself fails, rather than raising every tick", function()
        local h = support.loadEval()
        support.eval(h, "Event.Logic.Subscribe('p', function() end)")
        h.env.require("protocol").probeErrorText = function()
            error("broken")
        end
        support.eval(h, "Event.Logic.Subscribe('q', function() error('x') end)")
        assert.are.equal(1, support.lines(h, "[BRIDGE] stopped after an error"))
        h:advance(20 * 30)
        assert.are.equal(1, support.lines(h, "[BRIDGE] stopped after an error"))
    end)

    it("resets: clears probes and the scratch env, answers ok, with no reload", function()
        local h = support.loadEval()
        local first, session = h.instance, support.last(h).session
        support.eval(h, "x = 1")
        support.eval(h, counter("a"))
        local calls = spyEvent(h)
        local results, body = support.run(h, { { "r1", "reset", "" } })
        assert.are.same({ id = "r1", ok = true }, results.r1)
        assert.are.equal(1, support.lines(h, "[BRIDGE] reset r1: probes and scratch env cleared"))
        support.answer(h) -- the sync that carried the result, and the emits before the reset
        h:advance(20 * 10)
        assert.are.same({}, support.payloads(support.last(h), "Emit"))
        assert.are.same({}, support.ran(h)) -- no prl
        assert.are.same({}, calls)
        assert.are.equal(first, h.instance)
        assert.are.equal(session, body.session)
        local after = support.eval(h, "rawget(_G, 'x')")
        assert.are.same({ 1, {} }, { after.nvalues, after.values })
        -- A cleared probe's name, and its slot, are free again.
        h.env.require("protocol").limits.probes = 1
        assert.is_true(support.eval(h, counter("a")).ok)
    end)

    it("unsubscribes the load-time names on shutdown even if one raises", function()
        local h = support.loadEval()
        support.eval(h, counter("count"))
        local env = h.instance.env
        local real = env.Event
        local logic = setmetatable({
            Unsubscribe = function(name)
                if name == "devBridgeLogic" then error("unsubscribe failed") end
                return real.Logic.Unsubscribe(name)
            end,
        }, { __index = real.Logic })
        env.Event = setmetatable({ Logic = logic }, { __index = real })
        h:unload()
        env.Event = real
        assert.are.same({ "devBridgeLogic" }, subNames(h, "Logic"))
        assert.are.same({}, subNames(h, "VarTransmit")) -- the rest still went
    end)

    it("starts a fresh scratch env after a reload", function()
        local h = support.loadEval()
        support.eval(h, "x = 1")
        h:reload()
        h:step()
        assert.are.same({ 1 }, { support.eval(h, "rawget(_G, 'x')").nvalues })
        assert.matches('"values":%[null%]', support.lastRaw(h))
    end)
end)

describe("dev-bridge Log events", function()
    it("sends each line the bridge logs as a Log event with no source", function()
        local h = support.load()
        h:step()
        local body = support.last(h)
        local logs = support.payloads(body, "Log")
        assert.are.same({
            plugin = "dev-bridge",
            level = "log",
            text = "enabled, session " .. body.session,
        }, logs[1])
        assert.are.equal(1, support.lines(h, "[BRIDGE] enabled, session " .. body.session))
    end)
end)
