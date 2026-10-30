-- The HTTP shell the dev tools share (the recorder, the log tee and the dev bridge): start a
-- JSON POST and cancel one. Each keeps its own retry and backoff policy. The pure helpers
-- (failureText, the body builders) are in dev/batch.lua.
--
-- The crash rules both helpers encode (docs/api-concepts.md, "Runtime limits we've hit"):
--
--   * An API function is never handed to pcall: the client aborted every time one was
--     (Unsubscribe above all). The calls run inside Lua closures, and those go under pcall.
--   * A request is never started from a completion callback (that crashed the client). The
--     caller starts one from its Logic subscription only, and its completion callback just
--     settles its books or marks the request done. startPost cannot enforce this; it is the
--     caller's rule.
--   * The body stays referenced until the request finishes, in case the client doesn't copy
--     it. The pending record returned by startPost holds the request and the body; the caller
--     keeps it until the completion callback has run or it cancels.
--
-- The caller stores the returned record only after startPost returns, so a completion callback
-- must not run inside the Post call itself. The client delivers completions later, from its
-- own tick, and the harness only on h:respond.

local post = {}

-- A pending POST is { request = HTTPRequest, body = string } (spelled out where it is typed,
-- since this module is loaded through several dev/ symlinks and LuaLS rejects a @class twice).

-- POST `body` as JSON to `path` under the manifest url `url`; `onDone(finished)` runs when it
-- completes. Returns the pending record, or nil and the error when the request could not be
-- started (the client refusing a request, say). Nothing was left in flight in that case.
---@param http table the HTTPRequest table
---@param url PluginURL
---@param path string
---@param body string
---@param onDone fun(finished: HTTPRequest)
---@return { request: HTTPRequest, body: string }?
---@return any
function post.startPost(http, url, path, body, onDone)
    local pending = { body = body } ---@type table
    local ok, err = pcall(function()
        local request = http.new(url, path)
        request:AddHeader("Content-Type", "application/json")
        pending.request = request
        request:Post(body, onDone)
    end)
    if not ok then return nil, err end
    return pending
end

-- Cancel a pending POST, never raising. A nil `pending` is ignored.
---@param pending { request: HTTPRequest, body: string }?
function post.cancel(pending)
    if not pending or not pending.request then return end
    local request = pending.request
    -- A Lua closure around the API call, never the API function itself.
    pcall(function()
        request:Cancel()
    end)
end

return post
