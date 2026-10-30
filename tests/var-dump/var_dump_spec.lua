-- Smoke and upload-policy specs for plugins/var-dump. The harness has no id.VarPlayer /
-- id.VarClient iteration and faults on the plugin's read even under pcall, so the granted-path
-- specs (loadGranted) wrap sandbox.build to supply plain-table stand-ins. They only get start()
-- running for the transport specs: the stand-ins put the ID in the value slot, which the real
-- client does not (docs/api-concepts.md), so listing and snapshot contents are untested. The
-- harness does model formatStr.

local harness = require("tests.harness")
local sandbox = require("tests.harness.sandbox")

local SINK = "http://127.0.0.1:8765" -- var-dump's plugin.json "sink" url
local SERVER_TICK_MS = 600
local RETRY_TICKS = 8 -- var-dump's RETRY_TICKS
local NO_REPLY = { timedOut = true } -- a failure with no HTTP status

-- Load var-dump with httpAccess granted and `id.VarPlayer` / `id.VarClient` replaced by small
-- plain tables. The wrap is undone before returning, even if the load raises.
local function loadGranted()
    local h = harness.new("var-dump", { grant = { "httpAccess" } })
    -- A var's first change has no old value to read, which the harness faults on, so give it
    -- one before the plugin starts. Done before the wrap so a fault here can't leave it set.
    h.world:setVar("VarPlayer", "ABSYSTEM", 0)
    local build = sandbox.build
    ---@diagnostic disable-next-line: duplicate-set-field -- a deliberate wrap, undone below
    sandbox.build = function(...)
        local env = build(...)
        env.id =
            { VarPlayer = { ABSYSTEM = 5264 }, VarClient = { ACC_CREATE_LAST_RECOMMENDATION = 1 } }
        return env
    end
    local ok, err = pcall(h.load, h)
    sandbox.build = build
    assert(ok, err)
    return h
end

-- A loaded plugin whose snapshot has been sent and answered, so only /changes remains.
local function loadSettled()
    local h = loadGranted()
    h:advance(200)
    h:answerAll(SINK .. "/snapshot")
    h:advance(100)
    return h
end

-- Change a var and let one server tick pass.
local function change(h, value)
    h.world:setVar("VarPlayer", "ABSYSTEM", value)
    h:advance(SERVER_TICK_MS)
end

-- Let `n` server ticks pass.
local function ticks(h, n)
    h:advance(n * SERVER_TICK_MS)
end

local function consoleLines(h, needle)
    local n = 0
    for _, line in ipairs(h.console) do
        if line.text:find(needle, 1, true) then n = n + 1 end
    end
    return n
end

describe("plugins/var-dump without httpAccess", function()
    it("loads its json module, says how to grant access and sends nothing", function()
        local h = harness.load("var-dump")
        assert.are.equal(
            "[VARDUMP] waiting for httpAccess: run `ppr var-dump`, then `ppe var-dump httpAccess`",
            h:output()
        )
        h:advance(1200)
        assert.are.equal(0, #h.requests)
    end)

    it("is reloadable", function()
        local h = harness.load("var-dump")
        h:reload() -- faults if the old instance kept a subscription
        assert.are.equal(2, #h.console)
    end)
end)

describe("plugins/var-dump /changes uploads", function()
    it("keeps one request in flight and sends the rest after it completes", function()
        local h = loadSettled()
        change(h, 1)
        change(h, 2)
        change(h, 3)
        assert.are.equal(1, #h:requestsTo(SINK .. "/changes"))
        h:answerAll(SINK .. "/changes")
        h:advance(SERVER_TICK_MS)
        -- The two queued bodies go out one at a time.
        assert.are.equal(2, #h:requestsTo(SINK .. "/changes"))
        h:answerAll(SINK .. "/changes")
        h:advance(SERVER_TICK_MS)
        assert.are.equal(3, #h:requestsTo(SINK .. "/changes"))
    end)

    it("warns once per outage, then once on recovery, and keeps the failed changes", function()
        local h = loadSettled()
        change(h, 1)
        for _ = 1, 3 do
            h:answerAll(SINK .. "/changes", NO_REPLY)
            ticks(h, RETRY_TICKS)
        end
        assert.are.equal(1, consoleLines(h, "failed:"))
        assert.are.equal(0, consoleLines(h, "recovered"))
        h:answerAll(SINK .. "/changes")
        h:advance(SERVER_TICK_MS)
        assert.are.equal(1, consoleLines(h, "failed:"))
        assert.are.equal(1, consoleLines(h, "recovered"))
        -- The body that kept failing is the one that finally got through.
        local sent = h:requestsTo(SINK .. "/changes")
        assert.are.equal(sent[1].body, sent[#sent].body)
    end)

    it("drops a body the receiver answered with a non-200 and sends the next", function()
        local h = loadSettled()
        change(h, 1)
        change(h, 2)
        local sent = h:requestsTo(SINK .. "/changes")
        assert.are.equal(1, #sent)
        h:answerAll(SINK .. "/changes", { status = 400 })
        ticks(h, RETRY_TICKS)
        local after = h:requestsTo(SINK .. "/changes")
        assert.are.equal(2, #after)
        assert.are_not.equal(sent[1].body, after[2].body)
        -- Counted as dropped, reported once uploads succeed.
        h:answerAll(SINK .. "/changes")
        h:advance(SERVER_TICK_MS)
        assert.are.equal(
            1,
            consoleLines(h, "dropped 1 /changes uploads (1 changes) the receiver never took")
        )
    end)

    it("resends a body that got no reply, ahead of newer ones", function()
        local h = loadSettled()
        change(h, 1)
        change(h, 2)
        h:answerAll(SINK .. "/changes", NO_REPLY)
        ticks(h, RETRY_TICKS)
        local sent = h:requestsTo(SINK .. "/changes")
        assert.are.equal(2, #sent)
        assert.are.equal(sent[1].body, sent[2].body)
        assert.are.equal(0, consoleLines(h, "dropped"))
    end)

    it("starts no /changes request for RETRY_TICKS ticks after a failure", function()
        local h = loadSettled()
        change(h, 1)
        h:answerAll(SINK .. "/changes", NO_REPLY)
        ticks(h, RETRY_TICKS - 1)
        assert.are.equal(1, #h:requestsTo(SINK .. "/changes"))
        ticks(h, 1)
        assert.are.equal(2, #h:requestsTo(SINK .. "/changes"))
    end)

    it("drops the oldest queued bodies past the bound and says how many", function()
        -- 105 changes: the first is in flight, 104 queue, and 4 are past the bound of 100.
        local h = loadSettled()
        for i = 1, 105 do
            change(h, i)
        end
        h:answerAll(SINK .. "/changes")
        h:advance(SERVER_TICK_MS)
        assert.are.equal(
            1,
            consoleLines(h, "dropped 4 /changes uploads (4 changes) the receiver never took")
        )
    end)

    it("cancels the request in flight on shutdown", function()
        local h = loadSettled()
        change(h, 1)
        local n = #h.requests
        local inFlight = h:requestsTo(SINK .. "/changes")[1]
        h:unload() -- faults if PluginShutdown left a subscription
        h:advance(SERVER_TICK_MS)
        assert.are.equal(n, #h.requests)
        assert.is_true(inFlight.request.cancelled)
    end)

    it("reports unreported drops on shutdown", function()
        local h = loadSettled()
        for i = 1, 105 do
            change(h, i)
        end
        assert.are.equal(0, consoleLines(h, "dropped"))
        h:unload()
        assert.are.equal(
            1,
            consoleLines(h, "dropped 4 /changes uploads (4 changes) the receiver never took")
        )
    end)

    it("never queues past the bound when a failed body is requeued", function()
        -- One in flight plus 100 queued: the failed body has no room to come back.
        local h = loadSettled()
        for i = 1, 101 do
            change(h, i)
        end
        h:answerAll(SINK .. "/changes", NO_REPLY)
        ticks(h, RETRY_TICKS)
        h:answerAll(SINK .. "/changes")
        h:advance(SERVER_TICK_MS)
        assert.are.equal(
            1,
            consoleLines(h, "dropped 1 /changes uploads (1 changes) the receiver never took")
        )
    end)

    it("reports a drop once, not again on later successes", function()
        local h = loadSettled()
        for i = 1, 105 do
            change(h, i)
        end
        for _ = 1, 3 do
            h:answerAll(SINK .. "/changes")
            h:advance(SERVER_TICK_MS)
        end
        assert.are.equal(1, consoleLines(h, "dropped"))
    end)

    it("warns again for a second outage after a recovery", function()
        local h = loadSettled()
        change(h, 1)
        for round = 1, 2 do
            h:answerAll(SINK .. "/changes", NO_REPLY)
            ticks(h, RETRY_TICKS)
            h:answerAll(SINK .. "/changes")
            h:advance(SERVER_TICK_MS)
            change(h, 100 + round)
        end
        assert.are.equal(2, consoleLines(h, "failed:"))
        assert.are.equal(2, consoleLines(h, "recovered"))
    end)
end)

describe("plugins/var-dump snapshot upload", function()
    it("says it gave up even when the outage warning was already used", function()
        local h = loadGranted()
        h:advance(200) -- the snapshot's one part is sent
        change(h, 1)
        h:answerAll(SINK .. "/changes", { status = 500 }) -- the warn-once is spent here
        h:answerAll(SINK .. "/snapshot", { status = 500 })
        h:advance(SERVER_TICK_MS)
        assert.are.equal(1, consoleLines(h, "failed:"))
        assert.are.equal(1, consoleLines(h, "snapshot upload abandoned"))
    end)
end)
