-- Shared steps for the Chore Tracker's harness specs: load it in a scripted world, find and
-- click a list row, and pick chores in the settings view.

local harness = require("tests.harness")
local catalog = require("tests.harness.catalog")
local uiFake = require("tests.harness.api.ui")
require("tests.chore-tracker.support")
local fit = require("core/fit")
local varCore = require("core/vars")
local varRules = require("data/vars")
local chores = require("data/chores")
local view = require("core/view")

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
-- `opts.grant` lists permissions to grant (none by default).
-- Every var data/vars.lua watches starts at 0, because the harness faults on reading an
-- unset one (detect_spec.lua covers a var with no value, with stand-in globals); set one
-- before loading to start it elsewhere.
---@param opts table?
---@return table h
function M.loaded(opts)
    opts = opts or {}
    local h = harness.new("chore-tracker", { grant = opts.grant })
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

-- The open view's rows (list or settings), top to bottom: each hand-built row layer in the
-- window's content, as { layer, icon, label, box, text } (icon nil when the row has none). Found
-- through the harness's component states, since the plugin keeps its rows in locals.
---@param h table
---@return table[]
function M.rows(h)
    local content = h.ui:get("Window", { text = "Chores" }).content
    local out = {}
    for _, child in ipairs(uiFake.stateOf(content).children) do
        if child.class == "ui.Layer" then
            local row = { layer = child.proxy }
            for _, part in ipairs(child.children) do
                if part.class == "ui.Text" then
                    row.label, row.text = part.proxy, part.content
                elseif part.class == "ui.Sprite" then
                    -- The icon is left of the box, which sits at the row's right edge.
                    if row.box then
                        row.icon, row.box = row.box, part.proxy
                    else
                        row.box = part.proxy
                    end
                end
            end
            -- The Celebrations switches are a layer too, but hold no text of ours.
            if row.label then out[#out + 1] = row end
        end
    end
    table.sort(out, function(a, b)
        return a.layer.y < b.layer.y
    end)
    return out
end

-- The list row for a chore name (its text is the name, or the name and a shop count, or the start
-- of either followed by "..."), or nil.
---@param h table
---@param name string
---@return table?
function M.findRow(h, name)
    local found = nil
    for _, row in ipairs(M.rows(h)) do
        -- A name too long for the window is cut short and ends in "...". A bare "..." row has
        -- no prefix to match, so it matches nothing.
        local cut = row.text:sub(-#fit.ELLIPSIS) == fit.ELLIPSIS
                and row.text:sub(1, -#fit.ELLIPSIS - 1)
            or nil
        if cut and #cut == 0 then cut = nil end
        if
            row.text == name
            or row.text:sub(1, #name + 2) == name .. " ("
            or (cut and name:sub(1, #cut) == cut)
        then
            assert(found == nil, "two rows for " .. name)
            found = row
        end
    end
    return found
end

-- The list row for a chore name; errors if there is none.
---@param h table
---@param name string
---@return table
function M.row(h, name)
    return assert(M.findRow(h, name), "no row for " .. name)
end

-- Whether a chore's list row shows ticked.
---@param h table
---@param name string
---@return boolean
function M.ticked(h, name)
    return M.row(h, name).box.spriteID == catalog.config("Sprite", "RS3_BTN_CHECKBOX_SMALL_2")
end

-- Click a chore's row, in either view (on its text, which passes the click to the row).
---@param h table
---@param name string
function M.tick(h, name)
    click(h, M.row(h, name).label)
end

-- A chore's row text and tooltip text, read by hovering it.
---@param h table
---@param name string
---@return string text
---@return string tooltip
function M.rowShown(h, name)
    local row = M.row(h, name)
    assert(h.ui:hover(row.layer))
    local tips = h.ui:tooltips()
    h.ui:leave()
    assert(#tips == 1, "want one tooltip, got " .. #tips)
    return row.text, tips[1]
end

-- The settings view's Celebrations CheckboxButton holding the switch `id`.
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

-- The settings view's row for chore `id`. Names repeat across periods, so it is found by
-- position: the rows are in view.byPeriod order, one per chore.
---@param h table
---@param id string
---@return table
function M.settingsRow(h, id)
    local list, n = M.rows(h), 0
    for _, group in ipairs(view.byPeriod(chores)) do
        for _, chore in ipairs(group.chores) do
            n = n + 1
            if chore.id == id then return assert(list[n], "no settings row " .. id) end
        end
    end
    error("no chore " .. id)
end

-- Whether `id` is ticked in the settings view: a Celebrations switch by its value, else a
-- chore (picked) by its row's box.
---@param h table
---@param id string
---@return boolean
function M.picked(h, id)
    for _, cb in ipairs(h.ui:find("CheckboxButton")) do
        for _, choice in ipairs(h.ui:choices(cb)) do
            if choice.value == id then return choice.selected end
        end
    end
    return M.settingsRow(h, id).box.spriteID == catalog.config("Sprite", "RS3_BTN_CHECKBOX_SMALL_2")
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
    local win = h.ui:get("Window", { text = "Chores" })
    for _, id in ipairs(ids) do
        -- Settings lists every chore, so a row may be scrolled out of the view; bring it in.
        local picking = M.settingsRow(h, id)
        win:SetScrollPosition(picking.layer.y - 40)
        click(h, picking.label)
    end
    click(h, h.ui:get("SpriteButton", { sprite = "BACK" }))
    h:advance(20)
end

return M
