-- Self-tests: var.VarPlayer / var.VarClient and VarTransmit. Var names and IDs are real ones
-- from docs/vars/vars.csv.

local harness = require("tests.harness")

local function plugin(main)
    return { ["main.lua"] = main }
end

describe("vars", function()
    it("serves a var by name and by ID as the same object, reading the world", function()
        local h = harness.new(plugin([[
            local byName = var.VarPlayer.ABSYSTEM
            same = byName == var.VarPlayer.FromID(5264)
            value, id, name, domain = byName.value, byName.id, byName.configName, byName.typeName
            valueType = byName.valueType == ValueType.INTEGER
        ]]))
        h.world:setVar("VarPlayer", "ABSYSTEM", 7)
        h:load()
        assert.is_true(h.env.same)
        assert.are.same({ 7, 5264, "ABSYSTEM", "VarPlayer" }, {
            h.env.value,
            h.env.id,
            h.env.name,
            h.env.domain,
        })
        assert.is_true(h.env.valueType)
    end)

    it("fires VarTransmit on every set, changed or not, with the var object", function()
        local h = harness.new(plugin([[
            Event.VarTransmit.Subscribe("v", function(ev)
                print(ev.var == var.VarClient.ACC_CREATE_LAST_RECOMMENDATION, ev.oldValue, ev.newValue)
            end)
        ]]))
        h.world:setVar("VarClient", "ACC_CREATE_LAST_RECOMMENDATION", "a")
        h:load()
        h.world:setVar("VarClient", "ACC_CREATE_LAST_RECOMMENDATION", "b")
        h.world:setVar("VarClient", "ACC_CREATE_LAST_RECOMMENDATION", "b")
        assert.are.equal("true a b\ntrue b b", h:output())
    end)

    it("faults on a var name the catalog lacks, and returns nil for an unknown ID", function()
        assert.matches(
            "unmocked API: var.VarPlayer.NOT_A_REAL_VAR is not in docs/vars/vars.csv",
            harness.errorOf(function()
                harness.load(plugin("local v = var.VarPlayer.NOT_A_REAL_VAR"))
            end)
        )
        local h = harness.load(plugin("missing = var.VarPlayer.FromID(999999) == nil"))
        assert.is_true(h.env.missing)
    end)

    it("faults on reading a value the test never set", function()
        assert.matches(
            "var.VarPlayer.ABSYSTEM.value was never set",
            harness.errorOf(function()
                harness.load(plugin("local v = var.VarPlayer.ABSYSTEM.value"))
            end)
        )
    end)

    it("checks values against the var's type", function()
        local h = harness.new(plugin(""))
        assert.has_error(function()
            h.world:setVar("VarPlayer", "ABSYSTEM", "seven")
        end)
        assert.has_error(function()
            h.world:setVar("VarPlayer", "FRIEND_SORT_MODE", 8) -- a 3-bit VarBit
        end)
        h.world:setVar("VarPlayer", "FRIEND_SORT_MODE", 7)
    end)

    it("describes VarBits as the VarType page's example does", function()
        local h = harness.load(plugin([[
            local bit = var.VarPlayer.FRIEND_SORT_MODE
            isBit, mask, base = bit.isVarBit, bit.varBitMask, bit.baseVar.configName
            plain = var.VarPlayer.ABSYSTEM.isVarBit
            noBase = var.VarPlayer.ABSYSTEM.baseVar == nil
        ]]))
        assert.is_true(h.env.isBit)
        assert.are.equal(56, h.env.mask) -- bits 3-5
        assert.are.equal("OPTION_TOGGLE1", h.env.base)
        assert.is_false(h.env.plain)
        assert.is_true(h.env.noBase)
    end)

    it("keeps var values read-only to the plugin", function()
        assert.matches(
            "VarType.value is read%-only",
            harness.errorOf(function()
                harness.load(plugin("var.VarPlayer.ABSYSTEM.value = 1"))
            end)
        )
    end)
end)
