-- core/state: selection, completion across resets, and the persisted shape.

local support = require("tests.chore-tracker.support")
local state = require("core/state")
local M = support.MINUTES

-- One shop with three inventories, so any of them is the chore's one part and a purchase in
-- any ticks it; the two-shop parts TWO are for the needed count, and PATCHES, three parts
-- with a default of 1, for a default below all of them.
---@param list table[]
---@param default integer?
---@return table
local function partsOf(list, default)
    return { noun = "Shops", word = "bought", list = list, default = default }
end
local ONE = partsOf({ { name = "Shop", keys = { "SHOP_A", "SHOP_B", "SHOP_C" } } })
local TWO = partsOf({
    { name = "Shop A", keys = { "SHOP_A" } },
    { name = "Shop B", keys = { "SHOP_B", "SHOP_B2" } },
})
local PATCHES = partsOf({ { keys = { "P1" } }, { keys = { "P2" } }, { keys = { "P3" } } }, 1)
local NONE = partsOf({})

describe("chore-tracker state", function()
    local chores, byId
    before_each(function()
        chores = support.chores()
        byId = support.byId(chores)
    end)

    describe("resolve", function()
        it("gives the chore with the id, and fails naming the source and id on a miss", function()
            assert.are.equal(byId.m1, state.resolve(chores, "m1", "data/x.lua"))
            assert.has_error(function()
                state.resolve(chores, "nochore", "data/x.lua")
            end, "data/x.lua names a chore that data/chores.lua lacks: nochore")
        end)
    end)

    describe("selection", function()
        it("starts empty", function()
            assert.are.same({}, state.new().selected)
        end)

        it("appends each pick, so selected is the order they were picked in", function()
            local s = state.select(state.new(), chores, "m1")
            s = state.select(s, chores, "d1")
            s = state.select(s, chores, "w1")
            assert.are.same({ "m1", "d1", "w1" }, s.selected)
            assert.is_true(state.isSelected(s, "w1"))
            assert.is_false(state.isSelected(s, "d2"))
        end)

        it("puts a deselected then reselected chore last", function()
            local s = state.select(state.select(state.new(), chores, "d1"), chores, "d2")
            s = state.select(state.deselect(s, "d1"), chores, "d1")
            assert.are.same({ "d2", "d1" }, s.selected)
        end)

        it("keeps a chore's completion through a deselect and reselect", function()
            local now = M["2026-10-25 01:43"]
            local s = state.mark(state.select(state.new(), chores, "d1"), "d1", now)
            s = state.select(state.deselect(s, "d1"), chores, "d1")
            assert.is_true(state.isDone(s, byId.d1, now))
            assert.are.equal(now, s.done.d1)
        end)

        it("ignores selecting an id twice", function()
            local s = state.select(state.new(), chores, "d1")
            assert.are.same({ "d1" }, state.select(s, chores, "d1").selected)
        end)

        it("deselects", function()
            local s = state.select(state.select(state.new(), chores, "d1"), chores, "w1")
            assert.are.same({ "w1" }, state.deselect(s, "d1").selected)
        end)

        it("treats an id not in the chore list as a no-op", function()
            local s = state.select(state.new(), chores, "d1")
            assert.are.same(s, state.select(s, chores, "nope"))
            assert.are.equal(s, state.deselect(s, "nope"))
        end)

        it("gives back the same state when selecting an id not in the chore list", function()
            local s = state.select(state.new(), chores, "d1")
            assert.are.equal(s, state.select(s, chores, "nope"))
        end)

        it("never changes the state it is given", function()
            local s = state.new()
            state.select(s, chores, "d1")
            assert.are.same({}, s.selected)
        end)
    end)

    describe("completion", function()
        it("is done once marked, and not after unmarking", function()
            local now = M["2026-10-25 01:43"]
            local s = state.mark(state.new(), "d1", now)
            assert.are.equal(now, s.done.d1)
            assert.is_true(state.isDone(s, byId.d1, now))
            s = state.unmark(s, "d1")
            assert.is_nil(s.done.d1)
            assert.is_false(state.isDone(s, byId.d1, now))
        end)

        it("is not done if never marked", function()
            assert.is_false(state.isDone(state.new(), byId.d1, 0))
        end)

        it("resets a daily chore at the next 00:00 UTC", function()
            local s = state.mark(state.new(), "d1", M["2026-10-27 23:59"] - 60)
            assert.is_true(state.isDone(s, byId.d1, M["2026-10-27 23:59"]))
            assert.is_false(state.isDone(s, byId.d1, M["2026-10-28"]))
        end)

        it("counts a mark at exactly the reset minute as this period's", function()
            local s = state.mark(state.new(), "d1", M["2026-10-28"])
            assert.is_true(state.isDone(s, byId.d1, M["2026-10-28"]))
        end)

        it("keeps a weekly chore done until Wednesday 00:00 UTC", function()
            local s = state.mark(state.new(), "w1", M["2026-10-21"])
            assert.is_true(state.isDone(s, byId.w1, M["2026-10-27 23:59"]))
            assert.is_false(state.isDone(s, byId.w1, M["2026-10-28"]))
        end)

        it("keeps a monthly chore done until the 1st", function()
            local s = state.mark(state.new(), "m1", M["2026-12-01"])
            assert.is_true(state.isDone(s, byId.m1, M["2026-12-31 23:59"]))
            assert.is_false(state.isDone(s, byId.m1, M["2027-01-01"]))
        end)
    end)

    describe("purchases", function()
        local now = M["2026-10-25 01:43"]

        it("auto-marks a chore not done this period, and leaves a done one as it was", function()
            local s = state.autoMark(state.new(), byId.w1, now)
            assert.are.equal(now, s.done.w1)
            assert.are.equal(s, state.autoMark(s, byId.w1, now + 5))
            local later = state.autoMark(s, byId.w1, M["2026-10-28"])
            assert.are.equal(M["2026-10-28"], later.done.w1)
        end)

        it("records the shop and marks the chore done at the purchase minute", function()
            local s = state.recordPart(state.new(), byId.wshop, ONE, "SHOP_A", now)
            assert.are.equal(now, s.parts.wshop.SHOP_A)
            assert.are.equal(now, s.done.wshop)
            assert.is_true(state.keyDone(s, byId.wshop, "SHOP_A", now))
            assert.is_false(state.keyDone(s, byId.wshop, "SHOP_B", now))
            assert.is_true(state.isDone(s, byId.wshop, now))
        end)

        it("keeps an earlier done minute from this period", function()
            local s = state.mark(state.new(), "wshop", now - 60)
            s = state.recordPart(s, byId.wshop, ONE, "SHOP_A", now)
            s = state.recordPart(s, byId.wshop, ONE, "SHOP_B", now + 5)
            assert.are.equal(now - 60, s.done.wshop)
            assert.are.same({ SHOP_A = now, SHOP_B = now + 5 }, s.parts.wshop)
        end)

        it("re-marks a chore whose last tick was in an earlier period", function()
            local s = state.recordPart(state.new(), byId.wshop, ONE, "SHOP_A", M["2026-10-21"])
            s = state.recordPart(s, byId.wshop, ONE, "SHOP_B", M["2026-10-28"])
            assert.are.equal(M["2026-10-28"], s.done.wshop)
            assert.is_false(state.keyDone(s, byId.wshop, "SHOP_A", M["2026-10-28"]))
            assert.is_true(state.keyDone(s, byId.wshop, "SHOP_B", M["2026-10-28"]))
        end)

        it("gives back the same state for a shop already bought from this period", function()
            local s = state.recordPart(state.new(), byId.wshop, ONE, "SHOP_A", now)
            assert.are.equal(s, state.recordPart(s, byId.wshop, ONE, "SHOP_A", now + 5))
            -- Not once the tick is gone, or for another shop.
            local unticked = state.unmark(s, "wshop")
            assert.are_not.equal(
                unticked,
                state.recordPart(unticked, byId.wshop, ONE, "SHOP_A", now)
            )
            assert.are_not.equal(s, state.recordPart(s, byId.wshop, ONE, "SHOP_B", now))
        end)

        it("counts a shop as bought only within the chore's period", function()
            local s = state.recordPart(state.new(), byId.wshop, ONE, "SHOP_A", M["2026-10-21"])
            assert.is_true(state.keyDone(s, byId.wshop, "SHOP_A", M["2026-10-27 23:59"]))
            assert.is_false(state.keyDone(s, byId.wshop, "SHOP_A", M["2026-10-28"]))
        end)

        it("counts a shop as bought from any of its inventories", function()
            local s = state.recordPart(state.new(), byId.wshop, ONE, "SHOP_B", now)
            assert.is_true(state.partDone(s, byId.wshop, { keys = { "SHOP_A", "SHOP_B" } }, now))
            assert.is_false(state.partDone(s, byId.wshop, { keys = { "SHOP_A", "SHOP_C" } }, now))
            assert.is_false(state.partDone(s, byId.wshop, { keys = {} }, now))
            assert.is_false(state.partDone(s, byId.wshop, { keys = { "SHOP_B" } }, M["2026-10-28"]))
        end)

        it("is not undone by unticking or unpicking, and never changes its input", function()
            local s = state.select(state.new(), chores, "wshop")
            local bought = state.recordPart(s, byId.wshop, ONE, "SHOP_A", now)
            assert.are.same({}, s.parts)
            assert.is_nil(s.done.wshop)
            local unticked = state.unmark(bought, "wshop")
            assert.is_nil(unticked.done.wshop)
            assert.are.same({ SHOP_A = now }, unticked.parts.wshop)
            local unpicked = state.deselect(bought, "wshop")
            assert.are.same({ SHOP_A = now }, unpicked.parts.wshop)
            assert.are.same({ SHOP_A = now }, state.mark(bought, "wshop", now + 1).parts.wshop)
            assert.are.same({ SHOP_A = now }, state.select(bought, chores, "d1").parts.wshop)
        end)
    end)

    describe("shops needed", function()
        local now = M["2026-10-25 01:43"]

        it("defaults to all listed shops, and clamps a set count to 1..#listed", function()
            local s = state.new()
            assert.are.equal(2, state.partsNeeded(s, byId.wshop, TWO))
            assert.are.equal(1, state.partsNeeded(s, byId.wshop, ONE))
            s.needed.wshop = 5
            assert.are.equal(2, state.partsNeeded(s, byId.wshop, TWO))
            s.needed.wshop = -3
            assert.are.equal(1, state.partsNeeded(s, byId.wshop, TWO))
            -- A chore without shops needs none, even with a count left over from a longer list.
            assert.are.equal(0, state.partsNeeded(s, byId.wshop, NONE))
            assert.are.equal(0, state.partsNeeded(state.new(), byId.wshop, NONE))
        end)

        it("sets a count, clamped, holding only one short of all, and never ticks", function()
            local s = state.new()
            local one = state.setPartsNeeded(s, byId.wshop, TWO, 1)
            assert.are.same({ wshop = 1 }, one.needed)
            assert.are.same({}, s.needed)
            assert.are.equal(one, state.setPartsNeeded(one, byId.wshop, TWO, 0))
            assert.are.equal(s, state.setPartsNeeded(s, byId.wshop, TWO, 3))
            assert.are.same({}, state.setPartsNeeded(one, byId.wshop, TWO, 2).needed)
            -- Lowered to what was already bought, the chore stays unticked.
            local bought = state.recordPart(s, byId.wshop, TWO, "SHOP_A", now)
            assert.is_false(
                state.isDone(state.setPartsNeeded(bought, byId.wshop, TWO, 1), byId.wshop, now)
            )
        end)

        it("counts distinct listed shops bought, a shop with two inventories once", function()
            local s = state.recordPart(state.new(), byId.wshop, TWO, "SHOP_B", now)
            s = state.recordPart(s, byId.wshop, TWO, "SHOP_B2", now)
            assert.are.equal(1, state.partsDone(s, byId.wshop, TWO, now))
            assert.is_false(state.isDone(s, byId.wshop, now))
            assert.are.equal(0, state.partsDone(s, byId.wshop, TWO, M["2026-10-28"]))
        end)

        it("ticks only once the count of shops is bought from this period", function()
            local s = state.recordPart(state.new(), byId.wshop, TWO, "SHOP_A", now)
            assert.are.same({ SHOP_A = now }, s.parts.wshop)
            assert.is_false(state.isDone(s, byId.wshop, now))
            s = state.recordPart(s, byId.wshop, TWO, "SHOP_B", now + 5)
            assert.are.equal(now + 5, s.done.wshop)
            -- With a count of 1, the first purchase ticks.
            local one = state.setPartsNeeded(state.new(), byId.wshop, TWO, 1)
            assert.are.equal(now, state.recordPart(one, byId.wshop, TWO, "SHOP_B2", now).done.wshop)
        end)

        it(
            "re-judges a repeat purchase: it ticks once the count is met, else changes nothing",
            function()
                local s = state.recordPart(state.new(), byId.wshop, TWO, "SHOP_A", now)
                assert.are.equal(s, state.recordPart(s, byId.wshop, TWO, "SHOP_A", now + 1))
                -- The count lowered to what was bought: the next purchase, even a repeat, ticks.
                local lowered = state.setPartsNeeded(s, byId.wshop, TWO, 1)
                assert.are.equal(
                    now + 2,
                    state.recordPart(lowered, byId.wshop, TWO, "SHOP_A", now + 2).done.wshop
                )
                -- Unticked by hand with the count met: a repeat purchase ticks it again.
                local full = state.recordPart(s, byId.wshop, TWO, "SHOP_B", now + 3)
                local unticked = state.unmark(full, "wshop")
                assert.are.equal(
                    now + 4,
                    state.recordPart(unticked, byId.wshop, TWO, "SHOP_B2", now + 4).done.wshop
                )
            end
        )

        it(
            "needs the parts' default until a count is set, holding only one other than it",
            function()
                local s = state.new()
                assert.are.equal(1, state.partsNeeded(s, byId.wshop, PATCHES))
                -- A default above the list's size reads clamped.
                assert.are.equal(2, state.partsNeeded(s, byId.wshop, partsOf(TWO.list, 5)))
                local three = state.setPartsNeeded(s, byId.wshop, PATCHES, 3)
                assert.are.same({ wshop = 3 }, three.needed)
                assert.are.same({}, state.setPartsNeeded(three, byId.wshop, PATCHES, 1).needed)
                -- The default ticks on the first part.
                local now2 = M["2026-10-25 01:43"]
                local s2 = state.recordPart(s, byId.wshop, PATCHES, "P2", now2)
                assert.are.equal(now2, s2.done.wshop)
                assert.is_false(
                    state.isDone(
                        state.recordPart(three, byId.wshop, PATCHES, "P2", now2),
                        byId.wshop,
                        now2
                    )
                )
            end
        )

        it("leaves a tick alone when the count is raised above what was bought", function()
            local s = state.setPartsNeeded(state.new(), byId.wshop, TWO, 1)
            s = state.recordPart(s, byId.wshop, TWO, "SHOP_A", now)
            local raised = state.setPartsNeeded(s, byId.wshop, TWO, 2)
            assert.is_true(state.isDone(raised, byId.wshop, now))
            assert.are.equal(now, raised.done.wshop)
        end)
    end)

    describe("selectedIn", function()
        it("lists one period's picks in selected order with their places in selected", function()
            local s = state.new()
            for _, id in ipairs({ "d2", "w1", "d1", "gone" }) do
                s = state.select(s, chores, id)
            end
            s.selected[#s.selected + 1] = "gone"
            local ids, slots = state.selectedIn(s, chores, "daily")
            assert.are.same({ "d2", "d1" }, ids)
            assert.are.same({ 1, 3 }, slots)
        end)

        it("is empty for a period with no picks", function()
            local ids, slots = state.selectedIn(state.new(), chores, "daily")
            assert.are.same({}, ids)
            assert.are.same({}, slots)
        end)
    end)

    describe("move", function()
        it("moves a chore within its period, leaving other periods' places alone", function()
            local s = support.stateWith(chores, { "d1", "w1", "d2", "m1", "dshop" })
            assert.are.same(
                { "dshop", "w1", "d1", "m1", "d2" },
                state.move(s, chores, "dshop", 1).selected
            )
            assert.are.same(
                { "d2", "w1", "d1", "m1", "dshop" },
                state.move(s, chores, "d1", 2).selected
            )
        end)

        it("clamps the index to the period's range", function()
            local s = support.stateWith(chores, { "d1", "w1", "d2" })
            assert.are.same({ "d2", "w1", "d1" }, state.move(s, chores, "d2", -5).selected)
            assert.are.same({ "d2", "w1", "d1" }, state.move(s, chores, "d1", 99).selected)
        end)

        it("gives back the same state for an unselected id or the current place", function()
            local s = support.stateWith(chores, { "d1", "w1", "d2" })
            assert.are.equal(s, state.move(s, chores, "d2", 5))
            assert.are.equal(s, state.move(s, chores, "d1", 1))
            assert.are.equal(s, state.move(s, chores, "dshop", 1))
            assert.are.equal(s, state.move(s, chores, "gone", 1))
        end)

        it("gives back the same state for a selected id the chore list no longer has", function()
            -- A stored pick can outlive its chore; with no period it has no group to move in.
            local s = { selected = { "d1", "gone", "d2" }, done = {}, parts = {} }
            assert.are.equal(s, state.move(s, chores, "gone", 1))
        end)

        it("never mutates the state it was given", function()
            local s = support.stateWith(chores, { "d1", "d2" })
            state.move(s, chores, "d2", 1)
            assert.are.same({ "d1", "d2" }, s.selected)
        end)
    end)

    describe("serialise", function()
        it("gives version 4: picks in the player's order, done and part minutes, counts", function()
            local s = state.select(state.select(state.new(), chores, "w1"), chores, "d1")
            s = state.mark(s, "w1", 123)
            s = state.recordPart(s, byId.wshop, ONE, "SHOP_A", 456)
            s = state.setPartsNeeded(s, byId.dshop, TWO, 1)
            assert.are.same({
                version = 4,
                selected = { "w1", "d1" },
                done = { w1 = 123, wshop = 456 },
                parts = { wshop = { SHOP_A = 456 } },
                needed = { dshop = 1 },
            }, state.serialise(s))
        end)

        it("emits only strings, integers and tables", function()
            local s = state.mark(state.select(state.new(), chores, "d1"), "d1", 5)
            s = state.recordPart(s, byId.dshop, ONE, "SHOP_A", 5)
            s.done.d2 = 1.5 -- a float minute can't come from the clock, but must not be stored
            s.parts.dshop.SHOP_B = 2.5
            ---@param v any
            local function check(v)
                if type(v) == "table" then
                    for k, x in pairs(v) do
                        check(k)
                        check(x)
                    end
                else
                    assert(type(v) == "string" or math.type(v) == "integer", tostring(v))
                end
            end
            local out = state.serialise(s)
            check(out)
            assert.is_nil(out.done.d2)
            assert.is_nil(out.parts.dshop.SHOP_B)
        end)

        it("round-trips through fromStored", function()
            local s = state.select(state.select(state.new(), chores, "m1"), chores, "dshop")
            s = state.mark(s, "m1", M["2026-10-25 01:43"])
            s = state.recordPart(s, byId.dshop, ONE, "SHOP_A", M["2026-10-25 01:43"])
            s = state.setPartsNeeded(s, byId.wshop, TWO, 1)
            assert.are.same(s, state.fromStored(state.serialise(s), chores))
        end)
    end)

    describe("fromStored", function()
        local empty = { selected = {}, done = {}, parts = {}, needed = {} }

        it("gives an empty state for nil or a non-table", function()
            assert.are.same(empty, state.fromStored(nil, chores))
            assert.are.same(empty, state.fromStored("x", chores))
            assert.are.same(empty, state.fromStored(7, chores))
        end)

        it("gives an empty state for a missing or unknown version", function()
            local stored = { selected = { "d1" }, done = { d1 = 5 } }
            assert.are.same(empty, state.fromStored(stored, chores))
            stored.version = 5
            assert.are.same(empty, state.fromStored(stored, chores))
            stored.version = "1"
            assert.are.same(empty, state.fromStored(stored, chores))
        end)

        it("keeps only well-formed selected ids that are in the chore list", function()
            local stored = {
                version = 1,
                selected = { "w1", 3, "gone", "d1", true, {}, "w1" },
                done = {},
            }
            assert.are.same({ "w1", "d1" }, state.fromStored(stored, chores).selected)
        end)

        it("round-trips the player's order", function()
            local s = state.select(state.select(state.new(), chores, "m1"), chores, "d1")
            assert.are.same({ "m1", "d1" }, state.fromStored(state.serialise(s), chores).selected)
        end)

        it("keeps only integer done minutes for ids in the chore list", function()
            local stored = {
                version = 1,
                selected = {},
                done = { d1 = 10, d2 = "10", w1 = 2.5, m1 = 7.0, gone = 3, [4] = 4 },
            }
            local got = state.fromStored(stored, chores).done
            assert.are.same({ d1 = 10, m1 = 7 }, got)
            assert.are.equal("integer", math.type(got.m1))
        end)

        it("tolerates selected or done of the wrong type", function()
            local s = state.fromStored({ version = 1, selected = "d1", done = 5 }, chores)
            assert.are.same(empty, s)
            s = state.fromStored({ version = 1, done = { d1 = 1 } }, chores)
            assert.are.same({ selected = {}, done = { d1 = 1 }, parts = {}, needed = {} }, s)
        end)

        it("loads version 1 with its picks and ticks, and no shop progress", function()
            local stored = {
                version = 1,
                selected = { "dshop", "d1" },
                done = { dshop = 9 },
                shops = { dshop = { SHOP_A = 9 } }, -- not part of version 1
            }
            assert.are.same(
                { selected = { "dshop", "d1" }, done = { dshop = 9 }, parts = {}, needed = {} },
                state.fromStored(stored, chores)
            )
        end)

        it("drops malformed shop progress and keeps the rest", function()
            local stored = {
                version = 2,
                selected = { "d1" },
                done = { d1 = 1 },
                shops = {
                    dshop = { SHOP_A = 10, SHOP_B = "10", SHOP_C = 1.5, SHOP_D = 7.0, [3] = 4 },
                    wshop = "x",
                    gone = { SHOP_A = 1 },
                    m1 = { SHOP_A = "nope" },
                },
            }
            local got = state.fromStored(stored, chores)
            assert.are.same({ dshop = { SHOP_A = 10, SHOP_D = 7 } }, got.parts)
            assert.are.same({ "d1" }, got.selected)
            assert.are.same({ d1 = 1 }, got.done)
            assert.are.same({}, state.fromStored({ version = 2, shops = 5 }, chores).parts)
        end)

        it("loads version 2 with its shop progress and every chore at its default count", function()
            local stored = {
                version = 2,
                selected = { "wshop" },
                done = {},
                shops = { wshop = { SHOP_A = 9 } },
                needed = { wshop = 1 }, -- not part of version 2
            }
            local got = state.fromStored(stored, chores)
            assert.are.same({ wshop = { SHOP_A = 9 } }, got.parts)
            assert.are.same({}, got.needed)
            assert.are.equal(2, state.partsNeeded(got, byId.wshop, TWO))
        end)

        it("keeps whole counts of 1 or more for known chores and drops the rest", function()
            local stored = {
                version = 4,
                selected = {},
                done = {},
                needed = { wshop = 1, dshop = 9, d1 = 0, d2 = 1.5, w1 = "2", m1 = 3.0, gone = 1 },
            }
            local got = state.fromStored(stored, chores)
            assert.are.same({ wshop = 1, dshop = 9, m1 = 3 }, got.needed)
            -- One above the list's size, as after the list shrank, reads clamped.
            assert.are.equal(2, state.partsNeeded(got, byId.dshop, TWO))
            assert.are.same({}, state.fromStored({ version = 4, needed = "x" }, chores).needed)
        end)

        it("loads version 3's shop progress as parts, with its counts", function()
            local stored = {
                version = 3,
                selected = { "wshop" },
                done = {},
                shops = { wshop = { SHOP_A = 9 } },
                needed = { wshop = 1 },
            }
            local got = state.fromStored(stored, chores)
            assert.are.same({ wshop = { SHOP_A = 9 } }, got.parts)
            assert.are.same({ wshop = 1 }, got.needed)
            -- Version 4 keeps its progress as parts, not shops.
            stored.version = 4
            assert.are.same({}, state.fromStored(stored, chores).parts)
        end)
    end)
end)
