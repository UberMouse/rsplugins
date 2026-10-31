-- Chores done by collecting what a machine made, hand-written. Each machine keeps its product
-- in an output inventory the client holds wherever the player is, and only collecting takes
-- from it, so shell/detect.lua ticks a chore when the total in any of its output inventories
-- falls (core/detect.lua, fell). `proven` marks a chore seen ticking in the beta client.
--
-- The Invention Guild's six machines: collecting 7500 eternal planks emptied one's output, and
-- the outputs updated as the machines worked while the user was at the Player-Owned Farm (chore
-- probe, 2026-10-30, docs/api-concepts.md "Inventories"). Filling a machine (its _INPUT) isn't
-- counted: the chore is done once you collect.

---@class ChoreMachine
---@field chore string the chore id
---@field invs string[] the output inventories' config names
---@field proven boolean

local GUILD = {}
for n = 1, 6 do
    GUILD[n] = "INVENT_MACHINE_GUILD_" .. n .. "_OUTPUT"
end

---@type ChoreMachine[]
return {
    { chore = "invention-machine", invs = GUILD, proven = false },
    { chore = "invention-machine-weekly", invs = GUILD, proven = false },
}
