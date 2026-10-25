-- The dev recorder's pure core: turning API values into plain data, naming reads, mapping an
-- event to the world op it stands for, and the bounded buffer of encoded entries. Nothing
-- here calls the API or keeps state; dev/recorder.lua (the shell) does both. The recording
-- format is documented in docs/testing.md ("Recordings").

local json = require("dev/json")

local recording = {}

-- The recording format's version (docs/testing.md). Bump it when an entry's shape changes.
recording.SCHEMA = 1

-- Caps on one recorded value. Recording runs inside the plugin's own calls, which the client
-- stops after 1000 ms, so a huge value (a full bank, a long HTTP body) must cost a bounded
-- amount. 10,000 nodes covers a 1000-slot inventory (3 nodes a slot) with room to spare.
recording.MAX_NODES = 10000
recording.MAX_STRING = 4096

---@param s string
---@return string
local function capString(s)
    if #s <= recording.MAX_STRING then return s end
    return s:sub(1, recording.MAX_STRING) .. string.format("<+%d bytes>", #s - recording.MAX_STRING)
end

-- An API object's tostring() text without its memory address: the client's text is like
-- `sol.jag::InventoryProxy: 0x591cbdbce258`, and Inventory.Find() and Player.GetEntity() hand
-- out a fresh object per call, so with the address every call would differ and be recorded.
-- scripts/recording-sanitise.py (strip_address) strips the same suffix; change the two together.
---@param v any
---@return string
function recording.objectText(v)
    return (tostring(v):gsub(": 0x%x+$", ""))
end

-- How a value that isn't plain data is written: a config (anything with a configName) as
-- { config = name, id = n, type = typeName }, anything else as its objectText(). Reading a
-- member a value doesn't have may raise (client userdata), hence the pcall.
---@param v any
---@return any
function recording.objectData(v)
    local ok, form = pcall(function()
        if type(v.configName) ~= "string" then return nil end
        return { config = v.configName, id = v.id, type = v.typeName }
    end)
    if ok and form then return form end
    return recording.objectText(v)
end

-- A copy of `value` that JSON can hold. Plain tables are copied (a table met again inside
-- itself becomes "<cycle>"); strings are capped at MAX_STRING bytes; the first value past
-- MAX_NODES becomes "<truncated>" and the rest are left out. Anything else (an API object, a
-- table with a metatable, a function) is passed to `objectForm`, which the shell supplies
-- because only it knows which class an API object is.
---@param value any
---@param objectForm fun(v: any): any
---@return any
function recording.serialise(value, objectForm)
    local nodes, open = 0, {}
    local function walk(v)
        nodes = nodes + 1
        if nodes > recording.MAX_NODES then return "<truncated>" end
        local kind = type(v)
        if kind == "nil" or kind == "boolean" or kind == "number" then return v end
        if kind == "string" then return capString(v) end
        if kind ~= "table" or getmetatable(v) ~= nil then return objectForm(v) end
        if open[v] then return "<cycle>" end
        open[v] = true
        local out = {}
        for k, x in pairs(v) do
            local key = (type(k) == "string" or math.type(k) == "integer") and k or tostring(k)
            out[key] = walk(x)
            if nodes > recording.MAX_NODES then break end
        end
        open[v] = nil
        return out
    end
    return walk(value)
end

-- Read paths. A replay looks reads up by these strings, so the test harness builds its keys
-- with these same functions.

-- A config, named the same however the plugin reached it, e.g. `config.Inv.INV` or
-- `var.VarPlayer.QP`. Raises if a part is nil.
---@param root string "config" or "var"
---@param typeName any
---@param configName any
---@return string
function recording.configPath(root, typeName, configName)
    return root .. "." .. typeName .. "." .. configName
end

-- A member read off the object at `base`, e.g. `Player.GetEntity().displayName`.
---@param base string
---@param key any
---@return string
function recording.memberPath(base, key)
    return base .. "." .. tostring(key)
end

-- One element of the list at `base`, e.g. `Inventory.Find(config.Inv.INV):GetSlots()[1]`.
---@param base string
---@param i any
---@return string
function recording.indexPath(base, i)
    return base .. "[" .. tostring(i) .. "]"
end

-- An argument as it appears in a read's path: a stand-in by its own path, a string quoted,
-- a number or boolean as written, anything else by its type.
---@param v any
---@param pathOf (fun(v: any): string?)?
---@return string
local function argText(v, pathOf)
    local path = pathOf and pathOf(v)
    if path then return path end
    local kind = type(v)
    if kind == "string" then return string.format("%q", v) end
    if kind == "nil" or kind == "boolean" or kind == "number" then return tostring(v) end
    return "<" .. kind .. ">"
end

-- The path naming a call's result, e.g. `Inventory.Find(config.Inv.INV):GetSlots()`. `args`
-- is a table.pack() of the call's arguments; `first` skips `self` for a method call.
---@param base string the path of the object called on
---@param isMethod boolean called with ':'
---@param name string
---@param args table
---@param first integer
---@param pathOf (fun(v: any): string?)? an argument's own path, if it is a stand-in
---@return string
function recording.callPath(base, isMethod, name, args, first, pathOf)
    local parts = {}
    for i = first, args.n do
        parts[#parts + 1] = argText(args[i], pathOf)
    end
    return base .. (isMethod and ":" or ".") .. name .. "(" .. table.concat(parts, ", ") .. ")"
end

-- The harness world op (tests/harness/world.lua) an event stands for, so a replay can apply
-- it, or nil if the event isn't a world change the harness models. `p` is the serialised
-- payload; `contents` is the inventory's contents ({ size, slots }) read when an
-- InventoryAdded/Updated arrived, since the payload only names the changed slots.
---@param name string
---@param p table?
---@param contents table?
---@return table?
function recording.eventOp(name, p, contents)
    if type(p) ~= "table" then return nil end
    local var, inv = p.var, p.inv
    if name == "VarTransmit" and type(var) == "table" then
        return {
            op = "setVar",
            domain = var.type,
            name = var.config,
            id = var.id,
            value = p.newValue,
        }
    end
    if (name == "InventoryAdded" or name == "InventoryUpdated") and type(inv) == "table" then
        if not contents then return nil end
        return { op = "setInventory", inv = inv.id, size = contents.size, slots = contents.slots }
    end
    if name == "InventoryRemoved" and type(inv) == "table" then
        return { op = "removeInventory", inv = inv.id }
    end
    if name == "OptionalPermissionChanged" then
        return { op = "setPermission", permission = p.permissionName, enabled = p.enabled }
    end
    if name == "ChatMessage" then
        return {
            op = "chat",
            message = p.chatMessage,
            chatType = p.chatType,
            sender = p.senderNameUnfiltered,
        }
    end
    return nil
end

---------------------------------------------------------------------------
-- The entry buffer: encoded entries waiting to be sent, oldest first
---------------------------------------------------------------------------

-- Entries sit at buffer[first..last]. An entry keeps its index until it leaves, and leaving
-- is always from the front, so everything below `first` has been taken or dropped.
---@return table
function recording.newBuffer()
    return { first = 1, last = 0, bytes = 0 }
end

---@param buffer table
---@return integer
function recording.count(buffer)
    return buffer.last - buffer.first + 1
end

-- Add an encoded entry, then drop the oldest ones until the buffer holds at most `maxBytes`
-- (always keeping the newest). Returns how many were dropped.
---@param buffer table
---@param entry string
---@param maxBytes integer
---@return integer
function recording.push(buffer, entry, maxBytes)
    buffer.last = buffer.last + 1
    buffer[buffer.last] = entry
    buffer.bytes = buffer.bytes + #entry
    local dropped = 0
    while buffer.bytes > maxBytes and buffer.first < buffer.last do
        buffer.bytes = buffer.bytes - #buffer[buffer.first]
        buffer[buffer.first] = nil
        buffer.first = buffer.first + 1
        dropped = dropped + 1
    end
    return dropped
end

-- Remove and return the oldest entries, up to `maxBytes` in all (at least one, however big).
---@param buffer table
---@param maxBytes integer
---@return string[]
function recording.take(buffer, maxBytes)
    local out, bytes = {}, 0
    while buffer.first <= buffer.last do
        local entry = buffer[buffer.first]
        if #out > 0 and bytes + #entry > maxBytes then break end
        out[#out + 1] = entry
        bytes = bytes + #entry
        buffer[buffer.first] = nil
        buffer.first = buffer.first + 1
        buffer.bytes = buffer.bytes - #entry
    end
    return out
end

-- A batch's POST body: `meta` (schema, plugin, session...) plus the already-encoded entries,
-- spliced in as "<key>": [...] (key "entries" unless given) so they aren't encoded twice.
---@param meta table
---@param entries string[]
---@param key string?
---@return string
function recording.batchBody(meta, entries, key)
    local head = json.encode(meta) -- "{...}"; meta is never empty, so it's an object
    return head:sub(1, -2)
        .. ',"'
        .. (key or "entries")
        .. '":['
        .. table.concat(entries, ",")
        .. "]}"
end

return recording
