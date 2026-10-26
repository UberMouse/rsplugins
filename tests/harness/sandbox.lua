-- The global environment a plugin runs in: a fresh table per load, holding a whitelist of
-- the Lua stdlib, the mocked API and `require`. Reading any other global faults with
-- `unmocked API: <name>`, so a plugin using an API the harness doesn't model fails its test
-- instead of quietly getting nil. Plugins may still assign globals (PluginShutdown...).
--
-- `_G` is not that environment. In the client a plugin's env holds its own globals, `Plugin`
-- and `require`, and falls through to one table of stdlib and API shared by every plugin,
-- which is what `_G` names (dev-bridge eval, docs/api-concepts.md). The harness's `_G` reads
-- like that table and faults on any write to it.

local prettyui = require("tests.harness.api.prettyui")
local runtime = require("tests.harness.runtime")
local strict = require("tests.harness.strict")

local M = {}

-- Base functions and libraries plugins get: the stdlib the client's shared table held when
-- dev-bridge listed it (2026-10-26), bar load (opt-in) and collectgarbage (wrapped, below).
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
local LIBS = { "string", "table", "math", "coroutine" }

-- Why each opt-in global (OPT_IN, below) is withheld by default.
local OPT_IN_WHY = {
    -- recorder-demo's probe, 2026-10-25.
    os = "absent in the client; a test can opt in",
    io = "absent in the client; a test can opt in",
    -- dev-bridge's hello, 2026-10-26. Only the dev bridge's eval should run Lua from text.
    load = "present in the client, for dev tools only; a test can opt in",
}
-- Standard globals withheld, with a clearer message than "unmocked API". All but load are
-- absent in the client (dev-bridge listed its globals, 2026-10-26).
local WITHHELD = {
    debug = true,
    load = true,
    loadfile = true,
    dofile = true,
    package = true,
    os = true,
    io = true,
    utf8 = true,
}

-- The collectgarbage options that leave the host VM (busted's) as it was.
local GC_OPTIONS = { collect = true, count = true, step = true, isrunning = true }

-- Globals of the plugin's own env in the client, so not in its _G (dev-bridge, 2026-10-26).
local PLUGIN_ENV_ONLY = { Plugin = true, require = true }

local API_MODULES = {
    "tests.harness.api.plugin",
    "tests.harness.api.persistentdb",
    "tests.harness.api.http",
    "tests.harness.api.vars",
    "tests.harness.api.player",
    "tests.harness.api.inventory",
    "tests.harness.api.chat",
    "tests.harness.api.console",
    "tests.harness.api.ui",
    "tests.harness.api.helpers",
}

-- The plugin dependencies the harness has a fake for, by mod.io ID. Only the object form with
-- the numeric ID (`{ "prettyui": 6398181 }`, any key as the global) was probed in the client.
local DEPENDENCY_FAKES = { [prettyui.MOD_ID] = prettyui }
-- Other ways a manifest might name a faked dependency (a folder name, or the ID as a string).
-- They fail the load: whether the client resolves them is unconfirmed (docs/testing.md).
local UNCONFIRMED_NAMES =
    { prettyui = prettyui.MOD_ID, [tostring(prettyui.MOD_ID)] = prettyui.MOD_ID }

-- The global an array-form dependency gets: its name, with characters that aren't valid in a
-- Lua identifier made `_` and a leading digit prefixed with `_` (docs/plugin-anatomy.md).
---@param name string
---@return string
local function luaName(name)
    local out = tostring(name):gsub("[^%w_]", "_")
    if out:match("^%d") then out = "_" .. out end
    return out
end

-- A manifest value as JSON would show it, for fault messages.
---@param v any
---@return string
local function jsonValue(v)
    return type(v) == "string" and string.format("%q", v) or tostring(v)
end

-- Expose each dependency the manifest lists as its global; one without a fake, or a faked one
-- named in a form the client isn't known to accept, fails the load. The fakes are always
-- present and enabled, so optional ones are never nil.
---@param h table
---@param env table
local function installDependencies(h, env)
    for _, field in ipairs({ "requiredDependencies", "optionalDependencies" }) do
        local deps = h.manifest[field]
        if deps ~= nil and type(deps) ~= "table" then
            error("plugin.json " .. field .. " must be an array or an object", 0)
        end
        deps = deps or {}
        for _, key in ipairs(strict.sortedKeys(deps)) do
            local target = deps[key]
            local global = type(key) == "number" and luaName(target) or key
            local fake = type(key) == "string"
                and type(target) == "number"
                and DEPENDENCY_FAKES[target]
            if not fake then
                local id = UNCONFIRMED_NAMES[tostring(target):lower()]
                if id then
                    error(
                        string.format(
                            "plugin.json %s: %s names a faked dependency in a form unconfirmed "
                                .. "in the client; use the object form with the numeric mod.io "
                                .. 'ID, e.g. { "%s": %d }',
                            field,
                            type(key) == "number" and "[" .. jsonValue(target) .. "]"
                                or string.format("%q: %s", key, jsonValue(target)),
                            global,
                            id
                        ),
                        0
                    )
                end
                error(
                    string.format(
                        "plugin.json %s: the harness has no fake for dependency %s (global %s)",
                        field,
                        tostring(target),
                        global
                    ),
                    0
                )
            end
            fake.install(h, env, global)
        end
    end
end

---@param lib table
---@return table
local function copy(lib)
    local out = {}
    for k, v in pairs(lib) do
        out[k] = v
    end
    return out
end

-- `load` for one sandbox, so a spec can't reach outside it: text chunks only (a binary chunk
-- can corrupt the VM), and a chunk given no env argument gets the plugin's env, never the
-- host's _G. An env argument given, even nil, is used, as in Lua 5.4.
---@param env table
---@return function
local function sandboxedLoad(env)
    return function(chunk, chunkname, mode, ...)
        if type(chunk) ~= "string" then
            strict.fault("load: the harness models string chunks only")
        end
        if mode ~= nil and mode ~= "t" then
            strict.fault('load: the harness allows mode "t" only')
        end
        local chunkEnv = env
        if select("#", ...) > 0 then chunkEnv = (...) end
        -- selene: allow(incorrect_standard_library_use) -- its std has the pre-5.2 load
        return load(chunk, chunkname, "t", chunkEnv)
    end
end

-- Withheld unless a test opts in (opts.stdlib = { os = true, load = true }); each builds the
-- global for one sandbox.
local OPT_IN = {
    os = function()
        return copy(os)
    end,
    io = function()
        return copy(io)
    end,
    load = sandboxedLoad,
}

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

-- The plugin's `_G`: what the client's shared global table holds, which is `env` as built
-- so far less PLUGIN_ENV_ONLY. Any write faults, since the client's would reach every plugin.
-- It is an empty proxy so that no write escapes __newindex; so `rawget(_G, name)` is nil for
-- every name, where the client finds the stdlib and API.
---@param env table
---@return table
local function globalTable(env)
    local held = {}
    for name, v in pairs(env) do
        if not PLUGIN_ENV_ONLY[name] then held[name] = v end
    end
    local proxy = {}
    held._G = proxy -- the client's _G._G is _G
    return setmetatable(proxy, {
        __index = function(_, name)
            if held[name] ~= nil then return held[name] end
            if PLUGIN_ENV_ONLY[name] or rawget(env, name) ~= nil then
                strict.fault(
                    "_G."
                        .. tostring(name)
                        .. ": the client's _G is the table every plugin shares, not this "
                        .. "plugin's globals; read it plainly, or with rawget(_ENV, name)"
                )
            end
            return env[name] -- absent, withheld or unmocked, as for a plain read
        end,
        __newindex = function(_, name)
            strict.fault(
                "_G."
                    .. tostring(name)
                    .. " assigned: the client's _G is the table every plugin shares, so the "
                    .. "write would reach them all; assign the plugin's own global plainly"
            )
        end,
        __pairs = function()
            return next, held, nil
        end,
    })
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
    env.coroutine = budgetedCoroutine()
    env.collectgarbage = function(opt, ...)
        if opt ~= nil and not GC_OPTIONS[opt] then
            strict.fault("collectgarbage(" .. tostring(opt) .. ") is not modelled in the harness")
        end
        -- selene: allow(incorrect_standard_library_use) -- its std has no collectgarbage args
        return collectgarbage(opt, ...)
    end
    -- Lua starts with warnings off, and where the client would send them is unknown.
    env.warn = function(...)
        for i = 1, select("#", ...) do
            if type((select(i, ...))) ~= "string" then strict.fault("warn(msg1: string, ...)") end
        end
    end
    for name, enabled in pairs(h.stdlib) do
        if enabled then
            assert(OPT_IN[name], "stdlib opt-in only covers os, io and load, not " .. name)
            env[name] = OPT_IN[name](env)
        end
    end
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
    stdlib.collectgarbage, stdlib.warn = true, true
    for name in pairs(env) do
        local declared = strict.declared._G and strict.declared._G[name]
        if not stdlib[name] and not OPT_IN[name] and not declared then
            strict.declare("_G", name, "global")
        end
    end
    env._G = globalTable(env)
    -- After the registry above: dependency globals are other plugins' exports, not API the
    -- stubs declare.
    installDependencies(h, env)
    for name in pairs(h.absent) do
        assert(env[name] == nil, "opts.absent names " .. name .. ", which the sandbox provides")
    end

    return setmetatable(env, {
        __index = function(_, name)
            -- A global the test models as missing from the client (opts.absent) reads nil.
            if h.absent[name] then return nil end
            if WITHHELD[name] then
                local why = OPT_IN_WHY[name] or "absent in the client"
                strict.fault(
                    "not provided in the harness sandbox: " .. tostring(name) .. " (" .. why .. ")"
                )
            end
            strict.fault("unmocked API: " .. tostring(name))
        end,
    })
end

return M
