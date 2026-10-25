-- plugins/dev-bridge's eval (eval.lua) against the harness, with the sandbox's `load`: running
-- snippets, their values and output, the scratch env, emit, probes, the console proxy, reset
-- and shutdown. The caps' arithmetic is in protocol_spec.lua.

local support = require("tests.dev-bridge.support")

-- The probes' and the bridge's subscription names on `event`, in order.
local function subNames(h, event)
    local names = {}
    for i, entry in ipairs(h.instance.subs[event]) do
        names[i] = entry.name
    end
    return names
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

    it("installs a probe under a prefixed name that reports through emit", function()
        local h = support.loadEval()
        local _, body = support.eval(h, counter("Logic"))
        assert.are.same({ "devBridgeLogic", "devBridgeEval_Logic" }, subNames(h, "Logic"))
        local counts = {}
        for i, p in ipairs(support.payloads(body, "Emit")) do
            counts[i] = p.value
        end
        assert.is_true(#counts >= 5)
        assert.are.same({ 1, 2, 3 }, { counts[1], counts[2], counts[3] })
        -- The bridge's own Logic still syncs, and the probe can't take over its name.
        support.eval(h, counter("devBridgeLogic"))
        assert.are.same(
            { "devBridgeLogic", "devBridgeEval_Logic", "devBridgeEval_devBridgeLogic" },
            subNames(h, "Logic")
        )
    end)

    it("streams a probe's print as a Log event, source eval, and writes the console", function()
        local h = support.loadEval()
        support.eval(h, "Event.ServerLogic.Subscribe('p', function() print('server', 1) end)")
        h:advance(20 * 30)
        support.answer(h)
        h:advance(20 * 10)
        local logs = evalLogs(support.last(h))
        assert.is_true(#logs >= 1)
        assert.are.same(
            { plugin = "dev-bridge", level = "print", text = "server 1", source = "eval" },
            logs[1]
        )
        assert.is_true(support.lines(h, "server 1") >= 1)
    end)

    it("disarms a probe on Unsubscribe, keeping its one real subscription", function()
        local h = support.loadEval()
        support.eval(h, counter("count"))
        support.eval(h, "Event.Logic.Unsubscribe('count') Event.Logic.Unsubscribe('nope')")
        assert.are.same({ "devBridgeLogic", "devBridgeEval_count" }, subNames(h, "Logic"))
        support.answer(h)
        h:advance(20 * 10)
        assert.are.same({}, support.payloads(support.last(h), "Emit"))
        assert.is_nil(h.instance.subs.Logic[2].fn({ logicTick = 1 })) -- a no-op, returning nothing
    end)

    it("disarms only the probe that raised, logging its first error once", function()
        local h = support.loadEval()
        support.eval(h, counter("good"))
        local _, body =
            support.eval(h, "Event.Logic.Subscribe('bad', function() error('kaput') end)")
        assert.are.same(
            { "devBridgeLogic", "devBridgeEval_good", "devBridgeEval_bad" },
            subNames(h, "Logic")
        )
        local errors = {}
        for _, p in ipairs(evalLogs(body)) do
            if p.level == "error" then errors[#errors + 1] = p.text end
        end
        assert.are.equal(1, #errors)
        assert.matches('Event.Logic "bad" disarmed after an error: eval:1: kaput', errors[1])
        assert.is_true(#support.payloads(body, "Emit") > 0) -- good kept running
        h:advance(20 * 100) -- later ticks call bad's wrapper, which does nothing
        assert.are.equal(1, support.lines(h, '[BRIDGE] probe Event.Logic "bad"'))
    end)

    it("re-arms a disarmed probe on re-subscribe, without a second real Subscribe", function()
        local h = support.loadEval()
        local env = h.instance.env
        local real = env.Event
        local subscribes = 0
        local logic = setmetatable({
            Subscribe = function(name, fn)
                subscribes = subscribes + 1
                return real.Logic.Subscribe(name, fn)
            end,
        }, { __index = real.Logic })
        env.Event = setmetatable({ Logic = logic }, { __index = real })
        support.eval(h, "Event.Logic.Subscribe('p', function() error('first') end)")
        local _, body = support.eval(h, "Event.Logic.Subscribe('p', function() emit('p', 2) end)")
        assert.are.equal(1, subscribes)
        assert.are.same({ "devBridgeLogic", "devBridgeEval_p" }, subNames(h, "Logic"))
        assert.are.same({ tag = "p", value = 2 }, support.payloads(body, "Emit")[1])
    end)

    it("refuses a probe past the per-session cap, naming it and eval --reset", function()
        local h = support.loadEval()
        h.env.require("protocol").limits.probes = 2
        support.eval(h, "Event.Logic.Subscribe('a', function() end)")
        support.eval(h, "Event.ServerLogic.Subscribe('a', function() end)") -- another pair
        support.eval(h, "Event.Logic.Unsubscribe('a')") -- disarmed still counts
        local r = support.eval(h, "Event.Logic.Subscribe('b', function() end)")
        assert.is_false(r.ok)
        assert.matches("at most 2 probes per bridge session", r.error)
        assert.matches("eval %-%-reset", r.error)
        -- Re-arming an existing pair is no new probe.
        assert.is_true(support.eval(h, "Event.Logic.Subscribe('a', function() end)").ok)
    end)

    it("refuses a self-disabling console command from a snippet as exec does", function()
        local h = support.loadEval()
        local r = support.eval(h, "ExecuteConsoleCommand('poff dev-bridge')")
        assert.is_false(r.ok)
        assert.matches("^refused: this would disable dev%-bridge", r.error)
        assert.are.same({ true }, { support.eval(h, "ExecuteConsoleCommand('plist')").ok })
        assert.are.same({ "plist" }, support.ran(h))
    end)

    it("lets a snippet reload the bridge, whose shutdown removes its probes", function()
        local h = support.loadEval()
        h.onConsoleCommand = function(command)
            if command == "prl dev-bridge" then h:unload() end
        end
        support.eval(h, counter("count"))
        support.answer(h, {
            status = 200,
            body = support.line("r", "eval", "ExecuteConsoleCommand('prl dev-bridge')"),
        })
        assert.are.same({ "prl dev-bridge" }, support.ran(h))
        assert.are.same({}, subNames(h, "Logic"))
        h:advance(20 * 30)
        assert.are.equal(0, #support.open(h)) -- stopped: no result, no further sync
    end)

    it("stops a probe when an internal error stops the bridge, without unsubscribing", function()
        local h = support.loadEval()
        local hits = 0
        -- A bridge global, which the scratch env reads through to.
        h.instance.env.hit = function()
            hits = hits + 1
        end
        support.eval(h, "Event.Logic.Subscribe('count', function() hit() end)")
        h.env.require("protocol").refusal = function()
            error("boom")
        end
        support.answer(h, { status = 200, body = support.line("c", "exec", "plist") })
        assert.are.equal(1, support.lines(h, "[BRIDGE] stopped after an error"))
        assert.are.same({ "devBridgeLogic", "devBridgeEval_count" }, subNames(h, "Logic"))
        local before = hits
        h:advance(20 * 10)
        assert.are.equal(before, hits)
        h:unload()
        assert.are.same({}, subNames(h, "Logic"))
    end)

    it("resets: ok, then once that result has synced, reloads the bridge", function()
        local h = support.loadEval()
        h.onConsoleCommand = function(command)
            if command == "prl dev-bridge" then h:reload() end
        end
        local first = h.instance
        support.eval(h, "x = 1")
        support.eval(h, counter("a"))
        support.answer(h, { status = 200, body = support.line("r1", "reset", "") })
        h:advance(20 * 10) -- the reset ran; the sync carrying its result starts
        assert.are.same({ { id = "r1", ok = true } }, support.last(h).results)
        assert.are.same({}, support.ran(h)) -- not before that sync succeeded
        support.answer(h) -- it succeeds on this tick...
        assert.are.same({}, support.ran(h))
        assert.are.equal(first, h.instance)
        h:step() -- ...and the reload comes on the next
        assert.are.same({ "prl dev-bridge" }, { h.consoleCommands[4] })
        assert.are_not.equal(first, h.instance)
        assert.are.same({ "devBridgeLogic" }, subNames(h, "Logic"))
        h:step()
        local after = support.eval(h, "rawget(_G, 'x')")
        assert.are.same({ 1, {} }, { after.nvalues, after.values })
    end)

    it("disarms the probes at once on reset", function()
        local h = support.loadEval()
        support.eval(h, counter("a"))
        support.answer(h, { status = 200, body = support.line("r1", "reset", "") })
        h:advance(20 * 10)
        support.answer(h) -- the sync that carried the reset's result, and earlier emits
        h:advance(20 * 10)
        assert.are.same({}, support.payloads(support.last(h), "Emit"))
    end)

    it("waits for a failed sync carrying the reset's result to be retried", function()
        local h = support.loadEval()
        support.answer(h, { status = 200, body = support.line("r1", "reset", "") })
        h:advance(20 * 10)
        support.answer(h, { status = 500 })
        h:advance(20 * 100)
        assert.are.same({}, support.ran(h))
        h:advance(20 * 150) -- the retry, with the result again
        assert.are.same({ { id = "r1", ok = true } }, support.last(h).results)
        support.answer(h)
        h:step()
        assert.are.same({ "prl dev-bridge" }, support.ran(h))
    end)

    it("turns away commands that arrive while a reset's reload is pending", function()
        local h = support.loadEval()
        support.answer(h, {
            status = 200,
            body = support.line("r1", "reset", "") .. support.line("e1", "eval", "1"),
        })
        h:advance(20 * 10)
        local results = support.last(h).results
        assert.are.same({ id = "r1", ok = true }, results[1])
        assert.are.same({
            id = "e1",
            ok = false,
            error = "not run: the bridge is reloading for reset r1; send it again once it reconnects",
        }, results[2])
        -- One more arrives with the sync that delivers the reset: its result goes first.
        support.answer(h, { status = 200, body = support.line("x1", "exec", "plist") })
        h:advance(20 * 10)
        assert.are.same({}, support.ran(h))
        assert.are.equal("x1", support.last(h).results[1].id)
        support.answer(h)
        h:step()
        assert.are.same({ "prl dev-bridge" }, support.ran(h))
    end)

    it("unsubscribes every real probe subscription on shutdown, disarmed ones too", function()
        local h = support.loadEval()
        support.eval(h, counter("count"))
        support.eval(h, "Event.ServerLogic.Subscribe('s', function() end)")
        support.eval(h, "Event.Logic.Unsubscribe('count')")
        local probe = h.instance.subs.Logic[2].fn
        h:unload()
        assert.are.same({}, subNames(h, "Logic"))
        assert.are.same({}, subNames(h, "ServerLogic"))
        probe({ logicTick = 1 }) -- as if the client delivered one more during teardown
    end)

    it("removes the probes on shutdown even if the bridge's own unsubscribe raises", function()
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
