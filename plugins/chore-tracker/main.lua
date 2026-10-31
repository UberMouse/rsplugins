-- Chore Tracker: a checklist of RuneScape's daily, weekly and monthly chores (the list comes
-- from dailyscape, MIT; see data/chores.lua), in a PrettyUI window. You pick the chores you do
-- and tick them off; ticks clear at each period's reset, and some chores tick themselves from
-- what the game shows. README.md describes everything it does for the player.
--
-- It reads only what the game already gives your client: the game clock, your own display name
-- and position, your backpack, an open shop's stock, your Invention machines' output and your
-- own game vars. It asks for no permissions, sends nothing to the game or anywhere else, and
-- reads nothing about other players.
--
-- Saved per character, by display name: picks, their order, ticks, parts done and counts. Saved
-- for all characters: the window's layout and the celebration settings.
--
-- A picked chore the plugin sees done in the game gets a celebration popup; a tick by hand, or
-- one from lowering a chore's count, gets none. A period whose picked chores are now all done
-- gets one however the last was ticked. Settings turn the popups or their sound off.
--
-- Every console line carries [CHORES] (grep: \[CHORES\]); the display name is never logged.
-- README.md's "Console lines" section lists them.
--
-- dev-only:begin
-- Dev checkout only: the dev log tee below also asks for httpAccess and POSTs console lines to a
-- local daemon, and dev/remote runs Lua the daemon sends. scripts/package-plugin.py strips
-- every dev-only span and line from the upload, and check-submission.sh fails on any it missed
-- (media/chore-tracker/listing.md, "Before submitting").
--
-- dev-only:end

-- dev-only:begin
-- Forwards console output to rsdev.py, and runs `rsdev.py eval --plugin chore-tracker` snippets
-- in this plugin.
local tee = require("dev/tee") -- nil when dev/ isn't there; see PluginShutdown
local remote = require("dev/remote")
if tee then tee.install(_ENV, "chore-tracker") end
if remote then remote.install(_ENV, tee) end
-- dev-only:end

local chores = require("data/chores")
local collections = require("data/collections")
local counts = require("data/counts")
local machines = require("data/machines")
local icons = require("data/icons")
local shops = require("data/shops")
local varRules = require("data/vars")
local celebrate = require("core/celebrate")
local info = require("core/info")
local layout = require("core/layout")
local listlayout = require("core/listlayout")
local partsCore = require("core/parts")
local state = require("core/state")
local view = require("core/view")
local detect = require("shell/detect")
local grips = require("shell/grips")
local popups = require("shell/popups")
local prettyuiInternals = require("shell/prettyui_internals")
local rows = require("shell/rows")
local say = require("shell/say").say
local stepper = require("shell/stepper")
local store = require("shell/store")
local vars = require("shell/vars")
local window = require("shell/window")

local BUTTON_SIZE = layout.BUTTON_SIZE

-- Each chore's parts and their default count, from the data files.
local parts = partsCore.build(shops, varRules, counts)

-- How often, in Logic ticks (about 50 a second), to look for a login change and a moved or
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
-- What the window shows: logged out, waiting for the game clock, or ready. Logged out there
-- is nothing to pick or tick, so the window shows a notice and the mode is the list.
---@alias ChorePhase "loggedOut"|"waiting"|"ready"
---@alias ChoreMode "list"|"settings"|"info"
local phase = nil ---@type ChorePhase?
local mode = "list" ---@type ChoreMode

-- The open window's views, kept to update in place. All of them go with the window, so
-- clearViews starts a fresh set each time it is rebuilt.
---@class ChoreViews
---@field rows table<string, ChoreRowView> chore id -> its row in the open view (list, settings
--- or info: ids are the same in all)
---@field headings table<string, ui.Text> period -> its list heading
---@field steppers ChoreStepperView[] the settings view's count lines, refitted with the rows
---@field helpWidth integer? the window width the open view's help was wrapped for (the info
--- view, or settings with an empty How many to do block), to re-lay it after a resize
---@field polledWidth integer? the window width at the last poll, to tell when a resize settles
local views = { rows = {}, headings = {}, steppers = {} } ---@type ChoreViews

-- A view switch left for the next Logic tick. A button's action mustn't destroy the button
-- while PrettyUI is still handling its click, and a view switch rebuilds the window.
local pendingMode = nil ---@type ChoreMode?
-- A settings rebuild left for the next Logic tick, for the same reason: the chore just picked
-- or unpicked, whose count line comes or goes. Its row's content height is kept until then,
-- so the rebuild can keep that row where it was in the window.
local pendingCounts = nil ---@type { id: string, y: integer }?
-- The celebration settings, for all characters.
local celebrations = store.loadSettings()

-- dev-only:begin
-- The state above, for `rsdev.py eval --plugin` snippets and press(). A getter, since tracker,
-- mode, phase and the views are replaced as the plugin runs.
if remote then
    remote.expose("main", function()
        return {
            rows = views.rows,
            steppers = views.steppers,
            headings = views.headings,
            tracker = tracker,
            mode = mode,
            phase = phase,
            celebrations = celebrations,
        }
    end)
end
-- dev-only:end

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
    for _, section in ipairs(view.view(tracker, chores, clockNow(), parts)) do
        local heading = views.headings[section.period]
        if heading then heading.content = view.headingText(section) end
        for _, row in ipairs(section.rows) do
            local rowView = views.rows[row.id]
            if rowView then
                rows.show(rowView, view.rowText(row), row.done)
                rows.setTooltip(rowView, view.tooltip(row, view.partTooltip(row, section.period)))
            end
        end
    end
    window.refreshStrip()
end

-- Re-fit the rows' names to their widths (ui.Text can't clip, so a name is cut with "..." to
-- stop before the tick box), and the count lines' names likewise. rows.fit and
-- stepper.fit return at once when the width is unchanged, so fitting them all on each poll
-- costs nothing while the window is idle.
local function refitRows()
    assert(window.current(), "rows are only refitted while the window exists")
    for _, rowView in pairs(views.rows) do
        rows.fit(rowView)
    end
    for _, stepperView in ipairs(views.steppers) do
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
-- them, at the spots core/listlayout.lua gives. Each button leaves its view switch for the
-- next Logic tick (pendingMode).
---@param w prettyui.Window
local function buildList(w)
    local button = w:AddSpriteButton("SETTINGS", function()
        pendingMode = "settings"
    end, { size = BUTTON_SIZE, tooltip = "Pick chores" })
    -- At an explicit x and y, so it sits on the settings button's row and the flow doesn't move.
    w:AddSpriteButton("INFO", function()
        pendingMode = "info"
    end, {
        x = button.root.x + BUTTON_SIZE + layout.BUTTON_GAP,
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
    local sections = view.view(tracker, chores, now, parts)
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
    local wheel = window.wheelHandler(w)
    for _, section in ipairs(sections) do
        views.headings[section.period] =
            w:AddTitle({ text = view.headingText(section), y = spots.headings[section.period] })
        for _, row in ipairs(section.rows) do
            views.rows[row.id] = rows.new(w.content, spots.rows[row.id], icons[row.id], function()
                onTick(row.id)
            end, { wheel = wheel, grip = true })
        end
    end
    w:SetContentHeight(spots.height)
    refreshList()
    -- The grips' press targets sit over the window, placed from its viewport (see grips.lua).
    grips.build({
        -- The plugin layer takes children in the client; GetComponent's stub types it as a
        -- plain component.
        parent = parent --[[@as ui.ComponentCollection]],
        viewport = w.viewport,
        rows = views.rows,
        sections = lists,
        scrollY = function()
            return w.scrollY
        end,
        scrollTo = function(y)
            w:SetScrollPosition(y)
        end,
        wheel = wheel,
        watchSync = prettyuiInternals.overlaySync(w, parent --[[@as ui.ComponentCollection]]),
        onDrop = onDrop,
    })
end

---------------------------------------------------------------------------
-- Settings view
---------------------------------------------------------------------------

-- A settings row was clicked: pick or unpick its chore, save it straight away and tick or
-- empty the row's box. A chore with a count line in How many to do (which lists picked chores
-- only) has the view rebuilt on the next tick, to add or drop that line. No celebration:
-- picking is not completing.
---@param chore Chore
local function onPick(chore)
    assert(character, "settings are only built for a logged-in character")
    local picked = not state.isSelected(tracker, chore.id)
    if picked then
        tracker = state.select(tracker, chore.id)
    else
        tracker = state.deselect(tracker, chore.id)
    end
    store.saveState(character, tracker)
    local row = views.rows[chore.id]
    rows.showPick(row, chore.name, picked)
    local own = parts[chore.id]
    -- Settings rows never move once made, so the row's y is its content height.
    if own and view.hasCount(own) then pendingCounts = { id = chore.id, y = row.layer.y } end
end

-- Rebuild settings for a count line come or gone (onPick), keeping the clicked chore's row
-- where it was in the window: the scroll moves by as much as the block above it grew or
-- shrank. Skipped if the view has moved on (logged out, collapsed, or no longer settings).
---@param pending { id: string, y: integer }
local function rebuildCounts(pending)
    local w = window.current()
    if not w or window.isCollapsed() or mode ~= "settings" then return end
    local scrollY = w.scrollY
    window.rebuild(true)
    -- The rebuilt window, and the clicked chore's row in it.
    local fresh = window.current()
    local row = views.rows[pending.id]
    if row and fresh then fresh:SetScrollPosition(scrollY + row.layer.y - pending.y) end
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

-- A count stepper was clicked: change how many of the chore's parts tick it by `delta`, save
-- it straight away and show the new count. At either end of its range it changes nothing.
-- Lowered to the parts already done this period, it ticks the chore (state.setPartsNeeded);
-- without a clock it only sets the count.
---@param chore Chore
---@param delta integer
---@param shown ChoreStepperView
local function onPartsNeeded(chore, delta, shown)
    assert(character, "settings are only built for a logged-in character")
    local own = parts[chore.id]
    local now = clockNow()
    local count = state.partsNeeded(tracker, chore, own) + delta
    local before = tracker
    local changed = state.setPartsNeeded(tracker, chore, own, count, now)
    if changed == tracker then return end
    tracker = changed
    store.saveState(character, tracker)
    local needed = state.partsNeeded(tracker, chore, own)
    stepper.show(shown, view.neededText(needed, #own.list))
    say("needed", chore.id, needed)
    -- The player's own change, so like a hand tick it earns no popup of its own, but the
    -- one that clears a period does.
    if now then popups.enqueue(celebrate.decide(before, tracker, chores, now, true)) end
end

-- The "How many to do" block: its title next in PrettyUI's flow, then a stepper per picked
-- chore with a count (view.countSettings), or, with none, help saying what the block is for,
-- wrapped to the window's width (re-laid after a resize, as the info view's help is). Gives
-- back the block's bottom.
---@param w prettyui.Window
---@param wheel ChoreWheelHandler
---@return integer
local function buildCounts(w, wheel)
    local title = w:AddTitle("How many to do")
    local settingsLines = view.countSettings(tracker, chores, parts)
    if #settingsLines == 0 then
        local helpWidth = w.root.width
        views.helpWidth, views.polledWidth = helpWidth, helpWidth
        local help = w:AddText(rows.wrapText(view.NO_COUNTS, layout.helpTextWidth(helpWidth)))
        return help.y + help.height
    end
    local ys, bottom = listlayout.stack(#settingsLines, title.y + title.height)
    for i, line in ipairs(settingsLines) do
        views.steppers[#views.steppers + 1] = stepper.new(
            w.content,
            ys[i],
            line.label,
            view.neededText(line.needed, line.total),
            function(delta, shown)
                onPartsNeeded(line.chore, delta, shown)
            end,
            line.tooltip,
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

-- The settings view: the Celebrations switches and the counts title in PrettyUI's flow, the
-- count steppers, then a heading per period, a subheading per category within it, and
-- a hand-built row per chore below them.
---@param w prettyui.Window
local function buildSettings(w)
    w:AddTitle("Celebrations")
    w:AddCheckboxButton({
        { text = "Celebration popups", value = "popups", selected = celebrations.popups },
        { text = "Popup sound", value = "sound", selected = celebrations.sound },
    }, { onChange = onCelebrationSetting })
    local wheel = window.wheelHandler(w)
    local top = buildCounts(w, wheel)
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
                views.rows[chore.id] = row
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
-- window's width now (core/layout.lua, helpTextWidth; relayHelpOnPoll below re-lays them
-- after a resize), then a heading per status and a display-only row per chore below them, all
-- from the data files. Nothing here reads the game.
---@param w prettyui.Window
local function buildInfo(w)
    local helpWidth = w.root.width
    views.helpWidth, views.polledWidth = helpWidth, helpWidth
    local textWidth = layout.helpTextWidth(helpWidth)
    local top = 0
    for _, paragraph in ipairs(info.HELP) do
        local text = w:AddText(rows.wrapText(paragraph, textWidth))
        top = text.y + text.height
    end
    local groups = info.byStatus(chores, shops, collections, varRules, machines)
    local sections = {} ---@type ChoreSectionIds[]
    for i, group in ipairs(groups) do
        sections[i] = sectionIds(group.status, group.chores)
    end
    local spots = listlayout.place(sections, top)
    local wheel = window.wheelHandler(w)
    for _, group in ipairs(groups) do
        w:AddTitle({ text = info.headingText(group), y = spots.headings[group.status] })
        for _, chore in ipairs(group.chores) do
            local row =
                rows.new(w.content, spots.rows[chore.id], icons[chore.id], nil, { wheel = wheel })
            views.rows[chore.id] = row
            rows.show(row, info.rowName(chore, chores), false)
            rows.setTooltip(row, view.tooltip(chore))
        end
    end
    w:SetContentHeight(spots.height)
end

-- On the poll, rebuild the view with help in it (the info view, or settings with an empty How
-- many to do block), keeping its scroll, once the window's width differs from the one its help
-- was wrapped for and has stopped changing (layout.relayHelp), unless a resize drag is in
-- progress, since the rebuild would end it. Does nothing without help shown or while collapsed.
local function relayHelpOnPoll()
    local helpWidth, polledWidth = views.helpWidth, views.polledWidth
    if helpWidth == nil or window.isCollapsed() then return end
    local w = window.current()
    assert(w, "help is only re-laid while its window exists")
    assert(polledWidth, "the view that wraps help sets both widths")
    local width = w.root.width
    local settled = layout.relayHelp(helpWidth, polledWidth, width)
    views.polledWidth = width
    if settled and not prettyuiInternals.resizing(w) then window.rebuild(true) end
end

---------------------------------------------------------------------------
-- The window (its chrome and collapsed strip are shell/window.lua's)
---------------------------------------------------------------------------

-- What the collapsed strip shows: the next chore not done, or a notice while logged out or
-- waiting for the clock.
---@return ChoreStrip
local function stripContent()
    local notice = phase == "loggedOut" and "Log in to see your chores"
        or phase == "waiting" and "Waiting for the game clock"
        or nil
    local content = view.strip(view.view(tracker, chores, clockNow(), parts), notice)
    if content.id then content.icon = icons[content.id] end
    return content
end

-- A new window's content for the current phase and mode.
---@param w prettyui.Window
local function buildContent(w)
    if phase == "loggedOut" then
        w:AddText("Log in to see your chores.")
    elseif mode == "settings" then
        buildSettings(w)
    elseif mode == "info" then
        buildInfo(w)
    else
        buildList(w)
    end
end

-- Settings and info both go back to the list from the title-bar slot.
---@return boolean
local function awayFromList()
    return mode ~= "list"
end

-- The way back from settings or info, in the title-bar slot so it stays in reach however far
-- the view is scrolled. Like every view switch, it waits a tick.
local function backToList()
    pendingMode = "list"
end

-- The old window's views went with it.
local function clearViews()
    views = { rows = {}, headings = {}, steppers = {} }
end

-- Close hides the rows, and the client sends no mouse-leave to a hidden layer, so a hovered
-- row would reopen with its hovered box.
local function onCollapse()
    for _, rowView in pairs(views.rows) do
        rows.unhover(rowView)
    end
end

---------------------------------------------------------------------------
-- Chores the plugin sees done (shell/detect.lua, shell/vars.lua)
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

-- Each Logic tick: a view switch or settings rebuild left by a click, then on the poll the
-- login, the layout, re-laid help and refitted rows, then the window's own upkeep.
---@param ev LogicEventPayload
local function onLogic(ev)
    vars.tick()
    if pendingMode then
        mode = pendingMode
        pendingMode = nil
        pendingCounts = nil
        window.rebuild(false)
    elseif pendingCounts then
        rebuildCounts(pendingCounts)
        pendingCounts = nil
    end
    if ev.logicTick % POLL_TICKS == 0 then
        sync(false)
        window.saveLayoutIfChanged()
        relayHelpOnPoll()
        refitRows()
    end
    -- Every tick, so a grip's target keeps up with the window moving or scrolling.
    window.tick()
end

-- The clock ticking over syncs at once; every var update also goes to shell/vars.lua.
---@param ev VarTransmitEventPayload
local function onVarTransmit(ev)
    if ev.var.id == CLOCK_ID and ev.var.typeName == CLOCK_DOMAIN then sync(true) end
    vars.onVarTransmit(ev)
end

---------------------------------------------------------------------------
-- Start and stop
---------------------------------------------------------------------------

window.init({
    parent = parent,
    awayFromList = awayFromList,
    backToList = backToList,
    clearViews = clearViews,
    build = buildContent,
    onCollapse = onCollapse,
    strip = stripContent,
    -- The strip only shows a chore not done, so its click ticks it, as on its list row.
    onStripTick = onTick,
})
popups.init({ parent = parent })
detect.init({
    chores = chores,
    shops = shops,
    collections = collections,
    machines = machines,
    parts = parts,
    apply = apply,
})
vars.init({
    chores = chores,
    rules = varRules,
    parts = parts,
    apply = apply,
    where = detect.playerTile,
})
popups.configure(celebrations)
-- The login and clock before the window, so it opens on the right view. sync clears the
-- popups and scans what detect and vars watch, so their inits come first.
sync(false)
window.open()

Event.Logic.Subscribe("chore-tracker", onLogic)
Event.VarTransmit.Subscribe("chore-tracker", onVarTransmit)
Event.InventoryAdded.Subscribe("chore-tracker", detect.onInventoryAdded)
Event.InventoryUpdated.Subscribe("chore-tracker", detect.onInventoryUpdated)
Event.InventoryRemoved.Subscribe("chore-tracker", detect.onInventoryRemoved)
say("loaded", #chores, "chores")

function PluginShutdown()
    Event.Logic.Unsubscribe("chore-tracker")
    Event.VarTransmit.Unsubscribe("chore-tracker")
    Event.InventoryAdded.Unsubscribe("chore-tracker")
    Event.InventoryUpdated.Unsubscribe("chore-tracker")
    Event.InventoryRemoved.Unsubscribe("chore-tracker")
    window.shutdown()
    popups.clear()
    if remote then remote.shutdown() end -- dev-only: before the tee it rides on
    if tee then tee.shutdown() end -- dev-only: the tee's own Logic subscription
end
