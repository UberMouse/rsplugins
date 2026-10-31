-- Chores done by collecting what a machine made, hand-written: `invs` are the machines' output
-- inventories, and a collect from any one of them ticks the chore (core/detect.lua says how
-- one is seen), with no count to set. `proven` marks a chore seen ticking in the client.
--
-- The Invention Guild's six machines. Their outputs update as the machines work wherever the
-- player is, but after the client starts they aren't held until the player has been to the
-- machines, which collecting needs anyway. Filling a machine (its _INPUT) doesn't count: the
-- chore is done once you collect.

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
    { chore = "invention-machine", invs = GUILD, proven = true },
    { chore = "invention-machine-weekly", invs = GUILD, proven = true },
}
