-- core/settings: the celebration settings as stored.

require("tests.chore-tracker.support")
local settings = require("core/settings")

describe("chore-tracker core settings", function()
    it("defaults to popups and sound on", function()
        assert.are.same({ popups = true, sound = true }, settings.default())
    end)

    it("round-trips through serialise and fromStored", function()
        for _, s in ipairs({
            { popups = false, sound = true },
            { popups = true, sound = false },
            { popups = false, sound = false },
        }) do
            assert.are.same(s, settings.fromStored(settings.serialise(s)))
        end
    end)

    it("gives the defaults for a missing or malformed value", function()
        local default = settings.default()
        for _, bad in ipairs({ "x", 5, true, {}, { version = 2, popups = false } }) do
            assert.are.same(default, settings.fromStored(bad))
        end
        assert.are.same(default, settings.fromStored(nil))
    end)

    it("keeps a good field beside a bad one", function()
        local out = settings.fromStored({ version = 1, popups = false, sound = "loud" })
        assert.are.same({ popups = false, sound = true }, out)
    end)
end)
