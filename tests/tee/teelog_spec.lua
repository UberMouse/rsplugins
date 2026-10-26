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

    it("cuts long text with a marker, without splitting a character", function()
        assert.are.equal("short", t.cut("short", 10))
        assert.are.equal("abcde...[cut]", t.cut("abcdefgh", 5))
        -- The cut lands inside the first e-acute (2 bytes), a euro sign (3) or a G clef (4).
        assert.are.equal("ab...[cut]", t.cut("ab\195\169\195\169", 3))
        assert.are.equal("ab...[cut]", t.cut("ab\226\130\172", 4))
        assert.are.equal("ab...[cut]", t.cut("ab\240\157\132\158", 5))
        assert.are.equal("ab\240\157\132\158...[cut]", t.cut("ab\240\157\132\158cd", 6))
    end)

    it("keeps valid multibyte text as it is", function()
        local text = "a\195\169\226\130\172\240\157\132\158z"
        assert.are.equal(text, t.cut(text, 100))
    end)

    it("replaces bytes that aren't UTF-8", function()
        assert.are.equal("a?b", t.cut("a\255b", 10))
        assert.are.equal("????", t.cut("\255\255\255\255", 10))
        assert.are.equal("a?", t.cut("a\195", 10)) -- a lone lead byte at the end
        assert.are.equal("?a", t.cut("\169a", 10)) -- a stray continuation byte
        assert.are.equal("??", t.cut("\192\128", 10)) -- overlong NUL
        assert.are.equal("???", t.cut("\224\128\128", 10)) -- overlong 3-byte form
        assert.are.equal("???", t.cut("\237\160\128", 10)) -- surrogate D800
        assert.are.equal("????", t.cut("\244\144\128\128", 10)) -- U+110000
        assert.are.equal("\244\143\191\191", t.cut("\244\143\191\191", 10)) -- U+10FFFF
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
