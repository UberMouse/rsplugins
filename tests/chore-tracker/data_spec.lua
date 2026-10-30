-- The hand-written chore list (plugins/chore-tracker/data/chores.lua): what the core and the
-- window rely on, and the rules its header gives.

require("tests.chore-tracker.support")
local chores = require("data/chores")
local period = require("core/period")
local view = require("core/view")

-- Each value's position in a list, for ordering by it.
---@param list string[]
---@return table<string, integer>
local function positions(list)
    local out = {}
    for i, v in ipairs(list) do
        out[v] = i
    end
    return out
end

describe("chore-tracker data", function()
    it("has 66 chores: 20 daily, 41 weekly, 5 monthly", function()
        local counts = { daily = 0, weekly = 0, monthly = 0 }
        for _, c in ipairs(chores) do
            counts[c.period] = counts[c.period] + 1
        end
        assert.are.same({ daily = 20, weekly = 41, monthly = 5 }, counts)
    end)

    it("has unique ids, and unique names within a period", function()
        local ids, names = {}, {}
        for _, c in ipairs(chores) do
            assert(ids[c.id] == nil, "duplicate id " .. c.id)
            ids[c.id] = true
            local key = c.period .. " " .. c.name
            assert(names[key] == nil, "duplicate name " .. key)
            names[key] = true
        end
    end)

    it("gives every chore every field, with the right type", function()
        for _, c in ipairs(chores) do
            for _, field in ipairs({ "id", "name", "url", "desc" }) do
                assert.are.equal("string", type(c[field]), c.id .. "." .. field)
            end
            assert(c.id ~= "" and c.name ~= "", c.id)
            assert(c.period == "daily" or c.period == "weekly" or c.period == "monthly", c.id)
            assert.are.equal("table", type(c.links), c.id)
            for _, link in ipairs(c.links) do
                assert.are.equal("string", type(link), c.id)
            end
        end
    end)

    it("puts every daily and weekly chore in a category, and no monthly one", function()
        local known = positions(view.CATEGORIES)
        for _, c in ipairs(chores) do
            if c.period == "monthly" then
                assert(c.category == nil, c.id .. " is monthly but has a category")
            else
                assert(known[c.category], c.id .. " has no known category")
            end
        end
    end)

    it("lists chores in settings order: by period, then category, then name", function()
        local periods, categories = positions(period.PERIODS), positions(view.CATEGORIES)
        ---@param c table
        ---@return table
        local function key(c)
            return { periods[c.period], c.category and categories[c.category] or 0, c.name }
        end
        for i = 2, #chores do
            local a, b = key(chores[i - 1]), key(chores[i])
            local before = a[1] < b[1]
                or (a[1] == b[1] and (a[2] < b[2] or (a[2] == b[2] and a[3] < b[3])))
            assert(before, chores[i - 1].id .. " should come after " .. chores[i].id)
        end
    end)

    it("files every shop-run chore under Shops and every collection under Free supplies", function()
        local byId = {}
        for _, c in ipairs(chores) do
            byId[c.id] = c
        end
        for id in pairs(require("data/shops")) do
            assert.are.equal("shops", byId[id].category, id)
        end
        for _, collection in ipairs(require("data/collections")) do
            assert.are.equal("supplies", byId[collection.chore].category, collection.chore)
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
end)

-- The hand-written icon table (data/icons.lua): one built-in graphic per chore.
describe("chore-tracker icons", function()
    local icons = require("data/icons")
    local catalog = require("tests.harness.catalog")

    it("gives every chore exactly one icon, and names no chore that doesn't exist", function()
        local ids = {}
        for _, c in ipairs(chores) do
            ids[c.id] = true
            assert(icons[c.id] ~= nil, "no icon for " .. c.id)
        end
        for id in pairs(icons) do
            assert(ids[id], "an icon for " .. id .. ", which isn't a chore")
        end
    end)

    it("names one obj or one sprite per chore, each in docs/api/consts", function()
        for id, icon in pairs(icons) do
            local keys = {}
            for k in pairs(icon) do
                keys[#keys + 1] = k
            end
            assert(
                #keys == 1 and (icon.obj or icon.sprite),
                id .. ": want exactly one of obj/sprite"
            )
            if icon.obj then
                assert(catalog.config("Obj", icon.obj), id .. ": no id.Obj." .. icon.obj)
            else
                assert(
                    catalog.config("Sprite", icon.sprite),
                    id .. ": no id.Sprite." .. icon.sprite
                )
            end
        end
    end)
end)
