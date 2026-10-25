-- Self-tests: Chat.AddMessage and ChatMessage, per game/chat.html and core/events.html.

local harness = require("tests.harness")
local ChatType = harness.enums.ChatType

local function plugin(main)
    return {
        ["main.lua"] = main,
        ["plugin.json"] = '{ "optionalPermissions": [ "chatAccess" ] }',
    }
end

local ECHO = [[
    Event.ChatMessage.Subscribe("c", function(ev)
        print(ev.chatType, ev.senderNameSimple, ev.chatMessage)
    end)
]]

describe("Chat", function()
    it("queues AddMessage until the next logic step, as a PLUGIN message", function()
        local h =
            harness.load(plugin(ECHO .. "Chat.AddMessage('hello')"), { grant = { "chatAccess" } })
        assert.are.equal("", h:output())
        h:advance(20)
        assert.are.equal(ChatType.PLUGIN .. "  hello", h:output())
        assert.are.equal("hello", h.chatLog[1].message)
    end)

    it("delivers server messages only while chatAccess is granted", function()
        local h = harness.load(plugin(ECHO))
        h.world:chat("unseen", { chatType = ChatType.PUBLIC, sender = "Zezima" })
        h.world:grant("chatAccess")
        h.world:chat("seen", { chatType = ChatType.PUBLIC, sender = "Zezima" })
        assert.are.equal(ChatType.PUBLIC .. " Zezima seen", h:output())
        h.world:revoke("chatAccess")
        h.world:chat("unseen again", { chatType = ChatType.PUBLIC, sender = "Zezima" })
        assert.are.equal(ChatType.PUBLIC .. " Zezima seen", h:output())
        assert.are.equal(3, #h.chatLog) -- the chat window shows all three
    end)

    it("faults on AddMessage without chatAccess", function()
        assert.matches(
            "Chat.AddMessage without the chatAccess permission",
            harness.errorOf(function()
                harness.load(plugin("Chat.AddMessage('hi')"))
            end)
        )
    end)

    it("passes a subscriber's edit to the next subscriber and the chat window", function()
        local h = harness.load(
            plugin([[
            Event.ChatMessage.Subscribe("a", function(ev) ev.chatMessage = ev.chatMessage .. " Hello!" end)
            Event.ChatMessage.Subscribe("b", function(ev) print(ev.chatMessage) end)
        ]]),
            { grant = { "chatAccess" } }
        )
        h.world:chat("I'm a chat message.")
        assert.are.equal("I'm a chat message. Hello!", h:output())
        assert.are.equal("I'm a chat message. Hello!", h.chatLog[1].message)
    end)
end)
