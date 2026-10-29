-- What the API stubs in docs/api/ declare (see docs/README.md). The mocks take their enums,
-- event names and payload fields from here rather than retyping them, and the self-test
-- (api_names_spec.lua) checks every mocked member against `index()`.

local paths = require("tests.harness.paths")

local M = {}

-- Parsed once per process: it reads every generated stub file.
local cached = nil ---@type table?

-- Index the stubs: classes (with their ---@field names and `: Parent` classes), static
-- functions (`function T.f(`), methods (`function T:M(`), global functions and tables, and
-- enums. A class whose functions are written against a local (`---@class ui.Component` then
-- `local Component = {}` and `function Component:SetPos(`) gets them under both names.
---@return table
function M.index()
    if cached then return cached end
    local index =
        { classes = {}, parents = {}, statics = {}, methods = {}, globals = {}, enums = {} }
    local files = {}
    local find = assert(io.popen("find '" .. paths.repo("docs/api/generated") .. "' -name '*.lua'"))
    for file in find:lines() do
        files[#files + 1] = file
    end
    find:close()
    assert(#files > 0, "docs/api/generated is empty or missing: enter the dev shell (direnv)")
    files[#files + 1] = paths.repo("docs/api/types.lua")

    local function add(group, owner, member, line)
        group[owner] = group[owner] or {}
        group[owner][member] = line
    end
    for _, file in ipairs(files) do
        local class = nil ---@type string?
        local aliases = {} -- local name -> class, for this file
        for line in io.lines(file) do
            local name = line:match("^%-%-%-@class%s+([%w_%.]+)")
            local field = line:match("^%-%-%-@field%s+([%w_]+)")
            if name then
                class = name
                index.classes[name] = index.classes[name] or {}
                local parent = line:match("^%-%-%-@class%s+[%w_%.]+%s*:%s*([%w_%.]+)")
                if parent then index.parents[name] = parent end
            elseif field and class then
                index.classes[class][field] = line
            elseif not line:match("^%-%-%-") then
                local alias = line:match("^local%s+([%w_]+)%s*=%s*{}")
                if alias and class then aliases[alias] = class end
                class = nil
            end
            local enum = line:match("^%-%-%-@enum%s+([%w_%.]+)")
            if enum then index.enums[enum] = true end
            local owner, static = line:match("^function%s+([%w_%.]+)%.([%w_]+)%s*%(")
            if owner then add(index.statics, owner, static, line) end
            local mowner, method = line:match("^function%s+([%w_%.]+):([%w_]+)%s*%(")
            if mowner then
                add(index.methods, mowner, method, line)
                if aliases[mowner] then add(index.methods, aliases[mowner], method, line) end
            end
            local fn = line:match("^function%s+([%w_]+)%s*%(")
            local tbl = line:match("^([%w_]+)%s*=")
            if fn or tbl then index.globals[fn or tbl] = line end
        end
    end
    cached = index
    return index
end

-- The field names of a stub class, as a set.
---@param class string
---@return table<string, string> # field name -> its ---@field line
function M.fields(class)
    local fields = M.index().classes[class]
    assert(fields, "no ---@class " .. class .. " in docs/api")
    return fields
end

-- Load one stub file (they are plain Lua tables plus empty functions) and return a global it
-- defines, e.g. the ChatType enum from core/events.lua.
---@param file string path under docs/api/generated, e.g. "core/events.lua"
---@param name string
---@param seed table? globals the file assumes another file made, e.g. `{ ui = {} }`. A file
--- that assigns one again (`ui = {}` after its enums) keeps the seeded table
---@return table
function M.value(file, name, seed)
    local env = {}
    if seed then
        local store = seed
        env = setmetatable({}, {
            __index = store,
            __newindex = function(_, k, v)
                if store[k] == nil then store[k] = v end
            end,
        })
    end
    -- selene: allow(incorrect_standard_library_use) -- its std has the pre-5.2 load/loadfile
    local chunk = assert(loadfile(paths.repo("docs/api/generated/" .. file), "t", env))
    chunk()
    return assert(env[name], name .. " is not defined in docs/api/generated/" .. file)
end

return M
