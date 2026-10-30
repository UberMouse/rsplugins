-- Event.<Name>.Subscribe / Unsubscribe, and dispatch to subscribers.
--
-- Event names and payload fields come from docs/api/generated/core/events.lua. Behaviour from
-- https://developer.runescape.com/rs/core/events.html#overview: subscribers run in the order
-- they subscribed; a payload edited by one subscriber is what the next one sees.
--
-- From the live client (docs/testing.md fidelity ledger, dev-bridge probes 2026-10-26 and
-- 2026-10-30):
-- - Subscribe with a name the event already has does nothing: the first callback stays, where
--   it was, though the page says the name is replaced. After an Unsubscribe the name goes last.
-- - Mid-dispatch of an event: a subscriber added first runs on the next dispatch; Unsubscribe is
--   deferred to the dispatch's end, so Subscribe of the same name meanwhile does nothing and
--   the name is lost; a subscriber that reloads the plugin ends the old instance's dispatch.
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

-- The subscriber-list protocol, shared with fakes that subscribe from inside the harness (the
-- PrettyUI AchievementPopup): going through the plugin's Event global would put the harness's
-- runtime (a C frame) between the call and Unsubscribe's callerKind check. No argument checks.

-- Add `fn` under `name`; nothing if the name is already there. A removal deferred to the end
-- of a dispatch still counts as present.
---@param instance table
---@param event string
---@param name string
---@param fn function
function M.subscribe(instance, event, name, fn)
    local list = instance.subs[event]
    for _, entry in ipairs(list) do
        if entry.name == name then return end
    end
    list[#list + 1] = { name = name, fn = fn }
end

-- Remove `name`; true if it was there. Mid-dispatch of this event the entry stays until the
-- dispatch ends (M.dispatch drops it), as in the client (probe 2026-10-30).
---@param instance table
---@param event string
---@param name string
---@return boolean
function M.unsubscribe(instance, event, name)
    local list = instance.subs[event]
    for i, entry in ipairs(list) do
        if entry.name == name and not entry.removed then
            entry.removed = true
            if not instance.dispatching[event] then table.remove(list, i) end
            return true
        end
    end
    return false
end

local Subscription = strict.class("EventSubscription", {
    statics = {
        Subscribe = function(s, name, callback)
            if type(name) ~= "string" or type(callback) ~= "function" then
                strict.fault("Event." .. s.event .. ".Subscribe(name: string, callback: function)")
            end
            M.subscribe(s.instance, s.event, name, callback)
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
            return M.unsubscribe(s.instance, s.event, name)
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
    -- Copy first: a subscriber added during the dispatch first runs on the next one.
    local list = { table.unpack(instance.subs[event]) }
    -- Counted, since a subscriber may dispatch the same event again (nested).
    local dispatching = instance.dispatching
    dispatching[event] = (dispatching[event] or 0) + 1
    -- A subscriber's error still has to end the dispatch (counter and deferred removals), or
    -- the harness, reused after the error, would defer every later Unsubscribe forever.
    local ok, err = pcall(function()
        for _, entry in ipairs(list) do
            -- Alive is checked per subscriber: a subscriber that reloads the plugin ends the old
            -- instance's dispatch (probe 2026-10-30).
            if not instance.alive then break end
            if not entry.removed then
                local label = string.format("Event.%s subscriber '%s'", event, entry.name)
                runtime.call(h.budgetMs, label, entry.fn, payload)
            end
        end
    end)
    dispatching[event] = dispatching[event] - 1
    if dispatching[event] == 0 then
        dispatching[event] = nil
        -- Apply the removals deferred during the dispatch.
        local subs, kept = instance.subs[event], {}
        for _, entry in ipairs(subs) do
            if not entry.removed then kept[#kept + 1] = entry end
        end
        for i = #subs, 1, -1 do
            subs[i] = kept[i]
        end
    end
    -- The original error, untouched, so callers and specs see what runtime.call raised.
    if not ok then error(err, 0) end
end

-- The `Event` global for one plugin instance.
---@param instance table
---@return table
function M.namespace(instance)
    local proxies = {}
    for event in pairs(EVENT_NAMES) do
        instance.subs[event] = {}
        proxies[event] = Subscription.new({ event = event, instance = instance })
    end
    return EventNamespace.new({ proxies = proxies })
end

return M
