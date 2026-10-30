-- Seeing chores done from what the client shows the player: purchases at the shops in
-- data/shops.lua, and banknotes collected near the givers in data/collections.lua. It reads
-- only those shops' inventories, the backpack, and the player's own tile; the pure
-- comparisons are in core/detect.lua.
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
---@field say fun(...: any)
---Run `change` on the tracker at the clock's minute and keep what it returns (the same
---table means nothing changed); skipped, `change` uncalled, without a character and a
---clock.
---@field apply fun(change: ChoreChange)

---@class ChoreShopHit a core/detect ChoreShopEntry with its chore resolved
---@field chore Chore
---@field shop ChoreShop

---@class ChoreCollectionHit
---@field chore Chore
---@field collection ChoreCollection

local options = nil ---@type ChoreDetectOptions?
-- Shop inventory name -> the chores and shops it serves, and its config.
local shopIndex = {} ---@type table<string, ChoreShopHit[]>
local invTypes = {} ---@type table<string, InvType>
-- Every collection's note names, once each, and their configs.
local noteNames = {} ---@type string[]
-- Every collection with its chore, in data order.
local collectionHits = {} ---@type ChoreCollectionHit[]
local objTypes = {} ---@type table<string, ObjType>
-- The slot counts of each listed shop inventory the client holds now (one is held only
-- while its shop is open), and the backpack's count of each note, nil without a backpack.
local shopCounts = {} ---@type table<string, integer[]>
local noteCounts = nil ---@type table<string, integer>?

---@param o ChoreDetectOptions
function M.init(o)
    options = o
    collectionHits = {}
    for i, collection in ipairs(o.collections) do
        collectionHits[i] =
            { chore = state.resolve(o.chores, collection.chore, "data"), collection = collection }
    end
    -- A listed name the client's config lacks (a game update renamed it, say) is said once
    -- and left unwatched, so a nil config never reaches Inventory.Find or GetTotal. The
    -- casts drop config.Inv's and config.Obj's FromID member from the type. The client
    -- reads nil for an unknown name, without raising (docs/api-concepts.md#configs-vs-entities).
    shopIndex, invTypes = {}, {}
    -- Chore ids resolve for every shop, watched or not.
    for name, indexed in pairs(detectCore.index(o.shops)) do
        local entries = {} ---@type ChoreShopHit[]
        for i, entry in ipairs(indexed) do
            entries[i] = { chore = state.resolve(o.chores, entry.chore, "data"), shop = entry.shop }
        end
        local invType = config.Inv[name] --[[@as InvType?]]
        if invType then
            shopIndex[name], invTypes[name] = entries, invType
        else
            o.say("unknown inventory", name .. "; not watched")
        end
    end
    noteNames, objTypes = {}, {}
    local seen = {}
    for _, collection in ipairs(o.collections) do
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

-- The slot counts of a shop inventory, or nil if the client doesn't hold it.
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

-- The player's own tile, or nil when logged out or loading.
---@return ChoreTile?
local function playerTile()
    if not Player.IsAvailable() then return nil end
    local entity = Player.GetEntity()
    local at = entity and entity.coordGrid
    if not at then return nil end
    return { x = at.x, z = at.z, level = at.level }
end

-- Take the counts of every listed shop the client holds now, and of the notes in the
-- backpack, dropping older ones. main.lua calls it on each character switch, which
-- includes the load's first sync when logged in, so a plugin reloaded with a shop open
-- still sees the next purchase, and one character's counts are never compared with
-- another's.
function M.scan()
    shopCounts = {}
    for name, invType in pairs(invTypes) do
        shopCounts[name] = readCounts(invType)
    end
    noteCounts = readNotes()
end

---------------------------------------------------------------------------
-- What counts as done
---------------------------------------------------------------------------

-- A purchase at shop inventory `name`: record it for each chore the shop serves (picked or
-- not, so picking one later shows the period's truth), and tick the chore if it isn't done
-- this period. Each chore it changes is logged: a repeat purchase at a shop already bought
-- from this period changes and logs nothing, unless the chore was unticked by hand since.
---@param name string
local function onPurchase(name)
    assert(options, "init runs before any inventory event")
    local say = options.say
    options.apply(function(tracker, now)
        for _, entry in ipairs(shopIndex[name]) do
            local recorded = state.recordPurchase(tracker, entry.chore, name, now)
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
    local say, at = options.say, playerTile()
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

-- Events for anything but a listed shop or the backpack (the bank, say) return after
-- reading the inventory's name, so their size costs nothing here.

---@param ev InventoryAddedEventPayload
function M.onInventoryAdded(ev)
    local name = ev.inv.configName
    if shopIndex[name] then
        shopCounts[name] = readCounts(ev.inv)
    elseif name == BACKPACK then
        noteCounts = readNotes()
    end
end

-- In the backpack, a rise in notes may be a collection. In a listed shop, any line lower
-- than before is a purchase; the new counts become the baseline either way, so a restock or
-- a sale (counts rising) only moves it.
---@param ev InventoryUpdatedEventPayload
function M.onInventoryUpdated(ev)
    local name = ev.inv.configName
    if name == BACKPACK then
        onBackpack()
        return
    end
    if not shopIndex[name] then return end
    local before, after = shopCounts[name], readCounts(ev.inv)
    shopCounts[name] = after
    if before and after and detectCore.dropped(before, after) then onPurchase(name) end
end

---@param ev InventoryRemovedEventPayload
function M.onInventoryRemoved(ev)
    local name = ev.inv.configName
    if name == BACKPACK then
        noteCounts = nil
    elseif shopIndex[name] then
        shopCounts[name] = nil
    end
end

return M
