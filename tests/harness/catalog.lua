-- Real config names and IDs, so a test (and the plugin under test) can only use vars, invs and
-- objs that exist in the game. A misspelt name fails the test instead of passing against a mock
-- that would accept anything.
--   vars: docs/vars/vars.csv (every var the API exposes, from a var-dump snapshot)
--   invs, objs: the id.Inv / id.Obj tables in docs/api/consts/

local paths = require("tests.harness.paths")

local M = {}

-- Each loaded on first use and kept for the process.
local vars = nil ---@type table?
local configs = {}

-- A VarBit's "lo-hi" bit range (vars.csv `bits` column).
---@param bits string
---@return integer lo
---@return integer hi
local function bitRange(bits)
    local lo, hi = bits:match("^(%d+)%-(%d+)$")
    return assert(math.tointeger(tonumber(lo))), assert(math.tointeger(tonumber(hi)))
end

-- Built into a local and published at the end, so a failed load leaves no partial catalog.
---@return table
local function loadVars()
    local loaded = { byName = {}, byId = {} }
    local file = paths.repo("docs/vars/vars.csv")
    -- Not committed, so a fresh checkout lacks it until the catalog is built.
    local probe = io.open(file)
    if not probe then
        error(
            file
                .. " is missing: build the var catalog from a var dump (plugins/var-dump/README.md)"
        )
    end
    probe:close()
    local first = true
    for rawLine in io.lines(file) do
        local line = rawLine:gsub("\r$", "") -- the CSV has CRLF line endings
        if first then
            first = false -- header row
        else
            local domain, id, name, _, _, typeName, baseVar, bits =
                line:match("^([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*),([^,]*)$")
            assert(domain, "unexpected line in " .. file .. ": " .. line)
            local rec = {
                domain = domain,
                id = math.tointeger(tonumber(id)),
                name = name,
                type = typeName,
                baseVar = baseVar ~= "" and baseVar or nil,
            }
            if bits ~= "" then
                rec.lo, rec.hi = bitRange(bits)
                rec.mask = ((1 << (rec.hi - rec.lo + 1)) - 1) << rec.lo
            end
            loaded.byName[domain] = loaded.byName[domain] or {}
            loaded.byId[domain] = loaded.byId[domain] or {}
            loaded.byName[domain][name] = rec
            loaded.byId[domain][rec.id] = rec
        end
    end
    return loaded
end

-- A var's catalog record { domain, id, name, type, baseVar?, lo?, hi?, mask? }, by name or ID.
-- A VarBit has baseVar (its base var's name) and, where vars.csv gives its bits, lo/hi/mask.
---@param domain string "VarPlayer" or "VarClient"
---@param key string|integer
---@return table? # the record, or nil if the catalog has no such var
function M.var(domain, key)
    vars = vars or loadVars()
    local group = type(key) == "number" and vars.byId or vars.byName
    return group[domain] and group[domain][key]
end

-- name -> id and id -> name for one config type, from docs/api/consts/<kind>.lua.
---@param kind string "Inv" or "Obj"
---@return table # { byName = {}, byId = {} }
local function configTable(kind)
    if configs[kind] then return configs[kind] end
    local env = { id = {} }
    local file = paths.repo("docs/api/consts/" .. kind .. ".lua")
    -- selene: allow(incorrect_standard_library_use) -- its std has the pre-5.2 load/loadfile
    assert(loadfile(file, "t", env), "cannot load " .. file .. ": enter the dev shell (direnv)")()
    local byName, byId = env.id[kind], {}
    for name, id in pairs(byName) do
        byId[id] = name
    end
    configs[kind] = { byName = byName, byId = byId }
    return configs[kind]
end

-- A config's ID and name, looked up by either.
---@param kind string "Inv" or "Obj"
---@param key string|integer
---@return integer? id
---@return string? name
function M.config(kind, key)
    local t = configTable(kind)
    if math.type(key) == "integer" then
        ---@cast key integer
        local name = t.byId[key]
        if name then return key, name end
    elseif type(key) == "string" then
        local id = t.byName[key]
        if id then return id, key end
    end
    return nil, nil
end

return M
