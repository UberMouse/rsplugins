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
local Window = {}

---Resize, clamped to the window's min/max; also makes the current position stick.
---@param width number
---@param height number
function Window:SetSize(width, height) end

function Window:Show() end

---Call onClose(window), then hide the window. It isn't destroyed: Show() brings it back.
function Window:Close() end

function Window:Destroy() end

---Add a text row; set the returned component's `content` to change it.
---@param text string|{ text: string, tooltip: prettyui.Tooltip? }
---@return ui.Text
function Window:AddText(text) end

---@param text string|{ text: string, tooltip: prettyui.Tooltip? }
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

function SpriteButton:Destroy() end
