-- The PrettyUI test driver (h.ui): clicks, drags, resizes and hovers the fake's objects. Test-only
-- code that reads the library's state through `internal`. The library files (objects, window,
-- popup) never require it; only init.lua does, to re-export M.driver for the harness.

local runtime = require("tests.harness.runtime")
local strict = require("tests.harness.strict")
local ui = require("tests.harness.api.ui")
local internal = require("tests.harness.api.prettyui.internal")
-- Loading window.lua (and objects.lua under it) registers their shared functions on `internal`.
require("tests.harness.api.prettyui.window")

local TITLE_HEIGHT = internal.TITLE_HEIGHT
local DRAG_LAYER_GAP = internal.DRAG_LAYER_GAP
local clamp = internal.clamp
local remember = internal.remember
local clampedPos = internal.clampedPos
local gone = internal.gone
local windowSetSize = internal.windowSetSize
local stopTitleDrag = internal.stopTitleDrag
local windowShow = internal.windowShow
local windowClose = internal.windowClose

local M = {}

---------------------------------------------------------------------------
-- The test driver: h.ui
---------------------------------------------------------------------------

local Driver = {}
Driver.__index = Driver

---@param h table
---@return table
function M.driver(h)
    return setmetatable({
        h = h,
        altHeld = false,
        noOverlayInternals = false,
        registerRaises = false,
        scrollMode = "all",
        resizeMode = "all",
    }, Driver)
end

---@return table lib
function Driver:lib()
    return assert(self:optionalLib(), "the plugin has no prettyui dependency")
end

-- The fake library if the plugin depends on PrettyUI, else nil. The raw pointer driver (click,
-- press, hover, wheel on a plain ui.Layer) needs no PrettyUI, so it goes through this.
---@return table?
function Driver:optionalLib()
    local instance = self.h.instance
    assert(instance and instance.alive, "plugin not loaded")
    return instance.prettyui
end

-- Every PrettyUI object the plugin has made, or none when it has no PrettyUI dependency:
-- hit-testing a plain layer still asks what PrettyUI draws over it.
---@return table[]
function Driver:records()
    local lib = self:optionalLib()
    return lib and lib.records or {}
end

-- Forget the pointer state (hover, held press) for a plugin that is going away: the client
-- keeps neither across a reload.
function Driver:reset()
    self.hovering = nil
    self.pressing = nil
end

-- Every AchievementPopup the plugin has made, oldest first. Each is the popup's state:
-- title, text, width, height, sound, soundID, `played` (the sound id it would have played,
-- nil for none), `root`, `elapsed` Logic ticks, `destroyed` and `completed` (ended on its
-- own, so onComplete ran).
---@return table[]
function Driver:popups()
    local out = {}
    for _, r in ipairs(self:records()) do
        if r.kind == "AchievementPopup" then out[#out + 1] = r.s end
    end
    return out
end

-- Make every Window made from now on without (false) or with (true, the default) 1.2.0's
-- internal `_RegisterOverlay` and `_UnregisterOverlay`: without, they read nil, as on a
-- PrettyUI version that lacks them. Set it before `h:load()` for a window made at load.
---@param on boolean
function Driver:overlayInternals(on)
    self.noOverlayInternals = not on
end

-- Make every Window made from now on raise from `_RegisterOverlay` (true), as a PrettyUI version
-- whose internal takes other arguments would, or work again (false). A separate toggle, not a
-- mode of `overlayInternals`, which is a boolean for the internals being there at all. Set it
-- before `h:load()` for a window made at load.
---@param on boolean
function Driver:overlayRaises(on)
    self.registerRaises = on
end

-- Make every Window made from now on lack 1.2.0's internal `_scroll` ("noScroll"), its public
-- `viewport` ("noViewport") or its internal `_onScrollWheel` ("noWheel"), each reading nil as on
-- a PrettyUI version without it; "all" (the default) restores them. Set it before `h:load()`
-- for a window made at load.
---@param mode "all"|"noScroll"|"noViewport"|"noWheel"
function Driver:scrollInternals(mode)
    self.scrollMode = mode
end

-- Make every Window made from now on lack 1.2.0's internal `resize` ("none") or its `handles`
-- ("noHandles") or its `n` handle ("noN") or its `titleDrag` ("noTitleDrag"), as on a PrettyUI
-- version that lacks them; "all" (the default) restores them. Set it before `h:load()` for a
-- window made at load.
---@param mode "all"|"none"|"noHandles"|"noN"|"noTitleDrag"
function Driver:resizeInternals(mode)
    self.resizeMode = mode
end

-- The components registered as a Window's overlays, in the order registered.
---@param win table
---@return table[]
function Driver:overlays(win)
    local out = {}
    for i, overlay in ipairs(self:record(win, "Window").s.overlays) do
        out[i] = overlay.component
    end
    return out
end

-- Make AchievementPopup.show return nil from now on (true), or work again (false).
---@param on boolean
function Driver:popupsFail(on)
    self:lib().popupsFail = on
end

---@param obj any
---@param kind string?
---@return table record
function Driver:record(obj, kind)
    local r = self:lib().byObj[obj]
    assert(r, "not a PrettyUI object of this plugin: " .. tostring(obj))
    assert(kind == nil or r.kind == kind, "expected a " .. tostring(kind) .. ", got a " .. r.kind)
    return r
end

-- The text a record can be found by.
---@param r table
---@return string[]
local function texts(r)
    if r.kind == "Window" then return { r.s.title } end
    if r.kind == "Text" or r.kind == "Title" then return { r.s.content } end
    if r.kind == "CheckboxButton" then
        local out = {}
        for i, item in ipairs(r.s.items) do
            out[i] = item.text
        end
        return out
    end
    return {}
end

-- Live objects of `kind` ("Window", "Panel", "SpriteButton", "Text", "Title",
-- "CheckboxButton", "Divider"), in creation order. `filter`: { sprite = "MENU" } and/or
-- { text = "substring" } (a Window's title, a Text's content, a checkbox choice) and/or
-- { visible = true } (neither it nor an ancestor is hidden).
---@param kind string
---@param filter table?
---@return table[]
function Driver:find(kind, filter)
    filter = filter or {}
    local out = {}
    for _, r in ipairs(self:records()) do
        local ok = r.kind == kind and not gone(r)
        if ok and filter.sprite then ok = r.s.spriteName == filter.sprite:upper() end
        if ok and filter.visible then ok = ui.visible(r.s.rootState or r.s) end
        if ok and filter.text then
            ok = false
            for _, t in ipairs(texts(r)) do
                if t and t:find(filter.text, 1, true) then ok = true end
            end
        end
        if ok then out[#out + 1] = r.obj end
    end
    return out
end

-- The one live object matching; errors on none or several.
---@param kind string
---@param filter table?
---@return table
function Driver:get(kind, filter)
    local found = self:find(kind, filter)
    assert(#found == 1, string.format("expected one %s, found %d", kind, #found))
    return found[1]
end

-- A CheckboxButton's choices as plain data, in order: { text, value, selected, disabled,
-- tooltip }, and the group's text colour (nil for PrettyUI's default).
---@param checkbox table
---@return table[] choices
---@return integer? colour
function Driver:choices(checkbox)
    local r = self:record(checkbox, "CheckboxButton")
    local out = {}
    for i, item in ipairs(r.s.items) do
        out[i] = {
            text = item.text,
            value = item.value,
            selected = item.selected,
            disabled = item.disabled,
            tooltip = item.tooltip,
        }
    end
    return out, r.s.colour
end

-- The point the driver aims at on `cs` when a test gives none: its centre, in plugin-layer
-- coordinates.
---@param cs table component state
---@return number x
---@return number y
local function centre(cs)
    local x, y = ui.drawnPos(cs)
    return x + ui.width(cs) / 2, y + ui.height(cs) / 2
end

-- Whether a click on component `cs` at (cx, cy) (default: its centre) reaches it, and why
-- not. A destroyed one faults: a plugin that leaves a handle to it reachable has lost track of
-- its UI.
---@param cs table component state
---@param cx number?
---@param cy number?
---@return boolean
---@return string?
function Driver:lands(cs, cx, cy)
    if cs.destroyed then strict.fault("prettyui: clicked a component used after Destroy()") end
    if not ui.visible(cs) then return false, "hidden" end
    if cx == nil or cy == nil then
        cx, cy = centre(cs)
    end
    local clip = self:clipped(cs, cx, cy)
    if clip then return false, clip end
    for _, r in ipairs(self:records()) do
        local s = r.s
        if r.kind == "Window" and s.title and not gone(r) and ui.within(cs, s.rootState) then
            -- The title-bar drag layer sits over the window, short of the X's slot (probe).
            local wx, wy = ui.drawnPos(s.rootState)
            local right = wx + ui.width(s.rootState) - DRAG_LAYER_GAP
            if cx >= wx and cx < right and cy >= wy and cy < wy + TITLE_HEIGHT then
                return false, "covered by the window's title-bar drag layer"
            end
        end
        if r.kind == "Panel" and self.altHeld and not gone(r) and ui.within(cs, s.rootState) then
            return false, "Alt is held: the panel's drag layer takes the click"
        end
    end
    return true
end

-- Why a pointer action at (x, y) on component `cs` is clipped away, or nil if it isn't: the
-- point must lie in `cs`'s rect clipped by every ancestor's. The client clips hit-testing as
-- well as drawing: a row scrolled out of a window takes no click, and a press ends when the
-- pointer leaves the pressed layer or a parent's rect (docs/api-concepts.md, "Pointer hooks on a
-- plain `ui.Layer`" and "Pressing and dragging a plain `ui.Layer`").
---@param cs table component state
---@param x number
---@param y number
---@return string?
function Driver:clipped(cs, x, y)
    local by = ui.clipper(cs, x, y)
    if by == nil then return nil end
    for _, r in ipairs(self:records()) do
        if r.kind == "Window" and not gone(r) and by == r.s.viewportState then
            return "clipped: scrolled out of the window's view"
        end
    end
    if by == cs then return "clipped: the point is outside the target" end
    return "clipped: outside the " .. by.class .. " it is in"
end

-- The component on top at (x, y) among those that take the pointer there: a plugin's own (or
-- a window's content or viewport), shown, `clickthrough` false, with the point in its clipped
-- rect. Drawing order decides: children draw over their parent, later siblings over earlier
-- ones, and MoveToFront makes a component its parent's last child (ui/component.html). A
-- non-clickthrough component blocks the ones below it (the `clickthrough` field). PrettyUI's
-- own components aren't counted: the fake doesn't model their `clickthrough`. Faults on a
-- component drawn over `below` whose `clickthrough` was never set (the default is unprobed).
---@param x number
---@param y number
---@param below table the component the pointer would otherwise reach
---@return table?
function Driver:topAt(x, y, below)
    local top, pastBelow = nil, false
    local function visit(s)
        if s.hidden or s.destroyed then return end
        -- Ancestors have already passed, so the point is in the clipped rect iff in its own.
        if ui.clipper(s, x, y) == s then return end
        if s == below then pastBelow = true end
        if s.raw then
            if s.clickthrough == nil and pastBelow then
                strict.fault(
                    "prettyui: a "
                        .. s.class
                        .. " drawn over the target never had clickthrough set, and the "
                        .. "client's default is unprobed"
                )
            end
            if s.clickthrough == false then top = s end
        end
        for _, child in ipairs(s.children) do
            visit(child)
        end
    end
    visit(self.h.instance.uiRoot)
    return top
end

-- Whether a component the plugin made (or a window's content or viewport) is one the raw
-- pointer actions below apply to.
---@param cs table?
---@return boolean
local function isRaw(cs)
    return cs ~= nil and cs.raw == true
end

-- The component that takes a pointer action aimed at `cs`, at (x, y) in plugin-layer
-- coordinates (default: its centre): itself, or its nearest ancestor that isn't clickthrough
-- (the plugin root layer is the client's and takes none). Returns nil and why when the action
-- doesn't land: hidden, clipped (the point outside its clipped rect, e.g. scrolled out of a
-- window), nothing under the pointer takes it, or another component is drawn over it there
-- (see `topAt`). Faults if `cs` was destroyed, or if a component on the way never had
-- `clickthrough` set (the client's default is unprobed).
---@param cs table component state
---@param x number?
---@param y number?
---@return table? hit
---@return string? why
function Driver:reach(cs, x, y)
    if x == nil or y == nil then
        x, y = centre(cs)
    end
    local ok, why = self:lands(cs, x, y)
    if not ok then return nil, why end
    local c, hit = cs, nil
    while c.parent and not hit do
        if c.clickthrough == nil then
            strict.fault(
                "prettyui: "
                    .. c.class
                    .. " never had clickthrough set, and the client's default is unprobed"
            )
        end
        if not c.clickthrough then hit = c end
        c = c.parent
    end
    if not hit then return nil, "clickthrough: nothing under the pointer takes the click" end
    local top = self:topAt(x, y, hit)
    if top ~= hit then
        return nil, "covered: a " .. assert(top).class .. " drawn over it takes the pointer"
    end
    return hit
end

-- The point (x, y), in plugin-layer coordinates, in `hit`'s own coordinates as it sits now
-- (the pointer hooks' x, y).
---@param hit table
---@param x number
---@param y number
---@return integer x
---@return integer y
local function localPoint(hit, x, y)
    local hx, hy = ui.drawnPos(hit)
    return math.floor(x - hx), math.floor(y - hy)
end

-- Click a component the plugin made (or a window's content): the component that takes it
-- (see `reach`) gets ONCLICK and then ONRELEASE, both with the press point in its own
-- coordinates. A plugin acts on ONCLICK: a quick click can arrive release first in the client,
-- the order the fake doesn't reproduce (docs/api-concepts.md, "Pointer hooks on a plain `ui.Layer`").
---@param cs table
---@return boolean
---@return string?
function Driver:clickComponent(cs)
    local hit, why = self:reach(cs)
    if not hit then return false, why end
    local x, y = localPoint(hit, centre(cs))
    runtime.call(self.h.budgetMs, "component click", function()
        ui.fire(hit, ui.Hook.ONCLICK, x, y)
        ui.fire(hit, ui.Hook.ONRELEASE, x, y)
    end)
    return true
end

-- Press the mouse button on a component the plugin made (or a window's content) at (x, y) in
-- plugin-layer coordinates (default: its centre), and hold it. The component that takes it
-- (see `reach`) gets ONCLICK with the point in its own coordinates, and is the pressed layer
-- until the press ends. In the client the first ONHOLD comes on the same tick as ONCLICK
-- (docs/api-concepts.md, "Pointer hooks on a plain `ui.Layer`"); here it comes with the first
-- `moveTo`, so a spec can look at the plugin's UI between the two. Returns true, or false and why it didn't land (the reasons `click` gives).
---@param target any
---@param x number?
---@param y number?
---@return boolean
---@return string?
function Driver:press(target, x, y)
    assert(self.pressing == nil, "h.ui:press: a press is already held; release it first")
    local cs = ui.stateOf(target)
    assert(isRaw(cs), "h.ui:press needs a component the plugin made, or a window's content")
    assert(cs, "unreachable")
    if cs.destroyed then strict.fault("prettyui: pressed a component used after Destroy()") end
    if x == nil or y == nil then
        x, y = centre(cs)
    end
    local hit, why = self:reach(cs, x, y)
    if not hit then return false, why end
    self.pressing = { s = hit, x = x, y = y }
    local lx, ly = localPoint(hit, x, y)
    runtime.call(self.h.budgetMs, "component press", ui.fire, hit, ui.Hook.ONCLICK, lx, ly)
    return true
end

-- The held press, after checking its layer is still on show. What the client sends a pressed
-- layer that is hidden or destroyed mid-press is unprobed, so that faults.
---@param self table the driver
---@return table? # { s, x, y }, or nil when no press is held
local function heldPress(self)
    local p = self.pressing
    if p and not ui.visible(p.s) then
        strict.fault(
            "prettyui: the pressed layer was hidden or destroyed mid-press, and what the "
                .. "client sends it then is unprobed"
        )
    end
    return p
end

-- Move the held pointer to (x, y) in plugin-layer coordinates: one Logic tick of the press.
-- While the point is inside the pressed layer's rect clipped by every ancestor's, the layer
-- gets ONHOLD with the point in its own coordinates as it sits now (so after a layer moves,
-- the next ONHOLD is relative to its new place). Once the point leaves that area the press
-- ends there: ONRELEASE with the point, and false. The client fires ONHOLD every tick even
-- with the mouse still: moveTo the same point for that. The clock doesn't move: call
-- h:advance(20) between moves when the plugin's Logic matters (ONHOLD's order against Logic
-- within a tick is unprobed). Returns true, or false and why (no press held, or released).
---@param x number
---@param y number
---@return boolean
---@return string?
function Driver:moveTo(x, y)
    assert(type(x) == "number" and type(y) == "number", "h.ui:moveTo(x, y) needs numbers")
    local p = heldPress(self)
    if not p then return false, "no press held" end
    p.x, p.y = x, y
    local lx, ly = localPoint(p.s, x, y)
    if ui.clipper(p.s, x, y) then
        self.pressing = nil
        runtime.call(self.h.budgetMs, "component release", ui.fire, p.s, ui.Hook.ONRELEASE, lx, ly)
        return false, "released: the pointer left the pressed layer's hit area"
    end
    runtime.call(self.h.budgetMs, "component hold", ui.fire, p.s, ui.Hook.ONHOLD, lx, ly)
    return true
end

-- Let go of the mouse button: the pressed layer gets ONRELEASE with the pointer's last point
-- in its own coordinates. Returns true, or false and why when no press is held (none was made,
-- or a `moveTo` already ended it).
---@return boolean
---@return string?
function Driver:release()
    local p = heldPress(self)
    if not p then return false, "no press held" end
    self.pressing = nil
    local lx, ly = localPoint(p.s, p.x, p.y)
    runtime.call(self.h.budgetMs, "component release", ui.fire, p.s, ui.Hook.ONRELEASE, lx, ly)
    return true
end

-- Turn the mouse wheel by `delta` over a component the plugin made (or a window's content):
-- only the component that takes the pointer (see `reach`) gets ONSCROLLWHEEL(component, delta),
-- so one with no wheel listener swallows it and the window doesn't scroll. Returns true and
-- how many listeners ran (0: swallowed), or false and why it didn't land.
---@param target any
---@param delta number
---@return boolean
---@return string|integer
function Driver:wheel(target, delta)
    local cs = ui.stateOf(target)
    assert(isRaw(cs), "h.ui:wheel needs a component the plugin made, or a window's content")
    assert(cs, "unreachable")
    local hit, why = self:reach(cs)
    if not hit then return false, why or "did not land" end
    local ran =
        runtime.call(self.h.budgetMs, "mouse wheel", ui.fire, hit, ui.Hook.ONSCROLLWHEEL, delta)
    return true, ran
end

-- Click a SpriteButton (its action gets (button, true)), a Window's closeButton (Close), or
-- one choice of a CheckboxButton (toggles it; onChange fires), or a component the plugin made
-- (ONCLICK, ONRELEASE; see `clickComponent`). Returns false and the reason when the click
-- wouldn't reach it (hidden, under a drag layer, a disabled choice, clipped, clickthrough);
-- faults if the target was destroyed.
---@param target any
---@param value any the choice's value, for a CheckboxButton
---@return boolean
---@return string?
function Driver:click(target, value)
    local lib = self:optionalLib()
    local h = self.h
    local cs = ui.stateOf(target)
    if cs and lib and lib.closeButtons[cs] then
        local ok, why = self:lands(cs)
        if not ok then return false, why end
        local ws = lib.closeButtons[cs]
        runtime.call(h.budgetMs, "PrettyUI close button", windowClose, ws)
        return true
    end
    if isRaw(cs) then
        assert(cs, "unreachable")
        return self:clickComponent(cs)
    end
    local r = self:record(target)
    if r.kind == "SpriteButton" then
        local ok, why = self:lands(r.s.rootState)
        if not ok then return false, why end
        if r.s.action then
            runtime.call(h.budgetMs, "SpriteButton action", r.s.action, r.obj, true)
        end
        return true
    elseif r.kind == "CheckboxButton" then
        for _, item in ipairs(r.s.items) do
            if item.value == value then
                local ok, why = self:lands(item.rowState)
                if not ok then return false, why end
                if item.disabled then return false, "disabled choice" end
                runtime.call(h.budgetMs, "CheckboxButton click", function()
                    r.obj:SetSelected(value, not item.selected)
                end)
                return true
            end
        end
        error("no checkbox choice with value " .. tostring(value), 2)
    end
    error("can't click a " .. r.kind, 2)
end

-- 1.2.0's ONCLICK on the title bar (src/window.lua, titleDrag): the root to the front, then
-- the title-bar drag layer over it, and the resize turned off. `held`: the button is still
-- down, so the layer's isClicked reads true (a quick click never reads true afterwards).
---@param s table
---@param held boolean
local function pressTitle(s, held)
    s.root:MoveToFront()
    s.titleDrag:MoveToFront()
    s.resizeEnabled = false
    s.titleDragState.isClicked = held
end

-- 1.2.0's stopDrag (ONRELEASE / ONDRAGCOMPLETE): the press ends, the resize is turned back on
-- and the overlays sync.
---@param s table
local function releaseTitle(s)
    s.titleDragState.isClicked = false
    s.resizeEnabled = true
    stopTitleDrag(s)
end

-- The title bar of a shown, titled Window's record state.
---@param self table
---@param win table
---@return table
local function titled(self, win)
    local s = self:record(win, "Window").s
    assert(s.title, "only a titled Window has a title bar")
    assert(ui.visible(s.rootState), "the window is hidden")
    return s
end

-- Press a titled Window's title bar, drag it by (dx, dy) and let go, all in one step: it stays
-- inside its parent. The press raises the root and then the title-bar drag layer, and the
-- release syncs the overlays (1.2.0's stopDrag), both before the next Logic tick.
---@param win table
---@param dx number
---@param dy number
function Driver:dragTitle(win, dx, dy)
    local s = titled(self, win)
    pressTitle(s, true)
    local root = s.rootState
    local x, y = ui.pos(root)
    local nx, ny = clampedPos(root, x + dx, y + dy)
    if nx ~= x or ny ~= y then
        s.root:SetPos(nx, ny)
        remember(s)
    end
    releaseTitle(s)
end

-- Press a titled Window's title bar and keep holding it: the window's resize is off and the
-- title-bar drag layer's isClicked reads true until `releaseTitleBar`. Nothing moves.
---@param win table
function Driver:holdTitleBar(win)
    pressTitle(titled(self, win), true)
end

-- Let go of a title bar held with `holdTitleBar`: the resize is back on and the overlays sync.
---@param win table
function Driver:releaseTitleBar(win)
    releaseTitle(titled(self, win))
end

-- A quick click on a titled Window's title bar: press and release in one tick, which the
-- client delivers backwards (ONRELEASE, then ONCLICK; docs/api-concepts.md, "Pointer hooks on
-- a plain `ui.Layer`"). So the overlays sync first and then the root and title-bar drag layer
-- are raised over them, both before the next Logic tick. The release turns the resize back on
-- and the press then turns it off for good: the window is left with its resize disabled and
-- the title bar not held, as PrettyUI 1.2.0 leaves it in the client.
---@param win table
function Driver:clickTitle(win)
    local s = titled(self, win)
    releaseTitle(s)
    pressTitle(s, false)
end

-- Drag a resizable Window's bottom-right corner by (dw, dh): clamped to its min/max and to
-- the parent's edge. The press ends any title-bar press and shows the window (1.2.0's
-- Resize onBegin, src/window.lua), which raises its root; each move sets its size, which
-- syncs the overlays. With `held`, it is a further move of a resize already pressed (one per
-- Logic tick a held press gets, with `h:advance(20)` between): no press, so no Show.
---@param win table
---@param dw number
---@param dh number
---@param held boolean?
function Driver:resize(win, dw, dh, held)
    local s = self:record(win, "Window").s
    assert(s.resizable, "the window isn't resizable")
    assert(ui.visible(s.rootState), "the window is hidden")
    if not held then
        assert(s.resizeEnabled, "the window's resize handles are hidden: its resize is disabled")
        stopTitleDrag(s)
        windowShow(s)
    end
    local root = s.rootState
    local function axis(pos, size, delta, extent, minimum, maximum)
        local limit = math.max(minimum, math.min(maximum or math.huge, extent))
        pos = clamp(pos, 0, extent - minimum)
        return pos, clamp(size + delta, minimum, math.max(minimum, math.min(limit, extent - pos)))
    end
    local x, y = ui.pos(root)
    local nx, w = axis(x, ui.width(root), dw, ui.width(root.parent), s.minWidth, s.maxWidth)
    local ny, hgt = axis(y, ui.height(root), dh, ui.height(root.parent), s.minHeight, s.maxHeight)
    s.root:SetPos(nx, ny)
    windowSetSize(s, w, hgt)
end

-- What a hover target is: the component the pointer is over, and a function giving its
-- current tooltip (SetTooltip / SetOptionTooltip can replace it). `value` picks a
-- CheckboxButton's choice.
---@param target any
---@param value any
---@return table component state
---@return fun(): table?
function Driver:hoverTarget(target, value)
    local lib = self:optionalLib()
    local r = lib and lib.byObj[target]
    local cs = ui.stateOf(target)
    if not r and cs then
        return cs, function() end
    end -- a plain component: no tooltip
    r = self:record(target)
    if r.kind == "CheckboxButton" then
        for _, item in ipairs(r.s.items) do
            if item.value == value then
                return item.rowState,
                    function()
                        return item.tip
                    end
            end
        end
        error("no checkbox choice with value " .. tostring(value), 3)
    end
    local s = r.s
    return s.rootState or s, function()
        return s.tip
    end
end

-- Move the pointer onto `target` (a choice of a CheckboxButton by `value`). The previous
-- target gets its mouse-leave first, and this one its mouse-over, which shows its tooltip.
-- Returns false, and leaves the pointer where it was, if the target is hidden.
---@param target any
---@param value any
---@return boolean
---@return string?
function Driver:hover(target, value)
    local raw = ui.stateOf(target)
    if isRaw(raw) then
        assert(raw, "unreachable")
        return self:hoverComponent(raw)
    end
    local cs, tipOf = self:hoverTarget(target, value)
    if cs.destroyed then strict.fault("prettyui: hovered a component used after Destroy()") end
    -- Same check as a click, so the two agree on what is hidden, clipped or covered.
    local ok, why = self:lands(cs)
    if not ok then return false, why end
    self:leave()
    self.hovering = { cs = cs, tipOf = tipOf }
    local tip = tipOf()
    if tip then tip.shown = true end
    return true
end

-- Move the pointer onto a component the plugin made (or a window's content): the component
-- that takes it (see `reach`) gets ONMOUSEOVER(component, x, y) and reads isMouseOver true;
-- its Tooltip.attach tooltip shows if its listener gets to run. Moving between a component
-- and its clickthrough children stays on the same component: no events. Returns false and why, leaving the pointer
-- where it was, if it doesn't land.
---@param cs table component state
---@return boolean
---@return string?
function Driver:hoverComponent(cs)
    if cs.destroyed then strict.fault("prettyui: hovered a component used after Destroy()") end
    local hit, why = self:reach(cs)
    if not hit then return false, why end
    if self.hovering and self.hovering.cs == hit then return true end
    self:leave()
    local lib = self:optionalLib()
    local function tipOf()
        local tip = lib and lib.rawTips[hit]
        return tip and not tip.destroyed and tip or nil
    end
    self.hovering = { cs = hit, tipOf = tipOf, raw = true }
    hit.mouseOver = true
    local x, y = localPoint(hit, centre(cs))
    runtime.call(self.h.budgetMs, "component mouse-over", ui.fire, hit, ui.Hook.ONMOUSEOVER, x, y)
    return true
end

-- Move the pointer off whatever it is over. A target hidden (or destroyed) since it was
-- hovered gets no mouse-leave, so its tooltip stays shown: the stuck tooltips seen in the
-- client (docs/api-concepts.md, PrettyUI in the client). A component the plugin made reads
-- isMouseOver false either way, and otherwise gets ONMOUSELEAVE(component), whose tooltip
-- listener hides its tooltip.
function Driver:leave()
    local hovering = self.hovering
    self.hovering = nil
    if hovering == nil then return end
    if hovering.raw and not hovering.cs.destroyed then hovering.cs.mouseOver = false end
    if not ui.visible(hovering.cs) then return end
    if not hovering.raw then
        local tip = hovering.tipOf()
        if tip then tip.shown = false end
    else
        runtime.call(
            self.h.budgetMs,
            "component mouse-leave",
            ui.fire,
            hovering.cs,
            ui.Hook.ONMOUSELEAVE
        )
    end
end

-- The text of every tooltip on screen: shown, not destroyed, and drawn in a visible component.
---@return string[]
function Driver:tooltips()
    local out = {}
    local lib = self:optionalLib()
    for _, tip in ipairs(lib and lib.tooltips or {}) do
        if tip.shown and not tip.destroyed and ui.visible(tip.parent) then
            out[#out + 1] = tip.text
        end
    end
    return out
end

-- Hold or release Alt, as PrettyUI sees it (Keyboard available, not blocked, Alt down: in the
-- client the console being open blocks the keyboard).
---@param held boolean
function Driver:holdAlt(held)
    self.altHeld = held == true
end

-- Alt-drag a standalone Panel by (dx, dy), clamped inside its parent. Returns false, leaving
-- it where it is, unless Alt is held.
---@param panel table
---@param dx number
---@param dy number
---@return boolean
function Driver:altDrag(panel, dx, dy)
    local s = self:record(panel, "Panel").s
    if not self.altHeld then return false end
    assert(ui.visible(s.rootState), "the panel is hidden")
    local root = s.rootState
    local x, y = ui.pos(root)
    local nx, ny = clampedPos(root, x + dx, y + dy)
    s.root:SetPos(nx, ny)
    remember(s)
    return true
end

-- The held press as { component, x, y } (the pressed layer's proxy, and the pointer's last
-- point in plugin-layer coordinates), or nil when none is held.
---@return table?
function Driver:pressed()
    local p = self.pressing
    if not p then return nil end
    return { component = p.s.proxy, x = p.x, y = p.y }
end

-- The client stops reporting the button: the press ends with no ONRELEASE, unlike `release`
-- and a `moveTo` out of the layer. For a spec whose plugin has already dropped the pressed
-- layer, where the fake would otherwise keep a press the client no longer has.
function Driver:lostPress()
    assert(self.pressing, "h.ui:lostPress: no press is held")
    self.pressing = nil
end

-- A one-tick click as the client delivers it: ONRELEASE first, then ONCLICK, with no hold
-- between (docs/api-concepts.md, "Pointer hooks on a plain `ui.Layer`"). The component that
-- takes the click at `component`'s centre gets both, with the point in its own coordinates.
-- Returns true, or false and why it didn't land (the reasons `click` gives).
---@param component any a component the plugin made, or a window's content
---@return boolean
---@return string?
function Driver:quickClick(component)
    local cs = ui.stateOf(component)
    assert(isRaw(cs), "h.ui:quickClick needs a component the plugin made, or a window's content")
    assert(cs, "unreachable")
    local hit, why = self:reach(cs)
    if not hit then return false, why end
    local x, y = localPoint(hit, centre(cs))
    runtime.call(self.h.budgetMs, "component quick click", function()
        ui.fire(hit, ui.Hook.ONRELEASE, x, y)
        ui.fire(hit, ui.Hook.ONCLICK, x, y)
    end)
    return true
end

-- The children of a component, as the proxies the plugin holds, in draw order (the last is on
-- top). A destroyed child is no longer listed.
---@param component any
---@return table[]
function Driver:children(component)
    local cs = assert(ui.stateOf(component), "h.ui:children needs a component")
    local out = {}
    for i, child in ipairs(cs.children) do
        out[i] = child.proxy
    end
    return out
end

-- The plugin layer's children, bottom to top.
---@return table[]
function Driver:drawOrder()
    local instance = assert(self.h.instance, "plugin not loaded")
    return self:children(instance.uiRoot.proxy)
end

-- A component's (or a PrettyUI object's root's) layout as plain data:
-- { x, y, width, height, hidden, globalX, globalY, visible }. globalX, globalY are where it is
-- drawn, a window's scroll included, which its xyGlobal leaves out (as in the client).
---@param target any
---@return table
function Driver:layout(target)
    local cs = ui.stateOf(target)
    if not cs then
        local r = self:record(target)
        cs = assert(r.s.rootState or ui.stateOf(r.obj), "no root: destroyed?")
    end
    local x, y = ui.pos(cs)
    local gx, gy = ui.drawnPos(cs)
    return {
        x = x,
        y = y,
        width = ui.width(cs),
        height = ui.height(cs),
        hidden = cs.hidden,
        globalX = gx,
        globalY = gy,
        visible = ui.visible(cs),
    }
end

return M
