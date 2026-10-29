---@meta
-- LuaLS types for the part of PrettyUI 1.2.0 (mod.io 6398181, https://prettyui.j3.gg) that
-- the test harness fakes (tests/harness/api/prettyui.lua). Written from the installed 1.2.0
-- source and the docs site; PrettyUI ships without a licence, so nothing here is copied from
-- it. A plugin that lists it, e.g. `"requiredDependencies": { "prettyui": 6398181 }`, gets
-- it as the global `prettyui` (docs/plugin-anatomy.md). Declare a member here only when the
-- fake models it, so LuaLS and the harness agree on the subset.

---@alias prettyui.Tooltip string|table

---@class prettyui
---@field version string "1.2.0"
---@field Window prettyui.WindowModule
---@field Panel prettyui.PanelModule
---@field SpriteButton prettyui.SpriteButtonModule
---@field AchievementPopup prettyui.AchievementPopupModule
---@field Tooltip prettyui.TooltipModule
prettyui = {}

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

---@class prettyui.WindowOptions
---@field title string? Shown in a title bar the window can be dragged by. Untitled windows have none
---@field x number? Default 80
---@field y number? Default 80
---@field width number? Default 480, clamped to minWidth..maxWidth
---@field height number? Default 340, clamped to minHeight..maxHeight
---@field resizable boolean? Drag handles on the edges and corners
---@field minWidth number? Default 220
---@field minHeight number? Default 140
---@field maxWidth number?
---@field maxHeight number?
---@field onClose fun(window: prettyui.Window)? Called by Close(), before the window hides
---@field tooltip prettyui.Tooltip?

---@class prettyui.WindowModule
local WindowModule = {}

---@param parent ui.Component
---@param options prettyui.WindowOptions?
---@return prettyui.Window
function WindowModule.new(parent, options) end

---@class prettyui.Window
---@field root ui.Layer The window's own layer: read x/y/width/height for its position and size. A bare root:SetPos is snapped back unless SetSize follows. nil after Destroy()
---@field closeButton ui.Sprite The X at (width - 28, 7); clicking it calls Close()
---@field content ui.Layer The scrolling layer the rows live in. Make your own ui.Layer/Sprite/Text under it at an explicit position and call SetContentHeight so the window scrolls over them. nil after Destroy()
---@field _onScrollWheel fun(component: ui.Component, delta: number): boolean Internal, not API: the window's wheel handler. Subscribe it to a row's ui.Hook.ONSCROLLWHEEL so the wheel over that row still scrolls the window; it scrolls by delta * 32 px while the content overflows and returns false if the position moved, else true
---@field _scroll { scrollY: number }? Internal, not API: the content's scroll controller, whose `scrollY` is the only way to read the scroll position. nil after Destroy()
local Window = {}

---Scroll the content to `position` px from its top, clamped to 0..(content height - viewport height).
---@param position number?
function Window:SetScrollPosition(position) end

---Set the scrollable height of the content. It replaces the height the rows grew it to, and
---re-clamps the scroll position.
---@param height number
function Window:SetContentHeight(height) end

---Resize, clamped to the window's min/max; also makes the current position stick.
---@param width number
---@param height number
function Window:SetSize(width, height) end

function Window:Show() end

---Call onClose(window), then hide the window. It isn't destroyed: Show() brings it back.
function Window:Close() end

function Window:Destroy() end

---@class prettyui.TextOptions
---@field text string?
---@field tooltip prettyui.Tooltip?
---@field y number? Place the row at this content y instead of the next flow row; the flow doesn't move

---Add a text row; set the returned component's `content` to change it.
---@param text string|prettyui.TextOptions
---@return ui.Text
function Window:AddText(text) end

---@param text string|prettyui.TextOptions
---@return ui.Text
function Window:AddTitle(text) end

---@class prettyui.CheckboxChoice
---@field text string?
---@field label string? Same as text
---@field value any? Defaults to the text
---@field selected boolean?
---@field disabled boolean?
---@field tooltip prettyui.Tooltip? Shown while hovering this choice's row

---@class prettyui.CheckboxOptions
---@field onChange fun(group: prettyui.CheckboxButton, values: any[], value: any, selected: boolean)? After a change by the user, or by SetSelected unless notify is false
---@field selectedValues any[]|table<any, boolean>?
---@field y number? Place it at this content y instead of the next flow row; the flow doesn't move
---@field colour integer? The choices' text colour, 0xRRGGBBAA. Fixed once created
---@field tooltip prettyui.Tooltip?

---@param choices (string|prettyui.CheckboxChoice)[] Not empty
---@param options prettyui.CheckboxOptions?
---@return prettyui.CheckboxButton
function Window:AddCheckboxButton(choices, options) end

---@param options { tooltip: prettyui.Tooltip? }?
---@return prettyui.Divider
function Window:AddDivider(options) end

---Add a SpriteButton as the next content row (or at options.y, outside the flow).
---@param spriteName string
---@param action fun(button: prettyui.SpriteButton, enabled: boolean)?
---@param options prettyui.SpriteButtonOptions?
---@return prettyui.SpriteButton
function Window:AddSpriteButton(spriteName, action, options) end

---@class prettyui.CheckboxButton
---@field root ui.Layer
local CheckboxButton = {}

---The checked values, in choice order.
---@return any[]
function CheckboxButton:GetSelectedValues() end

---@param value any
---@return boolean
function CheckboxButton:IsSelected(value) end

---@param value any
---@param selected boolean
---@param notify boolean? false to skip onChange
---@return boolean # false if no choice has this value
function CheckboxButton:SetSelected(value, selected, notify) end

---Add, replace (nil removes) one choice's tooltip. A string on an existing tooltip only
---changes its text; a table makes a new, hidden one.
---@param value any
---@param tooltip prettyui.Tooltip?
---@return boolean # false if no choice has this value
function CheckboxButton:SetOptionTooltip(value, tooltip) end

function CheckboxButton:Destroy() end

---@class prettyui.Divider
---@field root ui.Sprite
local Divider = {}

function Divider:Destroy() end

---------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------

---@class prettyui.PanelOptions
---@field x number? Default 0
---@field y number? Default 0
---@field width number? Default 300
---@field height number? Default 160
---@field backgroundAlpha number? 0..1. The frame still draws at 0
---@field scrollable boolean? false: never scroll or show a scrollbar. Default true
---@field tooltip prettyui.Tooltip?

---@class prettyui.PanelModule
local PanelModule = {}

---A standalone panel. The user can Alt-drag it (with the console closed).
---@param parent ui.Component
---@param options prettyui.PanelOptions?
---@return prettyui.Panel
function PanelModule.new(parent, options) end

---@class prettyui.Panel
---@field root ui.Layer A bare root:SetPos is snapped back unless SetSize follows. nil after Destroy()
---@field width integer
---@field height integer
local Panel = {}

---Resize (at least 9x9) and keep the panel inside its parent; also makes the current position
---stick.
---@param width number
---@param height number
function Panel:SetSize(width, height) end

---Add a SpriteButton to the panel's content; the first row sits at +18,+16 inside the panel.
---@param spriteName string
---@param action fun(button: prettyui.SpriteButton, enabled: boolean)?
---@param options prettyui.SpriteButtonOptions?
---@return prettyui.SpriteButton
function Panel:AddSpriteButton(spriteName, action, options) end

function Panel:Destroy() end

---------------------------------------------------------------------------
-- SpriteButton
---------------------------------------------------------------------------

---@class prettyui.SpriteButtonOptions
---@field x number?
---@field y number?
---@field xAnchor number? Fraction of the parent's width added to x (1.0 = from its right edge)
---@field yAnchor number?
---@field size number? Width and height; default 24
---@field width number?
---@field height number?
---@field tooltip prettyui.Tooltip?

---@class prettyui.SpriteButtonModule
local SpriteButtonModule = {}

---Errors with "Unknown SpriteButton sprite: <name>" for a name PrettyUI doesn't have
---(MENU, SETTINGS, TRASH, LOCK... any case).
---@param parent ui.Component
---@param spriteName string
---@param action fun(button: prettyui.SpriteButton, enabled: boolean)?
---@param options prettyui.SpriteButtonOptions?
---@return prettyui.SpriteButton
function SpriteButtonModule.new(parent, spriteName, action, options) end

---@class prettyui.SpriteButton
---@field root ui.Sprite
local SpriteButton = {}

---Replace (nil removes) the tooltip. A string on an existing tooltip only changes its text; a
---table makes a new, hidden one.
---@param value prettyui.Tooltip?
---@return boolean
function SpriteButton:SetTooltip(value) end

function SpriteButton:Destroy() end

---------------------------------------------------------------------------
-- Tooltip
---------------------------------------------------------------------------

---@class prettyui.TooltipModule
local TooltipModule = {}

---Attach a tooltip to `target`: shown on its mouse-over, hidden on its mouse-leave. It makes
---`target` take the mouse (clickthrough false) until Destroy. With a Window's `content` as
---`parent`, it is drawn on the window's parent, hidden by Window:Close and destroyed by
---Window:Destroy. A string is the text; the table form takes `text` and `maxWidth`. Returns
---nil for a nil value.
---@param target ui.Component
---@param parent ui.Component
---@param value string|{ text: string, maxWidth: number? }?
---@return prettyui.TooltipAttachment?
function TooltipModule.attach(target, parent, value) end

---@class prettyui.TooltipAttachment
local TooltipAttachment = {}

---Remove the tooltip and give `target` its clickthrough back.
function TooltipAttachment:Destroy() end

---------------------------------------------------------------------------
-- AchievementPopup
---------------------------------------------------------------------------

---@class prettyui.AchievementPopupOptions
---@field parent ui.Component? Where `show` puts it; nil means the game area
---@field title string? Default "ACHIEVEMENT COMPLETE"
---@field text string?
---@field width number? Default 300
---@field height number? Default 92
---@field x number? Default -width/2
---@field y number? Default 20
---@field xAnchor number? Fraction of the parent's width added to x. Default 0.5
---@field yAnchor number? Fraction of the parent's height added to y. Default 0
---@field sound boolean? false plays no sound
---@field soundID SoundId? Default id.Sound.ARCH_INFO_POPUP
---@field onComplete fun(popup: prettyui.AchievementPopup)? Called after it fades out and is destroyed

---@class prettyui.AchievementPopupModule
local AchievementPopupModule = {}

---Show a popup in `options.parent`; nil when there is no parent to put it in. It ends itself
---after about 4 s (200 Logic ticks; it is destroyed on the 201st).
---@param options prettyui.AchievementPopupOptions?
---@return prettyui.AchievementPopup?
function AchievementPopupModule.show(options) end

---@param parent ui.Component
---@param options prettyui.AchievementPopupOptions?
---@return prettyui.AchievementPopup
function AchievementPopupModule.new(parent, options) end

---@class prettyui.AchievementPopup
---@field root ui.Layer nil after Destroy()
local AchievementPopup = {}

---Remove it and its Logic subscription. onComplete is not called.
function AchievementPopup:Destroy() end
