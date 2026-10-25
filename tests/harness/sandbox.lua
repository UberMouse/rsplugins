-- The global environment a plugin runs in: a fresh table per load, holding a whitelist of
-- the Lua stdlib, the mocked API and `require`. Reading any other global faults with
-- `unmocked API: <name>`, so a plugin using an API the harness doesn't model fails its test
-- instead of quietly getting nil. Plugins may still assign globals (PluginShutdown...).

local runtime = require("tests.harness.runtime")
local strict = require("tests.harness.strict")

local M = {}

-- Base functions and libraries plugins get. The client runs Lua 5.4.8; which stdlib parts it
-- exposes isn't documented, so this is the side-effect-free core of the stdlib (coroutine
-- too: an earlier plugins/var-dump ran one in the client).
local BASE = {
    "assert",
    "error",
    "getmetatable",
    "ipairs",
    "next",
    "pairs",
    "pcall",
    "rawequal",
    "rawget",
    "rawlen",
    "rawset",
    "select",
    "setmetatable",
    "tonumber",
    "tostring",
    "type",
    "xpcall",
    "_VERSION",
}
local LIBS = { "string", "table", "math", "utf8", "coroutine" }

-- Withheld unless a test opts in (opts.stdlib = { os = true }): the client has neither
-- (recorder-demo's probe, 2026-10-25), so a plugin mustn't rely on them.
local OPT_IN = { os = os, io = io }
-- Standard globals never provided, with a clearer message than "unmocked API".
local WITHHELD = {
    debug = true,
    load = true,
    loadfile = true,
    dofile = true,
    package = true,
    collectgarbage = true,
    os = true,
    io = true,
}

local API_MODULES = {
    "tests.harness.api.plugin",
    "tests.harness.api.persistentdb",
    "tests.harness.api.http",
    "tests.harness.api.vars",
    "tests.harness.api.player",
    "tests.harness.api.inventory",
    "tests.harness.api.chat",
}

---@param lib table
---@return table
local function copy(lib)
    local out = {}
    for k, v in pairs(lib) do
        out[k] = v
    end
    return out
end

-- The coroutine library, with every new thread under the time budget (runtime.watch).
---@return table
local function budgetedCoroutine()
    local lib = copy(coroutine)
    lib.create = function(f)
        local thread = coroutine.create(f)
        runtime.watch(thread)
        return thread
    end
    -- wrap's thread is never handed out, so it is watched from inside on its first resume.
    lib.wrap = function(f)
        if type(f) ~= "function" then return coroutine.wrap(f) end -- the stdlib's own error
        return coroutine.wrap(function(...)
            runtime.watch(coroutine.running())
            return f(...)
        end)
    end
    return lib
end

-- `require` as the client implements it (docs/plugin-anatomy.md): the path is relative to the
-- plugin root, without extension; each file runs once per load and later calls get the
-- cached result; a missing file gives nil; a circular require is an error. A file that fails
-- while running gives nil in the client; here it fails the test instead.
---@param h table the harness
---@param env table
---@return function
local function makeRequire(h, env)
    local cache, loading = {}, {}
    local NIL = {} -- cached marker for a file that returned nothing
    return function(path)
        if type(path) ~= "string" then strict.fault("require(path: string)") end
        local file = path .. ".lua"
        if cache[file] ~= nil then
            if cache[file] == NIL then return nil end
            return cache[file]
        end
        if loading[file] then strict.fault("circular require of " .. path) end
        local source = h.readFile(file)
        if source == nil then return nil end
        -- selene: allow(incorrect_standard_library_use) -- its std has the pre-5.2 load/loadfile
        local chunk, err = load(source, "@" .. h.label .. "/" .. file, "t", env)
        if not chunk then error(err, 2) end
        loading[file] = true
        local result = chunk()
        loading[file] = nil
        cache[file] = result == nil and NIL or result
        return result
    end
end

-- Build a fresh environment for one plugin instance.
---@param h table the harness
---@param instance table its `subs` table is filled by the Event namespace
---@return table env
function M.build(h, instance)
    local env = {}
    for _, name in ipairs(BASE) do
        env[name] = _G[name]
    end
    for _, name in ipairs(LIBS) do
        env[name] = copy(_G[name])
    end
    -- Whether the client has string.dump is unknown, so a plugin shouldn't rely on it.
    env.string.dump = nil
    env.coroutine = budgetedCoroutine()
    for name, enabled in pairs(h.stdlib) do
        if enabled then
            assert(OPT_IN[name], "stdlib opt-in only covers os and io, not " .. name)
            env[name] = copy(OPT_IN[name])
        end
    end
    env._G = env

    local events = require("tests.harness.api.events")
    env.Event = events.namespace(instance)
    for _, module in ipairs(API_MODULES) do
        require(module).install(h, env)
    end
    env.require = makeRequire(h, env)

    -- Register every API global for the stub self-test: anything that isn't stdlib.
    local stdlib = {}
    for _, name in ipairs(BASE) do
        stdlib[name] = true
    end
    for _, name in ipairs(LIBS) do
        stdlib[name] = true
    end
    for name in pairs(env) do
        local declared = strict.declared._G and strict.declared._G[name]
        if not stdlib[name] and not OPT_IN[name] and name ~= "_G" and not declared then
            strict.declare("_G", name, "global")
        end
    end

    return setmetatable(env, {
        __index = function(_, name)
            if WITHHELD[name] then
                local why = OPT_IN[name] and "absent in the client; a test can opt in"
                    or "client availability unknown"
                strict.fault(
                    "not provided in the harness sandbox: " .. tostring(name) .. " (" .. why .. ")"
                )
            end
            strict.fault("unmocked API: " .. tostring(name))
        end,
    })
end

return M
