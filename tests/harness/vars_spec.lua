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
        assert.matches(
            "VarPlayer.ABSYSTEM is %w+: expected an integer, got seven",
            harness.errorOf(function()
                h.world:setVar("VarPlayer", "ABSYSTEM", "seven")
            end)
        )
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

    describe("VarBit packing", function()
        -- HANDSAND_BUCKETS (2801) packs HANDSAND_BUCKETS_SAND_EXPLAINED (bit 0),
        -- HANDSAND_BUCKETS_CLAIMED_TODAY (bit 1), HANDSAND_COUNT (bits 0-6) and
        -- HANDSAND_RUNEDAY (bits 7-31).
        local WATCH = [[
            Event.VarTransmit.Subscribe("v", function(ev)
                local p = var.VarPlayer
                print(ev.var.configName, ev.oldValue, ev.newValue, p.HANDSAND_BUCKETS.value,
                    p.HANDSAND_BUCKETS_CLAIMED_TODAY.value, p.HANDSAND_COUNT.value)
            end)
        ]]

        it("reads a VarBit from its base, and a base update names the base", function()
            -- As claiming Bert's sand sent it in the var-dump change log (2026-10-25).
            local h = harness.new(plugin(WATCH))
            h.world:setVar("VarPlayer", "HANDSAND_BUCKETS", 0)
            h:load()
            h.world:setVar("VarPlayer", "HANDSAND_BUCKETS", 1)
            h.world:setVar("VarPlayer", 2801, 3)
            assert.are.equal("HANDSAND_BUCKETS 0 1 1 0 1\nHANDSAND_BUCKETS 1 3 3 1 3", h:output())
        end)

        it("writes a VarBit into its bits of the base, and the update names the VarBit", function()
            local h = harness.new(plugin(WATCH))
            h.world:setVar("VarPlayer", "HANDSAND_BUCKETS", (5 << 7) | 1) -- runeday 5, count 1
            h:load()
            h.world:setVar("VarPlayer", "HANDSAND_BUCKETS_CLAIMED_TODAY", 1)
            assert.are.equal("HANDSAND_BUCKETS_CLAIMED_TODAY 0 1 643 1 3", h:output())
            local p = h.env.var.VarPlayer
            assert.are.same({ 5, 1 }, { p.HANDSAND_RUNEDAY.value, p.FromID(-55454).value })
        end)

        it("extracts fields from a negative base and writes bit 31 as a negative base", function()
            local h = harness.load(plugin(""))
            local p = h.env.var.VarPlayer
            h.world:setVar("VarPlayer", "HANDSAND_BUCKETS", -1)
            assert.are.same({ (1 << 25) - 1, 127, 1 }, {
                p.HANDSAND_RUNEDAY.value,
                p.HANDSAND_COUNT.value,
                p.HANDSAND_BUCKETS_CLAIMED_TODAY.value,
            })
            h.world:setVar("VarPlayer", "HANDSAND_COUNT", 0)
            assert.are.equal(-128, p.HANDSAND_BUCKETS.value) -- bits 7-31 still set
            h.world:setVar("VarPlayer", "OPTION_TOGGLE1", 0)
            h.world:setVar("VarPlayer", "SLAYER_TOGGLE_SLAYER_COUNTER", 1) -- bit 31
            assert.are.equal(-2147483648, p.OPTION_TOGGLE1.value)
            h.world:setVar("VarPlayer", "SLAYER_TOGGLE_SLAYER_COUNTER", 0)
            assert.are.equal(0, p.OPTION_TOGGLE1.value)
        end)

        it("faults on a value that doesn't fit the VarBit, naming its bits", function()
            local h = harness.new(plugin(""))
            for v, shown in pairs({ [8] = "8", [-1] = "%-1" }) do
                assert.matches(
                    "VarPlayer.FRIEND_SORT_MODE is bits 3%-5 of OPTION_TOGGLE1: value must be 0..7, got "
                        .. shown,
                    harness.errorOf(function()
                        h.world:setVar("VarPlayer", "FRIEND_SORT_MODE", v)
                    end)
                )
            end
        end)

        it("faults on an int var value outside signed 32 bits, but not a LONG's", function()
            local h = harness.new(plugin(""))
            for v, shown in pairs({ [0xFFFFFFFF] = "4294967295", [-0x80000001] = "%-2147483649" }) do
                assert.matches(
                    "VarPlayer.HANDSAND_BUCKETS is INTEGER: value must be %-2147483648..2147483647, got "
                        .. shown,
                    harness.errorOf(function()
                        h.world:setVar("VarPlayer", "HANDSAND_BUCKETS", v)
                    end)
                )
            end
            h.world:setVar("VarPlayer", "HANDSAND_BUCKETS", -0x80000000)
            h.world:setVar("VarPlayer", "HANDSAND_BUCKETS", 0x7FFFFFFF)
            h.world:setVar("VarPlayer", "CONSTRUCTION_HOUSE_FURNITURE_DATA_INDEX_1", 1 << 40)
        end)

        it("starts an unset base at 0 when a VarBit is set first", function()
            local h = harness.new(plugin([[
                Event.VarTransmit.Subscribe("v", function(ev)
                    print(ev.var.configName, ev.oldValue, ev.newValue, ev.var.baseVar.value)
                end)
            ]]))
            h:load()
            h.world:setVar("VarPlayer", "FRIEND_SORT_MODE", 5)
            assert.are.equal("FRIEND_SORT_MODE 0 5 40", h:output())
            assert.are.equal(0, h.env.var.VarPlayer.OPTION_HIDE_DUEL_OP.value)
        end)

        it("faults on reading a VarBit whose base was never set", function()
            assert.matches(
                "var.VarPlayer.HANDSAND_COUNT.value was never set",
                harness.errorOf(function()
                    harness.load(plugin("local v = var.VarPlayer.HANDSAND_COUNT.value"))
                end)
            )
        end)
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
