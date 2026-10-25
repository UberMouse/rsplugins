-- The dev bridge's eval (shell): runs Lua snippets the local daemon sends (command kind eval)
-- in a scratch environment kept for the bridge session, and tracks the probes they install.
--
-- A snippet's globals live in the scratch table (its _G too); reads fall through to the
-- bridge's globals. In it, these globals differ from the bridge's:
--   print, log  during a snippet, captured into the result's output; afterwards (from a probe
--               callback), sent as Log events (source "eval"). Both reach the console too.
--   emit(tag, value)  sends an Emit event with the value serialised.
--   Event       Subscribe registers under protocol.probeName(name), so a probe can't replace
--               the bridge's own subscriptions. Unsubscribe from inside an event callback
--               aborts the client (docs/api-concepts.md), and snippets run inside Logic, so a
--               probe is never unsubscribed while the bridge runs, only disarmed: its
--               Unsubscribe, or its callback's first error, makes it a no-op, and a later
--               Subscribe of the same name re-arms it. Only shutdown unsubscribes probes, so
--               a session has at most protocol.limits.probes of them; reset reloads the bridge.
--   ExecuteConsoleCommand  refuses what exec refuses (protocol.consoleRefusal).
-- The scratch env is a convenience, not a sandbox: the snippet is trusted as exec is.
--
-- A snippet runs inside the bridge's Logic call, so one that runs past the client's 1000 ms
-- limit is aborted by the client, which takes the bridge down with it (`pon dev-bridge`
-- recovers). Nothing guards against that.

local protocol = require("protocol")
local recording = assert(require("dev/recording"), "dev/ (a link to lib/dev) is missing")

-- The client has load, and honours its mode and env arguments (docs/api-concepts.md, "Seen
-- with dev-bridge"). Without it eval reports an error.
local compile = load

local eval = {}

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
    -- event name -> { [the snippet's subscription name] = its entry }: one per real
    -- subscription, armed while its callback is set.
    local probes = {} ---@type table<string, table<string, { callback: function? }>>
    local count = 0 -- entries in probes, against protocol.limits.probes
    local disarmed = false -- set by disarmAll: every probe is a no-op from then on
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

    -- Disarm a probe: its subscription stays, but its wrapper does nothing from now on.
    ---@param event string
    ---@param name string
    local function disarm(event, name)
        local probe = probes[event] and probes[event][name]
        if probe then probe.callback = nil end
    end

    ---@param event string
    ---@param name any
    ---@param callback any
    local function subscribe(event, name, callback)
        if type(name) ~= "string" or type(callback) ~= "function" then
            error("Event." .. event .. ".Subscribe(name: string, callback: function)", 3)
        end
        probes[event] = probes[event] or {}
        local existing = probes[event][name]
        if existing then
            -- Re-armed in place: a second Subscribe under the same name is avoided, since
            -- whether the client replaces or duplicates it is unconfirmed.
            existing.callback = callback
            return
        end
        local full = protocol.probeCapError(count)
        if full then error(full, 3) end
        local entry = { callback = callback } ---@type { callback: function? }
        -- Calls the probe's current callback, passing its returns through (some events use
        -- them: EntityDraw's boolean). Once disarmed (by name, or all of them) it does nothing.
        local function wrapper(...)
            local current = entry.callback
            if disarmed or not current then return end
            local result = table.pack(pcall(current, ...))
            if result[1] then return table.unpack(result, 2, result.n) end
            entry.callback = nil
            local text = protocol.probeErrorText(event, name, result[2])
            log(protocol.TAG, text)
            host.push(protocol.logEntry(host.tick(), "error", text, "eval"))
        end
        Event[event].Subscribe(protocol.probeName(name), wrapper)
        probes[event][name] = entry
        count = count + 1
    end

    -- Event as a snippet sees it: Event.<Name>.Subscribe/Unsubscribe, the probe versions.
    local eventProxy = setmetatable({}, {
        __index = function(_, event)
            if Event[event] == nil then return nil end
            return {
                Subscribe = function(name, callback)
                    subscribe(event, name, callback)
                end,
                -- Only disarms: Unsubscribe from inside a callback (snippets run in Logic)
                -- aborts the client.
                Unsubscribe = function(name)
                    if type(name) == "string" then disarm(event, name) end
                end,
            }
        end,
    })

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

    -- Make every probe a no-op, without unsubscribing any: safe from inside a callback.
    function self.disarmAll()
        disarmed = true
    end

    -- Unsubscribe every probe for real. Only PluginShutdown may call this: Unsubscribe from
    -- inside an event callback aborts the client. Each under pcall, so one failing can't
    -- leave the rest.
    function self.unsubscribeAll()
        disarmed = true
        for event, names in pairs(probes) do
            for name in pairs(names) do
                pcall(Event[event].Unsubscribe, protocol.probeName(name))
            end
        end
        probes, count = {}, 0
    end

    return self
end

return eval
