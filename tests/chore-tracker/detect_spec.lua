-- shell/detect with a listed name the client's config lacks, as one might after a game update
-- renames it. The harness faults on any config name not in docs/api/consts (to catch typos),
-- so this runs detect.lua on its own, with globals that stand in for a config missing a name.

local support = require("tests.chore-tracker.support")
local detect = require("shell/detect")

describe("chore-tracker detect", function()
    local saved, said, found
    before_each(function()
        saved = { config = _G.config, Inventory = _G.Inventory, Player = _G.Player }
        said, found = {}, {}
        _G.config = {
            Inv = { INV = { name = "INV" }, KNOWN_SHOP = { name = "KNOWN_SHOP" } },
            Obj = { CERT_KNOWN = { name = "CERT_KNOWN" } },
        }
        local backpack = {
            isValid = true,
            GetTotal = function(_, obj)
                assert(obj ~= nil, "GetTotal(nil)")
                return 1
            end,
        }
        _G.Inventory = {
            Find = function(invType)
                assert(invType ~= nil, "Inventory.Find(nil)")
                found[#found + 1] = invType.name
                return invType.name == "INV" and backpack or nil
            end,
        }
        _G.Player = {
            IsAvailable = function()
                return false
            end,
        }
    end)
    after_each(function()
        _G.config, _G.Inventory, _G.Player = saved.config, saved.Inventory, saved.Player
    end)

    -- Init with a shop and a note the config lacks, then check each is said once and unwatched.
    local function initAndCheck()
        detect.init({
            chores = support.chores(),
            shops = {
                wshop = {
                    { name = "Known", invs = { "KNOWN_SHOP" }, proven = true },
                    { name = "Renamed", invs = { "GONE_SHOP" }, proven = true },
                },
            },
            collections = {
                {
                    chore = "d1",
                    npc = "someone",
                    notes = { "CERT_KNOWN", "CERT_GONE" },
                    tile = { x = 0, z = 0, level = 0 },
                    range = 10,
                    proven = true,
                },
            },
            machines = {
                { chore = "d1", invs = { "GONE_OUTPUT" }, proven = true },
                { chore = "wshop", invs = { "GONE_OUTPUT" }, proven = true },
            },
            say = function(...)
                said[#said + 1] = table.concat({ ... }, " ")
            end,
            apply = function()
                error("nothing here is bought or collected")
            end,
        })
        detect.scan()
        detect.scan()
        detect.onInventoryUpdated({ inv = { configName = "GONE_SHOP" } })
        detect.onInventoryRemoved({ inv = { configName = "GONE_SHOP" } })
        detect.onInventoryUpdated({ inv = { configName = "GONE_OUTPUT" } })
        assert.are.same({
            "unknown inventory GONE_SHOP; not watched",
            "unknown inventory GONE_OUTPUT; not watched",
            "unknown obj CERT_GONE; not watched",
        }, said)
        table.sort(found)
        assert.are.same({ "INV", "INV", "KNOWN_SHOP", "KNOWN_SHOP" }, found)
    end

    it("leaves an inventory or note the config lacks unwatched, saying so once", initAndCheck)

    it("fails at init naming a shop or collection chore that chores.lua lacks", function()
        local function say() end
        local function apply() end
        assert.has_error(function()
            detect.init({
                chores = support.chores(),
                shops = { nochore = { { name = "S", invs = { "KNOWN_SHOP" }, proven = true } } },
                collections = {},
                machines = {},
                parts = {},
                say = say,
                apply = apply,
            })
        end, "data names a chore that data/chores.lua lacks: nochore")
        assert.has_error(function()
            detect.init({
                chores = support.chores(),
                shops = {},
                collections = {
                    {
                        chore = "nochore",
                        npc = "x",
                        notes = {},
                        tile = { x = 0, z = 0, level = 0 },
                        range = 1,
                        proven = true,
                    },
                },
                machines = {},
                parts = {},
                say = say,
                apply = apply,
            })
        end, "data names a chore that data/chores.lua lacks: nochore")
    end)

    -- removeInventory fires only InventoryRemoved; the harness sends InventoryAdded when the
    -- backpack is set again, which re-baselines. So this drives detect directly: a lone update
    -- after a removal must not read as a rise against the old counts.
    it("takes no rise against a backpack's counts from before it was removed", function()
        local total, applied = 1, 0
        _G.Inventory.Find = function()
            return {
                isValid = true,
                GetTotal = function()
                    return total
                end,
            }
        end
        _G.Player = {
            IsAvailable = function()
                return true
            end,
            GetEntity = function()
                return { coordGrid = { x = 0, z = 0, level = 0 } }
            end,
        }
        detect.init({
            chores = support.chores(),
            shops = {},
            collections = {
                {
                    chore = "d1",
                    npc = "someone",
                    notes = { "CERT_KNOWN" },
                    tile = { x = 0, z = 0, level = 0 },
                    range = 10,
                    proven = true,
                },
            },
            machines = {},
            parts = {},
            say = function() end,
            apply = function()
                applied = applied + 1
            end,
        })
        detect.scan()
        detect.onInventoryRemoved({ inv = { configName = "INV" } })
        total = 5
        detect.onInventoryUpdated({ inv = { configName = "INV" } })
        assert.are.equal(0, applied)
        -- The update was the new baseline: a further rise counts.
        total = 9
        detect.onInventoryUpdated({ inv = { configName = "INV" } })
        assert.are.equal(1, applied)
    end)
end)

-- shell/vars with a var name the client's config lacks, by the same stand-in approach: the
-- harness faults on unknown var names by design.
describe("chore-tracker var detect", function()
    local vars = require("shell/vars")
    local saved, said, applied

    ---@param name string
    ---@param id integer
    ---@param value integer
    ---@return table
    local function varType(name, id, value)
        return {
            configName = name,
            id = id,
            typeName = "VarPlayer",
            isVarBit = false,
            value = value,
        }
    end

    local base = varType("BASE", 10, 0)
    local flag = {
        configName = "FLAG",
        id = -11,
        typeName = "VarPlayer",
        isVarBit = true,
        baseVar = base,
        value = 0,
    }

    ---@param varPlayer table
    local function load(varPlayer)
        said, applied = {}, 0
        _G.var = { VarPlayer = varPlayer }
        flag.value = 0
        vars.init({
            chores = support.chores(),
            rules = {
                { chore = "d1", done = { { "FLAG", "==", 1 } }, proven = true },
                {
                    chore = "d2",
                    done = { { "FLAG", "==", 1 }, { "GONE", "==", 1 } },
                    proven = true,
                },
                { chore = "w1", done = { { "GONE", ">", 0 } }, proven = true },
            },
            where = function() end,
            parts = {},
            say = function(...)
                said[#said + 1] = table.concat({ ... }, " ")
            end,
            apply = function(change)
                applied = applied + 1
                change(require("core/state").new(), 29881543)
            end,
        })
        vars.scan()
        for _ = 1, 500 do
            vars.tick()
        end
    end

    before_each(function()
        saved = _G.var
        load({ BASE = base, FLAG = flag })
    end)
    after_each(function()
        _G.var = saved
    end)

    it("leaves a var the config lacks unwatched, dropping its rules, saying so once", function()
        assert.are.same({ "unknown var GONE; not watched" }, said)
        flag.value = 1
        vars.onVarTransmit({ var = base })
        -- Only d1's rule is left to tick.
        assert.are.same({ "unknown var GONE; not watched", "seen d1 done (FLAG)" }, said)
        assert.are.equal(1, applied)
    end)

    it("fails at init naming a rule chore that chores.lua lacks", function()
        assert.has_error(function()
            vars.init({
                chores = support.chores(),
                rules = { { chore = "nochore", done = { { "FLAG", "==", 1 } }, proven = true } },
                where = function() end,
                parts = {},
                say = function() end,
                apply = function() end,
            })
        end, "data/vars.lua names a chore that data/chores.lua lacks: nochore")
    end)

    it("takes a var with no value at load as unread until it has one", function()
        flag.value = nil
        vars.scan()
        for _ = 1, 500 do
            vars.tick()
        end
        -- Its first value, already true, is the baseline: no tick.
        flag.value = 1
        vars.onVarTransmit({ var = flag })
        assert.are.same({ "unknown var GONE; not watched" }, said)
        -- A later change from that first value ticks as usual.
        flag.value = 0
        vars.onVarTransmit({ var = flag })
        flag.value = 1
        vars.onVarTransmit({ var = flag })
        assert.are.same({ "unknown var GONE; not watched", "seen d1 done (FLAG)" }, said)
    end)

    it("matches a base by id and domain, not by object", function()
        flag.value = 1
        vars.onVarTransmit({ var = varType("BASE", 10, 1) })
        assert.are.equal(1, applied)
        flag.value = 0
        local client = varType("OTHER", 10, 0)
        client.typeName = "VarClient"
        vars.onVarTransmit({ var = client })
        vars.onVarTransmit({ var = varType("UNRELATED", 99, 5) })
        assert.are.equal(1, applied)
    end)
end)
