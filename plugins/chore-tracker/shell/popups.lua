-- Shows the celebrations core/celebrate.lua decides on, one at a time, as PrettyUI
-- AchievementPopups in the plugin layer. A popup lasts about four seconds and calls
-- `onComplete` as it ends, which starts the next one in the queue. A celebration identical to the
-- popup on screen or to one already waiting is dropped, so ticking, unticking and re-ticking a
-- chore doesn't stack the same popup and jingle; once it has ended the chore shows again.

local say = require("shell/say").say

local M = {}

-- Size in pixels and built-in sound (id.Sound) per kind of popup: PrettyUI's default size for a
-- chore, bigger and a grander sound for a cleared period. The user picked both sounds by ear.
local STYLES = {
    chore = { width = 300, height = 92, sound = id.Sound.CHEEVO_ACHIEVEMENT_COMPLETE_SOUND_V3 },
    period = { width = 400, height = 120, sound = id.Sound.LEAGUE2_MASTER_TASK_COMPLETE },
}

-- The popup's centre sits this far down the plugin layer.
local Y_ANCHOR = 1 / 3

local parent = nil ---@type ui.Component?
local sound = true
local enabled = true
local queue = {} ---@type ChoreCelebration[]
local showing = nil ---@type prettyui.AchievementPopup? the popup on screen
local showingLabel = nil ---@type string? the label of the celebration `showing` shows

-- Where the popups go. Call once, before anything else.
---@param opts { parent: ui.Component }
function M.init(opts)
    parent = opts.parent
end

local showNext

-- Show the popup for `c`, or nil if PrettyUI had nowhere to put it.
---@param c ChoreCelebration
---@return prettyui.AchievementPopup?
local function show(c)
    assert(parent, "popups.init sets the parent first")
    local style = STYLES[c.kind]
    return prettyui.AchievementPopup.show({
        parent = parent,
        title = c.title,
        text = c.text,
        width = style.width,
        height = style.height,
        x = -(style.width // 2),
        xAnchor = 0.5,
        y = -(style.height // 2),
        yAnchor = Y_ANCHOR,
        sound = sound,
        soundID = style.sound,
        onComplete = function(done)
            -- A popup cleared or replaced meanwhile never calls this (it has been destroyed).
            if showing == done then
                showing = nil
                showingLabel = nil
                showNext()
            end
        end,
    })
end

-- Start the queue's first popup that PrettyUI can show; one it can't is dropped.
showNext = function()
    while showing == nil and #queue > 0 do
        local c = table.remove(queue, 1)
        showing = show(c)
        if showing then
            showingLabel = c.label
            say("celebrate", c.label)
        end
    end
end

-- Whether a celebration with this label is on screen or waiting in the queue.
---@param label string
---@return boolean
local function isPending(label)
    if showingLabel == label then return true end
    for _, c in ipairs(queue) do
        if c.label == label then return true end
    end
    return false
end

-- Queue celebrations (none when popups are off) and start one if none is showing. One whose
-- label is already showing or queued is dropped.
---@param celebrations ChoreCelebration[]
function M.enqueue(celebrations)
    if not enabled then return end
    for _, c in ipairs(celebrations) do
        if not isPending(c.label) then queue[#queue + 1] = c end
    end
    showNext()
end

-- Drop the queue and the popup on screen.
function M.clear()
    queue = {}
    if showing then
        local popup = showing
        showing, showingLabel = nil, nil
        popup:Destroy()
    end
end

-- Apply the settings. Turning popups off clears what is queued and showing.
---@param settings ChoreSettings
function M.configure(settings)
    enabled, sound = settings.popups, settings.sound
    if not enabled then M.clear() end
end

return M
