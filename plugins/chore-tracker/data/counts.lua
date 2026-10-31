-- The chores done at several parts that aren't shops (core/parts.lua), hand-written: the word
-- for their parts in a row's tooltip, and how many of them tick the chore until the player
-- sets a count in settings. The defaults are the user's (2026-10-31): most players do only
-- some of each, so all of them would leave the chore unticked. Thalmund's Wares and Shattered
-- Worlds have none, so they need every slot and challenge, as before they had counts.
--
-- The maximums are the parts' own numbers: 11 herb patches, 8 bloodwood trees, 7 farm troughs
-- (6 pens and the breeding pen), 12 penguins and the polar bear (runescape.wiki/w/
-- Penguin_Hide_and_Seek), 4 voyage slots, 6 Invention Guild machines, 4 shop slots and 3
-- challenges.

---@type table<string, ChoreCount>
return {
    ["herb-run"] = { noun = "Patches", default = 8 },
    ["bloodwood-tree"] = { noun = "Trees", default = 1 },
    ["player-owned-farm"] = { noun = "Troughs", default = 1 },
    ["penguin-hide-and-seek"] = { noun = "Penguins", default = 10 },
    ["player-owned-ports"] = { noun = "Voyages", default = 1 },
    ["invention-machine"] = { noun = "Machines", default = 2 },
    ["invention-machine-weekly"] = { noun = "Machines", default = 2 },
    ["thalmunds-wares"] = { noun = "Slots" },
    ["shattered-worlds"] = { noun = "Challenges" },
}
