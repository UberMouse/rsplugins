-- Inventory.Find, Inv / InvSlot, and the config.Inv / config.Obj entries they hand out.
--
-- From https://developer.runescape.com/rs/game/inventory.html: Find returns an Inv (the stub
-- says Inv[]; the page says Inv); slots are 1-indexed; GetSlot/GetSlots return copies; an
-- Inv becomes invalid when its inventory is removed, and re-adding it creates a new Inv
-- object. The page names the validity property `isValid` (the stub says `valid`).
--
-- config is mocked only as far as inventories need: config.Inv and config.Obj, with names and
-- IDs from docs/api/consts/. ObjType fields beyond id/configName/typeName come from
-- h.world:defineObj and fault if a test reads one it didn't define.

local recording = require("dev/recording")

local catalog = require("tests.harness.catalog")
local strict = require("tests.harness.strict")
local stubs = require("tests.harness.stubs")
local world = require("tests.harness.world")

local M = {}

-- config proxy -> its id, for the API functions that take an InvType or ObjType.
local invTypeIds = setmetatable({}, { __mode = "k" })
local objTypeIds = setmetatable({}, { __mode = "k" })

local InvType = strict.class("InvType", {
    fields = {
        id = function(s)
            return s.id
        end,
        configName = function(s)
            return s.name
        end,
        typeName = function()
            return "Inv"
        end,
        size = function(s)
            local inv = s.h.world.state.invs[s.id]
            if not inv then
                return s.h:recorded(
                    recording.memberPath(recording.configPath("config", "Inv", s.name), "size"),
                    "unmocked state: InvType.size of " .. s.name .. " (no h.world:setInventory)"
                )
            end
            return inv.size
        end,
    },
})

local objFields = {}
for field in pairs(stubs.fields("ObjType")) do
    objFields[field] = function(s)
        local defined = s.h.world.state.objs[s.id]
        local v = defined and defined[field]
        if v == nil then
            return s.h:recorded(
                recording.memberPath(recording.configPath("config", "Obj", tostring(s.name)), field),
                string.format("unmocked state: ObjType.%s of %s (h.world:defineObj)", field, s.name)
            )
        end
        return v
    end
end
objFields.id = function(s)
    return s.id
end
objFields.configName = function(s)
    return s.name
end
objFields.typeName = function()
    return "Obj"
end
local ObjType = strict.class("ObjType", { fields = objFields })

-- One config proxy per config per harness, so `==` comparisons work.
---@param h table
---@param kind string "Inv" or "Obj"
---@param id integer
---@return table
local function configProxy(h, kind, id)
    local k = kind .. ":" .. id
    if not h.configProxies[k] then
        local _, name = catalog.config(kind, id)
        -- An empty slot's obj: not in docs/api/consts, named as the client names it.
        if kind == "Obj" and id == world.EMPTY_OBJ then name = "UNKNOWN" end
        local proxy = (kind == "Inv" and InvType or ObjType).new({ h = h, id = id, name = name });
        (kind == "Inv" and invTypeIds or objTypeIds)[proxy] = id
        h.configProxies[k] = proxy
    end
    return h.configProxies[k]
end

---@param h table the harness
---@param id integer
---@return table
function M.invType(h, id)
    return configProxy(h, "Inv", id)
end

local InvSlot = strict.class("InvSlot", {
    fields = {
        obj = function(s)
            return configProxy(s.h, "Obj", s.obj)
        end,
        count = function(s)
            return s.count
        end,
    },
})

-- The live inventory behind an Inv, or a fault if it has been removed (or re-added as a
-- new Inv) since this one was handed out.
---@param s table Inv state
---@return table
local function live(s)
    local inv = s.h.world.state.invs[s.id]
    if not (inv and inv.generation == s.generation) then
        strict.fault("Inv used after its inventory was removed (check inv.isValid)")
    end
    return inv
end

---@param h table
---@param inv table world inventory
---@param i integer
---@return table?
local function slotCopy(h, inv, i)
    local slot = inv.slots[i]
    return slot and InvSlot.new({ h = h, obj = slot.obj, count = slot.count })
end

-- An empty slot as the client's GetSlots() gives it: obj -1, count 0.
---@param h table
---@return table
local function emptySlot(h)
    return InvSlot.new({ h = h, obj = world.EMPTY_OBJ, count = 0 })
end

---@param key any an ObjType proxy or an obj ID
---@return integer?
local function objKey(key)
    if objTypeIds[key] then return objTypeIds[key] end
    if math.type(key) == "integer" then return key end
    return nil
end

-- A config argument's path, as the recorder writes one; nil for any other argument.
---@param v any
---@return string?
local function configArgPath(v)
    local kind = (invTypeIds[v] and "Inv") or (objTypeIds[v] and "Obj")
    return kind and recording.configPath("config", kind, tostring(v.configName)) or nil
end

local Inv = strict.class("Inv", {
    fields = {
        id = function(s)
            return live(s).id
        end,
        config = function(s)
            return configProxy(s.h, "Inv", live(s).id)
        end,
        isValid = function(s)
            local inv = s.h.world.state.invs[s.id]
            return inv ~= nil and inv.generation == s.generation
        end,
        slotCount = function(s)
            return live(s).size
        end,
        usedSlotCount = function(s)
            local n = 0
            for _ in pairs(live(s).slots) do
                n = n + 1
            end
            return n
        end,
        freeSlotCount = function(s)
            local inv, used = live(s), 0
            for _ in pairs(inv.slots) do
                used = used + 1
            end
            return inv.size - used
        end,
    },
    methods = {
        -- An empty slot returns nil: the page only says "Returns nil on failure". Unconfirmed:
        -- the client may give an obj -1 slot here, as GetSlots does.
        GetSlot = function(s, index)
            local inv = live(s)
            if math.type(index) ~= "integer" then strict.fault("Inv:GetSlot(index: Integer)") end
            return slotCopy(s.h, inv, index)
        end,
        -- Dense, one InvSlot per slot, with empty slots as obj -1 x0 (seen in the client; see
        -- tests/fixtures/recorder-demo-shop.jsonl).
        GetSlots = function(s)
            local inv, out = live(s), {}
            for i = 1, inv.size do
                out[i] = slotCopy(s.h, inv, i) or emptySlot(s.h)
            end
            return out
        end,
        GetTotal = function(s, key)
            local inv, id = live(s), objKey(key)
            if not id then strict.fault("Inv:GetTotal expects an ObjType or an obj ID") end
            local total = 0
            for _, slot in pairs(inv.slots) do
                if slot.obj == id then total = total + slot.count end
            end
            return total
        end,
        GetCategoryTotal = function(s, category)
            local inv, total = live(s), 0
            for _, slot in pairs(inv.slots) do
                if configProxy(s.h, "Obj", slot.obj).category == category then
                    total = total + slot.count
                end
            end
            return total
        end,
    },
})

-- An InvSlot from its recorded form, { obj = { config, id, type }, count }. Anything else
-- (an obj written as text, a value cut short by the recorder's cap) faults, naming the path.
---@param h table
---@param v any
---@param path string the read's path, for the fault
---@return table?
local function recordedSlot(h, v, path)
    if v == nil then return nil end
    local obj = type(v) == "table" and v.obj or nil
    local id = type(obj) == "table" and obj.id or nil
    if math.type(id) ~= "integer" then
        strict.fault("replay: the recorded slot at " .. path .. " has no obj id")
    end
    return InvSlot.new({ h = h, obj = id, count = v.count })
end

-- A field getter that serves the recorded read under this Inv's path.
local function recordedField(name)
    return function(s)
        return s.h:recorded(recording.memberPath(s.path, name))
    end
end

-- Replay only: an Inv for an inventory the recording shows the plugin found, but that the
-- world doesn't hold yet (no InventoryAdded/Updated so far). Every member is the recorded
-- read under its path, e.g. `Inventory.Find(config.Inv.INV).usedSlotCount`, so reading one
-- the recording lacks faults `unrecorded: <path>`. It keeps reading the recording after the
-- world gets the inventory; Find hands out world-backed Invs from then on.
local RecordedInv = strict.class("Inv", {
    fields = {
        id = function(s)
            return s.id
        end,
        config = function(s)
            return configProxy(s.h, "Inv", s.id)
        end,
        isValid = recordedField("isValid"),
        slotCount = recordedField("slotCount"),
        usedSlotCount = recordedField("usedSlotCount"),
        freeSlotCount = recordedField("freeSlotCount"),
    },
    methods = {
        GetSlot = function(s, index)
            if math.type(index) ~= "integer" then strict.fault("Inv:GetSlot(index: Integer)") end
            local path = recording.callPath(s.path, true, "GetSlot", table.pack(index), 1)
            return recordedSlot(s.h, s.h:recorded(path), path)
        end,
        GetSlots = function(s)
            local path = recording.callPath(s.path, true, "GetSlots", { n = 0 }, 1)
            local slots = s.h:recorded(path)
            if slots == nil then return nil end
            local out = {}
            for i, v in pairs(slots) do
                out[i] = recordedSlot(s.h, v, recording.indexPath(path, i))
            end
            return out
        end,
        GetTotal = function(s, key)
            if not objKey(key) then strict.fault("Inv:GetTotal expects an ObjType or an obj ID") end
            local args = table.pack(key)
            return s.h:recorded(
                recording.callPath(s.path, true, "GetTotal", args, 1, configArgPath)
            )
        end,
        GetCategoryTotal = function(s, category)
            local args = table.pack(category)
            return s.h:recorded(recording.callPath(s.path, true, "GetCategoryTotal", args, 1))
        end,
    },
})

local Inventory = strict.class("Inventory", {
    statics = {
        -- Nil when the inventory isn't loaded (undocumented; the page shows no nil case). When
        -- replaying, an inventory the world doesn't hold is what the recording says Find
        -- returned.
        Find = function(s, key)
            local id = invTypeIds[key] or (math.type(key) == "integer" and key)
            if not id then strict.fault("Inventory.Find expects an InvType or an inv ID") end
            local inv = s.h.world.state.invs[id]
            if not inv and s.h.replay then
                local path = recording.callPath(
                    "Inventory",
                    false,
                    "Find",
                    table.pack(key),
                    1,
                    configArgPath
                )
                if s.h:recorded(path) == nil then return nil end
                return RecordedInv.new({ h = s.h, id = id, path = path })
            end
            if not inv then return nil end
            local k = id .. ":" .. inv.generation
            s.h.invProxies[k] = s.h.invProxies[k]
                or Inv.new({ h = s.h, id = id, generation = inv.generation })
            return s.h.invProxies[k]
        end,
    },
})

---@param h table
---@param kind string "Inv" or "Obj"
---@return table # config.Inv or config.Obj
local function configTable(h, kind)
    return strict.lookup(function(name)
        local id = catalog.config(kind, name)
        if not id then
            strict.fault(
                string.format(
                    "unmocked API: config.%s.%s is not in docs/api/consts/%s.lua",
                    kind,
                    name,
                    kind
                )
            )
        end
        ---@cast id -? -- fault() never returns
        return configProxy(h, kind, id)
    end, {
        FromID = function(id)
            return catalog.config(kind, id) and configProxy(h, kind, id) or nil
        end,
    })
end

local Config = strict.class("_global.config", {
    fields = {
        Inv = function(s)
            return s.Inv
        end,
        Obj = function(s)
            return s.Obj
        end,
    },
})
strict.declare("_global.config", "Inv.FromID", "inline")
strict.declare("_global.config", "Obj.FromID", "inline")

---@param h table the harness
---@param env table the sandbox being built
function M.install(h, env)
    env.Inventory = Inventory.new({ h = h })
    env.config = Config.new({ Inv = configTable(h, "Inv"), Obj = configTable(h, "Obj") })
end

return M
