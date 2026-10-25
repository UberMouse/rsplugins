-- Chores done by collecting from someone who is no shop, hand-written. Their goods arrive
-- as banknotes in the backpack with no shop open, so a chore ticks when any of its notes
-- rise in the backpack while the player is within `range` tiles of `tile` (the same plane,
-- and at most `range` tiles off on each axis). See shell/detect.lua.
--
-- Tiles are the wiki's NPC map pins, as world tiles. `proven` marks a collection whose notes
-- were seen arriving in the beta client (docs/api-concepts.md, "Shops in the client"); the
-- unproven one's note is taken from the client's obj list (docs/api/consts/Obj.lua).

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
