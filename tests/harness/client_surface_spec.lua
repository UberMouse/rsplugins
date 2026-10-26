-- Checks the mocks against the live client, not the stubs: tests/fixtures/client-surface.json
-- is the client's API surface as scripts/client-surface.py snapshots it through the dev bridge
-- (names, type() and enum numbers). Every global and member the harness serves must exist in
-- the client wherever the snapshot covers its owner, every enum value it serves must be the
-- client's, and every payload field it builds from the stubs must be on the client's payload.
-- api_names_spec.lua checks the same names against the stubs.

local dkjson = require("dkjson")
local harness = require("tests.harness")
local paths = require("tests.harness.paths")
local strict = require("tests.harness.strict")
local stubs = require("tests.harness.stubs")

local snap = assert(
    dkjson.decode(assert(paths.read(paths.repo("tests/fixtures/client-surface.json")))),
    "tests/fixtures/client-surface.json is not JSON"
)

-- Harness owner names whose members the snapshot lists under another name.
local ALIASES = {
    ["_global.config"] = "config",
    ["_global.var"] = "var",
    ["_global.id"] = "id",
    ["_global.utils"] = "utils",
    EventSubscription = "Event.Logic",
}

-- The members the client has for a harness owner, or nil when the snapshot doesn't cover it
-- (an opaque class table, or a type no snapshot instance reached, like ui.Text). A static is
-- looked for in the owner's namespace only: an instance's metatable lists sol's constructor
-- `new`, which the probe leaves out.
---@param owner string
---@param kind string the strict.declared kind
---@return table?
local function clientMembers(owner, kind)
    if owner == "_G" then
        local all = {}
        for _, part in ipairs({ snap.globals, snap.pluginEnv }) do
            for k, v in pairs(part) do
                all[k] = v
            end
        end
        return all
    end
    owner = ALIASES[owner] or owner
    local t = kind ~= "static" and snap.types[owner]
    if t and t.members and next(t.members) then return t.members end
    local ns = snap.namespaces[owner]
    if ns and ns.keys and next(ns.keys) then return ns.keys end
    return nil
end

describe("the mocks, against the live client's surface", function()
    harness.load({ ["main.lua"] = "" })

    it("serve only globals and members the client has", function()
        local missing, covered = {}, 0
        for owner, members in pairs(strict.declared) do
            for member, kind in pairs(members) do
                local client = clientMembers(owner, kind)
                -- "Inv.FromID": a function inside a table the snapshot doesn't descend into.
                if client and kind ~= "inline" then
                    covered = covered + 1
                    if client[member] == nil then
                        missing[#missing + 1] = owner .. "." .. member .. " (" .. kind .. ")"
                    end
                end
            end
        end
        table.sort(missing)
        assert.are.same({}, missing)
        -- A snapshot that covers little would pass vacuously.
        assert(covered >= 100, "only " .. covered .. " mocked members covered")
    end)

    it("serve the client's enum values", function()
        local wrong = {}
        for name, values in pairs(harness.enums) do
            local client = snap.enums[name]
            local keysOnly = not client and snap.namespaces[name] and snap.namespaces[name].keys
            if not client and not keysOnly then
                wrong[#wrong + 1] = name .. " is not in the client"
            else
                for k, v in pairs(values) do
                    if keysOnly then
                        if keysOnly[k] == nil then
                            wrong[#wrong + 1] = name .. "." .. k .. " missing"
                        end
                    elseif client[k] ~= v then
                        wrong[#wrong + 1] = string.format(
                            "%s.%s: harness %s, client %s",
                            name,
                            k,
                            tostring(v),
                            tostring(client[k])
                        )
                    end
                end
            end
        end
        table.sort(wrong)
        assert.are.same({}, wrong)
    end)

    it("build payloads with fields the client's payloads have", function()
        local missing, seen = {}, 0
        for event, client in pairs(snap.events) do
            seen = seen + 1
            for field in pairs(stubs.fields(event .. "EventPayload")) do
                if client[field] == nil then missing[#missing + 1] = event .. "." .. field end
            end
        end
        table.sort(missing)
        assert.are.same({}, missing)
        assert(seen > 0, "the snapshot has no event payloads")
    end)
end)
