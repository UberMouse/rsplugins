-- The Chore Tracker ticking shop runs from shop stock, through the harness: a shop is an
-- inventory the client holds only while it is open, and a line whose count drops is the
-- player buying (docs/api-concepts.md, "Shops in the client").

local harness = require("tests.harness")
local helpers = require("tests.chore-tracker.helpers")
local loaded, row, ticked, pick = helpers.loaded, helpers.row, helpers.ticked, helpers.pick

local FEATHERS = { name = "Feather Shop Run", id = "feather-shop-run" }
local YAK = { name = "Yak Hide", id = "yak-hide" }
local DAILY = { name = "Daily Challenge", id = "daily-challenge" }

-- Half a second: long enough for the plugin's login poll (every 25 Logic ticks).
local POLL_MS = 500

---@param h table
---@param minutes integer
local function setClock(h, minutes)
    h.world:setVar("VarPlayer", "CLOCK_TIME_DATE_MINUTES", minutes)
end

---@param h table
---@return table
local function window(h)
    return h.ui:get("Window", { text = "Chores" })
end

-- Open shop `inv` with one line of `count` feather packs and a line of bait.
---@param h table
---@param inv string
---@param count integer
local function openShop(h, inv, count)
    h.world:setInventory(inv, {
        { obj = "FEATHER_PACK", count = count },
        { obj = "FISHING_BAIT", count = 100 },
    }, 4)
end

-- Set the feather pack line of open shop `inv` (a purchase when it drops).
---@param h table
---@param inv string
---@param count integer
local function setFeathers(h, inv, count)
    openShop(h, inv, count)
end

-- The visible row's text and tooltip text for a chore.
---@param h table
---@param name string
---@return string text
---@return string tooltip
local function rowShown(h, name)
    local choice = h.ui:choices(row(h, name))[1]
    return choice.text, choice.tooltip.text
end

-- The stored shop progress of a character's chore.
---@param h table
---@param id string
---@param who string?
---@return table?
local function stored(h, id, who)
    local entry = h.db["state:" .. (who or "Zezima")]
    return entry and entry.value.shops[id]
end

describe("chore-tracker shop runs", function()
    it("ticks a chore on a purchase at one of its shops and records the shop", function()
        local h = loaded()
        pick(h, { FEATHERS.id })
        openShop(h, "FISHINGSHOP", 20)
        local writes = h.dbWrites
        setFeathers(h, "FISHINGSHOP", 0)
        assert.are.equal(writes + 1, h.dbWrites)
        assert.matches("%[CHORES%] purchase feather%-shop%-run at Gerrant, Port Sarim", h:output())
        assert.are.same({ FISHINGSHOP = helpers.NOW }, stored(h, FEATHERS.id))
        assert.are.equal(helpers.NOW, h.db["state:Zezima"].value.done[FEATHERS.id])

        h:advance(20)
        assert.is_true(ticked(h, FEATHERS.name))
        local text, tooltip = rowShown(h, FEATHERS.name)
        assert.are.equal("Feather Shop Run (1/4)", text)
        assert.matches(
            "Shops this week %(1/4%):<br>bought  Gerrant, Port Sarim<br>"
                .. "not yet  Lumbridge Fishing Supplies<br>not yet  Harry, Catherby<br>"
                .. "not yet  Shantay Pass<br>https://",
            tooltip
        )
        h.ui:get("Title", { text = "Weekly  1/1" })
    end)

    it("ignores a restock, a sale, an unrelated inventory, and a shop opened and closed", function()
        local h = loaded()
        pick(h, { FEATHERS.id })
        local win, writes = window(h), h.dbWrites
        openShop(h, "FISHINGSHOP", 20)
        setFeathers(h, "FISHINGSHOP", 25) -- restocked
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
        pick(h, { FEATHERS.id })
        openShop(h, "FISHINGSHOP", 20)
        setFeathers(h, "FISHINGSHOP", 19)
        h.world:removeInventory("FISHINGSHOP")
        setClock(h, helpers.NOW + 30)
        openShop(h, "FISHINGSHOP_LUM", 20)
        setFeathers(h, "FISHINGSHOP_LUM", 10)
        h:advance(20)
        assert.are.equal("Feather Shop Run (2/4)", (rowShown(h, FEATHERS.name)))
        assert.are.equal(helpers.NOW, h.db["state:Zezima"].value.done[FEATHERS.id])
        assert.are.same(
            { FISHINGSHOP = helpers.NOW, FISHINGSHOP_LUM = helpers.NOW + 30 },
            stored(h, FEATHERS.id)
        )
        local _, lines = h:output():gsub("%[CHORES%] purchase", "")
        assert.are.equal(2, lines)
    end)

    it("updates a single-shop chore in place: tick and tooltip, no rebuild", function()
        local h = loaded()
        pick(h, { YAK.id })
        local win = window(h)
        h.world:setInventory("FRISD_YAK_CONTRABAND", { { obj = "YAK_HIDE", count = 10 } })
        h.world:setInventory("FRISD_YAK_CONTRABAND", { { obj = "YAK_HIDE", count = 0 } })
        h:advance(20)
        assert.are.equal(win, window(h))
        assert.is_true(ticked(h, YAK.name))
        local text, tooltip = rowShown(h, YAK.name)
        assert.are.equal("Yak Hide", text)
        assert.matches("Shops this week %(1/1%):<br>bought  Vanligga, Jatizso", tooltip)
    end)

    it("records a purchase for a chore that isn't picked, shown once it is", function()
        local h = loaded()
        pick(h, { DAILY.id })
        openShop(h, "FISHINGSHOP", 20)
        setFeathers(h, "FISHINGSHOP", 0)
        assert.are.same({ FISHINGSHOP = helpers.NOW }, stored(h, FEATHERS.id))
        pick(h, { FEATHERS.id })
        assert.is_true(ticked(h, FEATHERS.name))
        assert.are.equal("Feather Shop Run (1/4)", (rowShown(h, FEATHERS.name)))
    end)

    it("clears the tick and the shop count at the weekly reset", function()
        local h = loaded()
        pick(h, { FEATHERS.id })
        openShop(h, "FISHINGSHOP", 20)
        setFeathers(h, "FISHINGSHOP", 0)
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
        pick(h, { FEATHERS.id })
        openShop(h, "FISHINGSHOP", 20)
        h:reload()
        setFeathers(h, "FISHINGSHOP", 15)
        h:advance(20)
        assert.is_true(ticked(h, FEATHERS.name))
        assert.are.same({ FISHINGSHOP = helpers.NOW }, stored(h, FEATHERS.id))
    end)

    it("keeps each character's shop progress apart", function()
        local h = loaded()
        pick(h, { FEATHERS.id })
        openShop(h, "FISHINGSHOP", 20)
        setFeathers(h, "FISHINGSHOP", 0)
        h.world:removeInventory("FISHINGSHOP")

        h.world:logout()
        h.world:login("Lynx Titan")
        h:advance(POLL_MS)
        pick(h, { FEATHERS.id })
        assert.is_false(ticked(h, FEATHERS.name))
        assert.are.equal("Feather Shop Run (0/4)", (rowShown(h, FEATHERS.name)))
        openShop(h, "FISHINGSHOP2", 20)
        setFeathers(h, "FISHINGSHOP2", 0)
        assert.are.same({ FISHINGSHOP2 = helpers.NOW }, stored(h, FEATHERS.id, "Lynx Titan"))
        assert.are.same({ FISHINGSHOP = helpers.NOW }, stored(h, FEATHERS.id))
    end)

    it("ignores a purchase while the clock isn't ready or nobody is logged in", function()
        local h = loaded({ clock = 0 })
        local writes = h.dbWrites
        openShop(h, "FISHINGSHOP", 20)
        setFeathers(h, "FISHINGSHOP", 0)
        assert.are.equal(writes, h.dbWrites)

        setClock(h, helpers.NOW)
        h.world:logout()
        h:advance(POLL_MS)
        setFeathers(h, "FISHINGSHOP", 20)
        setFeathers(h, "FISHINGSHOP", 0)
        assert.are.equal(writes, h.dbWrites)
        assert.is_nil(h:output():find("purchase", 1, true))
        assert.is_nil(h.db["state:Zezima"])
    end)

    it("ticks on a purchase at an unproven shop as at a proven one", function()
        local h = loaded()
        pick(h, { "meat-packs", "rune-shop-run" })
        h.world:setInventory("AFR_MEATSHOP", { { obj = "LOGS", count = 5 } })
        h.world:setInventory("AFR_MEATSHOP", { { obj = "LOGS", count = 4 } })
        h.world:setInventory("PEST_RUNE_STORE", { { obj = "AIRRUNE", count = 7000 } })
        h.world:setInventory("PEST_RUNE_STORE", { { obj = "AIRRUNE", count = 0 } })
        h:advance(20)
        assert.is_true(ticked(h, "Meat Packs"))
        assert.is_true(ticked(h, "Rune Shop Run"))
        assert.are.equal("Rune Shop Run (1/9)", (rowShown(h, "Rune Shop Run")))
        assert.matches("%[CHORES%] purchase meat%-packs at Chargurr, Oo'glog", h:output())
        assert.matches("%[CHORES%] purchase rune%-shop%-run at Void Knight Magic Store", h:output())
    end)

    it("loads a version 1 state with its picks and ticks", function()
        local h = loaded()
        h:unload()
        h.db["state:Zezima"] = {
            type = harness.enums.PersistentDBType.STRUCTURED_DATA,
            value = {
                version = 1,
                selected = { FEATHERS.id },
                done = { [FEATHERS.id] = helpers.NOW },
            },
        }
        h:load()
        assert.is_true(ticked(h, FEATHERS.name))
        assert.are.equal("Feather Shop Run (0/4)", (rowShown(h, FEATHERS.name)))
        openShop(h, "FISHINGSHOP", 20)
        setFeathers(h, "FISHINGSHOP", 0)
        h:advance(20)
        assert.are.equal("Feather Shop Run (1/4)", (rowShown(h, FEATHERS.name)))
        assert.are.equal(2, h.db["state:Zezima"].value.version)
    end)
end)

describe("chore-tracker Dell Monti", function()
    local DELL = { name = "Pineapples and Apples from Dell Monti", id = "dellmonti-pineapples" }
    -- His tile, per runescape.wiki/w/Dell_Monti.
    local X, Z = 2763, 3186

    -- Logged in at the tile given, with some of his notes in the backpack, Dell Monti's
    -- chore picked.
    ---@param x integer
    ---@param z integer
    ---@param level integer?
    ---@return table
    local function standingAt(x, z, level)
        local h = helpers.loaded({ load = false })
        h.world:setPosition(x, z, level)
        h.world:setInventory("INV", {
            { obj = "CERT_PINEAPPLE", count = 10 },
            { obj = "COINS", count = 500 },
        }, 28)
        h:load()
        pick(h, { DELL.id })
        return h
    end

    -- Dell Monti hands over notes: the backpack's apple and pineapple notes go up.
    ---@param h table
    local function collect(h)
        h.world:setInventory("INV", {
            { obj = "CERT_PINEAPPLE", count = 40 },
            { obj = "COINS", count = 500 },
            { obj = "CERT_COOKING_APPLE", count = 30 },
        }, 28)
    end

    it("ticks when his notes arrive near him, once a period", function()
        local h = standingAt(X + 10, Z - 10)
        local writes = h.dbWrites
        collect(h)
        assert.is_true(ticked(h, DELL.name))
        assert.are.equal(writes + 1, h.dbWrites)
        assert.matches("%[CHORES%] collected dellmonti%-pineapples near Dell Monti", h:output())
        -- More notes the same week change nothing stored.
        h.world:setInventory("INV", { { obj = "CERT_PINEAPPLE", count = 99 } }, 28)
        assert.are.equal(writes + 1, h.dbWrites)
    end)

    it("ignores his notes arriving further away or on another plane", function()
        for _, at in ipairs({ { X + 11, Z, 0 }, { X, Z - 11, 0 }, { X, Z, 1 } }) do
            local h = standingAt(at[1], at[2], at[3])
            local writes = h.dbWrites
            collect(h)
            assert.is_false(ticked(h, DELL.name))
            assert.are.equal(writes, h.dbWrites)
            assert.is_nil(h:output():find("collected", 1, true))
        end
    end)

    it("ignores notes leaving the backpack, and other items arriving", function()
        local h = standingAt(X, Z)
        local writes = h.dbWrites
        h.world:setInventory("INV", { { obj = "CERT_PINEAPPLE", count = 1 } }, 28)
        h.world:setInventory("INV", {
            { obj = "CERT_PINEAPPLE", count = 1 },
            { obj = "LOGS", count = 1 },
        }, 28)
        assert.is_false(ticked(h, DELL.name))
        assert.are.equal(writes, h.dbWrites)
    end)
end)
