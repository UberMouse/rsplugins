-- Strict proxies for the mocked API. Every mocked table, object and event payload is built
-- here, so that:
--   * reading a member the mock does not declare raises `unmocked API: <Class>.<member>`
--     instead of returning a silent nil;
--   * every declared member lands in one registry (`M.declared`), which the stub self-test
--     (tests/harness/api_names_spec.lua) checks against docs/api/generated;
--   * calling a method with `.` or a static function with `:` is caught (the arguments
--     would be shifted by one).
--
-- Errors the harness raises go through M.fault, which also records them. A plugin that wraps
-- an API call in pcall would otherwise swallow the error; the runtime re-raises any fault
-- recorded during a plugin call once the call returns (runtime.lua). A fault a plugin may
-- provoke on purpose to probe for something optional (a manifest url) is raised unrecorded.

local M = {}

-- Every fault raised so far, in order. The runtime compares its length before and after a
-- plugin call.
M.faults = {}

-- Source prefix of the harness's own files, e.g. "@./tests/harness/".
local HARNESS = debug.getinfo(1, "S").source:match("^(.*/)strict%.lua$") or "@tests/harness/"

-- Raise a harness error and record it. The error is positioned at the first caller outside
-- tests/harness/: the plugin line that misused the API, or the spec line that built a bad
-- world op. (Counting frames instead breaks on Lua's tail calls, which drop frames.)
---@param message string
---@param catchable boolean? true to let a pcall in the plugin catch it for good
function M.fault(message, catchable)
    if not catchable then M.faults[#M.faults + 1] = message end
    local level = 2
    while true do
        local info = debug.getinfo(level, "S")
        if not info then
            level = 1 -- no caller outside the harness: report the fault site itself
            break
        end
        if info.what ~= "C" and info.source:sub(1, #HARNESS) ~= HARNESS then break end
        level = level + 1
    end
    error(message, level)
end

-- Fault from a handler that must not return (a __pairs/__len that has no answer to give).
---@param message string
---@return any never returns; typed any so `return refuse(...)` satisfies a handler's declared return
local function refuse(message)
    M.fault(message)
    error("unreachable: fault raises")
end

-- debug.getinfo's `what` ("Lua", "main" or "C") for the first frame below the harness's own
-- Lua frames: the code that called into the mocked API. "C" means the API function was handed
-- straight to a C function such as pcall. "tail" means a Lua function tail-called it
-- (`return Event.X.Unsubscribe(k)`), which drops that function's frame, so whatever called it
-- (pcall, say) shows below. The same walk as M.fault, but a C frame stops it.
---@return string
function M.callerKind()
    local level, outermost = 2, nil
    while true do
        local info = debug.getinfo(level, "St")
        if not info then return "main" end -- nothing below the harness: no caller to blame
        if info.what == "C" or info.source:sub(1, #HARNESS) ~= HARNESS then
            if outermost and outermost.istailcall then return "tail" end
            return info.what
        end
        outermost = info
        level = level + 1
    end
end

-- A table's keys in a fixed order (grouped by type name, so numbers before strings), so a
-- fault over several bad entries always names the same one.
---@param t table
---@return any[]
function M.sortedKeys(t)
    local keys = {}
    for k in pairs(t) do
        keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b)
        if type(a) ~= type(b) then return type(a) < type(b) end
        if type(a) == "number" or type(a) == "string" then return a < b end
        return tostring(a) < tostring(b)
    end)
    return keys
end

-- Registry of declared API members: declared[owner][member] = kind, where kind is "global",
-- "field", "method", "static" or "enum". `owner` is the stub class name ("Inv",
-- "VarTransmitEventPayload", "_global.var"...) or "_G" for globals.
M.declared = {}

---@param owner string
---@param member string
---@param kind string
function M.declare(owner, member, kind)
    M.declared[owner] = M.declared[owner] or {}
    M.declared[owner][member] = kind
end

-- The message for an API call made with the wrong separator.
---@param class string
---@param member string
---@param want string the separator the API expects
---@param got string
---@return string
local function formatCall(class, member, want, got)
    return string.format(
        "%s%s%s called with '%s': the API declares it as %s%s%s",
        class,
        got,
        member,
        got,
        class,
        want,
        member
    )
end

-- A proxy class. `def` lists what the mock serves, keyed by member name:
--   fields   = { name = function(state) return value end }
--   methods  = { name = function(state, ...) end }   called as obj:name(...)
--   statics  = { name = function(state, ...) end }   called as Obj.name(...)
--   writable = { name = true }                       field may be assigned (stored in state)
--   setters  = { name = function(state, value) end } field assigned through a function, which
--                                                    checks the value (list it in `fields` too,
--                                                    for the read)
--   undeclared = true                                keep it out of M.declared: for fakes of
--                                                    another plugin's exports (PrettyUI), which
--                                                    the API stubs rightly lack
--   eq = function(stateA, stateB) return bool end    `==` between two objects of the class,
--                                                    for a client type that hands out a fresh
--                                                    userdata per call yet compares equal
--   tostring = function(state) return string end     the client's tostring() text, where it
--                                                    isn't the usual type name
-- `state` is the per-object table passed to new(); getters read the live world through it,
-- so an object always reflects current state rather than a snapshot.
---@param name string the stub class name, used in error messages and the registry
---@param def table
---@return table class with a `new(state)` constructor
function M.class(name, def)
    local fields, methods, statics = def.fields or {}, def.methods or {}, def.statics or {}
    local writable = def.writable or {}
    local setters = def.setters or {}
    if not def.undeclared then
        for k in pairs(fields) do
            M.declare(name, k, "field")
        end
        for k in pairs(methods) do
            M.declare(name, k, "method")
        end
        for k in pairs(statics) do
            M.declare(name, k, "static")
        end
    end

    local class = { name = name }
    local states = setmetatable({}, { __mode = "k" }) -- proxy -> state

    -- Returns its arguments. `return passthrough(method(...))` keeps the wrapper's frame while
    -- the mock runs (a plain `return method(...)` would tail-call it away), so callerKind can
    -- tell whether the plugin tail-called the wrapper.
    local function passthrough(...)
        return ...
    end

    local mt = {
        __name = name,
        __index = function(proxy, key)
            local s = states[proxy]
            if fields[key] then return fields[key](s) end
            local method = methods[key]
            if method then
                return function(self, ...)
                    if self ~= proxy then M.fault(formatCall(name, key, ":", ".")) end
                    return passthrough(method(s, ...))
                end
            end
            local static = statics[key]
            if static then
                return function(first, ...)
                    if first == proxy then M.fault(formatCall(name, key, ".", ":")) end
                    return passthrough(static(s, first, ...))
                end
            end
            M.fault("unmocked API: " .. name .. "." .. tostring(key))
        end,
        __newindex = function(proxy, key, value)
            if setters[key] then
                setters[key](states[proxy], value)
                return
            end
            if not writable[key] then
                M.fault(name .. "." .. tostring(key) .. " is read-only in the harness")
            end
            states[proxy][key] = value
        end,
        __tostring = function(proxy)
            if def.tostring then return def.tostring(states[proxy]) end
            return name
        end,
        -- pairs and # over sol userdata are unprobed (only getmetatable listing members is
        -- recorded, docs/api-concepts.md "Usertype members"); the empty proxy would walk nothing.
        __pairs = function()
            return refuse("pairs over a client userdata: unprobed (" .. name .. ")")
        end,
        __len = function()
            return refuse("# over a client userdata: unprobed (" .. name .. ")")
        end,
    }
    if def.eq then
        mt.__eq = function(a, b)
            local sa, sb = states[a], states[b]
            return sa ~= nil and sb ~= nil and def.eq(sa, sb)
        end
    end

    ---@param state table?
    ---@return table proxy
    function class.new(state)
        local proxy = setmetatable({}, mt)
        states[proxy] = state or {}
        return proxy
    end

    return class
end

-- A read-only enum table: known values index normally, unknown names fault. `opts` says what
-- pairs() over it does:
--   iterable = true     serves the values (probed: PluginPermissions lists its members)
--   refusal  = "text"   faults with `text`, a probed refusal (PersistentDBType is "not
--                       recognized as a container", docs/api-concepts.md)
--   neither             faults as unprobed: the client's answer isn't recorded
---@param name string
---@param values table name -> value
---@param opts { iterable: boolean?, refusal: string? }?
---@return table
function M.enum(name, values, opts)
    opts = opts or {}
    assert(not (opts.iterable and opts.refusal), "enum opts: iterable and refusal are exclusive")
    M.declare("_G", name, "enum")
    local copy = {}
    for k, v in pairs(values) do
        copy[k] = v
    end
    return setmetatable({}, {
        __index = function(_, key)
            local v = copy[key]
            if v == nil then M.fault("unmocked API: " .. name .. "." .. tostring(key)) end
            return v
        end,
        __newindex = function(_, key)
            M.fault(name .. "." .. tostring(key) .. " is read-only")
        end,
        __pairs = function()
            if opts.iterable then return next, copy, nil end
            return refuse("pairs over " .. name .. ": " .. (opts.refusal or "unprobed"))
        end,
    })
end

-- A lookup table whose keys are resolved on demand (var.VarPlayer.NAME, config.Obj.NAME):
-- `lookup(key)` returns the value or faults. `extra` holds fixed members such as FromID.
-- pairs() over it faults as unprobed (the keys aren't held, so it would silently walk nothing)
-- unless `opts.iterable`, which serves `extra` (Plugin.urls, probed to iterate).
---@param lookup fun(key: any): any
---@param extra table?
---@param opts { iterable: boolean? }?
---@return table
function M.lookup(lookup, extra, opts)
    extra = extra or {}
    local iterable = opts and opts.iterable
    return setmetatable({}, {
        __pairs = function()
            if iterable then return next, extra, nil end
            return refuse("pairs over a lookup table: unprobed")
        end,
        __index = function(_, key)
            if extra[key] ~= nil then return extra[key] end
            return lookup(key)
        end,
        __newindex = function(_, key)
            M.fault("cannot assign " .. tostring(key) .. ": config tables are read-only")
        end,
    })
end

return M
