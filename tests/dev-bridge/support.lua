-- Shared helpers for the dev bridge's specs. Its modules require paths relative to the plugin
-- root (docs/plugin-anatomy.md), so the plugin root goes first on the module path; dev/ is
-- found through lib/ (.busted).

local harness = require("tests.harness")

local root = "./plugins/dev-bridge/?.lua;"
if package.path:sub(1, #root) ~= root then package.path = root .. package.path end

local M = {}

M.SYNC_URL = "http://127.0.0.1:8766/bridge/sync"

-- The globals the bridge reports in hello.env that the sandbox doesn't provide. Whether the
-- client has them is what the report is for; these specs model a client without them.
M.ABSENT = { "load", "loadstring", "debug", "os", "io" }
-- The same for the eval specs, which opt in to the sandbox's `load`, as the client has it.
M.ABSENT_WITH_LOAD = { "loadstring", "debug", "os", "io" }

-- plugins/dev-bridge, not yet loaded, with `grant` (default both of its permissions).
---@param grant string[]?
---@return table h
function M.new(grant)
    return harness.new(
        "dev-bridge",
        { grant = grant or { "httpAccess", "chatAccess" }, absent = M.ABSENT }
    )
end

-- M.new, loaded.
---@param grant string[]?
---@return table h
function M.load(grant)
    local h = M.new(grant)
    h:load()
    return h
end

-- plugins/dev-bridge with `load` (opts.stdlib), loaded, with the first sync started.
---@return table h
function M.loadEval()
    local h = harness.new("dev-bridge", {
        grant = { "httpAccess", "chatAccess" },
        absent = M.ABSENT_WITH_LOAD,
        stdlib = { load = true },
    })
    h:load()
    h:step()
    return h
end

-- protocol.limits of the loaded bridge (specs shrink them in place), so the helpers below
-- follow the plugin's pacing instead of repeating its numbers.
---@param h table
---@return table
local function limits(h)
    return h.env.require("protocol").limits
end

-- Run `n` Logic ticks (20 ms each).
---@param h table
---@param n integer
function M.ticks(h, n)
    h:advance(n * 20)
end

-- Run the wait after a failed sync (limits.retryTicks), at the end of which the next starts.
---@param h table
function M.untilRetry(h)
    M.ticks(h, limits(h).retryTicks)
end

-- Answer the one open sync with `response` (a 200 with an empty body by default) and run
-- until the next sync has started, which is when the bridge reports what that answer led to.
-- Returns the next sync's body, decoded. A finished sync waits syncEveryTicks for the next, a
-- failed one retryTicks, so it gives up after the longer.
---@param h table
---@param response table?
---@return table body
function M.cycle(h, response)
    local before = #M.syncs(h)
    M.answer(h, response)
    for _ = 1, limits(h).retryTicks + 1 do
        if #M.syncs(h) > before then return M.last(h) end
        h:step()
    end
    error("no sync started after the answer", 2)
end

-- Record every real Event.<X>.Subscribe/Unsubscribe the bridge makes, as
-- "Subscribe <event> <name>" or "Unsubscribe <event> <name>", and the Logic tick of each. The
-- spy tail-calls the real function, so the harness still sees the bridge's own frame as the
-- caller and still faults an Unsubscribe the bridge passes straight to pcall. On a harness not
-- yet loaded, `atLoad` records the calls main.lua makes while h:load() runs (the harness keeps
-- subscriptions per event, not in call order); otherwise it spies from now on.
---@param h table
---@param atLoad boolean?
---@return string[] calls
---@return integer[] ticks
function M.spyEvent(h, atLoad)
    local calls, ticks = {}, {}
    local function note(text)
        calls[#calls + 1] = text
        ticks[#ticks + 1] = h.tick
    end
    local function wrap(env)
        local real = env.Event
        env.Event = setmetatable({}, {
            __index = function(_, event)
                local sub = real[event]
                return {
                    Subscribe = function(name, fn)
                        note("Subscribe " .. event .. " " .. name)
                        return sub.Subscribe(name, fn)
                    end,
                    Unsubscribe = function(name)
                        note("Unsubscribe " .. event .. " " .. name)
                        return sub.Unsubscribe(name)
                    end,
                }
            end,
        })
    end
    if not atLoad then
        wrap(h.instance.env)
        return calls, ticks
    end
    -- The sandbox is built inside h:load(), so wrap its builder for the length of that call.
    local sandbox = require("tests.harness.sandbox")
    local build = sandbox.build
    h.load = function(self)
        h.load = nil -- back to Harness.load
        rawset(sandbox, "build", function(...)
            local env = build(...)
            wrap(env)
            return env
        end)
        local ok, err = pcall(self.load, self)
        rawset(sandbox, "build", build)
        assert(ok, err)
    end
    return calls, ticks
end

-- Answer the open sync with `commands` ({ id, kind, arg } each, at most 10, which run one per
-- tick), run until the next sync starts and return its results by id, and its body.
---@param h table
---@param commands string[][]
---@return table<string, table> results
---@return table body
function M.run(h, commands)
    local reply = ""
    for _, c in ipairs(commands) do
        reply = reply .. M.line(c[1], c[2], c[3])
    end
    local body = M.cycle(h, { status = 200, body = reply })
    local byId = {}
    for _, result in ipairs(body.results) do
        byId[result.id] = result
    end
    return byId, body
end

-- M.run with one eval of `source`, returning its result.
---@param h table
---@param source string
---@return table result
---@return table body
function M.eval(h, source)
    local results, body = M.run(h, { { "e", "eval", source } })
    return assert(results.e, "no result for the eval"), body
end

-- The raw JSON of the latest sync, for what decoding loses (a null inside an array).
---@param h table
---@return string
function M.lastRaw(h)
    local all = M.syncs(h)
    return assert(all[#all], "no sync started").body
end

-- The bridge's sync requests, in order.
---@param h table
---@return table[]
function M.syncs(h)
    return h:requestsTo(M.SYNC_URL)
end

-- The sync requests neither answered nor cancelled.
---@param h table
---@return table[]
function M.open(h)
    local out = {}
    for _, record in ipairs(M.syncs(h)) do
        if not (record.response or record.state.fields.cancelled) then out[#out + 1] = record end
    end
    return out
end

-- A sync's body, decoded.
---@param record table
---@return table
function M.body(record)
    return harness.decodeJson(record.body, "sync body")
end

-- The latest sync, decoded.
---@param h table
---@return table
function M.last(h)
    local all = M.syncs(h)
    return M.body(assert(all[#all], "no sync started"))
end

-- Answer the one open sync with `response` (a 200 with an empty body by default), then step
-- once so it is delivered.
---@param h table
---@param response table?
function M.answer(h, response)
    local open = M.open(h)
    assert(#open == 1, "expected one open sync, found " .. #open)
    h:respond(open[1], response or { status = 200, body = "" })
    h:step()
end

-- A reply body line, escaped the way scripts/rsdev.py's escape_arg does.
---@param id string
---@param kind string
---@param arg string
---@return string
function M.line(id, kind, arg)
    local escaped = arg:gsub("\\", "\\\\"):gsub("\t", "\\t"):gsub("\n", "\\n"):gsub("\r", "\\r")
    return id .. "\t" .. kind .. "\t" .. escaped .. "\n"
end

-- A sync body's events other than Log (the bridge's own lines), so specs of forwarding can
-- ignore the bridge talking about itself.
---@param body table
---@return table[]
function M.forwarded(body)
    local out = {}
    for _, e in ipairs(body.events) do
        if e.name ~= "Log" then out[#out + 1] = e end
    end
    return out
end

-- The payloads of a sync body's events named `name`.
---@param body table
---@param name string
---@return table[]
function M.payloads(body, name)
    local out = {}
    for _, e in ipairs(body.events) do
        if e.name == name then out[#out + 1] = e.payload end
    end
    return out
end

-- The console commands run so far after the three self-grant ones.
---@param h table
---@return string[]
function M.ran(h)
    return { table.unpack(h.consoleCommands, 4) }
end

return M
