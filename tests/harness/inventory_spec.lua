-- Self-tests: Inventory.Find, Inv / InvSlot, config.Inv / config.Obj and the inventory events.
-- Names are real ones from docs/api/consts (INV = backpack, LOGS = 1511, COINS = 995).

local harness = require("tests.harness")

local function plugin(main)
    return { ["main.lua"] = main }
end

describe("Inventory", function()
    it("finds a loaded inventory by config or ID and reads its slots", function()
        local h = harness.new(plugin([[
            local inv = Inventory.Find(config.Inv.INV)
            same = inv == Inventory.Find(config.Inv.INV.id)
            counts = { inv.slotCount, inv.usedSlotCount, inv.freeSlotCount }
            first = inv:GetSlot(1)
            firstName, firstCount = first.obj.configName, first.count
            emptySlot = inv:GetSlot(2) == nil
            logs, coins = inv:GetTotal(config.Obj.LOGS), inv:GetTotal(995)
            slots = inv:GetSlots()
            bank = Inventory.Find(config.Inv.BANK) == nil
        ]]))
        h.world:setInventory("INV", {
            [1] = { obj = "LOGS", count = 1 },
            [3] = { obj = "LOGS", count = 1 },
            [4] = { obj = "COINS", count = 5000 },
        }, 28)
        h:load()
        local env = h.env
        assert.is_true(env.same)
        assert.are.same({ 28, 3, 25 }, env.counts)
        assert.are.equal("LOGS", env.firstName)
        assert.are.equal(1, env.firstCount)
        assert.is_true(env.emptySlot)
        assert.are.same({ 2, 5000 }, { env.logs, env.coins })
        assert.are.equal(5000, env.slots[4].count)
        assert.is_true(env.bank)
    end)

    it("fires InventoryAdded, then InventoryUpdated with the changed slots", function()
        local h = harness.load(plugin([[
            Event.InventoryAdded.Subscribe("a", function(ev) print("added", ev.inv.configName) end)
            Event.InventoryUpdated.Subscribe("u", function(ev)
                print("updated", ev.inv == config.Inv.INV, table.concat(ev.slotsUpdated, ","))
            end)
        ]]))
        h.world:setInventory("INV", { [1] = { obj = "LOGS" } }, 28)
        h.world:setInventory("INV", { [1] = { obj = "LOGS" }, [5] = { obj = "COINS", count = 3 } })
        h.world:setInventory("INV", { [1] = { obj = "LOGS" }, [5] = { obj = "COINS", count = 3 } })
        assert.are.equal("added INV\nupdated true 5", h:output())
    end)

    it("invalidates an Inv when its inventory is removed, and re-adds as a new Inv", function()
        local h = harness.new(plugin([[
            inv = Inventory.Find(config.Inv.INV)
            Event.InventoryRemoved.Subscribe("r", function(ev) print("removed", ev.inv.configName) end)
            function refind() return Inventory.Find(config.Inv.INV) end
        ]]))
        h.world:setInventory("INV", { [1] = { obj = "LOGS" } }, 28)
        h:load()
        local inv = h.env.inv
        h.world:removeInventory("INV")
        assert.are.equal("removed INV", h:output())
        assert.is_false(inv.isValid)
        assert.is_nil(h.env.refind())
        assert.has_error(function()
            return inv.slotCount
        end)
        h.world:setInventory("INV", { [1] = { obj = "LOGS" } }, 28)
        assert.are_not.equal(inv, h.env.refind())
        assert.is_true(h.env.refind().isValid)
    end)

    it("serves ObjType fields the test defined, and faults on others", function()
        local h = harness.new(plugin([[
            local logs = config.Obj.LOGS
            name, id = logs.name, logs.id
            local inv = Inventory.Find(config.Inv.INV)
            woodTotal = inv:GetCategoryTotal(22)
        ]]))
        h.world:defineObj("LOGS", { name = "Logs", category = 22 })
        h.world:defineObj("COINS", { category = 0 })
        h.world:setInventory("INV", { [1] = { obj = "LOGS", count = 2 }, [2] = { obj = "COINS" } })
        h:load()
        assert.are.equal("Logs", h.env.name)
        assert.are.equal(1511, h.env.id)
        assert.are.equal(2, h.env.woodTotal)
        assert.matches(
            "unmocked state: ObjType.cost of LOGS",
            harness.errorOf(function()
                harness.load(plugin("local c = config.Obj.LOGS.cost"))
            end)
        )
    end)

    it("rejects config names that aren't in docs/api/consts", function()
        local h = harness.new(plugin(""))
        assert.has_error(function()
            h.world:setInventory("INV", { [1] = { obj = "NOT_AN_OBJ" } })
        end)
        assert.matches(
            "config.Inv.NOT_AN_INV is not in docs/api/consts/Inv.lua",
            harness.errorOf(function()
                harness.load(plugin("local i = config.Inv.NOT_AN_INV"))
            end)
        )
        assert.matches(
            "unmocked API: _global.config.NPC",
            harness.errorOf(function()
                harness.load(plugin("local n = config.NPC"))
            end)
        )
    end)
end)
