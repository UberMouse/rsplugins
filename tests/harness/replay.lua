-- Replaying a recording (timeline.lua) into a harness's world: the shell around the pure
-- timeline. init.lua calls it from load() and step(), and the mocks reach the recorded reads
-- through h:recorded(). See docs/testing.md, "Replaying a recording".
--
-- As the clock passes each entry:
--   * an event's world op (event.op) is applied to h.world.state without firing what it
--     changed, and then the recorded event is fired, so the plugin gets the delivery it got in
--     the client (an InventoryUpdated stays one, even for an inventory new to the world);
--   * a read goes into the read table, and also into the world where the world models it:
--     a var's value, and the login (Player.IsAvailable(), the displayName). The mocks serve
--     the world first and fall back to the read table, so a test can script further changes
--     on top of a recording.

local catalog = require("tests.harness.catalog")
local chat = require("tests.harness.api.chat")
local events = require("tests.harness.api.events")
local inventory = require("tests.harness.api.inventory")
local paths = require("tests.harness.paths")
local persistentdb = require("tests.harness.api.persistentdb")
local strict = require("tests.harness.strict")
local timeline = require("tests.harness.timeline")
local vars = require("tests.harness.api.vars")
local world = require("tests.harness.world")

local M = {}

-- Attach a recording to a harness that isn't loaded yet: set each permission the recording
-- checked as its first check found it (over opts.grant), and seed PersistentDB from each
-- key's first Get.
---@param h table
---@param source string|table a .jsonl path (repo-relative or absolute), or a list of entries
---@return table timeline
function M.attach(h, source)
    assert(not h.instance, "attach a recording before h:load()")
    local entries = source
    if type(source) == "string" then
        local file = source:sub(1, 1) == "/" and source or paths.repo(source)
        entries = timeline.parse(assert(paths.read(file), "cannot read recording " .. file))
    end
    ---@cast entries table[]
    local tl = timeline.build(entries)
    for permission, granted in pairs(tl.grants) do
        world.apply(
            h.world.state,
            { op = "setPermission", permission = permission, enabled = granted }
        )
    end
    for key, first in pairs(tl.db) do
        persistentdb.seed(h.db, key, first.op, first.v)
    end
    -- reads: path -> { v = value }, so a recorded nil is told apart from a path never read.
    -- readsDone / eventsDone: the last tick whose leading reads / events have been applied.
    -- skipped: { t, event, why } per recorded delivery the harness couldn't make.
    h.replay = { timeline = tl, reads = {}, readsDone = -1, eventsDone = -1, skipped = {} }
    return tl
end

-- The value of a read the world doesn't hold: the latest recorded one, or a fault.
---@param h table
---@param key string the recorder's path for the read
---@param message string? the fault when not replaying ("unmocked state: ...")
---@return any
function M.lookup(h, key, message)
    local rp = h.replay
    if not rp then strict.fault(assert(message, "only replay mocks read without a message")) end
    local read = rp.reads[key]
    if not read then strict.fault("unrecorded: " .. key) end
    return read.v
end

-- A recorded read: into the read table, and into the world where the world models it.
---@param h table
---@param read table
local function applyRead(h, read)
    h.replay.reads[read.path] = { v = read.v }
    local state, path, v = h.world.state, read.path, read.v
    local player = state.player
    if path == "Player.IsAvailable()" then
        if v == true and not player.loggedIn then
            world.apply(state, { op = "login" }) -- the name comes with its own read
        elseif v == false and player.loggedIn then
            world.apply(state, { op = "logout" })
        end
    elseif path == "Player.GetEntity().displayName" then
        if type(v) == "string" and not (player.loggedIn and player.displayName == v) then
            world.apply(state, { op = "login", displayName = v })
        end
    else
        local domain, name = path:match("^var%.(%w+)%.([%w_]+)%.value$")
        local rec = domain and catalog.var(domain, name)
        if rec and world.varValueError(rec, v) == nil then
            world.apply(state, { op = "setVar", domain = rec.domain, id = rec.id, value = v })
        end
    end
end

-- Apply an event's world op, unless the world doesn't model what it changes: a var the
-- catalog lacks, or a value its type can't hold (config-typed vars, and BOOLEAN vars, which
-- VarTransmit reports as 0/1). Chat changes nothing in the world.
---@param h table
---@param op table?
local function applyOp(h, op)
    if not op or op.op == "chat" then return end
    if op.op == "setVar" then
        local rec = catalog.var(op.domain, op.id or op.name)
        if not (rec and world.varValueError(rec, op.value) == nil) then return end
    end
    world.apply(h.world.state, op)
end

-- Deliver a recorded event, its payload's API objects rebuilt from the world.
---@param h table
---@param t integer
---@param entry table { name, payload }
local function fire(h, t, entry)
    local name, p = entry.name, entry.payload
    if name == "ServerLogic" then return events.dispatch(h, name, nil) end
    if name == "VarTransmit" then
        local rec = type(p.var) == "table" and catalog.var(p.var.type, p.var.id)
        if not rec then
            local why = "var "
                .. tostring(p.var and p.var.config)
                .. " is not in docs/vars/vars.csv"
            table.insert(h.replay.skipped, { t = t, event = name, why = why })
            return
        end
        return h:fire(name, {
            var = vars.proxy(h, rec.domain, rec.id),
            oldValue = p.oldValue,
            newValue = p.newValue,
        })
    end
    if name == "InventoryAdded" or name == "InventoryUpdated" or name == "InventoryRemoved" then
        return h:fire(name, {
            inv = inventory.invType(h, p.inv.id),
            slotsUpdated = name == "InventoryUpdated" and p.slotsUpdated or nil,
        })
    end
    if name == "ChatMessage" then
        if not h.world.state.permissions.granted.chatAccess then
            strict.fault(
                "replay: the recording delivers ChatMessage at t="
                    .. t
                    .. ", but chatAccess "
                    .. 'isn\'t granted (pass grant = { "chatAccess" })'
            )
        end
        return chat.deliver(h, p.chatMessage, p.chatType, p.senderNameUnfiltered, p.timestamp)
    end
    for field, v in pairs(p) do
        if type(v) == "table" then
            strict.fault("replay can't rebuild " .. name .. "EventPayload." .. field)
        end
    end
    h:fire(name, p)
end

-- Before Logic: the reads Logic's callbacks made at this tick (main.lua's, at tick 0).
---@param h table
function M.beforeLogic(h)
    local rp = h.replay
    if not rp or h.tick <= rp.readsDone then return end
    rp.readsDone = h.tick
    local group = rp.timeline.ticks[h.tick]
    for _, read in ipairs(group and group.leading or {}) do
        applyRead(h, read)
    end
end

-- After Logic: this tick's events, each after its op and the reads its callbacks made.
-- Returns true while the recording supplies ServerLogic, so the harness's own clock doesn't
-- fire it too.
---@param h table
---@return boolean
function M.afterLogic(h)
    local rp = h.replay
    if not rp then return false end
    if h.tick > rp.eventsDone then
        rp.eventsDone = h.tick
        local group = rp.timeline.ticks[h.tick]
        for _, event in ipairs(group and group.events or {}) do
            applyOp(h, event.entry.op)
            for _, read in ipairs(event.reads) do
                applyRead(h, read)
            end
            if not event.skip then fire(h, h.tick, event.entry) end
        end
    end
    return h.tick <= rp.timeline.lastTick
end

return M
