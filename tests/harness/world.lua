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
local INT32_MIN, INT32_MAX = -0x80000000, 0x7FFFFFFF

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
        -- tile: the player's { x, z, level } once a setPosition op gives one
        player = { loggedIn = false, displayName = nil, login = 0, skills = {}, tile = nil },
        -- inv id -> { id, size, slots = { [i] = { obj = id, count = n } }, generation }, with
        -- only the non-empty slots in `slots`
        invs = {},
        invGeneration = 0,
        objs = {}, -- obj id -> fields a test defined (name, category...)
        -- known: every permission a setPermission op has named, granted or not, so a replay
        -- can tell a decided permission from the default (api/plugin.lua).
        permissions = { requested = requested, granted = {}, known = {} },
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

-- Why a var can't hold `value` in the harness's world, or nil if it can. A replay uses this to
-- leave alone the vars the world doesn't model.
---@param rec table catalog record
---@param value any
---@return string?
function M.varValueError(rec, value)
    local label = rec.domain .. "." .. rec.name
    if INTEGER_TYPES[rec.type] then
        if math.type(value) ~= "integer" then
            return label .. " is " .. rec.type .. ": expected an integer, got " .. tostring(value)
        end
        if rec.baseVar then
            if not rec.mask then
                return label .. " is a VarBit of " .. rec.baseVar .. " with no bits in vars.csv"
            end
            local max = rec.mask >> rec.lo
            if value < 0 or value > max then
                return string.format(
                    "%s is bits %d-%d of %s: value must be 0..%d, got %d",
                    label,
                    rec.lo,
                    rec.hi,
                    rec.baseVar,
                    max,
                    value
                )
            end
        elseif rec.type ~= "LONG" and (value < INT32_MIN or value > INT32_MAX) then
            -- The client holds every non-LONG int var as signed 32-bit (the 2026-10-25 var dump
            -- spans exactly that range), so a value outside it could never be read back.
            return string.format(
                "%s is %s: value must be %d..%d, got %d",
                label,
                rec.type,
                INT32_MIN,
                INT32_MAX,
                value
            )
        end
    elseif rec.type == "STRING" then
        if type(value) ~= "string" then return label .. " is STRING: expected a string" end
    elseif rec.type == "BOOLEAN" then
        if type(value) ~= "boolean" then return label .. " is BOOLEAN: expected a boolean" end
    else
        return label
            .. " is "
            .. rec.type
            .. ": the harness only models integer, string and boolean vars"
    end
    return nil
end

---@param rec table catalog record
---@param value any
local function checkVarValue(rec, value)
    local err = M.varValueError(rec, value)
    if err then strict.fault(err) end
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
local function invId(key)
    local id = catalog.config("Inv", key)
    if not id then strict.fault("inv " .. tostring(key) .. " is not in docs/api/consts/Inv.lua") end
    ---@cast id -? -- fault() never returns
    return id
end

local SKILLS = {}
for _, v in pairs(stubs.value("game/player.lua", "SkillType")) do
    SKILLS[v] = true
end

-- Whether `v` is a SkillType value.
---@param v any
---@return boolean
function M.isSkill(v)
    return SKILLS[v] == true
end

-- Whether the plugin holds permission `perm` (a name string) in `state`.
---@param state table
---@param perm string
---@return boolean
function M.granted(state, perm)
    return state.permissions.granted[perm] == true
end

local OBJ_FIELDS = stubs.fields("ObjType")

local ops = {}

-- A var's value in the world, or nil if it was never set. A VarBit holds no value of its own:
-- it is its bits of its base var's value, read unsigned (nil while the base is unset).
---@param state table
---@param rec table catalog record
---@return any
function M.varValue(state, rec)
    local values = state.vars[rec.domain]
    if not rec.baseVar then return values[rec.id] end
    local base = rec.mask and values[M.varRecord(rec.domain, rec.baseVar).id]
    return base and (base & rec.mask) >> rec.lo
end

-- The signed 32-bit int with v's low 32 bits, as the client holds an INTEGER var.
---@param v integer
---@return integer
local function int32(v)
    v = v & 0xFFFFFFFF
    return v >= 0x80000000 and v - 0x100000000 or v
end

-- Setting a VarBit writes its bits into its base var (starting an unset base at 0) and keeps
-- the base's other bits. The update names the var that was set, base or VarBit, with that
-- var's old and new values: the var-dump change log (2026-10-25) has both kinds of update.
function ops.setVar(state, op)
    local rec = M.varRecord(op.domain, op.name or op.id)
    checkVarValue(rec, op.value)
    local values = state.vars[rec.domain]
    local old = values[rec.id]
    if rec.baseVar then
        local base = M.varRecord(rec.domain, rec.baseVar)
        values[base.id] = values[base.id] or 0
        old = M.varValue(state, rec)
        values[base.id] = int32((values[base.id] & ~rec.mask) | (op.value << rec.lo))
    else
        values[rec.id] = op.value
    end
    -- The client fires VarTransmit for every update, changed or not (core/events.html#vartransmit).
    return { { event = "VarTransmit", domain = rec.domain, id = rec.id, old = old, new = op.value } }
end

-- `displayName` may be nil: a replay infers a login from Player.IsAvailable() before it has
-- seen the name read.
function ops.login(state, op)
    assert(op.displayName == nil or type(op.displayName) == "string", "displayName is a string")
    local p = state.player
    p.loggedIn, p.displayName, p.login = true, op.displayName, p.login + 1
    return {}
end

function ops.logout(state)
    state.player.loggedIn = false
    return {}
end

-- The player's tile, in world tile units as CoordGrid's x / z / level give them
-- (game/coordgrid.html#properties: x and z 0-12799, level 0-3). It survives a logout.
function ops.setPosition(state, op)
    local function inRange(v, max)
        return math.type(v) == "integer" and v >= 0 and v <= max
    end
    assert(
        inRange(op.x, 12799) and inRange(op.z, 12799) and inRange(op.level, 3),
        "setPosition needs integer x and z (0-12799) and level (0-3)"
    )
    state.player.tile = { x = op.x, z = op.z, level = op.level }
    return {}
end

-- Skill levels and XP, as the Player getters return them. Unset ones default to the
-- uncapped value (level / xp).
function ops.setSkill(state, op)
    if not M.isSkill(op.skill) then
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

-- The obj ID of an empty slot. In the client, GetSlots() gives every empty slot as obj -1
-- (configName "UNKNOWN") with count 0 (see tests/fixtures/recorder-demo-shop.jsonl).
M.EMPTY_OBJ = -1

-- Replace an inventory's contents. `slots` maps slot index (1-based) to { obj, count }; a slot
-- left out, or given as obj -1 (how recordings write empty slots), is empty. A real obj with
-- count 0 is not empty: a bought-out shop line stays in its shop inventory that way.
function ops.setInventory(state, op)
    local id = invId(op.inv)
    local old = state.invs[id]
    local slots, highest = {}, 0
    for i, slot in pairs(op.slots) do
        assert(math.type(i) == "integer" and i >= 1, "inventory slots are 1-based integers")
        if slot.obj ~= M.EMPTY_OBJ then
            slots[i] = { obj = objId(slot.obj), count = slot.count or 1 }
        end
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
    local id = invId(op.inv)
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
    perms.known[op.permission] = true
    if M.granted(state, op.permission) == enabled then return {} end
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
