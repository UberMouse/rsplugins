-- The PrettyUI fake's AchievementPopup: the Logic countdown that fades and ends it. Separate
-- from the windows because it shares only libraryObject with them. Part of the library.

local events = require("tests.harness.api.events")
local ui = require("tests.harness.api.ui")
local internal = require("tests.harness.api.prettyui.internal")
require("tests.harness.api.prettyui.objects")

local checkOptions = internal.checkOptions
local parentState = internal.parentState
local track = internal.track
local libraryObject = internal.libraryObject

-- AchievementPopup (src/achievement_popup.lua): a frame of PrettyUI's own sprites with a title
-- and a text, fading in over 15 ticks and out over the last 25, and ending itself on the 201st
-- Logic tick after it was made (elapsed ticks > 200: 15 in, 160 held, 25 out): it destroys
-- itself, then calls onComplete(popup). It subscribes its own Logic callback, named
-- prettyui_achievement_popup_<n>. The sound is not played; `played` records the id it would
-- (soundID, else ARCH_INFO_POPUP; none for sound = false).
local POPUP_DEFAULTS = { width = 300, height = 92, y = 20 }
local POPUP_TICKS = 200
local POPUP_MIN = 9
local DEFAULT_POPUP_SOUND = "ARCH_INFO_POPUP"

local AchievementPopup = libraryObject("prettyui.AchievementPopup instance", {}, function(s)
    events.unsubscribe(s.lib.h.instance, "Logic", s.eventName)
    s.onComplete = nil
end)

-- Make a popup in `parent` and start its Logic countdown.
---@param lib table
---@param parent any
---@param options any
---@return table popup
local function newPopup(lib, parent, options)
    local ps = parentState("AchievementPopup", parent)
    options = checkOptions("AchievementPopup", options)
    lib.popupCount = lib.popupCount + 1
    local width = math.max(POPUP_MIN, options.width or POPUP_DEFAULTS.width)
    local height = math.max(POPUP_MIN, options.height or POPUP_DEFAULTS.height)
    local s = {
        kind = "AchievementPopup",
        lib = lib,
        parent = parent,
        title = tostring(options.title or "ACHIEVEMENT COMPLETE"),
        text = tostring(options.text or ""),
        width = width,
        height = height,
        sound = options.sound,
        soundID = options.soundID,
        onComplete = options.onComplete,
        eventName = "prettyui_achievement_popup_" .. lib.popupCount,
        elapsed = 0,
        completed = false,
        destroyed = false,
    }
    if options.sound ~= false then s.played = options.soundID or ui.soundId(DEFAULT_POPUP_SOUND) end
    s.root, s.rootState = ui.create("Layer", ps)
    s.root:SetPos(
        options.x or -math.floor(width / 2),
        options.y or POPUP_DEFAULTS.y,
        options.xAnchor == nil and 0.5 or options.xAnchor,
        options.yAnchor or 0
    )
    s.root:SetSize(width, height)
    local obj = AchievementPopup.new(s)
    s.proxy = obj
    track(lib, "AchievementPopup", obj, s)
    events.subscribe(lib.h.instance, "Logic", s.eventName, function()
        if s.destroyed then return end
        s.elapsed = s.elapsed + 1
        if s.elapsed > POPUP_TICKS then
            local onComplete = s.onComplete
            s.proxy:Destroy()
            s.completed = true
            if onComplete then onComplete(s.proxy) end
        end
    end)
    return obj
end

internal.newPopup = newPopup
