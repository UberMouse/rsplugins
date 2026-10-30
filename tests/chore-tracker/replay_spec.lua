-- The Chore Tracker replaying tests/fixtures/chore-tracker-feather-buy.jsonl: 20 ticks of a real
-- beta-client session (recording 201740cf2b, ticks 2810..2830), in which the player bought out the
-- feathers at the Lumbridge fishing shop. In the client the Feather Shop Run went from (0/4) to
-- (1/4) and its row ticked.
--
-- The recording is of recorder-demo, so it holds that plugin's reads and the world's events, not
-- the Chore Tracker's. The recorded InventoryUpdated carries the shop's whole inventory *after*
-- the buy, but detection compares it with the counts the tracker held from before (it had seen
-- the shop open); the recording's window starts after that, so the spec stocks the shop before
-- the load. The watched vars start at 0 as in the other specs. The clock, the login, the events
-- and the shop's final stock all come from the recording.

local helpers = require("tests.chore-tracker.helpers")
local paths = require("tests.harness.paths")
local shops = require("data/shops")
local timeline = require("tests.harness.timeline")

local FIXTURE = "tests/fixtures/chore-tracker-feather-buy.jsonl"
local FEATHERS = { name = "Feather Shop Run", id = "feather-shop-run" }
-- The player the recording logged in, as the sanitiser renamed them.
local WHO = "Fixture Player"
-- VarPlayer.CLOCK_TIME_DATE_MINUTES as the recording read it at t = 0.
local CLOCK = 29889954

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

-- The fixture's entries, and a read of nil for every other shop the tracker watches: the
-- client held none of them open (Inventory.Find returns nil for an inventory that isn't
-- loaded), but recorder-demo never looked, and a replayed read nobody recorded faults.
---@return table[]
local function entries()
    local recorded = timeline.parse(assert(paths.read(paths.repo(FIXTURE))))
    local list = { table.remove(recorded, 1) } -- the session header
    for _, hits in pairs(shops) do
        for _, shop in ipairs(hits) do
            for _, inv in ipairs(shop.invs) do
                if inv ~= "FISHINGSHOP_LUM" then
                    list[#list + 1] =
                        { t = 0, k = "read", path = "Inventory.Find(config.Inv." .. inv .. ")" }
                end
            end
        end
    end
    table.move(recorded, 1, #recorded, #list + 1, list)
    return list
end

-- A tracker loaded with the Lumbridge shop open, then the recording replayed over it. The
-- Feather Shop Run is picked (shown in the list) unless `pick` is false.
---@param pick boolean
---@return table h
local function replayed(pick)
    -- No scripted login or clock: the recording's reads are both.
    local h = helpers.loaded({ load = false, login = false })
    local before = {}
    for i, line in ipairs(STOCK) do
        before[i] = { obj = line.obj, count = line.count }
    end
    before[6].count = FEATHERS_BEFORE
    h.world:setInventory("FISHINGSHOP_LUM", before, 19)
    -- The backpack before the buy, holding none of the banknotes the tracker counts: it reads
    -- their totals on load and on the recorded backpack update, which the recording never read.
    h.world:setInventory("INV", {}, 28)
    -- The recorder-demo recording never asked for httpAccess, which the dev log tee in main.lua
    -- does; declined, the tee stays off.
    h.world:revoke("httpAccess")
    -- The recording holds recorder-demo's PersistentDB keys, not ours, and a replay faults on a
    -- key it never saw, so store what a fresh install has: unreadable layout and settings (which
    -- load as their defaults) and a character with the Feather Shop Run picked, or nothing.
    helpers.seed(h, "layout", {})
    helpers.seed(h, "celebrations", {})
    helpers.seed(h, "state:" .. WHO, {
        version = 2,
        selected = pick and { FEATHERS.id } or {},
        done = {},
        shops = {},
    })
    h:useRecording(entries())
    h:load()
    h:playRecording()
    h:advance(20)
    return h
end

describe("chore-tracker replaying a recorded feather purchase", function()
    it("ticks the Feather Shop Run, one shop of four, as the client did", function()
        local h = replayed(true)
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
        local h = replayed(true)
        assert.are.same({ [FEATHERS.id] = CLOCK }, helpers.stored(h, WHO).done)
        assert.are.same(
            { [FEATHERS.id] = { FISHINGSHOP_LUM = CLOCK } },
            helpers.stored(h, WHO).shops
        )
    end)
end)
