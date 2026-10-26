-- The tee's pure core (lib/dev/teelog.lua): line shaping, the bounded queue, retry backoff.

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

    it("joins arguments like the console: tostring'd, space separated", function()
        assert.are.equal("a 1 nil true", t.joined("a", 1, nil, true))
        assert.are.equal("", t.joined())
    end)

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

    it("keeps the newest lines within the line and byte caps and counts the drops", function()
        local q = t.newQueue()
        assert.are.equal(0, t.push(q, "aa", 3, 100))
        t.push(q, "bb", 3, 100)
        t.push(q, "cc", 3, 100)
        assert.are.equal(1, t.push(q, "dd", 3, 100))
        assert.are.equal(3, t.count(q))
        assert.are.equal(2, t.push(q, "eeeeee", 10, 8)) -- bb and cc go: dd + eeeeee is 8 bytes
        assert.are.equal(2, t.push(q, "ffffffffff", 10, 4))
        assert.are.same({ "ffffffffff" }, t.take(q, 10, 100)) -- the newest is always kept
    end)

    it("takes batches within the line and byte limits, and at least one", function()
        local q = t.newQueue()
        for _, s in ipairs({ "a", "b", "c", "dddd" }) do
            t.push(q, s, 10, 100)
        end
        assert.are.same({ "a", "b" }, t.take(q, 2, 100))
        assert.are.same({ "c" }, t.take(q, 10, 3)) -- "dddd" would pass 3 bytes
        assert.are.same({ "dddd" }, t.take(q, 10, 1)) -- one however big
        assert.are.same({}, t.take(q, 10, 1))
    end)

    it("puts a failed batch back in front, still subject to the cap", function()
        local q = t.newQueue()
        t.push(q, "a", 10, 100)
        t.push(q, "b", 10, 100)
        local batch = t.take(q, 10, 100)
        t.push(q, "c", 10, 100)
        assert.are.equal(0, t.requeue(q, batch, 10, 100))
        assert.are.same({ "a", "b", "c" }, t.take(q, 10, 100))
        t.push(q, "c", 2, 100)
        assert.are.equal(1, t.requeue(q, { "a", "b" }, 2, 100)) -- a is the oldest
        assert.are.same({ "b", "c" }, t.take(q, 10, 100))
    end)

    it("requeues into an empty queue", function()
        local q = t.newQueue()
        t.push(q, "a", 10, 100)
        local batch = t.take(q, 10, 100)
        t.requeue(q, batch, 10, 100)
        assert.are.equal(1, t.count(q))
        assert.are.same({ "a" }, t.take(q, 10, 100))
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
