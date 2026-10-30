-- Self-tests: PersistentDB, per core/persistentdb.html.

local harness = require("tests.harness")
local support = require("tests.harness.spec_support")

local plugin = support.inline

describe("PersistentDB", function()
    it("round-trips each type and returns nil for a missing key", function()
        local h = harness.load(plugin([[
            PersistentDB:Set("b", true)
            PersistentDB:Set("i", 4)
            PersistentDB:Set("f", 4.5)
            PersistentDB:Set("s", "George")
            PersistentDB:Set("t", { colour = "orange", speed = 1000 })
            got = { PersistentDB:Get("b"), PersistentDB:Get("i"), PersistentDB:Get("f"), PersistentDB:Get("s") }
            tbl = PersistentDB:Get("t")
            missing = PersistentDB:Get("nope") == nil
        ]]))
        assert.are.same({ true, 4, 4.5, "George" }, h.env.got)
        assert.are.same({ colour = "orange", speed = 1000 }, h.env.tbl)
        assert.is_true(h.env.missing)
    end)

    it("typed getters return nil on a type mismatch; typed setters check the type", function()
        local h = harness.load(plugin([[
            PersistentDB:SetInt("n", 3)
            asInt, asString = PersistentDB:GetInt("n"), PersistentDB:GetString("n")
            badSet = PersistentDB:SetInt("m", "three")
            PersistentDB:SetFloat("x", 2)
            asFloat = PersistentDB:GetFloat("x")
            typed = PersistentDB:CheckExistsTyped("n", PersistentDBType.INT)
            wrongType = PersistentDB:CheckExistsTyped("n", PersistentDBType.STRING)
        ]]))
        assert.are.equal(3, h.env.asInt)
        assert.is_nil(rawget(h.env, "asString"))
        assert.is_nil(rawget(h.env, "badSet"))
        assert.are.equal("float", math.type(h.env.asFloat))
        assert.is_true(h.env.typed)
        assert.is_false(h.env.wrongType)
    end)

    it(
        "counts stores in h.dbWrites: Set and typed setters, not failures, reads or deletes",
        function()
            local h = harness.load(plugin([[
            PersistentDB:Set("a", 1)
            PersistentDB:SetInt("b", 2)
        ]]))
            assert.are.equal(2, h.dbWrites)
            local db = h.env.PersistentDB
            db:SetInt("c", "three") -- wrong type: stores nothing
            assert.are.equal(2, h.dbWrites)
            db:Get("a")
            db:GetInt("b")
            db:CheckExists("a")
            db:Delete("a")
            assert.are.equal(2, h.dbWrites)
            -- The count is the harness's, so it carries across a reload; main.lua runs again and
            -- stores twice more.
            h:reload()
            assert.are.equal(4, h.dbWrites)
        end
    )

    it("stores a copy of a table, dropping fields it can't store", function()
        local h = harness.load(plugin([[
            local t = { keep = 1, fn = print, nested = { ok = "yes" } }
            PersistentDB:Set("t", t)
            t.keep = 2
            stored = PersistentDB:Get("t")
        ]]))
        assert.are.same({ keep = 1, nested = { ok = "yes" } }, h.env.stored)
    end)

    it("iterates until the callback returns true, and deletes and clears", function()
        local h = harness.load(plugin([[
            for _, k in ipairs({ "a", "b", "c" }) do PersistentDB:Set(k, k) end
            seen = {}
            visited = PersistentDB:IterateEntries(function(k)
                seen[#seen + 1] = k
                return k == "b"
            end)
            PersistentDB:Delete("a")
            afterDelete = { PersistentDB:CheckExists("a"), PersistentDB:CheckExists("b") }
            PersistentDB:Clear()
            afterClear = PersistentDB:CheckExists("b")
        ]]))
        assert.are.same({ "a", "b" }, h.env.seen)
        assert.are.equal(2, h.env.visited)
        assert.are.same({ false, true }, h.env.afterDelete)
        assert.is_false(h.env.afterClear)
    end)

    it("survives reload, and the test can read it", function()
        local h =
            harness.load(plugin("PersistentDB:Set('runs', (PersistentDB:Get('runs') or 0) + 1)"))
        h:reload()
        assert.are.equal(2, h.db.runs.value)
    end)
end)
