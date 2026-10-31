-- Chores done by collecting banknotes from someone who is no shop, hand-written: the player
-- collects `notes` standing near `tile` (core/detect.lua says how that is seen). Tiles are the
-- wiki's NPC map pins. `proven` marks notes seen arriving in the client; an unproven one's
-- note name is taken from the client's item names (id.Obj).

---@class ChoreTile
---@field x integer world tile x
---@field z integer world tile z
---@field level integer the plane, 0-3

---@class ChoreCollection
---@field chore string the chore id
---@field npc string who the player collects from, for the log
---@field notes string[] the banknotes' obj config names
---@field tile ChoreTile where they stand
---@field range integer
---@field proven boolean

---@type ChoreCollection[]
return {
    {
        -- runescape.wiki/w/Dell_Monti
        chore = "dellmonti-pineapples",
        npc = "Dell Monti",
        notes = { "CERT_COOKING_APPLE", "CERT_PINEAPPLE" },
        tile = { x = 2763, z = 3186, level = 0 },
        range = 10,
        proven = true,
    },
    {
        -- Outside the Kalphite Lair: runescape.wiki/w/Weird_Old_Man
        chore = "oldman-potato-cactus",
        npc = "the Weird Old Man",
        notes = { "CERT_CACTUS_POTATO" },
        tile = { x = 3232, z = 3108, level = 0 },
        range = 10,
        proven = false,
    },
}
