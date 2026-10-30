-- var.VarPlayer / var.VarClient: VarType objects by name (var.VarPlayer.NAME) or ID
-- (var.VarPlayer.FromID(id)), reading `.value` from the world.
--
-- Names and IDs come from docs/vars/vars.csv. A name it lacks faults (a typo, or a var the API
-- doesn't expose). FromID returns nil for an ID it lacks: the catalog holds every var
-- plugins/var-dump got back from FromID, though the client may raise rather than return nil.

local recording = require("dev/recording")

local catalog = require("tests.harness.catalog")
local strict = require("tests.harness.strict")
local stubs = require("tests.harness.stubs")
local world = require("tests.harness.world")

local M = {}

M.ValueType = stubs.value("game/config/vartype.lua", "ValueType")

local VarType = strict.class("VarType", {
    fields = {
        id = function(s)
            return s.rec.id
        end,
        configName = function(s)
            return s.rec.name
        end,
        typeName = function(s)
            return s.rec.domain
        end,
        valueType = function(s)
            return M.ValueType[s.rec.type]
        end,
        value = function(s)
            local v = world.varValue(s.h.world.state, s.rec)
            if v == nil then
                local config = recording.configPath("var", s.rec.domain, s.rec.name)
                local path = recording.memberPath(config, "value")
                return s.h:recorded(
                    path,
                    "unmocked state: " .. path .. " was never set (h.world:setVar)"
                )
            end
            return v
        end,
        isVarBit = function(s)
            return s.rec.baseVar ~= nil
        end,
        -- Nil unless a VarBit, per the VarType properties table.
        baseVar = function(s)
            return s.rec.baseVar and M.proxy(s.h, s.rec.domain, s.rec.baseVar)
        end,
        varBitMask = function(s)
            return s.rec.mask
        end,
    },
})

local VarNamespace = strict.class("_global.var", {
    fields = {
        VarPlayer = "VarPlayer",
        VarClient = "VarClient",
    },
})
-- FromID is declared inline in the stub: `VarPlayer { [string]: VarType, FromID: ... }`.
strict.declare("_global.var", "VarPlayer.FromID", "inline")
strict.declare("_global.var", "VarClient.FromID", "inline")

-- The VarType proxy for a var, one per var per harness so `==` works as in the client.
---@param h table the harness
---@param domain string
---@param key string|integer name or ID
---@return table
function M.proxy(h, domain, key)
    local rec = world.varRecord(domain, key)
    local cache = h.varProxies
    local k = rec.domain .. ":" .. rec.id
    cache[k] = cache[k] or VarType.new({ h = h, rec = rec })
    return cache[k]
end

---@param h table the harness
---@param env table the sandbox being built
function M.install(h, env)
    local domains = {}
    for _, domain in ipairs({ "VarPlayer", "VarClient" }) do
        local fromID = function(varId)
            if math.type(varId) ~= "integer" then
                strict.fault("var." .. domain .. ".FromID expects an integer ID")
            end
            return catalog.var(domain, varId) and M.proxy(h, domain, varId)
        end
        domains[domain] = strict.lookup("var." .. domain, function(name)
            if not catalog.var(domain, name) then
                strict.fault(
                    string.format(
                        "unmocked API: var.%s.%s is not in docs/vars/vars.csv",
                        domain,
                        name
                    )
                )
            end
            return M.proxy(h, domain, name)
        end, { extra = { FromID = fromID } })
    end
    env.var = VarNamespace.new(domains)
    env.ValueType = strict.enum("ValueType", M.ValueType)
end

return M
