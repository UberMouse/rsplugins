-- Keeping the window's scroll, wheel, grips and resize cursors working across PrettyUI
-- versions. PrettyUI 1.2.0 offers no public way to do these, so this is the one file that
-- reaches into its state and internals; main.lua and shell/window.lua go through it.
--
-- State and internals used, each guarded so a version without it loses only that. The rule:
-- reads are type-guarded, method calls are pcalled.
-- - `_scroll.scrollY`: keeps the scroll through a rebuild (scrollPosition) and places the
--   grips' press targets over scrolled rows.
-- - `_onScrollWheel`: lets the wheel over a row scroll the window (wheelHandler).
-- - `viewport` (viewport): where the grips' targets are placed from; without it, or the
--   scroll, the grips don't drag.
-- - `_RegisterOverlay` / `_UnregisterOverlay`: to hear when the window lays out its overlays,
--   so the grips' targets can be raised back over it (overlaySync); without them the targets
--   stay under the window after a title-bar press or a resize.
-- - `resize.handles`: resize cursors on the window's edges and corners (setResizeCursors);
--   without them the window shows none.
-- - `resize.enabled` / `resize:SetEnabled` and `titleDrag` (with the client's `isClicked`):
--   turn the window's resize back on after a quick title-bar click (reviveResize); without
--   them the resize handles stay hidden after such a click until the title bar is dragged.

local rows = require("shell/rows")

local M = {}

-- How far `w`'s content is scrolled, or nil if that can't be read. PrettyUI 1.2.0
-- can set it (SetScrollPosition) but has no getter, so this reads its internal
-- `_scroll.scrollY`; a version without that field gives nil.
---@param w prettyui.Window
---@return number?
function M.scrollPosition(w)
    local scroll = w._scroll
    local y = type(scroll) == "table" and scroll.scrollY
    if type(y) == "number" then return y end
    return nil
end

-- The layer the window's content is clipped to and scrolls in, or nil if there is none.
-- PrettyUI 1.2.0's `viewport` is internal; client components are userdata, the harness's
-- fakes tables.
---@param w prettyui.Window
---@return ui.Layer?
function M.viewport(w)
    local viewport = w.viewport
    if type(viewport) == "userdata" or type(viewport) == "table" then
        return viewport --[[@as ui.Layer]]
    end
    return nil
end

-- A row swallows the mouse wheel unless it hands it to the window. The handler is PrettyUI
-- 1.2.0-internal, so without it the rows are still made, just without that.
---@param w prettyui.Window
---@return ChoreWheelHandler?
function M.wheelHandler(w)
    if type(w._onScrollWheel) == "function" then return w._onScrollWheel end
    return nil
end

-- A way to hear when `w` lays out its overlays, for grips.lua: called with a callback, it
-- registers a sentinel layer as one of `w`'s overlays (PrettyUI 1.2.0-internal) whose layout
-- is that callback, and returns the function that unregisters and destroys it. That must run
-- before `w` is destroyed: 1.2.0 checks only that an overlay's interface exists, which the
-- plugin layer's always does, so it would set `hidden` on a destroyed sentinel. The sentinel
-- is never shown (PrettyUI hides it on each sync) and lets clicks through. Returns nil for a
-- version without those internals; the function it returns gives nil if registering fails,
-- as on one whose internals take other arguments.
---@param w prettyui.Window
---@param parent ui.ComponentCollection the plugin layer, where PrettyUI's own overlays live
---@return (fun(onSync: fun()): fun()?)?
function M.overlaySync(w, parent)
    if type(w._RegisterOverlay) ~= "function" or type(w._UnregisterOverlay) ~= "function" then
        return nil
    end
    return function(onSync)
        local sentinel = ui.Layer.new(parent)
        sentinel:SetSize(1, 1)
        sentinel.clickthrough = true
        sentinel.hidden = true
        local ok = pcall(w._RegisterOverlay, w, sentinel, function()
            return false
        end, onSync)
        if not ok then
            sentinel:Destroy()
            return nil
        end
        return function()
            -- If it is still registered, PrettyUI would set `hidden` on it after a Destroy;
            -- left alive it stays hidden, 1x1 and click-through.
            if pcall(w._UnregisterOverlay, w, sentinel) then sentinel:Destroy() end
        end
    end
end

-- The cursor over each of the window's resize handles (PrettyUI 1.2.0 sets none): diagonal
-- arrows on the corners and the four-way arrow on the edges. In the client the vertical and
-- horizontal scale cursors show nothing on these handles (docs/api-concepts.md), so the edges
-- use the move cursor, which the title bar shows too.
local RESIZE_CURSORS = {
    nw = id.Cursor.TOPLEVEL_V2_SCALE_DIAG_1,
    se = id.Cursor.TOPLEVEL_V2_SCALE_DIAG_1,
    ne = id.Cursor.TOPLEVEL_V2_SCALE_DIAG_2,
    sw = id.Cursor.TOPLEVEL_V2_SCALE_DIAG_2,
    n = id.Cursor.TOPLEVEL_V2_MOVE,
    s = id.Cursor.TOPLEVEL_V2_MOVE,
    e = id.Cursor.TOPLEVEL_V2_MOVE,
    w = id.Cursor.TOPLEVEL_V2_MOVE,
}

-- Workaround for PrettyUI 1.2.0: a quick title-bar click reaches it release-first
-- (docs/api-concepts.md), so the release turns resize on and the press then turns it off for
-- good. Resize off with the title bar not held is that stuck state; turn it back on. A
-- collapsed (or missing) window is left alone.
---@param w prettyui.Window? the window, nil before it is built
---@param isCollapsed boolean whether the window is collapsed to its button
function M.reviveResize(w, isCollapsed)
    local win = w ---@type table?
    if isCollapsed or not win then return end
    local resize, titleDrag = win.resize, win.titleDrag
    if type(resize) ~= "table" then return end
    -- Client components are userdata; the harness's fakes are tables.
    if type(titleDrag) ~= "userdata" and type(titleDrag) ~= "table" then return end
    if resize.enabled ~= false or titleDrag.isClicked == true then return end
    if type(resize.SetEnabled) ~= "function" then return end
    pcall(resize.SetEnabled, resize, true)
end

-- Set the resize cursors on `w`'s eight resize handles with rows.setCursor. PrettyUI only
-- moves, sizes and hides the handles afterwards, so once per window is enough. A PrettyUI
-- without `resize.handles` (or a handle) is skipped.
---@param w table the PrettyUI window
function M.setResizeCursors(w)
    local resize = w.resize
    local handles = type(resize) == "table" and resize.handles
    if type(handles) ~= "table" then return end
    for key, cursor in pairs(RESIZE_CURSORS) do
        local handle = handles[key]
        -- pcall: a handle that isn't a layer, as in another PrettyUI version, costs only its
        -- own cursor, not the rest of the window's build.
        if handle then pcall(rows.setCursor, handle, cursor) end
    end
end

return M
