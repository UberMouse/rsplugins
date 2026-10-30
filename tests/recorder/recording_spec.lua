-- The dev recorder's pure core (lib/dev/recording.lua): serialisation, read paths and the world
-- op each event stands for.

local recording = require("dev/recording")

local function object(v)
    return "object:" .. type(v)
end

describe("recording.serialise", function()
    it("copies plain data and hands anything else to objectForm", function()
        assert.are.same({ 1, "a", true }, recording.serialise({ 1, "a", true }, object))
        local out = recording.serialise({ nested = { x = 2.5 }, f = print }, object)
        assert.are.same({ nested = { x = 2.5 }, f = "object:function" }, out)
        local classy = setmetatable({}, { __index = {} })
        assert.are.equal("object:table", recording.serialise(classy, object))
    end)

    it("guards cycles", function()
        local t = { name = "loop" }
        t.self = t
        assert.are.same({ name = "loop", self = "<cycle>" }, recording.serialise(t, object))
    end)

    it("writes a table met twice (not inside itself) in full both times", function()
        local shared = { 1 }
        assert.are.same(
            { a = { 1 }, b = { 1 } },
            recording.serialise({ a = shared, b = shared }, object)
        )
    end)

    it("caps strings and the number of values", function()
        local long = recording.serialise(string.rep("x", recording.MAX_STRING + 10), object)
        assert.are.equal(string.rep("x", recording.MAX_STRING) .. "<+10 bytes>", long)

        local big = {}
        for i = 1, recording.MAX_NODES + 5 do
            big[i] = i
        end
        local out = recording.serialise(big, object)
        -- The table itself is one node, so MAX_NODES - 1 elements fit.
        assert.are.equal(recording.MAX_NODES - 1, out[recording.MAX_NODES - 1])
        assert.are.equal("<truncated>", out[recording.MAX_NODES])
        assert.is_nil(out[recording.MAX_NODES + 1])
        assert.are.equal(recording.MAX_NODES, #out)
    end)

    it("stops walking every enclosing table at the cap", function()
        local inner = {}
        for i = 1, recording.MAX_NODES do
            inner[i] = i
        end
        local out = recording.serialise({ inner, "after" }, object)
        -- Outer and inner tables are two nodes, so the inner one's last fitting value is
        -- MAX_NODES - 2, and the outer table's second value is never reached.
        assert.are.equal("<truncated>", out[1][recording.MAX_NODES - 1])
        assert.are.equal(recording.MAX_NODES - 1, #out[1])
        assert.are.equal(1, #out)
    end)
end)

describe("recording.objectData", function()
    it("writes a config as { config, id, type }", function()
        local logs = setmetatable(
            {},
            { __index = { configName = "LOGS", id = 1511, typeName = "Obj" } }
        )
        assert.are.same({ config = "LOGS", id = 1511, type = "Obj" }, recording.objectData(logs))
    end)

    it("writes other userdata as its tostring() text", function()
        assert.matches("^file %(", recording.objectData(io.stdout))
    end)

    it("is what var-dump writes: configs, game objects and long strings", function()
        local logs = setmetatable(
            {},
            { __index = { configName = "LOGS", id = 1511, typeName = "Obj" } }
        )
        local out = recording.serialise({
            config = logs,
            game = io.stdout,
            long = string.rep("x", recording.MAX_STRING + 3),
        }, recording.objectData)
        assert.are.same({ config = "LOGS", id = 1511, type = "Obj" }, out.config)
        assert.matches("^file %(", out.game)
        assert.are.equal(string.rep("x", recording.MAX_STRING) .. "<+3 bytes>", out.long)
    end)

    it("leaves the memory address out of an object's text", function()
        -- The client's text for an Inv, from recording 20261025-144642-8f7250b863.
        local inv = setmetatable({}, {
            __tostring = function()
                return "sol.jag::InventoryProxy: 0x591cbdbce258"
            end,
        })
        assert.are.equal("sol.jag::InventoryProxy", recording.objectData(inv))
        assert.are.equal("sol.jag::InventoryProxy", recording.objectText(inv))
    end)
end)

describe("recording.callPath", function()
    it("names a call by its object's path and its arguments", function()
        local inv = {}
        local function pathOf(v)
            return v == inv and "config.Inv.INV" or nil
        end
        local args = table.pack(inv, "k", 3, nil, {})
        assert.are.equal(
            'Inventory.Find(config.Inv.INV, "k", 3, nil, <table>)',
            recording.callPath("Inventory", false, "Find", args, 1, pathOf)
        )
        assert.are.equal(
            "Inventory.Find(config.Inv.INV):GetSlots()",
            recording.callPath(
                "Inventory.Find(config.Inv.INV)",
                true,
                "GetSlots",
                table.pack(inv),
                2,
                pathOf
            )
        )
    end)
end)

describe("recording.eventOp", function()
    local var = { config = "OPTION_RUN", id = 463, type = "VarPlayer" }
    local inv = { config = "INV", id = 93, type = "Inv" }

    it("maps events onto the harness's world ops", function()
        assert.are.same(
            { op = "setVar", domain = "VarPlayer", name = "OPTION_RUN", id = 463, value = 1 },
            recording.eventOp("VarTransmit", { var = var, oldValue = 0, newValue = 1 })
        )
        local contents = { size = 28, slots = { [1] = { obj = 1511, count = 5 } } }
        assert.are.same(
            { op = "setInventory", inv = 93, size = 28, slots = contents.slots },
            recording.eventOp("InventoryUpdated", { inv = inv, slotsUpdated = { 1 } }, contents)
        )
        assert.are.same(
            { op = "removeInventory", inv = 93 },
            recording.eventOp("InventoryRemoved", { inv = inv })
        )
        assert.are.same(
            { op = "setPermission", permission = "chatAccess", enabled = true },
            recording.eventOp(
                "OptionalPermissionChanged",
                { permissionName = "chatAccess", enabled = true }
            )
        )
        assert.are.same(
            { op = "chat", message = "hi", chatType = 0, sender = "Bob" },
            recording.eventOp(
                "ChatMessage",
                { chatMessage = "hi", chatType = 0, senderNameUnfiltered = "Bob" }
            )
        )
    end)

    it(
        "gives nil when the event isn't a modelled world change, or lacks what the op needs",
        function()
            assert.is_nil(recording.eventOp("KeyDown", { gameKey = 1 }))
            assert.is_nil(recording.eventOp("ServerLogic", nil))
            assert.is_nil(recording.eventOp("InventoryAdded", { inv = inv }))
        end
    )
end)
