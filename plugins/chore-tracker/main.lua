-- Chore Tracker: a checklist of RuneScape's daily, weekly and monthly chores (the list comes
-- from dailyscape, MIT; see data/chores.lua), in a PrettyUI window.
--
-- In the settings view you pick the chores you do; the list then shows them under Daily,
-- Weekly and Monthly headings, and you tick one off by clicking its row, or drag it by its grip
-- to reorder it within its period. Ticks clear themselves when the game clock passes the
-- period's reset (UTC: daily at 00:00, weekly on Wednesday 00:00, monthly on the 1st). Some
-- chores also tick themselves, picked or not. A shop run ticks once you have bought from as
-- many of its shops as it needs this period (all of them, or fewer set in the Shop runs
-- block); a collection when its notes rise in your backpack near the giver (shell/detect.lua);
-- others when one of your own game vars changes to show them done (shell/vars.lua). A chore
-- already done at login or while the plugin was off is left to tick by hand. When the plugin
-- ticks a picked chore, or a period's picked chores are all done, a popup celebrates it
-- (shell/popups.lua); settings turn the popups or their sound off. Picks, their order, ticks
-- and shop-run counts are saved per character, by display name; the window's place, size and
-- collapsed state (shell/window.lua) and the celebration settings are saved for all characters.
-- Collapsed, the window becomes a strip showing the next chore not done, Daily first, then
-- Weekly, then Monthly, in the player's order, which a click ticks (shell/strip.lua). The info
-- button beside the settings button opens the info view: a little help, then every chore
-- under Automatic, Unproven or Manual, by whether it ticks itself (core/info.lua).
--
-- It reads only what the game already gives your client: the game clock, your own display
-- name and position, your backpack, an open shop's stock and your own game vars. It asks for
-- no permissions, sends nothing to the game or anywhere else, and reads nothing about other
-- players.
--
-- Every console line carries [CHORES] (grep: \[CHORES\]); the display name is never logged.
-- Chores ticked by the plugin and celebrations log "[CHORES] purchase", "collected", "seen" or
-- "celebrate" lines (grep: \[CHORES\] (purchase|collected|seen|celebrate)), and a shop run's
-- count set in settings logs "[CHORES] shops needed <chore id> <n>"; README.md's "Console
-- lines" section lists the others.
--
-- Dev checkout only: the dev log tee below also asks for httpAccess and POSTs console lines to a
-- local daemon, and dev/remote runs Lua the daemon sends; scripts/check-submission.sh fails
-- until both are stripped (README, "Before submitting").
--
-- README.md describes everything the plugin does for the player in full.

-- Dev only (remove before submitting, see the README): forwards console output to rsdev.py, and
-- runs `rsdev.py eval --plugin chore-tracker` snippets in this plugin.
local tee = require("dev/tee") -- nil when dev/ isn't there; see PluginShutdown
local remote = require("dev/remote")
if tee then tee.install(_ENV, "chore-tracker") end
if remote then remote.install(_ENV, tee) end

local chores = require("data/chores")
local collections = require("data/collections")
local icons = require("data/icons")
local shops = require("data/shops")
local varRules = require("data/vars")
local celebrate = require("core/celebrate")
local info = require("core/info")
local layout = require("core/layout")
local listlayout = require("core/listlayout")
local settings = require("core/settings")
local state = require("core/state")
local view = require("core/view")
local detect = require("shell/detect")
local grips = require("shell/grips")
local popups = require("shell/popups")
local prettyuiInternals = require("shell/prettyui_internals")
local rows = require("shell/rows")
local stepper = require("shell/stepper")
local store = require("shell/store")
local vars = require("shell/vars")
local window = require("shell/window")

-- Every console line from this plugin carries this tag, so it's easy to grep.
local function say(...)
    log("[CHORES]", ...)
end

local BUTTON_SIZE = layout.BUTTON_SIZE
-- The space between the list's settings and info buttons.
local BUTTON_GAP = 6

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
---@alias ChoreMode "list"|"settings"|"info"
local phase = nil ---@type ChorePhase?
local mode = "list" ---@type ChoreMode
-- The open view's components, to update in place: chore id -> its row (list, settings or info
-- rows, whichever view is open; ids are the same in all), and period -> its list heading. Both
-- go with the window.
local rowViews = {} ---@type table<string, ChoreRowView>
local headings = {} ---@type table<string, ui.Text>
-- The settings view's Shop runs lines, refitted with the rows; they go with the window too.
local stepperViews = {} ---@type ChoreStepperView[]
-- While the info view is open: the window width its help was wrapped for, and the width at the
-- last poll, to re-lay the help once a resize settles. They go with the window too.
local helpWidth = nil ---@type integer?
local polledWidth = nil ---@type integer?
-- A view switch left for the next Logic tick. A button's action mustn't destroy the button
-- while PrettyUI is still handling its click, and a view switch rebuilds the window.
local pendingMode = nil ---@type ChoreMode?
-- The celebration settings, for all characters.
local celebrations = settings.default()

-- Dev only (remove before submitting): the state above, for `rsdev.py eval --plugin` snippets
-- and press(). A getter, since tracker, mode and phase are replaced as the plugin runs.
if remote then
    remote.expose("main", function()
        return {
            rows = rowViews,
            steppers = stepperViews,
            headings = headings,
            tracker = tracker,
            mode = mode,
            phase = phase,
            celebrations = celebrations,
        }
    end)
end

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

-- Bring the list's headings, rows and tooltips, and the collapsed strip, up to date with the
-- tracker and the clock, in place: each row changes only what differs (rows.lua).
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
    window.refreshStrip()
end

-- Re-fit the rows' names to their widths (ui.Text can't clip, so a name is cut with "..." to
-- stop before the tick box), and the Shop runs lines' names likewise. rows.fit and
-- stepper.fit return at once when the width is unchanged, so fitting them all on each poll
-- costs nothing while the window is idle.
local function refitRows()
    assert(window.current(), "rows are only refitted while the window exists")
    for _, rowView in pairs(rowViews) do
        rows.fit(rowView)
    end
    for _, stepperView in ipairs(stepperViews) do
        stepper.fit(stepperView)
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

-- A section's row ids from its rows or chores, top to bottom.
---@param period ChorePeriod|ChoreStatus the section's heading key
---@param items {id: string}[]
---@return ChoreSectionIds
local function sectionIds(period, items)
    local ids = {}
    for i, item in ipairs(items) do
        ids[i] = item.id
    end
    return { period = period, ids = ids }
end

-- The list: the settings button and any notice in PrettyUI's flow, with the info button beside
-- the settings button, then a heading per period and a hand-built row per picked chore below
-- them, at the spots core/listlayout.lua gives.
---@param w prettyui.Window
---@param openSettings fun()
---@param openInfo fun()
local function buildList(w, openSettings, openInfo)
    local button =
        w:AddSpriteButton("SETTINGS", openSettings, { size = BUTTON_SIZE, tooltip = "Pick chores" })
    -- At an explicit x and y, so it sits on the settings button's row and the flow doesn't move.
    w:AddSpriteButton("INFO", openInfo, {
        x = button.root.x + BUTTON_SIZE + BUTTON_GAP,
        y = button.root.y,
        size = BUTTON_SIZE,
        tooltip = "About Chore Tracker",
    })
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
        lists[i] = sectionIds(section.period, section.rows)
    end
    local spots = listlayout.place(lists, top)
    local wheel = prettyuiInternals.wheelHandler(w)
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
    local viewport = prettyuiInternals.viewport(w)
    if viewport ~= nil then
        grips.build({
            -- The plugin layer takes children (docs/api-concepts.md, "UI"); GetComponent's
            -- stub types it as a plain component.
            parent = parent --[[@as ui.ComponentCollection]],
            viewport = viewport,
            rows = rowViews,
            sections = lists,
            scrollY = function()
                return prettyuiInternals.scrollPosition(w)
            end,
            scrollTo = function(y)
                w:SetScrollPosition(y)
            end,
            wheel = wheel,
            watchSync = prettyuiInternals.overlaySync(w, parent --[[@as ui.ComponentCollection]]),
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
    rows.showPick(rowViews[chore.id], chore.name, picked)
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

-- A shop-run stepper was clicked: change how many of the chore's shops tick it by `delta`,
-- save it straight away and show the new count. At either end of its range it changes
-- nothing. It never ticks or unticks the chore: the next purchase is judged by the new count.
---@param chore Chore
---@param delta integer
---@param shown ChoreStepperView
local function onShopsNeeded(chore, delta, shown)
    assert(character, "settings are only built for a logged-in character")
    local listed = shops[chore.id]
    local count = state.shopsNeeded(tracker, chore, listed) + delta
    local changed = state.setShopsNeeded(tracker, chore, listed, count)
    if changed == tracker then return end
    tracker = changed
    store.saveState(character, tracker)
    local needed = state.shopsNeeded(tracker, chore, listed)
    stepper.show(shown, view.neededText(needed, #listed))
    say("shops needed", chore.id, needed)
end

-- The Shop runs block: its title next in PrettyUI's flow, then a stepper per chore with more
-- than one listed shop, picked or not. Gives back the block's bottom.
---@param w prettyui.Window
---@param wheel ChoreWheelHandler?
---@return integer
local function buildShopRuns(w, wheel)
    local title = w:AddTitle("Shop runs")
    local settingsLines = view.shopsSettings(tracker, chores, shops)
    local ys, bottom = listlayout.stack(#settingsLines, title.y + title.height)
    for i, line in ipairs(settingsLines) do
        stepperViews[#stepperViews + 1] = stepper.new(
            w.content,
            ys[i],
            line.chore.name,
            view.neededText(line.needed, line.total),
            function(delta, shown)
                onShopsNeeded(line.chore, delta, shown)
            end,
            wheel
        )
    end
    return bottom
end

-- A settings subheading's key in the layout, unique across periods.
---@param p ChorePeriod
---@param category ChoreCategory
---@return string
local function subheadingKey(p, category)
    return p .. "/" .. category
end

-- The settings view: the Celebrations switches and the Shop runs title in PrettyUI's flow,
-- the Shop runs steppers, then a heading per period, a subheading per category within it, and
-- a hand-built row per chore below them.
---@param w prettyui.Window
local function buildSettings(w)
    w:AddTitle("Celebrations")
    w:AddCheckboxButton({
        { text = "Celebration popups", value = "popups", selected = celebrations.popups },
        { text = "Popup sound", value = "sound", selected = celebrations.sound },
    }, { onChange = onCelebrationSetting })
    local wheel = prettyuiInternals.wheelHandler(w)
    local top = buildShopRuns(w, wheel)
    local groups = view.byPeriod(chores)
    local sections = {} ---@type ChoreSectionIds[]
    for i, group in ipairs(groups) do
        local ids, subheads = {}, {}
        for _, subgroup in ipairs(group.subgroups) do
            if subgroup.category then
                subheads[#ids + 1] = subheadingKey(group.period, subgroup.category)
            end
            for _, chore in ipairs(subgroup.chores) do
                ids[#ids + 1] = chore.id
            end
        end
        sections[i] = { period = group.period, ids = ids, subheads = subheads }
    end
    local spots = listlayout.place(sections, top)
    for _, group in ipairs(groups) do
        w:AddTitle({ text = group.title, y = spots.headings[group.period] })
        for _, subgroup in ipairs(group.subgroups) do
            if subgroup.category then
                local key = subheadingKey(group.period, subgroup.category)
                local title = view.CATEGORY_TITLES[subgroup.category]
                rows.newSubheading(w.content, spots.subheadings[key], title)
            end
            for _, chore in ipairs(subgroup.chores) do
                local row = rows.new(w.content, spots.rows[chore.id], icons[chore.id], function()
                    onPick(chore)
                end, { wheel = wheel })
                rowViews[chore.id] = row
                rows.showPick(row, chore.name, state.isSelected(tracker, chore.id))
                rows.setTooltip(row, view.tooltip(chore))
            end
        end
    end
    w:SetContentHeight(spots.height)
end

---------------------------------------------------------------------------
-- Info view
---------------------------------------------------------------------------

-- The info view: the help paragraphs in PrettyUI's flow, each broken into lines that fit the
-- window's width now (core/layout.lua, helpTextWidth; relayInfo below re-lays them after a
-- resize), then a heading per status and a display-only row per chore below them, all from
-- the data files. Nothing here reads the game.
---@param w prettyui.Window
local function buildInfo(w)
    helpWidth = w.root.width
    polledWidth = helpWidth
    local textWidth = layout.helpTextWidth(helpWidth)
    local top = 0
    for _, paragraph in ipairs(info.HELP) do
        local text = w:AddText(rows.wrapText(paragraph, textWidth))
        top = text.y + text.height
    end
    local groups = info.byStatus(chores, shops, collections, varRules)
    local sections = {} ---@type ChoreSectionIds[]
    for i, group in ipairs(groups) do
        sections[i] = sectionIds(group.status, group.chores)
    end
    local spots = listlayout.place(sections, top)
    local wheel = prettyuiInternals.wheelHandler(w)
    for _, group in ipairs(groups) do
        w:AddTitle({ text = info.headingText(group), y = spots.headings[group.status] })
        for _, chore in ipairs(group.chores) do
            local row =
                rows.new(w.content, spots.rows[chore.id], icons[chore.id], nil, { wheel = wheel })
            rowViews[chore.id] = row
            rows.show(row, info.rowName(chore, chores), false)
            rows.setTooltip(row, view.tooltip(chore))
        end
    end
    w:SetContentHeight(spots.height)
end

-- On the poll, rebuild the info view (keeping its scroll) once the window's width differs from
-- the one its help was wrapped for and has stopped changing (core/layout.lua, relayInfo), and
-- no resize drag is in progress, since the rebuild would end it. Nothing in the other views or
-- collapsed.
local function relayInfo()
    local w = window.current()
    assert(w, "the info view is only re-laid while its window exists")
    if helpWidth == nil or window.isCollapsed() then return end
    assert(polledWidth, "buildInfo sets both widths")
    local width = w.root.width
    local settled = layout.relayInfo(helpWidth, polledWidth, width)
    polledWidth = width
    if settled and not prettyuiInternals.resizing(w) then window.rebuild(true) end
end

---------------------------------------------------------------------------
-- The window (its chrome and collapsed button are shell/window.lua's)
---------------------------------------------------------------------------

-- The view the window shows. Logged out there is nothing to pick or tick, so the logged-out
-- notice shows whatever the mode.
---@return ChoreMode|"loggedOut"
local function shownView()
    if phase == "loggedOut" then return "loggedOut" end
    return mode
end

-- What the collapsed strip shows: the next chore not done, or a notice while logged out or
-- waiting for the clock.
---@return ChoreStrip
local function stripContent()
    local notice = phase == "loggedOut" and "Log in to see your chores"
        or phase == "waiting" and "Waiting for the game clock"
        or nil
    local content = view.strip(view.view(tracker, chores, clockNow(), shops), notice)
    if content.id then content.icon = icons[content.id] end
    return content
end

-- A new window's content for the current phase and mode.
---@param w prettyui.Window
local function buildContent(w)
    local shown = shownView()
    if shown == "loggedOut" then
        w:AddText("Log in to see your chores.")
    elseif shown == "settings" then
        buildSettings(w)
    elseif shown == "info" then
        buildInfo(w)
    else
        buildList(w, function()
            pendingMode = "settings"
        end, function()
            pendingMode = "info"
        end)
    end
end

window.init({
    parent = parent,
    say = say,
    -- Settings and info both go back to the list from the title-bar slot.
    awayFromList = function()
        local shown = shownView()
        return shown == "settings" or shown == "info"
    end,
    -- The way back from settings or info, in the title-bar slot so it stays in reach however
    -- far the view is scrolled. Like every view switch, it waits a tick.
    backToList = function()
        pendingMode = "list"
    end,
    -- The old window's rows, headings, Shop runs lines and info widths went with it.
    clearViews = function()
        rowViews, headings, stepperViews = {}, {}, {}
        helpWidth, polledWidth = nil, nil
    end,
    build = buildContent,
    -- Close hides the rows, and the client sends no mouse-leave to a hidden layer, so a hovered
    -- row would reopen with its hovered box.
    onCollapse = function()
        for _, rowView in pairs(rowViews) do
            rows.unhover(rowView)
        end
    end,
    strip = stripContent,
    -- The strip only shows a chore not done, so its click ticks it, as on its list row.
    onStripTick = onTick,
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
vars.init({ chores = chores, rules = varRules, say = say, apply = apply })

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
        vars.scan()
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
    vars.tick()
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
        relayInfo()
        refitRows()
    end
    -- Every tick, so a grip's target keeps up with the window moving or scrolling.
    window.tick()
end)

Event.VarTransmit.Subscribe("chore-tracker", function(ev)
    if ev.var.id == CLOCK_ID and ev.var.typeName == CLOCK_DOMAIN then sync(true) end
    vars.onVarTransmit(ev)
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
    if remote then remote.shutdown() end -- dev only, before the tee it rides on
    if tee then tee.shutdown() end -- dev only: the tee's own Logic subscription
end
