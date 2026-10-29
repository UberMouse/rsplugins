-- Chore Tracker: a checklist of RuneScape's daily, weekly and monthly chores (the list from
-- dailyscape, MIT; see data/chores.lua), drawn with PrettyUI.
--
--   * The window lists the chores you picked, grouped Daily / Weekly / Monthly, each headed
--     with how many are done. Each chore is a row with its icon (data/icons.lua: a built-in
--     item icon or interface sprite), its name and a tick box. A click anywhere on the row
--     ticks it; done chores stay in place, ticked, icon and name dimmed, and a second click
--     unticks them. Over any row the cursor is the hyperlink hand and the box shows a
--     hovered sprite. Hover a chore for its description and wiki links (shown as text:
--     plugins can't open URLs).
--   * The settings button (top left of the content) opens the settings view, which has the
--     Celebrations switches and lists every chore to pick from, as the same icon rows under
--     Daily / Weekly / Monthly headings: click a row to pick or unpick it (its box ticks).
--     There, the title bar's top-right slot is a back button to the list, in reach however far
--     the settings are scrolled.
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
--       - Game vars: Bert's, Geoffrey's, Cromperty's and Coeden's freebies, the Daily
--         Challenge, Advance Time, Divine Locations and others in data/vars.lua (unproven
--         ones are marked there) tick when one of the player's own VarPlayer vars changes so
--         that the chore's rule turns true (the Daily Challenge's when its count of claimed
--         challenges rises, so any claim of a challenge's reward ticks it). A rule already
--         true when first read never ticks, nor does one turning true within 10 seconds of
--         loading or a character switch (the login's burst of vars), so a chore done while
--         the plugin was off is left to tick by hand. shell/vars.lua does this, reading only
--         the vars those rules name; no var's value is shown.
--     Each chore they tick (or shop first recorded in a period) logs "[CHORES] purchase
--     <chore id> at <shop>", "[CHORES] collected <chore id> near <giver>" or "[CHORES] seen
--     <chore id> done (<var>)" (grep: \[CHORES\] (purchase|collected|seen)).
--   * Celebrations (shell/popups.lua, core/celebrate.lua): when the plugin ticks a picked chore
--     itself, a PrettyUI AchievementPopup says so ("CHORE COMPLETE", the chore's name), and
--     when a period's picked chores are all done, a bigger one follows ("DAILIES COMPLETE").
--     The second also shows when the last is ticked by hand; picks, unticks, logins and
--     character switches show nothing. One popup at a time in the plugin layer, built-in
--     sounds, dropped at logout, a character switch, shutdown or when turned off. The
--     settings view's Celebrations section turns the popups and their sound off, saved for all
--     characters. Each popup logs "[CHORES] celebrate <chore id>" or "[CHORES] celebrate
--     <period> cleared" (grep: \[CHORES\] (purchase|collected|seen|celebrate) for all the
--     lines above and these).
--   * Picks and ticks are saved per character (by display name) as they change. The window's
--     position, size and collapsed state, and the collapsed button's spot, are saved for all
--     characters, as are the celebration settings. Logged out, the window says so; until the
--     game clock reads, nothing can be ticked.
--
-- It reads only what the game already gives the player's client (an open shop's stock, their
-- own backpack, position and game vars): no permissions, nothing sent to the game, nothing
-- about other players. Console lines carry [CHORES] (grep: \[CHORES\]); the display name is never
-- logged.
--
-- Dev checkout only: the dev log tee below also asks for httpAccess and POSTs console lines to a
-- local daemon; scripts/check-submission.sh fails until it is stripped (README, "Before
-- submitting").
--
-- The rows of both views, list and settings, are built by hand (shell/rows.lua) in the
-- window's content, at spots core/listlayout.lua works out, because PrettyUI 1.2.0's
-- CheckboxButton can't show an icon, be recoloured or be retexted (only the Celebrations
-- switches use it). Ticks, colours, counts and tooltips change in place; the window
-- is rebuilt only for a view switch, a login change or the clock starting or stopping. Two
-- reads of PrettyUI 1.2.0 internals, each guarded so a version without it loses only that:
-- `_scroll.scrollY`, to keep the scroll through such a rebuild (scrollPosition), and the
-- window's `_onScrollWheel`, handed to each row so the wheel over a row still scrolls the window
-- (wheelHandler).
--
-- The collapsed button is a PrettyUI Panel exactly the button's size (20x20), with no
-- background, scrolling off, and the hamburger as a child of the Panel's own root at its
-- origin, so the button covers the Panel's 4 px frame. A Panel always draws that frame, but
-- it is what makes Alt-drag work, and the button's screen spot is then the Panel's own.
-- The Panel is made on collapse and destroyed on expand: kept hidden while the window is
-- open, it would still take Alt-drags, and so clicks, over the window's hamburger.

-- Dev only (remove before submitting, see the README): forwards console output to rsdev.py.
local tee = require("dev/tee") -- nil when dev/ isn't there; see PluginShutdown
if tee then tee.install(_ENV, "chore-tracker") end

local chores = require("data/chores")
local collections = require("data/collections")
local icons = require("data/icons")
local shops = require("data/shops")
local varRules = require("data/vars")
local celebrate = require("core/celebrate")
local layout = require("core/layout")
local listlayout = require("core/listlayout")
local settingsCore = require("core/settings")
local state = require("core/state")
local view = require("core/view")
local detect = require("shell/detect")
local grips = require("shell/grips")
local popups = require("shell/popups")
local rows = require("shell/rows")
local store = require("shell/store")
local varDetect = require("shell/vars")

-- Every console line from this plugin carries this tag, so it's easy to grep.
local function say(...)
    log("[CHORES]", ...)
end

local BUTTON_SIZE = layout.BUTTON_SIZE

-- The smallest the window can be resized to.
local MIN_WIDTH, MIN_HEIGHT = 240, 160

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
-- The open view's components, to update in place: chore id -> its row (list rows or settings
-- rows, whichever view is open; ids are the same in both), and period -> its list heading. Both
-- go with the window.
local rowViews = {} ---@type table<string, ChoreRowView>
local headings = {} ---@type table<string, ui.Text>
-- Work left for the next Logic tick. A button's action mustn't destroy the button while
-- PrettyUI is still handling its click, so a view switch (which rebuilds the window) and
-- removing the collapsed panel after expanding wait a tick.
local pendingMode = nil ---@type ChoreMode?
local retiring = nil ---@type prettyui.Panel?
-- The layout the store holds, so it's written only when the window has really moved.
local savedLayout = nil ---@type ChoreLayout?
-- The celebration settings, for all characters.
local celebrations = settingsCore.default()

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

-- Bring the list's headings, rows and tooltips up to date with the tracker and the clock,
-- in place: each row changes only what differs (rows.lua).
local function refreshList()
    assert(win, "the list is only refreshed while its window exists")
    local content = win.content
    for _, section in ipairs(view.view(tracker, chores, clockNow(), shops)) do
        local heading = headings[section.period]
        if heading then heading.content = headingText(section) end
        for _, row in ipairs(section.rows) do
            local rowView = rowViews[row.id]
            if rowView then
                rows.show(rowView, view.rowText(row), row.done)
                rows.setTooltip(
                    rowView,
                    content,
                    tooltipFor(row, view.shopTooltip(row, section.period))
                )
            end
        end
    end
end

-- Re-fit the rows' names to their widths (ui.Text can't clip, so a name is cut with "..." to
-- stop before the tick box). rows.fit returns at once for a row whose width is unchanged, so
-- fitting every row on each poll costs nothing while the window is idle.
local function refitRows()
    assert(win, "rows are only refitted while the window exists")
    for _, rowView in pairs(rowViews) do
        rows.fit(rowView)
    end
end

-- A row was clicked: tick or untick its chore at the clock's minute, and save. Without a
-- character or a clock there is nothing to mark against, so nothing changes.
---@param id string
local function onTick(id)
    local now = clockNow()
    if character == nil or now == nil then return end
    local chore = state.find(chores, id)
    assert(chore, "a row is only made for a chore in the list")
    local before = tracker
    if state.isDone(tracker, chore, now) then
        tracker = state.unmark(tracker, id)
    else
        tracker = state.mark(tracker, id, now)
    end
    store.saveState(character, tracker)
    refreshList()
    -- A hand tick earns no popup of its own, but the one that clears a period does.
    popups.enqueue(celebrate.decide(before, tracker, chores, now, true))
end

-- How far the window's content is scrolled, or nil if that can't be read. PrettyUI 1.2.0
-- can set it (SetScrollPosition) but has no getter, so this reads its internal
-- `_scroll.scrollY`; a version without that field gives nil. (The plugin's other reads of
-- PrettyUI 1.2.0 state are the rows' wheel handler, `_onScrollWheel`, in wheelHandler, and the
-- window's `viewport`, which buildList hands the grips.)
---@return number?
local function scrollPosition()
    assert(win, "the window exists from load to shutdown")
    local scroll = win._scroll
    local y = scroll and scroll.scrollY
    if type(y) == "number" then return y end
    return nil
end

-- A row was dragged by its grip to `slot` among its period's rows: keep that order, saved for
-- the character. Without a character there is no order to save, so nothing changes.
---@param id string
---@param slot integer
local function onDrop(id, slot)
    if character == nil then return end
    local moved = state.move(tracker, chores, id, slot)
    if moved == tracker then return end
    tracker = moved
    store.saveState(character, tracker)
    local chore = assert(state.find(chores, id), "a row is only made for a chore in the list")
    say(string.format("moved %s to %d in %s", id, slot, chore.period))
end

-- A row swallows the mouse wheel unless it hands it to the window. The handler is PrettyUI
-- 1.2.0-internal, so without it the rows are still made, just without that.
---@param w prettyui.Window
---@return ChoreWheelHandler?
local function wheelHandler(w)
    if type(w._onScrollWheel) == "function" then return w._onScrollWheel end
    return nil
end

-- The list: the settings button and any notice in PrettyUI's flow, then a heading per period
-- and a hand-built row per picked chore below them, at the spots core/listlayout.lua gives.
---@param w prettyui.Window
---@param openSettings fun()
local function buildList(w, openSettings)
    local button =
        w:AddSpriteButton("SETTINGS", openSettings, { size = BUTTON_SIZE, tooltip = "Pick chores" })
    -- The list goes below the last of these, the button or the notice.
    local top = button.root.y + button.root.height
    local now = clockNow()
    if now == nil then
        local notice = w:AddText("Waiting for the game clock.")
        top = notice.y + notice.height
    end
    local sections = view.view(tracker, chores, now, shops)
    if #sections == 0 then
        w:AddText("No chores picked yet: use the settings button above to choose some.")
        return
    end
    local spots = listlayout.place(sections, top)
    local wheel = wheelHandler(w)
    local order = {} ---@type { period: string, ids: string[] }[]
    for _, section in ipairs(sections) do
        headings[section.period] =
            w:AddTitle({ text = headingText(section), y = spots.headings[section.period] })
        local ids = {}
        for _, row in ipairs(section.rows) do
            rowViews[row.id] = rows.new(w.content, spots.rows[row.id], icons[row.id], function()
                onTick(row.id)
            end, wheel, true)
            ids[#ids + 1] = row.id
        end
        order[#order + 1] = { period = section.period, ids = ids }
    end
    w:SetContentHeight(spots.height)
    refreshList()
    -- The grips' press targets sit over the window, placed from its viewport (see grips.lua).
    if w.viewport ~= nil then
        grips.build({
            -- The plugin layer takes children (docs/api-concepts.md, "UI"); GetComponent's
            -- stub types it as a plain component.
            parent = parent --[[@as ui.ComponentCollection]],
            viewport = w.viewport,
            rows = rowViews,
            sections = order,
            scrollY = scrollPosition,
            scrollTo = function(y)
                w:SetScrollPosition(y)
            end,
            wheel = wheel,
            onDrop = onDrop,
        })
    end
end

---------------------------------------------------------------------------
-- Settings view
---------------------------------------------------------------------------

-- A settings row's text: the chore's name, marked when it is a shop run.
---@param chore Chore
---@return string
local function pickText(chore)
    return chore.shop and chore.name .. " (shop)" or chore.name
end

-- A settings row was clicked: pick or unpick its chore, save it straight away and tick or
-- empty the row's box. No celebration: picking is not completing.
---@param chore Chore
local function onPick(chore)
    assert(character, "settings are only built for a logged-in character")
    local picked = not state.isSelected(tracker, chore.id)
    if picked then
        tracker = state.select(tracker, chores, chore.id)
    else
        tracker = state.deselect(tracker, chore.id)
    end
    store.saveState(character, tracker)
    rows.showPick(rowViews[chore.id], pickText(chore), picked)
end

-- A celebration setting was ticked or unticked: apply it and save it for all characters.
---@param _ prettyui.CheckboxButton
---@param _values any[]
---@param setting "popups"|"sound"
---@param on boolean
local function onCelebrationSetting(_, _values, setting, on)
    celebrations[setting] = on
    popups.configure(celebrations)
    store.saveSettings(celebrations)
end

-- The settings view: the Celebrations switches in PrettyUI's flow, then a heading per period
-- and a hand-built row per chore below them (listlayout.place wants sections of rows with ids,
-- which a group's chores are).
---@param w prettyui.Window
local function buildSettings(w)
    w:AddTitle("Celebrations")
    local switches = w:AddCheckboxButton({
        { text = "Celebration popups", value = "popups", selected = celebrations.popups },
        { text = "Popup sound", value = "sound", selected = celebrations.sound },
    }, { onChange = onCelebrationSetting })
    local groups = view.byPeriod(chores)
    local sections = {}
    for i, group in ipairs(groups) do
        sections[i] = { period = group.period, rows = group.chores }
    end
    local spots = listlayout.place(sections, switches.root.y + switches.root.height)
    local wheel = wheelHandler(w)
    for _, group in ipairs(groups) do
        w:AddTitle({ text = group.title, y = spots.headings[group.period] })
        for _, chore in ipairs(group.chores) do
            local row = rows.new(w.content, spots.rows[chore.id], icons[chore.id], function()
                onPick(chore)
            end, wheel)
            rowViews[chore.id] = row
            rows.showPick(row, pickText(chore), state.isSelected(tracker, chore.id))
            rows.setTooltip(row, w.content, tooltipFor(chore))
        end
    end
    w:SetContentHeight(spots.height)
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
    -- The grips' targets go first: they are the plugin layer's, not the window's, and a drag
    -- in progress ends unsaved with its rows.
    grips.clear()
    if win then win:Destroy() end
    rowViews, headings = {}, {}
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
    grips.follow(collapsed == nil)
end

-- Rebuild the window where it is, staying closed if collapsed. With `keepScroll`, the new
-- content is scrolled as far as the old (PrettyUI clamps it to the new content), so a login
-- change or the clock starting doesn't jump the list to the top; a view switch starts at the
-- top.
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
    -- it only with the window, and it would be back on the next Show. Replacing it with a
    -- table leaves a fresh, hidden one (a string would only retext it: PrettyUI 1.2.0's
    -- Tooltip.set, src/tooltip.lua).
    openButton:SetTooltip(COLLAPSE_TOOLTIP)
    -- Close hides the rows, and the client sends no mouse-leave to a hidden layer, so a hovered
    -- row would reopen with its hovered box.
    for _, rowView in pairs(rowViews) do
        rows.unhover(rowView)
    end
    win:Close()
    grips.follow(false)
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
    -- Show brings the window to the front, over the grips' targets.
    grips.raise()
    grips.follow(true)
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
    local before = tracker
    local changed = change(tracker, now)
    keep(changed)
    popups.enqueue(celebrate.decide(before, changed, chores, now, false))
end

popups.init({ parent = parent, say = say })
rows.init({ say = say })

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
        popups.clear()
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
    end
    if ev.logicTick % POLL_TICKS == 0 then
        sync(false)
        saveLayoutIfChanged()
        refitRows()
    end
    -- Every tick, so a grip's target keeps up with the window moving or scrolling.
    grips.follow(collapsed == nil)
end)

Event.VarTransmit.Subscribe("chore-tracker", function(ev)
    if ev.var.id == CLOCK_ID and ev.var.typeName == CLOCK_DOMAIN then sync(true) end
    varDetect.onVarTransmit(ev)
end)

Event.InventoryAdded.Subscribe("chore-tracker", detect.onInventoryAdded)
Event.InventoryUpdated.Subscribe("chore-tracker", detect.onInventoryUpdated)
Event.InventoryRemoved.Subscribe("chore-tracker", detect.onInventoryRemoved)

celebrations = store.loadSettings()
popups.configure(celebrations)
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
    grips.clear()
    if win then
        saveLayoutIfChanged()
        win:Destroy()
    end
    if collapsed then collapsed:Destroy() end
    if retiring then retiring:Destroy() end
    popups.clear()
    if tee then tee.shutdown() end -- dev only: the tee's own Logic subscription
end
