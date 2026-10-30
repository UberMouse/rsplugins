-- core/period: when the current daily, weekly and monthly period began, in epoch minutes.

local support = require("tests.chore-tracker.support")
local period = require("core/period")
local M = support.MINUTES

describe("chore-tracker periodStart", function()
    describe("daily", function()
        it("starts at 00:00 UTC that day", function()
            assert.are.equal(M["2026-10-25"], period.periodStart("daily", M["2026-10-25 01:43"]))
        end)

        it("counts the reset minute as the new day, and the minute before as the old", function()
            assert.are.equal(M["2026-10-28"], period.periodStart("daily", M["2026-10-28"]))
            assert.are.equal(
                M["2026-10-27 23:59"] - 1439,
                period.periodStart("daily", M["2026-10-27 23:59"])
            )
        end)

        it("handles epoch minute 0 and before it", function()
            assert.are.equal(0, period.periodStart("daily", 0))
            assert.are.equal(-1440, period.periodStart("daily", -1))
        end)
    end)

    describe("weekly", function()
        it("starts at the most recent Wednesday 00:00 UTC", function()
            -- 2026-10-25 01:43 is a Sunday.
            assert.are.equal(M["2026-10-21"], period.periodStart("weekly", M["2026-10-25 01:43"]))
        end)

        it("starts a new week at Wednesday 00:00, not the Tuesday 23:59 before it", function()
            assert.are.equal(M["2026-10-28"], period.periodStart("weekly", M["2026-10-28"]))
            assert.are.equal(M["2026-10-21"], period.periodStart("weekly", M["2026-10-27 23:59"]))
        end)

        it("puts epoch minute 0 (a Thursday) in the week from Wednesday 1969-12-31", function()
            assert.are.equal(M["1969-12-31"], period.periodStart("weekly", 0))
        end)

        it("crosses a year end", function()
            assert.are.equal(M["2026-12-30"], period.periodStart("weekly", M["2027-01-01"]))
        end)
    end)

    describe("monthly", function()
        it("starts at 00:00 UTC on the 1st", function()
            assert.are.equal(M["2026-10-01"], period.periodStart("monthly", M["2026-10-25 01:43"]))
        end)

        it("keeps Feb 29 of a leap year in February, and starts March on Mar 1", function()
            assert.are.equal(M["2028-02-01"], period.periodStart("monthly", M["2028-02-29"]))
            assert.are.equal(M["2028-02-01"], period.periodStart("monthly", M["2028-02-29 12:00"]))
            assert.are.equal(M["2028-03-01"], period.periodStart("monthly", M["2028-03-01"]))
            assert.are.equal(M["2028-03-01"], period.periodStart("daily", M["2028-03-01"]))
        end)

        it("rolls Dec 31 23:59 over to Jan 1 00:00", function()
            assert.are.equal(M["2026-12-01"], period.periodStart("monthly", M["2026-12-31 23:59"]))
            assert.are.equal(M["2027-01-01"], period.periodStart("monthly", M["2027-01-01"]))
        end)

        it("ends a 30-day month after the 30th", function()
            assert.are.equal(M["2026-04-01"], period.periodStart("monthly", M["2026-04-30 23:59"]))
            assert.are.equal(M["2026-05-01"], period.periodStart("monthly", M["2026-05-01"]))
        end)

        it("ends a 31-day month after the 31st", function()
            assert.are.equal(M["2026-03-01"], period.periodStart("monthly", M["2026-03-31 23:59"]))
            assert.are.equal(M["2026-04-01"], period.periodStart("monthly", M["2026-04-01"]))
        end)

        it("handles epoch minute 0 and the month before it", function()
            assert.are.equal(0, period.periodStart("monthly", 0))
            assert.are.equal(M["1969-12-01"], period.periodStart("monthly", -1))
        end)
    end)

    it("rejects an unknown period", function()
        assert.has_error(function()
            period.periodStart("yearly", 0)
        end)
    end)

    it("returns integers", function()
        for _, p in ipairs(period.PERIODS) do
            assert.are.equal("integer", math.type(period.periodStart(p, M["2026-10-25 01:43"])))
        end
    end)

    it("counts RuneDays from 2002-02-27", function()
        -- PENG_SPY_PL_DAY read 9002 on Wednesday 2026-10-21.
        assert.are.equal(9002, period.runeDay(support.MINUTES["2026-10-21"]))
        assert.are.equal(9002, period.runeDay(support.MINUTES["2026-10-21"] + 1439))
        assert.are.equal(9006, period.runeDay(support.MINUTES["2026-10-25 01:43"]))
        assert.are.equal(0, period.runeDay(11745 * 1440))
    end)
end)
