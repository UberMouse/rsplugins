-- print, log, Plugin (HasPermission, urls) and PluginPermissions.

local strict = require("tests.harness.strict")
local stubs = require("tests.harness.stubs")
local world = require("tests.harness.world")

local M = {}

-- Live, each PluginPermissions value is a userdata (sol.jag::scripting::PluginPermission), the
-- same object on every read, and Plugin.HasPermission refuses anything else, its name string
-- included (docs/api-concepts.md). The harness hands out one opaque proxy per permission; the
-- world and recordings name permissions by their string, as OptionalPermissionChanged does.
local PERMISSION_META = { __name = "sol.jag::scripting::PluginPermission" }
PERMISSION_META.__tostring = function(self)
    return string.format("sol.jag::scripting::PluginPermission: %p", self)
end
local NAMES = {} -- proxy -> name
M.PluginPermissions = {} -- name -> proxy
for name in pairs(stubs.value("core/plugin.lua", "PluginPermissions")) do
    local proxy = setmetatable({}, PERMISSION_META)
    M.PluginPermissions[name], NAMES[proxy] = proxy, name
end

-- The client's error for a string where a PluginPermissions value belongs.
local STRING_PERMISSION = "stack index 1, expected userdata, received string: value is not a "
    .. "valid userdata (bad argument into 'bool(const jag::scripting::PluginPermission&)')"

-- The name of a PluginPermissions value; faults on anything else.
---@param perm any
---@return string
function M.permissionName(perm)
    local name = NAMES[perm]
    if not name then
        if type(perm) == "string" then
            strict.fault(string.format("Plugin.HasPermission(%q): %s", perm, STRING_PERMISSION))
        end
        strict.fault("not a PluginPermissions value: " .. tostring(perm))
    end
    ---@cast name -? -- fault() never returns
    return name
end

-- A manifest url as the client hands it out: an opaque object, not a string. Live (beta client
-- 951-1, 2026-10-26) `..` on it raises, tostring gives a pointer string, and only HTTPRequest.new
-- reads it. The text lives in a side table keyed by the proxy, so a plugin can't reach it.
local URL_TEXT = setmetatable({}, { __mode = "k" })
local URL_META = {
    __name = "sol.jag::scripting::LuaPluginMetadata::URL",
    __concat = function()
        strict.fault(
            "attempt to concatenate a sol.jag::scripting::LuaPluginMetadata::URL value",
            true
        )
    end,
}
URL_META.__tostring = function(self)
    return string.format("sol.jag::scripting::LuaPluginMetadata::URL: %p", self)
end

---@param text string
---@return table
local function newUrl(text)
    local proxy = setmetatable({}, URL_META)
    URL_TEXT[proxy] = text
    return proxy
end

-- The text behind a Plugin.urls value, or nil for anything else. For the HTTPRequest mock only.
---@param value any
---@return string?
function M.urlText(value)
    return URL_TEXT[value]
end

local Plugin = strict.class("Plugin", {
    statics = {
        -- Replaying, a permission neither the recording nor the test has decided faults rather
        -- than answering the not-granted default: the client may well have had it granted.
        HasPermission = function(s, value)
            local perm = M.permissionName(value)
            if s.h.replay and not s.h.world.state.permissions.known[perm] then
                strict.fault("unrecorded: Plugin.HasPermission(" .. tostring(perm) .. ")")
            end
            return world.granted(s.h.world.state, perm)
        end,
    },
    fields = {
        -- Plugin.urls.<name> for each manifest url; an unknown name is nil, as live
        -- (docs/api-concepts.md). HTTPRequest.new faults on that nil, so a test still
        -- catches a url missing from plugin.json.
        urls = "urls",
    },
})

---@param ... any
---@return string
local function joined(...)
    local parts = table.pack(...)
    for i = 1, parts.n do
        parts[i] = tostring(parts[i])
    end
    return table.concat(parts, " ", 1, parts.n)
end

---@param h table the harness
---@param env table the sandbox being built
function M.install(h, env)
    local urls = {}
    for name, text in pairs(h.manifest.urls or {}) do
        urls[name] = newUrl(text)
    end
    local lookup = strict.lookup("Plugin.urls", function()
        return nil
    end, { extra = urls, iterable = true }) -- probed: pairs() over Plugin.urls lists the manifest's urls
    env.Plugin = Plugin.new({ h = h, urls = lookup })
    env.PluginPermissions =
        strict.enum("PluginPermissions", M.PluginPermissions, { iterable = true })

    -- Console output is captured for tests to read (h:output()); `echo` also prints it.
    local function write(kind, ...)
        local text = joined(...)
        h.console[#h.console + 1] = { kind = kind, text = text }
        if h.echo then io.write("[", kind, "] ", text, "\n") end
    end
    env.print = function(...)
        write("print", ...)
    end
    env.log = function(...)
        write("log", ...)
    end
end

return M
