-- Chores seen done from the player's own game vars, hand-written. Each entry is a chore id
-- and its done rule over named VarPlayer vars (the rule language is in core/vars.lua); the
-- names, base vars and bits are in docs/vars/vars.csv. shell/vars.lua ticks a chore when a
-- watched var changes and its rule goes from false to true (or, for a rule naming a `rises`
-- var, that var goes up; for one naming `falls` vars, the rule turns true as one of them
-- goes down), never on a var's first read.
--
-- `proven` marks a rule checked in the beta client: its vars seen moving as the chore was done
-- (recorded in docs/api-concepts.md), or the rule seen ticking its chore when its vars were set
-- with the !setvar cheat; the comments say which. An unproven one ticks the same way. The four free collections keep
-- their weekly period (data/chores.lua), so a claim ticks one until Wednesday's reset,
-- although the game's flag is daily.

-- Dream of Iaia. Each of the six base-camp resources has workers on it
-- (DINO_BASE_CAMP_WORKER_ASSIGNED_<R>), a stock (DINO_BASE_CAMP_RESOURCE_<R>) and, once
-- converted, XP stored at a skilling station (QUEST_EGW_FINALE_REWARD_STATION_XP_<SKILL>);
-- the stations are from runescape.wiki/w/Dream_of_Iaia.
local IAIA = {
    { "WOOD", "FLETCHING" },
    { "VINES", "HUNTER" },
    { "LEAVES", "HERBLORE" },
    { "PELTS", "CRAFTING" }, -- the wiki's "hides"
    { "STONE", "CONSTRUCTION" },
    { "CLAY", "FISHING" },
}

-- Done when every resource with workers on it is at 0 (its stock, or its station's XP); ticks
-- only when one of those went down, so moving workers away never ticks. The `> 0` group stops a
-- player with no workers reading as done. Each rule serves two periods because the worker
-- split sets how often it is due.
---@param prefix string
---@param field integer 1 to key each stock var by resource, 2 by station skill
---@return ChoreVarCondition[] done
---@return string[] falls
local function iaiaRule(prefix, field)
    local workers = {}
    local done = { { any = workers } }
    local falls = {}
    for _, pair in ipairs(IAIA) do
        local worker = "DINO_BASE_CAMP_WORKER_ASSIGNED_" .. pair[1]
        local stock = prefix .. pair[field]
        workers[#workers + 1] = { worker, ">", 0 }
        done[#done + 1] = { any = { { worker, "==", 0 }, { stock, "==", 0 } } }
        falls[#falls + 1] = stock
    end
    return done, falls
end

local resourceDone, resourceFalls = iaiaRule("DINO_BASE_CAMP_RESOURCE_", 1)
local xpDone, xpFalls = iaiaRule("QUEST_EGW_FINALE_REWARD_STATION_XP_", 2)

---@type ChoreVarRule[]
local rules = {
    -- Bit 1 of HANDSAND_BUCKETS: 0 -> 1 on the claim, still 1 after a relog.
    {
        chore = "bert-sand",
        done = { { "HANDSAND_BUCKETS_CLAIMED_TODAY", "==", 1 } },
        proven = true,
    },
    -- Bit 30 of ATSEER_TASK4.
    {
        chore = "geoffrey-flax",
        done = { { "ATSEER_REWARD_FLAX_GIVEN_TODAY", "==", 1 } },
        proven = true,
    },
    -- Bit 22 of ATAR_TASKS_4.
    { chore = "cromperty-pure-essence", done = { { "ATAR_ESS_USED", "==", 1 } }, proven = true },
    -- Bit 14 of ATELF_MAIN4.
    { chore = "coeden-logs", done = { { "ATELF_DAILY_LOGS_CLAIMED", "==", 1 } }, proven = true },
    -- Bits 0-13 of CHALLENGE_BI_1, which went 0 -> 2 -> 3 as three challenge rewards were
    -- claimed in the challenge window. Whether it resets daily or counts for life is
    -- unknown; either way a claim raises it, so any rise ticks the chore and it needs no
    -- conditions. INTERN_NOTES_DAILY_CHALLENGES_COMPLETE isn't used: it counts finished
    -- challenges not yet claimed, and falls on the claim.
    {
        chore = "daily-challenge",
        done = {},
        rises = "CHALLENGE_TOTAL_COMPLETED",
        proven = true,
    },
    -- Every charge of the week used. It read 3 at login; a cast wasn't checked.
    {
        chore = "advance-time",
        done = { { "MAGIC_ADVANCE_TIME_CHARGES_REMAINING", "==", 0 } },
        proven = false,
    },
    -- The day's gathering limit reached. The limit read 20 at login; not checked further.
    {
        chore = "divine-locations",
        done = {
            { "DIV_GATHER_LIMIT", ">", 0 },
            { "DIV_GATHERED", ">=", "DIV_GATHER_LIMIT" },
        },
        proven = false,
    },
    -- Dream of Iaia: checked in the beta client and validated against the chore on 2026-10-31;
    -- values and station mapping in docs/api-concepts.md.
    {
        chore = "dream-of-iaia-resource-daily",
        done = resourceDone,
        falls = resourceFalls,
        proven = true,
    },
    { chore = "dream-of-iaia-resource", done = resourceDone, falls = resourceFalls, proven = true },
    { chore = "dream-of-iaia-xp-weekly", done = xpDone, falls = xpFalls, proven = true },
    { chore = "dream-of-iaia-xp", done = xpDone, falls = xpFalls, proven = true },

    -- Seen moving as the user did each chore (chore probe, 2026-10-30, docs/api-concepts.md),
    -- and each ticked its chore in the client when set with !setvar (2026-10-31).
    -- Bits 0-1 of ARCH_RESEARCH_CONTRACT_1_1: 0 idle, 1 team out, 2 back to claim. Only
    -- sending a team moves it into 1.
    {
        chore = "archaeology-research",
        done = { { "ARCH_RESEARCH_CONTRACT_1_STATE", "==", 1 } },
        proven = true,
    },
    -- The epoch minute of the last resource collect; it rose to the collect's minute.
    { chore = "miscellania", done = {}, rises = "MISC_LAST_COLLECTION", proven = true },
    { chore = "miscellania-weekly", done = {}, rises = "MISC_LAST_COLLECTION", proven = true },

    -- The rules below are inferred from each var's name, unproven.

    -- The date blossoms were last taken (bits 5-20 of ELFCITY_PERM36), read as a RuneDay:
    -- its unit is assumed from the name, not checked.
    {
        chore = "crystal-tree-blossom",
        done = { { "ELFCITY_CRYSTAL_BLOSSOMS_LAST_DATE", "==", { runeDay = true } } },
        proven = false,
    },
    -- Games played today. The chore list counts two a day as the chore.
    {
        chore = "sinkholes",
        done = { { "RAND_DND_DAILY_GAMES", ">=", 2 } },
        proven = false,
    },
    {
        chore = "big-chinchompa",
        done = { { "DNDTRACKER_BIGCHINCHOMPA_GAME_PLAYED", "==", 1 } },
        proven = false,
    },
    -- Fixate charges used today. The chore list counts three a day as the chore.
    {
        chore = "fixate",
        done = { { "ARCH_EXCAVATION_FIXATE_DAILY", ">=", 3 } },
        proven = false,
    },
    {
        chore = "runesphere",
        done = { { "RCSIPHONXP_DAILY_DUST_HAND_IN", "==", 1 } },
        proven = false,
    },
    {
        chore = "soul-reaper",
        done = { { "BSLAY_REACHED_WEEKLY_CAP", "==", 1 } },
        proven = false,
    },
    -- Every one of Thalmund's four slots bought up to its limit. A slot's limit must be
    -- above 0: one with no limit would otherwise read 0 >= 0 as bought out.
    {
        chore = "thalmunds-wares",
        done = {
            { "NECRO_HUB_THALMUND_SLOT_1_MAX", ">", 0 },
            { "NECRO_HUB_THALMUND_SLOT_1_BOUGHT", ">=", "NECRO_HUB_THALMUND_SLOT_1_MAX" },
            { "NECRO_HUB_THALMUND_SLOT_2_MAX", ">", 0 },
            { "NECRO_HUB_THALMUND_SLOT_2_BOUGHT", ">=", "NECRO_HUB_THALMUND_SLOT_2_MAX" },
            { "NECRO_HUB_THALMUND_SLOT_3_MAX", ">", 0 },
            { "NECRO_HUB_THALMUND_SLOT_3_BOUGHT", ">=", "NECRO_HUB_THALMUND_SLOT_3_MAX" },
            { "NECRO_HUB_THALMUND_SLOT_4_MAX", ">", 0 },
            { "NECRO_HUB_THALMUND_SLOT_4_BOUGHT", ">=", "NECRO_HUB_THALMUND_SLOT_4_MAX" },
        },
        proven = false,
    },
    -- Its base var, SHOP_MULTIPURPOSE, wasn't sent during an Arhein purchase
    -- (docs/api-concepts.md), so this may never fire.
    { chore = "tears-of-guthix", done = { { "TOG_TEARS_COMPLETE", "==", 1 } }, proven = false },
    {
        chore = "herby-werby",
        done = { { "DINO_HERBLORE_DND_COMPLETED", "==", 1 } },
        proven = false,
    },
    {
        chore = "wisps-of-the-grove",
        done = { { "NATURE_BEINGS_DND_COMPLETED", "==", 1 } },
        proven = false,
    },
    -- All three of the week's reward challenges.
    {
        chore = "shattered-worlds",
        done = {
            { "SWORLDS_REWARD_CHALLENGE_BRONZE_COMPLETE", "==", 1 },
            { "SWORLDS_REWARD_CHALLENGE_SILVER_COMPLETE", "==", 1 },
            { "SWORLDS_REWARD_CHALLENGE_GOLD_COMPLETE", "==", 1 },
        },
        proven = false,
    },
    {
        chore = "aquarium-treasure-chest",
        done = { { "POH_AQUA_TREASURE_CHEST_USED", "==", 1 } },
        proven = false,
    },
    -- Defeats this week. The chore list counts two a week as the chore, so a week with one
    -- defeat is left to tick by hand rather than ticked half done.
    { chore = "agoroth", done = { { "ASH1_REPLAY_DEFEATED", ">=", 2 } }, proven = false },
    { chore = "broken-home", done = { { "HOUSE_DND_REPLAY_COMPLETED", "==", 1 } }, proven = false },
    {
        chore = "lupe",
        done = { { "ATUM_REWARD_LUPE_DAILY_SUPPLIES_CLAIMED", "==", 1 } },
        proven = false,
    },
    {
        chore = "effigy-incubator",
        done = { { "KERAPAC_DND_MONTHLY_COMPLETE", "==", 1 } },
        proven = false,
    },
    -- The rules below each ticked their chore in the client when their vars were set with
    -- !setvar (2026-10-31), so each var reaches the client and the rule fires. What each var
    -- means follows its name and the wiki's account of the activity (runescape.wiki, read
    -- 2026-10-31); none was seen moving with the chore done in play.

    -- Months since the statues were last built: it read 3 at login, and building should take
    -- it to 0. Only a fall ticks, so a var that reads 0 because it isn't sent never does.
    {
        chore = "god-statues",
        done = { { "GODSS_MONTHS_SINCE_USED", "==", 0 } },
        falls = { "GODSS_MONTHS_SINCE_USED" },
        proven = true,
    },
    -- The Troll Invasion limit reached: read 0 at login, the month's waves not yet played.
    {
        chore = "troll-invasion",
        done = { { "DNDTRACKER_TROLL_INVASION_LIMIT", "==", 1 } },
        proven = true,
    },

    -- The day's 23rd corrupted scarab, the last at full reputation, once the soul obelisk has
    -- been drained at all today. The obelisk's own cap (236 interactions) is in units the var
    -- doesn't show, so only a start counts.
    {
        chore = "menaphos-obelisk",
        done = {
            { "MENAPHOS_SCARABS_SQUISHED_TODAY", ">=", 23 },
            { "MENAPHOS_SOUL_OBELISK_DRAINED_AMOUNT", ">", 0 },
        },
        proven = true,
    },
    -- The day's 10 supplies handed in to Quercy, the most that give XP.
    {
        chore = "goebie-bands",
        done = { { "RAID1_GOEBIE_COURIER_LOOT_HANDED_IN_TODAY", ">=", 10 } },
        proven = true,
    },
    -- The day assigned a bounty last: taking one from Feng raises it.
    { chore = "gwd2-bounties", done = {}, rises = "GWD2_REP_TASK_LAST_DAY_GIVEN", proven = true },
    -- The quartermaster's weekly XP boost claimed: that needs the week's resources gathered.
    {
        chore = "capping-clan-citadel",
        done = { { "CLAN_CLAIMED_XP_REWARD", "==", 1 } },
        proven = true,
    },
    -- Waves cleared in the week's reward run; a reset takes it down, never up.
    {
        chore = "rush-of-blood",
        done = {},
        rises = "ELFCITY_SLAYER_WEEKLY_CHALLENGE_WAVES_COMPLETED",
        proven = true,
    },
    -- Meg leaves on her mission after the week's third answer: it read 0 with her at home, and
    -- her return takes it back down, so only her leaving can tick.
    { chore = "meg", done = { { "POP_MEG_ONMISSION", ">", 0 } }, proven = true },
    -- Taken as the time of the last clean-out. It read 0 in the client and on the server (never
    -- cleaned out), and a !setvar reached the client away from the oasis, so it is sent
    -- anywhere and arriving there can't tick it.
    {
        chore = "water-filtration",
        done = {},
        rises = "DUEL_ARENA_REMOVAL_WATER_FILTRATION_LOOT_TIME",
        proven = true,
    },
    -- Bit 16 of ELR1_BASEVAR2: Rosie's free supplies taken. Daily in the game, weekly here, as
    -- for the freebies above.
    { chore = "arc-supplies", done = { { "ELR1_DAILY_SUPPLIES_TAKEN", "==", 1 } }, proven = true },
    -- The oyster fed both its sea cucumber and its seaweed, which closes it for the month.
    {
        chore = "giant-oyster",
        done = {
            { "TUTISLAND_REWARD_OYSTER_FED_SEACUCMBER", "==", 1 },
            { "TUTISLAND_REWARD_OYSTER_FED_SEAWEED", "==", 1 },
        },
        proven = true,
    },
}

-- Arc contracts: PGC_TALLY counts the day's completed contracts, and the limit is 3 plus the
-- Waiko shop's "contracts per day" upgrades bought (PGC_PER_DAY_INCREASE, 0 to 4; it read 4).
for bought = 0, 4 do
    rules[#rules + 1] = {
        chore = "arc-contracts",
        done = { { "PGC_PER_DAY_INCREASE", "==", bought }, { "PGC_TALLY", ">=", 3 + bought } },
        proven = true,
    }
end

-- Chores with one var per tree, trough or patch: a rule each, any of which ticks the chore.
-- Seen moving in the chore probe of 2026-10-30. One var of each (tree 8, trough 1, patch 1)
-- ticked its chore in the client when set with !setvar (2026-10-31); the rest share its
-- layout.

-- A bloodwood tree reads 1 standing and 2 felled; felling tree 8 took it 1 -> 2.
for n = 1, 8 do
    rules[#rules + 1] = {
        chore = "bloodwood-tree",
        done = { { "SNIPER_BLOODTREE_" .. n, "==", 2 } },
        proven = true,
    }
end

-- Food in each Player-Owned Farm trough (of 1000); feeding took trough 1 0 -> 3. Only
-- feeding raises it, while the animals eat it down.
for _, trough in ipairs({ "1", "2", "3", "4", "5", "6", "BREEDING" }) do
    rules[#rules + 1] = {
        chore = "player-owned-farm",
        done = {},
        rises = "POF_FEEDING_TROUGH_" .. trough .. "_GENERAL_AMOUNT",
        proven = true,
    }
end

-- Seeds in each herb patch: clearing one took it 7 -> 0, planting 0 -> 7. Which number is
-- which patch is unknown, so the first patch planted in the day ticks the run.
for _, patch in ipairs({
    "1",
    "2",
    "3",
    "4",
    "5",
    "9",
    "DRUID",
    "MYARM",
    "WILDY",
    "ECOSYSTEM_1",
    "ECOSYSTEM_2",
}) do
    rules[#rules + 1] = {
        chore = "herb-run",
        done = {},
        rises = "FARMING_SEEDS_PLANTED_HERB_PATCH_" .. patch,
        proven = true,
    }
end

-- Fort Forinthry: the Town Hall's own record of bonus XP taken never reaches the client
-- (docs/api-concepts.md), so the chore ticks when any skill's bonus XP pool rises while the
-- player stands by Aster, who trades rested XP in. A claim of 2026-10-31 took
-- BONUSXP_AGILITY 0 -> 1596975 there, and a !setvar of it beside Aster ticked the chore in the
-- client (2026-10-31). A lamp or star used beside Aster ticks it too.
local ASTER = { x = 3302, z = 3571, level = 0, range = 10 } -- runescape.wiki/w/Aster
for _, skill in ipairs({
    "AGILITY",
    "ARCHAEOLOGY",
    "ATTACK",
    "CONSTRUCTION",
    "COOKING",
    "CRAFTING",
    "DEFENCE",
    "DIVINATION",
    "DUNGEONEERING",
    "FARMING",
    "FIREMAKING",
    "FISHING",
    "FLETCHING",
    "HERBLORE",
    "HITPOINTS",
    "HUNTER",
    "INVENTION",
    "MAGIC",
    "MINING",
    "NECROMANCY",
    "PRAYER",
    "RANGED",
    "RUNECRAFTING",
    "SLAYER",
    "SMITHING",
    "STRENGTH",
    "SUMMONING",
    "THIEVING",
    "WOODCUTTING",
}) do
    rules[#rules + 1] = {
        chore = "fort-forinthry-bonus-xp",
        done = {},
        rises = "BONUSXP_" .. skill,
        near = ASTER,
        proven = true,
    }
end

return rules
