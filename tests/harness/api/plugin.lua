-- print, log, Plugin (HasPermission, urls) and PluginPermissions.

local strict = require("tests.harness.strict")
local stubs = require("tests.harness.stubs")

local M = {}

M.PluginPermissions = stubs.value("core/plugin.lua", "PluginPermissions")
local PERMISSIONS = {}
for _, v in pairs(M.PluginPermissions) do
    PERMISSIONS[v] = true
end

-- Fault unless `perm` is a PluginPermissions value.
---@param perm any
function M.checkPermission(perm)
    if not PERMISSIONS[perm] then
        strict.fault("not a PluginPermissions value: " .. tostring(perm))
    end
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
        HasPermission = function(s, perm)
            M.checkPermission(perm)
            local perms = s.h.world.state.permissions
            if s.h.replay and not perms.known[perm] then
                strict.fault("unrecorded: Plugin.HasPermission(" .. tostring(perm) .. ")")
            end
            return perms.granted[perm] == true
        end,
    },
    fields = {
        -- Plugin.urls.<name> for each manifest url; an unknown name faults rather than
        -- returning nil, so a test catches a url missing from plugin.json.
        urls = function(s)
            return s.urls
        end,
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
    -- Catchable: a plugin may pcall a lookup to probe for an optional url (dev/recorder does),
    -- and a probe that comes back empty is not a misuse.
    local lookup = strict.lookup(function(name)
        strict.fault("Plugin.urls." .. tostring(name) .. " is not in plugin.json urls", true)
    end, urls)
    -- The page calls urls a table, so pairs() over it lists the manifest's urls.
    getmetatable(lookup).__pairs = function()
        return next, urls, nil
    end
    env.Plugin = Plugin.new({ h = h, urls = lookup })
    env.PluginPermissions = strict.enum("PluginPermissions", M.PluginPermissions)

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
    strict.declare("_G", "print", "global")
    strict.declare("_G", "log", "global")
end

return M
