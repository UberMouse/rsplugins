-- Chore Tracker: a checklist of RuneScape's daily, weekly and monthly chores (the list from
-- dailyscape, MIT; see data/chores.lua), drawn with PrettyUI.
--
--   * The window lists the chores you picked, grouped Daily / Weekly / Monthly, each headed
--     with how many are done. Tick a chore when you've done it; done chores stay in place,
--     dimmed, and a second click unticks them. Hover a chore for its description and wiki
--     links (shown as text: plugins can't open URLs).
--   * The settings button (top left of the content) opens the settings view, which lists
--     every chore to pick from; the back button returns to the list.
--   * The hamburger in the title bar's top-right corner (where PrettyUI's close X would be)
--     collapses the window into a single hamburger button at the same spot. Alt-drag that
--     button to move it (with the console closed); click it to open the window again, grown
--     left and down from the button.
--   * A chore counts as done until its period resets, by the game clock (UTC): daily at
--     00:00, weekly on Wednesday 00:00, monthly at 00:00 on the 1st.
--
-- Picks and ticks are kept in memory for now: they reset on reload.
--
-- It only shows a list you tick by hand: no permissions, nothing sent to the game, nothing
-- about other players. Console lines carry [CHORES] (grep: \[CHORES\]).
--
-- The collapsed button is a PrettyUI Panel exactly the button's size (20x20), with no
-- background, scrolling off, and the hamburger as a child of the Panel's own root at its
-- origin, so the button covers the Panel's 4 px frame. A Panel always draws that frame, but
-- it is what makes Alt-drag work, and the button's screen spot is then the Panel's own.
-- The Panel is made on collapse and destroyed on expand: kept hidden while the window is
-- open, it would still take Alt-drags, and so clicks, over the window's hamburger.

local chores = require("data/chores")
local period = require("core/period")
local state = require("core/state")
local view = require("core/view")

-- Every console line from this plugin carries this tag, so it's easy to grep.
local function say(...)
    log("[CHORES]", ...)
end

-- PrettyUI's close X is 20 px, at (width - 28, 7) from the window's top-left; the
-- hamburger takes that slot.
local BUTTON_SIZE = 20
local SLOT_X, SLOT_Y = -28, 7

-- Where the window first opens, and the smallest it can be resized to.
local DEFAULT_LAYOUT = { x = 600, y = 300, width = 320, height = 420 }
local MIN_WIDTH, MIN_HEIGHT = 240, 160

-- Row text colours (0xRRGGBBAA): PrettyUI 1.2.0's default for a choice, and a dimmed one
-- for done rows.
local TEXT_COLOUR = 0xE7D7B0FF
local DONE_COLOUR = 0x7A7262FF

-- Tooltips wrap at this width; wiki URLs are long.
local TOOLTIP_WIDTH = 360

local parent = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
assert(parent, "the plugin layer should exist once a plugin runs")

local tracker = state.new() -- picks and ticks
local mode = "list" -- or "settings"
local win = nil ---@type prettyui.Window?
local openButton = nil ---@type prettyui.SpriteButton? the hamburger in the window
local collapsed = nil ---@type prettyui.Panel? exists only while collapsed
local collapsedButton = nil ---@type prettyui.SpriteButton?
-- The list view's widgets, to update in place: chore id -> its two rows, and period ->
-- its heading.
local rowWidgets = {} ---@type table<string, { normal: prettyui.CheckboxButton, dimmed: prettyui.CheckboxButton }>
local headings = {} ---@type table<string, ui.Text>
-- Work left for the next Logic tick. A button's action mustn't destroy the button while
-- PrettyUI is still handling its click, so a view switch (which rebuilds the window) and
-- removing the collapsed panel after expanding wait a tick.
local pendingMode = nil ---@type string?
local retiring = nil ---@type prettyui.Panel?

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

-- Minutes since the Unix epoch, from the game clock. Until the clock reads (logged out,
-- loading) this is 0: marks are then made at minute 0 and every period's start is at or
-- before it, so nothing resets.
---@return integer
local function now()
    local minutes = var.VarPlayer.CLOCK_TIME_DATE_MINUTES.value
    if type(minutes) == "number" and minutes > 0 then return math.tointeger(minutes) or 0 end
    return 0
end

---@param v number
---@param lo number
---@param hi number
---@return number
local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

-- A component's on-screen position relative to the plugin layer, in whole pixels.
---@param component ui.Component
---@return integer x
---@return integer y
local function screenPos(component)
    local at, origin = component.xyGlobal, parent.xyGlobal
    return math.floor(at.x - origin.x + 0.5), math.floor(at.y - origin.y + 0.5)
end

-- A chore's tooltip: its description, then its wiki page and any other links, as text.
---@param chore { desc: string, url: string, links: string[] }
---@return prettyui.Tooltip
local function tooltipFor(chore)
    local lines = {}
    if chore.desc ~= "" then lines[#lines + 1] = chore.desc end
    lines[#lines + 1] = chore.url
    for _, link in ipairs(chore.links) do
        lines[#lines + 1] = link
    end
    return { text = table.concat(lines, "<br>"), maxWidth = TOOLTIP_WIDTH }
end

---@param section ChoreSection
---@return string
local function headingText(section)
    return string.format("%s  %d/%d", section.title, section.done, section.total)
end

---------------------------------------------------------------------------
-- List view
---------------------------------------------------------------------------

-- Show a row as done or not: ticked and dimmed, or unticked in the normal colour.
-- PrettyUI 1.2.0 can't recolour a choice once made, so each row exists twice at the same
-- spot, once per colour, and only the matching one is shown.
---@param id string
---@param done boolean
local function showDone(id, done)
    local widgets = rowWidgets[id]
    widgets.normal:SetSelected(id, done, false)
    widgets.dimmed:SetSelected(id, done, false)
    widgets.normal.root.hidden = done
    widgets.dimmed.root.hidden = not done
end

-- Bring the list's ticks, dimming and counts up to date with the tracker, in place.
local function refreshList()
    for _, section in ipairs(view.view(tracker, chores, now())) do
        local heading = headings[section.period]
        if heading then heading.content = headingText(section) end
        for _, row in ipairs(section.rows) do
            if rowWidgets[row.id] then showDone(row.id, row.done) end
        end
    end
end

-- A row was ticked or unticked by the player.
---@param _ prettyui.CheckboxButton
---@param _values any[]
---@param id string
---@param ticked boolean
local function onTick(_, _values, id, ticked)
    if ticked then
        tracker = state.mark(tracker, id, now())
    else
        tracker = state.unmark(tracker, id)
    end
    refreshList()
end

---@param w prettyui.Window
---@param openSettings fun()
local function buildList(w, openSettings)
    w:AddSpriteButton("SETTINGS", openSettings, { size = BUTTON_SIZE, tooltip = "Pick chores" })
    local sections = view.view(tracker, chores, now())
    if #sections == 0 then
        w:AddText("No chores picked yet: use the settings button above to choose some.")
        return
    end
    for _, section in ipairs(sections) do
        headings[section.period] = w:AddTitle(headingText(section))
        for _, row in ipairs(section.rows) do
            local choice = { text = row.name, value = row.id, tooltip = tooltipFor(row) }
            local normal = w:AddCheckboxButton(
                { choice },
                { onChange = onTick, colour = TEXT_COLOUR }
            )
            -- The dimmed copy sits on the normal row (an explicit y keeps it out of the flow).
            local dimmed = w:AddCheckboxButton(
                { choice },
                { onChange = onTick, colour = DONE_COLOUR, y = normal.root.y }
            )
            rowWidgets[row.id] = { normal = normal, dimmed = dimmed }
            showDone(row.id, row.done)
        end
    end
end

---------------------------------------------------------------------------
-- Settings view
---------------------------------------------------------------------------

-- A chore was picked or unpicked.
---@param _ prettyui.CheckboxButton
---@param _values any[]
---@param id string
---@param picked boolean
local function onPick(_, _values, id, picked)
    if picked then
        tracker = state.select(tracker, chores, id)
    else
        tracker = state.deselect(tracker, id)
    end
end

---@param w prettyui.Window
---@param openList fun()
local function buildSettings(w, openList)
    w:AddSpriteButton("BACK", openList, { size = BUTTON_SIZE, tooltip = "Back to the list" })
    for _, p in ipairs(period.PERIODS) do
        local choices = {}
        for _, chore in ipairs(chores) do
            if chore.period == p then
                choices[#choices + 1] = {
                    text = chore.shop and chore.name .. " (shop)" or chore.name,
                    value = chore.id,
                    selected = state.isSelected(tracker, chore.id),
                    tooltip = tooltipFor(chore),
                }
            end
        end
        if #choices > 0 then
            w:AddTitle(view.TITLES[p])
            w:AddCheckboxButton(choices, { onChange = onPick })
        end
    end
end

---------------------------------------------------------------------------
-- The window and its collapsed button
---------------------------------------------------------------------------

local collapse -- defined below; the window's hamburger calls it

-- (Re)build the window for the current mode at `layout`. There's no PrettyUI call to clear
-- a window's content, so switching views rebuilds the window where it was.
---@param layout { x: number, y: number, width: number, height: number }
local function buildWindow(layout)
    if win then win:Destroy() end
    rowWidgets, headings = {}, {}
    local w = prettyui.Window.new(parent, {
        title = "Chores",
        x = layout.x,
        y = layout.y,
        width = layout.width,
        height = layout.height,
        resizable = true,
        minWidth = MIN_WIDTH,
        minHeight = MIN_HEIGHT,
    })
    win = w
    w.closeButton.hidden = true
    openButton = prettyui.SpriteButton.new(w.root, "MENU", collapse, {
        x = SLOT_X,
        y = SLOT_Y,
        xAnchor = 1.0,
        size = BUTTON_SIZE,
        tooltip = "Collapse",
    })
    if mode == "settings" then
        buildSettings(w, function()
            pendingMode = "list"
        end)
    else
        buildList(w, function()
            pendingMode = "settings"
        end)
    end
end

-- Switch to `to`, keeping the window's position and size.
---@param to string
local function switchView(to)
    assert(win, "views are switched from the open window")
    mode = to
    local r = win.root
    buildWindow({ x = r.x, y = r.y, width = r.width, height = r.height })
end

local expand

-- Close the window and put a lone hamburger where the window's was.
collapse = function()
    assert(win and openButton, "the window's hamburger only exists with the window")
    local x, y = screenPos(openButton.root)
    win:Close()
    collapsed = prettyui.Panel.new(parent, {
        x = x,
        y = y,
        width = BUTTON_SIZE,
        height = BUTTON_SIZE,
        backgroundAlpha = 0,
        scrollable = false,
    })
    collapsedButton = prettyui.SpriteButton.new(collapsed.root, "MENU", expand, {
        size = BUTTON_SIZE,
        tooltip = "Chores (Alt-drag to move)",
    })
    say("collapsed at", x, y)
end

-- Re-open the window so its hamburger lands on the collapsed one, then drop the panel.
expand = function()
    assert(win and collapsed and collapsedButton, "the collapsed button only exists collapsed")
    local x, y = screenPos(collapsedButton.root)
    local r = win.root
    -- Kept inside the plugin layer: near an edge the window shifts, off the button's spot.
    local wx = clamp(x - (r.width + SLOT_X), 0, parent.width - r.width)
    local wy = clamp(y - SLOT_Y, 0, parent.height - r.height)
    -- A bare SetPos is snapped back by PrettyUI; SetSize after it makes the spot stick.
    r:SetPos(wx, wy)
    win:SetSize(r.width, r.height)
    win:Show()
    collapsed.root.hidden = true
    retiring, collapsed, collapsedButton = collapsed, nil, nil
    say("expanded from", x, y)
end

---------------------------------------------------------------------------
-- Start and stop
---------------------------------------------------------------------------

Event.Logic.Subscribe("chore-tracker", function()
    if retiring then
        retiring:Destroy()
        retiring = nil
    end
    if pendingMode then
        local to = pendingMode
        pendingMode = nil
        switchView(to)
    end
end)

buildWindow(DEFAULT_LAYOUT)
say("loaded", #chores, "chores")

function PluginShutdown()
    Event.Logic.Unsubscribe("chore-tracker")
    if win then win:Destroy() end
    if collapsed then collapsed:Destroy() end
    if retiring then retiring:Destroy() end
end
