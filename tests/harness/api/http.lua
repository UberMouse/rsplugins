-- HTTPRequest. Nothing goes on the network: Get/Post append a record to h.requests, the test
-- answers it with h:respond(record, response), and the harness delivers the response on a
-- later Logic step (deliver(), called from init.lua's step()).
--
-- Modelled from https://developer.runescape.com/rs/core/http.html: httpAccess is required;
-- the base URL must be one of the manifest's urls; Get/Post/AddHeader on an active request
-- raise. From docs/api-concepts.md ("Runtime limits we've hit"): starting a request inside a
-- completion callback crashed the client, so it fails the test here. The failure fields,
-- Cancel and the 10 s timeout follow what the client (libcurl underneath) did against the
-- rsdev daemon (api-concepts.md, "Seen with dev-bridge").

local runtime = require("tests.harness.runtime")
local strict = require("tests.harness.strict")
local plugin = require("tests.harness.api.plugin")
local world = require("tests.harness.world")

local M = {}

local CALLBACK_CRASH = "started an HTTP request inside an HTTP completion callback, which "
    .. 'crashed the client (docs/api-concepts.md, "Runtime limits we\'ve hit"); record the '
    .. "result and start the next request from a Logic callback instead"

-- The client's error for Get/Post/AddHeader on a request that hasn't finished.
local ACTIVE = "This request is already being executed"

-- The client gives up on a request after 10 s (500 Logic ticks), with libcurl's
-- CURLE_OPERATION_TIMEDOUT and its message.
local TIMEOUT_TICKS = 500
local TIMEOUT_CODE = 28
local TIMEOUT_INFO = "ErrorOperation timed out after 10001 milliseconds with 0 bytes received"

-- What a test may put in a response (h:respond).
local RESPONSE_KEYS = {
    status = true,
    body = true,
    header = true,
    timedOut = true,
    error = true,
    errorCode = true,
    noBody = true,
}

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
    if not world.granted(h.world.state, "httpAccess") then
        strict.fault("HTTPRequest used without the httpAccess permission")
    end
    if s.active then
        strict.fault("HTTPRequest:" .. method .. " called on an active request: " .. ACTIVE)
    end
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
        -- The callback never runs. The client reads cancelled at once and finished + failed
        -- some ticks later; the harness finishes it on the next step.
        Cancel = function(s)
            if not s.active then return end
            s.active = false
            s.fields.cancelled = true
            s.cancelling = true
        end,
        AddHeader = function(s, key, value)
            if s.active then
                strict.fault("HTTPRequest:AddHeader called on an active request: " .. ACTIVE)
            end
            s.headers[key] = value
        end,
    },
})

local Namespace = strict.class("HTTPRequest", {
    statics = {
        new = function(s, baseURL, path)
            local h = s.h
            if not world.granted(h.world.state, "httpAccess") then
                strict.fault("HTTPRequest.new without the httpAccess permission")
            end
            -- Only a Plugin.urls value is a base URL; the harness hands those out, so one the
            -- manifest lacks (or a plain string) has no text behind it.
            local base = plugin.urlText(baseURL)
            if not base then
                strict.fault(
                    "HTTPRequest.new: the base URL is not a plugin.json url (a Plugin.urls value)"
                )
            end
            if path ~= nil and type(path) ~= "string" then
                strict.fault("HTTPRequest.new(baseURL, path: String?)")
            end
            local state = { h = h, headers = {}, fields = pendingFields(base .. (path or "")) }
            state.proxy = Request.new(state)
            return state.proxy
        end,
    },
})

-- Answer a captured request. `response` is { status = 200, body = "", header = "" } for a
-- reply (a status of 400 or more is a failure, as in the client), { timedOut = true } for a
-- timeout, or { error = "info", errorCode = n } for a failure. It is delivered on the next
-- Logic step.
---@param record table an entry of h.requests
---@param response table
function M.respond(record, response)
    if record.response then strict.fault("this request has already been answered") end
    for key in pairs(response) do
        if not RESPONSE_KEYS[key] then
            strict.fault("h:respond: unknown response field " .. tostring(key))
        end
    end
    record.response = response
end

-- Fill in a finished request's fields from the test's response.
---@param f table the request's fields
---@param r table the response
local function finish(f, r)
    f.finished = true
    if r.timedOut then
        f.failed, f.timedOut = true, true
        f.errorCode, f.errorInfo = TIMEOUT_CODE, TIMEOUT_INFO
    elseif r.error then
        f.failed, f.errorCode, f.errorInfo = true, r.errorCode or 0, r.error
    elseif (r.status or 200) >= 400 then
        -- Live, a 400 and a 404 came back failed with the code, no error code or info, and
        -- no data or progress. Whether a 3xx counts as successful is unconfirmed.
        f.failed, f.responseCode, f.header = true, r.status, r.header or ""
    else
        f.successful, f.responseCode = true, r.status or 200
        f.data, f.header = r.body or "", r.header or ""
        f.downloadedBytes, f.downloadTotalBytes = #f.data, #f.data
        if r.noBody then f.data = nil end -- a 200 whose data the client left nil
        f.progress = 1.0
    end
end

-- Deliver every answered request started before this step, in request order, and time out
-- those left unanswered for TIMEOUT_TICKS. A cancelled request finishes, failed, with no
-- callback.
---@param h table the harness
function M.deliver(h)
    for _, record in ipairs(h.requests) do
        local s = record.state
        if s.cancelling then
            s.cancelling = false
            s.fields.finished, s.fields.failed = true, true
        end
        local r = record.response
        if not r and s.active and h.tick - record.startTick >= TIMEOUT_TICKS then
            r = { timedOut = true }
            record.response = r
        end
        if r and not record.delivered and record.startTick < h.tick and s.active then
            record.delivered = true
            s.active = false
            finish(s.fields, r)
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
