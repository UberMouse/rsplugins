-- HTTPRequest. Nothing goes on the network: Get/Post append a record to h.requests, the test
-- answers it with h:respond(record, response), and the harness delivers the response on a
-- later Logic step (deliver(), called from init.lua's step()).
--
-- Modelled from https://developer.runescape.com/rs/core/http.html: httpAccess is required;
-- the base URL must be one of the manifest's urls; Get/Post/AddHeader on an active request
-- raise. From docs/api-concepts.md ("Runtime limits we've hit"): starting a request inside a
-- completion callback crashed the client, so it fails the test here.

local runtime = require("tests.harness.runtime")
local strict = require("tests.harness.strict")

local M = {}

local CALLBACK_CRASH = "started an HTTP request inside an HTTP completion callback, which "
    .. 'crashed the client (docs/api-concepts.md, "Runtime limits we\'ve hit"); record the '
    .. "result and start the next request from a Logic callback instead"

-- Field values of a request that hasn't finished.
---@param url string
---@return table
local function pendingFields(url)
    return {
        data = "",
        header = "",
        cancelled = false,
        finished = false,
        successful = false,
        failed = false,
        timedOut = false,
        responseCode = 0,
        errorCode = 0,
        errorInfo = "",
        progress = nil,
        url = url,
        downloadedBytes = 0,
        downloadTotalBytes = 0,
    }
end

local FIELD_NAMES = pendingFields("")
FIELD_NAMES.progress = true -- nil-valued, so pairs() would skip it
local fields = {}
for name in pairs(FIELD_NAMES) do
    fields[name] = function(s)
        return s.fields[name]
    end
end

---@param s table request state
---@param method string "GET" or "POST"
---@param body string?
---@param onDone function?
local function start(s, method, body, onDone)
    local h = s.h
    if h.inHttpCallback then strict.fault(CALLBACK_CRASH) end
    if not h.world.state.permissions.granted.httpAccess then
        strict.fault("HTTPRequest used without the httpAccess permission")
    end
    if s.active then strict.fault("HTTPRequest:" .. method .. " called on an active request") end
    s.active = true
    s.fields = pendingFields(s.fields.url)
    h.requests[#h.requests + 1] = {
        method = method,
        url = s.fields.url,
        body = body,
        headers = s.headers,
        request = s.proxy,
        state = s,
        onDone = onDone,
        instance = h.instance,
        startTick = h.tick,
    }
end

local Request = strict.class("HTTPRequest", {
    fields = fields,
    methods = {
        Get = function(s, onDone)
            start(s, "GET", nil, onDone)
        end,
        Post = function(s, data, onDone)
            if type(data) ~= "string" then strict.fault("HTTPRequest:Post(data: String, ...)") end
            start(s, "POST", data, onDone)
        end,
        Cancel = function(s)
            if not s.active then return end
            s.active = false
            s.fields.cancelled, s.fields.finished = true, true
        end,
        AddHeader = function(s, key, value)
            if s.active then strict.fault("HTTPRequest:AddHeader called on an active request") end
            s.headers[key] = value
        end,
    },
})

local Namespace = strict.class("HTTPRequest", {
    statics = {
        new = function(s, baseURL, path)
            local h = s.h
            if not h.world.state.permissions.granted.httpAccess then
                strict.fault("HTTPRequest.new without the httpAccess permission")
            end
            local known = false
            for _, url in pairs(h.manifest.urls or {}) do
                known = known or url == baseURL
            end
            if not known then
                strict.fault(
                    "HTTPRequest.new: " .. tostring(baseURL) .. " is not a plugin.json url"
                )
            end
            if path ~= nil and type(path) ~= "string" then
                strict.fault("HTTPRequest.new(baseURL, path: String?)")
            end
            local state = { h = h, headers = {}, fields = pendingFields(baseURL .. (path or "")) }
            state.proxy = Request.new(state)
            return state.proxy
        end,
    },
})

-- Answer a captured request. `response` is { status = 200, body = "", header = "" } for a
-- reply, { timedOut = true } for a timeout, or { error = "info", errorCode = n } for a
-- failure. It is delivered on the next Logic step.
---@param record table an entry of h.requests
---@param response table
function M.respond(record, response)
    if record.response then strict.fault("this request has already been answered") end
    record.response = response
end

-- Deliver every answered request started before this step, in request order.
---@param h table the harness
function M.deliver(h)
    for _, record in ipairs(h.requests) do
        local s, r = record.state, record.response
        if r and not record.delivered and record.startTick < h.tick and s.active then
            record.delivered = true
            s.active = false
            local f = s.fields
            f.finished = true
            if r.timedOut then
                f.failed, f.timedOut, f.errorInfo = true, true, "timed out"
            elseif r.error then
                f.failed, f.errorCode, f.errorInfo = true, r.errorCode or 0, r.error
            else
                -- `successful` means the exchange completed, whatever the status code
                -- (plugins/var-dump checks responseCode separately).
                f.successful, f.responseCode = true, r.status or 200
                f.data, f.header = r.body or "", r.header or ""
                f.downloadedBytes, f.downloadTotalBytes = #f.data, #f.data
                f.progress = 1.0
            end
            if record.onDone and record.instance.alive then
                h.inHttpCallback = true
                local ok, err = pcall(
                    runtime.call,
                    h.budgetMs,
                    "HTTP completion callback for " .. record.url,
                    record.onDone,
                    record.request
                )
                h.inHttpCallback = false
                if not ok then error(err, 0) end
            end
        end
    end
end

---@param h table the harness
---@param env table the sandbox being built
function M.install(h, env)
    env.HTTPRequest = Namespace.new({ h = h })
end

return M
