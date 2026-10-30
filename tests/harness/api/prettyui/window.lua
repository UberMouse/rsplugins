-- The PrettyUI fake's Window and Panel: window internals (viewport, scroll, overlays, close,
-- resize controllers) and the two classes. Panel lives here, not in objects.lua, because it
-- shares the window's flow, context and clamp helpers. Part of the library, not the driver.

local strict = require("tests.harness.strict")
local ui = require("tests.harness.api.ui")
local internal = require("tests.harness.api.prettyui.internal")
require("tests.harness.api.prettyui.objects")

local PANEL_MIN = internal.PANEL_MIN
local SCROLL_STEP = internal.SCROLL_STEP
local clamp = internal.clamp
local live = internal.live
local remember = internal.remember
local clampIntoParent = internal.clampIntoParent
local destroyTip = internal.destroyTip
local libraryObject = internal.libraryObject
local addSpriteButton = internal.addSpriteButton
local addText = internal.addText
local addCheckbox = internal.addCheckbox
local addDivider = internal.addDivider

-- The viewport's height: the window inside its frame.
---@param s table
---@return integer
local function viewportHeight(s)
    return math.max(1, ui.height(s.viewportState))
end

-- Size the content to the scroll height (the content height, or the viewport's if that is
-- taller) and scroll the viewport over it, as 1.2.0's `_Layout` and `SetScrollPosition` do
-- (content:SetSize, viewport:SetScrollPos). The content and everything on it move up by the
-- scroll; their own x, y don't change.
---@param s table
local function syncContent(s)
    s.content:SetSize(0, math.max(s.flow.contentHeight, viewportHeight(s)), 1.0)
    s.viewportState.scrollY = s.scrollY
end

-- 1.2.0's Window:_SyncOverlays(hidden) (src/window.lua): unless `hidden`, each registered
-- overlay's layout() runs; then the overlay is hidden if `hidden` or its isVisible() returns
-- false, and raised if not. 1.2.0 skips an overlay only when its interface is gone, which a
-- plugin-layer component shares with the window, so a destroyed one still registered is
-- touched: here that faults, as any use of a destroyed component does.
---@param s table
---@param hidden boolean
local function syncOverlays(s, hidden)
    -- A layout() may register or unregister; go over the ones registered now.
    for _, overlay in ipairs(table.move(s.overlays, 1, #s.overlays, 1, {})) do
        if not hidden and overlay.layout then overlay.layout() end
        local hide = hidden or (overlay.isVisible ~= nil and not overlay.isVisible())
        overlay.component.hidden = hide
        if not hide then overlay.component:MoveToFront() end
    end
end

-- Whether the window's root is hidden, as 1.2.0 passes it to _SyncOverlays after a scroll or a
-- resize.
---@param s table
---@return boolean
local function rootHidden(s)
    return s.rootState.hidden == true
end

-- Window:SetScrollPosition: the content's scroll, clamped to 0..(content height less the
-- viewport's), as 1.2.0 does on every scroll and resize; then the overlays sync, moved or not
-- (src/core/scroll.lua, SetScrollPosition).
---@param s table
---@param position number?
local function windowScrollTo(s, position)
    if position ~= nil and type(position) ~= "number" then
        strict.fault("prettyui Window:SetScrollPosition(position) needs a number")
    end
    local most = math.max(0, s.flow.contentHeight - viewportHeight(s))
    s.scrollY = clamp(math.floor(position or 0), 0, most)
    syncContent(s)
    syncOverlays(s, rootHidden(s))
end

-- Window:SetContentHeight(height): the scrollable height, floored and at least 0. It replaces
-- the height the rows grew it to (a later row placed lower grows it again), and re-clamps
-- the scroll.
---@param s table
---@param height number
local function windowSetContentHeight(s, height)
    live(s)
    if type(height) ~= "number" then
        strict.fault("prettyui Window:SetContentHeight(height) needs a number")
    end
    s.flow.contentHeight = math.max(0, math.floor(height))
    windowScrollTo(s, s.scrollY)
end

-- The window's wheel handler (its scroll controller's `_onScrollWheel`), as 1.2.0 binds it
-- to the content: while the content overflows it scrolls by delta * 32 px and returns false
-- if the position moved; otherwise it returns true. A top-level window has no parent
-- handler to pass the wheel on to.
---@param s table
---@param delta number
---@return boolean
local function windowWheel(s, delta)
    live(s)
    if s.flow.contentHeight > viewportHeight(s) then
        local before = s.scrollY
        windowScrollTo(s, before + delta * SCROLL_STEP)
        if s.scrollY ~= before then return false end
    end
    return true
end

-- Window:SetSize, clamped to the window's min/max; it also makes the current position the
-- one a stray root:SetPos snaps back to, and re-clamps the scroll. 1.2.0 syncs the overlays
-- again after the scroll's sync (src/window.lua, SetSize).
---@param s table
---@param width number
---@param height number
local function windowSetSize(s, width, height)
    s.root:SetSize(
        clamp(math.floor(width), s.minWidth, s.maxWidth),
        clamp(math.floor(height), s.minHeight, s.maxHeight)
    )
    if s.bounded then remember(s) end
    windowScrollTo(s, s.scrollY)
    syncOverlays(s, rootHidden(s))
end

-- The end of a title-bar press (1.2.0's stopDrag, src/window.lua), on its release and on every
-- Close, Destroy and resize: it syncs the overlays, shown. Only a titled window has it.
---@param s table
local function stopTitleDrag(s)
    if s.title then syncOverlays(s, false) end
end

-- Window:Show: the root, then the title-bar drag layer, to the front, then the overlays sync
-- (src/window.lua, Show).
---@param s table
local function windowShow(s)
    s.root.hidden = false
    s.root:MoveToFront()
    if s.titleDrag then
        s.titleDrag.hidden = false
        s.titleDrag:MoveToFront()
    end
    syncOverlays(s, false)
end

-- Hide (Close) or destroy (Destroy) every tooltip of a host's content context.
---@param context table
---@param destroy boolean
local function clearContext(context, destroy)
    for _, tip in ipairs(context.tips) do
        tip.shown = false
        if destroy then tip.destroyed = true end
    end
end

-- Close: end any title-bar press, hide the content's tooltips, call onClose(window), then
-- hide and sync the overlays hidden (the 1.2.0 order).
---@param s table
local function windowClose(s)
    live(s)
    stopTitleDrag(s)
    clearContext(s.tips, false)
    if s.onClose then s.onClose(s.proxy) end
    if not s.destroyed then
        s.root.hidden = true
        if s.titleDrag then s.titleDrag.hidden = true end
        syncOverlays(s, true)
    end
end

-- 1.2.0's internal overlay registry (src/window.lua): `component` is synced with the window
-- (syncOverlays) until unregistered or the window is destroyed. Registering one again
-- replaces its callbacks.
---@param s table
---@param component any
---@param isVisible any
---@param layout any
local function registerOverlay(s, component, isVisible, layout)
    live(s)
    -- `h.ui:overlayRaises(true)`: a version whose internal takes other arguments raises here.
    if s.registerRaises then
        strict.fault("prettyui Window:_RegisterOverlay: stand-in for a changed signature", true)
    end
    if ui.stateOf(component) == nil then
        strict.fault("prettyui Window:_RegisterOverlay(component, ...) needs a component")
    end
    for _, fn in ipairs({ isVisible or false, layout or false }) do
        if fn and type(fn) ~= "function" then
            strict.fault("prettyui Window:_RegisterOverlay: isVisible and layout are functions")
        end
    end
    local entry = { component = component, isVisible = isVisible, layout = layout }
    for i, overlay in ipairs(s.overlays) do
        if overlay.component == component then
            s.overlays[i] = entry
            return
        end
    end
    s.overlays[#s.overlays + 1] = entry
end

---@param s table
---@param component any
local function unregisterOverlay(s, component)
    for i, overlay in ipairs(s.overlays) do
        if overlay.component == component then
            table.remove(s.overlays, i)
            return
        end
    end
end

-- An overlay-registry method served as a field, so a window made after
-- `h.ui:overlayInternals(false)` reads it as nil, standing in for a PrettyUI without it.
---@param s table
---@param name string
---@param fn fun(s: table, ...)
---@return function?
local function overlayMethod(s, name, fn)
    if s.noOverlayInternals then return nil end
    return function(self, ...)
        if self ~= s.proxy then
            strict.fault("prettyui Window." .. name .. " is a method: call it with ':'")
        end
        fn(s, ...)
    end
end

-- The keys of 1.2.0's eight resize handles (src/core/resize.lua).
local RESIZE_HANDLES = { "n", "s", "e", "w", "nw", "ne", "sw", "se" }

-- Stand-ins for 1.2.0's `resize` controller and its `handles` table. Stricter than 1.2.0's plain
-- table on purpose: an unknown key such as `resize.handle` or `handles.nn` faults, not reads nil.
-- `state.handles` is set for every resizable window; only the `resize` getter's `handles` field
-- reads nil under `resizeInternals("noHandles")`, and its `n` under `"noN"`.
local ResizeHandles = strict.class("prettyui.Window resize handles", {
    undeclared = true,
    fields = (function()
        local fields = {}
        for _, key in ipairs(RESIZE_HANDLES) do
            fields[key] = function(s)
                return s[key]
            end
        end
        return fields
    end)(),
})
local ResizeController = strict.class("prettyui.Window resize", {
    undeclared = true,
    fields = {
        handles = function(s)
            return s.handles and ResizeHandles.new(s.handles) or nil
        end,
        -- 1.2.0's `enabled` (src/core/resize.lua): true when made. Kept on the window's state,
        -- since the getter below makes a fresh controller on every read.
        enabled = function(s)
            return s.win.resizeEnabled
        end,
    },
    methods = {
        SetEnabled = function(s, enabled)
            s.win.resizeEnabled = enabled
        end,
    },
})

-- A field that faults once the object is destroyed, as its methods do. The members left bare
-- below read nil instead, as 1.2.0 clears them on Destroy.
---@param read fun(s: table): any
---@return fun(s: table): any
local function liveField(read)
    return function(s)
        live(s)
        return read(s)
    end
end

-- 1.2.0's internal scroll controller: only `scrollY` is modelled, a snapshot at the read, so
-- any other key faults instead of reading nil.
local ScrollController = strict.class("prettyui.Window instance._scroll", {
    undeclared = true,
    fields = {
        ---@return number
        scrollY = function(s)
            live(s.owner)
            return s.scrollY
        end,
    },
})

local Window = strict.class("prettyui.Window instance", {
    undeclared = true,
    fields = {
        root = "root",
        closeButton = liveField(
            ---@return table
            function(s)
                return s.closeButton
            end
        ),
        -- The scrolling layer the rows live in, for a plugin's own components.
        content = function(s)
            if s.destroyed then return nil end
            return s.content
        end,
        -- The layer the content scrolls in: its rect is the part of the content on show.
        -- Public state 1.2.0's scroll controller syncs onto the window (`syncOwner`).
        viewport = function(s)
            if s.destroyed or s.scrollMode == "noViewport" then return nil end
            return s.viewport
        end,
        -- 1.2.0's internal wheel handler (also set on the window by its scroll controller):
        -- a plugin hands it to a row's ONSCROLLWHEEL so the wheel still scrolls the window.
        _onScrollWheel = liveField(
            ---@return function?
            function(s)
                if s.scrollMode == "noWheel" then return nil end
                return s.onWheel
            end
        ),
        ---@return table?
        _scroll = function(s)
            if s.destroyed or s.scrollMode == "noScroll" then return nil end
            return ScrollController.new({ scrollY = s.scrollY, owner = s })
        end,
        -- 1.2.0's internal title-bar drag layer (a titled window's only), a sibling of the root
        -- on the window's parent. Only its stacking and `hidden` are modelled: its rect is left
        -- 0x0 at the origin (`lands` models the title bar it covers), and it is not one of the
        -- plugin's own layers, so it takes no pointer actions.
        titleDrag = function(s)
            if s.resizeMode == "noTitleDrag" then return nil end
            return s.titleDrag
        end,
        -- 1.2.0's internal resize controller of a resizable window: only its `handles` are
        -- modelled, eight bare layers on the window's parent. A window made after
        -- `h.ui:resizeInternals("none" or "noHandles")` reads it as nil (or without handles),
        -- and after `"noN"` its `n` handle reads nil.
        resize = function(s)
            if s.destroyed or not s.handles or s.resizeMode == "none" then return nil end
            local handles = s.handles
            if s.resizeMode == "noHandles" then
                handles = nil
            elseif s.resizeMode == "noN" then
                handles = {}
                for key, handle in pairs(s.handles) do
                    if key ~= "n" then handles[key] = handle end
                end
            end
            return ResizeController.new({ handles = handles, win = s })
        end,
        _RegisterOverlay = liveField(
            ---@return function?
            function(s)
                return overlayMethod(s, "_RegisterOverlay", registerOverlay)
            end
        ),
        _UnregisterOverlay = liveField(
            ---@return function?
            function(s)
                return overlayMethod(s, "_UnregisterOverlay", unregisterOverlay)
            end
        ),
    },
    methods = {
        SetSize = function(s, width, height)
            live(s)
            if type(width) ~= "number" or type(height) ~= "number" then
                strict.fault("prettyui Window:SetSize(width, height) needs numbers")
            end
            windowSetSize(s, width, height)
        end,
        SetScrollPosition = function(s, position)
            live(s)
            windowScrollTo(s, position)
        end,
        SetContentHeight = windowSetContentHeight,
        Show = function(s)
            live(s)
            windowShow(s)
        end,
        Close = windowClose,
        -- 1.2.0 ends any title-bar press and syncs the overlays hidden before tearing down,
        -- then forgets them (src/window.lua, Destroy). Not libraryObject's Destroy: that marks
        -- the object destroyed first, and these steps run before it does.
        Destroy = function(s)
            if s.destroyed then return end
            stopTitleDrag(s)
            syncOverlays(s, true)
            s.overlays = {}
            s.destroyed = true
            clearContext(s.tips, true)
            destroyTip(s.tip)
            if s.titleDrag then
                s.titleDrag:Destroy()
                s.titleDrag = nil
            end
            for _, handle in pairs(s.handles or {}) do
                handle:Destroy()
            end
            s.handles = nil
            s.root:Destroy()
            s.root = nil
        end,
        AddText = function(s, value)
            return addText(s.lib, s, value, false)
        end,
        AddTitle = function(s, value)
            return addText(s.lib, s, value, true)
        end,
        AddCheckboxButton = function(s, choices, options)
            return addCheckbox(s.lib, s, choices, options)
        end,
        AddDivider = function(s, options)
            return addDivider(s.lib, s, options)
        end,
        AddSpriteButton = function(s, spriteName, action, options)
            return addSpriteButton(s, spriteName, action, options)
        end,
    },
})

local Panel = libraryObject("prettyui.Panel instance", {
    fields = {
        width = liveField(
            ---@return number
            function(s)
                return s.width
            end
        ),
        height = liveField(
            ---@return number
            function(s)
                return s.height
            end
        ),
    },
    methods = {
        -- Clamped to at least 9x9, then kept inside the parent; also makes the current
        -- position the one a stray root:SetPos snaps back to.
        SetSize = function(s, width, height)
            live(s)
            if type(width) ~= "number" or type(height) ~= "number" then
                strict.fault("prettyui Panel:SetSize(width, height) needs numbers")
            end
            s.width = clamp(math.floor(width), PANEL_MIN)
            s.height = clamp(math.floor(height), PANEL_MIN)
            s.root:SetSize(s.width, s.height)
            clampIntoParent(s)
        end,
        -- Rows flow from (14, 12) inside the 4 px frame, so the first sits at +18,+16 (probe).
        AddSpriteButton = function(s, spriteName, action, options)
            return addSpriteButton(s, spriteName, action, options)
        end,
    },
}, function(s)
    clearContext(s.tips, true)
    destroyTip(s.tip)
end)

internal.syncContent = syncContent
internal.windowWheel = windowWheel
internal.windowSetSize = windowSetSize
internal.stopTitleDrag = stopTitleDrag
internal.windowShow = windowShow
internal.windowClose = windowClose
internal.RESIZE_HANDLES = RESIZE_HANDLES
internal.Window = Window
internal.Panel = Panel
