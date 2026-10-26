-- Self-tests: Player availability, entity and skill getters.

local harness = require("tests.harness")
local SkillType = harness.enums.SkillType

local function plugin(main)
    return { ["main.lua"] = main }
end

describe("Player", function()
    it("is unavailable until login, then serves the display name", function()
        local h = harness.load(plugin([[
            function check()
                available = Player.IsAvailable()
                name = available and Player.GetEntity().displayName
            end
            check()
        ]]))
        assert.is_false(h.env.available)
        h.world:login("Zezima")
        h.env.check()
        assert.is_true(h.env.available)
        assert.are.equal("Zezima", h.env.name)
    end)

    it("serves the player's tile as a CoordGrid, read fresh each time", function()
        local h = harness.new(plugin([[
            function tile()
                local c = Player.GetEntity().coordGrid
                return { c.level, c.x, c.z, c.mapSquareX, c.mapSquareZ, c.localX, c.localZ }
            end
        ]]))
        h.world:login("Zezima")
        h:load()
        -- Dell Monti's tile: !tele 0,43,49,11,50.
        h.world:setPosition(2763, 3186)
        assert.are.same({ 0, 2763, 3186, 43, 49, 11, 50 }, h.env.tile())
        h.world:setPosition(2763, 3186, 1)
        assert.are.equal(1, h.env.tile()[1])
    end)

    it("faults on the player's tile until a test sets one", function()
        local h = harness.new(plugin("function tile() return Player.GetEntity().coordGrid end"))
        h.world:login("Zezima")
        h:load()
        assert.matches(
            "unmocked state: the player's position",
            harness.errorOf(function()
                h.env.tile()
            end)
        )
        assert.matches(
            "setPosition needs integer",
            harness.errorOf(function()
                h.world:setPosition(12800, 0)
            end)
        )
    end)

    it("faults when a getter runs while logged out", function()
        assert.matches(
            "Player.GetEntity called while logged out",
            harness.errorOf(function()
                harness.load(plugin("Player.GetEntity()"))
            end)
        )
    end)

    it("hands out a new entity per call, `==` to the others of one login", function()
        local h = harness.new(plugin([[
            function entity() return Player.GetEntity() end
        ]]))
        h.world:login("Zezima")
        h:load()
        local first = h.env.entity()
        assert.are.equal(first, h.env.entity())
        assert.is_false(rawequal(first, h.env.entity())) -- so not one table key, as live
        h.world:logout()
        h.world:login("Zezima")
        assert.are_not.equal(first, h.env.entity())
    end)

    it("compares CoordGrids by tile and prints them as the client does", function()
        local h = harness.new(plugin([[
            local a, b = Player.GetEntity().coordGrid, Player.GetEntity().coordGrid
            same, raw, text = a == b, rawequal(a, b), tostring(a)
        ]]))
        h.world:login("Zezima")
        h.world:setPosition(3225, 3223)
        h:load()
        assert.are.same({ true, false, "0,50,50,25,23" }, { h.env.same, h.env.raw, h.env.text })
    end)

    it("serves levels and XP, defaulting boosted and capped to the base values", function()
        local h = harness.new(plugin([[
            levels = {
                Player.GetLevelGameplay(SkillType.ATTACK), Player.GetLevelCapped(SkillType.ATTACK),
                Player.GetLevelUncapped(SkillType.ATTACK), Player.GetXPCapped(SkillType.ATTACK),
                Player.GetXPUncapped(SkillType.ATTACK), Player.GetLevelGameplay(SkillType.MINING),
            }
        ]]))
        h.world:login("Zezima")
        h.world:setSkill(SkillType.ATTACK, { level = 99, xp = 13034431, gameplay = 112 })
        h.world:setSkill(SkillType.MINING, { level = 50, xp = 101333 })
        h:load()
        assert.are.same({ 112, 99, 99, 13034431, 13034431, 50 }, h.env.levels)
    end)

    it("faults on a skill the test never set", function()
        local h = harness.new(plugin("local l = Player.GetLevelGameplay(SkillType.SLAYER)"))
        h.world:login("Zezima")
        assert.matches(
            "skill 18 was never set",
            harness.errorOf(function()
                h:load()
            end)
        )
    end)

    it("leaves other PlayerEntity members unmocked", function()
        local h = harness.new(plugin("local c = Player.GetEntity().route"))
        h.world:login("Zezima")
        assert.matches(
            "unmocked API: PlayerEntity.route",
            harness.errorOf(function()
                h:load()
            end)
        )
    end)
end)
