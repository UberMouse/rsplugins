-- Which celebrations a change to the tracker earns, as plain data: a chore the plugin ticked
-- by itself, and a period whose picked chores are now all done. Pure: the shell passes the
-- tracker before and after a change and shows what comes back.

local period = require("core/period")
local state = require("core/state")
local view = require("core/view")

local M = {}

M.CHORE_TITLE = "CHORE COMPLETE"

-- The title of the popup for a cleared period.
M.PERIOD_TITLES = {
    daily = "DAILIES COMPLETE",
    weekly = "WEEKLIES COMPLETE",
    monthly = "MONTHLIES COMPLETE",
}

---@class ChoreCelebration
---@field kind "chore"|"period"
---@field title string the popup's heading
---@field text string the popup's body
---@field label string what the console line names: a chore's id, or "<period> cleared"

-- How many of `period`'s chores `s` has picked, and whether all of them are done at `now`.
---@param s ChoreState
---@param chores Chore[]
---@param p ChorePeriod
---@param now integer
---@return integer picked
---@return boolean allDone false when nothing is picked
local function periodStatus(s, chores, p, now)
    local picked, done = 0, 0
    for _, chore in ipairs(chores) do
        if chore.period == p and state.isSelected(s, chore.id) then
            picked = picked + 1
            if state.isDone(s, chore, now) then done = done + 1 end
        end
    end
    return picked, picked > 0 and done == picked
end

-- The celebrations for the tracker going from `old` to `new` at `now`, in the order to show
-- them: the chores first (in chore-list order), then the periods they cleared. A picked
-- chore that turned from not done to done earns a popup only if the plugin ticked it
-- (`manual` false); a period whose picked chores went from not all done to all done earns one
-- however the last was ticked. Picking and unpicking change what a period holds, not what
-- got ticked, so the shell does not ask about those.
---@param old ChoreState
---@param new ChoreState
---@param chores Chore[]
---@param now integer
---@param manual boolean true when the player ticked by hand
---@return ChoreCelebration[]
function M.decide(old, new, chores, now, manual)
    local out = {}
    if not manual then
        for _, chore in ipairs(chores) do
            if
                state.isSelected(new, chore.id)
                and not state.isDone(old, chore, now)
                and state.isDone(new, chore, now)
            then
                out[#out + 1] = {
                    kind = "chore",
                    title = M.CHORE_TITLE,
                    text = chore.name,
                    label = chore.id,
                }
            end
        end
    end
    for _, p in ipairs(period.PERIODS) do
        local _, wasAll = periodStatus(old, chores, p, now)
        local picked, isAll = periodStatus(new, chores, p, now)
        if isAll and not wasAll then
            out[#out + 1] = {
                kind = "period",
                title = M.PERIOD_TITLES[p],
                text = string.format(
                    "All %d of your %s chore%s done",
                    picked,
                    view.TITLES[p]:lower(),
                    picked == 1 and "" or "s"
                ),
                label = p .. " cleared",
            }
        end
    end
    return out
end

return M
