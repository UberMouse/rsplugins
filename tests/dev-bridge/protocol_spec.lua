-- The dev bridge's pure core (plugins/dev-bridge/protocol.lua): the sync body, parsing and
-- unescaping the daemon's reply, and which commands are refused.

local dkjson = require("dkjson")
local support = require("tests.dev-bridge.support")
local protocol = require("protocol")

describe("protocol.syncBody", function()
    it("holds the schema-1 fields with the encoded events spliced in", function()
        local events = {
            protocol.eventEntry(7, "ChatMessage", { chatMessage = "hi" }),
            protocol.eventEntry(9, "GameStateChanged", { oldState = 20, newState = 30 }),
        }
        local body = dkjson.decode(protocol.syncBody({
            session = "abc123",
            seq = 3,
            dropped = 2,
            hello = { version = "Lua 5.4", env = { load = "nil" } },
            results = { { id = "c1", ok = false, error = "no" } },
        }, events))
        assert.are.same({
            schema = 1,
            plugin = "dev-bridge",
            session = "abc123",
            seq = 3,
            dropped = 2,
            hello = { version = "Lua 5.4", env = { load = "nil" } },
            events = {
                { t = 7, name = "ChatMessage", payload = { chatMessage = "hi" } },
                { t = 9, name = "GameStateChanged", payload = { oldState = 20, newState = 30 } },
            },
            results = { { id = "c1", ok = false, error = "no" } },
        }, body)
    end)

    it("writes no events and no results as empty arrays", function()
        local body = protocol.syncBody({ session = "s", seq = 1, dropped = 0, results = {} }, {})
        assert.matches('"events":%[%]', body)
        assert.matches('"results":%[%]', body)
    end)
end)

describe("protocol.parseReply", function()
    it("splits lines into commands and unescapes the arg", function()
        local arg = "say a\tb\nc\\d\re"
        local commands, malformed = protocol.parseReply(
            support.line("c1-ab", "exec", arg) .. support.line("c2", "exec", "")
        )
        assert.are.same({
            { id = "c1-ab", kind = "exec", arg = arg },
            { id = "c2", kind = "exec", arg = "" },
        }, commands)
        assert.are.same({}, malformed)
    end)

    it("takes an empty body as no commands", function()
        assert.are.same({ {}, {} }, { protocol.parseReply("") })
    end)

    it("refuses a body cut short of its final newline", function()
        local commands, why = protocol.parseReply("c1\texec\tplist")
        assert.is_nil(commands)
        assert.matches("newline", why)
    end)

    it("skips lines without a usable id or kind", function()
        local long = string.rep("a", 33)
        local commands, malformed = protocol.parseReply(
            "no tabs\n"
                .. long
                .. "\texec\tx\n"
                .. "bad id!\texec\tx\n"
                .. "c1\t\tx\n"
                .. "c2\texec\ttoo\tmany\n"
                .. support.line("ok_1", "exec", "plist")
        )
        assert.are.same({ { id = "ok_1", kind = "exec", arg = "plist" } }, commands)
        assert.are.equal(5, #malformed)
    end)
end)

describe("protocol.unescape", function()
    it("undoes rsdev.py's escape_arg and leaves other escapes as written", function()
        assert.are.equal("a\\b\tc\nd\re", protocol.unescape("a\\\\b\\tc\\nd\\re"))
        assert.are.equal("\\x and a trailing \\", protocol.unescape("\\x and a trailing \\"))
        -- An escaped backslash before a t is a backslash then a t, not a tab.
        assert.are.equal("\\t", protocol.unescape("\\\\t"))
    end)
end)

describe("protocol.isSelfDisable", function()
    it("catches each disabling form naming dev-bridge, any case and spacing", function()
        for _, command in ipairs({
            "poff dev-bridge",
            "  POFF   dev-bridge  ",
            "Plugins_Disable DEV-BRIDGE",
            "plugins_setenabled dev-bridge false",
            "plugins_setenabled dev-bridge true",
            "ppd dev-bridge httpAccess",
            "plugins_permissions_disable dev-bridge chatAccess",
        }) do
            assert(protocol.isSelfDisable(command), command)
        end
    end)

    it("lets other plugins and other commands through", function()
        for _, command in ipairs({
            "prl dev-bridge",
            "  PRL   dev-bridge  ",
            "plugins_reload dev-bridge",
            "prl chore-tracker",
            "poff debug-plugin",
            "pon dev-bridge",
            "ppe dev-bridge httpAccess",
            "plist",
            "prl",
            "",
            "!tele 0,50,50,9,56",
            "prl dev-bridge2",
        }) do
            assert(not protocol.isSelfDisable(command), command)
        end
    end)
end)

describe("protocol.refusal", function()
    it("refuses unknown kinds and self-disabling commands, and nothing else", function()
        assert.are.equal("unknown kind eval", protocol.refusal({ kind = "eval", arg = "1" }))
        assert.matches("console", protocol.refusal({ kind = "exec", arg = "poff dev-bridge" }))
        assert.is_nil(protocol.refusal({ kind = "exec", arg = "plist" }))
        assert.is_nil(protocol.refusal({ kind = "exec", arg = "prl dev-bridge" }))
    end)
end)

describe("protocol.chatAllowed", function()
    local ChatType = require("tests.harness.api.chat").ChatType
    local OWN = "UberMouse894"

    it("names the stub's ChatType values", function()
        for _, set in ipairs({ protocol.SYSTEM_CHAT, protocol.SPEECH_CHAT }) do
            for name, value in pairs(set) do
                assert.are.equal(ChatType[name], value, name)
            end
        end
    end)

    it("forwards every system type whatever the sender", function()
        for name, value in pairs(protocol.SYSTEM_CHAT) do
            assert.are.equal(true, protocol.chatAllowed(value, "", OWN), name)
            assert.are.equal(true, protocol.chatAllowed(value, "Bob", nil), name)
        end
    end)

    it("forwards a speech type only from the local player", function()
        for name, value in pairs(protocol.SPEECH_CHAT) do
            assert.are.equal(true, protocol.chatAllowed(value, OWN, OWN), name)
            assert.are.equal(false, protocol.chatAllowed(value, "Bob", OWN), name)
            assert.are.equal(false, protocol.chatAllowed(value, "", OWN), name) -- no sender
            assert.are.equal(false, protocol.chatAllowed(value, OWN, nil), name) -- own name unknown
            assert.are.equal(false, protocol.chatAllowed(value, "", nil), name)
            assert.are.equal(false, protocol.chatAllowed(value, "", ""), name)
        end
    end)

    it("compares names ignoring case, markup, underscores and spacing", function()
        local pub = ChatType.PUBLIC
        assert.is_true(protocol.chatAllowed(pub, "ubermouse894", OWN))
        assert.is_true(protocol.chatAllowed(pub, OWN, "<img=11>UberMouse894"))
        assert.is_true(protocol.chatAllowed(pub, "Uber_Mouse 894", " uber  mouse 894 "))
        assert.is_true(protocol.chatAllowed(pub, "Uber\194\160Mouse", "uber mouse"))
        assert.is_false(protocol.chatAllowed(pub, "UberMouse89", OWN))
        assert.is_false(protocol.chatAllowed(pub, "<img=11>Bob", "Bob2"))
    end)

    it("drops every other type, including broadcasts and unknown numbers", function()
        for _, value in ipairs({ ChatType.LOGIN_LOGOUT, ChatType.FRIEND_NOTIFICATION }) do
            assert.is_false(protocol.chatAllowed(value, OWN, OWN))
        end
        assert.is_false(protocol.chatAllowed(ChatType.TRADE_REQUEST, "Bob", OWN))
        assert.is_false(protocol.chatAllowed(ChatType.CLANCHANNEL_AFFINED_NOTIFICATION, "", OWN))
        -- World News naming other players, empty sender, seen in the client as type 138.
        assert.are.equal(138, ChatType.BROADCAST_WORLD)
        assert.is_false(protocol.chatAllowed(138, "", OWN))
        assert.is_false(protocol.chatAllowed(9999, OWN, OWN))
        assert.is_false(protocol.chatAllowed(nil, OWN, OWN))
        assert.is_false(protocol.chatAllowed("2", OWN, OWN))
    end)
end)

describe("protocol.chatView", function()
    it("keeps the player's own line as seen in the client", function()
        local data = {
            chatType = 2,
            senderNameSimple = "UberMouse894",
            senderNameUnfiltered = "<img=11>UberMouse894",
            senderNameFiltered = "<img=11> <col=6d6d75>Ironman</col> UberMouse894",
            chatMessage = "Test",
        }
        assert.are.same(data, protocol.chatView(data, "UberMouse894"))
    end)

    it("blanks another player's name on a system message", function()
        local view = protocol.chatView({
            chatType = 0,
            senderNameSimple = "Bob",
            senderNameUnfiltered = "<img=1>Bob",
            senderNameFiltered = "Bob",
            chatMessage = "x",
        }, "Me")
        assert.are.same(
            "",
            view.senderNameSimple .. view.senderNameUnfiltered .. view.senderNameFiltered
        )
        assert.are.equal("x", view.chatMessage)
    end)

    it("drops other players' speech", function()
        assert.is_nil(protocol.chatView({ chatType = 2, senderNameSimple = "Bob" }, "Me"))
    end)
end)

describe("protocol.entryView", function()
    local fields = {
        verbText = "Trade with",
        subjectText = "Bob",
        extraText = "(level-3)",
        fullText = "Trade with Bob (level-3)",
        overrideText = "",
        actionType = 46,
        actionEntryType = 7,
        actionVerbType = 2,
        subjectHash = 5,
        npcData = "ignored",
    }

    it("blanks the player's name when the entry targets a player", function()
        local view = protocol.entryView(fields, true)
        assert.are.equal("<player>", view.subjectText)
        assert.are.equal("<player>", view.fullText)
        assert.are.equal("<player>", view.overrideText)
        assert.are.equal("Trade with", view.verbText)
        assert.are.equal(5, view.subjectHash)
        assert.is_nil(view.npcData)
    end)

    it("also blanks on the entry or action type, or when playerData can't be read", function()
        assert.are.equal("<player>", protocol.entryView(fields, false).subjectText)
        local npc = { subjectText = "Cow", actionType = 9, actionEntryType = 4 }
        assert.are.equal("Cow", protocol.entryView(npc, false).subjectText)
        assert.are.equal("<player>", protocol.entryView(npc, nil).subjectText)
        assert.are.equal(
            "<player>",
            protocol.entryView({ subjectText = "B", actionType = 2046 }, false).subjectText
        )
    end)
end)
