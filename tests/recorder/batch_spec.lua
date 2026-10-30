-- The dev tools' shared batch transport (lib/dev/batch.lua): session ids, the entry buffer, the
-- batch body, JSON splicing and byte capping.

local dkjson = require("dkjson")
local batch = require("dev/batch")

describe("batch.newSession", function()
    it("is 4 to 10 hex digits, a valid daemon session id", function()
        for _ = 1, 50 do
            local id = batch.newSession()
            assert.is_not_nil(id:match("^%x+$"))
            assert.is_true(#id >= 4 and #id <= 10)
            assert.is_not_nil(id:match("^[A-Za-z0-9][A-Za-z0-9._-]*$"))
        end
    end)
end)

describe("the entry buffer", function()
    it("drops the oldest entries past its byte limit, keeping the newest", function()
        local buffer = batch.newBuffer()
        assert.are.equal(0, batch.push(buffer, "aaaaaaaaaa", 25))
        assert.are.equal(0, batch.push(buffer, "bbbbbbbbbb", 25))
        assert.are.equal(1, batch.push(buffer, "cccccccccc", 25))
        assert.are.equal(2, batch.count(buffer))
        -- Bigger than the limit on its own: everything older goes, and it stays.
        assert.are.equal(2, batch.push(buffer, string.rep("d", 40), 25))
        assert.are.same({ string.rep("d", 40) }, batch.take(buffer, 100))
    end)

    it("takes the oldest entries up to a byte limit, at least one", function()
        local buffer = batch.newBuffer()
        for _, entry in ipairs({ "1111", "2222", "3333" }) do
            batch.push(buffer, entry, 1000)
        end
        assert.are.same({ "1111", "2222" }, batch.take(buffer, 9))
        assert.are.same({ "3333" }, batch.take(buffer, 1))
        assert.are.same({}, batch.take(buffer, 100))
        assert.are.equal(0, batch.count(buffer))
    end)
end)

describe("the entry buffer with a line cap", function()
    it("keeps the newest entries within the line and byte caps and counts the drops", function()
        local q = batch.newBuffer()
        assert.are.equal(0, batch.push(q, "aa", 100, 3))
        batch.push(q, "bb", 100, 3)
        batch.push(q, "cc", 100, 3)
        assert.are.equal(1, batch.push(q, "dd", 100, 3))
        assert.are.equal(3, batch.count(q))
        assert.are.equal(2, batch.push(q, "eeeeee", 8, 10)) -- bb and cc go: dd + eeeeee is 8 bytes
        assert.are.equal(2, batch.push(q, "ffffffffff", 4, 10))
        assert.are.same({ "ffffffffff" }, batch.take(q, 100, 10)) -- the newest is always kept
    end)

    it("takes batches within the line and byte limits, and at least one", function()
        local q = batch.newBuffer()
        for _, s in ipairs({ "a", "b", "c", "dddd" }) do
            batch.push(q, s, 100, 10)
        end
        assert.are.same({ "a", "b" }, batch.take(q, 100, 2))
        assert.are.same({ "c" }, batch.take(q, 3, 10)) -- "dddd" would pass 3 bytes
        assert.are.same({ "dddd" }, batch.take(q, 1, 10)) -- one however big
        assert.are.same({}, batch.take(q, 1, 10))
    end)

    it("puts a failed batch back in front, still subject to the caps", function()
        local q = batch.newBuffer()
        batch.push(q, "a", 100, 10)
        batch.push(q, "b", 100, 10)
        local sent = batch.take(q, 100, 10)
        batch.push(q, "c", 100, 10)
        assert.are.equal(0, batch.requeue(q, sent, 100, 10))
        assert.are.same({ "a", "b", "c" }, batch.take(q, 100, 10))
        batch.push(q, "c", 100, 2)
        assert.are.equal(1, batch.requeue(q, { "a", "b" }, 100, 2)) -- a is the oldest
        assert.are.same({ "b", "c" }, batch.take(q, 100, 10))
    end)

    it("requeues into an empty buffer, and requeues nothing", function()
        local q = batch.newBuffer()
        batch.push(q, "a", 100)
        local sent = batch.take(q, 100)
        assert.are.equal(0, batch.requeue(q, {}, 100, 10))
        batch.requeue(q, sent, 100, 10)
        assert.are.equal(1, batch.count(q))
        assert.are.equal(1, q.bytes)
        assert.are.same({ "a" }, batch.take(q, 100))
    end)

    it("ignores lines when no cap is given", function()
        local q = batch.newBuffer()
        for _ = 1, 50 do
            assert.are.equal(0, batch.push(q, "x", 1000))
        end
        assert.are.equal(50, batch.count(q))
        assert.are.equal(50, #batch.take(q, 1000))
    end)
end)

describe("batch.text", function()
    it("never raises on a value whose tostring fails", function()
        local bad = setmetatable({}, {
            __tostring = function()
                error("no")
            end,
        })
        assert.are.equal("<a table that tostring() fails on>", batch.text(bad))
    end)
end)

describe("batch.joined", function()
    it("joins arguments like the console: tostring'd, space separated", function()
        assert.are.equal("a 1 nil true", batch.joined("a", 1, nil, true))
        assert.are.equal("", batch.joined())
    end)

    it("names an argument whose tostring raises", function()
        local bad = setmetatable({}, {
            __tostring = function()
                error("no text")
            end,
        })
        assert.are.equal("x <a table that tostring() fails on>", batch.joined("x", bad))
    end)
end)

describe("batch.batchBody", function()
    it("splices encoded entries into the batch", function()
        local body = batch.batchBody(
            { schema = 1, seq = 1 },
            { '{"k":"read","t":0}', '{"k":"event","t":1}' }
        )
        assert.are.same({
            schema = 1,
            seq = 1,
            entries = { { k = "read", t = 0 }, { k = "event", t = 1 } },
        }, dkjson.decode(body))
    end)
end)

describe("batch.withField", function()
    it("splices an encoded value into a non-empty object", function()
        assert.are.equal('{"a":1,"b":[2]}', batch.withField('{"a":1}', "b", "[2]"))
    end)

    it("splices into an empty object without a stray comma", function()
        assert.are.equal('{"b":2}', batch.withField("{}", "b", "2"))
    end)
end)

describe("batch.cap", function()
    it("leaves text under or at the limit alone", function()
        assert.are.same({ "abc", false }, { batch.cap("abc", 5) })
        assert.are.same({ "abcde", false }, { batch.cap("abcde", 5) })
    end)

    it("cuts text over the limit and appends the byte count", function()
        assert.are.same({ "abcde<+3 bytes>", true }, { batch.cap("abcdefgh", 5) })
    end)
end)

describe("batch.failureText", function()
    it("says timed out for a timeout, whatever else the request holds", function()
        assert.are.equal(
            "timed out",
            batch.failureText({ timedOut = true, responseCode = 0, errorCode = 28 } --[[@as table]])
        )
    end)

    it("gives the response code, error code and error text otherwise", function()
        assert.are.equal(
            "response 500, error 0 nil",
            batch.failureText({ timedOut = false, responseCode = 500, errorCode = 0 } --[[@as table]])
        )
    end)
end)

describe("batch.permissionHint", function()
    it("names the ppr and ppe steps for the plugin", function()
        assert.are.equal("(`ppr p`, then `ppe p httpAccess`)", batch.permissionHint("p"))
    end)

    it("adds one more step when given", function()
        assert.are.equal(
            "(`ppr p`, then `ppe p httpAccess`, then `prl p`)",
            batch.permissionHint("p", "`prl p`")
        )
    end)
end)
