-- The dev log tee (lib/dev/tee.lua) with small inline plugins: capture of print/log, callback
-- errors, batching and retries, the no-op paths and coexistence with the recorder.

local harness = require("tests.harness")
local support = require("tests.tee.support")

-- A loaded plugin that starts with the tee installed and httpAccess granted.
---@param main string
---@param opts table?
---@return table h
local function loaded(main, opts)
    local h =
        harness.new(support.plugin(support.INSTALL .. main), opts or { grant = { "httpAccess" } })
    h:load()
    return h
end

-- The plugin's subscription `name` to `event`, as the client holds it (the tee's wrapper).
---@param h table
---@param event string
---@param name string
---@return function
local function callback(h, event, name)
    for _, entry in ipairs(h.instance.subs[event]) do
        if entry.name == name then return entry.fn end
    end
    error("no subscription " .. name)
end

-- Step until the tee has made `count` requests, at most `max` steps. Returns the steps taken.
---@param h table
---@param count integer
---@param max integer
---@return integer
local function stepsUntilPosts(h, count, max)
    for n = 1, max do
        h:step()
        if #support.posts(h) >= count then return n end
    end
    error("no request #" .. count .. " within " .. max .. " steps")
end

describe("dev tee", function()
    describe("console output", function()
        it("sends print and log lines, which still reach the console", function()
            local h = loaded('print("a", 1)\nlog("b", nil)')
            assert.are.equal(0, #support.posts(h)) -- nothing is sent outside Logic
            h:step()
            assert.are.same({ "a 1", "b nil" }, support.batchTexts(h))
            local lines = support.batchLines(h)
            assert.are.same({ "print", "log" }, { lines[1].level, lines[2].level })
            assert.is_not_nil(h:output():find("a 1\nb nil", 1, true))
        end)

        it("queues a line whose argument has a failing tostring", function()
            -- The real print is replaced first: the harness's own would raise on the argument.
            local h = harness.new(
                support.plugin("print = function() end\n" .. support.INSTALL),
                { grant = { "httpAccess" } }
            )
            h:load()
            local bad = setmetatable({}, {
                __tostring = function()
                    error("no text")
                end,
            })
            h.env.print("x", bad)
            h:step()
            assert.are.same({ "x <a table that tostring() fails on>" }, support.batchTexts(h))
        end)

        it("stamps each line with the Logic tick since install", function()
            local h = loaded("Event.Logic.Subscribe('p', function() end)")
            h:advance(100) -- 5 ticks
            h.env.print("late")
            h:step()
            assert.are.equal(5, support.batchLines(h)[1].t)
        end)

        it("cuts a long line", function()
            local h = loaded('print(string.rep("x", 5000))')
            h:step()
            assert.are.equal(
                h.env.require("dev/teelog").MAX_TEXT + #"...[cut]",
                #support.batchTexts(h)[1]
            )
        end)

        it("does not queue its own console lines", function()
            local h = loaded("")
            h:step()
            assert.are.same({}, support.posts(h))
            assert.are.equal(1, h:consoleCount("[TEE] sending"))
        end)
    end)

    describe("without the utf8 library", function()
        it("is not there, and a print with non-ASCII text still reaches a POST", function()
            local h = loaded('HAS_UTF8 = rawget(_G, "utf8") ~= nil\nprint("caf\195\169 \255")')
            assert.is_false(h.env.HAS_UTF8)
            h:step()
            assert.are.same({ "caf\195\169 \255" }, support.batchTexts(h))
        end)
    end)

    describe("shutdown", function()
        local function logicNames(h)
            local names = {}
            for i, entry in ipairs(h.instance.subs.Logic) do
                names[i] = entry.name
            end
            return names
        end

        it("unsubscribes the flush", function()
            local h = loaded("Event.Logic.Subscribe('mine', function() end)")
            assert.are.same({ "devTeeFlush", "mine" }, logicNames(h))
            h.env.require("dev/tee").shutdown()
            assert.are.same({ "mine" }, logicNames(h))
        end)

        it("cancels a request in flight", function()
            local h = loaded('print("a")')
            h:step()
            assert.are.equal(1, #support.posts(h))
            h.env.require("dev/tee").shutdown()
            assert.is_true(support.posts(h)[1].request.cancelled)
        end)

        it("is safe twice and starts nothing afterwards", function()
            local h = loaded("")
            local tee = h.env.require("dev/tee")
            tee.shutdown()
            tee.shutdown()
            h.env.print("late")
            h:advance(5000)
            assert.are.equal(0, #support.posts(h))
        end)

        it("does nothing when install did not install", function()
            local h = loaded("", { grant = {} })
            h.env.require("dev/tee").shutdown()
            h:advance(100)
            assert.are.equal(0, #h.requests)
        end)
    end)

    describe("callback errors", function()
        it("ships the error and raises the original value again", function()
            local h = loaded([[
                E = { code = 7 }
                Event.VarTransmit.Subscribe("tbl", function() error(E) end)
                F = function() error("plain") end
                Event.VarTransmit.Subscribe("str", F)
            ]])
            local _, expected = pcall(h.env.F)
            local ok, err = pcall(callback(h, "VarTransmit", "tbl"))
            assert.is_false(ok)
            assert.is_true(rawequal(h.env.E, err))
            ok, err = pcall(callback(h, "VarTransmit", "str"))
            assert.is_false(ok)
            assert.are.equal(expected, err) -- the same text: no second position added
            h:step()
            local lines = support.batchLines(h)
            assert.are.equal("error", lines[1].level)
            assert.is_not_nil(
                lines[1].text:find("Event.VarTransmit subscriber 'tbl': table:", 1, true)
            )
            assert.are.equal("Event.VarTransmit subscriber 'str': " .. expected, lines[2].text)
        end)

        it("passes return values through", function()
            local h = loaded([[
                Event.VarTransmit.Subscribe("ret", function(...) return 42, nil, ... end)
            ]])
            local results = table.pack(callback(h, "VarTransmit", "ret")("x"))
            assert.are.equal(3, results.n)
            assert.are.same({ 42, "x" }, { results[1], results[3] })
            assert.is_nil(results[2])
        end)

        it("leaves a callback that works alone", function()
            local h = loaded([[
                T = { n = 0 }
                Event.Logic.Subscribe("n", function() T.n = T.n + 1 end)
            ]])
            h:advance(100)
            assert.are.equal(5, h.env.T.n)
            assert.are.same({}, support.posts(h))
        end)
    end)

    describe("Subscribe and Unsubscribe", function()
        it("go to the real API: a direct Unsubscribe removes the subscription", function()
            local h = loaded([[
                Event.Logic.Subscribe("gone", function() ran = true end)
                Event.Logic.Unsubscribe("gone")
            ]])
            h:advance(60)
            assert.is_nil(rawget(h.env, "ran"))
        end)

        it("leave the API's own checks to the API", function()
            local err = harness.errorOf(function()
                loaded("Event.Logic.Subscribe(1, 2)")
            end)
            assert.is_not_nil(err:find("Subscribe(name: string", 1, true))
        end)
    end)

    describe("batches", function()
        it("sends the daemon's schema", function()
            local h = loaded('print("x")')
            h:step()
            local record = support.posts(h)[1]
            assert.are.equal("application/json", record.headers["Content-Type"])
            local batch = support.batches(h)[1]
            assert.are.equal(1, batch.schema)
            assert.are.equal("t", batch.plugin)
            assert.is_not_nil(batch.session:match("^%w[%w._-]*$"))
            assert.is_true(#batch.session <= 64)
            assert.are.equal("integer", math.type(batch.seq))
            assert.are.equal(1, batch.seq)
            assert.are.equal(0, batch.dropped)
            for _, line in ipairs(batch.lines) do
                assert.are.equal("integer", math.type(line.t))
                assert.is_not_nil(({ print = 1, log = 1, error = 1 })[line.level])
                assert.are.equal("string", type(line.text))
            end
        end)

        it("posts only from Logic and keeps one request in flight", function()
            local h = loaded('print("a")')
            assert.are.equal(0, #support.posts(h))
            h:step()
            assert.are.equal(1, #support.posts(h))
            h.env.print("b")
            h:advance(5000) -- unanswered: no second request
            assert.are.equal(1, #support.posts(h))
            support.answer(h)
            h:advance(2000)
            assert.are.equal(2, #support.posts(h))
            assert.are.same({ "a", "b" }, support.batchTexts(h))
            assert.are.equal(2, support.batches(h)[2].seq)
        end)

        it("sends nothing while idle", function()
            local h = loaded("")
            h:advance(5000)
            assert.are.equal(0, #support.posts(h))
        end)

        it("keeps the newest lines when the queue is full and reports the loss", function()
            local h = loaded("")
            h.env.require("dev/tee").limits.bufferLines = 3
            for i = 1, 5 do
                h.env.print("n" .. i)
            end
            h:step()
            assert.are.same({ "n3", "n4", "n5" }, support.batchTexts(h))
            assert.are.equal(2, support.batches(h)[1].dropped)
        end)

        it("splits a backlog into batches within the limit", function()
            local h = loaded("")
            h.env.require("dev/tee").limits.batchLines = 2
            for i = 1, 5 do
                h.env.print("n" .. i)
            end
            h:step()
            support.answer(h)
            h:advance(2000)
            support.answer(h)
            h:advance(2000)
            local sizes = {}
            for i, batch in ipairs(support.batches(h)) do
                sizes[i] = #batch.lines
            end
            assert.are.same({ 2, 2, 1 }, sizes)
        end)
    end)

    describe("failures", function()
        -- Tight timings so a test is short: a retry waits 10 ticks, then 20, then 40.
        local function shrink(h)
            local limits = h.env.require("dev/tee").limits
            limits.postEveryTicks, limits.retryTicks, limits.maxRetryTicks = 1, 10, 40
        end

        it("keeps the lines and retries with a growing wait", function()
            local h = loaded('print("a")')
            shrink(h)
            h:step()
            support.answer(h, { error = "refused", errorCode = 7 })
            h:step() -- delivers the failure
            h.env.print("b") -- queued during the wait
            local first = stepsUntilPosts(h, 2, 30)
            assert(first >= 8 and first <= 11, "first retry after " .. first)
            support.answer(h, { error = "refused", errorCode = 7 })
            h:step()
            local second = stepsUntilPosts(h, 3, 60)
            assert(second >= 18 and second <= 21, "second retry after " .. second)
            local batches = support.batches(h)
            assert.are.same({ "a", "b" }, { batches[2].lines[1].text, batches[2].lines[2].text })
            assert.are.same({ 1, 2, 3 }, { batches[1].seq, batches[2].seq, batches[3].seq })
            assert.are.equal(1, h:consoleCount("POST failed")) -- one line per streak
        end)

        it("treats a non-200 reply as a failure to retry", function()
            local h = loaded('print("a")')
            shrink(h)
            h:step()
            support.answer(h, { status = 500 })
            h:step()
            stepsUntilPosts(h, 2, 30)
            assert.are.equal("a", support.batches(h)[2].lines[1].text)
        end)

        it("starts a new streak, and a new console line, after a success", function()
            local h = loaded('print("a")')
            shrink(h)
            h:step()
            support.answer(h, { error = "refused" })
            h:step()
            stepsUntilPosts(h, 2, 30)
            support.answer(h) -- success
            h:step()
            h.env.print("b")
            stepsUntilPosts(h, 3, 30)
            support.answer(h, { error = "refused" })
            h:step()
            assert.are.equal(2, h:consoleCount("POST failed"))
        end)

        it("drops a batch the daemon refuses with a 400, once", function()
            local h = loaded('print("bad")')
            shrink(h)
            h:step()
            support.answer(h, { status = 400 })
            h:step()
            h.env.print("next")
            stepsUntilPosts(h, 2, 30)
            local batch = support.batches(h)[2]
            assert.are.same({ "next" }, { batch.lines[1].text })
            assert.are.equal(1, #batch.lines)
            assert.are.equal(1, batch.dropped)
            assert.are.equal(1, h:consoleCount("refused a batch"))
        end)

        -- A plugin whose HTTPRequest fails as the test sets FAIL: "new" throws from new, "post"
        -- throws from Post.
        local FLAKY = [[
FAIL = false
local real = HTTPRequest
HTTPRequest = {
    new = function(...)
        if FAIL == "new" then error("no request") end
        local request = real.new(...)
        return {
            AddHeader = function(_, ...) request:AddHeader(...) end,
            Post = function(_, ...)
                if FAIL == "post" then error("no post") end
                request:Post(...)
            end,
        }
    end,
}
]]

        for _, mode in ipairs({ "new", "post" }) do
            it(
                "requeues the lines when HTTPRequest " .. mode .. " throws, and sends them later",
                function()
                    -- The tee takes HTTPRequest at install, so the stand-in goes in first.
                    local h = harness.new(
                        support.plugin(FLAKY .. support.INSTALL .. 'print("a")'),
                        { grant = { "httpAccess" } }
                    )
                    h:load()
                    shrink(h)
                    h.env.FAIL = mode
                    h:step()
                    assert.are.equal(0, #support.posts(h))
                    assert.are.equal(1, h:consoleCount("could not start a POST"))
                    h.env.print("b")
                    h.env.FAIL = false
                    stepsUntilPosts(h, 1, 30)
                    assert.are.same({ "a", "b" }, support.batchTexts(h))
                    assert.are.equal(1, h:consoleCount("could not start a POST"))
                    assert.are.equal(0, support.batches(h)[1].dropped)
                end
            )
        end

        it("drops the oldest of a backlog that outgrows the queue while it waits", function()
            local h = loaded('print("a")')
            shrink(h)
            h.env.require("dev/tee").limits.bufferLines = 2
            h:step()
            support.answer(h, { error = "refused" })
            h:step()
            h.env.print("b")
            h.env.print("c")
            stepsUntilPosts(h, 2, 30)
            local batch = support.batches(h)[2]
            assert.are.same({ "b", "c" }, { batch.lines[1].text, batch.lines[2].text })
            assert.are.equal(1, batch.dropped)
        end)
    end)

    describe("when it cannot run", function()
        it("installs with the opaque manifest url and never prints its text", function()
            -- The client's Plugin.urls values can't be concatenated; this raised live.
            local h = harness.new(support.plugin(support.INSTALL), { grant = { "httpAccess" } })
            h:load()
            assert.are.equal(1, h:consoleCount("[TEE] sending this plugin's console output"))
            assert.are.equal(0, h:consoleCount("127.0.0.1"))
        end)

        it("does nothing without urls.rsdev, after one console line", function()
            local h = harness.new(
                support.plugin(
                    support.INSTALL .. 'print("x")',
                    '{ "name": "T", "version": "0.0.1", "contactEmailAddress": "t@example.com",'
                        .. ' "optionalPermissions": [ "httpAccess" ] }'
                ),
                { grant = { "httpAccess" } }
            )
            h:load()
            h:advance(2000)
            assert.are.equal(0, #h.requests)
            assert.are.equal(1, h:consoleCount("[TEE] no urls.rsdev"))
            assert.are.equal(1, h:consoleCount("x"))
            assert.are.equal(0, #h.instance.subs.Logic)
        end)

        it("does nothing without httpAccess, even if it is granted later", function()
            local h = loaded('print("x")', { grant = {} })
            h:advance(500)
            assert.are.equal(1, h:consoleCount("[TEE] httpAccess not granted"))
            assert.are.equal(0, #h.instance.subs.Logic)
            h.world:grant("httpAccess")
            h.env.print("y")
            h:advance(2000)
            assert.are.equal(0, #h.requests)
            assert.are.same({ "x", "y" }, { h.console[2].text, h.console[3].text })
        end)

        it("installs once per enable", function()
            local h = loaded(support.INSTALL)
            assert.are.equal(1, #h.instance.subs.Logic)
        end)
    end)

    describe("with the recorder", function()
        local MANIFEST = [[{
            "name": "T", "version": "0.0.1", "contactEmailAddress": "t@example.com",
            "optionalPermissions": [ "httpAccess" ],
            "urls": { "rsdev": "http://127.0.0.1:8766", "recorder": "http://127.0.0.1:8766" }
        }]]

        -- Both modules first, then the tee, then the recorder (tee.lua's header).
        local MAIN = [[
            local tee = require("dev/tee")
            local recorder = require("dev/recorder")
            tee.install(_ENV, "t")
            recorder.install(_ENV, "t")
            Event.VarTransmit.Subscribe("v", function(ev)
                print("saw var")
                error("bad var")
            end)
        ]]

        it("keeps recording deliveries and keeps teeing console lines and errors", function()
            local h = harness.new(support.plugin(MAIN, MANIFEST), { grant = { "httpAccess" } })
            h.world:setVar("VarPlayer", "QP", 10)
            h:load()
            local ok = pcall(function()
                h.world:setVar("VarPlayer", "QP", 11)
            end)
            assert.is_false(ok) -- the callback's error still reaches the client
            h:advance(100)
            local texts = support.batchTexts(h)
            assert.are.equal("saw var", texts[1])
            assert.is_not_nil(texts[2]:find("Event.VarTransmit subscriber 'v': ", 1, true))
            assert.is_not_nil(texts[2]:find("bad var", 1, true))
            local recorded = {}
            for _, record in ipairs(h:requestsTo("http://127.0.0.1:8766/record")) do
                recorded[#recorded + 1] = record.body
            end
            assert.is_true(#recorded > 0)
            assert.is_not_nil(table.concat(recorded):find('"VarTransmit"', 1, true))
        end)
    end)
end)
