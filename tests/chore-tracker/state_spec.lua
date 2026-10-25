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

        it("keeps selected ids in chore-list order, whatever order they were picked in", function()
            local s = state.select(state.new(), chores, "m1")
            s = state.select(s, chores, "d1")
            s = state.select(s, chores, "w1")
            assert.are.same({ "d1", "w1", "m1" }, s.selected)
            assert.is_true(state.isSelected(s, "w1"))
            assert.is_false(state.isSelected(s, "d2"))
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

    describe("serialise", function()
        it("gives version 1, selected ids in chore-list order, and done minutes", function()
            local s = state.select(state.select(state.new(), chores, "w1"), chores, "d1")
            s = state.mark(s, "w1", 123)
            assert.are.same(
                { version = 1, selected = { "d1", "w1" }, done = { w1 = 123 } },
                state.serialise(s)
            )
        end)

        it("emits only strings, integers and tables", function()
            local s = state.mark(state.select(state.new(), chores, "d1"), "d1", 5)
            s.done.d2 = 1.5 -- a float minute can't come from the clock, but must not be stored
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
        end)

        it("round-trips through deserialise", function()
            local s = state.select(state.select(state.new(), chores, "m1"), chores, "dshop")
            s = state.mark(s, "m1", M["2026-10-25 01:43"])
            assert.are.same(s, state.deserialise(state.serialise(s), chores))
        end)
    end)

    describe("deserialise", function()
        local empty = { selected = {}, done = {} }

        it("gives an empty state for nil or a non-table", function()
            assert.are.same(empty, state.deserialise(nil, chores))
            assert.are.same(empty, state.deserialise("x", chores))
            assert.are.same(empty, state.deserialise(7, chores))
        end)

        it("gives an empty state for a missing or unknown version", function()
            local stored = { selected = { "d1" }, done = { d1 = 5 } }
            assert.are.same(empty, state.deserialise(stored, chores))
            stored.version = 2
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
            assert.are.same({ "d1", "w1" }, state.deserialise(stored, chores).selected)
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
            assert.are.same({ selected = {}, done = { d1 = 1 } }, s)
        end)
    end)
end)
