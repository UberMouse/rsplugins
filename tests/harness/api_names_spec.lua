-- Guards the mocks against invented APIs: every global and member the harness serves must be
-- declared in the stubs (docs/api/generated, plus docs/api/types.lua for `var`/`config`), with
-- the same call form. A name the stubs get wrong goes in OFFICIAL_ONLY with the page that
-- proves it.

local harness = require("tests.harness")
local strict = require("tests.harness.strict")
local stubs = require("tests.harness.stubs")

local OFFICIAL_ONLY = {
    ["Inv.isValid"] = "https://developer.runescape.com/rs/game/inventory.html#properties "
        .. "(the stub calls it `valid`)",
}

-- Whether the stubs declare `owner.member` as a member of this kind.
---@return boolean
local function inStubs(index, owner, member, kind)
    if owner == "_G" then
        if kind == "enum" then return index.enums[member] == true end
        return index.globals[member] ~= nil
    end
    local fields = index.classes[owner] or {}
    if kind == "inline" then
        -- "VarPlayer.FromID": a function listed inside a field's type, e.g.
        -- `---@field VarPlayer { [string]: VarType, FromID: fun(...) }`.
        local field, fn = member:match("^([%w_]+)%.([%w_]+)$")
        local line = fields[field]
        return line ~= nil and line:find(fn .. ":", 1, true) ~= nil
    end
    if kind == "field" then return fields[member] ~= nil end
    -- EventSubscription declares Subscribe/Unsubscribe as fun-typed fields, not functions.
    if kind == "method" then
        return (index.methods[owner] or {})[member] ~= nil or fields[member] ~= nil
    end
    if kind == "static" then
        return (index.statics[owner] or {})[member] ~= nil or fields[member] ~= nil
    end
    error("unknown kind " .. kind)
end

describe("mocked API names", function()
    -- Loading a plugin builds every global; payload classes are stub-built by construction.
    harness.load({ ["main.lua"] = "" })
    local index = stubs.index()

    it("are all declared in the stubs, with the same call form", function()
        local missing = {}
        for owner, members in pairs(strict.declared) do
            for member, kind in pairs(members) do
                local name = owner .. "." .. member
                if not OFFICIAL_ONLY[name] and not inStubs(index, owner, member, kind) then
                    missing[#missing + 1] = name .. " (" .. kind .. ")"
                end
            end
        end
        table.sort(missing)
        assert.are.same({}, missing)
    end)

    it("cover the surface this harness promises", function()
        local d = strict.declared
        assert.are.equal("method", d.PersistentDB.Get)
        assert.are.equal("static", d.Player.GetEntity)
        assert.are.equal("method", d.HTTPRequest.Post)
        assert.are.equal("static", d.HTTPRequest.new)
        assert.are.equal("field", d.Plugin.urls)
        assert.are.equal("global", d._G.require)
    end)

    it("would catch an invented name or a wrong call form", function()
        assert.is_false(inStubs(index, "Player", "GetTrackingIDs", "static"))
        assert.is_false(inStubs(index, "PersistentDB", "Get", "static"))
        assert.is_false(inStubs(index, "_G", "World2", "global"))
    end)

    it("list each OFFICIAL_ONLY name because the stub really lacks it", function()
        for name in pairs(OFFICIAL_ONLY) do
            local owner, member = name:match("^(.-)%.([^.]+)$")
            assert(not inStubs(index, owner, member, "field"), name .. " is in the stubs now")
        end
    end)
end)
