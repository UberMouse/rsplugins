-- Event.<Name>.Subscribe / Unsubscribe, and dispatch to subscribers.
--
-- Event names and payload fields come from docs/api/generated/core/events.lua. Behaviour from
-- https://developer.runescape.com/rs/core/events.html#overview: subscribers run in the order
-- they subscribed; re-using a name replaces that subscription (for that event only); a payload
-- edited by one subscriber is what the next one sees.
--
-- Four live aborts (rs2client SIGABRT, which pcall can't catch; dev-bridge, 2026-10-26;
-- docs/testing.md fidelity ledger) fit two readings, so the harness faults on the union:
--   (a) Unsubscribe of a subscription created while a callback was running (an Event
--       dispatch, an HTTP completion callback or a PrettyUI hook) faults anywhere, even in
--       PluginShutdown: every such Unsubscribe aborted the client, wherever it was called from.
--   (b) Unsubscribe while an Event dispatch or HTTP completion callback is running faults,
--       unless the plugin is dead (PluginShutdown during h:unload, even one a subscriber
--       triggered, as a self-prl does): load-time subscriptions were unsubscribed there safely.

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
            local instance = s.instance
            -- Rule (a): made inside a callback, so it can never be unsubscribed.
            local runtimeMade = instance.callbacks > 0 or instance.uiHooks > 0
            local list = s.subs[s.event]
            for _, entry in ipairs(list) do
                -- Replacing keeps the original position: the docs don't say, so this is a guess.
                if entry.name == name then
                    entry.fn = callback
                    entry.runtime = entry.runtime or runtimeMade
                    return
                end
            end
            list[#list + 1] = { name = name, fn = callback, runtime = runtimeMade }
        end,
        Unsubscribe = function(s, name)
            local instance = s.instance
            local list = s.subs[s.event]
            local index = nil ---@type integer?
            for i, entry in ipairs(list) do
                if entry.name == name then index = i end
            end
            if index and list[index].runtime then
                strict.fault(
                    "Event."
                        .. s.event
                        .. ".Unsubscribe of a subscription made inside a callback: the client"
                        .. " aborts (SIGABRT) wherever it is called from, PluginShutdown included;"
                        .. " see docs/testing.md fidelity ledger"
                )
            end
            if instance.alive and instance.callbacks > 0 then
                strict.fault(
                    "Event."
                        .. s.event
                        .. ".Unsubscribe inside an event or HTTP callback: the client aborts"
                        .. " (SIGABRT), see docs/testing.md fidelity ledger"
                )
            end
            if index then
                list[index].removed = true
                table.remove(list, index)
            end
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

-- Call `fn(...)` as a client callback of `instance`, returning what it returns. `counter` is
-- "callbacks" for an Event dispatch or HTTP completion callback (rules (a) and (b)) or
-- "uiHooks" for a UI hook (rule (a) only: no Unsubscribe from one has been seen to abort).
-- Nested callbacks nest the count, which is restored even when `fn` raises.
---@param instance table
---@param counter "callbacks"|"uiHooks"
---@param fn function
---@return any ...
function M.during(instance, counter, fn, ...)
    instance[counter] = instance[counter] + 1
    local result = table.pack(pcall(fn, ...))
    instance[counter] = instance[counter] - 1
    if not result[1] then error(result[2], 0) end
    return table.unpack(result, 2, result.n)
end

-- Call every current subscriber of `event` with `payload`, under the runtime's limits.
---@param h table the harness
---@param event string
---@param payload table?
function M.dispatch(h, event, payload)
    local instance = h.instance
    if not (instance and instance.alive) then return end
    -- Copy first: a subscriber may unsubscribe others while we iterate (once dead, say).
    local list = { table.unpack(instance.subs[event]) }
    M.during(instance, "callbacks", function()
        for _, entry in ipairs(list) do
            if not entry.removed then
                local label = string.format("Event.%s subscriber '%s'", event, entry.name)
                runtime.call(h.budgetMs, label, entry.fn, payload)
            end
        end
    end)
end

-- The `Event` global for one plugin instance.
---@param instance table
---@return table
function M.namespace(instance)
    local proxies = {}
    instance.callbacks, instance.uiHooks = 0, 0
    for event in pairs(EVENT_NAMES) do
        instance.subs[event] = {}
        proxies[event] =
            Subscription.new({ event = event, subs = instance.subs, instance = instance })
    end
    return EventNamespace.new({ proxies = proxies })
end

return M
