-- Self-tests: Plugin.HasPermission / Plugin.urls, permission changes, and HTTPRequest.

local harness = require("tests.harness")

local MANIFEST = [[{
    "name": "T", "version": "0.0.1", "contactEmailAddress": "t@example.com",
    "optionalPermissions": [ "httpAccess", "chatAccess" ],
    "urls": { "sink": "http://127.0.0.1:8765" }
}]]

local function plugin(main)
    return { ["main.lua"] = main, ["plugin.json"] = MANIFEST }
end

describe("Plugin", function()
    it("reports granted permissions and exposes manifest urls", function()
        local h = harness.load(
            plugin([[
            http = Plugin.HasPermission(PluginPermissions.httpAccess)
            chat = Plugin.HasPermission(PluginPermissions.chatAccess)
            sink = Plugin.urls.sink
        ]]),
            { grant = { "httpAccess" } }
        )
        assert.is_true(h.env.http)
        assert.is_false(h.env.chat)
        assert.are.equal("http://127.0.0.1:8765", h.env.sink)
    end)

    it("faults on a url the manifest lacks", function()
        assert.matches(
            "Plugin.urls.wiki is not in plugin.json urls",
            harness.errorOf(function()
                harness.load(plugin("local u = Plugin.urls.wiki"))
            end)
        )
    end)

    it("fires OptionalPermissionChanged when a permission is granted or revoked", function()
        local h = harness.load(plugin([[
            Event.OptionalPermissionChanged.Subscribe("p", function(ev)
                print(ev.permissionName, ev.enabled, Plugin.HasPermission(ev.permissionName))
            end)
        ]]))
        h.world:grant("chatAccess")
        h.world:grant("chatAccess") -- no change, no event
        h.world:revoke("chatAccess")
        assert.are.equal("chatAccess true true\nchatAccess false false", h:output())
    end)

    it("only grants permissions the manifest requests", function()
        local h = harness.new(plugin(""))
        assert.has_error(function()
            h.world:grant("trackingAccess")
        end)
    end)
end)

describe("HTTPRequest", function()
    local SENDER = [[
        function send(body)
            local req = HTTPRequest.new(Plugin.urls.sink, "/changes")
            req:AddHeader("Content-Type", "application/json")
            req:Post(body, function(r)
                print("done", r.successful, r.responseCode, r.data, r.timedOut)
            end)
            return req
        end
    ]]

    it("captures requests and delivers the test's response on a later tick", function()
        local h = harness.load(plugin(SENDER), { grant = { "httpAccess" } })
        local req = h.env.send("{}")
        local record = h.requests[1]
        assert.are.same(
            { "POST", "http://127.0.0.1:8765/changes", "{}", "application/json" },
            { record.method, record.url, record.body, record.headers["Content-Type"] }
        )
        assert.is_false(req.finished)
        h:respond(record, { status = 200, body = "ok" })
        assert.are.equal("", h:output()) -- not before the next tick
        h:advance(20)
        assert.are.equal("done true 200 ok false", h:output())
        assert.is_true(req.finished)
    end)

    it("reports a timeout", function()
        local h = harness.load(plugin(SENDER), { grant = { "httpAccess" } })
        h.env.send("{}")
        h:respond(h.requests[1], { timedOut = true })
        h:advance(20)
        assert.are.equal("done false 0  true", h:output())
    end)

    it("faults without httpAccess, or for a base url not in the manifest", function()
        local h = harness.load(plugin(SENDER))
        assert.has_error(function()
            h.env.send("{}")
        end)
        assert.matches(
            "is not a plugin.json url",
            harness.errorOf(function()
                harness.load(
                    plugin("HTTPRequest.new('http://example.com')"),
                    { grant = { "httpAccess" } }
                )
            end)
        )
    end)

    it("faults on Post or AddHeader while the request is active", function()
        local h = harness.load(plugin(SENDER), { grant = { "httpAccess" } })
        local req = h.env.send("{}")
        assert.has_error(function()
            req:Post("again")
        end)
        assert.has_error(function()
            req:AddHeader("X", "y")
        end)
    end)

    it("fails the test when a completion callback starts another request", function()
        local h = harness.load(
            plugin([[
            local req = HTTPRequest.new(Plugin.urls.sink)
            req:Get(function()
                HTTPRequest.new(Plugin.urls.sink):Post("next")
            end)
        ]]),
            { grant = { "httpAccess" } }
        )
        h:respond(h.requests[1], { status = 200 })
        local err = harness.errorOf(function()
            h:advance(20)
        end)
        assert.matches("^HTTP completion callback for http://127.0.0.1:8765: ", err)
        assert.matches("crashed the client %(docs/api%-concepts.md", err)
    end)

    it("drops completion callbacks of an unloaded plugin", function()
        local h = harness.load(plugin(SENDER), { grant = { "httpAccess" } })
        h.env.send("{}")
        h:unload()
        h:respond(h.requests[1], { status = 200 })
        h:advance(20)
        assert.are.equal("", h:output())
    end)
end)
