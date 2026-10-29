-- core/celebrate: which celebrations a change to the tracker earns. core/settings: the
-- celebration settings as stored.

local support = require("tests.chore-tracker.support")
local celebrate = require("core/celebrate")
local settings = require("core/settings")
local state = require("core/state")

local NOW = support.MINUTES["2026-10-25 01:43"]
local NEXT_DAY = support.MINUTES["2026-10-26"]

describe("chore-tracker celebrate", function()
    local chores, byId
    before_each(function()
        chores = support.chores()
        byId = {}
        for _, c in ipairs(chores) do
            byId[c.id] = c
        end
    end)

    -- A tracker with `ids` picked.
    ---@param ids string[]
    ---@return table
    local function picked(ids)
        local s = state.new()
        for _, id in ipairs(ids) do
            s = state.select(s, chores, id)
        end
        return s
    end

    ---@param celebrations table[]
    ---@return string[]
    local function labels(celebrations)
        local out = {}
        for i, c in ipairs(celebrations) do
            out[i] = c.label
        end
        return out
    end

    describe("a chore the plugin ticked", function()
        it("celebrates a picked chore turning done, named by its text", function()
            local old = picked({ "d1", "d2" })
            local new = state.autoMark(old, byId.d1, NOW)
            local out = celebrate.decide(old, new, chores, NOW, false)
            assert.are.same({ "d1" }, labels(out))
            assert.are.equal("chore", out[1].kind)
            assert.are.equal("CHORE COMPLETE", out[1].title)
            assert.are.equal("D1", out[1].text)
        end)

        it("doesn't celebrate a tick by hand", function()
            local old = picked({ "d1", "d2" })
            local new = state.mark(old, "d1", NOW)
            assert.are.same({}, celebrate.decide(old, new, chores, NOW, true))
        end)

        it("doesn't celebrate unticking", function()
            local old = state.mark(picked({ "d1", "d2" }), "d1", NOW)
            local new = state.unmark(old, "d1")
            assert.are.same({}, celebrate.decide(old, new, chores, NOW, true))
            assert.are.same({}, celebrate.decide(old, new, chores, NOW, false))
        end)

        it("doesn't celebrate a chore that isn't picked", function()
            local old = picked({ "d1" })
            local new = state.autoMark(old, byId.d2, NOW)
            assert.are.same({}, celebrate.decide(old, new, chores, NOW, false))
        end)

        it("doesn't celebrate a chore already done this period", function()
            local old = state.mark(picked({ "d1", "d2" }), "d1", NOW)
            local new = state.autoMark(old, byId.d1, NOW + 5)
            assert.are.same({}, celebrate.decide(old, new, chores, NOW + 5, false))
        end)

        it("doesn't celebrate a purchase that only records another shop of a done chore", function()
            local old = state.recordPurchase(picked({ "dshop", "d1" }), byId.dshop, "inv-a", NOW)
            local new = state.recordPurchase(old, byId.dshop, "inv-b", NOW + 1)
            assert.are_not.equal(old, new)
            assert.are.same({}, celebrate.decide(old, new, chores, NOW + 1, false))
        end)

        it("celebrates a chore marked done in a new period", function()
            local old = state.mark(picked({ "d1", "d2" }), "d1", NOW)
            local new = state.autoMark(old, byId.d1, NEXT_DAY)
            assert.are.same({ "d1" }, labels(celebrate.decide(old, new, chores, NEXT_DAY, false)))
        end)
    end)

    describe("a cleared period", function()
        it("celebrates the last picked chore of a period, by hand or not", function()
            local old = state.mark(picked({ "d1", "d2" }), "d1", NOW)
            local byHand = state.mark(old, "d2", NOW)
            local out = celebrate.decide(old, byHand, chores, NOW, true)
            assert.are.same({ "daily cleared" }, labels(out))
            assert.are.equal("period", out[1].kind)
            assert.are.equal("DAILIES COMPLETE", out[1].title)
            assert.matches("All 2 of your daily chores done", out[1].text)

            local auto =
                celebrate.decide(old, state.autoMark(old, byId.d2, NOW), chores, NOW, false)
            assert.are.same({ "d2", "daily cleared" }, labels(auto))
        end)

        it("titles each period, and counts one chore in the singular", function()
            local weekly = picked({ "w1" })
            local out = celebrate.decide(weekly, state.mark(weekly, "w1", NOW), chores, NOW, true)
            assert.are.equal("WEEKLIES COMPLETE", out[1].title)
            assert.matches("All 1 of your weekly chore done", out[1].text)
            local monthly = picked({ "m1" })
            out = celebrate.decide(monthly, state.mark(monthly, "m1", NOW), chores, NOW, true)
            assert.are.equal("MONTHLIES COMPLETE", out[1].title)
            assert.are.same({ "monthly cleared" }, labels(out))
        end)

        it("doesn't celebrate while a picked chore is still to do", function()
            local old = picked({ "d1", "d2" })
            assert.are.same(
                {},
                celebrate.decide(old, state.mark(old, "d1", NOW), chores, NOW, true)
            )
        end)

        it("doesn't count chores of other periods or unpicked ones", function()
            local old = picked({ "d1", "w1" })
            local out = celebrate.decide(old, state.mark(old, "d1", NOW), chores, NOW, true)
            assert.are.same({ "daily cleared" }, labels(out))
        end)

        it("celebrates again after an untick and re-tick", function()
            local full = state.mark(state.mark(picked({ "d1", "d2" }), "d1", NOW), "d2", NOW)
            local undone = state.unmark(full, "d2")
            assert.are.same({}, celebrate.decide(full, undone, chores, NOW, true))
            local again = state.mark(undone, "d2", NOW)
            assert.are.same(
                { "daily cleared" },
                labels(celebrate.decide(undone, again, chores, NOW, true))
            )
        end)

        it("doesn't celebrate a period that was already all done", function()
            local full = state.mark(picked({ "d1" }), "d1", NOW)
            assert.are.same(
                {},
                celebrate.decide(full, state.mark(full, "d1", NOW + 1), chores, NOW + 1, true)
            )
        end)

        it("orders chores before the periods they clear, periods daily first", function()
            local old = picked({ "d1", "w1" })
            local new = state.autoMark(state.autoMark(old, byId.w1, NOW), byId.d1, NOW)
            assert.are.same(
                { "d1", "w1", "daily cleared", "weekly cleared" },
                labels(celebrate.decide(old, new, chores, NOW, false))
            )
        end)
    end)
end)

describe("chore-tracker settings", function()
    it("defaults to popups and sound on", function()
        assert.are.same({ popups = true, sound = true }, settings.default())
    end)

    it("round-trips through serialise and fromStored", function()
        local s = { popups = false, sound = true }
        assert.are.same(s, settings.fromStored(settings.serialise(s)))
    end)

    it("gives the defaults for a missing or malformed value", function()
        local default = settings.default()
        for _, bad in ipairs({ "x", 5, true, {}, { version = 2, popups = false } }) do
            assert.are.same(default, settings.fromStored(bad))
        end
        assert.are.same(default, settings.fromStored(nil))
    end)

    it("keeps a good field beside a bad one", function()
        local out = settings.fromStored({ version = 1, popups = false, sound = "loud" })
        assert.are.same({ popups = false, sound = true }, out)
    end)
end)
