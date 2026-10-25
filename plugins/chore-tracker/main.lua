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
--     00:00, weekly on Wednesday 00:00, monthly at 00:00 on the 1st. Ticks clear by
--     themselves when the clock passes a reset.
--   * Picks and ticks are saved per character (by display name) as they change. The window's
--     position, size and collapsed state, and the collapsed button's spot, are saved for all
--     characters. Logged out, the window says so; until the game clock reads, nothing can be
--     ticked.
--
-- It only shows a list you tick by hand: no permissions, nothing sent to the game, nothing
-- about other players. Console lines carry [CHORES] (grep: \[CHORES\]); the display name is
-- never logged.
--
-- The collapsed button is a PrettyUI Panel exactly the button's size (20x20), with no
-- background, scrolling off, and the hamburger as a child of the Panel's own root at its
-- origin, so the button covers the Panel's 4 px frame. A Panel always draws that frame, but
-- it is what makes Alt-drag work, and the button's screen spot is then the Panel's own.
-- The Panel is made on collapse and destroyed on expand: kept hidden while the window is
-- open, it would still take Alt-drags, and so clicks, over the window's hamburger.

local chores = require("data/chores")
local layout = require("core/layout")
local period = require("core/period")
local state = require("core/state")
local view = require("core/view")
local store = require("shell/store")

-- Every console line from this plugin carries this tag, so it's easy to grep.
local function say(...)
    log("[CHORES]", ...)
end

-- PrettyUI's close X is 20 px; the hamburger takes its slot (layout.SLOT_X, SLOT_Y).
local BUTTON_SIZE = 20

-- The smallest the window can be resized to.
local MIN_WIDTH, MIN_HEIGHT = 240, 160

-- Row text colours (0xRRGGBBAA): PrettyUI 1.2.0's default for a choice, and a dimmed one
-- for done rows.
local TEXT_COLOUR = 0xE7D7B0FF
local DONE_COLOUR = 0x7A7262FF

-- The window hamburger's tooltip. A table, so SetTooltip replaces it (see collapseAt).
local COLLAPSE_TOOLTIP = { text = "Collapse" }

-- Tooltips wrap at this width; wiki URLs are long.
local TOOLTIP_WIDTH = 360

-- How often, in Logic ticks (50 a second), to look for a login change and a moved or
-- resized window.
local POLL_TICKS = 25

-- Minutes since the Unix epoch; a VarTransmit fires as it ticks over.
local CLOCK = var.VarPlayer.CLOCK_TIME_DATE_MINUTES
local CLOCK_ID = CLOCK.id

local parent = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
assert(parent, "the plugin layer should exist once a plugin runs")

-- The logged-in character's display name (used only as their store key, never logged), and
-- their picks and ticks.
local character = nil ---@type string?
local tracker = state.new()
-- What the window shows: "loggedOut", "waiting" (for the game clock) or "ready".
local phase = nil ---@type string?
local mode = "list" -- or "settings"
local win = nil ---@type prettyui.Window?
local openButton = nil ---@type prettyui.SpriteButton? the hamburger in the window
local collapsed = nil ---@type prettyui.Panel? exists only while collapsed
local collapsedButton = nil ---@type prettyui.SpriteButton?
-- The list view's widgets, to update in place: chore id -> its two rows, and period ->
-- its heading.
local rowWidgets = {} ---@type table<string, { normal: prettyui.CheckboxButton, dimmed: prettyui.CheckboxButton, tooltip: prettyui.Tooltip, done: boolean? }>
local headings = {} ---@type table<string, ui.Text>
-- Work left for the next Logic tick. A button's action mustn't destroy the button while
-- PrettyUI is still handling its click, so a view switch (which rebuilds the window) and
-- removing the collapsed panel after expanding wait a tick.
local pendingMode = nil ---@type string?
local retiring = nil ---@type prettyui.Panel?
-- The layout the store holds, so it's written only when the window has really moved.
local savedLayout = nil ---@type ChoreLayout?

---------------------------------------------------------------------------
-- Reading the game
---------------------------------------------------------------------------

-- The game clock, or nil until it reads (logged out, loading).
---@return integer?
local function clockNow()
    local minutes = CLOCK.value
    if type(minutes) == "number" and minutes > 0 then return math.tointeger(minutes) end
    return nil
end

-- The logged-in character's display name, or nil when logged out or loading.
---@return string?
local function currentName()
    if not Player.IsAvailable() then return nil end
    local entity = Player.GetEntity()
    return entity and entity.displayName or nil
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

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
    if widgets.done == done then return end
    widgets.done = done
    widgets.normal:SetSelected(id, done, false)
    widgets.dimmed:SetSelected(id, done, false)
    local showing, hiding = widgets.normal, widgets.dimmed
    if done then
        showing, hiding = widgets.dimmed, widgets.normal
    end
    showing.root.hidden = false
    hiding.root.hidden = true
    -- A shown tooltip hides only on its own row's mouse-leave, which a hidden row never gets,
    -- so the hidden copy's tooltip would stay up. Replacing it with the same table (not a
    -- string, which only retexts it) gives a fresh, hidden one: PrettyUI 1.2.0's
    -- SetOptionTooltip behaviour, read from its source (src/tooltip.lua, Tooltip.set).
    hiding:SetOptionTooltip(id, widgets.tooltip)
end

-- Bring the list's ticks, dimming and counts up to date with the tracker and the clock, in
-- place. Only rows whose done state changed are touched.
local function refreshList()
    for _, section in ipairs(view.view(tracker, chores, clockNow())) do
        local heading = headings[section.period]
        if heading then heading.content = headingText(section) end
        for _, row in ipairs(section.rows) do
            if rowWidgets[row.id] then showDone(row.id, row.done) end
        end
    end
end

-- A row was ticked or unticked by the player: mark it at the clock's minute and save.
---@param group prettyui.CheckboxButton
---@param _values any[]
---@param id string
---@param ticked boolean
local function onTick(group, _values, id, ticked)
    local now = clockNow()
    if character == nil or now == nil then
        -- Nothing to mark against yet: put the box back.
        group:SetSelected(id, not ticked, false)
        return
    end
    if ticked then
        tracker = state.mark(tracker, id, now)
    else
        tracker = state.unmark(tracker, id)
    end
    store.saveState(character, tracker)
    refreshList()
end

---@param w prettyui.Window
---@param openSettings fun()
local function buildList(w, openSettings)
    w:AddSpriteButton("SETTINGS", openSettings, { size = BUTTON_SIZE, tooltip = "Pick chores" })
    local now = clockNow()
    if now == nil then w:AddText("Waiting for the game clock.") end
    local sections = view.view(tracker, chores, now)
    if #sections == 0 then
        w:AddText("No chores picked yet: use the settings button above to choose some.")
        return
    end
    for _, section in ipairs(sections) do
        headings[section.period] = w:AddTitle(headingText(section))
        for _, row in ipairs(section.rows) do
            local tooltip = tooltipFor(row)
            local choice = { text = row.name, value = row.id, tooltip = tooltip }
            local normal = w:AddCheckboxButton(
                { choice },
                { onChange = onTick, colour = TEXT_COLOUR }
            )
            -- The dimmed copy sits on the normal row (an explicit y keeps it out of the flow).
            local dimmed = w:AddCheckboxButton(
                { choice },
                { onChange = onTick, colour = DONE_COLOUR, y = normal.root.y }
            )
            -- Both start unticked and shown; showDone settles which one stays.
            dimmed.root.hidden = true
            rowWidgets[row.id] =
                { normal = normal, dimmed = dimmed, tooltip = tooltip, done = false }
            showDone(row.id, row.done)
        end
    end
end

---------------------------------------------------------------------------
-- Settings view
---------------------------------------------------------------------------

-- A chore was picked or unpicked: save it straight away.
---@param _ prettyui.CheckboxButton
---@param _values any[]
---@param id string
---@param picked boolean
local function onPick(_, _values, id, picked)
    assert(character, "settings are only built for a logged-in character")
    if picked then
        tracker = state.select(tracker, chores, id)
    else
        tracker = state.deselect(tracker, id)
    end
    store.saveState(character, tracker)
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

-- (Re)build the window at `at` for the current phase and mode. There's no PrettyUI call to
-- clear a window's content, so a view switch, a login change or the clock starting
-- rebuilds the window where it was.
---@param at { x: integer, y: integer, width: integer, height: integer }
local function buildWindow(at)
    if win then win:Destroy() end
    rowWidgets, headings = {}, {}
    local w = prettyui.Window.new(parent, {
        title = "Chores",
        x = at.x,
        y = at.y,
        width = at.width,
        height = at.height,
        resizable = true,
        minWidth = MIN_WIDTH,
        minHeight = MIN_HEIGHT,
    })
    win = w
    w.closeButton.hidden = true
    openButton = prettyui.SpriteButton.new(w.root, "MENU", collapse, {
        x = layout.SLOT_X,
        y = layout.SLOT_Y,
        xAnchor = 1.0,
        size = BUTTON_SIZE,
        tooltip = COLLAPSE_TOOLTIP,
    })
    if phase == "loggedOut" then
        w:AddText("Log in to see your chores.")
    elseif mode == "settings" then
        buildSettings(w, function()
            pendingMode = "list"
        end)
    else
        buildList(w, function()
            pendingMode = "settings"
        end)
    end
end

-- Rebuild the window where it is, staying closed if collapsed.
local function rebuild()
    assert(win, "the window exists from load to shutdown")
    local r = win.root
    buildWindow({ x = r.x, y = r.y, width = r.width, height = r.height })
    if collapsed and win then win:Close() end
end

local expand

-- Close the window and put a lone hamburger at (x, y) in the plugin layer.
---@param x integer
---@param y integer
local function collapseAt(x, y)
    assert(win and openButton, "the window's hamburger only exists with the window")
    -- The hamburger's tooltip is drawn inside the window, not in its content, so Close hides
    -- it only with the window, and it would be back on the next Show. Replacing it (with a
    -- table, as in showDone) leaves a fresh, hidden one.
    openButton:SetTooltip(COLLAPSE_TOOLTIP)
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
end

-- The window's hamburger: collapse where it is.
collapse = function()
    assert(openButton, "the window's hamburger called this")
    local x, y = screenPos(openButton.root)
    collapseAt(x, y)
    say("collapsed at", x, y)
end

-- Re-open the window so its hamburger lands on the collapsed one, then drop the panel.
expand = function()
    assert(win and collapsed and collapsedButton, "the collapsed button only exists collapsed")
    local x, y = screenPos(collapsedButton.root)
    local r = win.root
    -- Kept inside the plugin layer: near an edge the window shifts, off the button's spot.
    local wx = clamp(x - (r.width + layout.SLOT_X), 0, parent.width - r.width)
    local wy = clamp(y - layout.SLOT_Y, 0, parent.height - r.height)
    -- A bare SetPos is snapped back by PrettyUI; SetSize after it makes the spot stick.
    r:SetPos(wx, wy)
    win:SetSize(r.width, r.height)
    win:Show()
    collapsed.root.hidden = true
    retiring, collapsed, collapsedButton = collapsed, nil, nil
    say("expanded from", x, y)
end

-- Where everything is now, as a layout to save.
---@return ChoreLayout
local function currentLayout()
    assert(win and openButton, "the window exists from load to shutdown")
    local r = win.root
    local button = collapsedButton and collapsedButton.root or openButton.root
    local bx, by = screenPos(button)
    return {
        x = r.x,
        y = r.y,
        width = r.width,
        height = r.height,
        collapsed = collapsed ~= nil,
        buttonX = bx,
        buttonY = by,
    }
end

-- Save the layout if it differs from what the store holds.
local function saveLayoutIfChanged()
    local now = currentLayout()
    if savedLayout and layout.same(savedLayout, now) then return end
    store.saveLayout(now)
    savedLayout = now
end

---------------------------------------------------------------------------
-- Following the game
---------------------------------------------------------------------------

-- Catch up with the login and the clock. A new character (or logging out) loads their
-- state; a change of phase rebuilds the window. Otherwise, when the clock ticked, the list
-- updates in place, which is all a reset needs: a mark from before a period's start no
-- longer counts as done.
---@param clockTicked boolean
local function sync(clockTicked)
    local name = currentName()
    local now = clockNow()
    local nextPhase = name == nil and "loggedOut" or now == nil and "waiting" or "ready"
    local switched = name ~= character
    if switched then
        character = name
        if name then
            tracker = store.loadState(name)
            say("showing the logged-in character's chores")
        else
            tracker = state.new()
            say("logged out")
        end
    end
    if switched or nextPhase ~= phase then
        if nextPhase == "waiting" and phase ~= "waiting" then say("waiting for the game clock") end
        phase = nextPhase
        if phase == "loggedOut" then mode = "list" end
        if win then rebuild() end
    elseif clockTicked and phase == "ready" and mode == "list" then
        refreshList()
    end
end

---------------------------------------------------------------------------
-- Start and stop
---------------------------------------------------------------------------

Event.Logic.Subscribe("chore-tracker", function(ev)
    if retiring then
        retiring:Destroy()
        retiring = nil
    end
    if pendingMode then
        mode = pendingMode
        pendingMode = nil
        rebuild()
    end
    if ev.logicTick % POLL_TICKS == 0 then
        sync(false)
        saveLayoutIfChanged()
    end
end)

Event.VarTransmit.Subscribe("chore-tracker", function(ev)
    if ev.var.id == CLOCK_ID then sync(true) end
end)

sync(false)
-- The layout as stored, then fitted to the plugin layer. savedLayout keeps the stored one,
-- so a layout that had to be moved in gets saved at the next check.
savedLayout = store.loadLayout()
local start =
    layout.clamp(savedLayout, parent.width, parent.height, MIN_WIDTH, MIN_HEIGHT, BUTTON_SIZE)
buildWindow(start)
if start.collapsed then collapseAt(start.buttonX, start.buttonY) end
say("loaded", #chores, "chores")

function PluginShutdown()
    Event.Logic.Unsubscribe("chore-tracker")
    Event.VarTransmit.Unsubscribe("chore-tracker")
    if win then
        saveLayoutIfChanged()
        win:Destroy()
    end
    if collapsed then collapsed:Destroy() end
    if retiring then retiring:Destroy() end
end
