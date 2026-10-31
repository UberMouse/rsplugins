-- The chores done at several parts that aren't shops (core/parts.lua), hand-written: the word
-- for their parts in a row's tooltip, how many of them tick the chore until the player sets a
-- count in settings, and the settings line's tooltip, saying what the count counts (the period
-- is added to it). The defaults are the user's (2026-10-31): most players do only some of
-- each, so all of them would leave the chore unticked. Thalmund's Wares and Shattered Worlds
-- have none, so they need every slot and challenge, as before they had counts. A `fixed` count
-- has no settings line: the Player-Owned Port needs all four voyages (the user's call).
--
-- The maximums are the parts' own numbers: 11 herb patches, 8 bloodwood trees, 7 farm troughs
-- (6 pens and the breeding pen), 12 penguins and the polar bear (runescape.wiki/w/
-- Penguin_Hide_and_Seek), 4 voyage slots, 4 shop slots and 3 challenges.

---@type table<string, ChoreCount>
return {
    ["herb-run"] = { noun = "Patches", default = 8, help = "How many herb patches you plant" },
    ["bloodwood-tree"] = {
        noun = "Trees",
        default = 1,
        help = "How many bloodwood trees you fell for bolts",
    },
    ["player-owned-farm"] = {
        noun = "Troughs",
        default = 1,
        help = "How many pens you feed, the breeding pen included",
    },
    ["penguin-hide-and-seek"] = {
        noun = "Penguins",
        default = 10,
        help = "How many penguins you spot; the polar bear counts as one",
    },
    ["player-owned-ports"] = { noun = "Voyages", default = 4, fixed = true },
    ["thalmunds-wares"] = { noun = "Slots", help = "How many of Thalmund's slots you buy out" },
    ["shattered-worlds"] = {
        noun = "Challenges",
        help = "How many of the reward challenges you complete",
    },
}
