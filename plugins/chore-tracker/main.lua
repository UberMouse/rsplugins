-- Chore Tracker: a checklist of RuneScape's daily, weekly and monthly chores (the list comes
-- from dailyscape, MIT; see data/chores.lua), in a PrettyUI window.
--
-- In the settings view you pick the chores you do; the list then shows them under Daily,
-- Weekly and Monthly headings, and you tick one off by clicking its row, or drag it by its grip
-- to reorder it within its period. Ticks clear themselves when the game clock passes the
-- period's reset (UTC: daily at 00:00, weekly on Wednesday 00:00, monthly on the 1st). Some
-- chores also tick themselves, picked or not: a shop run when you buy at one of its shops and
-- a collection when its notes rise in your backpack near the giver (shell/detect.lua), and
-- others when one of your own game vars changes to show them done (shell/vars.lua; a chore
-- already done at login or while the plugin was off is left to tick by hand). When the plugin
-- ticks a picked chore, or a period's picked chores are all done, a popup celebrates it
-- (shell/popups.lua); settings turn the popups or their sound off. Picks, their order and
-- ticks are saved per character, by display name; the window's place, size and collapsed
-- state (shell/window.lua) and the celebration settings are saved for all characters.
--
-- It reads only what the game already gives your client: the game clock, your own display
-- name and position, your backpack, an open shop's stock and your own game vars. It asks for
-- no permissions, sends nothing to the game or anywhere else, and reads nothing about other
-- players.
--
-- Every console line carries [CHORES] (grep: \[CHORES\]); the display name is never logged.
-- Chores ticked by the plugin and celebrations log "[CHORES] purchase", "collected", "seen" or
-- "celebrate" lines (grep: \[CHORES\] (purchase|collected|seen|celebrate)); README.md's
-- "Console lines" section lists the others.
--
-- Dev checkout only: the dev log tee below also asks for httpAccess and POSTs console lines to a
-- local daemon; scripts/check-submission.sh fails until it is stripped (README, "Before
-- submitting").
--
-- README.md describes everything the plugin does for the player in full.

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
local internals = require("shell/prettyui_internals")
local rows = require("shell/rows")
local store = require("shell/store")
local varDetect = require("shell/vars")
local window = require("shell/window")

-- Every console line from this plugin carries this tag, so it's easy to grep.
local function say(...)
    log("[CHORES]", ...)
end

local BUTTON_SIZE = layout.BUTTON_SIZE

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
-- The open view's components, to update in place: chore id -> its row (list rows or settings
-- rows, whichever view is open; ids are the same in both), and period -> its list heading. Both
-- go with the window.
local rowViews = {} ---@type table<string, ChoreRowView>
local headings = {} ---@type table<string, ui.Text>
-- A view switch left for the next Logic tick. A button's action mustn't destroy the button
-- while PrettyUI is still handling its click, and a view switch rebuilds the window.
local pendingMode = nil ---@type ChoreMode?
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
-- List view
---------------------------------------------------------------------------

-- Bring the list's headings, rows and tooltips up to date with the tracker and the clock,
-- in place: each row changes only what differs (rows.lua).
local function refreshList()
    local win = window.current()
    assert(win, "the list is only refreshed while its window exists")
    for _, section in ipairs(view.view(tracker, chores, clockNow(), shops)) do
        local heading = headings[section.period]
        if heading then heading.content = view.headingText(section) end
        for _, row in ipairs(section.rows) do
            local rowView = rowViews[row.id]
            if rowView then
                rows.show(rowView, view.rowText(row), row.done)
                rows.setTooltip(rowView, view.tooltip(row, view.shopTooltip(row, section.period)))
            end
        end
    end
end

-- Re-fit the rows' names to their widths (ui.Text can't clip, so a name is cut with "..." to
-- stop before the tick box). rows.fit returns at once for a row whose width is unchanged, so
-- fitting every row on each poll costs nothing while the window is idle.
local function refitRows()
    assert(window.current(), "rows are only refitted while the window exists")
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

-- A row was dragged by its grip to `slot` among its period's rows: keep that order, saved for
-- the character. Without a character there is no order to save, so nothing changes.
---@param id string
---@param slot integer
local function onDrop(id, slot)
    if character == nil then return end
    local chore = assert(state.find(chores, id), "a row is only made for a chore in the list")
    local moved = state.move(tracker, chores, id, slot)
    if moved == tracker then return end
    tracker = moved
    store.saveState(character, tracker)
    say(string.format("moved %s to %d in %s", id, slot, chore.period))
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
    -- Each section's row ids, built once for both the layout and the grips.
    local lists = {} ---@type ChoreSectionIds[]
    for i, section in ipairs(sections) do
        local ids = {}
        for j, row in ipairs(section.rows) do
            ids[j] = row.id
        end
        lists[i] = { period = section.period, ids = ids }
    end
    local spots = listlayout.place(lists, top)
    local wheel = internals.wheelHandler(w)
    for _, section in ipairs(sections) do
        headings[section.period] =
            w:AddTitle({ text = view.headingText(section), y = spots.headings[section.period] })
        for _, row in ipairs(section.rows) do
            rowViews[row.id] = rows.new(w.content, spots.rows[row.id], icons[row.id], function()
                onTick(row.id)
            end, { wheel = wheel, grip = true })
        end
    end
    w:SetContentHeight(spots.height)
    refreshList()
    -- The grips' press targets sit over the window, placed from its viewport (see grips.lua).
    local viewport = internals.viewport(w)
    if viewport ~= nil then
        grips.build({
            -- The plugin layer takes children (docs/api-concepts.md, "UI"); GetComponent's
            -- stub types it as a plain component.
            parent = parent --[[@as ui.ComponentCollection]],
            viewport = viewport,
            rows = rowViews,
            sections = lists,
            scrollY = function()
                return internals.scrollPosition(w)
            end,
            scrollTo = function(y)
                w:SetScrollPosition(y)
            end,
            wheel = wheel,
            watchSync = internals.overlaySync(w, parent --[[@as ui.ComponentCollection]]),
            onDrop = onDrop,
        })
    end
end

---------------------------------------------------------------------------
-- Settings view
---------------------------------------------------------------------------

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
    rows.showPick(rowViews[chore.id], view.pickText(chore), picked)
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
-- and a hand-built row per chore below them.
---@param w prettyui.Window
local function buildSettings(w)
    w:AddTitle("Celebrations")
    local switches = w:AddCheckboxButton({
        { text = "Celebration popups", value = "popups", selected = celebrations.popups },
        { text = "Popup sound", value = "sound", selected = celebrations.sound },
    }, { onChange = onCelebrationSetting })
    local groups = view.byPeriod(chores)
    local sections = {} ---@type ChoreSectionIds[]
    for i, group in ipairs(groups) do
        local ids = {}
        for j, chore in ipairs(group.chores) do
            ids[j] = chore.id
        end
        sections[i] = { period = group.period, ids = ids }
    end
    local spots = listlayout.place(sections, switches.root.y + switches.root.height)
    local wheel = internals.wheelHandler(w)
    for _, group in ipairs(groups) do
        w:AddTitle({ text = group.title, y = spots.headings[group.period] })
        for _, chore in ipairs(group.chores) do
            local row = rows.new(w.content, spots.rows[chore.id], icons[chore.id], function()
                onPick(chore)
            end, { wheel = wheel })
            rowViews[chore.id] = row
            rows.showPick(row, view.pickText(chore), state.isSelected(tracker, chore.id))
            rows.setTooltip(row, view.tooltip(chore))
        end
    end
    w:SetContentHeight(spots.height)
end

---------------------------------------------------------------------------
-- The window (its chrome and collapsed button are shell/window.lua's)
---------------------------------------------------------------------------

-- Whether the window shows the settings view. Logged out there is nothing to pick, so the
-- logged-out notice shows whatever the mode.
---@return boolean
local function inSettings()
    return phase ~= "loggedOut" and mode == "settings"
end

-- A new window's content for the current phase and mode.
---@param w prettyui.Window
local function buildContent(w)
    if phase == "loggedOut" then
        w:AddText("Log in to see your chores.")
    elseif inSettings() then
        buildSettings(w)
    else
        buildList(w, function()
            pendingMode = "settings"
        end)
    end
end

window.init({
    parent = parent,
    say = say,
    inSettings = inSettings,
    -- The settings view's way out, in the title-bar slot so it stays in reach however far the
    -- list is scrolled. Like every view switch, it waits a tick.
    backToList = function()
        pendingMode = "list"
    end,
    -- The old window's rows and headings went with it.
    clearViews = function()
        rowViews, headings = {}, {}
    end,
    build = buildContent,
    -- Close hides the rows, and the client sends no mouse-leave to a hidden layer, so a hovered
    -- row would reopen with its hovered box.
    onCollapse = function()
        for _, rowView in pairs(rowViews) do
            rows.unhover(rowView)
        end
    end,
})

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
        if window.current() then window.rebuild(true) end
    elseif clockTicked and phase == "ready" and mode == "list" then
        refreshList()
    end
end

---------------------------------------------------------------------------
-- Start and stop
---------------------------------------------------------------------------

Event.Logic.Subscribe("chore-tracker", function(ev)
    varDetect.tick()
    -- Before the view switch: a panel retired by expand last tick is past its click.
    window.dropRetired()
    if pendingMode then
        mode = pendingMode
        pendingMode = nil
        window.rebuild(false)
    end
    if ev.logicTick % POLL_TICKS == 0 then
        sync(false)
        window.saveLayoutIfChanged()
        refitRows()
    end
    -- Every tick, so a grip's target keeps up with the window moving or scrolling.
    window.tick()
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
-- The login and clock first, so the window opens on the right view.
sync(false)
window.open()
say("loaded", #chores, "chores")

function PluginShutdown()
    Event.Logic.Unsubscribe("chore-tracker")
    Event.VarTransmit.Unsubscribe("chore-tracker")
    Event.InventoryAdded.Unsubscribe("chore-tracker")
    Event.InventoryUpdated.Unsubscribe("chore-tracker")
    Event.InventoryRemoved.Unsubscribe("chore-tracker")
    window.shutdown()
    popups.clear()
    if tee then tee.shutdown() end -- dev only: the tee's own Logic subscription
end
