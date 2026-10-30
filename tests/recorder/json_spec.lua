-- The dev recorder's JSON encoder (lib/dev/json.lua): which tables become arrays.

local dkjson = require("dkjson")
local json = require("dev/json")

describe("json.encode", function()
    it("writes a table keyed 1..n as an array", function()
        assert.are.equal('["a","b","c"]', json.encode({ "a", "b", "c" }))
        assert.are.equal("[]", json.encode({}))
    end)

    it("writes a gapped table as an object, keeping every entry", function()
        -- Built slot by slot, like a GetSlots() table with empty slots. `#slots` is 4 here,
        -- the same as the key count, so a length check alone would call it an array.
        local slots = {}
        for _, i in ipairs({ 1, 2, 4, 6 }) do
            slots[i] = ({ "a", "b", "c", "d", "e", "f" })[i]
        end
        assert.are.equal(4, #slots)
        assert.are.same(
            { ["1"] = "a", ["2"] = "b", ["4"] = "d", ["6"] = "f" },
            dkjson.decode(json.encode(slots))
        )
    end)

    it("writes a table with string and integer keys as an object", function()
        local mixed = { "a" }
        mixed.x = "b"
        assert.are.same({ ["1"] = "a", x = "b" }, dkjson.decode(json.encode(mixed)))
    end)

    it("escapes control characters as JSON, \\u-escaped when they have no short form", function()
        assert.are.equal('"a\\u0001b\\n"', json.encode("a\1b\n"))
        -- A raw NUL would make the line invalid JSON; DEL is escaped too, so the output stays plain ASCII.
        local s = "x\0y\127z"
        assert.are.equal('"x\\u0000y\\u007fz"', json.encode(s))
        assert.are.equal(s, dkjson.decode(json.encode(s)))
    end)
end)
