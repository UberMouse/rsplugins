-- Player: IsAvailable, GetEntity (displayName only) and the level / XP getters, read from
-- h.world.state.player.
--
-- What the client does when a getter runs while logged out is undocumented; IsAvailable is
-- documented as "whether Player data is available to access", so every other getter faults
-- while logged out, which makes a plugin that skips the check fail its test.

local recording = require("dev/recording")

local strict = require("tests.harness.strict")
local stubs = require("tests.harness.stubs")

local M = {}

-- The recorder's path for the player's name read; a replay also logs in from it.
M.DISPLAY_NAME_PATH = recording.memberPath(
    recording.callPath("Player", false, "GetEntity", { n = 0 }, 1),
    "displayName"
)

M.SkillType = stubs.value("game/player.lua", "SkillType")
local SKILLS = {}
for _, v in pairs(M.SkillType) do
    SKILLS[v] = true
end

-- Only displayName is modelled; other PlayerEntity members fault as unmocked. A replayed login
-- may not know the name yet (h:recorded).
local PlayerEntity = strict.class("PlayerEntity", {
    fields = {
        displayName = function(s)
            if s.displayName ~= nil then return s.displayName end
            return s.h:recorded(
                M.DISPLAY_NAME_PATH,
                "unmocked state: the player's displayName (h.world:login)"
            )
        end,
    },
})

---@param s table namespace state
---@param fn string the getter, for the message
---@return table player state
local function loggedIn(s, fn)
    local p = s.h.world.state.player
    if not p.loggedIn then
        strict.fault("Player." .. fn .. " called while logged out (check Player.IsAvailable())")
    end
    return p
end

-- A getter that reads one value of a skill.
---@param fn string
---@param key string the skills entry field
---@return function
local function skillGetter(fn, key)
    return function(s, skill)
        local p = loggedIn(s, fn)
        if not SKILLS[skill] then strict.fault("Player." .. fn .. ": not a SkillType value") end
        local levels = p.skills[skill]
        if not levels then
            return s.h:recorded(
                recording.callPath("Player", false, fn, table.pack(skill), 1),
                "unmocked state: skill " .. tostring(skill) .. " was never set (h.world:setSkill)"
            )
        end
        return levels[key]
    end
end

local Player = strict.class("Player", {
    statics = {
        IsAvailable = function(s)
            return s.h.world.state.player.loggedIn
        end,
        -- One entity per login, so the same object comes back until the next login.
        GetEntity = function(s)
            local p = loggedIn(s, "GetEntity")
            if s.entityLogin ~= p.login then
                s.entityLogin = p.login
                s.entity = PlayerEntity.new({ h = s.h, displayName = p.displayName })
            end
            return s.entity
        end,
        GetLevelGameplay = skillGetter("GetLevelGameplay", "gameplay"),
        GetLevelCapped = skillGetter("GetLevelCapped", "capped"),
        GetLevelUncapped = skillGetter("GetLevelUncapped", "uncapped"),
        GetXPCapped = skillGetter("GetXPCapped", "xpCapped"),
        GetXPUncapped = skillGetter("GetXPUncapped", "xp"),
    },
})

---@param h table the harness
---@param env table the sandbox being built
function M.install(h, env)
    env.Player = Player.new({ h = h })
    env.SkillType = strict.enum("SkillType", M.SkillType)
end

return M
