-- The dev bridge's eval (shell): runs Lua snippets the local daemon sends (command kind eval)
-- in a scratch environment kept for the bridge session, and holds the probes they install.
--
-- A probe is an entry in this module's table, never a client subscription. main.lua
-- subscribes each event in protocol.PROBE_EVENTS once, at load, and its handler calls
-- fanOut, which calls that event's probes. Four client aborts (docs/api-concepts.md, "Runtime
-- limits we've hit") showed that a subscription made inside a callback, where snippets run,
-- can never be unsubscribed safely, so a snippet's Subscribe and Unsubscribe only edit the
-- table, and reset clears it without a client call. A fifth (a self-reload from Logic with 39
-- load-time subscriptions) is why PROBE_EVENTS is only stage 1's six.
--
-- A snippet's globals live in the scratch table (its _G too); reads fall through to the
-- bridge's globals. In it, these globals differ from the bridge's:
--   print, log  during a snippet, captured into the result's output; afterwards (from a probe
--               callback), sent as Log events (source "eval"). Both reach the console too.
--   emit(tag, value)  sends an Emit event with the value serialised.
--   Event       Event.<X>.Subscribe(name, fn) adds the probe `name` on X, or replaces its
--               callback; Event.<X>.Unsubscribe(name) removes it. X must be in
--               protocol.PROBE_EVENTS, else both raise. At most protocol.limits.probes live
--               probes. A probe's first error removes it.
--   ExecuteConsoleCommand  refuses what exec refuses (protocol.consoleRefusal).
-- The scratch env is a convenience, not a sandbox: the snippet is trusted as exec is.
--
-- A snippet must NEVER call the real Event.<X>.Subscribe or Unsubscribe, which it can reach
-- through getmetatable(_G).__index. A subscription made at runtime can never be removed
-- without aborting the client, so from then on even `prl dev-bridge` or `poff dev-bridge` is
-- expected to abort it. Probably the same for ExecuteConsoleCommand("prl <other plugin>") or
-- poff when that plugin made subscriptions at runtime (unverified).
--
-- A snippet runs inside the bridge's Logic call, so one that runs past the client's 1000 ms
-- limit is aborted by the client, which takes the bridge down with it (`pon dev-bridge`
-- recovers). A probe on Logic runs in the same handler call as the bridge's own Logic work and
-- shares that 1000 ms budget, so a slow one takes the bridge down too. Nothing guards against
-- either.

local protocol = require("protocol")
local recording = assert(require("dev/recording"), "dev/ (a link to lib/dev) is missing")

-- The client has load, and honours its mode and env arguments (docs/api-concepts.md, "Seen
-- with dev-bridge"). Without it eval reports an error.
local compile = load

local eval = {}

---@class (exact) DevBridgeProbe
---@field name string the name the snippet subscribed with
---@field callback function
---@field removed boolean set when unsubscribed, replaced, errored or cleared

-- One event's probes in the order added. `running` counts the fan-outs of the event in
-- progress (a probe can trigger a nested one), during which removed entries stay in place.
---@class DevBridgeProbeList
---@field [integer] DevBridgeProbe
---@field running integer

-- A value as plain data, as forwarded event payloads are; one that can't be serialised (its
-- tostring() raises) becomes text saying so rather than failing the whole result.
---@param v any
---@return any
local function serialise(v)
    local ok, data = pcall(recording.serialise, v, recording.objectData)
    if ok then return data end
    return "<could not serialise: " .. protocol.text(data) .. ">"
end

-- A new evaluator for one bridge session. `host.push(entry)` buffers an encoded Log or Emit
-- event (the host drops it once the bridge has stopped); `host.tick()` is the Logic tick to
-- stamp it with.
---@param host { push: fun(entry: string), tick: fun(): integer }
---@return table
function eval.new(host)
    local self = {}
    -- event name -> its probes. An event with no live probes has no list, so the bridge's
    -- handler checks `self.probes[event]` and returns. Emptied in place, never replaced, so
    -- the host may keep the reference.
    local probes = {} ---@type table<string, DevBridgeProbeList>
    self.probes = probes
    local count = 0 -- live probes, against protocol.limits.probes
    local output = nil ---@type { lines: string[], truncated: boolean }?

    -- A print or log from scratch code: into the running snippet's output, else a Log event.
    ---@param level "print"|"log"
    local function capture(level, ...)
        local text = protocol.joinText(...)
        if output then
            protocol.addOutput(output, text)
        else
            host.push(protocol.logEntry(host.tick(), level, text, "eval"))
        end
    end

    -- Drop `list`'s removed entries, and the list itself once empty, unless a fan-out of its
    -- event is walking it by index; the last fan-out to finish sweeps instead.
    ---@param event string
    ---@param list DevBridgeProbeList
    local function sweep(event, list)
        if list.running > 0 then return end
        local kept = 0
        for i = 1, #list do
            local probe = list[i]
            list[i] = nil
            if not probe.removed then
                kept = kept + 1
                list[kept] = probe
            end
        end
        -- A clear() during the fan-out detached this list; a new one may stand in its place.
        if kept == 0 and probes[event] == list then probes[event] = nil end
    end

    ---@param probe DevBridgeProbe
    local function markRemoved(probe)
        if probe.removed then return end
        probe.removed = true
        count = count - 1
    end

    -- The live probe `name` on `event`, if any.
    ---@param event string
    ---@param name string
    ---@return DevBridgeProbe?
    local function find(event, name)
        for _, probe in ipairs(probes[event] or {}) do
            if probe.name == name and not probe.removed then return probe end
        end
        return nil
    end

    ---@param event string
    ---@param name any
    local function remove(event, name)
        local probe = type(name) == "string" and find(event, name)
        if not probe then return end
        markRemoved(probe)
        sweep(event, probes[event])
    end

    -- Add the probe, replacing one of the same name: the old entry is removed and the new one
    -- goes last, so a replacement made during a fan-out is first called on the next dispatch.
    ---@param event string
    ---@param name string
    ---@param callback function
    local function add(event, name, callback)
        remove(event, name)
        local list = probes[event]
        if not list then
            list = { running = 0 }
            probes[event] = list
        end
        list[#list + 1] = { name = name, callback = callback, removed = false }
        count = count + 1
    end

    -- Event as a snippet sees it. Errors are raised at level 2, the snippet's call.
    local eventProxy = setmetatable({}, {
        __index = function(_, event)
            return {
                Subscribe = function(name, callback)
                    local refused = protocol.probeEventError(event)
                    if refused then error(refused, 2) end
                    if type(name) ~= "string" or type(callback) ~= "function" then
                        error(
                            "Event." .. event .. ".Subscribe(name: string, callback: function)",
                            2
                        )
                    end
                    local full = not find(event, name) and protocol.probeCapError(count)
                    if full then error(full, 2) end
                    add(event, name, callback)
                end,
                Unsubscribe = function(name)
                    local refused = protocol.probeEventError(event)
                    if refused then error(refused, 2) end
                    remove(event, name)
                end,
            }
        end,
    })

    -- Call `event`'s probes with `payload`, in the order added, each under pcall. Their
    -- returns are dropped: no event in PROBE_EVENTS uses a subscriber's return, so a probe
    -- can't affect the client that way. Mark and sweep: a probe removed during the pass (by
    -- itself, another probe, an error or a clear) is only marked, so it isn't called later in
    -- the pass, and the pass sweeps it at the end; a probe added during the pass lands past
    -- the length read at its start, so it is first called on the next dispatch of that event,
    -- including a nested one during this pass. A probe's
    -- first error removes it, logged once on the console and as a Log event.
    ---@param event string
    ---@param payload any
    function self.fanOut(event, payload)
        local list = probes[event]
        if not list then return end
        list.running = list.running + 1
        for i = 1, #list do
            local probe = list[i]
            if not probe.removed then
                local ok, err = pcall(probe.callback, payload)
                if not ok then
                    markRemoved(probe)
                    local text = protocol.probeErrorText(event, probe.name, err)
                    log(protocol.TAG, text)
                    host.push(protocol.logEntry(host.tick(), "error", text, "eval"))
                end
            end
        end
        list.running = list.running - 1
        sweep(event, list)
    end

    -- Remove every probe: a pure table edit, so safe from inside any callback.
    function self.clear()
        for event, list in pairs(probes) do
            for _, probe in ipairs(list) do
                probe.removed = true
            end
            probes[event] = nil
        end
        count = 0
    end

    ---@return table
    local function newScratch()
        local env = setmetatable({}, { __index = _ENV })
        env._G = env
        env.print = function(...)
            capture("print", ...)
            print(...)
        end
        env.log = function(...)
            capture("log", ...)
            log(...)
        end
        env.emit = function(tag, value)
            host.push(protocol.emitEntry(host.tick(), tag, serialise(value)))
        end
        env.Event = eventProxy
        env.ExecuteConsoleCommand = function(command)
            local refused = type(command) == "string" and protocol.consoleRefusal(command)
            if refused then error(refused, 0) end
            return ExecuteConsoleCommand(command)
        end
        return env
    end
    local scratch = newScratch()

    -- Command kind reset: no probes and a fresh scratch env, without reloading the bridge.
    function self.reset()
        self.clear()
        scratch = newScratch()
    end

    -- Run one snippet: `return <source>` first, so an expression gives its values, then
    -- `<source>` as statements. Returns the fields of protocol.resultEntry, but the id.
    ---@param source string
    ---@return table
    function self.run(source)
        if type(compile) ~= "function" then
            return { ok = false, error = "this client has no load(), so eval can't run Lua" }
        end
        local chunk, err = compile("return " .. source, "=eval", "t", scratch)
        if not chunk then
            chunk, err = compile(source, "=eval", "t", scratch)
        end
        if not chunk then return { ok = false, error = err } end
        output = protocol.newOutput()
        local result = table.pack(pcall(chunk))
        local printed = output
        output = nil
        if not result[1] then return { ok = false, error = result[2], output = printed } end
        local values = {}
        for i = 2, result.n do
            values[i - 1] = serialise(result[i])
        end
        return { ok = true, values = values, nvalues = result.n - 1, output = printed }
    end

    return self
end

return eval
