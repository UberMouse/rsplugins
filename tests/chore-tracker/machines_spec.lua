-- The Chore Tracker ticking the Invention machine chores when machines' output is collected,
-- through the harness: an output inventory whose total falls is a collect (data/machines.lua),
-- and each machine collected from is a part, two of which tick the chores by default
-- (data/counts.lua).

local helpers = require("tests.chore-tracker.helpers")
local loaded, ticked, togglePicks, doneAt =
    helpers.loaded, helpers.ticked, helpers.togglePicks, helpers.doneAt

local DAILY = { name = "Invention Machines", id = "invention-machine" }
local WEEKLY = "invention-machine-weekly"
local OUTPUT = "INVENT_MACHINE_GUILD_3_OUTPUT"
local OTHER = "INVENT_MACHINE_GUILD_5_OUTPUT"

describe("chore-tracker invention machines", function()
    it("ticks both periods' chores once two machines' output is collected", function()
        local h = loaded()
        togglePicks(h, { DAILY.id })
        helpers.stock(h, OUTPUT, "WOODPLANK", 7500)
        helpers.stock(h, OTHER, "WOODPLANK", 300)
        h:advance(20)
        assert.is_nil(doneAt(h, DAILY.id))
        h.world:setInventory(OUTPUT, {}, 4)
        h:advance(20)
        assert.matches("%[CHORES%] collected invention%-machine from " .. OUTPUT, h:output())
        assert.matches(
            "%[CHORES%] collected invention%-machine%-weekly from " .. OUTPUT,
            h:output()
        )
        -- One machine of the default two: counted, not ticked.
        assert.is_nil(doneAt(h, DAILY.id))
        assert.are.equal("Invention Machines (1/2)", (helpers.rowShown(h, DAILY.name)))
        h.world:setInventory(OTHER, {}, 4)
        h:advance(20)
        assert.is_true(ticked(h, DAILY.name))
        assert.are.equal(helpers.NOW, doneAt(h, WEEKLY))
    end)

    it("doesn't tick while a machine works, or for another inventory falling", function()
        local h = loaded()
        helpers.stock(h, OUTPUT, "WOODPLANK", 10)
        helpers.stock(h, OUTPUT, "WOODPLANK", 40)
        helpers.stock(h, "INVENT_MACHINE_GUILD_3_INPUT", "LOGS", 100)
        helpers.stock(h, "INVENT_MACHINE_GUILD_3_INPUT", "LOGS", 0)
        h:advance(20)
        assert.is_nil(doneAt(h, DAILY.id))
        assert.is_nil(doneAt(h, WEEKLY))
        assert.is_nil(h:output():find("collected", 1, true))
    end)
end)
