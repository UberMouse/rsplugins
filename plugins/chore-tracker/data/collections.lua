-- Chores done by collecting from someone who is no shop, hand-written. The goods arrive as
-- banknotes with no shop open, so shell/detect.lua ticks one when its notes rise near `tile`
-- (core/shops.lua, near). Tiles are the wiki's NPC map pins. `proven` marks notes seen
-- arriving in the beta client (docs/api-concepts.md, "Shops in the client"); an unproven
-- one's note name is from docs/api/consts/Obj.lua.

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
        -- runescape.wiki/w/Dell_Monti; !tele 0,43,49,11,50.
        chore = "dellmonti-pineapples",
        npc = "Dell Monti",
        notes = { "CERT_COOKING_APPLE", "CERT_PINEAPPLE" },
        tile = { x = 2763, z = 3186, level = 0 },
        range = 10,
        proven = true,
    },
    {
        -- Outside the Kalphite Lair: runescape.wiki/w/Weird_Old_Man; !tele 0,50,48,32,36.
        chore = "oldman-potato-cactus",
        npc = "the Weird Old Man",
        notes = { "CERT_CACTUS_POTATO" },
        tile = { x = 3232, z = 3108, level = 0 },
        range = 10,
        proven = false,
    },
}
