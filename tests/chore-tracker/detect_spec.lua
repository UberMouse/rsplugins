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

    it("leaves an inventory or note the config lacks unwatched, saying so once", function()
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
    end)
end)
