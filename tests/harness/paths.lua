-- Repo-relative paths, resolved from this file's location so the harness works whatever
-- directory busted was started from.

local M = {}

local here = debug.getinfo(1, "S").source:match("^@(.*)$") or ""
-- "" when the harness was loaded by a relative path from the repo root.
M.root = here:match("^(.*)tests/harness/paths%.lua$") or ""

---@param relative string a path from the repo root, e.g. "docs/vars/vars.csv"
---@return string
function M.repo(relative)
    return M.root .. relative
end

---@param path string
---@return string? # the contents, or nil if the file can't be read
function M.read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local text = f:read("a")
    f:close()
    return text
end

return M
