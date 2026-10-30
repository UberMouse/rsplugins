-- Self-tests: loading a plugin, require, the strict environment, the stdlib whitelist and the
-- lifecycle hooks.

local harness = require("tests.harness")
local support = require("tests.harness.spec_support")

-- An inline plugin whose main.lua is `main`, plus any other files.
local function plugin(main, files)
    return support.inline(main, { files = files })
end

describe("loading", function()
    it("runs main.lua from a plugin folder given by path", function()
        local h = harness.load("tests/fixtures/plugins/hello")
        assert.are.equal("[HELLO] fixture loaded", h:output())
    end)

    it("runs inline main.lua in a fresh env per load", function()
        local h = harness.load(plugin("counter = 1 print('loaded')"))
        assert.are.equal(1, h.env.counter)
        assert.are.equal("loaded", h:output())
    end)

    it("refuses a manifest with requiredPermissions, which the client can't run", function()
        assert.matches(
            "requiredPermissions is broken in the client",
            harness.errorOf(
                harness.new,
                plugin("", { ["plugin.json"] = '{ "requiredPermissions": ["httpAccess"] }' })
            )
        )
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
        assert.matches(
            "circular require of",
            harness.errorOf(
                harness.load,
                plugin("require('a')", {
                    ["a.lua"] = "return require('b')",
                    ["b.lua"] = "return require('a')",
                })
            )
        )
    end)
end)

describe("strict environment", function()
    it("faults on a global the harness doesn't provide, naming it", function()
        assert.matches(
            "^main.lua: inline/main.lua:1: unmocked API: World",
            harness.errorOf(harness.load, plugin("local w = World"))
        )
    end)

    it("faults on an unmocked member of a mocked namespace", function()
        assert.matches(
            "unmocked API: Player.GetTrackingID",
            harness.errorOf(harness.load, plugin("Player.GetTrackingID()"))
        )
    end)

    it("still fails when the plugin swallows the fault with pcall", function()
        assert.matches(
            "caught a harness error.*unmocked API: World",
            harness.errorOf(harness.load, plugin("pcall(function() return World end)"))
        )
    end)

    it("catches a method called with '.' and a static called with ':'", function()
        assert.matches(
            "PersistentDB.Get called with '.'",
            harness.errorOf(harness.load, plugin("PersistentDB.Get('k')"))
        )
        assert.matches(
            "Player:IsAvailable called with ':'",
            harness.errorOf(harness.load, plugin("Player:IsAvailable()"))
        )
    end)

    it("faults on an unknown enum member, and on a write to an enum", function()
        assert.matches(
            "unmocked API: PluginPermissions%.httpaccess",
            harness.errorOf(harness.load, plugin("local _ = PluginPermissions.httpaccess"))
        )
        assert.matches("is read%-only", harness.errorOf(harness.load, plugin("ChatType.X = 1")))
    end)

    it("reads a name in opts.absentNames as the client reads an unknown one", function()
        local main = [[
            invNil = config.Inv.INV == nil
            objNil = config.Obj.LOGS == nil
            varNil = var.VarPlayer.ABSYSTEM == nil
            sprite, obj = id.Sprite.XP_TOKEN_0, id.Obj.POP_LOG
            known = config.Inv.BANK ~= nil
        ]]
        local h = harness.load(plugin(main), {
            absentNames = {
                "config.Inv.INV",
                "config.Obj.LOGS",
                "var.VarPlayer.ABSYSTEM",
                "id.Sprite.XP_TOKEN_0",
                "id.Obj.POP_LOG",
            },
        })
        assert.is_true(h.env.invNil and h.env.objNil and h.env.varNil and h.env.known)
        assert.are.same({ -1, -1 }, { h.env.sprite, h.env.obj })
        -- Other unknown names still fault, so a typo is caught.
        assert.matches(
            "unknown sprite: id.Sprite.NOPE",
            harness.errorOf(harness.load, plugin("local _ = id.Sprite.NOPE"), {
                absentNames = { "id.Sprite.XP_TOKEN_0" },
            })
        )
        assert.matches(
            "unmocked API: config.Inv.NOPE",
            harness.errorOf(harness.load, plugin("local _ = config.Inv.NOPE"), {
                absentNames = { "config.Inv.INV" },
            })
        )
        assert.matches(
            "opts.absentNames id.Font.X: only",
            harness.errorOf(harness.new, plugin(""), { absentNames = { "id.Font.X" } })
        )
    end)

    it("reads a global named in opts.absent as nil, and rejects naming a provided one", function()
        local h = harness.load(plugin("seen = World == nil"), { absent = { "World" } })
        assert.is_true(h.env.seen)
        assert.matches(
            "opts.absent names string, which the sandbox provides",
            harness.errorOf(harness.load, plugin(""), { absent = { "string" } })
        )
    end)

    it("lets the plugin define its own globals", function()
        local h = harness.load(plugin("myGlobal = 5 doubled = myGlobal * 2"))
        assert.are.equal(10, h.env.doubled)
    end)
end)

describe("stdlib", function()
    it("provides string, table, math and the base functions, but no utf8", function()
        local h = harness.load(plugin([[
            ok = string.format("%d", 3) == "3" and table.concat({ "a", "b" }) == "ab"
                and math.max(1, 2) == 2 and select("#", 1, 2) == 2 and rawget(_G, "utf8") == nil
                and type(pcall) == "function" and type(error) == "function"
                and math.type(1) == "integer" and type(string.dump) == "function"
                and math.type(collectgarbage("count")) == "float" and warn("x") == nil
        ]]))
        assert.is_true(h.env.ok)
        assert.matches(
            "not provided in the harness sandbox: utf8 %(absent in the client%)",
            harness.errorOf(harness.load, plugin("local n = utf8.len('x')"))
        )
        assert.matches(
            "collectgarbage%(stop%) is not modelled",
            harness.errorOf(harness.load, plugin('collectgarbage("stop")'))
        )
    end)

    it("withholds os and io unless a test opts in", function()
        assert.matches(
            "not provided in the harness sandbox: os",
            harness.errorOf(harness.load, plugin("local t = os.time()"))
        )
        local h = harness.load(plugin("t = os.time()"), { stdlib = { os = true } })
        assert.is_number(h.env.t)
    end)

    it("withholds load unless a test opts in, then keeps chunks in the sandbox", function()
        assert.matches(
            "not provided in the harness sandbox: load %(present in the client",
            harness.errorOf(harness.load, plugin("local f = load('return 1')"))
        )
        local h = harness.load(
            plugin([[
                inSandbox = load("return _G")() == _G
                own = load("return y", "=c", "t", { y = 7 })()
                noEnv = load("return _ENV", "=c", "t", nil)() == nil
            ]]),
            { stdlib = { load = true } }
        )
        assert.are.same({ true, 7, true }, { h.env.inSandbox, h.env.own, h.env.noEnv })
        assert.matches(
            "only",
            harness.errorOf(
                harness.load,
                plugin("load('return 1', 'c', 'b')"),
                { stdlib = { load = true } }
            )
        )
    end)

    it("gives each load its own copy of a library table", function()
        local h = harness.load(plugin("string.extra = true"))
        assert.is_nil(rawget(string, "extra")) -- the host's string table is untouched
        local first = h.env.string
        h:reload()
        assert.are_not.equal(first, h.env.string)
    end)
end)

describe("_G", function()
    it("reads the API and stdlib but not the plugin's own globals, as the client's does", function()
        local h = harness.load(plugin([[
            mine = 1
            same = _G.print == print and _G._G == _G and _G ~= _ENV
            raw = { rawget(_G, "mine"), rawget(_ENV, "mine") }
            names = {}
            for name in pairs(_G) do names[name] = true end
        ]]))
        assert.is_true(h.env.same)
        assert.are.same({ nil, 1 }, h.env.raw)
        assert.is_true(h.env.names.Event and h.env.names.print)
        assert.is_nil(h.env.names.Plugin or h.env.names.require or h.env.names.mine)
        for _, name in ipairs({ "mine", "Plugin", "require" }) do
            assert.matches(
                "_G%." .. name .. ": the client's _G is the table every plugin shares",
                harness.errorOf(harness.load, plugin("mine = 1 local x = _G." .. name))
            )
        end
    end)

    it("faults on any write to _G, which would reach every plugin", function()
        for _, code in ipairs({ "_G.mine = 1", "_G.print = nil", "_G['Event'] = {}" }) do
            assert.matches(
                "assigned: the client's _G is the table every plugin shares",
                harness.errorOf(harness.load, plugin(code))
            )
        end
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

    describe("leftover subscriptions", function()
        local LEAK = "Event.Logic.Subscribe('tick', function() end)"

        it(
            "faults on unload when the plugin has no PluginShutdown, naming event and name",
            function()
                local h = harness.load(plugin(LEAK))
                local err = harness.errorOf(h.unload, h)
                assert.is_not_nil(string.find(err, "left subscriptions behind", 1, true))
                assert.is_not_nil(string.find(err, "Logic 'tick'", 1, true))
            end
        )

        it("names only what PluginShutdown left, in event order", function()
            local h = harness.load(plugin([[
                Event.Logic.Subscribe("a", function() end)
                Event.KeyTyped.Subscribe("b", function() end)
                Event.Logic.Subscribe("c", function() end)
                function PluginShutdown() Event.Logic.Unsubscribe("a") end
            ]]))
            local err = harness.errorOf(h.unload, h)
            assert.is_not_nil(string.find(err, "KeyTyped 'b', Logic 'c'", 1, true))
            assert.is_nil(err:find("'a'", 1, true))
        end)

        it("faults on reload too", function()
            local h = harness.load(plugin(LEAK))
            assert.is_not_nil(string.find(harness.errorOf(h.reload, h), "Logic 'tick'", 1, true))
        end)

        it("passes when PluginShutdown unsubscribes everything", function()
            local h = harness.load(
                plugin(LEAK .. " function PluginShutdown() Event.Logic.Unsubscribe('tick') end")
            )
            h:unload()
        end)

        it("is skipped by allowLeftSubscriptions, on unload and reload", function()
            local h = harness.load(plugin(LEAK), { allowLeftSubscriptions = true })
            h:reload()
            h:unload()
        end)

        it("reports a raising PluginShutdown alone", function()
            local h = harness.load(plugin(LEAK .. " function PluginShutdown() error('boom') end"))
            local err = harness.errorOf(h.unload, h)
            assert.is_not_nil(string.find(err, "boom", 1, true))
            assert.is_nil(err:find("left subscriptions", 1, true))
        end)
    end)

    it("reload shuts down, drops subscriptions, and keeps PersistentDB", function()
        -- The plugin leaves its Logic subscription on purpose: the harness itself must drop it.
        local h = harness.load(
            plugin([[
            loads = (PersistentDB:Get("loads") or 0) + 1
            PersistentDB:Set("loads", loads)
            Event.Logic.Subscribe("tick", function() print("tick " .. loads) end)
            function PluginShutdown() print("shutdown " .. loads) end
        ]]),
            { allowLeftSubscriptions = true }
        )
        h:reload()
        h:advance(20)
        assert.are.equal("shutdown 1\ntick 2", h:output())
        assert.are.equal(2, h.env.loads)
    end)
end)
