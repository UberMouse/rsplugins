-- When each reset period began, in epoch minutes (minutes since 1970-01-01 00:00 UTC), the
-- unit of the client's clock var. Pure integer arithmetic, because the client has no `os`.
-- The resets are dailyscape's (checkReset in dailyscape.js): daily at 00:00 UTC, weekly on
-- Wednesday 00:00 UTC, monthly at 00:00 UTC on the 1st. It also turns an epoch minute into the
-- game's RuneDay number.

local M = {}

---@alias ChorePeriod "daily"|"weekly"|"monthly"

-- The periods in display order.
M.PERIODS = { "daily", "weekly", "monthly" } ---@type ChorePeriod[]

local MINUTES_PER_DAY = 1440
-- RuneDay 0 is 2002-02-27, day 11745 counted from 1970-01-01. Checked against the game:
-- PENG_SPY_PL_DAY read 9002 on Wednesday 2026-10-21.
local RUNEDAY_EPOCH = 11745

-- The RuneDay (the game's day number) of an epoch minute.
---@param minutes integer
---@return integer
function M.runeDay(minutes)
    return minutes // MINUTES_PER_DAY - RUNEDAY_EPOCH
end

-- The day of the month (1-31) of a day counted from 1970-01-01. This is the days-to-civil
-- algorithm from Howard Hinnant's "chrono-Compatible Low-Level Date Algorithms", which
-- handles leap years (including the 100/400 rules) without tables. It counts years from
-- March, so February's leap day falls at the end of a "year".
---@param days integer
---@return integer
local function dayOfMonth(days)
    local z = days + 719468 -- days from 0000-03-01 to 1970-01-01
    local era = z // 146097 -- 400-year eras; // floors, so this is right before 1970 too
    local doe = z - era * 146097 -- day of era, 0..146096
    local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365 -- year of era
    local doy = doe - (365 * yoe + yoe // 4 - yoe // 100) -- day of year from Mar 1, 0..365
    local mp = (5 * doy + 2) // 153 -- month from March, 0..11
    return doy - (153 * mp + 2) // 5 + 1
end

-- The epoch minute when the `period` containing `minutes` began. A period starts at its own
-- reset minute, so a Wednesday 00:00 is the start of a new week.
---@param period ChorePeriod
---@param minutes integer epoch minutes
---@return integer
function M.periodStart(period, minutes)
    local days = minutes // MINUTES_PER_DAY
    if period == "daily" then return days * MINUTES_PER_DAY end
    if period == "weekly" then
        -- Day 0 was a Thursday, so (days + 1) % 7 is the number of days since Wednesday.
        return (days - (days + 1) % 7) * MINUTES_PER_DAY
    end
    if period == "monthly" then return (days - (dayOfMonth(days) - 1)) * MINUTES_PER_DAY end
    error("unknown period " .. tostring(period), 2)
end

return M
