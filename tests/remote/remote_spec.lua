-- Remote eval (lib/dev/remote.lua) over the dev log tee, with small inline plugins: polling,
-- running snippets in the plugin's environment, reset, expose and press, and the paths where it
-- stays off.

local harness = require("tests.harness")
local support = require("tests.tee.support")

local INSTALL = 'local tee = require("dev/tee")\nlocal remote = require("dev/remote")\n'
    .. 'tee.install(_ENV, "t")\nremote.install(_ENV, tee)\n'

-- A loaded plugin with the tee and remote installed and httpAccess granted.
---@param main string?
---@param opts table?
---@return table h
local function loaded(main, opts)
    local h = harness.new(
        support.plugin(INSTALL .. (main or "")),
        opts or { grant = { "httpAccess" }, stdlib = { load = true } }
    )
    h:load()
    return h
end

-- Step until the tee has made `count` requests, at most `max` steps.
---@param h table
---@param count integer
---@param max integer?
local function untilPosts(h, count, max)
    for _ = 1, max or 40 do
        h:step()
        if #support.posts(h) >= count then return end
    end
    error("no request #" .. count)
end

-- Send `lines` (reply lines without the trailing newline) as the reply to the latest POST,
-- then step until the next POST, which carries the results. Returns that batch, decoded.
---@param h table
---@param lines string[]
---@return table
local function exchange(h, lines)
    local posts = support.posts(h)
    local body = #lines > 0 and table.concat(lines, "\n") .. "\n" or ""
    h:respond(posts[#posts], { status = 200, body = body })
    untilPosts(h, #posts + 1)
    local batches = support.batches(h)
    return batches[#batches]
end

-- The result of one eval sent as command `id`.
---@param h table
---@param source string
---@return table
local function eval(h, source)
    local escaped = source:gsub("\\", "\\\\"):gsub("\n", "\\n"):gsub("\t", "\\t")
    local batch = exchange(h, { "c1\teval\t" .. escaped })
    assert.are.equal(1, #batch.results)
    return batch.results[1]
end

describe("dev remote", function()
    it("polls even with no lines, saying it takes commands", function()
        local h = loaded()
        untilPosts(h, 1, 1)
        local batch = support.batches(h)[1]
        assert.is_true(batch.remote)
        assert.are.same({}, batch.results)
        assert.is_not_nil(h:output():find("[REMOTE] taking eval commands", 1, true))
    end)

    it("runs a snippet in the plugin's environment and sends its values and output", function()
        local h = loaded("counter = 5")
        untilPosts(h, 1)
        local r = eval(h, "print('hi', counter) return counter + 1, nil")
        assert.are.same({ "c1", true, 6, 2 }, { r.id, r.ok, r.values[1], r.nvalues })
        assert.are.same({ "hi 5" }, r.output)
    end)

    it("reaches main.lua's locals through an exposed getter", function()
        local h =
            loaded("local hidden = { n = 41 }\nremote.expose('main', function() return hidden end)")
        untilPosts(h, 1)
        assert.are.same({ 42 }, eval(h, "exposed.main().n + 1").values)
    end)

    it("reports compile and runtime errors", function()
        local h = loaded()
        untilPosts(h, 1)
        local r = eval(h, "return (")
        assert.is_false(r.ok)
        assert.is_not_nil(r.error:find("eval", 1, true))
        r = eval(h, "print('before') error('boom')")
        assert.is_false(r.ok)
        assert.are.same({ "before" }, r.output)
        assert.is_not_nil(r.error:find("boom", 1, true))
    end)

    it("answers a command its own code fails on, so eval isn't left waiting", function()
        -- Shut down while the tee still polls: the scratch env is gone, so the eval's assert fails.
        local h = loaded("function stopRemote() remote.shutdown() end")
        untilPosts(h, 1)
        h.env.stopRemote()
        local r = eval(h, "1")
        assert.are.same({ "c1", false }, { r.id, r.ok })
        assert.is_not_nil(r.error:find("dev/remote failed", 1, true))
    end)

    it("keeps snippet globals in a scratch env, cleared by reset", function()
        local h = loaded("x = 'plugin'")
        untilPosts(h, 1)
        eval(h, "x = 'scratch'")
        assert.are.same({ "scratch" }, eval(h, "x").values)
        assert.are.equal("plugin", h.env.x)
        local batch = exchange(h, { "c2\treset\t" })
        assert.is_true(batch.results[1].ok)
        assert.are.same({ "plugin" }, eval(h, "x").values)
    end)

    it("presses an exposed pressable by its text or label", function()
        local main = [[
pressed = {}
local rows = {
    { text = "Alpha Run", onClick = function() pressed[#pressed + 1] = "alpha" end },
    { label = { content = "Beta Run" }, onClick = function() pressed[#pressed + 1] = "beta" end },
    { text = "Alpha", onClick = function() pressed[#pressed + 1] = "exact" end },
}
remote.expose("rows", function() return rows end)
]]
        local h = loaded(main)
        untilPosts(h, 1)
        assert.are.same({ "Beta Run" }, eval(h, "press('beta')").values)
        assert.are.same({ "Alpha" }, eval(h, "press('alpha')").values) -- exact beats partial
        local r = eval(h, "press('run')")
        assert.is_false(r.ok)
        assert.is_not_nil(r.error:find("several match", 1, true))
        assert.are.same({ "Beta Run" }, eval(h, "press('run', 2)").values)
        r = eval(h, "press('gamma')")
        assert.is_not_nil(r.error:find("nothing pressable", 1, true))
        assert.are.same({ "beta", "exact", "beta" }, h.env.pressed)
    end)

    it("stays off without httpAccess", function()
        local h = loaded(nil, {})
        h:advance(2000)
        assert.are.equal(0, #support.posts(h))
        assert.is_not_nil(h:output():find("[REMOTE] the dev log tee isn't sending", 1, true))
    end)

    it("resends results whose POST failed", function()
        local h = loaded()
        untilPosts(h, 1)
        h:respond(support.posts(h)[1], { status = 200, body = "c1\teval\t1\n" })
        untilPosts(h, 2)
        assert.are.equal(1, #support.batches(h)[2].results)
        h:respond(support.posts(h)[2], { status = 500 })
        untilPosts(h, 3, 400) -- after the retry wait
        local third = support.batches(h)[3]
        assert.are.equal("c1", third.results[1].id)
    end)

    it("stops polling at shutdown", function()
        local h = loaded("function PluginShutdown() remote.shutdown() tee.shutdown() end")
        untilPosts(h, 1)
        h:respond(support.posts(h)[1], { status = 200 })
        h.env.PluginShutdown()
        h:advance(2000)
        assert.are.equal(1, #support.posts(h))
    end)
end)
