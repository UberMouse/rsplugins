-- Chores seen done from the player's own game vars, hand-written. Each entry is a chore id
-- and its done rule over named VarPlayer vars (the rule language is in core/vars.lua); the
-- names, base vars and bits are in docs/vars/vars.csv. shell/vars.lua ticks a chore when a
-- watched var changes and its rule goes from false to true (or, for a rule naming a `rises`
-- var, that var goes up; for one naming `falls` vars, the rule turns true as one of them
-- goes down), never on a var's first read.
--
-- `proven` marks a rule whose vars were checked against the chore in the beta client (recorded
-- in docs/api-concepts.md); an unproven one ticks the same way. The four free collections keep
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
return {
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
}
