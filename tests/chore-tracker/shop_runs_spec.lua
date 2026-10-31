-- The Chore Tracker ticking shop runs from shop stock, through the harness: a shop is an
-- inventory the client holds only while it is open, and a line whose count drops is the
-- player buying (docs/api-concepts.md, "Shops in the client").

local helpers = require("tests.chore-tracker.helpers")
local loaded, ticked, togglePicks, rowShown, doneAt =
    helpers.loaded, helpers.ticked, helpers.togglePicks, helpers.rowShown, helpers.doneAt

local FEATHERS = { name = "Feather Shop Run", id = "feather-shop-run" }
local YAK = { name = "Yak Hides from Vanligga", id = "yak-hide" }
local DAILY = { name = "Daily Challenge", id = "daily-challenge" }

local POLL_MS, setClock = helpers.POLL_MS, helpers.setClock

local window = helpers.window

-- Set open shop `inv` to `count` feather packs and a line of bait (a purchase when the count
-- drops). Not helpers.buy: the bait line is part of what these specs check around.
---@param h table
---@param inv string
---@param count integer
local function stockFeathers(h, inv, count)
    helpers.stock(h, inv, "FEATHER_PACK", count, { { obj = "FISHING_BAIT", count = 100 } })
end

describe("chore-tracker shop runs", function()
    it("records each purchase, and by default ticks once all four shops are bought", function()
        local h = loaded()
        togglePicks(h, { FEATHERS.id })
        stockFeathers(h, "FISHINGSHOP", 20)
        local writes = h.dbWrites
        stockFeathers(h, "FISHINGSHOP", 0)
        assert.are.equal(writes + 1, h.dbWrites)
        assert.matches("%[CHORES%] purchase feather%-shop%-run at Gerrant, Port Sarim", h:output())
        assert.are.same({ FISHINGSHOP = helpers.NOW }, helpers.stored(h).parts[FEATHERS.id])
        assert.is_nil(helpers.doneAt(h, FEATHERS.id))

        h:advance(20)
        assert.is_false(ticked(h, FEATHERS.name))
        local text, tooltip = rowShown(h, FEATHERS.name)
        assert.are.equal("Feather Shop Run (1/4)", text)
        assert.matches(
            "Shops this week %(1/4%):<br>bought  Gerrant, Port Sarim<br>"
                .. "not yet  Lumbridge Fishing Supplies<br>not yet  Harry, Catherby<br>"
                .. "not yet  Shantay Pass<br>https://",
            tooltip
        )
        h.ui:get("Title", { text = "Weekly  0/1" })

        for _, inv in ipairs({ "FISHINGSHOP_LUM", "FISHINGSHOP2" }) do
            stockFeathers(h, inv, 20)
            stockFeathers(h, inv, 0)
        end
        assert.is_false(ticked(h, FEATHERS.name))
        stockFeathers(h, "SHANTAYSHOP", 20)
        stockFeathers(h, "SHANTAYSHOP", 0)
        h:advance(20)
        assert.is_true(ticked(h, FEATHERS.name))
        assert.are.equal("Feather Shop Run (4/4)", (rowShown(h, FEATHERS.name)))
        h.ui:get("Title", { text = "Weekly  1/1" })
    end)

    it("ticks once the set count of shops is bought, with a popup when picked", function()
        local h = loaded()
        togglePicks(h, { FEATHERS.id })
        helpers.setNeeded(h, FEATHERS.id, 2)
        assert.are.same({ [FEATHERS.id] = 2 }, helpers.stored(h).needed)
        stockFeathers(h, "FISHINGSHOP", 20)
        stockFeathers(h, "FISHINGSHOP", 0)
        h:advance(20)
        assert.is_false(ticked(h, FEATHERS.name))
        local text, tooltip = rowShown(h, FEATHERS.name)
        assert.are.equal("Feather Shop Run (1/2)", text)
        -- The tooltip still lists every shop.
        assert.matches(
            "Shops this week %(1/2%):<br>bought  Gerrant.*not yet  Shantay Pass",
            tooltip
        )
        assert.are.same({}, h.ui:popups())

        stockFeathers(h, "FISHINGSHOP2", 20)
        stockFeathers(h, "FISHINGSHOP2", 0)
        h:advance(20)
        assert.is_true(ticked(h, FEATHERS.name))
        assert.are.equal("Feather Shop Run (2/2)", (rowShown(h, FEATHERS.name)))
        assert.matches("%[CHORES%] celebrate feather%-shop%-run", h:output())
        assert.is_true(#h.ui:popups() > 0)
        -- A third shop shows no more than the count.
        stockFeathers(h, "SHANTAYSHOP", 20)
        stockFeathers(h, "SHANTAYSHOP", 0)
        h:advance(20)
        assert.are.equal("Feather Shop Run (2/2)", (rowShown(h, FEATHERS.name)))
    end)

    it("ignores a restock, a sale, an unrelated inventory, and a shop opened and closed", function()
        local h = loaded()
        togglePicks(h, { FEATHERS.id })
        local win, writes = window(h), h.dbWrites
        stockFeathers(h, "FISHINGSHOP", 20)
        stockFeathers(h, "FISHINGSHOP", 25) -- restocked
        h.world:setInventory("FISHINGSHOP", {
            { obj = "FEATHER_PACK", count = 25 },
            { obj = "FISHING_BAIT", count = 100 },
            { obj = "FEATHER", count = 50 }, -- the player sold some
        }, 4)
        h.world:setInventory("BANK", { { obj = "COINS", count = 5 } }, 10)
        h.world:setInventory("BANK", { { obj = "COINS", count = 1 } }, 10)
        h.world:removeInventory("FISHINGSHOP")
        h:advance(100)
        assert.are.equal(writes, h.dbWrites)
        assert.are.equal(win, window(h))
        assert.is_false(ticked(h, FEATHERS.name))
        assert.are.equal("Feather Shop Run (0/4)", (rowShown(h, FEATHERS.name)))
        assert.is_nil(h:output():find("purchase", 1, true))
    end)

    it("counts a second shop of the same chore, keeping the first tick's minute", function()
        local h = loaded()
        togglePicks(h, { FEATHERS.id })
        helpers.setNeeded(h, FEATHERS.id, 1)
        stockFeathers(h, "FISHINGSHOP", 20)
        stockFeathers(h, "FISHINGSHOP", 19)
        h.world:removeInventory("FISHINGSHOP")
        setClock(h, helpers.NOW + 30)
        stockFeathers(h, "FISHINGSHOP_LUM", 20)
        stockFeathers(h, "FISHINGSHOP_LUM", 10)
        h:advance(20)
        assert.are.equal("Feather Shop Run (1/1)", (rowShown(h, FEATHERS.name)))
        assert.are.equal(helpers.NOW, helpers.doneAt(h, FEATHERS.id))
        assert.are.same(
            { FISHINGSHOP = helpers.NOW, FISHINGSHOP_LUM = helpers.NOW + 30 },
            helpers.stored(h).parts[FEATHERS.id]
        )
        local _, lines = h:output():gsub("%[CHORES%] purchase", "")
        assert.are.equal(2, lines)
    end)

    it("updates a single-shop chore in place: tick and tooltip, no rebuild", function()
        local h = loaded()
        togglePicks(h, { YAK.id })
        local win = window(h)
        helpers.buy(h, "FRISD_YAK_CONTRABAND", "YAK_HIDE", 10, 0)
        h:advance(20)
        assert.are.equal(win, window(h))
        assert.is_true(ticked(h, YAK.name))
        local text, tooltip = rowShown(h, YAK.name)
        assert.are.equal("Yak Hides from Vanligga", text)
        assert.matches("Shops this week %(1/1%):<br>bought  Vanligga, Jatizso", tooltip)
    end)

    it("records a purchase for a chore that isn't picked, shown once it is", function()
        local h = loaded()
        togglePicks(h, { DAILY.id })
        stockFeathers(h, "FISHINGSHOP", 20)
        stockFeathers(h, "FISHINGSHOP", 0)
        assert.are.same({ FISHINGSHOP = helpers.NOW }, helpers.stored(h).parts[FEATHERS.id])
        togglePicks(h, { FEATHERS.id })
        assert.is_false(ticked(h, FEATHERS.name))
        assert.are.equal("Feather Shop Run (1/4)", (rowShown(h, FEATHERS.name)))
        -- Set to one shop, unpicked: the tick waits for the next purchase, and comes then.
        togglePicks(h, { FEATHERS.id })
        helpers.setNeeded(h, FEATHERS.id, 1)
        stockFeathers(h, "FISHINGSHOP", 0) -- the baseline after the last purchase
        stockFeathers(h, "FISHINGSHOP", 20)
        stockFeathers(h, "FISHINGSHOP", 10)
        togglePicks(h, { FEATHERS.id })
        assert.is_true(ticked(h, FEATHERS.name))
        assert.are.equal("Feather Shop Run (1/1)", (rowShown(h, FEATHERS.name)))
    end)

    it("clears the tick and the shop count at the weekly reset", function()
        local h = loaded()
        togglePicks(h, { FEATHERS.id })
        stockFeathers(h, "FISHINGSHOP", 20)
        stockFeathers(h, "FISHINGSHOP", 0)
        h:advance(20)
        local win = window(h)
        setClock(h, helpers.WEDNESDAY - 1)
        h:advance(20)
        assert.are.equal(win, window(h)) -- a clock tick that changes nothing rebuilds nothing
        setClock(h, helpers.WEDNESDAY)
        h:advance(20)
        assert.is_false(ticked(h, FEATHERS.name))
        local text, tooltip = rowShown(h, FEATHERS.name)
        assert.are.equal("Feather Shop Run (0/4)", text)
        assert.matches("Shops this week %(0/4%):<br>not yet  Gerrant, Port Sarim", tooltip)
        h.ui:get("Title", { text = "Weekly  0/1" })
    end)

    it("sees the next purchase after a reload with the shop open", function()
        local h = loaded()
        togglePicks(h, { FEATHERS.id })
        helpers.setNeeded(h, FEATHERS.id, 1)
        stockFeathers(h, "FISHINGSHOP", 20)
        h:reload()
        stockFeathers(h, "FISHINGSHOP", 15)
        h:advance(20)
        assert.is_true(ticked(h, FEATHERS.name))
        assert.are.same({ FISHINGSHOP = helpers.NOW }, helpers.stored(h).parts[FEATHERS.id])
    end)

    it("keeps each character's shop progress apart", function()
        local h = loaded()
        togglePicks(h, { FEATHERS.id })
        stockFeathers(h, "FISHINGSHOP", 20)
        stockFeathers(h, "FISHINGSHOP", 0)
        h.world:removeInventory("FISHINGSHOP")

        h.world:logout()
        h.world:login("Lynx Titan")
        h:advance(POLL_MS)
        togglePicks(h, { FEATHERS.id })
        assert.is_false(ticked(h, FEATHERS.name))
        assert.are.equal("Feather Shop Run (0/4)", (rowShown(h, FEATHERS.name)))
        stockFeathers(h, "FISHINGSHOP2", 20)
        stockFeathers(h, "FISHINGSHOP2", 0)
        assert.are.same(
            { FISHINGSHOP2 = helpers.NOW },
            helpers.stored(h, "Lynx Titan").parts[FEATHERS.id]
        )
        assert.are.same({ FISHINGSHOP = helpers.NOW }, helpers.stored(h).parts[FEATHERS.id])
    end)

    it("ignores a purchase while the clock isn't ready or nobody is logged in", function()
        local h = loaded({ clock = 0 })
        local writes = h.dbWrites
        stockFeathers(h, "FISHINGSHOP", 20)
        stockFeathers(h, "FISHINGSHOP", 0)
        assert.are.equal(writes, h.dbWrites)

        setClock(h, helpers.NOW)
        h.world:logout()
        h:advance(POLL_MS)
        stockFeathers(h, "FISHINGSHOP", 20)
        stockFeathers(h, "FISHINGSHOP", 0)
        assert.are.equal(writes, h.dbWrites)
        assert.is_nil(h:output():find("purchase", 1, true))
        assert.is_nil(helpers.stored(h))
    end)

    it("writes and logs nothing for another purchase at a shop bought from this period", function()
        local h = loaded()
        togglePicks(h, { FEATHERS.id })
        stockFeathers(h, "FISHINGSHOP", 20)
        stockFeathers(h, "FISHINGSHOP", 19)
        h:advance(20)
        local win, writes = window(h), h.dbWrites
        stockFeathers(h, "FISHINGSHOP", 18)
        stockFeathers(h, "FISHINGSHOP", 10)
        h:advance(20)
        assert.are.equal(writes, h.dbWrites)
        assert.are.equal(win, window(h))
        assert.are.equal("Feather Shop Run (1/4)", (rowShown(h, FEATHERS.name)))
        local _, lines = h:output():gsub("%[CHORES%] purchase", "")
        assert.are.equal(1, lines)
    end)

    it(
        "changes a count in place, keeping the window and its scroll; a view switch doesn't",
        function()
            local h = loaded()
            togglePicks(h, { DAILY.id, FEATHERS.id, YAK.id })
            -- Short enough that the list overflows and can scroll.
            h.ui:resize(window(h), 0, -260)
            -- Scrolled, but not so far that the settings button (content y 12-32) leaves the
            -- view: it is clicked below.
            window(h):SetScrollPosition(20)
            local win = window(h)
            assert.are.equal(20, win._scroll.scrollY)
            stockFeathers(h, "FISHINGSHOP", 20)
            stockFeathers(h, "FISHINGSHOP", 0)
            h:advance(20)
            assert.are.equal(win, window(h))
            assert.are.equal("Feather Shop Run (1/4)", helpers.row(h, FEATHERS.name).text)
            assert.are.equal(20, window(h)._scroll.scrollY)

            helpers.openSettings(h)
            assert.are.equal(0, window(h)._scroll.scrollY)
        end
    )

    it("counts a shop with two inventories as one, whichever is bought from", function()
        local h = loaded()
        togglePicks(h, { "rune-shop-run" })
        helpers.buy(h, "LUNAR_RUNESHOP_COMPL", "AIRRUNE", 7000, 6000)
        h.world:removeInventory("LUNAR_RUNESHOP_COMPL")
        helpers.buy(h, "LUNAR_RUNESHOP", "AIRRUNE", 7000, 6000)
        h:advance(20)
        assert.are.equal("Rune Shop Run (1/11)", (rowShown(h, "Rune Shop Run")))
        local _, tooltip = rowShown(h, "Rune Shop Run")
        assert.matches("bought  Baba Yaga, Lunar Isle", tooltip)
        assert.matches("purchase rune%-shop%-run at Baba Yaga, Lunar Isle", h:output())
    end)

    it("ticks on a purchase at an unproven shop as at a proven one", function()
        local h = loaded()
        togglePicks(h, { "meat-packs", "rune-shop-run" })
        helpers.setNeeded(h, "rune-shop-run", 1)
        helpers.buy(h, "AFR_MEATSHOP", "LOGS", 5, 4)
        helpers.buy(h, "PEST_RUNE_STORE", "AIRRUNE", 7000, 0)
        h:advance(20)
        assert.is_true(ticked(h, "Meat Packs from Chargurr"))
        assert.is_true(ticked(h, "Rune Shop Run"))
        assert.are.equal("Rune Shop Run (1/1)", (rowShown(h, "Rune Shop Run")))
        assert.matches("%[CHORES%] purchase meat%-packs at Chargurr, Oo'glog", h:output())
        assert.matches("%[CHORES%] purchase rune%-shop%-run at Void Knight Magic Store", h:output())
    end)

    it("loads a version 1 state with its picks and ticks", function()
        local h = loaded()
        h:unload()
        helpers.seed(h, "state:Zezima", {
            version = 1,
            selected = { FEATHERS.id },
            done = { [FEATHERS.id] = helpers.NOW },
        })
        h:load()
        assert.is_true(ticked(h, FEATHERS.name))
        assert.are.equal("Feather Shop Run (0/4)", (rowShown(h, FEATHERS.name)))
        stockFeathers(h, "FISHINGSHOP", 20)
        stockFeathers(h, "FISHINGSHOP", 0)
        h:advance(20)
        assert.are.equal("Feather Shop Run (1/4)", (rowShown(h, FEATHERS.name)))
        assert.are.equal(4, helpers.stored(h).version)
    end)

    it("ticks Seaweed and Pineapples on a purchase at his shop", function()
        local h = loaded()
        local function stock(seaweed)
            h.world:setInventory("ARHEINSTORE", {
                { obj = "SEAWEED", count = seaweed },
                { obj = "PINEAPPLE", count = 50 },
            }, 10)
        end
        stock(50)
        stock(0)
        assert.are.equal(helpers.NOW, doneAt(h, "seaweed-and-pineapples"))
        assert.matches(
            "%[CHORES%] purchase seaweed%-and%-pineapples at Arhein, Catherby",
            h:output()
        )
    end)
end)

-- Logged in at the tile given (the clock at `opts.clock`, logged out with `opts.login`
-- false), with `notes` x10 in the backpack, the chore `id` picked.
---@param id string
---@param notes string
---@param x integer
---@param z integer
---@param level integer?
---@param opts table?
---@return table
local function collectorAt(id, notes, x, z, level, opts)
    local h = helpers.loaded({ load = false })
    h.world:setPosition(x, z, level)
    h.world:setInventory("INV", {
        { obj = notes, count = 10 },
        { obj = "COINS", count = 500 },
    }, 28)
    h:load()
    togglePicks(h, { id })
    if opts and opts.clock then setClock(h, opts.clock) end
    if opts and opts.login == false then
        h.world:logout()
        h:advance(POLL_MS)
    end
    return h
end

-- The backpack's `notes` rise from 10 to 40.
---@param h table
---@param notes string
local function gain(h, notes)
    h.world:setInventory("INV", {
        { obj = notes, count = 40 },
        { obj = "COINS", count = 500 },
    }, 28)
end

local COLLECTORS = {
    {
        chore = "dellmonti-pineapples",
        name = "Pineapples and Apples from Dell Monti",
        npc = "Dell Monti",
        notes = "CERT_PINEAPPLE",
        x = 2763,
        z = 3186,
    },
    {
        chore = "oldman-potato-cactus",
        name = "Potato Cactus from Weird Old Man",
        npc = "the Weird Old Man",
        notes = "CERT_CACTUS_POTATO",
        x = 3232,
        z = 3108,
    },
}

describe("chore-tracker collections", function()
    for _, c in ipairs(COLLECTORS) do
        it("ticks " .. c.chore .. " when its notes arrive near " .. c.npc, function()
            local h = collectorAt(c.chore, c.notes, c.x - 10, c.z + 10)
            local writes = h.dbWrites
            gain(h, c.notes)
            assert.is_true(ticked(h, c.name))
            assert.are.equal(writes + 1, h.dbWrites)
            assert.matches(
                "%[CHORES%] collected " .. c.chore:gsub("%-", "%%-") .. " near " .. c.npc,
                h:output()
            )
        end)

        it(
            "writes and logs nothing for " .. c.chore .. "'s second rise in the same period",
            function()
                local h = collectorAt(c.chore, c.notes, c.x, c.z)
                gain(h, c.notes)
                local writes = h.dbWrites
                h.world:setInventory("INV", { { obj = c.notes, count = 99 } }, 28)
                assert.are.equal(writes, h.dbWrites)
                local _, lines = h:output():gsub("collected", "")
                assert.are.equal(1, lines)
            end
        )

        it("ticks " .. c.chore .. " when another note arrives alongside its notes", function()
            local h = collectorAt(c.chore, c.notes, c.x, c.z)
            local writes = h.dbWrites
            h.world:setInventory("INV", {
                { obj = c.notes, count = 40 },
                { obj = "COINS", count = 500 },
                { obj = "CERT_COOKING_APPLE", count = 30 },
            }, 28)
            assert.is_true(ticked(h, c.name))
            assert.are.equal(writes + 1, h.dbWrites)
        end)

        it(
            "ignores " .. c.chore .. " when notes leave the backpack or other items arrive",
            function()
                local h = collectorAt(c.chore, c.notes, c.x, c.z)
                local writes = h.dbWrites
                h.world:setInventory("INV", { { obj = c.notes, count = 1 } }, 28)
                h.world:setInventory("INV", {
                    { obj = c.notes, count = 1 },
                    { obj = "LOGS", count = 1 },
                }, 28)
                assert.is_false(ticked(h, c.name))
                assert.are.equal(writes, h.dbWrites)
            end
        )

        it("ignores " .. c.chore .. "'s notes further away or on another plane", function()
            for _, at in ipairs({ { c.x + 11, c.z, 0 }, { c.x, c.z - 11, 0 }, { c.x, c.z, 1 } }) do
                local h = collectorAt(c.chore, c.notes, at[1], at[2], at[3])
                local writes = h.dbWrites
                gain(h, c.notes)
                assert.is_false(ticked(h, c.name))
                assert.are.equal(writes, h.dbWrites)
                assert.is_nil(h:output():find("collected", 1, true))
            end
        end)

        it("ignores " .. c.chore .. " without a clock or logged out", function()
            for _, opts in ipairs({ { clock = 0 }, { login = false } }) do
                local h = collectorAt(c.chore, c.notes, c.x, c.z, 0, opts)
                local writes = h.dbWrites
                gain(h, c.notes)
                assert.are.equal(writes, h.dbWrites)
                assert.is_nil(h:output():find("collected", 1, true))
            end
        end)
    end

    it("re-baselines on a backpack that closes and returns with more notes, not ticking", function()
        local c = COLLECTORS[1]
        local h = collectorAt(c.chore, c.notes, c.x, c.z)
        local writes = h.dbWrites
        -- The backpack goes (10 notes) and comes back with 40, standing at the giver: a rise
        -- against nothing the plugin kept, so only a baseline.
        h.world:removeInventory("INV")
        gain(h, c.notes)
        assert.is_false(ticked(h, c.name))
        assert.are.equal(writes, h.dbWrites)
        assert.is_nil(h:output():find("collected", 1, true))
        assert.is_nil(h:output():find("fault", 1, true))
        -- The detector is live: a rise from that baseline ticks.
        h.world:setInventory("INV", { { obj = c.notes, count = 99 } }, 28)
        assert.is_true(ticked(h, c.name))
        assert.are.equal(writes + 1, h.dbWrites)
    end)
end)
