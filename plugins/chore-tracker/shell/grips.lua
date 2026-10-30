-- Dragging a list row by its grip to a new place in its period.
--
-- A press that leaves the layer it started on ends at once, even with the button still held,
-- and a layer can't take the pointer outside its ancestors' rects (docs/api-concepts.md,
-- "Pressing and dragging a plain `ui.Layer`"). So the presses aren't taken by the rows, which
-- sit inside the window: each grip has an invisible press target, a layer on the plugin layer
-- itself, docked over the grip. On the first ONHOLD of a press the target stretches over the
-- whole plugin layer and comes to the front, so it keeps the press wherever the pointer goes
-- until the real release, when it docks back. While a drag lasts, the dragged row follows the
-- pointer within its period and the period's other rows slide apart to show where it would
-- drop (core/reorder.lua works out where); past the list's top or bottom edge the window
-- scrolls. The release drops the row there and hands the move to the caller to save.
--
-- follow() re-docks the targets every Logic tick so they track the window being moved, resized
-- or scrolled. shell/window.lua also calls it right after a build, collapse or expand; by then
-- a build has cleared the grips and a collapse or expand came from a click elsewhere, so at
-- most a just-ended press ages a tick early.
--
-- PrettyUI raises the window over the targets when it is shown, when its title bar is pressed
-- and when a resize begins. A MoveToFront on a hidden layer is lost and one on a layer under
-- the pointer resets its hover (docs/api-concepts.md), so a target is raised as it is shown,
-- and the shown ones again once the window stops syncing its overlays (watchSync): a resize or
-- wheel spin syncs every tick, so the raise waits for the first Logic tick with no sync.
--
-- A held press gets ONHOLD every Logic tick, even with the pointer still (docs/api-concepts.md).
-- A drag that goes DRAG_LOST_TICKS without one has lost its release (the pointer leaving the
-- client window ends a drag, docs/api-concepts.md) and is dropped as a release would be: left
-- stretched in front, its target would take the next click anywhere and move the row.

local reorder = require("core/reorder")
local rows = require("shell/rows")

local M = {}

-- The cursor over a grip and for the whole drag; the user's pick from a cursor probe
-- (docs/api-concepts.md).
local GRIP_CURSOR = id.Cursor.CURSOR_PUSH
local GRIP_SIZE, GRIP_Y = rows.GRIP_SIZE, rows.GRIP_Y
-- About 200 ms: well clear of the every-tick ONHOLD of a held press.
local DRAG_LOST_TICKS = 10

---@class ChoreGrip
---@field id string the chore id of the row it sits over
---@field period string
---@field target ui.Layer the press target, a child of the plugin layer
---@field x integer? where it was last docked, in plugin-layer coordinates
---@field y integer?
---@field hidden boolean

---@class ChoreGripsOpts
---@field parent ui.ComponentCollection the plugin layer
---@field viewport ui.Layer the layer the window's content scrolls in
---@field rows table<string, ChoreRowView> the list's rows by chore id
---@field sections ChoreSectionIds[] each period's row ids, top to bottom
---@field scrollY fun(): number? how far the content is scrolled, or nil if unreadable
---@field scrollTo fun(y: number) scroll the content (the window clamps it)
---@field wheel ChoreWheelHandler? the window's wheel handler, so the wheel over a grip scrolls
---@field watchSync (fun(onSync: fun()): fun()?)? have onSync called each time the window lays out
--- its overlays; returns the function that stops it, or nil if it couldn't start. Without it
--- the targets stay under the window after a title-bar press or a resize
---@field onDrop fun(id: string, slot: integer) a row was dropped at a new place in its period

---@class ChoreGripDrag
---@field grip ChoreGrip
---@field row ChoreRowView
---@field ids string[] its period's row ids in their order at the start
---@field from integer its index in `ids`
---@field firstY integer the period's first row's content y
---@field grab number the pointer's offset below the row's top
---@field slot integer where it would drop now
---@field idle integer Logic ticks since its last ONHOLD

local ctx = nil ---@type ChoreGripsOpts?
local grips = {} ---@type ChoreGrip[]
-- Each period's row ids, top to bottom: a copy of the built sections, kept in step with drops.
local sections = {} ---@type ChoreSectionIds[]
local drag = nil ---@type ChoreGripDrag?
-- A grip pressed whose drag hasn't started, and how many Logic ticks ago. A quick click can
-- arrive release-first (docs/api-concepts.md), leaving a press with no ONHOLD or release to
-- follow; it is forgotten on the second Logic tick after, since a held press gets its first
-- ONHOLD on its own tick (docs/api-concepts.md).
local pressed = nil ---@type { grip: ChoreGrip, ticks: integer }?
-- Whether the window was open at the last follow.
local shown = false
-- Whether the last dock hid every target but a dragging one, so a closed window needs no more.
local allHidden = false
-- Stops the watchSync callback; nil when there is none.
local stopWatch = nil ---@type fun()?
-- A raise is owed: a sync came since the last raise. Cleared when the raise is done or the
-- window is closed.
local synced = false
-- A sync came since the last follow(), which clears it; while true the burst is still going
-- and the raise waits.
local syncedSinceFollow = false

-- The viewport's spot and size in plugin-layer coordinates, and the scroll position; nil when
-- the scroll can't be read. Rows are placed from these, not from their own xyGlobal, which
-- leaves out the scroll in the client (docs/api-concepts.md).
---@return { x: number, y: number, width: number, height: number, scroll: number }?
local function view()
    assert(ctx, "grips are only followed once built")
    local scroll = ctx.scrollY()
    if scroll == nil then return nil end
    local at, origin = ctx.viewport.xyGlobal, ctx.parent.xyGlobal
    return {
        x = at.x - origin.x,
        y = at.y - origin.y,
        width = ctx.viewport.width,
        height = ctx.viewport.height,
        scroll = scroll,
    }
end

-- Put a grip's target at (x, y), or hide it; touches the component only for a change.
---@param grip ChoreGrip
---@param x integer
---@param y integer
---@param hide boolean
local function place(grip, x, y, hide)
    if hide ~= grip.hidden then
        grip.hidden = hide
        grip.target.hidden = hide
        -- Over whatever was raised while it was hidden, which a raise then would have missed.
        if not hide then grip.target:MoveToFront() end
    end
    if not hide and (x ~= grip.x or y ~= grip.y) then
        grip.x, grip.y = x, y
        grip.target:SetPos(x, y)
    end
end

-- Dock every target that isn't dragging over its grip, hidden unless the window is open and
-- the grip is wholly inside the visible list.
local function dock()
    assert(ctx, "grips are only docked once built")
    local v = view()
    for _, grip in ipairs(grips) do
        if not (drag and drag.grip == grip) then
            local layer = ctx.rows[grip.id].layer
            local x, y, inView = 0, 0, false
            if v then
                x = math.floor(v.x + layer.x + 0.5)
                y = math.floor(v.y + layer.y - v.scroll + GRIP_Y + 0.5)
                inView = x >= v.x
                    and x + GRIP_SIZE <= v.x + v.width
                    and y >= v.y
                    and y + GRIP_SIZE <= v.y + v.height
            end
            place(grip, x, y, not (shown and inView))
        end
    end
    allHidden = not shown
end

-- Move a row's layer to content y `y`, if it isn't there.
---@param row ChoreRowView
---@param y integer
local function moveRow(row, y)
    if row.layer.y ~= y then row.layer:SetPos(row.layer.x, y) end
end

-- One pointer sample of the drag, `pointerY` in plugin-layer coordinates: scroll when past the
-- list's edge, then lay the period out around the dragged row. A sample that isn't a number
-- is skipped.
---@param pointerY any
local function update(pointerY)
    assert(ctx and drag, "a drag sample needs a drag")
    if type(pointerY) ~= "number" then return end
    local v = view()
    if v == nil then return end
    local top, bottom = v.y, v.y + v.height
    local step = reorder.scrollStep(pointerY, top, bottom)
    if step ~= 0 then
        ctx.scrollTo(v.scroll + step)
        v.scroll = ctx.scrollY() or v.scroll
    end
    -- Past an edge the row stays at that edge, under where the pointer leaves the list.
    local clamped = math.max(top, math.min(pointerY, bottom))
    local at = reorder.drag(drag.ids, drag.firstY, drag.from, clamped - top + v.scroll - drag.grab)
    drag.slot = at.slot
    moveRow(drag.row, at.y)
    for rowId, y in pairs(at.rows) do
        moveRow(ctx.rows[rowId], y)
    end
end

-- The period's section, by period.
---@param period string
---@return ChoreSectionIds
local function sectionOf(period)
    assert(ctx, "sections exist once built")
    for _, section in ipairs(sections) do
        if section.period == period then return section end
    end
    error("no section for " .. period)
end

-- The first ONHOLD of a press on `grip`, `localY` the pointer's y on its docked target:
-- stretch the target over the plugin layer to keep the press, raise the row over its
-- neighbours, and take the first sample.
---@param grip ChoreGrip
---@param localY any
local function start(grip, localY)
    assert(ctx, "a drag needs built grips")
    if type(localY) ~= "number" or grip.y == nil then return end
    local section = sectionOf(grip.period)
    local ids = table.move(section.ids, 1, #section.ids, 1, {})
    local from = 1
    for i, rowId in ipairs(ids) do
        if rowId == grip.id then from = i end
    end
    local row = ctx.rows[grip.id]
    drag = {
        grip = grip,
        row = row,
        ids = ids,
        from = from,
        firstY = ctx.rows[ids[1]].layer.y,
        grab = GRIP_Y + localY,
        slot = from,
        idle = 0,
    }
    pressed = nil
    local target = grip.target
    target:SetPos(0, 0)
    target:SetSize(ctx.parent.width, ctx.parent.height)
    target:MoveToFront()
    row.layer:MoveToFront()
    update(grip.y + localY)
end

-- The press ended: settle the period's rows at their slots, dock the target back over its grip
-- and report a changed order.
local function drop()
    assert(ctx and drag, "a drop needs a drag")
    local d = drag
    drag = nil
    local ids = d.ids
    table.remove(ids, d.from)
    table.insert(ids, d.slot, d.grip.id)
    sectionOf(d.grip.period).ids = ids
    for rowId, y in pairs(reorder.settle(ids, d.firstY)) do
        moveRow(ctx.rows[rowId], y)
    end
    d.grip.target:SetSize(GRIP_SIZE, GRIP_SIZE)
    -- Forget the spot so the next dock moves it back.
    d.grip.x, d.grip.y = nil, nil
    dock()
    if d.slot ~= d.from then ctx.onDrop(d.grip.id, d.slot) end
end

-- Make a press target over each list row's grip. Call after the rows are made, then follow.
-- Without a readable scroll position a target couldn't be put over its grip, so then none is
-- made and the grips don't drag.
---@param opts ChoreGripsOpts
function M.build(opts)
    M.clear()
    if opts.scrollY() == nil then return end
    ctx = opts
    for i, section in ipairs(opts.sections) do
        sections[i] =
            { period = section.period, ids = table.move(section.ids, 1, #section.ids, 1, {}) }
        for _, rowId in ipairs(section.ids) do
            local target = ui.Layer.new(opts.parent)
            target:SetSize(GRIP_SIZE, GRIP_SIZE)
            target.clickthrough = false
            target.hidden = true
            rows.setCursor(target, GRIP_CURSOR)
            local grip = ---@type ChoreGrip
                { id = rowId, period = section.period, target = target, hidden = true }
            target:Subscribe(ui.Hook.ONCLICK, function()
                pressed = { grip = grip, ticks = 0 }
            end)
            target:Subscribe(ui.Hook.ONHOLD, function(_, _, y)
                if drag then
                    if drag.grip == grip then
                        drag.idle = 0
                        update(y)
                    end
                elseif pressed and pressed.grip == grip then
                    start(grip, y)
                end
            end)
            target:Subscribe(ui.Hook.ONRELEASE, function()
                pressed = nil
                if drag and drag.grip == grip then drop() end
            end)
            if opts.wheel then target:Subscribe(ui.Hook.ONSCROLLWHEEL, opts.wheel) end
            grips[#grips + 1] = grip
        end
    end
    if opts.watchSync then
        stopWatch = opts.watchSync(function()
            -- During a drag only its own scrolling (or the wheel) can sync, since the
            -- stretched target takes every press. Such a sync is dropped rather than queue a
            -- raise onto the target under the pointer right after the drop; a raise already
            -- pending from before the drag still runs once the drag ends.
            if not drag then
                synced, syncedSinceFollow = true, true
            end
        end)
    end
end

-- Destroy every press target, dropping any drag unsaved (its rows are going too).
function M.clear()
    -- First, while the window it watches still exists: callers clear the grips before
    -- destroying the window.
    if stopWatch then stopWatch() end
    for _, grip in ipairs(grips) do
        grip.target:Destroy()
    end
    grips, sections, drag, pressed, ctx, stopWatch = {}, {}, nil, nil, nil, nil
    shown, allHidden, synced, syncedSinceFollow = false, false, false, false
end

-- Keep the targets over their grips and in front of the window, and drop a drag whose release
-- never came or whose window closed (its stretched target would take clicks). Call every Logic
-- tick, `open` false while the window is closed; one extra call is a harmless re-dock.
---@param open boolean
function M.follow(open)
    if pressed and not drag then
        pressed.ticks = pressed.ticks + 1
        if pressed.ticks >= 2 then pressed = nil end
    end
    shown = open
    if drag then
        drag.idle = drag.idle + 1
        if not open or drag.idle > DRAG_LOST_TICKS then drop() end
    end
    -- The window may have been raised over the shown targets: bring them back over it, once,
    -- on the first tick no sync came before, since a raise resets the hover of the target under
    -- the pointer. Hidden ones are raised as they are shown. A press or a drag keeps the raise
    -- waiting, since raising the pressed target would reset it. A closed window syncs again
    -- when it is shown.
    local quiet = not syncedSinceFollow
    syncedSinceFollow = false
    if synced and quiet and not pressed and not drag then
        synced = false
        if open then
            for _, grip in ipairs(grips) do
                if not grip.hidden then grip.target:MoveToFront() end
            end
        end
    end
    if ctx and (open or not allHidden) then dock() end
end

return M
