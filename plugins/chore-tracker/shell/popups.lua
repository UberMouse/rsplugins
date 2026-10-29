-- Shows the celebrations core/celebrate.lua decides on, one at a time, as PrettyUI
-- AchievementPopups in the plugin layer. A popup lasts about four seconds and calls
-- `onComplete` as it ends, which starts the next one in the queue.

local M = {}

-- Size in pixels and built-in sound (id.Sound, docs/api/consts/Sound.lua) per kind of popup:
-- PrettyUI's default size for a chore, bigger and a grander sound for a cleared period.
local STYLES = {
    chore = { width = 300, height = 92, sound = id.Sound.ARCH_INFO_POPUP },
    period = { width = 400, height = 120, sound = id.Sound.LEAGUE2_HARD_TASK_COMPLETE },
}

-- The popup's centre sits this far down the plugin layer.
local Y_ANCHOR = 1 / 3

local parent = nil ---@type ui.Component?
local say = nil ---@type fun(...)?
local sound = true
local enabled = true
local queue = {} ---@type ChoreCelebration[]
local showing = nil ---@type prettyui.AchievementPopup? the popup on screen

-- Where the popups go and where their log lines go. Call once, before anything else.
---@param opts { parent: ui.Component, say: fun(...) }
function M.init(opts)
    parent, say = opts.parent, opts.say
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
                showNext()
            end
        end,
    })
end

-- Start the queue's first popup that PrettyUI can show; one it can't is dropped.
showNext = function()
    assert(say, "popups.init sets say first")
    while showing == nil and #queue > 0 do
        local c = table.remove(queue, 1)
        showing = show(c)
        if showing then say("celebrate", c.label) end
    end
end

-- Queue celebrations (none when popups are off) and start one if none is showing.
---@param celebrations ChoreCelebration[]
function M.enqueue(celebrations)
    if not enabled then return end
    for _, c in ipairs(celebrations) do
        queue[#queue + 1] = c
    end
    showNext()
end

-- Drop the queue and the popup on screen.
function M.clear()
    queue = {}
    if showing then
        local popup = showing
        showing = nil
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
