-- Shared steps for the Chore Tracker's harness specs: load it in a scripted world, find and
-- click rows, toggle picks and ticks, drive the window (collapse, expand, back), seed and read
-- stored state, and set the clock and shop stock.

local harness = require("tests.harness")
local catalog = require("tests.harness.catalog")
local uiFake = require("tests.harness.api.ui")
local support = require("tests.chore-tracker.support")
local fit = require("core/fit")
local varsCore = require("core/vars")
local varRules = require("data/vars")
local chores = require("data/chores")
local view = require("core/view")
local state = require("core/state")
local listlayout = require("core/listlayout")

local M = {}

-- Click `target` (busted's assert isn't visible to a required module, so this raises).
---@param h table
---@param target any
---@param value any
local function click(h, target, value)
    local ok, why = h.ui:click(target, value)
    assert(ok, why)
end
M.click = click

-- The checkbox sprites by state: shell/rows.lua draws a hovered row with _1 (empty) or _3 (ticked).
M.BOX_EMPTY = catalog.config("Sprite", "RS3_BTN_CHECKBOX_0")
M.BOX_EMPTY_HOVERED = catalog.config("Sprite", "RS3_BTN_CHECKBOX_1")
M.BOX_TICKED = catalog.config("Sprite", "RS3_BTN_CHECKBOX_2")
M.BOX_TICKED_HOVERED = catalog.config("Sprite", "RS3_BTN_CHECKBOX_3")
local TICKED_SPRITES = { [M.BOX_TICKED] = true, [M.BOX_TICKED_HOVERED] = true }
local EMPTY_SPRITES = { [M.BOX_EMPTY] = true, [M.BOX_EMPTY_HOVERED] = true }

-- A row label's colour when not done and done. shell/rows.lua keeps these private, so they are
-- copied here, once; change them with rows.lua.
M.TEXT_COLOUR, M.DONE_COLOUR = 0xE7D7B0FF, 0x7A7262FF

-- Whether a checkbox sprite is a ticked one, plain or hovered. A missing or unknown sprite
-- errors, so a box that never drew can't read as unticked.
---@param sprite any
---@return boolean
local function isTicked(sprite)
    if TICKED_SPRITES[sprite] then return true end
    if EMPTY_SPRITES[sprite] then return false end
    error("not a checkbox sprite: " .. tostring(sprite))
end

-- Epoch minutes, looked up from support.MINUTES (checked there against Python's datetime, UTC).
M.NOW = support.MINUTES["2026-10-25 01:43"] -- a Sunday
M.NEXT_DAY = support.MINUTES["2026-10-26"] -- 00:00, a daily reset
M.WEDNESDAY = support.MINUTES["2026-10-28"] -- 00:00, a weekly reset
M.NEXT_MONTH = support.MINUTES["2026-11-01"] -- 00:00, a monthly reset

-- Harness milliseconds that cover the plugin's timers. They mirror main.lua's POLL_TICKS (25
-- Logic ticks, the login and layout poll) and shell/vars.lua's SETTLE_TICKS (500), at 20 ms a
-- tick; if either changes, change these.
M.POLL_MS = 500
M.SETTLE_MS = 10000

-- Set the game clock (epoch minutes).
---@param h table
---@param minutes integer
function M.setClock(h, minutes)
    h.world:setVar("VarPlayer", "CLOCK_TIME_DATE_MINUTES", minutes)
end

-- Store `value` at persistent-DB key `key` the way the plugin does; call it before h:load().
---@param h table
---@param key string
---@param value table
function M.seed(h, key, value)
    h.db[key] = { type = harness.enums.PersistentDBType.STRUCTURED_DATA, value = value }
end

-- Set shop `inv` to one line of `count` of `obj` (and the `others` lines after it, if any). A
-- line whose count drops from the previous call is the player buying.
---@param h table
---@param inv string
---@param obj string
---@param count integer
---@param others table[]?
function M.stock(h, inv, obj, count, others)
    local lines = { { obj = obj, count = count } }
    for _, line in ipairs(others or {}) do
        lines[#lines + 1] = line
    end
    h.world:setInventory(inv, lines, 4)
end

-- Buy from open shop `inv`: its `obj` line drops from `from` to `to`.
---@param h table
---@param inv string
---@param obj string
---@param from integer
---@param to integer
function M.buy(h, inv, obj, from, to)
    M.stock(h, inv, obj, from)
    M.stock(h, inv, obj, to)
end

-- The Chores window.
---@param h table
---@return table
function M.window(h)
    return h.ui:get("Window", { text = "Chores" })
end

-- A harness past the settle window, where var ticks start. `before` (var name -> value) is set
-- before loading; `opts` are M.loaded's (its `load` is overridden).
---@param before table<string, integer>?
---@param opts table?
---@return table
function M.settled(before, opts)
    opts = opts or {}
    opts.load = false
    local h = M.loaded(opts)
    for name, value in pairs(before or {}) do
        h.world:setVar("VarPlayer", name, value)
    end
    h:load()
    h:advance(M.SETTLE_MS)
    return h
end

-- A harness with the clock at `opts.clock` (default NOW; 0 for not ready) and logged in as
-- `opts.login` (default "Zezima"; false for logged out), loaded unless `opts.load` is false.
-- `opts.grant` lists permissions to grant (none by default). `opts.absentNames` is the
-- harness's: names that read as the client reads an unknown one.
-- Every var data/vars.lua watches starts at 0, because the harness faults on reading an
-- unset one (detect_spec.lua covers a var with no value, with stand-in globals); set one
-- before loading to start it elsewhere.
---@param opts table?
---@return table h
function M.loaded(opts)
    opts = opts or {}
    local h = harness.new("chore-tracker", { grant = opts.grant, absentNames = opts.absentNames })
    h.world:setVar("VarPlayer", "CLOCK_TIME_DATE_MINUTES", opts.clock or M.NOW)
    for _, rule in ipairs(varRules) do
        for _, name in ipairs(varsCore.names(rule)) do
            h.world:setVar("VarPlayer", name, 0)
        end
    end
    if opts.login ~= false then h.world:login(opts.login or "Zezima") end
    if opts.load ~= false then h:load() end
    return h
end

-- The open view's rows (list or settings), top to bottom: each hand-built row layer in the
-- window's content, as { layer, grip, icon, label, box, text } (grip nil in settings rows, icon
-- nil when the row has none). Found through the driver's children, since the plugin
-- keeps its rows in locals.
---@param h table
---@return table[]
function M.rows(h)
    local content = M.window(h).content
    local grip = catalog.config("Sprite", "HAMBURGER_MENU_ICON")
    local boxes = {
        [M.BOX_EMPTY] = true,
        [M.BOX_EMPTY_HOVERED] = true,
        [M.BOX_TICKED] = true,
        [M.BOX_TICKED_HOVERED] = true,
    }
    local out = {}
    for _, layer in ipairs(h.ui:children(content)) do
        if assert(uiFake.stateOf(layer)).class == "ui.Layer" then
            local row = { layer = layer }
            for _, proxy in ipairs(h.ui:children(layer)) do
                local part = assert(uiFake.stateOf(proxy))
                if part.class == "ui.Text" then
                    row.label, row.text = proxy, part.content
                elseif part.class == "ui.Sprite" and part.spriteID == grip then
                    row.grip = proxy
                elseif part.class == "ui.Sprite" and boxes[part.spriteID] then
                    row.box = proxy
                elseif part.class == "ui.Sprite" and not part.hidden then
                    row.icon = proxy
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

-- A chore's display name, from data/chores.
---@param id string
---@return string
function M.name(id)
    return assert(state.find(chores, id), "no chore " .. id).name
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
    return isTicked(M.row(h, name).box.spriteID)
end

-- Toggle a chore by clicking its row, in either view (on its text, which passes the click to
-- the row): ticks an unticked one, unticks a ticked one.
---@param h table
---@param name string
function M.toggleTick(h, name)
    click(h, M.row(h, name).label)
end

-- The state value stored for a character (default "Zezima"), or nil if none is stored.
---@param h table
---@param who string?
---@return table?
function M.stored(h, who)
    local entry = h.db["state:" .. (who or "Zezima")]
    return entry and entry.value
end

-- The minute chore `id` is stored as done for a character, or nil.
---@param h table
---@param id string
---@param who string?
---@return integer?
function M.doneAt(h, id, who)
    local value = M.stored(h, who)
    return value and value.done[id]
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
    -- A row's leave listener that doesn't return true blocks the tooltip's own, which sticks.
    assert(#h.ui:tooltips() == 0, "tooltip still up after leaving the row")
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
        for _, subgroup in ipairs(group.subgroups) do
            for _, chore in ipairs(subgroup.chores) do
                n = n + 1
                if chore.id == id then return assert(list[n], "no settings row " .. id) end
            end
        end
    end
    error("no chore " .. id)
end

-- The settings view's category subheadings, top to bottom: each one's text and content y.
-- They are the content's own texts (PrettyUI's titles are tracked apart) that name a category.
---@param h table
---@return { text: string, y: number }[]
function M.subheadings(h)
    local titles = {}
    for _, title in pairs(view.CATEGORY_TITLES) do
        titles[title] = true
    end
    local out = {}
    for _, proxy in ipairs(h.ui:children(M.window(h).content)) do
        local part = assert(uiFake.stateOf(proxy))
        if part.class == "ui.Text" and titles[part.content] then
            out[#out + 1] = { text = part.content, y = proxy.y }
        end
    end
    table.sort(out, function(a, b)
        return a.y < b.y
    end)
    return out
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
    return isTicked(M.settingsRow(h, id).box.spriteID)
end

-- Open the settings view.
---@param h table
function M.openSettings(h)
    click(h, h.ui:get("SpriteButton", { sprite = "SETTINGS" }))
    h:advance(20)
end

-- Open the info view.
---@param h table
function M.openInfo(h)
    click(h, h.ui:get("SpriteButton", { sprite = "INFO" }))
    h:advance(20)
end

-- Click the visible hamburger, which collapses an open window and expands a collapsed one.
---@param h table
function M.collapse(h)
    click(h, h.ui:get("SpriteButton", { sprite = "MENU", visible = true }))
    h:advance(20)
end

-- Same MENU click; the second name states the spec's intent.
M.expand = M.collapse

-- Click the settings view's back button, returning to the list.
---@param h table
function M.back(h)
    click(h, h.ui:get("SpriteButton", { sprite = "BACK" }))
    h:advance(20)
end

M.MINUS = catalog.config("Sprite", "RS3_CONTEXTUAL_INPUT_MINUS")
M.PLUS = catalog.config("Sprite", "RS3_CONTEXTUAL_INPUT_PLUS")

-- The settings view's Shop runs line for chore `id`: its name and value texts and its minus
-- and plus button layers. They sit straight in the content: the name is the content's own
-- text with the chore's name, whole or cut with "..." (a settings row's label is inside its row
-- layer), and the value and buttons share its row.
---@param h table
---@param id string
---@return { label: table, value: table, minus: table, plus: table }
function M.stepper(h, id)
    local name = M.name(id)
    local children = h.ui:children(M.window(h).content)
    local label
    for _, proxy in ipairs(children) do
        local part = assert(uiFake.stateOf(proxy))
        local text = part.class == "ui.Text" and part.content
        local cut = text and text:match("^(.*)%.%.%.$")
        if text == name or (cut and name:sub(1, #cut) == cut) then label = proxy end
    end
    assert(label, "no Shop runs line for " .. id)
    local out = { label = label }
    for _, proxy in ipairs(children) do
        local part = assert(uiFake.stateOf(proxy))
        local inRow = proxy.y >= label.y and proxy.y < label.y + listlayout.ROW_HEIGHT
        if inRow and part.class == "ui.Text" and part.content:match("^%d+ of %d+$") then
            out.value = proxy
        elseif inRow and part.class == "ui.Layer" then
            for _, inner in ipairs(h.ui:children(proxy)) do
                local sprite = assert(uiFake.stateOf(inner)).spriteID
                if sprite == M.MINUS then out.minus = proxy end
                if sprite == M.PLUS then out.plus = proxy end
            end
        end
    end
    assert(out.value and out.minus and out.plus, "an incomplete Shop runs line for " .. id)
    return out
end

-- Open settings, step chore `id`'s shops-needed count to `n` with its stepper, and go back
-- to the list.
---@param h table
---@param id string
---@param n integer
function M.setShopsNeeded(h, id, n)
    M.openSettings(h)
    local line = M.stepper(h, id)
    M.window(h):SetScrollPosition(line.label.y - 40)
    for _ = 1, 20 do
        local shown = tonumber(line.value.content:match("^(%d+)"))
        if shown == n then break end
        click(h, shown > n and line.minus or line.plus)
    end
    assert(line.value.content:match("^(%d+)") == tostring(n), "cannot step " .. id .. " to " .. n)
    M.back(h)
end

-- Open settings, toggle the picked state of the chores whose ids are given (picks an unpicked
-- one, unpicks a picked one), and go back to the list.
---@param h table
---@param ids string[]
function M.togglePicks(h, ids)
    M.openSettings(h)
    local win = M.window(h)
    for _, id in ipairs(ids) do
        -- Settings lists every chore, so a row may be scrolled out of the view; bring it in.
        local picking = M.settingsRow(h, id)
        win:SetScrollPosition(picking.layer.y - 40)
        click(h, picking.label)
    end
    M.back(h)
end

return M
