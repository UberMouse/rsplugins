-- Player: IsAvailable, GetEntity (displayName and coordGrid) and the level / XP getters, read
-- from h.world.state.player.
--
-- What the client does when a getter runs while logged out is undocumented; IsAvailable is
-- documented as "whether Player data is available to access", so every other getter faults
-- while logged out, which makes a plugin that skips the check fail its test.

local recording = require("dev/recording")

local strict = require("tests.harness.strict")
local stubs = require("tests.harness.stubs")
local world = require("tests.harness.world")

local M = {}

-- The recorder's path for the player's name read; a replay also logs in from it.
M.DISPLAY_NAME_PATH = recording.memberPath(
    recording.callPath("Player", false, "GetEntity", { n = 0 }, 1),
    "displayName"
)

M.SkillType = stubs.value("game/player.lua", "SkillType")

-- A CoordGrid of world tile (x, z) on `level`, per game/coordgrid.html#properties: map
-- squares are 64 tiles, so mapSquareX = x // 64 and localX = x % 64. Live, two reads of the
-- same tile gave two userdata that compare `==`, and tostring gave
-- "level,mapSquareX,mapSquareZ,localX,localZ" (docs/api-concepts.md).
local CoordGrid = strict.class("CoordGrid", {
    eq = function(a, b)
        return a.x == b.x and a.z == b.z and a.level == b.level
    end,
    tostring = function(s)
        return string.format("%d,%d,%d,%d,%d", s.level, s.x // 64, s.z // 64, s.x % 64, s.z % 64)
    end,
    fields = {
        level = "level",
        x = "x",
        z = "z",
        mapSquareX = function(s)
            return s.x // 64
        end,
        mapSquareZ = function(s)
            return s.z // 64
        end,
        localX = function(s)
            return s.x % 64
        end,
        localZ = function(s)
            return s.z % 64
        end,
    },
})

-- Only displayName and coordGrid are modelled; other PlayerEntity members fault as
-- unmocked. A replayed login may not know the name yet (h:recorded); a position comes only
-- from h.world:setPosition, never from a recording.
local PlayerEntity = strict.class("PlayerEntity", {
    -- The same player, as long as the login lasts (live, two GetEntity() results are `==`).
    eq = function(a, b)
        return a.login == b.login
    end,
    fields = {
        -- The tile at the time of the read, as a new CoordGrid each time.
        coordGrid = function(s)
            local tile = s.h.world.state.player.tile
            if not tile then
                strict.fault("unmocked state: the player's position (h.world:setPosition)")
            end
            return CoordGrid.new({ x = tile.x, z = tile.z, level = tile.level })
        end,
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
        if not world.isSkill(skill) then
            strict.fault("Player." .. fn .. ": not a SkillType value")
        end
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
        -- A new object per call, as in the client, equal (`==`) to the others of one login.
        GetEntity = function(s)
            local p = loggedIn(s, "GetEntity")
            return PlayerEntity.new({ h = s.h, displayName = p.displayName, login = p.login })
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
