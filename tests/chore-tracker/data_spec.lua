-- The generated chore list (plugins/chore-tracker/data/chores.lua, from
-- scripts/chores-from-dailyscape.py): what the core and the window rely on.

require("tests.chore-tracker.support")
local chores = require("data/chores")

describe("chore-tracker data", function()
    it("has dailyscape's 67 chores", function()
        assert.are.equal(67, #chores)
    end)

    it("splits them into dailyscape's periods and shop tables", function()
        local counts = { daily = 0, weekly = 0, monthly = 0 }
        local shops = { daily = 0, weekly = 0, monthly = 0 }
        for _, c in ipairs(chores) do
            counts[c.period] = counts[c.period] + 1
            if c.shop then shops[c.period] = shops[c.period] + 1 end
        end
        assert.are.same({ daily = 20, weekly = 42, monthly = 5 }, counts)
        assert.are.same({ daily = 3, weekly = 17, monthly = 0 }, shops)
    end)

    it("keeps dailyscape's order: daily, daily shops, weekly, weekly shops, monthly", function()
        local order = {}
        for _, c in ipairs(chores) do
            local group = c.period .. (c.shop and " shop" or "")
            if order[#order] ~= group then order[#order + 1] = group end
        end
        assert.are.same({ "daily", "daily shop", "weekly", "weekly shop", "monthly" }, order)
        assert.are.equal("daily-challenge", chores[1].id)
    end)

    it("has unique ids", function()
        local seen = {}
        for _, c in ipairs(chores) do
            assert(seen[c.id] == nil, "duplicate id " .. c.id)
            seen[c.id] = true
        end
    end)

    it("gives every chore every field, with the right type", function()
        for _, c in ipairs(chores) do
            for _, field in ipairs({ "id", "name", "url", "desc" }) do
                assert.are.equal("string", type(c[field]), c.id .. "." .. field)
            end
            assert(c.id ~= "" and c.name ~= "", c.id)
            assert(c.period == "daily" or c.period == "weekly" or c.period == "monthly", c.id)
            assert.are.equal("boolean", type(c.shop), c.id)
            assert.are.equal("table", type(c.links), c.id)
            for _, link in ipairs(c.links) do
                assert.are.equal("string", type(link), c.id)
            end
        end
    end)

    it("links only to https urls", function()
        for _, c in ipairs(chores) do
            assert(c.url:find("^https://"), c.id .. " " .. c.url)
            for _, link in ipairs(c.links) do
                assert(link:find("^https://"), c.id .. " " .. link)
            end
        end
    end)

    it("leaves no markup in desc but <br>", function()
        for _, c in ipairs(chores) do
            local rest = c.desc:gsub("<br>", "")
            assert(not rest:find("<[%a/!]"), c.id .. ": " .. c.desc)
        end
    end)

    it("turns a desc's anchors into text and links", function()
        local ports
        for _, c in ipairs(chores) do
            if c.id == "player-owned-ports" then ports = c end
        end
        assert(ports, "player-owned-ports is one of dailyscape's daily chores")
        assert.are.equal(
            "Manage your player owned port<br>Buy resources from Black Marketeer",
            ports.desc
        )
        assert.are.same({ "https://runescape.wiki/w/The_Black_Marketeer" }, ports.links)
    end)
end)
