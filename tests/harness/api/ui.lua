-- ui.Interfaces:GetComponent for the plugin root layer, id.Component for its name, the
-- fake components the PrettyUI fake (api/prettyui.lua) builds on it, ui.Layer/Sprite/Text.new
-- for a plugin's own components, ui.Hook and ui.AlignMode, and id.Sound, id.Font, id.Sprite
-- and id.Obj by name. Nothing else under `ui` or `id` is modelled: any other member faults as
-- unmocked.
--
-- A component keeps what it was given (SetPos/SetSize pixels plus fractions of the parent's
-- size, as on ui/component.html) and works out x, y, width and height from its parent on
-- every read, so a child anchored to its parent's right edge follows it as it moves and
-- resizes, as children do in the client (docs/api-concepts.md, UI).

local catalog = require("tests.harness.catalog")
local strict = require("tests.harness.strict")
local stubs = require("tests.harness.stubs")

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

-- Absolute position as `xyGlobal` reads it: the sum of the positions up the tree, with no
-- ancestor's scroll in it. In the client a row under a layer scrolled by SetScrollPos kept its
-- xyGlobal (dev-bridge probe, 2026-10-29, docs/api-concepts.md), though it draws higher.
---@param s table
---@return integer x
---@return integer y
function M.globalPos(s)
    if not s.parent then return 0, 0 end
    local gx, gy = M.globalPos(s.parent)
    local x, y = M.pos(s)
    return gx + x, gy + y
end

-- Where it is drawn and takes the pointer, in plugin-layer coordinates: like globalPos, but a
-- parent scrolled down by `scrollY` (the PrettyUI fake sets it on a Window's viewport, where
-- 1.2.0 calls SetScrollPos) draws its children that much higher. Hit-testing, clipping and
-- the driver's pointer points use this one.
---@param s table
---@return integer x
---@return integer y
function M.drawnPos(s)
    if not s.parent then return 0, 0 end
    local gx, gy = M.drawnPos(s.parent)
    local x, y = M.pos(s)
    return gx + x, gy + y - s.parent.scrollY
end

-- Whether the point (x, y), in plugin-layer coordinates, is outside the part of `s` that
-- takes the pointer: its own rect clipped by every ancestor's (docs/api-concepts.md,
-- "Pressing and dragging a plain `ui.Layer`").
-- Returns the first of `s` and its ancestors whose rect leaves the point out, or nil.
---@param s table
---@param x number
---@param y number
---@return table? # the component that clips the point away
function M.clipper(s, x, y)
    while s do
        local gx, gy = M.drawnPos(s)
        if x < gx or y < gy or x >= gx + M.width(s) or y >= gy + M.height(s) then return s end
        s = s.parent
    end
    return nil
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

-- ui.Hook and ui.AlignMode are numbers in the client, though the stubs list strings
-- (docs/api-concepts.md, "Enums are numbers in the client"). The member names come from the
-- stubs; the numbers are invented (sorted names, counted from `base`), so a plugin can name a
-- member but not depend on its value.
---@param base integer
---@param stubValues table the stub's name -> string table
---@return table values name -> number
local function opaqueEnum(base, stubValues)
    local values = {}
    for i, name in ipairs(strict.sortedKeys(stubValues)) do
        values[name] = base + i
    end
    return values
end

---@param values table name -> number
---@return table # number -> name
local function namesByValue(values)
    local names = {}
    for name, v in pairs(values) do
        names[v] = name
    end
    return names
end

M.Hook = opaqueEnum(1000, stubs.value("ui/component.lua", "ui").Hook)
M.AlignMode = opaqueEnum(2000, stubs.value("ui/common_types.lua", "ui", { ui = {} }).AlignMode)
local hookNames, alignNames = namesByValue(M.Hook), namesByValue(M.AlignMode)

-- The id of a listener subscribed without one (Subscribe(hook, fn)).
local DEFAULT_ID = {}

-- Add a listener to `s` for `hook` under `id` (nil for the default one). A second listener
-- under an id already used for that hook is refused: what the client does is unprobed.
---@param s table component state
---@param hook integer
---@param id string?
---@param fn function
function M.addListener(s, hook, id, fn)
    local list = s.hooks[hook] or {}
    s.hooks[hook] = list
    id = id or DEFAULT_ID
    for _, listener in ipairs(list) do
        if listener.id == id then
            strict.fault(
                s.class
                    .. ":Subscribe: "
                    .. hookNames[hook]
                    .. " already has a listener under that id (whether the client replaces it "
                    .. "is unprobed): Unsubscribe it first"
            )
        end
    end
    list[#list + 1] = { id = id, fn = fn }
end

-- Remove `s`'s listener for `hook` under `id` (nil for the default one). Returns whether
-- there was one.
---@param s table component state
---@param hook integer
---@param id string?
---@return boolean
function M.removeListener(s, hook, id)
    local list = s.hooks[hook] or {}
    for i, listener in ipairs(list) do
        if listener.id == (id or DEFAULT_ID) then
            table.remove(list, i)
            return true
        end
    end
    return false
end

-- Run `s`'s listeners for `hook` in subscription order, each as fn(component, ...), while
-- each returns true. The stub says a listener returning nothing lets the next run; in the
-- client it stops them (docs/api-concepts.md, hook listener returns). A component destroyed
-- by an earlier listener gets no more. Callers run this under runtime.call.
---@param s table component state
---@param hook integer
---@param ... any
---@return integer # how many listeners ran
function M.fire(s, hook, ...)
    local snapshot = {}
    for i, listener in ipairs(s.hooks[hook] or {}) do
        snapshot[i] = listener
    end
    local ran = 0
    for _, listener in ipairs(snapshot) do
        if s.destroyed then break end
        ran = ran + 1
        if listener.fn(s.proxy, ...) ~= true then break end
    end
    return ran
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

-- A member the plugin has to set before it reads it: the client's default is unprobed, so
-- the fake doesn't invent one.
---@param member string
---@return fun(s: table): any
local function storedField(member)
    return function(s)
        if s[member] == nil then
            strict.fault(
                s.class
                    .. "."
                    .. member
                    .. " read before it was set: the client's default is unprobed"
            )
        end
        return s[member]
    end
end

-- Assigning `member` stores the value if `accepts` it, else faults with `expected`.
-- Cursor/op config states carry `owner` (their component), whose liveness gates them; a
-- component's own state has no `owner` and is checked directly.
---@param member string
---@param accepts fun(value: any): boolean
---@param expected string
---@return fun(s: table, value: any)
local function checkedSetter(member, accepts, expected)
    return function(s, value)
        live(s.owner or s)
        if not accepts(value) then
            strict.fault(s.class .. "." .. member .. " must be " .. expected)
        end
        s[member] = value
    end
end

---@param value any
---@return boolean
local function isInteger(value)
    return math.type(value) == "integer"
end

-- A cursor id the plugin may set: -1 (none) or a member of id.Cursor.
---@param value any
---@return boolean
local function isCursor(value)
    return value == -1 or (isInteger(value) and catalog.config("Cursor", value) ~= nil)
end

-- ui.ComponentCursorConfig: only `mouseOverCursor` is modelled. Its state is a table of the
-- component's own (`s.cursorState`) holding `owner`, so a handle kept across the component's
-- Destroy() faults on use.
local CursorConfig = strict.class("ui.ComponentCursorConfig", {
    fields = {
        mouseOverCursor = function(s)
            live(s.owner)
            return storedField("mouseOverCursor")(s)
        end,
    },
    setters = {
        mouseOverCursor = checkedSetter("mouseOverCursor", isCursor, "-1 or an id.Cursor member"),
    },
})

-- ui.ComponentOpConfig: the op cursors only. An op index is an integer from 0.
local OpConfig = strict.class("ui.ComponentOpConfig", {
    methods = {
        SetOpCursor = function(s, opIndex, cursorID, ...)
            live(s.owner)
            if not (isInteger(opIndex) and opIndex >= 0) or select("#", ...) > 0 then
                strict.fault(
                    "ui.ComponentOpConfig:SetOpCursor(opIndex, cursorID) needs an op index"
                )
            end
            if not (isInteger(cursorID) and catalog.config("Cursor", cursorID)) then
                strict.fault(
                    "ui.ComponentOpConfig:SetOpCursor: cursorID must be an id.Cursor member"
                )
            end
            s.opCursors[opIndex] = cursorID
        end,
        -- The page says what an unset op gives only as a filter description; -1 is the
        -- "no cursor" value mouseOverCursor uses.
        GetOpCursor = function(s, opIndex)
            live(s.owner)
            return s.opCursors[opIndex] or -1
        end,
        ClearOpCursors = function(s)
            live(s.owner)
            s.opCursors = {}
        end,
    },
})

-- The members every fake component has (ui/component.html), each faulting once destroyed.
local FIELDS = {
    clickthrough = storedField("clickthrough"),
    alpha = storedField("alpha"),
    rgba = storedField("rgba"),
    isMouseOver = function(s)
        return s.mouseOver
    end,
    -- Faults on every component: when it reads true is unprobed (a quick title-bar click was
    -- never seen with it true at a Logic tick, docs/api-concepts.md).
    isClicked = storedField("isClicked"),
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
    -- One proxy per component, so `c.cursorConfig == c.cursorConfig` and no proxy per read.
    cursorConfig = function(s)
        if not s.cursorProxy then
            s.cursorState = { class = "ui.ComponentCursorConfig", owner = s }
            s.cursorProxy = CursorConfig.new(s.cursorState)
        end
        return s.cursorProxy
    end,
    opConfig = function(s)
        if not s.opProxy then
            s.opState = { class = "ui.ComponentOpConfig", opCursors = {}, owner = s }
            s.opProxy = OpConfig.new(s.opState)
        end
        return s.opProxy
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
    -- Last among its siblings draws on top (ui/component.html#movetofront). On a component
    -- that is itself hidden it does nothing: in the client such a raise left it under a window
    -- once it was shown again (grip probe, 2026-10-29, docs/api-concepts.md). A shown one
    -- under a hidden ancestor is unprobed and raised as usual.
    MoveToFront = function(s)
        s.frontCalls = s.frontCalls + 1
        if not s.parent or s.hidden then return end
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
    -- Subscribe(hook, callback) or Subscribe(hook, id, callback) (ui/component.html#subscribe).
    Subscribe = function(s, hook, first, second, ...)
        if hookNames[hook] == nil then
            strict.fault(s.class .. ":Subscribe: the hook must be a ui.Hook member")
        end
        if select("#", ...) > 0 then strict.fault(s.class .. ":Subscribe: too many arguments") end
        if type(first) == "function" and second == nil then
            M.addListener(s, hook, nil, first)
        elseif type(first) == "string" and type(second) == "function" then
            M.addListener(s, hook, first, second)
        else
            strict.fault(s.class .. ":Subscribe(hook, callback) or Subscribe(hook, id, callback)")
        end
    end,
    -- Unsubscribe(hook) removes the default listener, Unsubscribe(hook, id) the one under that
    -- id. The page says nothing of an id nothing used; the fake faults, as the client's
    -- answer is unprobed.
    Unsubscribe = function(s, hook, id, ...)
        if hookNames[hook] == nil then
            strict.fault(s.class .. ":Unsubscribe: the hook must be a ui.Hook member")
        end
        if select("#", ...) > 0 or (id ~= nil and type(id) ~= "string") then
            strict.fault(s.class .. ":Unsubscribe(hook) or Unsubscribe(hook, id)")
        end
        if M.removeListener(s, hook, id) then return end
        strict.fault(
            s.class
                .. ":Unsubscribe: no "
                .. hookNames[hook]
                .. " listener under that id (what the client does is unprobed)"
        )
    end,
}

-- Assignable members shared by every component: each checks its value (ui/component.html).
local SETTERS = {
    clickthrough = checkedSetter("clickthrough", function(v)
        return type(v) == "boolean"
    end, "a boolean"),
    alpha = checkedSetter("alpha", function(v)
        return type(v) == "number"
    end, "a number"),
    hidden = checkedSetter("hidden", function(v)
        return type(v) == "boolean"
    end, "a boolean"),
    rgba = checkedSetter("rgba", function(v)
        return isInteger(v) and v >= 0 and v <= 0xFFFFFFFF
    end, "an integer from 0 to 0xFFFFFFFF"),
}

---@param name string the stub class
---@param more { fields: table?, setters: table?, methods: table? }? members of this kind
---@return table class
local function componentClass(name, more)
    more = more or {}
    local fields, methods = {}, {}
    local setters = {}
    for k, fn in pairs(FIELDS) do
        fields[k] = function(s)
            live(s)
            return fn(s)
        end
    end
    for k, fn in pairs(more.fields or {}) do
        fields[k] = function(s)
            live(s)
            return fn(s)
        end
    end
    for _, set in ipairs({ SETTERS, more.setters or {} }) do
        for k, fn in pairs(set) do
            setters[k] = fn
        end
    end
    for _, set in ipairs({ METHODS, more.methods or {} }) do
        for k, fn in pairs(set) do
            methods[k] = function(s, ...)
                live(s)
                return fn(s, ...)
            end
        end
    end
    return strict.class(name, { fields = fields, methods = methods, setters = setters })
end

-- Text:AlignTo(horizontal[, vertical]) takes ui.AlignMode members.
---@param s table
---@param horizontal any
---@param vertical any
---@param ... any
local function alignTo(s, horizontal, vertical, ...)
    if
        alignNames[horizontal] == nil
        or (vertical ~= nil and alignNames[vertical] == nil)
        or select("#", ...) > 0
    then
        strict.fault(s.class .. ":AlignTo(horizontal[, vertical]) takes ui.AlignMode members")
    end
end

-- What GetComponent returns for the plugin layer is a ui.Component per the stub; the
-- PrettyUI fake makes Layers, Sprites and Texts, as the real library does.
local CLASSES = {
    Component = componentClass("ui.Component"),
    Layer = componentClass("ui.Layer"),
    Sprite = componentClass("ui.Sprite", {
        fields = {
            spriteID = storedField("spriteID"),
            -- -1 while none is associated (ui/decorative_components/sprite.html).
            associatedObjectID = function(s)
                return s.objectID
            end,
        },
        setters = { spriteID = checkedSetter("spriteID", isInteger, "an integer") },
        methods = {
            -- SetAssociatedObject(objectID, quantity?): only an object in docs/api/consts/Obj.lua.
            SetAssociatedObject = function(s, objectID, quantity, ...)
                if not isInteger(objectID) or not catalog.config("Obj", objectID) then
                    strict.fault(
                        s.class
                            .. ":SetAssociatedObject: no object with id "
                            .. tostring(objectID)
                            .. " in docs/api/consts/Obj.lua"
                    )
                end
                if quantity ~= nil and not (isInteger(quantity) and quantity >= 0) then
                    strict.fault(s.class .. ":SetAssociatedObject: quantity must be a count")
                end
                if select("#", ...) > 0 then
                    strict.fault(s.class .. ":SetAssociatedObject: too many arguments")
                end
                s.objectID = objectID
            end,
        },
    }),
    Text = componentClass("ui.Text", {
        fields = {
            font = storedField("font"),
            content = function(s)
                return s.content
            end,
        },
        setters = {
            font = checkedSetter("font", isInteger, "an integer"),
            content = checkedSetter("content", function(v)
                return type(v) == "string"
            end, "a string"),
        },
        methods = { AlignTo = alignTo },
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
        scrollY = 0, -- how far its children are scrolled up (see drawnPos)
        content = kind == "Text" and "" or nil,
        hooks = {}, -- ui.Hook value -> listeners, in subscription order
        mouseOver = false,
        frontCalls = 0, -- MoveToFront calls, effective or not, for specs that count raises
        objectID = kind == "Sprite" and -1 or nil,
    }
    if parent then parent.children[#parent.children + 1] = s end
    local proxy = assert(CLASSES[kind], kind).new(s)
    s.proxy = proxy
    statesByProxy[proxy] = s
    return proxy, s
end

-- The id of a built-in sound, for the PrettyUI fake's default popup sound.
---@param name string
---@return integer
function M.soundId(name)
    return assert(catalog.config("Sound", name), "unknown sound " .. name)
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

-- ui.Layer.new, ui.Sprite.new and ui.Text.new: a plugin's own component under a live
-- ui.ComponentCollection (the plugin layer or a Layer, which includes a PrettyUI window's
-- content). The optional categoryID and dynamicID aren't modelled.
---@param kind string "Layer", "Sprite" or "Text"
---@return table class with the static `new`
local function constructor(kind)
    local what = "ui." .. kind .. ".new"
    return strict.class("ui." .. kind, {
        statics = {
            new = function(_, parent, categoryID, dynamicID)
                if categoryID ~= nil or dynamicID ~= nil then
                    strict.fault("unmocked API: " .. what .. " with a categoryID or dynamicID")
                end
                local ps = statesByProxy[parent]
                if not ps then strict.fault(what .. ": parent must be a ui.ComponentCollection") end
                assert(ps, "unreachable")
                if ps.destroyed then strict.fault(what .. ": parent was destroyed") end
                if ps.class == "ui.Sprite" or ps.class == "ui.Text" then
                    strict.fault(what .. ": a " .. ps.class .. " is not a ui.ComponentCollection")
                end
                local proxy, s = M.create(kind, ps)
                s.raw = true -- the plugin's own, for the h.ui driver's pointer actions
                return proxy
            end,
        },
    })
end

-- A read-only enum table of opaque numbers (ui.Hook, ui.AlignMode); other names fault.
---@param name string
---@param values table
---@return table
local function enumTable(name, values)
    return strict.lookup(function(member)
        strict.fault("unmocked API: " .. name .. "." .. tostring(member))
    end, values)
end

local UiNamespace = strict.class("ui", {
    fields = {
        Interfaces = function(s)
            return s.interfaces
        end,
        Layer = function(s)
            return s.Layer
        end,
        Sprite = function(s)
            return s.Sprite
        end,
        Text = function(s)
            return s.Text
        end,
        Hook = function(s)
            return s.Hook
        end,
        AlignMode = function(s)
            return s.AlignMode
        end,
    },
})
-- The stubs declare these as classes and enums of their own, not as fields of `ui`.
for _, member in ipairs({ "Interfaces", "Layer", "Sprite", "Text", "Hook", "AlignMode" }) do
    strict.declare("ui", member, "namespace")
end

local IdNamespace = strict.class("_global.id", {
    fields = {
        Component = function(s)
            return s.components
        end,
        Sound = function(s)
            return s.sounds
        end,
        Font = function(s)
            return s.fonts
        end,
        Sprite = function(s)
            return s.sprites
        end,
        Obj = function(s)
            return s.objs
        end,
        Cursor = function(s)
            return s.cursors
        end,
    },
})

-- id.<kind>.NAME from docs/api/consts/<kind>.lua (loaded on first use): a plugin can only name
-- one that exists. `label` is the singular for the fault. FromID isn't modelled.
---@param kind string "Sound", "Font", "Sprite", "Obj" or "Cursor"
---@param label string
---@return table
local function idNames(kind, label)
    return strict.lookup(function(name)
        if name == "FromID" then strict.fault("unmocked API: id." .. kind .. ".FromID") end
        local found = catalog.config(kind, name)
        if not found then
            strict.fault("unknown " .. label .. ": id." .. kind .. "." .. tostring(name))
        end
        return found
    end)
end

---@param h table the harness
---@param env table the sandbox being built
function M.install(h, env)
    -- One root per load, the same object on every call (the client may hand out a fresh
    -- userdata each time, as Player.GetEntity does).
    local root, rootState = M.create("Component", nil)
    h.instance.uiRoot = rootState
    env.ui = UiNamespace.new({
        interfaces = Interfaces.new({ root = root }),
        Layer = constructor("Layer").new({}),
        Sprite = constructor("Sprite").new({}),
        Text = constructor("Text").new({}),
        Hook = enumTable("ui.Hook", M.Hook),
        AlignMode = enumTable("ui.AlignMode", M.AlignMode),
    })
    env.id = IdNamespace.new({
        components = strict.lookup(function(name)
            strict.fault("unmocked API: id.Component." .. tostring(name))
        end, { [M.PLUGIN_LAYER_NAME] = M.PLUGIN_LAYER_ID }),
        sounds = idNames("Sound", "sound"), -- the mock plays nothing
        fonts = idNames("Font", "font"),
        sprites = idNames("Sprite", "sprite"),
        objs = idNames("Obj", "object"), -- for SetAssociatedObject
        cursors = idNames("Cursor", "cursor"), -- for the cursor configs
    })
end

return M
