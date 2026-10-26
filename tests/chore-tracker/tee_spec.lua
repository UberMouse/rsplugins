-- Chore Tracker's opt-in to the dev log tee (lib/dev/tee.lua). The dev/ link, the two
-- lines in main.lua and the shutdown line are stripped before submission, so this spec goes
-- with them.

local dkjson = require("dkjson")
local helpers = require("tests.chore-tracker.helpers")

describe("chore tracker with the dev log tee", function()
    it("forwards its console lines once httpAccess is granted", function()
        local h = helpers.loaded({ grant = { "httpAccess" } })
        h:step()
        local posts = {}
        for _, record in ipairs(h.requests) do
            if record.url == "http://127.0.0.1:8766/tee" then posts[#posts + 1] = record end
        end
        assert.are.equal(1, #posts)
        local batch = assert(dkjson.decode(posts[1].body))
        assert.are.equal("chore-tracker", batch.plugin)
        local found = false
        for _, line in ipairs(batch.lines) do
            found = found or (line.level == "log" and line.text:find("[CHORES]", 1, true) ~= nil)
        end
        assert.is_true(found)
    end)

    it("leaves no subscription behind when it shuts down", function()
        local h = helpers.loaded({ grant = { "httpAccess" } })
        h:step()
        h:unload()
        for event, list in pairs(h.instance.subs) do
            local names = {}
            for i, entry in ipairs(list) do
                names[i] = entry.name
            end
            assert.are.same({}, names, "still subscribed to " .. event)
        end
    end)

    it("does nothing without httpAccess: one [TEE] line, no requests", function()
        local h = helpers.loaded()
        h:advance(2000)
        assert.are.equal(0, #h.requests)
        assert.is_not_nil(h:output():find("[TEE] httpAccess not granted", 1, true))
    end)
end)
