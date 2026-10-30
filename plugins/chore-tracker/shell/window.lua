-- The Chore Tracker's window chrome: making and remaking the PrettyUI window, its title-bar
-- slot button, collapsing it to a lone button and expanding it again, and saving where it all
-- is. What goes in the window is main.lua's: it hands in a `build` that fills a new window's
-- content for the current view, and the window calls it on every (re)build.
--
-- The title-bar slot (where PrettyUI's close X would be) holds the hamburger, which collapses
-- the window, or in the settings view a back button to the list. Collapsed, the window is
-- closed and a strip stands with its hamburger where the slot was, and the next chore to do
-- (shell/strip.lua) to its left: Alt-drag it to move it (with the console closed), click the
-- chore to tick it, or click the hamburger to open the window again, grown left and down from
-- the button.

local grips = require("shell/grips")
local prettyuiInternals = require("shell/prettyui_internals")
local layout = require("core/layout")
local store = require("shell/store")
local strip = require("shell/strip")

local M = {}

local BUTTON_SIZE = layout.BUTTON_SIZE

-- The window hamburger's tooltip. A table, so SetTooltip replaces it (see collapseAt).
local COLLAPSE_TOOLTIP = { text = "Collapse" }
-- The same slot's tooltip while the settings view is open.
local BACK_TOOLTIP = { text = "Back to the list" }

---@class ChoreWindowOpts
---@field parent ui.Component the plugin layer, where the window and the collapsed button go
---@field say fun(...) where log lines go (main.lua's, so they carry [CHORES])
---@field inSettings fun(): boolean whether the settings view is the one to show; its slot
--- button is then the back button
---@field backToList fun() the back button's action
---@field clearViews fun() forget the old window's content views; called once it is destroyed
---@field build fun(w: prettyui.Window) fill a new window's content for the current view
---@field onCollapse fun() called as the window closes to its button, just before Close
---@field strip fun(): ChoreStrip what the collapsed strip shows now
---@field onStripTick fun(id: string) the collapsed strip's chore was clicked

local opts = nil ---@type ChoreWindowOpts?
local win = nil ---@type prettyui.Window?
-- The title-bar slot's button: the hamburger, or back to the list in settings.
local openButton = nil ---@type prettyui.SpriteButton?
local collapsed = nil ---@type prettyui.Panel? exists only while collapsed
local collapsedButton = nil ---@type prettyui.SpriteButton?
local stripView = nil ---@type ChoreStripView? the collapsed panel's chore row and message
-- The row width the collapsed panel was sized for.
local stripWidth = nil ---@type integer?
-- A button's action mustn't destroy the button while PrettyUI is still handling its click, so
-- the collapsed panel left behind by expanding waits here for the next Logic tick (dropRetired).
local retiring = nil ---@type prettyui.Panel?
-- The layout the store holds, so it's written only when the window has really moved.
local savedLayout = nil ---@type ChoreLayout?

-- What the window needs from main.lua. Call once, before anything else.
---@param o ChoreWindowOpts
function M.init(o)
    opts = o
end

-- The window, or nil before it is first built.
---@return prettyui.Window?
function M.current()
    return win
end

-- A component's on-screen position relative to the plugin layer, in whole pixels.
---@param component ui.Component
---@return integer x
---@return integer y
local function screenPos(component)
    assert(opts, "window.init runs before any window function")
    local at, origin = component.xyGlobal, opts.parent.xyGlobal
    return math.floor(at.x - origin.x + 0.5), math.floor(at.y - origin.y + 0.5)
end

-- Keep the grips' targets over their grips, shown only while the window is open.
function M.followGrips()
    grips.follow(collapsed == nil)
end

-- Re-open the window so its hamburger lands on the collapsed one, then drop the panel.
local function expand()
    assert(opts, "window.init runs before any window function")
    assert(win and collapsed and collapsedButton, "the collapsed button only exists collapsed")
    local parent = opts.parent
    local x, y = screenPos(collapsedButton.root)
    local r = win.root
    local wx, wy = layout.windowForButton(x, y, r.width, r.height, parent.width, parent.height)
    -- A bare SetPos is snapped back by PrettyUI; SetSize after it makes the spot stick.
    r:SetPos(wx, wy)
    win:SetSize(r.width, r.height)
    -- Show brings the window to the front; followGrips below shows the grips' targets, which
    -- brings them back over it.
    win:Show()
    collapsed.root.hidden = true
    -- An earlier panel still waiting for the tick is past its click, so it can go now.
    if retiring then retiring:Destroy() end
    retiring, collapsed, collapsedButton = collapsed, nil, nil
    stripView, stripWidth = nil, nil
    M.followGrips()
    opts.say("expanded from", x, y)
end

-- Close the window and put the collapsed strip so its hamburger is at (x, y) in the plugin
-- layer.
--
-- The strip is a PrettyUI Panel (it is what makes Alt-drag work), scrolling off, with the
-- hamburger and the strip's row as children of the Panel's own root, at the spots
-- core/layout.lua gives: the hamburger anchored to the right edge, so a resize leaves it put
-- once the panel is moved by the width it changed. The Panel is made on collapse and
-- destroyed on expand: kept hidden while the window is open, it would still take Alt-drags,
-- and so clicks, over the window.
---@param x integer
---@param y integer
local function collapseAt(x, y)
    assert(opts, "window.init runs before any window function")
    assert(win and openButton, "the window's hamburger only exists with the window")
    -- The hamburger's tooltip is drawn inside the window, not in its content, so Close hides
    -- it only with the window, and it would be back on the next Show. Replacing it with a
    -- table leaves a fresh, hidden one (a string would only retext it: PrettyUI 1.2.0's
    -- Tooltip.set, src/tooltip.lua).
    openButton:SetTooltip(COLLAPSE_TOOLTIP)
    -- Before Close: main.lua unhovers its rows, which get no mouse-leave once hidden.
    opts.onCollapse()
    win:Close()
    -- Not followGrips: that reads `collapsed`, which is only assigned below.
    grips.follow(false)
    local parent = opts.parent
    local content = opts.strip()
    local rowWidth = strip.rowWidth(content)
    local box = layout.stripForButton(x, y, rowWidth, parent.width, parent.height)
    collapsed = prettyui.Panel.new(parent, {
        x = box.x,
        y = box.y,
        width = box.width,
        height = box.height,
        scrollable = false,
    })
    collapsedButton = prettyui.SpriteButton.new(collapsed.root, "MENU", expand, {
        x = layout.STRIP_BUTTON_X,
        y = layout.STRIP_BUTTON_Y,
        xAnchor = 1.0,
        size = BUTTON_SIZE,
        tooltip = "Chores (Alt-drag to move)",
    })
    stripView, stripWidth = strip.new(collapsed.root, opts.onStripTick), rowWidth
    strip.show(stripView, content)
end

-- Bring the collapsed strip up to date: the chore it shows, and its width when the texts it
-- fits changed (a login change), keeping its hamburger where it is. Nothing while open.
function M.refreshStrip()
    assert(opts, "window.init runs before any window function")
    if not collapsed then return end
    assert(collapsedButton and stripView, "the strip is made with the collapsed panel")
    local content = opts.strip()
    local rowWidth = strip.rowWidth(content)
    if rowWidth ~= stripWidth then
        local parent = opts.parent
        local x, y = screenPos(collapsedButton.root)
        local box = layout.stripForButton(x, y, rowWidth, parent.width, parent.height)
        -- As in expand: SetSize after the SetPos makes the spot stick.
        collapsed.root:SetPos(box.x, box.y)
        collapsed:SetSize(box.width, box.height)
        stripWidth = rowWidth
    end
    strip.show(stripView, content)
end

-- The window's hamburger: collapse where it is.
local function collapse()
    assert(opts, "window.init runs before any window function")
    assert(openButton, "the window's hamburger called this")
    local x, y = screenPos(openButton.root)
    collapseAt(x, y)
    opts.say("collapsed at", x, y)
end

-- (Re)build the window at `at` for the current view. There's no PrettyUI call to clear a
-- window's content, so a view switch, a login change or the clock starting rebuilds the
-- window where it was.
---@param at { x: integer, y: integer, width: integer, height: integer }
local function build(at)
    assert(opts, "window.init runs before any window function")
    -- The grips' targets go first: they are the plugin layer's, not the window's, and a drag
    -- in progress ends unsaved with its rows.
    grips.clear()
    if win then win:Destroy() end
    opts.clearViews()
    local w = prettyui.Window.new(opts.parent, {
        title = "Chores",
        x = at.x,
        y = at.y,
        width = at.width,
        height = at.height,
        resizable = true,
        minWidth = layout.MIN_WIDTH,
        minHeight = layout.MIN_HEIGHT,
    })
    win = w
    prettyuiInternals.setResizeCursors(w)
    w.closeButton.hidden = true
    -- The title-bar slot is the one spot of the title bar the drag layer leaves clickable.
    -- It collapses the window, except in the settings view, where it goes back to the list
    -- (collapsing from there means going back first). A view switch rebuilds the window, so
    -- each view simply makes its own button.
    local settings = opts.inSettings()
    openButton = prettyui.SpriteButton.new(
        w.root,
        settings and "BACK" or "MENU",
        settings and opts.backToList or collapse,
        {
            x = layout.SLOT_X,
            y = layout.SLOT_Y,
            xAnchor = 1.0,
            size = BUTTON_SIZE,
            tooltip = settings and BACK_TOOLTIP or COLLAPSE_TOOLTIP,
        }
    )
    opts.build(w)
    M.followGrips()
end

-- Rebuild the window where it is, staying closed if collapsed. With `keepScroll`, the new
-- content is scrolled as far as the old (PrettyUI clamps it to the new content), so a login
-- change or the clock starting doesn't jump the list to the top; a view switch starts at the
-- top.
---@param keepScroll boolean
function M.rebuild(keepScroll)
    assert(win, "the window exists from load to shutdown")
    local r = win.root
    local scrollY = keepScroll and prettyuiInternals.scrollPosition(win) or nil
    build({ x = r.x, y = r.y, width = r.width, height = r.height })
    if scrollY then win:SetScrollPosition(scrollY) end
    if collapsed then
        win:Close()
        M.refreshStrip()
    end
end

-- Open the window where the store says, collapsed if it was. The stored layout is fitted to
-- the plugin layer first; savedLayout keeps the stored one, so a layout that had to be moved
-- in gets saved at the next check.
function M.open()
    assert(opts, "window.init runs before any window function")
    local parent = opts.parent
    savedLayout = store.loadLayout()
    local start = layout.keepInside(savedLayout, parent.width, parent.height)
    build(start)
    if start.collapsed then collapseAt(start.buttonX, start.buttonY) end
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
function M.saveLayoutIfChanged()
    local now = currentLayout()
    if savedLayout and layout.same(savedLayout, now) then return end
    store.saveLayout(now)
    savedLayout = now
end

-- Destroy the collapsed panel an expand left behind, now that its click is over. main.lua
-- calls this early in each Logic tick, before the view switch.
function M.dropRetired()
    if retiring then
        retiring:Destroy()
        retiring = nil
    end
end

-- The window's per-tick upkeep, called every Logic tick so a grip's target keeps up with the
-- window moving or scrolling, and a stuck resize comes back.
function M.tick()
    M.followGrips()
    prettyuiInternals.reviveResize(win, collapsed ~= nil)
end

-- The window's part of PluginShutdown: the grips' targets, then the layout saved and the
-- window destroyed, then the collapsed and retiring panels.
function M.shutdown()
    grips.clear()
    if win then
        M.saveLayoutIfChanged()
        win:Destroy()
    end
    if collapsed then collapsed:Destroy() end
    if retiring then retiring:Destroy() end
end

return M
