-- Lets the chore tracker's specs load its modules the way the client does: require paths are
-- relative to the plugin root (docs/plugin-anatomy.md), so core/state.lua's
-- require("core/period") has to resolve under plugins/chore-tracker/. Busted runs from the
-- repo root, so the plugin root goes first on the module path.

local root = "./plugins/chore-tracker/?.lua;"
if package.path:sub(1, #root) ~= root then package.path = root .. package.path end

local M = {}

-- Epoch minutes for the dates the specs use, checked against Python's datetime (UTC).
M.MINUTES = {
    ["1969-12-31"] = -1440,
    ["1969-12-01"] = -44640,
    ["2026-03-01"] = 29538720,
    ["2026-03-25"] = 29573280,
    ["2026-03-31 23:59"] = 29583359,
    ["2026-04-01"] = 29583360,
    ["2026-04-29"] = 29623680,
    ["2026-04-30"] = 29625120,
    ["2026-04-30 23:59"] = 29626559,
    ["2026-05-01"] = 29626560,
    ["2026-10-01"] = 29846880,
    ["2026-10-21"] = 29875680,
    ["2026-10-25"] = 29881440,
    ["2026-10-25 01:43"] = 29881543,
    ["2026-10-26"] = 29882880,
    ["2026-10-27 23:59"] = 29885759,
    ["2026-10-28"] = 29885760,
    ["2026-12-01"] = 29934720,
    ["2026-12-30"] = 29976480,
    ["2026-12-31"] = 29977920,
    ["2026-12-31 23:59"] = 29979359,
    ["2027-01-01"] = 29979360,
    ["2028-02-01"] = 30549600,
    ["2028-02-29"] = 30589920,
    ["2028-02-29 12:00"] = 30590640,
    ["2028-03-01"] = 30591360,
}

-- A small chore list: one plain and one shop chore per period except monthly.
---@return table[]
function M.chores()
    ---@param id string
    ---@param period string
    ---@param shop boolean
    ---@return table
    local function chore(id, period, shop)
        return {
            id = id,
            name = id:upper(),
            period = period,
            shop = shop,
            url = "https://example.test/" .. id,
            desc = "about " .. id,
            links = {},
        }
    end
    return {
        chore("d1", "daily", false),
        chore("d2", "daily", false),
        chore("dshop", "daily", true),
        chore("w1", "weekly", false),
        chore("wshop", "weekly", true),
        chore("m1", "monthly", false),
    }
end

return M
