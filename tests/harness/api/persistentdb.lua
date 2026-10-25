-- PersistentDB, in memory. The store lives on the harness (h.db), not the plugin instance, so
-- it survives reload() like the client's on-disk store survives `prl`.
--
-- Behaviour from https://developer.runescape.com/rs/core/persistentdb.html: Get returns nil for
-- a missing key; the typed getters also return nil on a type mismatch; Set returns a Bool;
-- table fields of types other than Bool/Int/Float/String/Table are ignored; IterateEntries
-- stops when the callback returns true and returns how many entries it visited.

local strict = require("tests.harness.strict")

local M = {}

-- The official page gives these values (0-4); the stub has them as strings.
M.PersistentDBType = { BOOL = 0, INT = 1, FLOAT = 2, STRING = 3, STRUCTURED_DATA = 4 }
local T = M.PersistentDBType

-- The PersistentDBType a Lua value would be stored as, or nil if it can't be stored.
---@param value any
---@return integer?
local function typeOf(value)
    local t = type(value)
    if t == "boolean" then return T.BOOL end
    if t == "string" then return T.STRING end
    if t == "table" then return T.STRUCTURED_DATA end
    if math.type(value) == "integer" then return T.INT end
    if math.type(value) == "float" then return T.FLOAT end
    return nil
end

-- A deep copy keeping only storable keys and values, so the store never shares a table with
-- the plugin.
---@param value table
---@param seen table?
---@return table
local function copyData(value, seen)
    seen = seen or {}
    if seen[value] then strict.fault("PersistentDB: cannot store a table that contains itself") end
    seen[value] = true
    local out = {}
    for k, v in pairs(value) do
        local kt = type(k)
        if (kt == "string" or kt == "number") and typeOf(v) then
            out[k] = type(v) == "table" and copyData(v, seen) or v
        end
    end
    seen[value] = nil
    return out
end

---@param entry table?
---@return any
local function valueOf(entry)
    if not entry then return nil end
    if entry.type == T.STRUCTURED_DATA then return copyData(entry.value) end
    return entry.value
end

---@param key any
local function checkKey(key)
    if type(key) ~= "string" then strict.fault("PersistentDB key must be a string") end
end

---@param s table
---@param key string
---@param value any
---@param want integer? the type a typed setter requires
---@return boolean?
local function set(s, key, value, want)
    checkKey(key)
    local t = typeOf(value)
    if not t then strict.fault("PersistentDB cannot store a " .. type(value)) end
    -- A whole number is a valid Float; store it as one.
    if want == T.FLOAT and t == T.INT then
        value, t = value + 0.0, T.FLOAT
    end
    if want and t ~= want then return nil end
    s.db[key] = { type = t, value = t == T.STRUCTURED_DATA and copyData(value) or value }
    return true
end

---@param s table
---@param key string
---@param want integer
---@return any
local function getTyped(s, key, want)
    checkKey(key)
    local entry = s.db[key]
    if entry and entry.type == want then return valueOf(entry) end
    return nil
end

local methods = {
    Get = function(s, key)
        checkKey(key)
        return valueOf(s.db[key])
    end,
    Set = function(s, key, value)
        return set(s, key, value)
    end,
    CheckExists = function(s, key)
        checkKey(key)
        return s.db[key] ~= nil
    end,
    CheckExistsTyped = function(s, key, wantType)
        checkKey(key)
        local entry = s.db[key]
        return entry ~= nil and entry.type == wantType
    end,
    IterateEntries = function(s, callback)
        -- Sorted so tests are deterministic; the client's order is unknown.
        local keys = {}
        for k in pairs(s.db) do
            keys[#keys + 1] = k
        end
        table.sort(keys)
        local visited = 0
        for _, k in ipairs(keys) do
            visited = visited + 1
            if callback(k, valueOf(s.db[k])) == true then break end
        end
        return visited
    end,
    Delete = function(s, key)
        checkKey(key)
        s.db[key] = nil
        return true
    end,
    Clear = function(s)
        for k in pairs(s.db) do
            s.db[k] = nil
        end
        return true
    end,
}
-- The typed getters' and setters' suffixes (GetInt, SetInt...).
local TYPED = {
    Bool = T.BOOL,
    Int = T.INT,
    Float = T.FLOAT,
    String = T.STRING,
    StructuredData = T.STRUCTURED_DATA,
}
for suffix, t in pairs(TYPED) do
    methods["Get" .. suffix] = function(s, key)
        return getTyped(s, key, t)
    end
    methods["Set" .. suffix] = function(s, key, value)
        return set(s, key, value, t)
    end
end

local PersistentDB = strict.class("PersistentDB", { methods = methods })

-- Store what a recorded Get found under `key` (a replay's starting state). `getter` is the
-- method that found it ("Get", "GetInt"...), which gives the stored type; for a plain Get it
-- is the value's own type, so a Float that JSON wrote as a whole number comes back an Int.
---@param db table h.db
---@param key string
---@param getter string
---@param value any
function M.seed(db, key, getter, value)
    set({ db = db }, key, value, TYPED[getter:sub(4)])
end

---@param h table the harness
---@param env table the sandbox being built
function M.install(h, env)
    env.PersistentDB = PersistentDB.new({ db = h.db })
    env.PersistentDBType = strict.enum("PersistentDBType", M.PersistentDBType)
end

return M
