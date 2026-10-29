-- core/state: selection, completion across resets, and the persisted shape.

local support = require("tests.chore-tracker.support")
local state = require("core/state")
local M = support.MINUTES

describe("chore-tracker state", function()
    local chores, byId
    before_each(function()
        chores = support.chores()
        byId = {}
        for _, c in ipairs(chores) do
            byId[c.id] = c
        end
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
            assert.are.same(s, state.deselect(s, "nope"))
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
            local s = state.recordPurchase(state.new(), byId.wshop, "SHOP_A", now)
            assert.are.equal(now, s.shops.wshop.SHOP_A)
            assert.are.equal(now, s.done.wshop)
            assert.is_true(state.shopBought(s, byId.wshop, "SHOP_A", now))
            assert.is_false(state.shopBought(s, byId.wshop, "SHOP_B", now))
            assert.is_true(state.isDone(s, byId.wshop, now))
        end)

        it("keeps an earlier done minute from this period", function()
            local s = state.mark(state.new(), "wshop", now - 60)
            s = state.recordPurchase(s, byId.wshop, "SHOP_A", now)
            s = state.recordPurchase(s, byId.wshop, "SHOP_B", now + 5)
            assert.are.equal(now - 60, s.done.wshop)
            assert.are.same({ SHOP_A = now, SHOP_B = now + 5 }, s.shops.wshop)
        end)

        it("re-marks a chore whose last tick was in an earlier period", function()
            local s = state.recordPurchase(state.new(), byId.wshop, "SHOP_A", M["2026-10-21"])
            s = state.recordPurchase(s, byId.wshop, "SHOP_B", M["2026-10-28"])
            assert.are.equal(M["2026-10-28"], s.done.wshop)
            assert.is_false(state.shopBought(s, byId.wshop, "SHOP_A", M["2026-10-28"]))
            assert.is_true(state.shopBought(s, byId.wshop, "SHOP_B", M["2026-10-28"]))
        end)

        it("gives back the same state for a shop already bought from this period", function()
            local s = state.recordPurchase(state.new(), byId.wshop, "SHOP_A", now)
            assert.are.equal(s, state.recordPurchase(s, byId.wshop, "SHOP_A", now + 5))
            -- Not once the tick is gone, or for another shop.
            local unticked = state.unmark(s, "wshop")
            assert.are_not.equal(
                unticked,
                state.recordPurchase(unticked, byId.wshop, "SHOP_A", now)
            )
            assert.are_not.equal(s, state.recordPurchase(s, byId.wshop, "SHOP_B", now))
        end)

        it("counts a shop as bought only within the chore's period", function()
            local s = state.recordPurchase(state.new(), byId.wshop, "SHOP_A", M["2026-10-21"])
            assert.is_true(state.shopBought(s, byId.wshop, "SHOP_A", M["2026-10-27 23:59"]))
            assert.is_false(state.shopBought(s, byId.wshop, "SHOP_A", M["2026-10-28"]))
        end)

        it(
            "counts a shop as bought from any of its inventories, and none without a clock",
            function()
                local s = state.recordPurchase(state.new(), byId.wshop, "SHOP_B", now)
                assert.is_true(state.shopBoughtAny(s, byId.wshop, { "SHOP_A", "SHOP_B" }, now))
                assert.is_false(state.shopBoughtAny(s, byId.wshop, { "SHOP_A", "SHOP_C" }, now))
                assert.is_false(state.shopBoughtAny(s, byId.wshop, {}, now))
                assert.is_false(state.shopBoughtAny(s, byId.wshop, { "SHOP_B" }, nil))
                assert.is_false(state.shopBoughtAny(s, byId.wshop, { "SHOP_B" }, M["2026-10-28"]))
            end
        )

        it("is not undone by unticking or unpicking, and never changes its input", function()
            local s = state.select(state.new(), chores, "wshop")
            local bought = state.recordPurchase(s, byId.wshop, "SHOP_A", now)
            assert.are.same({}, s.shops)
            assert.is_nil(s.done.wshop)
            local unticked = state.unmark(bought, "wshop")
            assert.is_nil(unticked.done.wshop)
            assert.are.same({ SHOP_A = now }, unticked.shops.wshop)
            local unpicked = state.deselect(bought, "wshop")
            assert.are.same({ SHOP_A = now }, unpicked.shops.wshop)
            assert.are.same({ SHOP_A = now }, state.mark(bought, "wshop", now + 1).shops.wshop)
            assert.are.same({ SHOP_A = now }, state.select(bought, chores, "d1").shops.wshop)
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
        local function picked(ids)
            local s = state.new()
            for _, id in ipairs(ids) do
                s = state.select(s, chores, id)
            end
            return s
        end

        it("moves a chore within its period, leaving other periods' places alone", function()
            local s = picked({ "d1", "w1", "d2", "m1", "dshop" })
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
            local s = picked({ "d1", "w1", "d2" })
            assert.are.same({ "d2", "w1", "d1" }, state.move(s, chores, "d2", -5).selected)
            assert.are.same({ "d2", "w1", "d1" }, state.move(s, chores, "d1", 99).selected)
        end)

        it("gives back the same state for an unselected id or the current place", function()
            local s = picked({ "d1", "w1", "d2" })
            assert.are.equal(s, state.move(s, chores, "d2", 5))
            assert.are.equal(s, state.move(s, chores, "d1", 1))
            assert.are.equal(s, state.move(s, chores, "dshop", 1))
            assert.are.equal(s, state.move(s, chores, "gone", 1))
        end)

        it("gives back the same state for a selected id the chore list no longer has", function()
            -- A stored pick can outlive its chore; with no period it has no group to move in.
            local s = { selected = { "d1", "gone", "d2" }, done = {}, shops = {} }
            assert.are.equal(s, state.move(s, chores, "gone", 1))
        end)

        it("never mutates the state it was given", function()
            local s = picked({ "d1", "d2" })
            state.move(s, chores, "d2", 1)
            assert.are.same({ "d1", "d2" }, s.selected)
        end)
    end)

    describe("serialise", function()
        it("gives version 2, selected ids in the player's order, done and shop minutes", function()
            local s = state.select(state.select(state.new(), chores, "w1"), chores, "d1")
            s = state.mark(s, "w1", 123)
            s = state.recordPurchase(s, byId.wshop, "SHOP_A", 456)
            assert.are.same({
                version = 2,
                selected = { "w1", "d1" },
                done = { w1 = 123, wshop = 456 },
                shops = { wshop = { SHOP_A = 456 } },
            }, state.serialise(s))
        end)

        it("emits only strings, integers and tables", function()
            local s = state.mark(state.select(state.new(), chores, "d1"), "d1", 5)
            s = state.recordPurchase(s, byId.dshop, "SHOP_A", 5)
            s.done.d2 = 1.5 -- a float minute can't come from the clock, but must not be stored
            s.shops.dshop.SHOP_B = 2.5
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
            assert.is_nil(out.shops.dshop.SHOP_B)
        end)

        it("round-trips through deserialise", function()
            local s = state.select(state.select(state.new(), chores, "m1"), chores, "dshop")
            s = state.mark(s, "m1", M["2026-10-25 01:43"])
            s = state.recordPurchase(s, byId.dshop, "SHOP_A", M["2026-10-25 01:43"])
            assert.are.same(s, state.deserialise(state.serialise(s), chores))
        end)
    end)

    describe("deserialise", function()
        local empty = { selected = {}, done = {}, shops = {} }

        it("gives an empty state for nil or a non-table", function()
            assert.are.same(empty, state.deserialise(nil, chores))
            assert.are.same(empty, state.deserialise("x", chores))
            assert.are.same(empty, state.deserialise(7, chores))
        end)

        it("gives an empty state for a missing or unknown version", function()
            local stored = { selected = { "d1" }, done = { d1 = 5 } }
            assert.are.same(empty, state.deserialise(stored, chores))
            stored.version = 3
            assert.are.same(empty, state.deserialise(stored, chores))
            stored.version = "1"
            assert.are.same(empty, state.deserialise(stored, chores))
        end)

        it("keeps only well-formed selected ids that are in the chore list", function()
            local stored = {
                version = 1,
                selected = { "w1", 3, "gone", "d1", true, {}, "w1" },
                done = {},
            }
            assert.are.same({ "w1", "d1" }, state.deserialise(stored, chores).selected)
        end)

        it("round-trips the player's order", function()
            local s = state.select(state.select(state.new(), chores, "m1"), chores, "d1")
            assert.are.same({ "m1", "d1" }, state.deserialise(state.serialise(s), chores).selected)
        end)

        it("keeps only integer done minutes for ids in the chore list", function()
            local stored = {
                version = 1,
                selected = {},
                done = { d1 = 10, d2 = "10", w1 = 2.5, m1 = 7.0, gone = 3, [4] = 4 },
            }
            local got = state.deserialise(stored, chores).done
            assert.are.same({ d1 = 10, m1 = 7 }, got)
            assert.are.equal("integer", math.type(got.m1))
        end)

        it("tolerates selected or done of the wrong type", function()
            local s = state.deserialise({ version = 1, selected = "d1", done = 5 }, chores)
            assert.are.same(empty, s)
            s = state.deserialise({ version = 1, done = { d1 = 1 } }, chores)
            assert.are.same({ selected = {}, done = { d1 = 1 }, shops = {} }, s)
        end)

        it("loads version 1 with its picks and ticks, and no shop progress", function()
            local stored = {
                version = 1,
                selected = { "dshop", "d1" },
                done = { dshop = 9 },
                shops = { dshop = { SHOP_A = 9 } }, -- not part of version 1
            }
            assert.are.same(
                { selected = { "dshop", "d1" }, done = { dshop = 9 }, shops = {} },
                state.deserialise(stored, chores)
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
            local got = state.deserialise(stored, chores)
            assert.are.same({ dshop = { SHOP_A = 10, SHOP_D = 7 } }, got.shops)
            assert.are.same({ "d1" }, got.selected)
            assert.are.same({ d1 = 1 }, got.done)
            assert.are.same({}, state.deserialise({ version = 2, shops = 5 }, chores).shops)
        end)
    end)
end)
