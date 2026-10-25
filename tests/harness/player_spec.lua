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

    it("faults when a getter runs while logged out", function()
        assert.matches(
            "Player.GetEntity called while logged out",
            harness.errorOf(function()
                harness.load(plugin("Player.GetEntity()"))
            end)
        )
    end)

    it("returns the same entity until the next login", function()
        local h = harness.new(plugin([[
            function entity() return Player.GetEntity() end
        ]]))
        h.world:login("Zezima")
        h:load()
        local first = h.env.entity()
        assert.are.equal(first, h.env.entity())
        h.world:logout()
        h.world:login("Zezima")
        assert.are_not.equal(first, h.env.entity())
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
        local h = harness.new(plugin("local c = Player.GetEntity().coordGrid"))
        h.world:login("Zezima")
        assert.matches(
            "unmocked API: PlayerEntity.coordGrid",
            harness.errorOf(function()
                h:load()
            end)
        )
    end)
end)
