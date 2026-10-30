-- A fake of the part of PrettyUI 1.2.0 (https://prettyui.j3.gg, mod.io 6398181) the Chore
-- Tracker uses, served as the dependency global a manifest asks for, and the test driver
-- (h.ui) that clicks, drags and resizes it. It is the harness's own code: PrettyUI ships
-- without a licence, so none of its source is copied. The numbers in internal.lua (sizes, offsets,
-- defaults) were read from the installed 1.2.0 source and checked against a beta-client
-- probe on 2026-10-25; docs/testing.md's fidelity ledger says which is which.
--
-- Modelled: Window (titled, resizable, close button, AddText/AddTitle/AddCheckboxButton/
-- AddDivider/AddSpriteButton, SetScrollPosition and the `_scroll.scrollY` it sets, the
-- `content` layer for a plugin's own components and the `viewport` it scrolls in,
-- SetContentHeight, the wheel handler, the title-bar drag layer `titleDrag`'s stacking, and the
-- overlays registered with the internal `_RegisterOverlay` and when they are synced),
-- standalone Panel (AddSpriteButton, Alt-drag), SpriteButton and Tooltip.attach. Any other
-- library member, method or option faults as unmocked; extend the fake, with a ledger row,
-- when a plugin needs more.
--
-- Layout: this file is the library's entry point (the Library class, the *Module statics,
-- install and step). internal.lua holds the shared helpers, objects.lua the library objects,
-- window.lua Window and Panel, popup.lua AchievementPopup and driver.lua the h.ui driver.

local strict = require("tests.harness.strict")
local ui = require("tests.harness.api.ui")
local internal = require("tests.harness.api.prettyui.internal")
-- Each file registers its shared functions on `internal` as it loads, in this order.
require("tests.harness.api.prettyui.objects")
require("tests.harness.api.prettyui.window")
require("tests.harness.api.prettyui.popup")
local driver = require("tests.harness.api.prettyui.driver")

local M = {}

M.MOD_ID = 6398181
M.VERSION = "1.2.0"

local BORDER = internal.BORDER
local TITLE_HEIGHT = internal.TITLE_HEIGHT
local CLOSE_SIZE = internal.CLOSE_SIZE
local CLOSE_RIGHT = internal.CLOSE_RIGHT
local CLOSE_Y = internal.CLOSE_Y
local WINDOW_DEFAULTS = internal.WINDOW_DEFAULTS
local PANEL_BORDER = internal.PANEL_BORDER
local PANEL_DEFAULTS = internal.PANEL_DEFAULTS
local START_Y = internal.START_Y
local clamp = internal.clamp
local checkOptions = internal.checkOptions
local parentState = internal.parentState
local remember = internal.remember
local clampIntoParent = internal.clampIntoParent
local gone = internal.gone
local track = internal.track
local attachTip = internal.attachTip
local newContext = internal.newContext
local attachRawTooltip = internal.attachRawTooltip
local newSpriteButton = internal.newSpriteButton
local syncContent = internal.syncContent
local windowWheel = internal.windowWheel
local RESIZE_HANDLES = internal.RESIZE_HANDLES
local Window = internal.Window
local Panel = internal.Panel
local newPopup = internal.newPopup

-- The library tables: prettyui.Window.new(...) and so on.
---@param name string
---@param new function
---@return table class
local function module(name, new)
    return strict.class("prettyui." .. name, { undeclared = true, statics = { new = new } })
end

local WindowModule = module("Window", function(lib, parent, options)
    local ps = parentState("Window.new", parent)
    options = checkOptions("Window", options)
    local s = {
        kind = "Window",
        lib = lib,
        title = options.title,
        onClose = options.onClose,
        tips = newContext(ps),
        resizable = options.resizable == true,
        minWidth = options.minWidth or WINDOW_DEFAULTS.minWidth,
        minHeight = options.minHeight or WINDOW_DEFAULTS.minHeight,
        maxWidth = options.maxWidth,
        maxHeight = options.maxHeight,
        flow = { nextY = START_Y, hasItems = false, contentHeight = 0 },
        destroyed = false,
    }
    s.root, s.rootState = ui.create("Layer", ps)
    s.root:SetPos(options.x or WINDOW_DEFAULTS.x, options.y or WINDOW_DEFAULTS.y)
    s.root:SetSize(
        clamp(options.width or WINDOW_DEFAULTS.width, s.minWidth, s.maxWidth),
        clamp(options.height or WINDOW_DEFAULTS.height, s.minHeight, s.maxHeight)
    )
    local top = s.title and TITLE_HEIGHT or BORDER
    s.scrollY = 0
    -- 1.2.0 puts the viewport at 0,0 in a scroll root inside the frame; the fake leaves out
    -- that root (same place) and the scrollbar, so the viewport is the frame's full width.
    s.viewport, s.viewportState = ui.create("Layer", s.rootState)
    s.viewport:SetPos(BORDER, top)
    s.viewport:SetSize(-BORDER * 2, -top - BORDER, 1.0, 1.0)
    s.content, s.contentState = ui.create("Layer", s.viewportState)
    -- Both take pointer input and hand the wheel to the window's handler, as the scroll
    -- controller sets them up (subscribed with no id, so it is their default ONSCROLLWHEEL
    -- listener); the h.ui driver treats them like a plugin's own layers.
    s.onWheel = function(_, delta)
        return windowWheel(s, delta)
    end
    for _, layer in ipairs({ s.viewportState, s.contentState }) do
        layer.clickthrough = false
        layer.raw = true
        ui.addListener(layer, ui.Hook.ONSCROLLWHEEL, nil, s.onWheel)
    end
    s.flow.onGrow = function()
        syncContent(s)
    end
    syncContent(s)
    s.overlays = {}
    s.noOverlayInternals = lib.h.ui.noOverlayInternals
    s.registerRaises = lib.h.ui.registerRaises
    s.scrollMode = lib.h.ui.scrollMode
    if s.title then
        local drag, dragState = ui.create("Layer", ps)
        s.titleDrag = drag
        -- A real layer's isClicked is false until the title bar is held; the generic fake
        -- layer faults on it until set, so 1.2.0's titleDrag starts it false.
        dragState.isClicked = false
        s.titleDragState = dragState
    end
    s.resizeEnabled = true
    s.resizeMode = lib.h.ui.resizeMode
    if s.resizable then
        s.handles = {}
        for _, key in ipairs(RESIZE_HANDLES) do
            s.handles[key] = ui.create("Layer", ps)
        end
    end
    s.closeButton, s.closeState = ui.create("Sprite", s.rootState)
    s.closeButton:SetPos(-CLOSE_SIZE - CLOSE_RIGHT, CLOSE_Y, 1.0)
    s.closeButton:SetSize(CLOSE_SIZE, CLOSE_SIZE)
    s.tip = attachTip(lib, s.rootState, ps, options.tooltip, nil)
    -- Only a titled or resizable window gets PrettyUI's drag bounds, which snap a stray
    -- root:SetPos back.
    s.bounded = s.title ~= nil or s.resizable
    if s.bounded then remember(s) end
    local obj = Window.new(s)
    s.proxy = obj
    lib.closeButtons[s.closeState] = s
    track(lib, "Window", obj, s)
    return obj
end)

local PanelModule = module("Panel", function(lib, parent, options)
    local ps = parentState("Panel.new", parent)
    options = checkOptions("Panel", options)
    local s = {
        kind = "Panel",
        lib = lib,
        tips = newContext(ps),
        backgroundAlpha = options.backgroundAlpha,
        width = options.width or PANEL_DEFAULTS.width,
        height = options.height or PANEL_DEFAULTS.height,
        flow = { nextY = START_Y, hasItems = false, contentHeight = 0 },
        destroyed = false,
    }
    s.root, s.rootState = ui.create("Layer", ps)
    s.root:SetPos(options.x or 0, options.y or 0)
    s.root:SetSize(s.width, s.height)
    local content
    content, s.contentState = ui.create("Layer", s.rootState)
    content:SetPos(PANEL_BORDER, PANEL_BORDER)
    content:SetSize(-PANEL_BORDER * 2, -PANEL_BORDER * 2, 1.0, 1.0)
    s.tip = attachTip(lib, s.rootState, ps, options.tooltip, nil)
    clampIntoParent(s)
    local obj = Panel.new(s)
    s.proxy = obj
    track(lib, "Panel", obj, s)
    return obj
end)

local SpriteButtonModule = module("SpriteButton", function(lib, parent, spriteName, action, options)
    local ps = parentState("SpriteButton.new", parent)
    return newSpriteButton(lib, ps, spriteName, action, checkOptions("SpriteButton", options))
end)

local AchievementPopupModule = strict.class("prettyui.AchievementPopup", {
    undeclared = true,
    statics = {
        new = function(lib, parent, options)
            return newPopup(lib, parent, options)
        end,
        -- nil when there is no parent, as in 1.2.0. The real one then falls back to the game
        -- area, which the harness doesn't have: a plugin must pass a parent. The driver's
        -- popupsFail() stands in for a client with nowhere to put it.
        show = function(lib, options)
            options = checkOptions("AchievementPopup", options)
            if lib.popupsFail then return nil end
            if options.parent == nil then
                strict.fault("unmocked API: AchievementPopup.show without options.parent")
            end
            return newPopup(lib, options.parent, options)
        end,
    },
})

local TooltipModule = strict.class("prettyui.Tooltip", {
    undeclared = true,
    statics = { attach = attachRawTooltip },
})

local Library = strict.class("prettyui", {
    undeclared = true,
    fields = {
        Window = "Window",
        Panel = "Panel",
        SpriteButton = "SpriteButton",
        AchievementPopup = "AchievementPopup",
        Tooltip = "Tooltip",
        version = function()
            return M.VERSION
        end,
    },
})

-- Expose the fake as `env[global]`. One library per load, shared by every global that
-- names it.
---@param h table the harness
---@param env table
---@param global string
function M.install(h, env, global)
    local instance = h.instance
    if not instance.prettyui then
        local lib = {
            records = {},
            byObj = setmetatable({}, { __mode = "k" }),
            closeButtons = {},
            tooltips = {},
            rawTips = {}, -- target state -> its Tooltip.attach tooltip
            h = h,
            popupCount = 0,
        }
        lib.global = Library.new({
            Window = WindowModule.new(lib),
            Panel = PanelModule.new(lib),
            SpriteButton = SpriteButtonModule.new(lib),
            AchievementPopup = AchievementPopupModule.new(lib),
            Tooltip = TooltipModule.new(lib),
        })
        instance.prettyui = lib
    end
    env[global] = instance.prettyui.global
end

-- Once per harness step, before Logic: a Window or Panel root moved by a bare root:SetPos
-- goes back to its remembered position. The probe saw PrettyUI's drag bounds do this to a
-- Panel; when the client triggers it is unknown (docs/testing.md, fidelity ledger).
---@param h table
function M.step(h)
    local lib = h.instance and h.instance.alive and h.instance.prettyui
    if not lib then return end
    for _, r in ipairs(lib.records) do
        local s = r.s
        if (r.kind == "Window" or r.kind == "Panel") and not gone(r) and s.remembered then
            local x, y = ui.pos(s.rootState)
            if x ~= s.remembered.x or y ~= s.remembered.y then
                s.root:SetPos(s.remembered.x, s.remembered.y)
            end
        end
    end
end

M.driver = driver.driver

return M
