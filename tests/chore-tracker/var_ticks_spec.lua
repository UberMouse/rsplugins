-- The Chore Tracker ticking chores from the player's own game vars (data/vars.lua), through
-- the harness, whose VarBits pack into their base vars as the client's do. A chore ticks only
-- on a change seen after the 10 s settle that follows the load or a character switch.

local helpers = require("tests.chore-tracker.helpers")
local loaded, ticked, togglePicks, doneAt =
    helpers.loaded, helpers.ticked, helpers.togglePicks, helpers.doneAt

local BERT = { name = "Sand from Bert", id = "bert-sand" }
local CHALLENGE = { name = "Daily Challenge", id = "daily-challenge" }
local ADVANCE = { id = "advance-time" }

local SETTLE_MS, POLL_MS, settled = helpers.SETTLE_MS, helpers.POLL_MS, helpers.settled

---@param h table
---@param name string
---@param value integer
local function set(h, name, value)
    h.world:setVar("VarPlayer", name, value)
end

-- How many `seen` lines the plugin has logged.
---@param h table
---@return integer
local function seenLines(h)
    local _, n = h:output():gsub("%[CHORES%] seen ", "")
    return n
end

describe("chore-tracker var ticks", function()
    it("ticks a chore when its VarBit turns true, logging the var", function()
        local h = settled()
        togglePicks(h, { BERT.id })
        assert.is_false(ticked(h, BERT.name))
        local writes = h.dbWrites
        set(h, "HANDSAND_BUCKETS_CLAIMED_TODAY", 1)
        assert.are.equal(writes + 1, h.dbWrites)
        assert.are.equal(helpers.NOW, doneAt(h, BERT.id))
        assert.matches(
            "%[CHORES%] seen bert%-sand done %(HANDSAND_BUCKETS_CLAIMED_TODAY%)",
            h:output()
        )
        h:advance(20)
        assert.is_true(ticked(h, BERT.name))
    end)

    it("ticks from an event naming the base var", function()
        local h = settled()
        -- Bit 1 of HANDSAND_BUCKETS is the claim flag; bit 0 is unrelated.
        set(h, "HANDSAND_BUCKETS", 1)
        assert.is_nil(doneAt(h, BERT.id))
        set(h, "HANDSAND_BUCKETS", 3)
        assert.are.equal(helpers.NOW, doneAt(h, BERT.id))
        assert.are.equal(1, seenLines(h))
    end)

    it("ticks each of the four freebies from its flag", function()
        local flags = {
            ["bert-sand"] = "HANDSAND_BUCKETS_CLAIMED_TODAY",
            ["geoffrey-flax"] = "ATSEER_REWARD_FLAX_GIVEN_TODAY",
            ["cromperty-pure-essence"] = "ATAR_ESS_USED",
            ["coeden-logs"] = "ATELF_DAILY_LOGS_CLAIMED",
        }
        for id, flag in pairs(flags) do
            local h = settled()
            set(h, flag, 1)
            assert.are.equal(helpers.NOW, doneAt(h, id), id)
            assert.are.equal(1, seenLines(h), id)
        end
    end)

    it("doesn't tick a rule already true at load", function()
        local h = settled({ HANDSAND_BUCKETS_CLAIMED_TODAY = 1 })
        -- Other bits of the same base change (bits 7-31); the claim flag stays 1.
        set(h, "HANDSAND_RUNEDAY", 9006)
        set(h, "HANDSAND_BUCKETS_CLAIMED_TODAY", 1)
        assert.is_nil(doneAt(h, BERT.id))
        assert.are.equal(0, seenLines(h))
    end)

    it("doesn't tick a rule turning true within the settle window after load", function()
        local h = loaded()
        h:advance(SETTLE_MS - 100)
        set(h, "HANDSAND_BUCKETS_CLAIMED_TODAY", 1)
        h:advance(200)
        assert.is_nil(doneAt(h, BERT.id))
        -- The flag stays 1, so only a fresh change after a reset would tick it.
        set(h, "ATAR_ESS_USED", 1)
        assert.are.equal(helpers.NOW, doneAt(h, "cromperty-pure-essence"))
        assert.is_nil(doneAt(h, BERT.id))
    end)

    it("settles again after a character switch", function()
        local h = settled()
        h.world:login("Lynx Titan")
        h:advance(POLL_MS)
        set(h, "HANDSAND_BUCKETS_CLAIMED_TODAY", 1)
        assert.is_nil(doneAt(h, BERT.id, "Lynx Titan"))
        h:advance(SETTLE_MS)
        set(h, "ATELF_DAILY_LOGS_CLAIMED", 1)
        assert.are.equal(helpers.NOW, doneAt(h, "coeden-logs", "Lynx Titan"))
        assert.is_nil(doneAt(h, BERT.id, "Lynx Titan"))
        assert.is_nil(doneAt(h, "coeden-logs"))
    end)

    it("changes nothing on a var of an unrelated base", function()
        local h = settled()
        local writes = h.dbWrites
        set(h, "ABSYSTEM", 7)
        assert.are.equal(writes, h.dbWrites)
        assert.are.equal(0, seenLines(h))
    end)

    it("keeps a chore's earlier tick, logging nothing", function()
        local h = settled()
        togglePicks(h, { BERT.id })
        helpers.toggleTick(h, BERT.name)
        helpers.setClock(h, helpers.NOW + 30)
        local writes = h.dbWrites
        set(h, "HANDSAND_BUCKETS_CLAIMED_TODAY", 1)
        assert.are.equal(writes, h.dbWrites)
        assert.are.equal(helpers.NOW, doneAt(h, BERT.id))
        assert.are.equal(0, seenLines(h))
    end)

    it("drops a tick without a clock or a character", function()
        for _, opts in ipairs({ { clock = 0 }, { login = false } }) do
            local h = settled(nil, opts)
            local writes = h.dbWrites
            set(h, "HANDSAND_BUCKETS_CLAIMED_TODAY", 1)
            assert.are.equal(writes, h.dbWrites)
            assert.are.equal(0, seenLines(h))
        end
    end)

    it("ticks the Daily Challenge when a challenge's reward is claimed", function()
        local h = settled()
        togglePicks(h, { CHALLENGE.id })
        set(h, "CHALLENGE_TOTAL_COMPLETED", 1)
        assert.are.equal(helpers.NOW, doneAt(h, CHALLENGE.id))
        assert.matches(
            "%[CHORES%] seen daily%-challenge done %(CHALLENGE_TOTAL_COMPLETED%)",
            h:output()
        )
        h:advance(20)
        assert.is_true(ticked(h, CHALLENGE.name))
    end)

    it("ticks the Daily Challenge on a rise from a large total at load", function()
        local h = settled({ CHALLENGE_TOTAL_COMPLETED = 500 })
        -- Another field of CHALLENGE_BI_1 changing re-reads the total, still 500.
        set(h, "OGE_COMBAT_COMPLETE", 1)
        assert.is_nil(doneAt(h, CHALLENGE.id))
        assert.are.equal(0, seenLines(h))
        set(h, "CHALLENGE_TOTAL_COMPLETED", 501)
        assert.are.equal(helpers.NOW, doneAt(h, CHALLENGE.id))
    end)

    it("doesn't tick the Daily Challenge on a claim within the settle window", function()
        local h = loaded()
        h:advance(SETTLE_MS - 100)
        set(h, "CHALLENGE_TOTAL_COMPLETED", 1)
        h:advance(200)
        assert.is_nil(doneAt(h, CHALLENGE.id))
        assert.are.equal(0, seenLines(h))
    end)

    it("doesn't tick the Daily Challenge on a total unchanged or falling", function()
        local h = settled({ CHALLENGE_TOTAL_COMPLETED = 3 })
        set(h, "CHALLENGE_TOTAL_COMPLETED", 3)
        set(h, "CHALLENGE_TOTAL_COMPLETED", 0)
        assert.is_nil(doneAt(h, CHALLENGE.id))
        assert.are.equal(0, seenLines(h))
    end)

    it("doesn't tick the Daily Challenge when a challenge is finished", function()
        local h = settled()
        -- The count of finished but unclaimed challenges.
        set(h, "INTERN_NOTES_DAILY_CHALLENGES_COMPLETE", 1)
        set(h, "INTERN_NOTES_DAILY_CHALLENGES_COMPLETE", 3)
        assert.is_nil(doneAt(h, CHALLENGE.id))
        assert.are.equal(0, seenLines(h))
    end)

    it("logs the Daily Challenge once when a second claim follows", function()
        local h = settled()
        set(h, "CHALLENGE_TOTAL_COMPLETED", 1)
        assert.are.equal(helpers.NOW, doneAt(h, CHALLENGE.id))
        helpers.setClock(h, helpers.NOW + 30)
        local writes = h.dbWrites
        set(h, "CHALLENGE_TOTAL_COMPLETED", 2)
        assert.are.equal(writes, h.dbWrites)
        assert.are.equal(helpers.NOW, doneAt(h, CHALLENGE.id))
        assert.are.equal(1, seenLines(h))
    end)

    it("ticks Advance Time on its last charge, only after the baseline", function()
        local h = loaded({ load = false })
        set(h, "MAGIC_ADVANCE_TIME_CHARGES_REMAINING", 3)
        h:load()
        -- Used up within the settle window: only the baseline moves.
        set(h, "MAGIC_ADVANCE_TIME_CHARGES_REMAINING", 0)
        h:advance(SETTLE_MS)
        assert.is_nil(doneAt(h, ADVANCE.id))

        h = settled({ MAGIC_ADVANCE_TIME_CHARGES_REMAINING = 3 })
        set(h, "MAGIC_ADVANCE_TIME_CHARGES_REMAINING", 2)
        set(h, "MAGIC_ADVANCE_TIME_CHARGES_REMAINING", 1)
        assert.is_nil(doneAt(h, ADVANCE.id))
        set(h, "MAGIC_ADVANCE_TIME_CHARGES_REMAINING", 0)
        assert.are.equal(helpers.NOW, doneAt(h, ADVANCE.id))
        assert.matches(
            "%[CHORES%] seen advance%-time done %(MAGIC_ADVANCE_TIME_CHARGES_REMAINING%)",
            h:output()
        )
    end)

    it("ticks Divine Locations when the day's limit is gathered", function()
        local h = settled({ DIV_GATHER_LIMIT = 20, DIV_GATHERED = 18 })
        set(h, "DIV_GATHERED", 19)
        assert.is_nil(doneAt(h, "divine-locations"))
        set(h, "DIV_GATHERED", 20)
        assert.are.equal(helpers.NOW, doneAt(h, "divine-locations"))
    end)

    it("ticks Thalmund's Wares once every slot is bought out, counting each", function()
        local before = {}
        for n = 1, 4 do
            before["NECRO_HUB_THALMUND_SLOT_" .. n .. "_MAX"] = 10
            before["NECRO_HUB_THALMUND_SLOT_" .. n .. "_BOUGHT"] = 8
        end
        local h = settled(before)
        togglePicks(h, { "thalmunds-wares" })
        for n = 1, 3 do
            set(h, "NECRO_HUB_THALMUND_SLOT_" .. n .. "_BOUGHT", 10)
        end
        -- Each slot bought out counts towards the default of all four.
        assert.is_nil(doneAt(h, "thalmunds-wares"))
        assert.matches(
            "%[CHORES%] seen thalmunds%-wares part %(NECRO_HUB_THALMUND_SLOT_3_BOUGHT%)",
            h:output()
        )
        h:advance(POLL_MS)
        assert.are.equal("Thalmund's Wares (3/4)", (helpers.rowShown(h, "Thalmund's Wares")))
        set(h, "NECRO_HUB_THALMUND_SLOT_4_BOUGHT", 10)
        assert.are.equal(helpers.NOW, doneAt(h, "thalmunds-wares"))
        assert.matches(
            "%[CHORES%] seen thalmunds%-wares done %(NECRO_HUB_THALMUND_SLOT_4_BOUGHT%)",
            h:output()
        )
    end)

    it("ticks a Herb Run on its default of 8 patches, or the count set in settings", function()
        local patches = { "1", "2", "3", "4", "5", "9", "DRUID", "MYARM" }
        local before = {}
        for _, patch in ipairs(patches) do
            before["FARMING_SEEDS_PLANTED_HERB_PATCH_" .. patch] = 0
        end
        local h = settled(before)
        for i = 1, 7 do
            set(h, "FARMING_SEEDS_PLANTED_HERB_PATCH_" .. patches[i], 7)
        end
        assert.is_nil(doneAt(h, "herb-run"))
        set(h, "FARMING_SEEDS_PLANTED_HERB_PATCH_" .. patches[8], 7)
        assert.are.equal(helpers.NOW, doneAt(h, "herb-run"))

        -- Set to 1, the first patch planted ticks it.
        local again = settled(before)
        helpers.setNeeded(again, "herb-run", 1)
        set(again, "FARMING_SEEDS_PLANTED_HERB_PATCH_DRUID", 7)
        assert.are.equal(helpers.NOW, doneAt(again, "herb-run"))
    end)

    it("ticks the Crystal Tree Blossom when taken on the clock's RuneDay", function()
        -- The harness clock, NOW, is 2026-10-25: RuneDay 9006.
        local h = settled({ ELFCITY_CRYSTAL_BLOSSOMS_LAST_DATE = 9004 })
        set(h, "ELFCITY_CRYSTAL_BLOSSOMS_LAST_DATE", 9005)
        assert.is_nil(doneAt(h, "crystal-tree-blossom"))
        set(h, "ELFCITY_CRYSTAL_BLOSSOMS_LAST_DATE", 9006)
        assert.are.equal(helpers.NOW, doneAt(h, "crystal-tree-blossom"))
        assert.matches(
            "%[CHORES%] seen crystal%-tree%-blossom done %(ELFCITY_CRYSTAL_BLOSSOMS_LAST_DATE%)",
            h:output()
        )
    end)
end)
