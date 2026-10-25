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

local Plugin = strict.class("Plugin", {
    statics = {
        HasPermission = function(s, perm)
            M.checkPermission(perm)
            return s.h.world.state.permissions.granted[perm] == true
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
    local urls = h.manifest.urls or {}
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
