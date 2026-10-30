-- The tee's pure core (lib/dev/teelog.lua): line shaping, batch body, retry backoff.

local harness = require("tests.harness")
local support = require("tests.tee.support")

-- The module runs under the plugin's environment in the client, and needs only plain Lua, so
-- load it through a harness plugin's require.
local function teelog()
    local h = harness.new(support.plugin("return nil"))
    h:load()
    return h.env.require("dev/teelog")
end

describe("dev tee core", function()
    local t = teelog()

    it("cuts long text at a byte cap and leaves the rest as it was", function()
        assert.are.equal("short", t.cut("short", 10))
        assert.are.equal("abcde", t.cut("abcde", 5))
        assert.are.equal("abcde...[cut]", t.cut("abcdefgh", 5))
        -- A byte cut may split a multibyte character: the daemon decodes with replacement.
        assert.are.equal("ab\195...[cut]", t.cut("ab\195\169", 3))
        assert.are.equal("a\255b", t.cut("a\255b", 10))
    end)

    it("doubles the wait with each failure, up to the maximum", function()
        assert.are.same({ 10, 20, 40, 50, 50 }, {
            t.backoff(1, 10, 50),
            t.backoff(2, 10, 50),
            t.backoff(3, 10, 50),
            t.backoff(4, 10, 50),
            t.backoff(9, 10, 50),
        })
    end)
end)
