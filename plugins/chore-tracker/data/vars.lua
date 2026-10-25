-- Chores seen done from the player's own game vars, hand-written. Each entry is a chore id
-- and its done rule over named VarPlayer vars (the rule language is in core/vars.lua); the
-- names, base vars and bits are in docs/vars/vars.csv. shell/vars.lua ticks a chore when a
-- watched var changes and its rule goes from false to true (or, for a rule naming a `rises`
-- var, that var goes up), never on a var's first read.
--
-- `proven` marks a rule whose var was seen to move as the chore was done in the beta client
-- (the var-dump session of 2026-10-25, docs/api-concepts.md); an unproven one ticks the same
-- way. The four free collections keep dailyscape's weekly period (the user's choice), so the
-- first claim in a week ticks one until Wednesday's reset, although the game's flag is daily.

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
    -- unknown; either way a claim raises it, so any rise ticks the chore (the user's choice)
    -- and it needs no conditions. INTERN_NOTES_DAILY_CHALLENGES_COMPLETE isn't used: it
    -- counts finished challenges not yet claimed, and falls on the claim.
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
}
