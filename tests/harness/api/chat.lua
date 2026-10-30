-- Chat.AddMessage and ChatMessage delivery.
--
-- From https://developer.runescape.com/rs/game/chat.html and core/events.html#chatmessage:
-- the Chat table needs chatAccess; AddMessage is queued until the next logic update and then
-- triggers ChatMessage with ChatType.PLUGIN; ChatMessage only reaches plugins granted
-- chatAccess; subscribers may edit chatMessage, and later subscribers see the edit.

local events = require("tests.harness.api.events")
local strict = require("tests.harness.strict")
local stubs = require("tests.harness.stubs")
local world = require("tests.harness.world")

local M = {}

M.ChatType = stubs.value("core/events.lua", "ChatType")

-- Seconds since the Unix epoch at logic tick 0, for ChatMessage.timestamp. Arbitrary but
-- fixed, so tests are deterministic.
local EPOCH = 1767225600 -- 2026-01-01T00:00:00Z

-- Show a message in the chat window: fire ChatMessage if the plugin may see it, then record
-- the (possibly edited) text in h.chatLog.
---@param h table the harness
---@param message string
---@param chatType integer
---@param sender string? "" when no player sent it
---@param timestamp integer? unix seconds; defaults to the harness clock (a replay passes the
---  recorded one)
function M.deliver(h, message, chatType, sender, timestamp)
    sender = sender or ""
    local payload = events.payload("ChatMessage", {
        chatMessage = message,
        senderNameUnfiltered = sender,
        senderNameFiltered = sender,
        senderNameSimple = sender,
        chatType = chatType,
        timestamp = timestamp or EPOCH + h.tick // 50,
    })
    assert(payload, "ChatMessage has a payload")
    if world.granted(h.world.state, "chatAccess") then
        events.dispatch(h, "ChatMessage", payload)
    end
    h.chatLog[#h.chatLog + 1] =
        { message = payload.chatMessage, chatType = chatType, sender = sender }
end

local Chat = strict.class("Chat", {
    statics = {
        AddMessage = function(s, message)
            if not world.granted(s.h.world.state, "chatAccess") then
                strict.fault("Chat.AddMessage without the chatAccess permission")
            end
            if type(message) ~= "string" then strict.fault("Chat.AddMessage(message: String)") end
            table.insert(s.h.chatQueue, message)
        end,
    },
})

-- Deliver messages queued by AddMessage before this logic step.
---@param h table the harness
function M.flush(h)
    local queue = h.chatQueue
    h.chatQueue = {}
    for _, message in ipairs(queue) do
        M.deliver(h, message, M.ChatType.PLUGIN)
    end
end

---@param h table the harness
---@param env table the sandbox being built
function M.install(h, env)
    env.Chat = Chat.new({ h = h })
    env.ChatType = strict.enum("ChatType", M.ChatType)
end

return M
