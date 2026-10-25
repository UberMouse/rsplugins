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
        assert.are.same({
            "unknown inventory GONE_SHOP; not watched",
            "unknown obj CERT_GONE; not watched",
        }, said)
        table.sort(found)
        assert.are.same({ "INV", "INV", "KNOWN_SHOP", "KNOWN_SHOP" }, found)
    end

    it("leaves an inventory or note the config lacks unwatched, saying so once", initAndCheck)

    it("treats a config lookup that raises like a name the config lacks", function()
        for _, domain in ipairs({ "Inv", "Obj" }) do
            setmetatable(_G.config[domain], {
                __index = function(_, name)
                    error("no " .. domain .. " " .. name)
                end,
            })
        end
        initAndCheck()
    end)
end)

-- shell/vars with a var name the client's config lacks, by the same stand-in approach: the
-- harness faults on unknown var names by design.
describe("chore-tracker var detect", function()
    local varDetect = require("shell/vars")
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
        varDetect.init({
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
            say = function(...)
                said[#said + 1] = table.concat({ ... }, " ")
            end,
            apply = function(change)
                applied = applied + 1
                change(require("core/state").new(), 29881543)
            end,
        })
        varDetect.scan()
        for _ = 1, 500 do
            varDetect.tick()
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
        varDetect.onVarTransmit({ var = base })
        -- Only d1's rule is left to tick.
        assert.are.same({ "unknown var GONE; not watched", "seen d1 done (FLAG)" }, said)
        assert.are.equal(1, applied)
    end)

    it("treats a var lookup that raises like a name the config lacks", function()
        load(setmetatable({ BASE = base, FLAG = flag }, {
            __index = function(_, name)
                error("no var " .. name)
            end,
        }))
        assert.are.same({ "unknown var GONE; not watched" }, said)
        flag.value = 1
        varDetect.onVarTransmit({ var = base })
        assert.are.same({ "unknown var GONE; not watched", "seen d1 done (FLAG)" }, said)
        assert.are.equal(1, applied)
    end)

    it("takes a var with no value at load as unread until it has one", function()
        flag.value = nil
        varDetect.scan()
        for _ = 1, 500 do
            varDetect.tick()
        end
        -- Its first value, already true, is the baseline: no tick.
        flag.value = 1
        varDetect.onVarTransmit({ var = flag })
        assert.are.same({ "unknown var GONE; not watched" }, said)
        -- A later change from that first value ticks as usual.
        flag.value = 0
        varDetect.onVarTransmit({ var = flag })
        flag.value = 1
        varDetect.onVarTransmit({ var = flag })
        assert.are.same({ "unknown var GONE; not watched", "seen d1 done (FLAG)" }, said)
    end)

    it("matches a base by id and domain, not by object", function()
        flag.value = 1
        varDetect.onVarTransmit({ var = varType("BASE", 10, 1) })
        assert.are.equal(1, applied)
        flag.value = 0
        local client = varType("OTHER", 10, 0)
        client.typeName = "VarClient"
        varDetect.onVarTransmit({ var = client })
        varDetect.onVarTransmit({ var = varType("UNRELATED", 99, 5) })
        assert.are.equal(1, applied)
    end)
end)
