-- Seeing chores done from what the client shows the player: purchases at the shops in
-- data/shops.lua, banknotes collected near the givers in data/collections.lua, and products
-- collected from the machines in data/machines.lua. It reads only those shops' and machines'
-- inventories, the backpack, and the player's own tile; the pure comparisons are in
-- core/detect.lua.
--
-- main.lua subscribes the inventory events to the handlers here and hands in an `apply`
-- that changes the tracker, so this module keeps no chore state of its own: only the last
-- counts it read, to compare the next ones with.

local detectCore = require("core/detect")
local state = require("core/state")

local M = {}

-- The backpack's inventory config name.
local BACKPACK = "INV"

---@alias ChoreChange fun(tracker: ChoreState, now: integer): ChoreState

---@class ChoreDetectOptions
---@field chores Chore[]
---@field shops table<string, ChoreShop[]>
---@field collections ChoreCollection[]
---@field machines ChoreMachine[]
---@field parts table<string, ChoreParts> chore id -> its parts (core/parts.lua)
---@field say fun(...: any)
---Run `change` on the tracker at the clock's minute and keep what it returns (the same
---table means nothing changed); skipped, `change` uncalled, without a character and a
---clock.
---@field apply fun(change: ChoreChange)

---@class ChoreCollectionHit
---@field chore Chore
---@field collection ChoreCollection

local options = nil ---@type ChoreDetectOptions?
-- Shop inventory name -> the chores and shops it serves.
local shopIndex = {} ---@type table<string, ChoreShopHit[]>
-- Machine output inventory name -> the chores it serves.
local machineChores = {} ---@type table<string, Chore[]>
-- Every watched shop and machine output inventory's config (no name is both, data_spec.lua
-- checks), and the slot counts of each one the client holds now (a shop's only while it is
-- open).
local invTypes = {} ---@type table<string, InvType>
local invCounts = {} ---@type table<string, integer[]>
-- Every collection with its chore, in data order.
local collectionHits = {} ---@type ChoreCollectionHit[]
-- Every collection's note names, once each, their configs, and the backpack's count of each
-- (nil without a backpack).
local noteNames = {} ---@type string[]
local objTypes = {} ---@type table<string, ObjType>
local noteCounts = nil ---@type table<string, integer>?

-- A listed name the client's config lacks (a game update renamed it, say) is said once and
-- left unwatched, so a nil config never reaches Inventory.Find or GetTotal. The client reads
-- nil for an unknown name, without raising (docs/api-concepts.md#configs-vs-entities). The
-- casts drop config.Inv's and config.Obj's FromID member from the type.

-- Watch inventory `name` if the client's config has it; say so and return false if not.
---@param name string
---@param say fun(...: any)
---@return boolean
local function watchInv(name, say)
    local invType = config.Inv[name] --[[@as InvType?]]
    if not invType then
        say("unknown inventory", name .. "; not watched")
        return false
    end
    invTypes[name] = invType
    return true
end

---@param o ChoreDetectOptions
local function indexShops(o)
    shopIndex = {}
    -- core/detect resolves every shop's chore, watched or not.
    for name, hits in pairs(detectCore.index(o.shops, o.chores)) do
        if watchInv(name, o.say) then shopIndex[name] = hits end
    end
end

---@param o ChoreDetectOptions
local function indexMachines(o)
    machineChores = {}
    for _, machine in ipairs(o.machines) do
        local chore = state.resolve(o.chores, machine.chore, "data/machines.lua")
        for _, name in ipairs(machine.invs) do
            machineChores[name] = machineChores[name] or {}
            table.insert(machineChores[name], chore)
        end
    end
    for name in pairs(machineChores) do
        if not watchInv(name, o.say) then machineChores[name] = nil end
    end
end

---@param o ChoreDetectOptions
local function indexCollections(o)
    collectionHits, noteNames, objTypes = {}, {}, {}
    local seen = {}
    for i, collection in ipairs(o.collections) do
        local chore = state.resolve(o.chores, collection.chore, "data/collections.lua")
        collectionHits[i] = { chore = chore, collection = collection }
        for _, name in ipairs(collection.notes) do
            if not seen[name] then
                seen[name] = true
                local obj = config.Obj[name] --[[@as ObjType?]]
                if obj then
                    noteNames[#noteNames + 1], objTypes[name] = name, obj
                else
                    o.say("unknown obj", name .. "; not watched")
                end
            end
        end
    end
end

---@param o ChoreDetectOptions
function M.init(o)
    options = o
    invTypes, invCounts = {}, {}
    indexShops(o)
    indexMachines(o)
    indexCollections(o)
end

---------------------------------------------------------------------------
-- Reading the game
---------------------------------------------------------------------------

-- An inventory the client holds, or nil.
---@param invType InvType
---@return Inv?
local function findInv(invType)
    -- Find returns an Inv, per game/inventory.html#findinvtype (the stub says Inv[]).
    local inv = Inventory.Find(invType) --[[@as Inv?]]
    -- isValid, per game/inventory.html#properties (the stub says `valid`).
    ---@diagnostic disable-next-line: undefined-field
    if inv and inv.isValid then return inv end
    return nil
end

-- The slot counts of a shop or machine output inventory, or nil if the client doesn't hold it.
---@param invType InvType
---@return integer[]?
local function readCounts(invType)
    local inv = findInv(invType)
    local slots = inv and inv:GetSlots() -- "Returns nil on failure"
    if not slots then return nil end
    local counts = {}
    for i, slot in ipairs(slots) do
        counts[i] = slot.count
    end
    return counts
end

-- How many of each collection note the backpack holds, or nil without a backpack.
---@return table<string, integer>?
local function readNotes()
    local inv = findInv(config.Inv[BACKPACK] --[[@as InvType]])
    if not inv then return nil end
    local counts = {}
    for _, name in ipairs(noteNames) do
        counts[name] = inv:GetTotal(objTypes[name])
    end
    return counts
end

-- The player's own tile, or nil when logged out or loading. shell/vars.lua reads it too.
---@return ChoreTile?
function M.playerTile()
    if not Player.IsAvailable() then return nil end
    local entity = Player.GetEntity()
    local at = entity and entity.coordGrid
    if not at then return nil end
    return { x = at.x, z = at.z, level = at.level }
end

-- Take the counts of every listed shop and machine output the client holds now, and of the
-- notes in the backpack, dropping older ones. main.lua calls it on each character switch,
-- which includes the load's first sync when logged in, so a plugin reloaded with a shop open
-- still sees the next purchase, and one character's counts are never compared with
-- another's.
function M.scan()
    invCounts = {}
    for name, invType in pairs(invTypes) do
        invCounts[name] = readCounts(invType)
    end
    noteCounts = readNotes()
end

---------------------------------------------------------------------------
-- What counts as done
---------------------------------------------------------------------------

-- A purchase at shop inventory `name`: record it for each chore the shop serves (picked or
-- not, so picking one later shows the period's truth), and tick the chore if it isn't done
-- this period and enough of its shops were bought from (state.recordPart). Each chore it
-- changes is logged: a repeat purchase at a shop already bought from this period changes and
-- logs nothing, unless it now ticks the chore (unticked by hand, or its count lowered, since).
---@param name string
local function onPurchase(name)
    assert(options, "init runs before any inventory event")
    local say, parts = options.say, options.parts
    options.apply(function(tracker, now)
        for _, entry in ipairs(shopIndex[name]) do
            local own = parts[entry.chore.id]
            local recorded = state.recordPart(tracker, entry.chore, own, name, now)
            if recorded ~= tracker then say("purchase", entry.chore.id, "at", entry.shop.name) end
            tracker = recorded
        end
        return tracker
    end)
end

-- Some notes rose in the backpack: tick each collection they belong to whose giver the
-- player stands near, if its chore isn't done this period, logging only a tick.
---@param before table<string, integer>
---@param after table<string, integer>
local function onNotesRose(before, after)
    assert(options, "init runs before any inventory event")
    local say, at = options.say, M.playerTile()
    if not at then return end
    for _, hit in ipairs(collectionHits) do
        local collection = hit.collection
        if
            detectCore.rose(before, after, collection.notes)
            and detectCore.near(at, collection.tile, collection.range)
        then
            options.apply(function(tracker, now)
                local ticked = state.autoMark(tracker, hit.chore, now)
                if ticked ~= tracker then say("collected", hit.chore.id, "near", collection.npc) end
                return ticked
            end)
        end
    end
end

-- Something was collected from machine output `name`: tick each chore it serves, if it isn't
-- done this period, logging only a tick.
---@param name string
local function onCollected(name)
    assert(options, "init runs before any inventory event")
    local say = options.say
    options.apply(function(tracker, now)
        for _, chore in ipairs(machineChores[name]) do
            local ticked = state.autoMark(tracker, chore, now)
            if ticked ~= tracker then say("collected", chore.id, "from", name) end
            tracker = ticked
        end
        return tracker
    end)
end

-- The backpack changed: compare the notes with their last counts. Only a rise reads the
-- player's tile.
local function onBackpack()
    local before, after = noteCounts, readNotes()
    noteCounts = after
    if before and after and detectCore.rose(before, after, noteNames) then
        onNotesRose(before, after)
    end
end

---------------------------------------------------------------------------
-- Inventory events
---------------------------------------------------------------------------

-- Events for anything but a listed shop, a listed machine output or the backpack (the bank,
-- say) return after reading the inventory's name, so their size costs nothing here.

---@param ev InventoryAddedEventPayload
function M.onInventoryAdded(ev)
    local name = ev.inv.configName
    if invTypes[name] then
        invCounts[name] = readCounts(ev.inv)
    elseif name == BACKPACK then
        noteCounts = readNotes()
    end
end

-- In the backpack, a rise in notes may be a collection. In a listed shop, any line lower
-- than before is a purchase; in a machine output, a lower total is a collect. The new counts
-- become the baseline either way, so a restock, a sale or a machine working (counts rising)
-- only moves it.
---@param ev InventoryUpdatedEventPayload
function M.onInventoryUpdated(ev)
    local name = ev.inv.configName
    if name == BACKPACK then
        onBackpack()
        return
    end
    if not invTypes[name] then return end
    local before, after = invCounts[name], readCounts(ev.inv)
    invCounts[name] = after
    if not (before and after) then return end
    if shopIndex[name] then
        if detectCore.dropped(before, after) then onPurchase(name) end
    elseif machineChores[name] then
        if detectCore.fell(before, after) then onCollected(name) end
    end
end

---@param ev InventoryRemovedEventPayload
function M.onInventoryRemoved(ev)
    local name = ev.inv.configName
    if name == BACKPACK then
        noteCounts = nil
    elseif invTypes[name] then
        invCounts[name] = nil
    end
end

return M
