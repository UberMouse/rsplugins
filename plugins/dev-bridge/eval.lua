-- The dev bridge's eval (shell): runs Lua snippets the local daemon sends (command kind eval)
-- in a scratch environment kept for the bridge session, and holds the probes they install.
--
-- A probe is an entry in this module's table, never a client subscription of its own: the
-- bridge's handler for an event calls fanOut, which calls that event's probes. It makes no
-- Subscribe or Unsubscribe call (fanOut logs; a snippet's print, log and console commands reach
-- the client). It tells the host when an event gains its first probe
-- (host.firstProbe) and when it has none left (host.noProbes); main.lua then subscribes or
-- unsubscribes that event's handler at the client on its next Logic tick, for events outside
-- its six load-time ones.
-- So a snippet's Subscribe and Unsubscribe, a probe's removal and reset are table edits here.
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
-- A snippet that calls the real Event.<X>.Subscribe (reachable through
-- getmetatable(_G).__index) must call the real Unsubscribe itself, directly: neither reset nor
-- the bridge's PluginShutdown knows about it, so after a reset its callback keeps firing.
-- Never pass Event.<X>.Unsubscribe straight to pcall or xpcall: all seven client aborts seen
-- so far did that (docs/api-concepts.md, "Runtime limits we've hit").
--
-- A snippet runs inside the bridge's Logic call, so one that runs past the client's 1000 ms
-- limit is aborted by the client, which takes the bridge down with it (`pon dev-bridge`
-- recovers). A probe on Logic runs in the same handler call as the bridge's own Logic work and
-- shares that 1000 ms budget, so a slow one takes the bridge down too. Nothing guards against
-- either.

local protocol = require("protocol")
local recording = assert(require("dev/recording"), "dev/ (a link to lib/dev) is missing")
local batch = assert(require("dev/batch"), "dev/ (a link to lib/dev) is missing")
local devCommand = assert(require("dev/command"), "dev/ (a link to lib/dev) is missing")

-- The client has load, and honours its mode and env arguments (docs/api-concepts.md, "Plugin
-- environment and globals"). Without it eval reports an error.
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

---@class (exact) DevBridgeEvalHost
---@field push fun(entry: string)
---@field tick fun(): integer
---@field firstProbe fun(event: string)
---@field noProbes fun(event: string)

-- A value as plain data, as forwarded event payloads are; one that can't be serialised (its
-- tostring() raises) becomes text saying so rather than failing the whole result.
---@param v any
---@return any
local function serialise(v)
    local ok, data = pcall(recording.serialise, v, recording.objectData)
    if ok then return data end
    return "<could not serialise: " .. batch.text(data) .. ">"
end

-- A new evaluator for one bridge session. `host.push(entry)` buffers an encoded Log or Emit
-- event (the host drops it once the bridge has stopped); `host.tick()` is the Logic tick to
-- stamp it with. `host.firstProbe(event)` is called before an event with no probe list gets
-- one (an error from it fails the snippet's Subscribe), `host.noProbes(event)` once its list
-- is gone.
---@param host DevBridgeEvalHost
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
        local text = batch.joined(...)
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
        if kept == 0 and probes[event] == list then
            probes[event] = nil
            host.noProbes(event)
        end
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
            host.firstProbe(event)
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

    -- Call `event`'s probes with `payload`, in the order added, each under pcall; returns are
    -- dropped (no PROBE_EVENTS event uses one). A probe removed mid-pass is only marked, so
    -- it isn't called again this pass and is swept at the end; one added mid-pass is first
    -- called on the next dispatch. A probe's first error removes it, logged on the console and
    -- as a Log event.
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

    -- Remove every probe. No client call: host.noProbes only queues the event's removal.
    function self.clear()
        for event, list in pairs(probes) do
            for _, probe in ipairs(list) do
                probe.removed = true
            end
            probes[event] = nil
            host.noProbes(event)
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
        local chunk, err = devCommand.compile(compile, source, scratch)
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
