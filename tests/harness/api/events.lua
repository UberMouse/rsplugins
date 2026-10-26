-- Event.<Name>.Subscribe / Unsubscribe, and dispatch to subscribers.
--
-- Event names and payload fields come from docs/api/generated/core/events.lua. Behaviour from
-- https://developer.runescape.com/rs/core/events.html#overview: subscribers run in the order
-- they subscribed; a payload edited by one subscriber is what the next one sees.
--
-- From the live client (docs/testing.md fidelity ledger, dev-bridge probes 2026-10-26):
-- - Subscribe with a name the event already has does nothing: the first callback stays, where
--   it was, though the page says the name is replaced. After an Unsubscribe the name goes last.
-- - Unsubscribe returns true if it removed the name, false otherwise.
-- - Event.<X>.Unsubscribe passed straight to pcall or xpcall, so that a C function calls it,
--   aborts the client (rs2client SIGABRT, which pcall can't catch): all seven aborts used that
--   form. A direct call, a closure under pcall and a tail call (`return Event.X.Unsubscribe(k)`
--   from a function pcall called) all survived. The fault is recorded, so the plugin's own
--   pcall can't hide it.

local runtime = require("tests.harness.runtime")
local strict = require("tests.harness.strict")
local stubs = require("tests.harness.stubs")

local M = {}

local Subscription = strict.class("EventSubscription", {
    statics = {
        Subscribe = function(s, name, callback)
            if type(name) ~= "string" or type(callback) ~= "function" then
                strict.fault("Event." .. s.event .. ".Subscribe(name: string, callback: function)")
            end
            local list = s.subs[s.event]
            for _, entry in ipairs(list) do
                if entry.name == name then return end
            end
            list[#list + 1] = { name = name, fn = callback }
        end,
        Unsubscribe = function(s, name)
            if strict.callerKind() == "C" then
                strict.fault(
                    "Event."
                        .. s.event
                        .. ".Unsubscribe passed straight to pcall: the client aborts (SIGABRT),"
                        .. " see docs/testing.md fidelity ledger"
                )
            end
            local list = s.subs[s.event]
            for i, entry in ipairs(list) do
                if entry.name == name then
                    table.remove(list, i)
                    entry.removed = true
                    return true
                end
            end
            return false
        end,
    },
})

local EVENT_NAMES = stubs.fields("Event")

local eventFields = {}
for event in pairs(EVENT_NAMES) do
    eventFields[event] = function(s)
        return s.proxies[event]
    end
end
local EventNamespace = strict.class("Event", { fields = eventFields })

-- Payload classes, built on first use from the stub's <Name>EventPayload class. Fields the
-- stub doesn't mark "(Read-only)" are writable.
local payloadClasses = {}

---@param event string
---@return table? # the class, or nil for events without a payload (ServerLogic)
local function payloadClass(event)
    local name = event .. "EventPayload"
    if payloadClasses[name] == nil then
        local stubFields = stubs.index().classes[name]
        if not stubFields then
            payloadClasses[name] = false
        else
            local fields, writable = {}, {}
            for field, line in pairs(stubFields) do
                fields[field] = function(s)
                    local v = s[field]
                    if v == nil then
                        strict.fault("unmocked state: " .. name .. "." .. field .. " was not set")
                    end
                    return v
                end
                if not line:find("(Read-only)", 1, true) then writable[field] = true end
            end
            payloadClasses[name] = strict.class(name, { fields = fields, writable = writable })
        end
    end
    return payloadClasses[name] or nil
end

-- A payload proxy for `event` holding `values`; nil for events without a payload. Faults on a
-- field the stub's payload class lacks.
---@param event string
---@param values table?
---@return table?
function M.payload(event, values)
    if not EVENT_NAMES[event] then strict.fault("unmocked API: Event." .. tostring(event)) end
    local class = payloadClass(event)
    if not class then
        if values and next(values) then strict.fault("Event." .. event .. " has no payload") end
        return nil
    end
    local stubFields = stubs.fields(event .. "EventPayload")
    local state = {}
    for k, v in pairs(values or {}) do
        if not stubFields[k] then
            strict.fault(event .. "EventPayload has no field " .. tostring(k))
        end
        state[k] = v
    end
    return class.new(state)
end

-- Call every current subscriber of `event` with `payload`, under the runtime's limits.
---@param h table the harness
---@param event string
---@param payload table?
function M.dispatch(h, event, payload)
    local instance = h.instance
    if not (instance and instance.alive) then return end
    -- Copy first: a subscriber may unsubscribe itself or others while we iterate.
    local list = { table.unpack(instance.subs[event]) }
    for _, entry in ipairs(list) do
        if not entry.removed then
            local label = string.format("Event.%s subscriber '%s'", event, entry.name)
            runtime.call(h.budgetMs, label, entry.fn, payload)
        end
    end
end

-- The `Event` global for one plugin instance.
---@param instance table
---@return table
function M.namespace(instance)
    local proxies = {}
    for event in pairs(EVENT_NAMES) do
        instance.subs[event] = {}
        proxies[event] = Subscription.new({ event = event, subs = instance.subs })
    end
    return EventNamespace.new({ proxies = proxies })
end

return M
