-- The dev bridge's eval (shell): runs Lua snippets the local daemon sends (command kind eval)
-- in a scratch environment kept for the bridge session, and tracks the probes they install.
--
-- A snippet's globals live in the scratch table (its _G too); reads fall through to the
-- bridge's globals. In it, these globals differ from the bridge's:
--   print, log  during a snippet, captured into the result's output; afterwards (from a probe
--               callback), sent as Log events (source "eval"). Both reach the console too.
--   emit(tag, value)  sends an Emit event with the value serialised.
--   Event       Subscribe registers under protocol.probeName(name), so a probe can't replace
--               the bridge's own subscriptions, and is tracked so reset and shutdown can remove
--               it. A probe whose callback raises is unsubscribed after its first error.
--   ExecuteConsoleCommand  refuses what exec refuses (protocol.consoleRefusal).
-- The scratch env is a convenience, not a sandbox: the snippet is trusted as exec is.
--
-- A snippet runs inside the bridge's Logic call, so one that runs past the client's 1000 ms
-- limit is aborted by the client, which takes the bridge down with it (`pon dev-bridge`
-- recovers). Nothing guards against that.

local protocol = require("protocol")
local recording = assert(require("dev/recording"), "dev/ (a link to lib/dev) is missing")

-- The client has load (docs/api-concepts.md, "Seen with dev-bridge"); whether it honours the
-- mode and env arguments is unconfirmed. Without it eval reports an error.
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
    local probes = {} -- event name -> { [the snippet's subscription name] = true }
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

    ---@param event string
    ---@param name string
    local function forget(event, name)
        if probes[event] then probes[event][name] = nil end
        pcall(Event[event].Unsubscribe, protocol.probeName(name))
    end

    ---@param event string
    ---@param name any
    ---@param callback any
    local function subscribe(event, name, callback)
        if type(name) ~= "string" or type(callback) ~= "function" then
            error("Event." .. event .. ".Subscribe(name: string, callback: function)", 3)
        end
        -- Passes the callback's returns through: some events use them (EntityDraw's boolean).
        local function probe(...)
            local result = table.pack(pcall(callback, ...))
            if result[1] then return table.unpack(result, 2, result.n) end
            forget(event, name)
            local text = protocol.probeErrorText(event, name, result[2])
            log(protocol.TAG, text)
            host.push(protocol.logEntry(host.tick(), "error", text, "eval"))
        end
        Event[event].Subscribe(protocol.probeName(name), probe)
        probes[event] = probes[event] or {}
        probes[event][name] = true
    end

    -- Event as a snippet sees it: Event.<Name>.Subscribe/Unsubscribe, the probe versions.
    local eventProxy = setmetatable({}, {
        __index = function(_, event)
            if Event[event] == nil then return nil end
            return {
                Subscribe = function(name, callback)
                    subscribe(event, name, callback)
                end,
                Unsubscribe = function(name)
                    if type(name) == "string" then forget(event, name) end
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

    -- Unsubscribe every probe. Each under pcall, so one failing can't leave the rest.
    function self.stop()
        for event, names in pairs(probes) do
            for name in pairs(names) do
                pcall(Event[event].Unsubscribe, protocol.probeName(name))
            end
        end
        probes = {}
    end

    -- Unsubscribe every probe and start a fresh scratch env.
    function self.reset()
        self.stop()
        scratch = newScratch()
    end

    return self
end

return eval
