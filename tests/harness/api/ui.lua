-- ui.Interfaces:GetComponent for the plugin root layer, id.Component for its name, and the
-- fake components the PrettyUI fake (api/prettyui.lua) builds on it. Nothing else under `ui`
-- or `id` is modelled: any other member faults as unmocked.
--
-- A component keeps what it was given (SetPos/SetSize pixels plus fractions of the parent's
-- size, as on ui/component.html) and works out x, y, width and height from its parent on
-- every read, so a child anchored to its parent's right edge follows it as it moves and
-- resizes, as children do in the client (docs/api-concepts.md, UI).

local strict = require("tests.harness.strict")

local M = {}

-- docs/api/consts/Component.lua; ui_spec.lua checks the value against it.
M.PLUGIN_LAYER_NAME = "TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP"
M.PLUGIN_LAYER_ID = 96797567
-- The plugin layer's size and position in the beta client (PrettyUI probe, 2026-10-25).
M.ROOT_WIDTH, M.ROOT_HEIGHT = 3836, 2121

-- proxy -> state, for the PrettyUI fake to find the component behind a parent it is given.
local statesByProxy = setmetatable({}, { __mode = "k" })

---@param v number
---@return integer
local function round(v)
    return math.floor(v + 0.5)
end

---@param s table component state
---@return integer
function M.width(s)
    if not s.parent then return M.ROOT_WIDTH end
    return round(s.pw + s.rw * M.width(s.parent))
end

---@param s table
---@return integer
function M.height(s)
    if not s.parent then return M.ROOT_HEIGHT end
    return round(s.ph + s.rh * M.height(s.parent))
end

-- Position relative to the parent.
---@param s table
---@return integer x
---@return integer y
function M.pos(s)
    if not s.parent then return 0, 0 end
    return round(s.px + s.rx * M.width(s.parent)), round(s.py + s.ry * M.height(s.parent))
end

-- Absolute position (xyGlobal).
---@param s table
---@return integer x
---@return integer y
function M.globalPos(s)
    if not s.parent then return 0, 0 end
    local gx, gy = M.globalPos(s.parent)
    local x, y = M.pos(s)
    return gx + x, gy + y
end

-- Whether it would draw: neither it nor any ancestor is hidden or destroyed.
---@param s table
---@return boolean
function M.visible(s)
    while s do
        if s.hidden or s.destroyed then return false end
        s = s.parent
    end
    return true
end

-- Whether `s` is `ancestor` or inside it.
---@param s table
---@param ancestor table
---@return boolean
function M.within(s, ancestor)
    while s do
        if s == ancestor then return true end
        s = s.parent
    end
    return false
end

---@param proxy any
---@return table? # the component's state, or nil if `proxy` is not a fake component
function M.stateOf(proxy)
    return statesByProxy[proxy]
end

local Vector2 = strict.class("Vector2", {
    fields = {
        x = function(s)
            return s.x
        end,
        y = function(s)
            return s.y
        end,
    },
})

-- Every member of a destroyed component faults: the client's behaviour is undocumented, and
-- a plugin that keeps using one has lost track of its UI.
---@param s table
local function live(s)
    if s.destroyed then strict.fault(s.class .. " used after Destroy()") end
end

---@param s table
local function destroy(s)
    s.destroyed = true
    for _, child in ipairs(s.children) do
        destroy(child)
    end
end

---@param what string
---@param ... any
local function numbers(what, ...)
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if v ~= nil and type(v) ~= "number" then
            strict.fault(what .. ": arguments must be numbers")
        end
    end
end

-- The members every fake component has (ui/component.html), each faulting once destroyed.
local FIELDS = {
    x = function(s)
        return (M.pos(s))
    end,
    y = function(s)
        return select(2, M.pos(s))
    end,
    width = function(s)
        return M.width(s)
    end,
    height = function(s)
        return M.height(s)
    end,
    hidden = function(s)
        return s.hidden
    end,
    xyGlobal = function(s)
        local x, y = M.globalPos(s)
        return Vector2.new({ x = x, y = y })
    end,
}

local METHODS = {
    -- SetPos(x, y, parentPercentageX?, parentPercentageY?); the self-percentage arguments
    -- aren't modelled.
    SetPos = function(s, x, y, rx, ry, ...)
        numbers(s.class .. ":SetPos", x, y, rx, ry)
        if type(x) ~= "number" or type(y) ~= "number" then
            strict.fault(s.class .. ":SetPos(x, y, ...) needs x and y")
        end
        if select("#", ...) > 0 then
            strict.fault("unmocked API: " .. s.class .. ":SetPos self-percentage arguments")
        end
        if not s.parent then
            strict.fault("the plugin root layer is the client's: don't move it")
        end
        s.px, s.py, s.rx, s.ry = x, y, rx or 0, ry or 0
    end,
    SetSize = function(s, w, h, rw, rh)
        numbers(s.class .. ":SetSize", w, h, rw, rh)
        if type(w) ~= "number" or type(h) ~= "number" then
            strict.fault(s.class .. ":SetSize(w, h, ...) needs w and h")
        end
        if not s.parent then
            strict.fault("the plugin root layer is the client's: don't resize it")
        end
        s.pw, s.ph, s.rw, s.rh = w, h, rw or 0, rh or 0
    end,
    -- Last among its siblings draws on top (ui/component.html#movetofront).
    MoveToFront = function(s)
        if not s.parent then return end
        local siblings = s.parent.children
        for i, child in ipairs(siblings) do
            if child == s then
                table.remove(siblings, i)
                break
            end
        end
        siblings[#siblings + 1] = s
    end,
    -- Destroys its children too (ui/component.html#destroy).
    Destroy = function(s)
        if not s.parent then
            strict.fault("the plugin root layer is the client's: don't destroy it")
        end
        destroy(s)
        local siblings = s.parent.children
        for i, child in ipairs(siblings) do
            if child == s then
                table.remove(siblings, i)
                break
            end
        end
    end,
}

---@param name string the stub class
---@param extra table? more fields
---@return table class
local function componentClass(name, extra)
    local fields, methods, writable = {}, {}, { hidden = true }
    for k, fn in pairs(FIELDS) do
        fields[k] = function(s)
            live(s)
            return fn(s)
        end
    end
    for k, fn in pairs(extra or {}) do
        fields[k] = fn
        writable[k] = true
    end
    for k, fn in pairs(METHODS) do
        methods[k] = function(s, ...)
            live(s)
            return fn(s, ...)
        end
    end
    return strict.class(name, { fields = fields, methods = methods, writable = writable })
end

-- What GetComponent returns for the plugin layer is a ui.Component per the stub; the
-- PrettyUI fake makes Layers, Sprites and Texts, as the real library does.
local CLASSES = {
    Component = componentClass("ui.Component"),
    Layer = componentClass("ui.Layer"),
    Sprite = componentClass("ui.Sprite"),
    Text = componentClass("ui.Text", {
        content = function(s)
            live(s)
            return s.content
        end,
    }),
}

---@param kind string "Component" (the root), "Layer", "Sprite" or "Text"
---@param parent table? parent state; nil for the root
---@return table proxy
---@return table state
function M.create(kind, parent)
    local s = {
        class = "ui." .. kind,
        parent = parent,
        children = {},
        px = 0,
        py = 0,
        rx = 0,
        ry = 0,
        pw = 0,
        ph = 0,
        rw = 0,
        rh = 0,
        hidden = false,
        destroyed = false,
        content = kind == "Text" and "" or nil,
    }
    if parent then parent.children[#parent.children + 1] = s end
    local proxy = assert(CLASSES[kind], kind).new(s)
    s.proxy = proxy
    statesByProxy[proxy] = s
    return proxy, s
end

local Interfaces = strict.class("ui.Interfaces", {
    methods = {
        GetComponent = function(s, combinedID, ...)
            if select("#", ...) > 0 then
                strict.fault("unmocked API: ui.Interfaces:GetComponent with more than a combinedID")
            end
            if combinedID ~= M.PLUGIN_LAYER_ID then
                strict.fault(
                    "unmocked API: ui.Interfaces:GetComponent("
                        .. tostring(combinedID)
                        .. "): only id.Component."
                        .. M.PLUGIN_LAYER_NAME
                        .. " is modelled"
                )
            end
            return s.root
        end,
    },
})

local UiNamespace = strict.class("ui", {
    fields = {
        Interfaces = function(s)
            return s.interfaces
        end,
    },
})
-- The stubs declare ui.Interfaces as a class of its own, not a field of `ui`.
strict.declare("ui", "Interfaces", "namespace")

local IdNamespace = strict.class("_global.id", {
    fields = {
        Component = function(s)
            return s.components
        end,
    },
})

---@param h table the harness
---@param env table the sandbox being built
function M.install(h, env)
    -- One root per load, the same object on every call (the client may hand out a fresh
    -- userdata each time, as Player.GetEntity does).
    local root, rootState = M.create("Component", nil)
    h.instance.uiRoot = rootState
    env.ui = UiNamespace.new({ interfaces = Interfaces.new({ root = root }) })
    env.id = IdNamespace.new({
        components = strict.lookup(function(name)
            strict.fault("unmocked API: id.Component." .. tostring(name))
        end, { [M.PLUGIN_LAYER_NAME] = M.PLUGIN_LAYER_ID }),
    })
end

return M
