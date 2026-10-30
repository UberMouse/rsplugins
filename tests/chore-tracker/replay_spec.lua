-- The Chore Tracker replaying two real beta-client sessions, each recorded by recorder-demo.
--
-- tests/fixtures/chore-tracker-feather-buy.jsonl: 20 ticks (recording 201740cf2b, ticks
-- 2810..2830) in which the player bought out the feathers at the Lumbridge fishing shop. In the
-- client the Feather Shop Run went from (0/4) to (1/4) and its row ticked.
--
-- tests/fixtures/chore-tracker-bert-sand.jsonl: 760 ticks (recording 7e06f091e8, ticks
-- 2680..3440) in which the player reset HANDSAND_BUCKETS with the cheat
-- `!setvar handsand_buckets_claimed_today 0` (fixture tick 550, 3 -> 1), then claimed Sand from
-- Bert (fixture tick 758, 1 -> 3). The client logged `seen bert-sand done` and
-- `celebrate bert-sand` and ticked the row. The window opens 550 ticks before the reset because
-- the tracker ignores var changes for 500 ticks after it loads (shell/vars.lua SETTLE_TICKS).
--
-- The recording is of recorder-demo, so it holds that plugin's reads and the world's events, not
-- the Chore Tracker's. The recorded InventoryUpdated carries the shop's whole inventory *after*
-- the buy, but detection compares it with the counts the tracker held from before (it had seen
-- the shop open); the recording's window starts after that, so the spec stocks the shop before
-- the load. The watched vars start at 0 as in the other specs. The clock, the login, the events
-- and the shop's final stock all come from the recording.
--
-- In the Bert replay the recorded VarTransmits of HANDSAND_BUCKETS drive the tracker's own var
-- detection (the harness packs HANDSAND_BUCKETS_CLAIMED_TODAY, bit 1, from the base var). The
-- spec supplies the base var's value from before the window, 3.

local helpers = require("tests.chore-tracker.helpers")
local paths = require("tests.harness.paths")
local shops = require("data/shops")
local timeline = require("tests.harness.timeline")

local FEATHER_FIXTURE = "tests/fixtures/chore-tracker-feather-buy.jsonl"
local BERT_FIXTURE = "tests/fixtures/chore-tracker-bert-sand.jsonl"
local BERT = { name = "Sand from Bert", id = "bert-sand" }
local FEATHERS = { name = "Feather Shop Run", id = "feather-shop-run" }
-- The player the recording logged in, as the sanitiser renamed them.
local WHO = "Fixture Player"
-- VarPlayer.CLOCK_TIME_DATE_MINUTES as each recording read it at t = 0.
local CLOCK = 29889954
local BERT_CLOCK = 29889958

-- FISHINGSHOP_LUM's lines as the recording ends, by obj id (the recording's own slots). Slot 6,
-- FEATHER (obj 314), is the line bought out.
local STOCK = {
    { obj = 303, count = 5 },
    { obj = 307, count = 10 },
    { obj = 309, count = 10 },
    { obj = 13431, count = 10 },
    { obj = 313, count = 1000 },
    { obj = 314, count = 0 },
    { obj = 317, count = 0 },
    { obj = 327, count = 0 },
    { obj = 345, count = 0 },
    { obj = 321, count = 0 },
    { obj = 335, count = 0 },
    { obj = 349, count = 0 },
    { obj = 331, count = 0 },
    { obj = 13435, count = 0 },
    { obj = 43412, count = 20 },
}
-- The feathers the shop held before the buy: the amount bought, which the recording's
-- SHOP_LAST_VIEWED_BUYAMT var (3500) and the backpack's feather slot both show.
local FEATHERS_BEFORE = 3500

-- The fixture's entries, and a read of nil for every shop the tracker watches except `open`: the
-- client held none of them open (Inventory.Find returns nil for an inventory that isn't
-- loaded), but recorder-demo never looked, and a replayed read nobody recorded faults.
---@param fixture string
---@param open string? the shop the recording has open, if any
---@return table[]
local function entries(fixture, open)
    local recorded = timeline.parse(assert(paths.read(paths.repo(fixture))))
    local list = { table.remove(recorded, 1) } -- the session header
    for _, hits in pairs(shops) do
        for _, shop in ipairs(hits) do
            for _, inv in ipairs(shop.invs) do
                if inv ~= open then
                    list[#list + 1] =
                        { t = 0, k = "read", path = "Inventory.Find(config.Inv." .. inv .. ")" }
                end
            end
        end
    end
    table.move(recorded, 1, #recorded, #list + 1, list)
    return list
end

-- A tracker loaded, then the recording replayed over it. `o.fixture` is the recording, `o.open`
-- the shop it has open, `o.picked` the chore ids the character has picked, `o.before` runs on
-- the harness after the shared setup and before the load, to put the world as it was when the
-- recording's window opened, and `o.upTo` is the tick to stop at (the recording's last by
-- default).
---@param o { fixture: string, open: string?, picked: string[], before: fun(h: table), upTo: integer? }
---@return table h
local function replayed(o)
    -- No scripted login or clock: the recording's reads are both.
    local h = helpers.loaded({ load = false, login = false })
    -- The backpack before the recording, holding none of the banknotes the tracker counts: it
    -- reads their totals on load and on a recorded backpack update, which the recording never
    -- read.
    h.world:setInventory("INV", {}, 28)
    -- The recorder-demo recording never asked for httpAccess, which the dev log tee in main.lua
    -- does; declined, the tee stays off.
    h.world:revoke("httpAccess")
    -- The recording holds recorder-demo's PersistentDB keys, not ours, and a replay faults on a
    -- key it never saw, so store what a fresh install has: unreadable layout and settings (which
    -- load as their defaults) and a character with the chores picked, none done.
    helpers.seed(h, "layout", {})
    helpers.seed(h, "celebrations", {})
    helpers.seed(h, "state:" .. WHO, {
        version = 2,
        selected = o.picked,
        done = {},
        shops = {},
    })
    o.before(h)
    h:useRecording(entries(o.fixture, o.open))
    h:load()
    if o.upTo then
        while h.tick < o.upTo do
            h:step()
        end
    else
        h:playRecording()
    end
    h:advance(20) -- one more tick, past the last recorded entry
    return h
end

-- The feather recording: the Lumbridge shop open, the Feather Shop Run picked.
---@return table h
local function feathersBought()
    return replayed({
        fixture = FEATHER_FIXTURE,
        open = "FISHINGSHOP_LUM",
        picked = { FEATHERS.id },
        before = function(h)
            local before = {}
            for i, line in ipairs(STOCK) do
                before[i] = { obj = line.obj, count = line.count }
            end
            before[6].count = FEATHERS_BEFORE
            h.world:setInventory("FISHINGSHOP_LUM", before, 19)
        end,
    })
end

-- The Bert recording up to fixture tick `upTo` (its last by default), Sand from Bert picked and
-- not done, as the player had it.
---@param upTo integer?
---@return table h
local function sandSession(upTo)
    return replayed({
        fixture = BERT_FIXTURE,
        picked = { BERT.id },
        upTo = upTo,
        before = function(h)
            -- HANDSAND_BUCKETS read 3 before the reset (bit 1, the claim, set), the recording's
            -- first VarTransmit of it being the reset to 1. helpers.loaded zeroed the VarBit, so
            -- write the base over it. The row had been unticked by hand, so nothing is done.
            h.world:setVar("VarPlayer", "HANDSAND_BUCKETS", 3)
        end,
    })
end

describe("chore-tracker replaying a recorded feather purchase", function()
    it("ticks the Feather Shop Run, one shop of four, as the client did", function()
        local h = feathersBought()
        assert.is_true(helpers.ticked(h, FEATHERS.name))
        local text, tooltip = helpers.rowShown(h, FEATHERS.name)
        assert.are.equal("Feather Shop Run (1/4)", text)
        assert.is_not_nil(tooltip:find("bought  Lumbridge Fishing Supplies", 1, true))
        assert.is_not_nil(
            h:output()
                :find("[CHORES] purchase feather-shop-run at Lumbridge Fishing Supplies", 1, true)
        )
        assert.are.same({ FISHINGSHOP_LUM = CLOCK }, helpers.stored(h, WHO).shops[FEATHERS.id])
        assert.are.equal(CLOCK, helpers.doneAt(h, FEATHERS.id, WHO))
    end)

    it("marks nothing else done", function()
        local h = feathersBought()
        assert.are.same({ [FEATHERS.id] = CLOCK }, helpers.stored(h, WHO).done)
        assert.are.same(
            { [FEATHERS.id] = { FISHINGSHOP_LUM = CLOCK } },
            helpers.stored(h, WHO).shops
        )
    end)
end)

describe("chore-tracker replaying a recorded claim of Sand from Bert", function()
    it("leaves Sand from Bert undone after the reset", function()
        local h = sandSession(600) -- the reset is at 550, the claim not until 758
        assert.is_false(helpers.ticked(h, BERT.name))
        assert.are.same({}, helpers.stored(h, WHO).done)
        assert.is_nil(h:output():find("seen bert-sand", 1, true))
    end)

    it("ticks Sand from Bert at the claim, as the client did", function()
        local h = sandSession()
        assert.is_true(helpers.ticked(h, BERT.name))
        assert.is_not_nil(
            h:output()
                :find("[CHORES] seen bert-sand done (HANDSAND_BUCKETS_CLAIMED_TODAY)", 1, true)
        )
        assert.is_not_nil(h:output():find("[CHORES] celebrate bert-sand", 1, true))
        assert.are.same({ [BERT.id] = BERT_CLOCK }, helpers.stored(h, WHO).done)
    end)
end)
