# Developer cheats

Cheats are console commands (prefix `!`) for setting up a character to test against. They only
work in the plugin beta/dev environment and don't exist on live, so plugin logic must never depend
on them. Run them from the console, or from Lua with `ExecuteConsoleCommand("!...")`.

> **Cheat use is logged server-side. Abusing cheats can get the account temporarily or
> permanently banned. Use them only for plugin testing.**

Config names in cheats are case-insensitive (`!give logs` = `!give LOGS`) and match Lua
config names (`config.Obj.LOGS`, `config.Inv.BANK`). Find them with `pan Obj`, `pan VarPlayer`, etc.

## Movement / location

| Command | Notes |
|---|---|
| `!tele <coord>` | Full `0,50,50,9,56` or `0_50_50_9_56`, or map-square shorthand `0,50,50` (centre of square) |
| `!tele <named>` | Named destination, e.g. `grandexchange` (`0,49,54,29,40`) |
| `!getcoord` | Print your coordinate. In an instance it also prints the region source coordinate |
| `!coordsave` / `!coordtele` | Listed by the developer site, but missing from beta client 951-1: "Could not find debugproc coord_save" (2026-10-31). Note the tile yourself before a `!tele` (`!getcoord`, or `Player.GetEntity().coordGrid` in a bridge eval) |
| Ctrl+Shift+click | Teleport to the clicked point (world, minimap, world map) |

## Items and inventories

| Command | Notes |
|---|---|
| `!give <obj> [count] [inv]` | Add to backpack (`inv`) or another inventory (e.g. `bank`). Stops when full |
| `!objadd <obj> [count]` | Drop the item on the ground at your feet |
| `!listinv <inv>` | Print an inventory's contents, including VarObj values |
| `!clearinv` / `!clearworn` | Delete everything in the backpack / equipment |
| `!bank` | Open the bank anywhere |

## Inspecting the world

| Command | Notes |
|---|---|
| `!listnpcs <radius>` | NPC entities within radius (max 32) |
| `!listlocs <radius>` | Loc entities within radius (max 32) |
| `!listobjs <radius> <obj or null>` | Ground items within radius (max 32), optional filter |

## Skills

| Command | Notes |
|---|---|
| `!skillsetlevel <skill> <level>` / `!skillsetxp <skill> <xp>` | Set directly. **Doesn't** trigger level-up checks |
| `!skilladdlevel <skill> <n>` / `!skilladdxp <skill> <n>` | Add. **Does** trigger level-up checks |

To reach a level with level-up effects, set it to one below, then add one.

## Vars

| Command | Notes |
|---|---|
| `!getvar <name>` / `!setvar <name> <value>` | VarPlayer (or a VarBit on one). Values are int, long or string. Two `!setvar`s of one var sent back to back can land in one server tick, so the client gets only the last value: wait about 3 s before setting it back (2026-10-31). A var the game doesn't transmit changes on the server only (`!getvar` shows it; the client still reads the old value) |
| `!getvarc <name>` / `!setvarc <name> <value>` | VarClient |

## Account state

| Command | Notes |
|---|---|
| `!allinone` | Complete all quests/tasks and max all skills |
| `!resetsave` / `!unresetsave` | Flag/unflag the beta character for reset on next logout |
| `!godmode` | Toggle combat invulnerability |
| `!maxhp` | Toggle constant full health |
| `!hitall` | Deal 5000 damage to every NPC within 50 tiles |
| `!setironman` / `!sethardcore` / `!setgroupironman <0/1>` | Toggle game modes |

## Skill-specific and misc

| Command | Notes |
|---|---|
| `!archcompletetutorial` | Finish the Archaeology tutorial |
| `!archgivemats <count> <inv>` | All Archaeology materials |
| `!inventgivemats` / `!inventwipemats` | Max out / clear Invention materials |
| `!inventmachinerun` | Advance Invention machines by 1 hour |
| `!inventsetperks <slot> <perk1> <rank1> <perk2> <rank2> <gizmoSlot 1/2>` | Set gizmo perks on a backpack item |
| `!pouchadd <currency> <count> <clampOverflow 0/1>`, `!pouchdel`, `!pouchdeposit <currency> <inv>`, `!pouchwithdraw`, `!pouchspace`, `!pouchtotal`, `!testpouchadd`, `!testpouchdel` | Currency pouch. Uses numeric currency IDs |
| `!tlihide` / `!tlishow` | Hide/show all interfaces (for screenshots) |

The numeric ID tables for Invention perks and currencies are at
<https://developer.runescape.com/rs/cheats.html#invention-perk-ids> and `#currency-ids`.
Examples: dungeoneering tokens = 44, ectotokens = 9, Mazcab teci = 11.
