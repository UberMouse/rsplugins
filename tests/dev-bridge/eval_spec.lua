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

    it("unsubscribes a probe by the name the snippet gave it", function()
        local h = support.loadEval()
        support.eval(h, counter("count"))
        support.eval(h, "Event.Logic.Unsubscribe('count')")
        assert.are.same({ "devBridgeLogic" }, subNames(h, "Logic"))
    end)

    it("unsubscribes only the probe that raised, logging its first error once", function()
        local h = support.loadEval()
        support.eval(h, counter("good"))
        local _, body =
            support.eval(h, "Event.Logic.Subscribe('bad', function() error('kaput') end)")
        assert.are.same({ "devBridgeLogic", "devBridgeEval_good" }, subNames(h, "Logic"))
        local errors = {}
        for _, p in ipairs(evalLogs(body)) do
            if p.level == "error" then errors[#errors + 1] = p.text end
        end
        assert.are.equal(1, #errors)
        assert.matches('Event.Logic "bad" unsubscribed after an error: eval:1: kaput', errors[1])
        assert.are.equal(1, support.lines(h, '[BRIDGE] probe Event.Logic "bad"'))
        assert.is_true(#support.payloads(body, "Emit") > 0) -- good kept running
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
            if command == "prl dev-bridge" then h.instance.env.PluginShutdown() end
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

    it("resets: probes unsubscribed, a fresh scratch env, ok with no values", function()
        local h = support.loadEval()
        support.eval(h, "x = 1")
        support.eval(h, counter("a"))
        support.eval(h, "Event.ServerLogic.Subscribe('b', function() end)")
        local results = support.run(h, { { "r1", "reset", "" }, { "r2", "reset", "" } })
        assert.are.same({ id = "r1", ok = true }, results.r1)
        assert.are.same({ id = "r2", ok = true }, results.r2) -- with no probes left
        assert.are.same({ "devBridgeLogic" }, subNames(h, "Logic"))
        assert.are.same({}, subNames(h, "ServerLogic"))
        local after = support.eval(h, "rawget(_G, 'x')")
        assert.are.same({ 1, {} }, { after.nvalues, after.values })
        assert.matches('"values":%[null%]', support.lastRaw(h))
    end)

    it("unsubscribes the probes on shutdown, and a later probe call is harmless", function()
        local h = support.loadEval()
        support.eval(h, counter("count"))
        local probe = h.instance.subs.Logic[2].fn
        h:unload()
        assert.are.same({}, subNames(h, "Logic"))
        probe({ logicTick = 1 }) -- as if the client delivered one more during teardown
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
