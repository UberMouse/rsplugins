-- Remote eval (a dev tool, not for submission): runs Lua snippets that scripts/rsdev.py sends to
-- this plugin (`rsdev.py eval --plugin <name> <lua>`) inside the plugin's own environment, so a
-- check can read the plugin's state and call its functions, and press its UI without the
-- mouse. The dev bridge's eval runs in the bridge, which can't reach another plugin's locals.
--
-- It rides on the log tee (dev/tee.lua): commands arrive in the replies to the tee's POSTs and
-- results go back in the next one. A plugin opts in after the tee, in main.lua's first lines:
--
--     local tee = require("dev/tee") -- nil when dev/ isn't there
--     local remote = require("dev/remote")
--     if tee then tee.install(_ENV, "my-plugin") end
--     if remote then remote.install(_ENV, tee) end
--
-- and `if remote then remote.shutdown() end` in PluginShutdown, before tee.shutdown(). Without
-- the tee running (no urls.rsdev, no httpAccess) it logs one [REMOTE] line and does nothing.
--
-- A snippet's globals live in a scratch table kept until a reset or reload; reads fall through
-- to the plugin's globals, the API included. It also sees:
--   print, log  captured into the result's output, and still printed (and teed)
--   exposed     what the plugin registered with remote.expose(name, value); a function value
--               is a getter, called with no arguments (for state held in main.lua's locals)
--   press(text, nth)  call the onClick of the pressable whose text is `text` (ignoring case),
--               or else contains it; returns that text. A pressable is any table reachable
--               from `exposed` with an onClick function and a `text` string or a `label` ui.Text.
--               It runs the plugin's own handler, as a click would, minus the client's hit
--               testing and event order (rsdev.py click does those).
-- The scratch env is a convenience, not a sandbox: the snippet is trusted as `exec` is.
--
-- Snippets must not subscribe to events: neither a reset nor remote.shutdown knows about a
-- subscription made through the plugin's Event, so its callback would keep firing after them,
-- even after the plugin is disabled (a left-over subscription is suspected of a crash on
-- `prl`, docs/api-concepts.md). Use the dev bridge's eval probes for that.
--
-- A snippet runs inside the tee's Logic callback. One that runs past the client's 1000 ms
-- per-call limit is killed by the client, which can take the plugin down with it; reload it
-- (`prl <name>`). Keep snippets short.

local command = require("dev/command")
local recording = require("dev/recording")
local batch = require("dev/batch")

local remote = {}

-- Caps on one result, as the bridge's (rsdev.py MAX_BODY is 2 MB).
remote.limits = {
    valueBytes = 64 * 1024,
    outputLines = 200,
    lineBytes = 2 * 1024,
    -- At most tee.limits.resultBytes, which caps a POST's results: a bigger one still goes
    -- alone, and could take the POST past the daemon's cap.
    resultBytes = 1024 * 1024,
}

local MAX_DEPTH = 6 -- how deep press() looks inside the exposed values

local realLog = log

local function say(...)
    realLog("[REMOTE]", ...)
end

local active = false
local pluginEnv = nil ---@type table?
local scratch = nil ---@type table?
local output = nil ---@type { lines: string[], truncated: boolean }?
local exposed = {} ---@type table<string, any>

-- A value as plain data, as the bridge serialises eval values; one whose tostring() raises
-- becomes text saying so.
---@param v any
---@return any
local function serialise(v)
    local ok, data = pcall(recording.serialise, v, recording.objectData)
    if ok then return data end
    return "<could not serialise: " .. batch.text(data) .. ">"
end

-- The text a pressable shows: its `text`, else its `label`'s content. A label that isn't a
-- ui.Text raises on `.content`, so it reads under pcall (a Lua closure, never an API function).
---@param t table
---@return string?
local function pressableText(t)
    if type(t.text) == "string" then return t.text end
    if t.label == nil then return nil end
    local ok, content = pcall(function()
        return t.label.content
    end)
    return ok and type(content) == "string" and content or nil
end

-- Every pressable reachable from the exposed values, in a stable order (names sorted).
---@return { text: string, onClick: function }[]
local function pressables()
    local found, seen = {}, {}
    local function visit(v, depth)
        if type(v) ~= "table" or seen[v] or depth > MAX_DEPTH then return end
        seen[v] = true
        if type(v.onClick) == "function" then
            local text = pressableText(v)
            if text then found[#found + 1] = { text = text, onClick = v.onClick } end
        end
        local keys = {}
        for k in pairs(v) do
            keys[#keys + 1] = k
        end
        table.sort(keys, function(a, b)
            return tostring(a) < tostring(b)
        end)
        for _, k in ipairs(keys) do
            visit(v[k], depth + 1)
        end
    end
    local names = {}
    for name in pairs(exposed) do
        names[#names + 1] = name
    end
    table.sort(names)
    for _, name in ipairs(names) do
        local value = exposed[name]
        if type(value) == "function" then value = value() end
        visit(value, 1)
    end
    return found
end

-- Press the pressable showing `text` (see the header). Raises, naming the candidates, when
-- none or several match.
---@param text string
---@param nth integer?
---@return string
local function press(text, nth)
    if type(text) ~= "string" then error("press(text: string, nth: integer?)", 2) end
    local want = text:lower()
    local exact, partial = {}, {}
    for _, p in ipairs(pressables()) do
        local have = p.text:lower()
        if have == want then
            exact[#exact + 1] = p
        elseif have:find(want, 1, true) then
            partial[#partial + 1] = p
        end
    end
    local matches = #exact > 0 and exact or partial
    if #matches == 0 then error("nothing pressable shows " .. string.format("%q", text), 2) end
    if nth == nil and #matches > 1 then
        local names = {}
        for i, p in ipairs(matches) do
            names[i] = string.format("%d: %q", i, p.text)
        end
        error("several match, pass nth: " .. table.concat(names, "; "), 2)
    end
    local chosen = matches[nth or 1]
    if not chosen then error(string.format("nth %d, but %d match", nth, #matches), 2) end
    chosen.onClick()
    return chosen.text
end

---@return table
local function newScratch()
    assert(pluginEnv, "install() took the plugin's environment")
    local env = setmetatable({}, { __index = pluginEnv })
    env._G = env
    local function capture(real)
        return function(...)
            if output then command.addOutput(output, batch.joined(...), remote.limits) end
            real(...)
        end
    end
    env.print = capture(pluginEnv.print)
    env.log = capture(pluginEnv.log)
    env.exposed = exposed
    env.press = press
    return env
end

---@param cmd { id: string, kind: string, arg: string }
---@return string
local function runCommand(cmd)
    if cmd.kind == "reset" then
        scratch = newScratch()
        return command.resultEntry({ id = cmd.id, ok = true }, remote.limits)
    end
    if cmd.kind ~= "eval" then
        local why = "unknown kind " .. cmd.kind
        return command.resultEntry({ id = cmd.id, ok = false, error = why }, remote.limits)
    end
    assert(scratch, "install() made the scratch env")
    local chunk, err = command.compile(load, cmd.arg, scratch)
    if not chunk then
        return command.resultEntry({ id = cmd.id, ok = false, error = err }, remote.limits)
    end
    output = command.newOutput()
    local result = table.pack(pcall(chunk))
    local printed = output
    output = nil
    if not result[1] then
        local failed = { id = cmd.id, ok = false, error = result[2], output = printed }
        return command.resultEntry(failed, remote.limits)
    end
    local values = {}
    for i = 2, result.n do
        values[i - 1] = serialise(result[i])
    end
    return command.resultEntry({
        id = cmd.id,
        ok = true,
        values = values,
        nvalues = result.n - 1,
        output = printed,
    }, remote.limits)
end

-- Run one command for the tee and return its encoded result. A failure of remote's own (the
-- snippet's are caught in runCommand) still answers, so the CLI isn't left waiting for a result
-- that never comes.
---@param cmd { id: string, kind: string, arg: string }
---@return string
local function run(cmd)
    local ok, entry = pcall(runCommand, cmd)
    if ok then return entry end
    output = nil
    local why = "dev/remote failed: " .. batch.text(entry)
    return command.resultEntry({ id = cmd.id, ok = false, error = why }, remote.limits)
end

-- Start taking commands for the plugin whose environment is `env` (main.lua's `_ENV`), over
-- `tee`, which must already be installed. Logs once and does nothing if the tee isn't sending.
---@param env table
---@param tee table? dev/tee, or nil when dev/ isn't there
function remote.install(env, tee)
    if active then return end
    pluginEnv = env
    realLog = env.log
    if not (tee and tee.attach(run)) then
        say("the dev log tee isn't sending, so not taking commands")
        return
    end
    scratch = newScratch()
    active = true
    say("taking eval commands (rsdev.py eval --plugin)")
end

-- Register `value` under `name` for snippets (`exposed.<name>`) and press(). Pass a getter
-- function for state that main.lua replaces as it runs.
---@param name string
---@param value any
function remote.expose(name, value)
    exposed[name] = value
end

-- Stop: forget the scratch env and what was exposed. The tee's own shutdown stops the polling.
function remote.shutdown()
    active = false
    scratch, exposed = nil, {}
end

return remote
