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

describe("protocol.isSelfTarget", function()
    it("catches each short and long form naming dev-bridge, any case and spacing", function()
        for _, command in ipairs({
            "prl dev-bridge",
            "  PRL   dev-bridge  ",
            "poff dev-bridge",
            "plugins_reload dev-bridge",
            "Plugins_Disable DEV-BRIDGE",
            "plugins_setenabled dev-bridge false",
            "plugins_setenabled dev-bridge true",
            "ppd dev-bridge httpAccess",
            "plugins_permissions_disable dev-bridge chatAccess",
        }) do
            assert(protocol.isSelfTarget(command), command)
        end
    end)

    it("lets other plugins and other commands through", function()
        for _, command in ipairs({
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
            assert(not protocol.isSelfTarget(command), command)
        end
    end)
end)

describe("protocol.refusal", function()
    it("refuses unknown kinds and self-targeting commands, and nothing else", function()
        assert.are.equal("unknown kind eval", protocol.refusal({ kind = "eval", arg = "1" }))
        assert.matches("console", protocol.refusal({ kind = "exec", arg = "poff dev-bridge" }))
        assert.is_nil(protocol.refusal({ kind = "exec", arg = "plist" }))
    end)
end)
