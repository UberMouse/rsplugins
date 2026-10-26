-- Prints where the API stubs and the live client disagree, from the client's surface snapshot
-- (tests/fixtures/client-surface.json, made by scripts/client-surface.py): per type and
-- namespace the snapshot lists, the members only the client has (undocumented, or missing
-- from the stubs) and those only the stubs have (renamed, removed or invented), and the
-- globals the stubs lack. A starting point for extending the mocks, and for stub fixes to
-- check against the official pages. From the repo root, in the dev shell:
--
--     lua tests/harness/surface_report.lua

local dkjson = require("dkjson")
local paths = require("tests.harness.paths")
local stubs = require("tests.harness.stubs")

local snap = assert(
    dkjson.decode(assert(paths.read(paths.repo("tests/fixtures/client-surface.json")))),
    "tests/fixtures/client-surface.json is not JSON"
)
local index = stubs.index()

-- Namespaces the report leaves out: the stdlib, and tables the stubs declare another way.
local SKIP = { string = true, table = true, math = true, coroutine = true, __internal = true }

-- Lua's own globals, which the stubs don't declare.
local STDLIB = {}
for name in
    (
        "_G _VERSION assert collectgarbage coroutine error getmetatable ipairs load math "
        .. "next pairs pcall rawequal rawget rawlen rawset select setmetatable string table "
        .. "tonumber tostring type warn xpcall"
    ):gmatch("%S+")
do
    STDLIB[name] = true
end

-- Every member the stubs give a class: its fields, methods and statics, and its parents'.
---@param class string
---@return table? # nil when the stubs have no such class
local function stubMembers(class)
    if not (index.classes[class] or index.statics[class] or index.methods[class]) then
        return nil
    end
    local out = {}
    while class do
        for _, group in ipairs({ index.classes, index.methods, index.statics }) do
            for member in pairs(group[class] or {}) do
                out[member] = true
            end
        end
        class = index.parents[class]
    end
    return out
end

---@param set table
---@return string
local function sortedList(set)
    local out = {}
    for k in pairs(set) do
        out[#out + 1] = k
    end
    table.sort(out)
    return #out > 0 and table.concat(out, " ") or "-"
end

-- One block of the report: the two differences between a client member list and the stubs'.
---@param label string
---@param client table name -> type
---@param stub table? name -> true
local function compare(label, client, stub)
    if not stub then
        local n = 0
        for _ in pairs(client) do
            n = n + 1
        end
        print(string.format("%s: not in the stubs (%d members live)", label, n))
        return
    end
    local clientOnly, stubOnly = {}, {}
    for k in pairs(client) do
        if not stub[k] then clientOnly[k] = true end
    end
    for k in pairs(stub) do
        -- The probe leaves out sol's constructor, so a stub's `new` can't be checked.
        if client[k] == nil and k ~= "new" then stubOnly[k] = true end
    end
    if next(clientOnly) or next(stubOnly) then
        print(label)
        print("  client only: " .. sortedList(clientOnly))
        print("  stubs only:  " .. sortedList(stubOnly))
    end
end

---@param t table
---@return string[]
local function sortedKeys(t)
    local out = {}
    for k in pairs(t) do
        out[#out + 1] = k
    end
    table.sort(out)
    return out
end

print("Client surface captured " .. snap.captured .. " (" .. snap.version .. ")\n")
print("# Types (members of an object the snapshot reached)")
for _, owner in ipairs(sortedKeys(snap.types)) do
    local t = snap.types[owner]
    if t.members and next(t.members) then
        compare(owner .. " (" .. tostring(t.usertype) .. ")", t.members, stubMembers(owner))
    end
end
print("\n# Namespaces (keys of a global table)")
for _, name in ipairs(sortedKeys(snap.namespaces)) do
    local ns = snap.namespaces[name]
    if ns.keys and next(ns.keys) and not SKIP[name] and not index.enums[name] then
        compare(name, ns.keys, stubMembers(name))
    end
end
print("\n# Globals the stubs lack (bar Lua's own and the <Name>Event payload tables)")
local undocumented = {}
for name in pairs(snap.globals) do
    local known = index.globals[name] or index.enums[name] or STDLIB[name]
    if not known and not name:match("Event$") then undocumented[name] = true end
end
print("  " .. sortedList(undocumented))
