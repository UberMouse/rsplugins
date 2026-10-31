-- The chores the tracker offers, hand-written. Listed in the order the settings view shows
-- them: by period, then category (core/view.lua's CATEGORIES order), then name.
--
-- `id` is what saved picks, ticks and shop purchases are keyed by, and what the other data
-- files name, so it never changes, even when a name does (`bloodwood-tree` is Bakriminel Bolts).
-- Naming rules: Title Case in the game's spelling; the activity, not the action ("Clan
-- Citadel Cap", not "Capping Clan Citadel"); goods from one source are "<goods> from <source>",
-- from several shops "<goods> Shop Run", unless the shop's own name is the familiar one
-- (Thalmund's Wares). A name must make sense without its category, since the list and the
-- collapsed strip show only its period. Monthly chores have no category: five rows need no
-- subheadings.
--
-- The list started as a copy of dailyscape's (https://github.com/dailyscape/dailyscape.github.io,
-- dailyscape.js at commit f6a503cb3480ede1dfe1fe9d17867999939598c9), whose names, periods,
-- wiki links and descriptions it keeps in edited form, used under its MIT licence:
--
-- MIT License
--
-- Copyright (c) 2021 607ch00
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.

---@alias ChoreCategory "activities"|"combat"|"skilling"|"upkeep"|"supplies"|"shops"

---@class Chore
---@field id string fixed for good: saved state and the other data files are keyed by it
---@field name string
---@field period ChorePeriod
---@field category ChoreCategory? its settings subheading; none sits straight under the period
---@field url string
---@field desc string plain text; `<br>` is its only markup
---@field links string[]? further pages for its tooltip, after `url`

-- Both periods of each Dream of Iaia chore share one tooltip.
local IAIA_RESOURCE_DESC =
    "Turn stored resources into skilling station XP, 2 resources to 1 XP<br>How often depends on how you split your workers"
local IAIA_XP_DESC =
    "Use up the XP stored in your skilling stations<br>How often depends on how you split your workers"

---@type Chore[]
return {
    -- Daily: activities

    {
        id = "arc-contracts",
        name = "Arc Contracts",
        period = "daily",
        category = "activities",
        url = "https://runescape.wiki/w/Contract",
        desc = "Complete up to 7 contracts in the Arc for chimes and XP<br>Deplete your claimed island",
    },
    {
        id = "big-chinchompa",
        name = "Big Chinchompa",
        period = "daily",
        category = "activities",
        url = "https://runescape.wiki/w/Big_Chinchompa",
        desc = "Play the day's private hunting instance for Hunter XP",
    },
    {
        id = "daily-challenge",
        name = "Daily Challenge",
        period = "daily",
        category = "activities",
        url = "https://runescape.wiki/w/Challenge_System",
        desc = "Claim the day's challenge rewards for XP",
    },
    {
        id = "goebie-bands",
        name = "Goebie Supply Run",
        period = "daily",
        category = "activities",
        url = "https://runescape.wiki/w/Supply_run",
        desc = "Do the day's supply run in Mazcab for goebie bands",
    },
    {
        id = "menaphos-obelisk",
        name = "Menaphos Obelisk and Scarabs",
        period = "daily",
        category = "activities",
        url = "https://runescape.wiki/w/Soul_obelisk_(Menaphos)",
        desc = "Gain Menaphos reputation at the soul obelisk ('SoulObby' friends chat) and from corrupted scarabs",
        links = { "https://runescape.wiki/w/Corrupted_Scarab_(Menaphos)" },
    },
    {
        id = "nemi-forest",
        name = "Nemi Forest",
        period = "daily",
        category = "activities",
        url = "https://runescape.wiki/w/Nemi_Forest",
        desc = "The day's map is in the 'NemiForest' friends chat and on its subreddit",
        links = { "https://www.reddit.com/r/NemiForest/new/" },
    },
    {
        id = "sinkholes",
        name = "Sinkholes",
        period = "daily",
        category = "activities",
        url = "https://runescape.wiki/w/Sinkholes",
        desc = "Play two a day for Dungeoneering XP lamps and tokens",
    },

    -- Daily: skilling

    {
        id = "archaeology-research",
        name = "Archaeology Research",
        period = "daily",
        category = "skilling",
        url = "https://runescape.wiki/w/Research",
        desc = "Send out research teams with chronotes for Archaeology XP and resources",
    },
    {
        id = "book-of-char",
        name = "Book of Char",
        period = "daily",
        category = "skilling",
        url = "https://runescape.wiki/w/The_Book_of_Char",
        desc = "Drop logs on the ground and light them with the book for fast Firemaking XP",
    },
    {
        id = "divine-locations",
        name = "Divine Locations",
        period = "daily",
        category = "skilling",
        url = "https://runescape.wiki/w/Divine_location",
        desc = "Gather the day's resources from divine locations; divine yews give the best XP",
    },
    {
        id = "fixate",
        name = "Fixate Charges",
        period = "daily",
        category = "skilling",
        url = "https://runescape.wiki/w/Fixate",
        desc = "Use three fixate charges for guaranteed artefacts, e.g. at Red Rum Relics III",
        links = { "https://runescape.wiki/w/Red_Rum_Relics_III" },
    },
    {
        id = "rapid-growth",
        name = "Rapid Growth",
        period = "daily",
        category = "skilling",
        url = "https://runescape.wiki/w/Rapid_Growth",
        desc = "Cast it to make your plants grow faster, up to twice a day",
    },
    {
        id = "runesphere",
        name = "Runesphere",
        period = "daily",
        category = "skilling",
        url = "https://runescape.wiki/w/Runesphere",
        desc = "Hand in up to 1,000 rune dust for 25k XP",
    },

    -- Daily: upkeep

    {
        id = "bloodwood-tree",
        name = "Bakriminel Bolts",
        period = "daily",
        category = "upkeep",
        url = "https://runescape.wiki/w/Money_making_guide/Fletching_bakriminel_bolts",
        desc = "Fletch bakriminel bolts from your bloodwood tree, every 6 hours",
    },
    {
        id = "crystal-tree-blossom",
        name = "Crystal Tree Blossom",
        period = "daily",
        category = "upkeep",
        url = "https://runescape.wiki/w/Crystal_tree_blossom",
        desc = "Collect blossom from a crystal tree, for perfect plus potions",
    },
    {
        id = "dream-of-iaia-resource-daily",
        name = "Dream of Iaia Resources",
        period = "daily",
        category = "upkeep",
        url = "https://runescape.wiki/w/Dream_of_Iaia",
        desc = IAIA_RESOURCE_DESC,
    },
    {
        id = "herb-run",
        name = "Herb Run",
        period = "daily",
        category = "upkeep",
        url = "https://runescape.wiki/w/Money_making_guide/Farming_spirit_weed",
        desc = "Plant and harvest your herb patches",
    },
    {
        id = "invention-machine",
        name = "Invention Machines",
        period = "daily",
        category = "upkeep",
        url = "https://runescape.wiki/w/Machines",
        desc = "Fill your invention machines and collect what they made",
    },
    {
        id = "miscellania",
        name = "Miscellania",
        period = "daily",
        category = "upkeep",
        url = "https://runescape.wiki/w/Calculator:Other/Miscellania",
        desc = "Check the kingdom's approval rating and the funds in its coffer",
    },
    {
        id = "player-owned-farm",
        name = "Player-Owned Farm",
        period = "daily",
        category = "upkeep",
        url = "https://runescape.wiki/w/Player-owned_farm",
        desc = "Tend your farm's animals",
    },
    {
        id = "player-owned-ports",
        name = "Player-Owned Port",
        period = "daily",
        category = "upkeep",
        url = "https://runescape.wiki/w/Player-owned_port",
        desc = "Manage your port's voyages<br>Buy resources from the Black Marketeer",
        links = { "https://runescape.wiki/w/The_Black_Marketeer" },
    },

    -- Weekly: activities

    {
        id = "big-top-bonanza",
        name = "Big Top Bonanza",
        period = "weekly",
        category = "activities",
        url = "https://runescape.wiki/w/Balthazar_Beauregard%27s_Big_Top_Bonanza",
        desc = "Perform circus tricks for XP",
    },
    {
        id = "broken-home",
        name = "Broken Home Replay",
        period = "weekly",
        category = "activities",
        url = "https://runescape.wiki/w/Broken_Home/Quick_guide",
        desc = "Replay the quest in under 37 minutes without dying, eating at most once, for a huge XP lamp",
    },
    {
        id = "capping-clan-citadel",
        name = "Clan Citadel Cap",
        period = "weekly",
        category = "activities",
        url = "https://runescape.wiki/w/Clan_Citadel",
        desc = "Reach the week's resource cap for skill XP; it also sets the citadel's XP bonus",
    },
    {
        id = "familiarisation",
        name = "Familiarisation",
        period = "weekly",
        category = "activities",
        url = "https://runescape.wiki/w/Familiarisation",
        desc = "Rewards include a Summoning outfit",
    },
    {
        id = "herby-werby",
        name = "Herby Werby",
        period = "weekly",
        category = "activities",
        url = "https://runescape.wiki/w/Herby_Werby",
        desc = "Rewards include a herb bag and totem pieces",
    },
    {
        id = "meg",
        name = "Meg's Questions",
        period = "weekly",
        category = "activities",
        url = "https://runescape.wiki/w/Meg#Meg's_questions",
        desc = "Answer them for an XP lamp and coins",
    },
    {
        id = "penguin-hide-and-seek",
        name = "Penguin Hide and Seek",
        period = "weekly",
        category = "activities",
        url = "https://runescape.wiki/w/Penguin_Hide_and_Seek",
        desc = "Find the week's penguins for XP lamps",
        links = { "https://2016.world60pengs.com/" },
    },
    {
        id = "tears-of-guthix",
        name = "Tears of Guthix",
        period = "weekly",
        category = "activities",
        url = "https://runescape.wiki/w/Tears_of_Guthix",
        desc = "Collect tears for XP in your lowest skill",
    },
    {
        id = "wisps-of-the-grove",
        name = "Wisps of the Grove",
        period = "weekly",
        category = "activities",
        url = "https://runescape.wiki/w/Wisps_of_the_Grove",
        desc = "Farming and Hunter XP, and the Vinny pet",
    },

    -- Weekly: combat

    {
        id = "agoroth",
        name = "Agoroth",
        period = "weekly",
        category = "combat",
        url = "https://runescape.wiki/w/Agoroth",
        desc = "Defeat it twice a week; a black pearl gives a medium prismatic fallen star's bonus XP",
    },
    {
        id = "gwd2-bounties",
        name = "GWD2 Bounties",
        period = "weekly",
        category = "combat",
        url = "https://runescape.wiki/w/Feng,_the_Bounty_Master",
        desc = "Store up to 5 bounties for God Wars Dungeon 2 reputation",
    },
    {
        id = "rush-of-blood",
        name = "Rush of Blood",
        period = "weekly",
        category = "combat",
        url = "https://runescape.wiki/w/Rush_of_Blood",
        desc = "Slayer XP and titles",
    },
    {
        id = "shattered-worlds",
        name = "Shattered Worlds",
        period = "weekly",
        category = "combat",
        url = "https://runescape.wiki/w/Shattered_Worlds",
        desc = "Complete the week's challenges for extra shattered anima",
        links = { "https://runescape.wiki/w/Shattered_Worlds/Rewards" },
    },
    {
        id = "skeletal-horror",
        name = "Skeletal Horror",
        period = "weekly",
        category = "combat",
        url = "https://runescape.wiki/w/Skeletal_horror",
        desc = "Kill it for an elite or master clue scroll",
    },
    {
        id = "soul-reaper",
        name = "Soul Reaper",
        period = "weekly",
        category = "combat",
        url = "https://runescape.wiki/w/Soul_Reaper",
        desc = "Kill your assigned bosses for up to 300 points",
    },

    -- Weekly: upkeep

    {
        id = "advance-time",
        name = "Advance Time",
        period = "weekly",
        category = "upkeep",
        url = "https://runescape.wiki/w/Advance_Time",
        desc = "Use the Advance Time spell 3 times",
    },
    {
        id = "aquarium-treasure-chest",
        name = "Aquarium Treasure Chest",
        period = "weekly",
        category = "upkeep",
        url = "https://runescape.wiki/w/Treasure_chest_decoration",
        desc = "Search it for an elite or master clue scroll",
    },
    {
        id = "dream-of-iaia-resource",
        name = "Dream of Iaia Resources",
        period = "weekly",
        category = "upkeep",
        url = "https://runescape.wiki/w/Dream_of_Iaia",
        desc = IAIA_RESOURCE_DESC,
    },
    {
        id = "dream-of-iaia-xp-weekly",
        name = "Dream of Iaia XP",
        period = "weekly",
        category = "upkeep",
        url = "https://runescape.wiki/w/Dream_of_Iaia",
        desc = IAIA_XP_DESC,
    },
    {
        id = "fort-forinthry-bonus-xp",
        name = "Fort Forinthry Bonus XP",
        period = "weekly",
        category = "upkeep",
        url = "https://runescape.wiki/w/Town_Hall_(Fort_Forinthry)",
        desc = "Claim up to 15 small stars' worth of bonus XP at the Town Hall",
    },
    {
        id = "invention-machine-weekly",
        name = "Invention Machines",
        period = "weekly",
        category = "upkeep",
        url = "https://runescape.wiki/w/Machines",
        desc = "Fill your invention machines and collect what they made",
    },
    {
        id = "miscellania-weekly",
        name = "Miscellania",
        period = "weekly",
        category = "upkeep",
        url = "https://runescape.wiki/w/Calculator:Other/Miscellania",
        desc = "Check the kingdom's approval rating and the funds in its coffer",
    },
    {
        id = "water-filtration",
        name = "Water Filtration",
        period = "weekly",
        category = "upkeep",
        url = "https://runescape.wiki/w/Water_filtration_system",
        desc = "Clean out the system at Het's Oasis for troves, golden roses and more",
    },

    -- Weekly: free supplies (handed out by someone who is no shop)

    {
        id = "arc-supplies",
        name = "Arc Supplies from Rosie",
        period = "weekly",
        category = "supplies",
        url = "https://runescape.wiki/w/Rosie_(supplies)",
        desc = "Free supplies for Arc voyages from Rosie's crate",
    },
    {
        id = "geoffrey-flax",
        name = "Flax from Geoffrey",
        period = "weekly",
        category = "supplies",
        url = "https://runescape.wiki/w/Geoffrey",
        desc = "",
    },
    {
        id = "coeden-logs",
        name = "Logs from Coeden",
        period = "weekly",
        category = "supplies",
        url = "https://runescape.wiki/w/Coeden",
        desc = "",
    },
    {
        id = "dellmonti-pineapples",
        name = "Pineapples and Apples from Dell Monti",
        period = "weekly",
        category = "supplies",
        url = "https://runescape.wiki/w/Dell_Monti",
        desc = "",
    },
    {
        id = "oldman-potato-cactus",
        name = "Potato Cactus from Weird Old Man",
        period = "weekly",
        category = "supplies",
        url = "https://runescape.wiki/w/Weird_Old_Man",
        desc = "",
    },
    {
        id = "cromperty-pure-essence",
        name = "Pure Essence from Cromperty",
        period = "weekly",
        category = "supplies",
        url = "https://runescape.wiki/w/Wizard_Cromperty",
        desc = "",
    },
    {
        id = "bert-sand",
        name = "Sand from Bert",
        period = "weekly",
        category = "supplies",
        url = "https://runescape.wiki/w/Bert",
        desc = "",
    },
    {
        id = "lupe",
        name = "Soul Supplies from Lupe",
        period = "weekly",
        category = "supplies",
        url = "https://runescape.wiki/w/Lupe#Underworld_achievement_rewards",
        desc = "",
    },

    -- Weekly: shops

    {
        id = "bandit-duty-free",
        name = "Bandit Duty Free",
        period = "weekly",
        category = "shops",
        url = "https://runescape.wiki/w/Money_making_guide/Buying_construction_materials_from_Bandit_Duty_Free",
        desc = "A Wilderness shop: get skulled by Mr. Ex first. Some of its goods resell slowly",
    },
    {
        id = "broad-arrowheads",
        name = "Broad Arrowhead Shop Run",
        period = "weekly",
        category = "shops",
        url = "https://runescape.wiki/w/Money_making_guide/Buying_broad_arrowheads",
        desc = "Sold by Slayer Masters",
    },
    {
        id = "feather-shop-run",
        name = "Feather Shop Run",
        period = "weekly",
        category = "shops",
        url = "https://runescape.wiki/w/Money_making_guide/Buying_feathers",
        desc = "Buy feather packs from the fishing shops",
    },
    {
        id = "feathers-of-ma-at",
        name = "Feathers of Ma'at",
        period = "weekly",
        category = "shops",
        url = "https://runescape.wiki/w/Money_making_guide/Buying_feathers_of_Ma%27at",
        desc = "",
    },
    {
        id = "meat-packs",
        name = "Meat Packs from Chargurr",
        period = "weekly",
        category = "shops",
        url = "https://runescape.wiki/w/Money_making_guide/Buying_Meat_from_Oo%27glog",
        desc = "Buy only the packs",
    },
    {
        id = "razmire-planks",
        name = "Planks from Razmire",
        period = "weekly",
        category = "shops",
        url = "https://runescape.wiki/w/Razmire_Keelgan",
        desc = "30 noted planks; his other goods may not sell quickly",
    },
    {
        id = "rune-shop-run",
        name = "Rune Shop Run",
        period = "weekly",
        category = "shops",
        url = "https://runescape.wiki/w/Money_making_guide/Buying_runes",
        desc = "",
    },
    {
        id = "seaweed-and-pineapples",
        name = "Seaweed and Pineapples from Arhein",
        period = "weekly",
        category = "shops",
        url = "https://runescape.wiki/w/Money_making_guide/Buying_seaweed_and_pineapples_from_Arhein",
        desc = "",
    },
    {
        id = "thalmunds-wares",
        name = "Thalmund's Wares",
        period = "weekly",
        category = "shops",
        url = "https://runescape.wiki/w/Thalmund%27s_Wares",
        desc = "A merchant in the City of Um",
    },
    {
        id = "vial-of-water-packs",
        name = "Vial of Water Shop Run",
        period = "weekly",
        category = "shops",
        url = "https://runescape.wiki/w/Money_making_guide/Buying_vials_of_water",
        desc = "Buy vial of water packs; Sigmund the Merchant sells 6 more",
    },
    {
        id = "yak-hide",
        name = "Yak Hides from Vanligga",
        period = "weekly",
        category = "shops",
        url = "https://runescape.wiki/w/Money_making_guide/Buying_yak-hide",
        desc = "",
    },

    -- Monthly

    {
        id = "dream-of-iaia-xp",
        name = "Dream of Iaia XP",
        period = "monthly",
        url = "https://runescape.wiki/w/Dream_of_Iaia",
        desc = IAIA_XP_DESC,
    },
    {
        id = "effigy-incubator",
        name = "Effigy Incubator",
        period = "monthly",
        url = "https://runescape.wiki/w/Effigy_Incubator",
        desc = "Get 10 or more effigies",
    },
    {
        id = "giant-oyster",
        name = "Giant Oyster",
        period = "monthly",
        url = "https://runescape.wiki/w/Giant_Oyster",
        desc = "Fishing and Farming XP and a free Treasure Trails chest",
    },
    {
        id = "god-statues",
        name = "God Statues",
        period = "monthly",
        url = "https://runescape.wiki/w/God_Statues",
        desc = "Up to 177k Construction XP and 88k Prayer or Slayer XP",
    },
    {
        id = "troll-invasion",
        name = "Troll Invasion",
        period = "monthly",
        url = "https://runescape.wiki/w/Troll_Invasion",
        desc = "Defend all waves for an XP book of up to 77k",
    },
}
