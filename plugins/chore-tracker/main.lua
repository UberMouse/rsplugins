-- Chore Tracker: a checklist of RuneScape's daily, weekly and monthly chores (the list from
-- dailyscape, MIT; see data/chores.lua), drawn with PrettyUI.
--
--   * The window lists the chores you picked, grouped Daily / Weekly / Monthly, each headed
--     with how many are done. Tick a chore when you've done it; done chores stay in place,
--     dimmed, and a second click unticks them. Hover a chore for its description and wiki
--     links (shown as text: plugins can't open URLs).
--   * The settings button (top left of the content) opens the settings view, which lists
--     every chore to pick from. There, the title bar's top-right slot is a back button to the
--     list, in reach however far the settings are scrolled.
--   * In the list, the hamburger in that slot (where PrettyUI's close X would be) collapses
--     the window into a single hamburger button at the same spot. Alt-drag that
--     button to move it (with the console closed); click it to open the window again, grown
--     left and down from the button.
--   * A chore counts as done until its period resets, by the game clock (UTC): daily at
--     00:00, weekly on Wednesday 00:00, monthly at 00:00 on the 1st. Ticks clear by
--     themselves when the clock passes a reset.
--   * Some chores tick themselves, whether or not they are picked; ticking by hand still
--     works for them and changes no shop's progress.
--       - Shop runs: any purchase at any of a chore's shops (data/shops.lua, where the ones
--         not yet seen in the client are marked unproven) marks it done for the period. A
--         shop is an inventory the client gets only while that shop is open, and its stock
--         is the player's own, so a line whose count drops is the player buying. A shop
--         with a before- and an after-quest inventory counts a purchase in either. A chore
--         with more than one shop shows how many were bought from this period, as "Feather
--         Shop Run (1/4)", and its tooltip lists each shop as bought or not yet.
--       - Collections (data/collections.lua): Dell Monti's apples and pineapples and the
--         Weird Old Man's potato cacti (unproven) arrive as banknotes in the backpack, so
--         such a chore ticks when its notes rise while the player is within 10 tiles of
--         the giver, on the same plane. shell/detect.lua does these two, reading only the
--         listed shops' inventories, the backpack and the player's own tile.
--       - Game vars (data/vars.lua): Bert's, Geoffrey's, Cromperty's and Coeden's freebies,
--         the Daily Challenge, Advance Time, Divine Locations and 16 more daily, weekly and
--         monthly chores (marked unproven there) tick when one of the
--         player's own VarPlayer vars changes so that the chore's rule turns true (the
--         Daily Challenge's when its count of claimed challenges rises, so any claim of a
--         challenge's reward ticks it). A rule
--         already true when first read never ticks, nor does one turning true within 10
--         seconds of loading or a character switch (the login's burst of vars), so a chore
--         done while the plugin was off is left to tick by hand. shell/vars.lua does this,
--         reading only the vars those rules name; no var's value is shown.
--     Each chore they tick (or shop first recorded in a period) logs "[CHORES] purchase
--     <chore id> at <shop>", "[CHORES] collected <chore id> near <giver>" or "[CHORES] seen
--     <chore id> done (<var>)" (grep: \[CHORES\] (purchase|collected|seen)).
--   * Picks and ticks are saved per character (by display name) as they change. The window's
--     position, size and collapsed state, and the collapsed button's spot, are saved for all
--     characters. Logged out, the window says so; until the game clock reads, nothing can be
--     ticked.
--
-- It reads only what the game already gives the player's client (an open shop's stock, their
-- own backpack, position and game vars): no permissions, nothing sent to the game, nothing
-- about other players. Console lines carry [CHORES] (grep: \[CHORES\]); the display name is never
-- logged.
--
-- The collapsed button is a PrettyUI Panel exactly the button's size (20x20), with no
-- background, scrolling off, and the hamburger as a child of the Panel's own root at its
-- origin, so the button covers the Panel's 4 px frame. A Panel always draws that frame, but
-- it is what makes Alt-drag work, and the button's screen spot is then the Panel's own.
-- The Panel is made on collapse and destroyed on expand: kept hidden while the window is
-- open, it would still take Alt-drags, and so clicks, over the window's hamburger.

local chores = require("data/chores")
local collections = require("data/collections")
local shops = require("data/shops")
local varRules = require("data/vars")
local layout = require("core/layout")
local state = require("core/state")
local view = require("core/view")
local detect = require("shell/detect")
local store = require("shell/store")
local varDetect = require("shell/vars")

-- Every console line from this plugin carries this tag, so it's easy to grep.
local function say(...)
    log("[CHORES]", ...)
end

local BUTTON_SIZE = layout.BUTTON_SIZE

-- The smallest the window can be resized to.
local MIN_WIDTH, MIN_HEIGHT = 240, 160

-- Row text colours (0xRRGGBBAA): PrettyUI 1.2.0's default for a choice, and a dimmed one
-- for done rows.
local TEXT_COLOUR = 0xE7D7B0FF
local DONE_COLOUR = 0x7A7262FF

-- The window hamburger's tooltip. A table, so SetTooltip replaces it (see collapseAt).
local COLLAPSE_TOOLTIP = { text = "Collapse" }
-- The same slot's tooltip while the settings view is open.
local BACK_TOOLTIP = { text = "Back to the list" }

-- Tooltips wrap at this width; wiki URLs are long.
local TOOLTIP_WIDTH = 360

---@alias ChoreTooltip { text: string, maxWidth: integer }

-- How often, in Logic ticks (50 a second), to look for a login change and a moved or
-- resized window.
local POLL_TICKS = 25

-- Minutes since the Unix epoch; a VarTransmit fires as it ticks over. Var ids repeat across
-- domains (VarClient, VarNPC...), so a match needs the domain as well as the id.
local CLOCK = var.VarPlayer.CLOCK_TIME_DATE_MINUTES
local CLOCK_ID, CLOCK_DOMAIN = CLOCK.id, CLOCK.typeName

local parent = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
assert(parent, "the plugin layer should exist once a plugin runs")

-- The logged-in character's display name (used only as their store key, never logged), and
-- their picks and ticks.
local character = nil ---@type string?
local tracker = state.new()
-- What the window shows: logged out, waiting for the game clock, or ready.
---@alias ChorePhase "loggedOut"|"waiting"|"ready"
---@alias ChoreMode "list"|"settings"
local phase = nil ---@type ChorePhase?
local mode = "list" ---@type ChoreMode
local win = nil ---@type prettyui.Window?
-- The title-bar slot's button: the hamburger, or back to the list in settings.
local openButton = nil ---@type prettyui.SpriteButton?
local collapsed = nil ---@type prettyui.Panel? exists only while collapsed
local collapsedButton = nil ---@type prettyui.SpriteButton?
-- The list view's widgets, to update in place: chore id -> its two rows (with the text they
-- were made with), and period -> its heading.
local rowWidgets = {} ---@type table<string, { normal: prettyui.CheckboxButton, dimmed: prettyui.CheckboxButton, text: string, tooltip: ChoreTooltip, done: boolean? }>
local headings = {} ---@type table<string, ui.Text>
-- Work left for the next Logic tick. A button's action mustn't destroy the button while
-- PrettyUI is still handling its click, so a view switch or a row whose text changed (both
-- rebuild the window) and removing the collapsed panel after expanding wait a tick.
local pendingMode = nil ---@type ChoreMode?
local pendingRebuild = false
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

-- A component's on-screen position relative to the plugin layer, in whole pixels.
---@param component ui.Component
---@return integer x
---@return integer y
local function screenPos(component)
    local at, origin = component.xyGlobal, parent.xyGlobal
    return math.floor(at.x - origin.x + 0.5), math.floor(at.y - origin.y + 0.5)
end

-- A chore's tooltip: its description, then `extra` lines (a list row's shops), then its wiki
-- page and any other links, as text.
---@param chore { desc: string, url: string, links: string[] }
---@param extra string[]?
---@return ChoreTooltip
local function tooltipFor(chore, extra)
    local lines = {}
    if chore.desc ~= "" then lines[#lines + 1] = chore.desc end
    for _, line in ipairs(extra or {}) do
        lines[#lines + 1] = line
    end
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

-- Give a row a new tooltip. A table, as in showDone, so a shown one is replaced by a fresh,
-- hidden one rather than left up.
---@param id string
---@param tooltip ChoreTooltip
local function setRowTooltip(id, tooltip)
    local widgets = rowWidgets[id]
    widgets.tooltip = tooltip
    widgets.normal:SetOptionTooltip(id, tooltip)
    widgets.dimmed:SetOptionTooltip(id, tooltip)
end

-- Bring the list's ticks, dimming, counts and tooltips up to date with the tracker and the
-- clock. Only rows that changed are touched, in place, except that PrettyUI 1.2.0 has no
-- call to change a choice's text: a row whose shop count changed means rebuilding the
-- window (next tick, as this can run inside a row's click).
local function refreshList()
    local sections = view.view(tracker, chores, clockNow(), shops)
    for _, section in ipairs(sections) do
        for _, row in ipairs(section.rows) do
            local widgets = rowWidgets[row.id]
            if widgets and widgets.text ~= view.rowText(row) then
                pendingRebuild = true
                return
            end
        end
    end
    for _, section in ipairs(sections) do
        local heading = headings[section.period]
        if heading then heading.content = headingText(section) end
        for _, row in ipairs(section.rows) do
            local widgets = rowWidgets[row.id]
            if widgets then
                local tooltip = tooltipFor(row, view.shopTooltip(row, section.period))
                if tooltip.text ~= widgets.tooltip.text then setRowTooltip(row.id, tooltip) end
                showDone(row.id, row.done)
            end
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
    local sections = view.view(tracker, chores, now, shops)
    if #sections == 0 then
        w:AddText("No chores picked yet: use the settings button above to choose some.")
        return
    end
    for _, section in ipairs(sections) do
        headings[section.period] = w:AddTitle(headingText(section))
        for _, row in ipairs(section.rows) do
            local tooltip = tooltipFor(row, view.shopTooltip(row, section.period))
            local text = view.rowText(row)
            local choice = { text = text, value = row.id, tooltip = tooltip }
            local normal = w:AddCheckboxButton(
                { choice },
                { onChange = onTick, colour = TEXT_COLOUR }
            )
            -- The dimmed copy sits on the normal row (an explicit y keeps it out of the flow).
            local dimmed = w:AddCheckboxButton(
                { choice },
                { onChange = onTick, colour = DONE_COLOUR, y = normal.root.y }
            )
            -- Both start unticked, normal shown and dimmed hidden; showDone swaps them for a
            -- done row.
            dimmed.root.hidden = true
            rowWidgets[row.id] =
                { normal = normal, dimmed = dimmed, text = text, tooltip = tooltip, done = false }
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
local function buildSettings(w)
    for _, group in ipairs(view.byPeriod(chores)) do
        local choices = {}
        for _, chore in ipairs(group.chores) do
            choices[#choices + 1] = {
                text = chore.shop and chore.name .. " (shop)" or chore.name,
                value = chore.id,
                selected = state.isSelected(tracker, chore.id),
                tooltip = tooltipFor(chore),
            }
        end
        w:AddTitle(group.title)
        w:AddCheckboxButton(choices, { onChange = onPick })
    end
end

---------------------------------------------------------------------------
-- The window and its collapsed button
---------------------------------------------------------------------------

local collapse -- defined below; the window's hamburger calls it

-- The settings view's way out, in the title-bar slot so it stays in reach however far the
-- list is scrolled. Like every view switch, it waits a tick.
local function backToList()
    pendingMode = "list"
end

-- (Re)build the window at `at` for the current phase and mode. There's no PrettyUI call to
-- clear a window's content, so a view switch, a login change or the clock starting
-- rebuilds the window where it was.
---@param at { x: integer, y: integer, width: integer, height: integer }
local function buildWindow(at)
    if win then win:Destroy() end
    rowWidgets, headings = {}, {}
    pendingRebuild = false
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
    -- The title-bar slot is the one spot of the title bar the drag layer leaves clickable.
    -- It collapses the window, except in the settings view, where it goes back to the list
    -- (collapsing from there means going back first). A view switch rebuilds the window, so
    -- each view simply makes its own button.
    local settings = phase ~= "loggedOut" and mode == "settings"
    openButton = prettyui.SpriteButton.new(
        w.root,
        settings and "BACK" or "MENU",
        settings and backToList or collapse,
        {
            x = layout.SLOT_X,
            y = layout.SLOT_Y,
            xAnchor = 1.0,
            size = BUTTON_SIZE,
            tooltip = settings and BACK_TOOLTIP or COLLAPSE_TOOLTIP,
        }
    )
    if phase == "loggedOut" then
        w:AddText("Log in to see your chores.")
    elseif settings then
        buildSettings(w)
    else
        buildList(w, function()
            pendingMode = "settings"
        end)
    end
end

-- How far the window's content is scrolled, or nil if that can't be read. PrettyUI 1.2.0
-- can set it (SetScrollPosition) but has no getter, so this reads its internal
-- `_scroll.scrollY`; a version without that field gives nil.
---@return number?
local function scrollPosition()
    assert(win, "the window exists from load to shutdown")
    local scroll = win._scroll
    local y = scroll and scroll.scrollY
    if type(y) == "number" then return y end
    return nil
end

-- Rebuild the window where it is, staying closed if collapsed. With `keepScroll`, the new
-- content is scrolled as far as the old (PrettyUI clamps it to the new content), so a row
-- whose count changed doesn't jump the list to the top; a view switch starts at the top.
---@param keepScroll boolean
local function rebuild(keepScroll)
    assert(win, "the window exists from load to shutdown")
    local r = win.root
    local scrollY = keepScroll and scrollPosition() or nil
    buildWindow({ x = r.x, y = r.y, width = r.width, height = r.height })
    if scrollY then win:SetScrollPosition(scrollY) end
    if collapsed then win:Close() end
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
    local wx, wy = layout.windowForButton(x, y, r.width, r.height, parent.width, parent.height)
    -- A bare SetPos is snapped back by PrettyUI; SetSize after it makes the spot stick.
    r:SetPos(wx, wy)
    win:SetSize(r.width, r.height)
    win:Show()
    collapsed.root.hidden = true
    -- An earlier panel still waiting for the tick is past its click, so it can go now.
    if retiring then retiring:Destroy() end
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
-- Chores the plugin sees done (shell/detect.lua)
---------------------------------------------------------------------------

-- Keep a changed tracker: save it and show it. `changed` the same table as `tracker` means
-- nothing changed, and nothing is written.
---@param changed ChoreState
local function keep(changed)
    assert(character, "a chore is only seen done while logged in")
    if changed == tracker then return end
    tracker = changed
    store.saveState(character, tracker)
    if phase == "ready" and mode == "list" then refreshList() end
end

-- Like a tick by hand, a chore seen done is ignored without a character and a clock to mark
-- it against.
---@param change ChoreChange
local function apply(change)
    local now = clockNow()
    if character == nil or now == nil then return end
    keep(change(tracker, now))
end

detect.init({
    chores = chores,
    shops = shops,
    collections = collections,
    say = say,
    apply = apply,
})
varDetect.init({ chores = chores, rules = varRules, say = say, apply = apply })

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
    ---@type ChorePhase
    local nextPhase = name == nil and "loggedOut" or now == nil and "waiting" or "ready"
    local switched = name ~= character
    if switched then
        character = name
        if name then
            tracker = store.loadState(name, chores)
            say("showing the logged-in character's chores")
        else
            tracker = state.new()
            say("logged out")
        end
        detect.scan()
        varDetect.scan()
    end
    if switched or nextPhase ~= phase then
        if nextPhase == "waiting" and phase ~= "waiting" then say("waiting for the game clock") end
        phase = nextPhase
        if phase == "loggedOut" then mode = "list" end
        -- A view switch clicked in the old content is stale now (it would reopen settings
        -- after a logout).
        pendingMode = nil
        if win then rebuild(true) end
    elseif clockTicked and phase == "ready" and mode == "list" then
        refreshList()
    end
end

---------------------------------------------------------------------------
-- Start and stop
---------------------------------------------------------------------------

Event.Logic.Subscribe("chore-tracker", function(ev)
    varDetect.tick()
    if retiring then
        retiring:Destroy()
        retiring = nil
    end
    if pendingMode then
        mode = pendingMode
        pendingMode = nil
        rebuild(false)
    elseif pendingRebuild then
        rebuild(true)
    end
    if ev.logicTick % POLL_TICKS == 0 then
        sync(false)
        saveLayoutIfChanged()
    end
end)

Event.VarTransmit.Subscribe("chore-tracker", function(ev)
    if ev.var.id == CLOCK_ID and ev.var.typeName == CLOCK_DOMAIN then sync(true) end
    varDetect.onVarTransmit(ev)
end)

Event.InventoryAdded.Subscribe("chore-tracker", detect.onInventoryAdded)
Event.InventoryUpdated.Subscribe("chore-tracker", detect.onInventoryUpdated)
Event.InventoryRemoved.Subscribe("chore-tracker", detect.onInventoryRemoved)

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
    Event.InventoryAdded.Unsubscribe("chore-tracker")
    Event.InventoryUpdated.Unsubscribe("chore-tracker")
    Event.InventoryRemoved.Unsubscribe("chore-tracker")
    if win then
        saveLayoutIfChanged()
        win:Destroy()
    end
    if collapsed then collapsed:Destroy() end
    if retiring then retiring:Destroy() end
end
