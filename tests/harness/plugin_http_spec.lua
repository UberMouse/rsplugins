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
            sinkType = type(sink)
        ]]),
            { grant = { "httpAccess" } }
        )
        assert.is_true(h.env.http)
        assert.is_false(h.env.chat)
        assert.is_true(h.env.sinkType ~= "string")
        assert.is_true(h.env.sink ~= "http://127.0.0.1:8765")
    end)

    it("hands out urls that are opaque, like the client's", function()
        local h = harness.load(plugin([[
            concatOk, concatErr = pcall(function() return Plugin.urls.sink .. "" end)
            text = tostring(Plugin.urls.sink)
        ]]))
        assert.is_false(h.env.concatOk)
        assert.matches("attempt to concatenate", h.env.concatErr)
        assert.matches("LuaPluginMetadata::URL", h.env.concatErr)
        assert.is_nil(h.env.text:find("127.0.0.1", 1, true))
    end)

    it("reads nil for a url the manifest lacks, as the client does", function()
        local h = harness.load(plugin("missing = Plugin.urls.wiki == nil"))
        assert.is_true(h.env.missing)
    end)

    it("faults on a request to a url the manifest lacks", function()
        assert.matches(
            "is not a plugin.json url",
            harness.errorOf(function()
                harness.load(
                    plugin("HTTPRequest.new(Plugin.urls.wiki)"),
                    { grant = { "httpAccess" } }
                )
            end)
        )
    end)

    it("lists the manifest urls with pairs", function()
        local h = harness.load(plugin([[
            names = {}
            for name, url in pairs(Plugin.urls) do names[#names + 1] = name .. ":" .. type(url) end
        ]]))
        assert.are.same({ "sink:table" }, h.env.names)
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
        local req = h.env.send("{}")
        h:respond(h.requests[1], { timedOut = true })
        h:advance(20)
        assert.are.equal("done false 0  true", h:output())
        assert.are.same(
            { true, 28, "ErrorOperation timed out after 10001 milliseconds with 0 bytes received" },
            { req.failed, req.errorCode, req.errorInfo }
        )
    end)

    it("times out a request left unanswered for 10 s, as the client does", function()
        local h = harness.load(plugin(SENDER), { grant = { "httpAccess" } })
        h.env.send("{}")
        h:advance(9980)
        assert.are.equal("", h:output())
        h:advance(20)
        assert.are.equal("done false 0  true", h:output())
    end)

    it("fails a 4xx reply, keeping its code but not its body", function()
        local h = harness.load(plugin(SENDER), { grant = { "httpAccess" } })
        local req = h.env.send("{}")
        h:respond(h.requests[1], { status = 404, body = "nope", header = "HTTP/1.0 404" })
        h:advance(20)
        assert.are.equal("done false 404  false", h:output())
        assert.are.same(
            { true, 0, "", "HTTP/1.0 404", 0 },
            { req.failed, req.errorCode, req.errorInfo, req.header, req.downloadedBytes }
        )
        assert.is_nil(req.progress)
    end)

    it("never calls back a cancelled request, which finishes failed on the next step", function()
        local h = harness.load(plugin(SENDER), { grant = { "httpAccess" } })
        local req = h.env.send("{}")
        req:Cancel()
        assert.are.same({ true, false, false }, { req.cancelled, req.finished, req.failed })
        h:respond(h.requests[1], { status = 200 })
        h:advance(20)
        assert.are.same({ true, true, false }, { req.finished, req.failed, req.successful })
        h:advance(20000)
        assert.are.equal("", h:output())
    end)

    it("refuses a response field it doesn't know", function()
        local h = harness.load(plugin(SENDER), { grant = { "httpAccess" } })
        h.env.send("{}")
        assert.matches(
            "unknown response field successful",
            harness.errorOf(function()
                h:respond(h.requests[1], { status = 400, successful = false })
            end)
        )
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
        assert.matches(
            "This request is already being executed",
            harness.errorOf(function()
                req:Post("again")
            end)
        )
        assert.matches(
            "This request is already being executed",
            harness.errorOf(function()
                req:AddHeader("X", "y")
            end)
        )
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
