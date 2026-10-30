-- plugins/var-dump's own JSON encoder: which tables become arrays.

local dkjson = require("dkjson")
local json = dofile("plugins/var-dump/json.lua")

describe("var-dump json.encode", function()
    it("writes a table keyed 1..n as an array", function()
        assert.are.equal('["a","b","c"]', json.encode({ "a", "b", "c" }))
        assert.are.equal("[]", json.encode({}))
    end)

    it("writes a gapped table as an object, keeping every entry", function()
        -- Built by assignment so `#t` is 4, the same as the key count: a length check alone
        -- would call it an array.
        local t = {}
        for _, i in ipairs({ 1, 2, 4, 6 }) do
            t[i] = ({ "a", "b", "c", "d", "e", "f" })[i]
        end
        assert.are.equal(4, #t)
        assert.are.same(
            { ["1"] = "a", ["2"] = "b", ["4"] = "d", ["6"] = "f" },
            dkjson.decode(json.encode(t))
        )
    end)

    it("escapes control characters as JSON, \\u-escaped when they have no short form", function()
        assert.are.equal('"a\\u0001b\\n"', json.encode("a\1b\n"))
        -- A raw NUL would make the line invalid JSON. DEL is valid raw JSON, but %c matches it, so it is
        -- escaped too.
        local s = "x\0y\127z"
        assert.are.equal('"x\\u0000y\\u007fz"', json.encode(s))
        assert.are.equal(s, dkjson.decode(json.encode(s)))
    end)
end)
