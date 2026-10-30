-- Smoke and upload-policy specs for plugins/var-dump.
--
-- The harness models formatStr but not id.VarPlayer / id.VarClient iteration (the id namespace
-- in tests/harness/api/ui.lua has no such tables), and it faults on the plugin's read of them
-- even under the plugin's own pcall. So the granted-path specs wrap sandbox.build to give the
-- plugin plain-table stand-ins for those two (`loadGranted`). They test the upload policy
-- after the listing; how the real client lists vars, and the snapshot contents, are not tested.

local harness = require("tests.harness")
local sandbox = require("tests.harness.sandbox")

local SINK = "http://127.0.0.1:8765" -- var-dump's plugin.json "sink" url
local SERVER_TICK_MS = 600

-- Load var-dump with httpAccess granted and `id.VarPlayer` / `id.VarClient` replaced by small
-- tables. The wrap is undone before returning.
local function loadGranted()
    local build = sandbox.build
    ---@diagnostic disable-next-line: duplicate-set-field -- a deliberate wrap, undone below
    sandbox.build = function(...)
        local env = build(...)
        env.id =
            { VarPlayer = { ABSYSTEM = 5264 }, VarClient = { ACC_CREATE_LAST_RECOMMENDATION = 1 } }
        return env
    end
    local h = harness.new("var-dump", { grant = { "httpAccess" } })
    -- A var's first change has no old value to read, which the harness faults on, so give it
    -- one before the plugin starts.
    h.world:setVar("VarPlayer", "ABSYSTEM", 0)
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
        for _ = 1, 4 do
            h:answerAll(SINK .. "/changes", { status = 500 })
            h:advance(SERVER_TICK_MS)
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

    it("drops the oldest queued bodies past the bound and says how many", function()
        -- 105 changes: the first is in flight, 104 queue, and 4 are past the bound of 100.
        local h = loadSettled()
        for i = 1, 105 do
            change(h, i)
        end
        h:answerAll(SINK .. "/changes")
        h:advance(SERVER_TICK_MS)
        assert.are.equal(1, consoleLines(h, "dropped 4 queued /changes uploads (4 changes)"))
    end)

    it("cancels the request in flight on shutdown", function()
        local h = loadSettled()
        change(h, 1)
        local n = #h.requests
        h:unload() -- faults if PluginShutdown left a subscription
        h:advance(SERVER_TICK_MS)
        assert.are.equal(n, #h.requests)
    end)
end)
