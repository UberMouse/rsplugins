-- The simulated game world: plain data, changed only by `apply(state, op)`.
--
-- An op is a table such as { op = "setVar", domain = "VarPlayer", name = "X", value = 3 }.
-- apply() validates it against the catalogs and stubs, updates the state and returns the
-- changes it made, e.g. { event = "VarTransmit", domain = "VarPlayer", id = 123, old = 0,
-- new = 3 }. It never calls plugin code: the harness (init.lua) turns changes into event
-- payloads and fires them. Ops are data so that scripted tests (the builder in init.lua) and a
-- recorded timeline can drive the same world.

local catalog = require("tests.harness.catalog")
local strict = require("tests.harness.strict")
local stubs = require("tests.harness.stubs")

local M = {}

-- Value types whose values are plain Lua integers, per the ValueType table on
-- https://developer.runescape.com/rs/game/config/vartype.html#valuetype ("Integer"/"Long").
-- Config-typed vars (OBJ, NPC, COORDGRID...) need config proxies the harness doesn't model.
local INTEGER_TYPES = {}
for name in
    (
        "INTEGER LONG VAR_INT CATEGORY CHAR CHATCAT CHATPHRASE CUTSCENE2D IDKIT MAPELEMENT "
        .. "MATERIAL MODEL NPC_UID OVERLAYINTERFACE PLAYER_UID SEQ SPRITE SYNTH VORBIS"
    ):gmatch("%S+")
do
    INTEGER_TYPES[name] = true
end

---@param manifest table the plugin's parsed plugin.json ({} if it has none)
---@return table state
function M.new(manifest)
    local requested = {}
    for _, kind in ipairs({ "optionalPermissions", "requiredPermissions" }) do
        for _, perm in ipairs(manifest[kind] or {}) do
            requested[perm] = kind
        end
    end
    return {
        vars = { VarPlayer = {}, VarClient = {} }, -- domain -> id -> value
        player = { loggedIn = false, displayName = nil, login = 0, skills = {} },
        invs = {}, -- inv id -> { id, size, slots = { [i] = { obj = id, count = n } }, generation }
        invGeneration = 0,
        objs = {}, -- obj id -> fields a test defined (name, category...)
        permissions = { requested = requested, granted = {} },
    }
end

-- Resolve a var by name or ID to its catalog record, or raise.
---@param domain string
---@param key string|integer
---@return table
function M.varRecord(domain, key)
    if domain ~= "VarPlayer" and domain ~= "VarClient" then
        strict.fault("unmocked API: var." .. tostring(domain) .. " (only VarPlayer and VarClient)")
    end
    local rec = catalog.var(domain, key)
    if not rec then
        strict.fault(string.format("var.%s %s is not in docs/vars/vars.csv", domain, tostring(key)))
    end
    ---@cast rec -? -- fault() never returns
    return rec
end

-- Check a var value against its catalog type.
---@param rec table catalog record
---@param value any
local function checkVarValue(rec, value)
    local label = rec.domain .. "." .. rec.name
    if INTEGER_TYPES[rec.type] then
        if math.type(value) ~= "integer" then
            strict.fault(
                label .. " is " .. rec.type .. ": expected an integer, got " .. tostring(value)
            )
        end
        if rec.mask then
            local width = rec.mask
            while width & 1 == 0 do
                width = width >> 1
            end
            if value < 0 or value > width then
                strict.fault(label .. " is a VarBit: value must be 0.." .. width)
            end
        end
    elseif rec.type == "STRING" then
        if type(value) ~= "string" then strict.fault(label .. " is STRING: expected a string") end
    elseif rec.type == "BOOLEAN" then
        if type(value) ~= "boolean" then
            strict.fault(label .. " is BOOLEAN: expected a boolean")
        end
    else
        strict.fault(
            label
                .. " is "
                .. rec.type
                .. ": the harness only models integer, string and "
                .. "boolean vars"
        )
    end
end

-- An obj's ID, resolved from a config name or ID, or raise.
---@param key string|integer
---@return integer
local function objId(key)
    local id = catalog.config("Obj", key)
    if not id then strict.fault("obj " .. tostring(key) .. " is not in docs/api/consts/Obj.lua") end
    ---@cast id -? -- fault() never returns
    return id
end

---@param key string|integer
---@return integer
function M.invId(key)
    local id = catalog.config("Inv", key)
    if not id then strict.fault("inv " .. tostring(key) .. " is not in docs/api/consts/Inv.lua") end
    ---@cast id -? -- fault() never returns
    return id
end

local SkillType = stubs.value("game/player.lua", "SkillType")
local SKILLS = {}
for _, v in pairs(SkillType) do
    SKILLS[v] = true
end

local OBJ_FIELDS = stubs.fields("ObjType")

local ops = {}

function ops.setVar(state, op)
    local rec = M.varRecord(op.domain, op.name or op.id)
    checkVarValue(rec, op.value)
    local values = state.vars[rec.domain]
    local old = values[rec.id]
    values[rec.id] = op.value
    -- The client fires VarTransmit for every update, changed or not (core/events.html#vartransmit).
    return { { event = "VarTransmit", domain = rec.domain, id = rec.id, old = old, new = op.value } }
end

function ops.login(state, op)
    assert(type(op.displayName) == "string", "login needs a displayName")
    local p = state.player
    p.loggedIn, p.displayName, p.login = true, op.displayName, p.login + 1
    return {}
end

function ops.logout(state)
    state.player.loggedIn = false
    return {}
end

-- Skill levels and XP, as the Player getters return them. Unset ones default to the
-- uncapped value (level / xp).
function ops.setSkill(state, op)
    if not SKILLS[op.skill] then
        strict.fault("setSkill: not a SkillType value: " .. tostring(op.skill))
    end
    assert(
        math.type(op.level) == "integer" and math.type(op.xp) == "integer",
        "setSkill needs integer level and xp"
    )
    state.player.skills[op.skill] = {
        uncapped = op.level,
        capped = op.capped or op.level,
        gameplay = op.gameplay or op.level,
        xp = op.xp,
        xpCapped = op.xpCapped or op.xp,
    }
    return {}
end

function ops.defineObj(state, op)
    local id = objId(op.obj)
    for k in pairs(op.fields) do
        if not OBJ_FIELDS[k] then
            strict.fault("ObjType has no field " .. tostring(k) .. " in docs/api")
        end
    end
    state.objs[id] = op.fields
    return {}
end

-- Replace an inventory's contents. `slots` maps slot index (1-based) to { obj, count }.
function ops.setInventory(state, op)
    local id = M.invId(op.inv)
    local old = state.invs[id]
    local slots, highest = {}, 0
    for i, slot in pairs(op.slots) do
        assert(math.type(i) == "integer" and i >= 1, "inventory slots are 1-based integers")
        slots[i] = { obj = objId(slot.obj), count = slot.count or 1 }
        highest = math.max(highest, i)
    end
    local size = op.size or (old and old.size) or highest
    if highest > size then
        strict.fault("slot " .. highest .. " is past the inventory size " .. size)
    end
    if not old then
        state.invGeneration = state.invGeneration + 1
        state.invs[id] = { id = id, size = size, slots = slots, generation = state.invGeneration }
        return { { event = "InventoryAdded", inv = id } }
    end
    local changed = {}
    for i = 1, math.max(size, old.size) do
        local a, b = old.slots[i], slots[i]
        if (a and a.obj) ~= (b and b.obj) or (a and a.count) ~= (b and b.count) then
            changed[#changed + 1] = i
        end
    end
    old.slots, old.size = slots, size
    if #changed == 0 then return {} end
    return { { event = "InventoryUpdated", inv = id, slots = changed } }
end

function ops.removeInventory(state, op)
    local id = M.invId(op.inv)
    if not state.invs[id] then return {} end
    state.invs[id] = nil
    return { { event = "InventoryRemoved", inv = id } }
end

-- Grant or revoke a permission. Only permissions the manifest requests can be granted, and
-- only optional ones fire OptionalPermissionChanged (core/events.html#optionalpermissionchanged).
function ops.setPermission(state, op)
    local perms = state.permissions
    local kind = perms.requested[op.permission]
    if not kind then
        strict.fault(tostring(op.permission) .. " is not requested in the plugin's plugin.json")
    end
    local enabled = op.enabled and true or false
    if (perms.granted[op.permission] or false) == enabled then return {} end
    perms.granted[op.permission] = enabled or nil
    if kind ~= "optionalPermissions" then return {} end
    return {
        { event = "OptionalPermissionChanged", permission = op.permission, enabled = enabled },
    }
end

-- A chat message arriving from the server.
function ops.chat(_, op)
    assert(type(op.message) == "string", "chat needs a message string")
    return {
        { event = "ChatMessage", message = op.message, chatType = op.chatType, sender = op.sender },
    }
end

-- Apply one op and return the changes it made (event records for the harness to fire).
---@param state table
---@param op table
---@return table[] changes
function M.apply(state, op)
    local handler = ops[op.op]
    if not handler then strict.fault("unknown world op: " .. tostring(op.op)) end
    return handler(state, op)
end

return M
