-- Shared steps for the Chore Tracker's harness specs: load it in a scripted world, find a
-- list row, and pick chores in the settings view.

local harness = require("tests.harness")
require("tests.chore-tracker.support")
local varCore = require("core/vars")
local varRules = require("data/vars")

local M = {}

-- Click `target` (busted's assert isn't visible to a required module, so this raises).
---@param h table
---@param target any
---@param value any
local function click(h, target, value)
    local ok, why = h.ui:click(target, value)
    assert(ok, why)
end

-- Epoch minutes (checked against Python's datetime, UTC).
M.NOW = 29881543 -- 2026-10-25 01:43, a Sunday
M.NEXT_DAY = 29882880 -- 2026-10-26 00:00, a daily reset
M.WEDNESDAY = 29885760 -- 2026-10-28 00:00, a weekly reset
M.NEXT_MONTH = 29891520 -- 2026-11-01 00:00, a monthly reset

-- A harness with the clock at `opts.clock` (default NOW; 0 for not ready) and logged in as
-- `opts.login` (default "Zezima"; false for logged out), loaded unless `opts.load` is false.
-- Every var data/vars.lua watches starts at 0 (the harness faults on reading an unset one);
-- set one before loading to start it elsewhere.
---@param opts table?
---@return table h
function M.loaded(opts)
    opts = opts or {}
    local h = harness.new("chore-tracker")
    h.world:setVar("VarPlayer", "CLOCK_TIME_DATE_MINUTES", opts.clock or M.NOW)
    for _, rule in ipairs(varRules) do
        for _, name in ipairs(varCore.names(rule)) do
            h.world:setVar("VarPlayer", name, 0)
        end
    end
    if opts.login ~= false then h.world:login(opts.login or "Zezima") end
    if opts.load ~= false then h:load() end
    return h
end

-- The one visible list row (of its normal and dimmed copies) for a chore name.
---@param h table
---@param name string
---@return table
function M.row(h, name)
    return h.ui:get("CheckboxButton", { text = name, visible = true })
end

-- Whether a chore's visible list row is ticked.
---@param h table
---@param name string
---@return boolean
function M.ticked(h, name)
    return h.ui:choices(M.row(h, name))[1].selected
end

-- Click a chore's visible list row.
---@param h table
---@param name string
---@param id string
function M.tick(h, name, id)
    click(h, M.row(h, name), id)
end

-- The settings view's CheckboxButton holding chore `id`.
---@param h table
---@param id string
---@return table
function M.group(h, id)
    for _, cb in ipairs(h.ui:find("CheckboxButton")) do
        for _, choice in ipairs(h.ui:choices(cb)) do
            if choice.value == id then return cb end
        end
    end
    error("no settings choice " .. id)
end

-- Whether chore `id` is ticked in the settings view (picked).
---@param h table
---@param id string
---@return boolean
function M.picked(h, id)
    for _, choice in ipairs(h.ui:choices(M.group(h, id))) do
        if choice.value == id then return choice.selected end
    end
    error("unreachable: group() found " .. id)
end

-- Open the settings view.
---@param h table
function M.openSettings(h)
    click(h, h.ui:get("SpriteButton", { sprite = "SETTINGS" }))
    h:advance(20)
end

-- Open settings, toggle the chores whose ids are given, and go back to the list.
---@param h table
---@param ids string[]
function M.pick(h, ids)
    M.openSettings(h)
    for _, id in ipairs(ids) do
        click(h, M.group(h, id), id)
    end
    click(h, h.ui:get("SpriteButton", { sprite = "BACK" }))
    h:advance(20)
end

return M
