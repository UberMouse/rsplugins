-- Self-tests: loading a plugin, require, the strict environment, the stdlib whitelist and the
-- lifecycle hooks.

local harness = require("tests.harness")

-- An inline plugin whose main.lua is `main`, plus any other files.
local function plugin(main, files)
    local t = files or {}
    t["main.lua"] = main
    return t
end

describe("loading", function()
    it("runs main.lua from a plugins/ folder", function()
        local h = harness.load("var-dump")
        assert.matches("%[VARDUMP%] waiting for httpAccess", h:output())
    end)

    it("runs inline main.lua in a fresh env per load", function()
        local h = harness.load(plugin("counter = 1 print('loaded')"))
        assert.are.equal(1, h.env.counter)
        assert.are.equal("loaded", h:output())
    end)

    it("refuses a manifest with requiredPermissions, which the client can't run", function()
        assert.has_error(function()
            harness.new(
                plugin("", { ["plugin.json"] = '{ "requiredPermissions": ["httpAccess"] }' })
            )
        end)
    end)
end)

describe("require", function()
    it("resolves paths from the plugin root, not the calling file", function()
        local h = harness.load(plugin("result = require('a/b/file1')", {
            ["a/b/file1.lua"] = "return require('a/b/file2') + 1",
            ["a/b/file2.lua"] = "return 41",
        }))
        assert.are.equal(42, h.env.result)
    end)

    it("runs each file once per load and returns the cached value", function()
        local h = harness.load(plugin("same = require('mod') == require('mod')", {
            -- rawget: reading an unset global faults, even the plugin's own.
            ["mod.lua"] = "runs = (rawget(_G, 'runs') or 0) + 1 return {}",
        }))
        assert.is_true(h.env.same)
        assert.are.equal(1, rawget(h.env, "runs"))
    end)

    it("gives a fresh module table after reload", function()
        local h = harness.load(plugin("mod = require('mod')", { ["mod.lua"] = "return {}" }))
        local first = h.env.mod
        h:reload()
        assert.are_not.equal(first, h.env.mod)
    end)

    it("returns nil for a missing file", function()
        local h = harness.load(plugin("missing = require('nope') == nil"))
        assert.is_true(h.env.missing)
    end)

    it("fails on a circular require", function()
        assert.has_error(function()
            harness.load(plugin("require('a')", {
                ["a.lua"] = "return require('b')",
                ["b.lua"] = "return require('a')",
            }))
        end)
    end)
end)

describe("strict environment", function()
    it("faults on a global the harness doesn't provide, naming it", function()
        assert.matches(
            "^main.lua: inline/main.lua:1: unmocked API: World",
            harness.errorOf(function()
                harness.load(plugin("local w = World"))
            end)
        )
    end)

    it("faults on an unmocked member of a mocked namespace", function()
        assert.matches(
            "unmocked API: Player.GetTrackingID",
            harness.errorOf(function()
                harness.load(plugin("Player.GetTrackingID()"))
            end)
        )
    end)

    it("still fails when the plugin swallows the fault with pcall", function()
        assert.matches(
            "caught a harness error.*unmocked API: World",
            harness.errorOf(function()
                harness.load(plugin("pcall(function() return World end)"))
            end)
        )
    end)

    it("catches a method called with '.' and a static called with ':'", function()
        assert.matches(
            "PersistentDB.Get called with '.'",
            harness.errorOf(function()
                harness.load(plugin("PersistentDB.Get('k')"))
            end)
        )
        assert.matches(
            "Player:IsAvailable called with ':'",
            harness.errorOf(function()
                harness.load(plugin("Player:IsAvailable()"))
            end)
        )
    end)

    it("lets the plugin define its own globals", function()
        local h = harness.load(plugin("myGlobal = 5 doubled = myGlobal * 2"))
        assert.are.equal(10, h.env.doubled)
    end)
end)

describe("stdlib", function()
    it("provides string, table, math, utf8 and the base functions", function()
        local h = harness.load(plugin([[
            ok = string.format("%d", 3) == "3" and table.concat({ "a", "b" }) == "ab"
                and math.max(1, 2) == 2 and utf8.char(65) == "A" and select("#", 1, 2) == 2
                and type(pcall) == "function" and type(error) == "function"
                and math.type(1) == "integer" and _G == _ENV
        ]]))
        assert.is_true(h.env.ok)
    end)

    it("withholds os and io unless a test opts in", function()
        assert.matches(
            "not provided in the harness sandbox: os",
            harness.errorOf(function()
                harness.load(plugin("local t = os.time()"))
            end)
        )
        local h = harness.load(plugin("t = os.time()"), { stdlib = { os = true } })
        assert.is_number(h.env.t)
    end)

    it("gives each load its own copy of a library table", function()
        local h = harness.load(plugin("string.extra = true"))
        assert.is_nil(rawget(string, "extra")) -- the host's string table is untouched
        local first = h.env.string
        h:reload()
        assert.are_not.equal(first, h.env.string)
    end)
end)

describe("lifecycle", function()
    it("calls a global PluginShutdown on unload", function()
        local h = harness.load(plugin("function PluginShutdown() print('bye') end"))
        h:unload()
        assert.are.equal("bye", h:output())
    end)

    it("does not call a local PluginShutdown", function()
        local h = harness.load(plugin("local function PluginShutdown() print('bye') end"))
        h:unload()
        assert.are.equal("", h:output())
    end)

    it("reload shuts down, drops subscriptions, and keeps PersistentDB", function()
        local h = harness.load(plugin([[
            loads = (PersistentDB:Get("loads") or 0) + 1
            PersistentDB:Set("loads", loads)
            Event.Logic.Subscribe("tick", function() print("tick " .. loads) end)
            function PluginShutdown() print("shutdown " .. loads) end
        ]]))
        h:reload()
        h:advance(20)
        assert.are.equal("shutdown 1\ntick 2", h:output())
        assert.are.equal(2, h.env.loads)
    end)
end)
