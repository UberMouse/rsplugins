-- Self-tests: replaying a recording (h:useRecording, timeline.lua, replay.lua) with small
-- hand-written recordings in the recorder's format (docs/testing.md, "Recordings").

local harness = require("tests.harness")
local timeline = require("tests.harness.timeline")

local MANIFEST = [[{ "name": "T", "version": "0.0.1", "contactEmailAddress": "t@example.com",
    "optionalPermissions": [ "chatAccess", "httpAccess" ] }]]

-- An inline plugin whose main.lua starts with a `say` that logs the current Logic tick.
---@param main string
---@return table
local function plugin(main)
    return {
        ["plugin.json"] = MANIFEST,
        ["main.lua"] = [[
            local tick = 0
            Event.Logic.Subscribe("tick", function(ev) tick = ev.logicTick end)
            function say(...) print(tick, ...) end
        ]] .. main,
    }
end

local HEADER = '{"k": "session", "schema": 1, "plugin": "t", "session": "s"}\n'
local QP = { config = "QP", id = 1297, type = "VarPlayer" }

describe("replaying a recording", function()
    it("fires each event at its recorded tick, applying its op to the world first", function()
        local h = harness.new(plugin([[
            Event.VarTransmit.Subscribe("v", function(ev)
                say(ev.var.configName, ev.oldValue, ev.newValue, var.VarPlayer.QP.value)
            end)
        ]]))
        h:useRecording({
            { t = 0, k = "read", path = "var.VarPlayer.QP.value", v = 1 },
            {
                t = 3,
                k = "event",
                name = "VarTransmit",
                payload = { var = QP, oldValue = 1, newValue = 2 },
                op = { op = "setVar", domain = "VarPlayer", name = "QP", id = 1297, value = 2 },
            },
        })
        h:load()
        h:advance(40) -- ticks 1-2
        assert.are.equal("", h:output())
        h:step()
        assert.are.equal("3 QP 1 2 2", h:output())
        assert.are.equal(2, h.world.state.vars.VarPlayer[1297])
    end)

    it("serves a read the latest value recorded at or before the current tick", function()
        local h = harness.new(plugin([[
            Event.Logic.Subscribe("poll", function()
                local inv = Inventory.Find(config.Inv.INV)
                if inv and inv.isValid then say(inv.usedSlotCount) end
            end)
        ]]))
        local found = "Inventory.Find(config.Inv.INV)"
        h:useRecording({
            { t = 1, k = "read", path = found, v = "sol.jag::InventoryProxy" },
            { t = 1, k = "read", path = found .. ".isValid", v = true },
            { t = 1, k = "read", path = found .. ".usedSlotCount", v = 3 },
            { t = 3, k = "read", path = found .. ".usedSlotCount", v = 4 },
        })
        h:load()
        h:advance(80)
        -- The world holds no INV, so the Inv comes from the recording.
        assert.are.equal("1 3\n2 3\n3 4\n4 4", h:output())
    end)

    it("serves the slots and totals of an inventory the world doesn't hold", function()
        local h = harness.new(plugin([[
            local bank = Inventory.Find(93)
            local slots = bank:GetSlots()
            say(#slots, slots[1].obj.configName, slots[2].obj.id, bank:GetTotal(config.Obj.LOGS),
                bank:GetSlot(1).count, Inventory.Find(config.Inv.BANK) == nil)
            local missing = bank:GetTotal(995)
        ]]))
        local logs = '{"config": "LOGS", "id": 1511, "type": "Obj"}'
        local empty = '{"config": "UNKNOWN", "id": -1, "type": "Obj"}'
        local lines = {
            '{"t": 0, "k": "read", "path": "Inventory.Find(93)", "v": "sol.jag::InventoryProxy"}',
            '{"t": 0, "k": "read", "path": "Inventory.Find(93):GetSlots()", "v": {"1": {"obj": '
                .. logs
                .. ', "count": 5}, "2": {"obj": '
                .. empty
                .. ', "count": 0}}}',
            '{"t": 0, "k": "read", "path": "Inventory.Find(93):GetTotal(config.Obj.LOGS)", "v": 5}',
            '{"t": 0, "k": "read", "path": "Inventory.Find(93):GetSlot(1)", "v": {"obj": '
                .. logs
                .. ', "count": 5}}',
            -- Recorded returning nil: the JSON has no "v".
            '{"t": 0, "k": "read", "path": "Inventory.Find(config.Inv.BANK)"}',
        }
        h:useRecording(timeline.parse(HEADER .. table.concat(lines, "\n")))
        -- The recording never read GetTotal(995).
        assert.matches(
            "unrecorded: Inventory%.Find%(93%):GetTotal%(995%)",
            harness.errorOf(function()
                h:load()
            end)
        )
        assert.are.equal("0 2 LOGS -1 5 5 true", h:output())
    end)

    it("fails a read the recording never made with unrecorded: <key>", function()
        local h = harness.new(plugin("local qp = var.VarPlayer.QP.value"))
        h:useRecording({ { t = 0, k = "read", path = "var.VarPlayer.OPTION_RUN.value", v = 0 } })
        assert.matches(
            "unrecorded: var%.VarPlayer%.QP%.value",
            harness.errorOf(function()
                h:load()
            end)
        )
    end)

    it("carries on as a scripted world once the recording ends", function()
        local h = harness.new(plugin([[
            Event.VarTransmit.Subscribe("v", function(ev) say(ev.var.configName, ev.newValue) end)
            Event.ServerLogic.Subscribe("s", function() say("server") end)
        ]]))
        h:useRecording({
            { t = 5, k = "event", name = "ServerLogic" },
            {
                t = 6,
                k = "event",
                name = "VarTransmit",
                payload = { var = QP, oldValue = 1, newValue = 2 },
                op = { op = "setVar", domain = "VarPlayer", name = "QP", id = 1297, value = 2 },
            },
        })
        h:load()
        h:playRecording()
        -- ServerLogic came from the recording (tick 5), not the harness's clock.
        assert.are.equal("5 server\n6 QP 2", h:output())
        h.world:setVar("VarPlayer", "QP", 3)
        h:advance(480) -- to tick 30: the harness's own ServerLogic is back
        assert.are.equal("5 server\n6 QP 2\n6 QP 3\n30 server", h:output())
    end)

    it("infers the login, seeds PersistentDB and grants from the first entries", function()
        local h = harness.new(plugin([[
            say(Player.GetEntity().displayName, PersistentDB:GetInt("n"), PersistentDB:Get("other"),
                Plugin.HasPermission(PluginPermissions.chatAccess),
                Plugin.HasPermission(PluginPermissions.httpAccess))
        ]]))
        h:useRecording({
            { t = 0, k = "read", path = "Player.IsAvailable()", v = true },
            { t = 0, k = "read", path = "Player.GetEntity().displayName", v = "Fixture Player" },
            { t = 0, k = "db", op = "GetInt", key = "n", v = 4 },
            { t = 0, k = "db", op = "SetInt", key = "n", value = 5, v = true },
            { t = 0, k = "db", op = "Set", key = "other", value = "x", v = true },
            { t = 0, k = "db", op = "Get", key = "other", v = "x" }, -- its own write: no seed
            { t = 0, k = "perm", permission = "chatAccess", v = true },
            { t = 0, k = "perm", permission = "httpAccess", v = false },
            { t = 9, k = "perm", permission = "httpAccess", v = true }, -- not a starting grant
        })
        h:load()
        assert.are.equal("0 Fixture Player 4 nil true false", h:output())
    end)

    it("skips the plugin's own chat coming back, and delivers server chat", function()
        local h = harness.new(
            plugin([[
            Event.ChatMessage.Subscribe("c", function(ev) say(ev.chatType, ev.chatMessage, ev.timestamp) end)
        ]]),
            { grant = { "chatAccess" } }
        )
        local function chat(t, message, chatType)
            return {
                t = t,
                k = "event",
                name = "ChatMessage",
                payload = {
                    chatMessage = message,
                    senderNameUnfiltered = "",
                    senderNameFiltered = "",
                    senderNameSimple = "",
                    chatType = chatType,
                    timestamp = 1792892990,
                },
                op = { op = "chat", message = message, chatType = chatType, sender = "" },
            }
        end
        h:useRecording({
            chat(1, "You pick the target's pocket.", 109),
            chat(2, "from the plugin", harness.enums.ChatType.PLUGIN),
        })
        h:load()
        h:playRecording()
        assert.are.equal("1 109 You pick the target's pocket. 1792892990", h:output())
        assert.are.equal(1, #h.chatLog)
    end)

    it("reads JSON text, with slot tables keyed by digit strings, into the world", function()
        local h = harness.new(plugin([[
            Event.InventoryUpdated.Subscribe("i", function(ev)
                local slots = Inventory.Find(ev.inv):GetSlots()
                say(#slots, slots[1].obj.configName, slots[3].count, slots[2].obj.id)
            end)
        ]]))
        h:useRecording(timeline.parse(HEADER .. [[
{"t": 2, "k": "event", "name": "InventoryUpdated", "payload": {"inv": {"config": "INV", "id": 93, "type": "Inv"}, "slotsUpdated": [3]}, "op": {"op": "setInventory", "inv": 93, "size": 3, "slots": {"1": {"obj": 1511, "count": 1}, "3": {"obj": 995, "count": 7}}}}
]]))
        h:load()
        h:playRecording()
        -- Recorded as InventoryUpdated, so delivered as one, though the world had no INV.
        assert.are.equal("2 3 LOGS 7 -1", h:output())
    end)

    it("faults a permission check neither the recording nor the test decided", function()
        local main = "say(Plugin.HasPermission(PluginPermissions.httpAccess))"
        local h = harness.new(plugin(main))
        h:useRecording({})
        assert.matches(
            "unrecorded: Plugin%.HasPermission%(httpAccess%)",
            harness.errorOf(function()
                h:load()
            end)
        )
        -- Decided by the test, it is answered: granted up front, or revoked by the builder.
        h = harness.new(plugin(main), { grant = { "httpAccess" } })
        h:useRecording({})
        h:load()
        assert.are.equal("0 true", h:output())
        h = harness.new(plugin(main))
        h:useRecording({})
        h.world:revoke("httpAccess")
        h:load()
        assert.are.equal("0 false", h:output())
        -- Not replaying, an ungranted permission is simply not granted.
        assert.are.equal("0 false", harness.load(plugin(main)):output())
    end)

    it("decides a permission from a recorded OptionalPermissionChanged before firing it", function()
        local h = harness.new(plugin([[
            Event.OptionalPermissionChanged.Subscribe("p", function(ev)
                say(ev.permissionName, ev.enabled, Plugin.HasPermission(PluginPermissions.httpAccess))
            end)
        ]]))
        -- No perm entry or grant before it: only the event's op can have decided httpAccess.
        h:useRecording({
            {
                t = 2,
                k = "event",
                name = "OptionalPermissionChanged",
                payload = { permissionName = "httpAccess", enabled = true },
                op = { op = "setPermission", permission = "httpAccess", enabled = true },
            },
        })
        h:load()
        h:playRecording()
        assert.are.equal("2 httpAccess true true", h:output())
    end)

    it("faults a PersistentDB read of a key neither recorded nor set in the replay", function()
        local h = harness.new(plugin('say(PersistentDB:GetInt("n"))'))
        h:useRecording({ { t = 0, k = "db", op = "GetInt", key = "other", v = 1 } })
        assert.matches(
            'unrecorded: PersistentDB:GetInt%("n"%)',
            harness.errorOf(function()
                h:load()
            end)
        )
        h = harness.new(plugin('say(PersistentDB:CheckExists("n"))'))
        h:useRecording({})
        assert.matches(
            'unrecorded: PersistentDB:CheckExists%("n"%)',
            harness.errorOf(function()
                h:load()
            end)
        )
    end)

    it("answers a PersistentDB key the recording, the plugin or the test accounts for", function()
        local h = harness.new(plugin([[
            PersistentDB:SetInt("mine", 3)
            PersistentDB:Delete("gone")
            say(PersistentDB:Get("unset"), PersistentDB:GetInt("mine"), PersistentDB:Get("gone"),
                PersistentDB:GetString("given"))
            PersistentDB:Clear()
            say(PersistentDB:Get("anything"))
        ]]))
        -- "unset": recorded as a Get that found nothing (no "v").
        h:useRecording({ { t = 0, k = "db", op = "Get", key = "unset" } })
        h.db.given = { type = harness.enums.PersistentDBType.STRING, value = "x" }
        h:load()
        assert.are.equal("0 nil 3 nil x\n0 nil", h:output())
        -- Not replaying, an unknown key is simply unset.
        assert.are.equal("0 nil", harness.load(plugin('say(PersistentDB:Get("n"))')):output())
    end)

    it("refuses a recording with dropped entries unless the test allows the gap", function()
        local function lossy()
            return {
                { t = 1, k = "read", path = "var.VarPlayer.QP.value", v = 1 },
                { t = 4, k = "dropped", n = 7 },
                { t = 4, k = "read", path = "var.VarPlayer.QP.value", v = 2 },
            }
        end
        local h = harness.new(plugin(""))
        assert.matches(
            "recording lost 7 entries in 1 gap%(s%), the first at t=4; pass "
                .. "{ allowDropped = true }",
            harness.errorOf(function()
                h:useRecording(lossy())
            end)
        )
        h:useRecording(lossy(), { allowDropped = true })
        assert.are.same({ { t = 4, n = 7 } }, h.replay.dropped)
    end)

    it("refuses a dropped line without a tick, which can't be placed in the replay", function()
        assert.matches(
            "recording entry 2 %(dropped%) has no integer t",
            harness.errorOf(function()
                timeline.build({
                    { t = 1, k = "read", path = "var.VarPlayer.QP.value", v = 1 },
                    { k = "dropped", n = 7 },
                })
            end)
        )
    end)

    it("leaves ServerLogic to the harness clock when the recording has none", function()
        local h =
            harness.new(plugin('Event.ServerLogic.Subscribe("s", function() say("server") end)'))
        h:useRecording({ { t = 40, k = "read", path = "var.VarPlayer.QP.value", v = 1 } })
        h:load()
        h:playRecording()
        assert.are.equal("30 server", h:output())
    end)

    it("faults a recorded slot that has no obj id, naming its path", function()
        local h = harness.new(plugin("local slots = Inventory.Find(93):GetSlots()"))
        h:useRecording({
            { t = 0, k = "read", path = "Inventory.Find(93)", v = "sol.jag::InventoryProxy" },
            { t = 0, k = "read", path = "Inventory.Find(93):GetSlots()", v = { { obj = "LOGS" } } },
        })
        assert.matches(
            "replay: the recorded slot at Inventory%.Find%(93%):GetSlots%(%)%[1%] has no obj id",
            harness.errorOf(function()
                h:load()
            end)
        )
    end)

    it("refuses a recording in another schema", function()
        local h = harness.new(plugin(""))
        local schema2 = HEADER:gsub('"schema": 1', '"schema": 2')
        assert.matches(
            "recording schema 2; the harness replays schema 1",
            harness.errorOf(function()
                h:useRecording(timeline.parse(schema2))
            end)
        )
    end)
end)
