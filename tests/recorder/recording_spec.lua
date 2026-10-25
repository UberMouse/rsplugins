-- The dev recorder's pure core (lib/dev/recording.lua): serialisation, read paths, the world
-- op each event stands for, the bounded buffer and the batch body.

local dkjson = require("dkjson")
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
        assert.are.equal("<truncated>", out[#big])
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

describe("the entry buffer", function()
    it("drops the oldest entries past its byte limit, keeping the newest", function()
        local buffer = recording.newBuffer()
        assert.are.equal(0, recording.push(buffer, "aaaaaaaaaa", 25))
        assert.are.equal(0, recording.push(buffer, "bbbbbbbbbb", 25))
        assert.are.equal(1, recording.push(buffer, "cccccccccc", 25))
        assert.are.equal(2, recording.count(buffer))
        -- Bigger than the limit on its own: everything older goes, and it stays.
        assert.are.equal(2, recording.push(buffer, string.rep("d", 40), 25))
        assert.are.same({ string.rep("d", 40) }, recording.take(buffer, 100))
    end)

    it("takes the oldest entries up to a byte limit, at least one", function()
        local buffer = recording.newBuffer()
        for _, entry in ipairs({ "1111", "2222", "3333" }) do
            recording.push(buffer, entry, 1000)
        end
        assert.are.same({ "1111", "2222" }, recording.take(buffer, 9))
        assert.are.same({ "3333" }, recording.take(buffer, 1))
        assert.are.same({}, recording.take(buffer, 100))
        assert.are.equal(0, recording.count(buffer))
    end)
end)

describe("recording.batchBody", function()
    it("splices encoded entries into the batch", function()
        local body = recording.batchBody(
            { schema = recording.SCHEMA, seq = 1 },
            { '{"k":"read","t":0}', '{"k":"event","t":1}' }
        )
        assert.are.same({
            schema = 1,
            seq = 1,
            entries = { { k = "read", t = 0 }, { k = "event", t = 1 } },
        }, dkjson.decode(body))
    end)
end)
