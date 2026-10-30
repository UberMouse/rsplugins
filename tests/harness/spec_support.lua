-- Boilerplate the harness specs share: the inline-plugin files table, the manifests that turn on
-- PrettyUI and HTTP, and the plugin-layer prelude. Not a spec (no _spec suffix), so busted skips it.

local M = {}

-- A manifest that lists PrettyUI as a dependency, so the h.ui driver is there.
M.PRETTYUI_MANIFEST = [[{ "name": "t", "version": "1", "contactEmailAddress": "t@example.com",
    "requiredDependencies": { "prettyui": 6398181 } }]]

-- A manifest with the optional permissions and the one url the HTTP specs use.
M.HTTP_MANIFEST = [[{
    "name": "T", "version": "0.0.1", "contactEmailAddress": "t@example.com",
    "optionalPermissions": [ "httpAccess", "chatAccess" ],
    "urls": { "sink": "http://127.0.0.1:8765" }
}]]

-- Lua source that binds `name` to the plugin layer, the parent a plugin's UI hangs off.
---@param name string
---@return string
function M.pluginLayer(name)
    return name
        .. " = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)\n"
end

-- The files table for harness.new/load: an inline plugin whose main.lua is `main`.
-- `opts.manifest` becomes plugin.json; `opts.files` adds more files (it is copied, not changed).
---@param main string
---@param opts { manifest: string?, files: table<string, string>? }?
---@return table<string, string>
function M.inline(main, opts)
    opts = opts or {}
    local files = {}
    for name, text in pairs(opts.files or {}) do
        files[name] = text
    end
    files["main.lua"] = main
    if opts.manifest then files["plugin.json"] = opts.manifest end
    return files
end

return M
