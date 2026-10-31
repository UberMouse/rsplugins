# API concepts

A conceptual guide to the API. The full per-type reference is the LuaLS stubs in `docs/api/` (see
[README.md](README.md#the-api-reference-api)). Treat names here as orientation, and check
signatures against the stubs.

Evidence tags below name where a fact was seen. Several sections used to be dated probe logs, and
the tag keeps that provenance next to the fact:

- *first recording, 2026-10-25*: `plugins/recorder-demo` in the beta client, its probe line and the
  dev recorder's recording `20261025-144642-8f7250b863` (bank, picking things up, pickpocketing,
  talking to NPCs, buying out a shop line). See [testing.md](testing.md#recordings) for recordings.
- *dev-bridge, 2026-10-26*: `plugins/dev-bridge` in the beta client (951-1).
- *dev-bridge eval, 2026-10-26*: read-only snippets sent with `rsdev.py eval` (bridge sessions
  2cadd0be39 and 5082c0e41d, beta client 951-1), to check the test harness's guesses
  ([testing.md](testing.md#fidelity-ledger)). The probe sources aren't kept; each finding says what
  was called.
- *rsdev shot, 2026-10-26*: probing the client's window on X11 (i3, one 3840x2160 VMware monitor).
- *walkable-flood, 2026-10-20*: `plugins/walkable-flood` (deleted; commit `0bb7291`) never ran in the
  client with results recorded, so facts so tagged are the plugin's assumptions or stub/docs
  readings, marked open or *(stub)*.
- *chore probe, 2026-10-30*: the user did chores on their main account on the plugin dev server
  while the bridge forwarded `VarTransmit`, `InventoryUpdated`, system chat and menu picks (bridge
  session 1b4060db2c), and `rsdev.py eval` read vars and inventories. The chore-by-chore results
  are in [plans/chore-tracker.md](plans/chore-tracker.md#probed-2026-10-30-signals-found-not-built-yet).

## Reading the type notation

The official reference annotates Lua with pseudo-types:

| Notation | Meaning |
|---|---|
| `function T:M(x: Float)` | Method, call with a colon: `obj:M(0.8)` |
| `function T.f(name: String?) -> T?` | Static function, call with a dot. `?` = optional/nullable |
| `{ String -> Int }` | Dictionary table |
| `[String]` | Array table |
| `Uint8`, `Int32`, … | Plain Lua numbers; the size only shows the valid range |
| `A \| B` | Either type |
| `Base -> Derived` | Inheritance (e.g. `ui.Component -> ui.Button`); a Derived works wherever a Base is expected |
| `Type<T>` | Generic placeholder; the doc explains which concrete types apply |

## API map

| Area | Contents |
|---|---|
| **Core** (globals) | `print`, `log`, `formatStr` (`{}` placeholders), `ExecuteConsoleCommand` |
| Core modules | `Event` (subscriptions), `Plugin` (permissions, urls, resources), `PersistentDB`, `HTTPRequest`, `ClientOptions`, `Keyboard`, `Mouse` |
| **Game** | `Player` (self: levels, XP, run energy, weight, combat level, entity), `World`, `Camera`, `Chat`, `Inventory`, `GrandExchange`, `MiniMenu`, `ScreenConvert` (world↔screen), `Shapes`/`ShapeList` (world-space drawing), `CoordGrid`/`CoordFine` |
| Game configs (`config.*`) | Static definitions: `NPC`, `Obj`, `Loc`, `Inv`, `Quest`, `Achievement`, `Enum`, `Struct`, `Param`, `Var*`, `Seq`, `SpotAnim`, `Font`, `Hitmark`, `Headbar`, `Cursor`, `MapElement`, `DBTable`/`DBRow`, `BaseAnimSet` |
| Game entities | Live instances near the player: `NPCEntity`, `PlayerEntity`, `LocEntity`, `ObjStackEntity` |
| Game lists | Entity queries: `NPCList`, `PlayerList`, `LocList`, `ObjStackList` (`All`, `ByName`, `ByDistance`, `ByConfig`, `ByConfigID`, `ByUID`, `Filter`, …) |
| **Math** | `Vector2/3/4`, `Quaternion`, `Matrix33`, `Rect`, `AABB`, `lerp`, `slerp`, `clamp`, `random` |
| **UI** (`ui.*`) | Component tree, `ui.Interfaces`, style sheets, layout components (`Layer`, `Panel`, `GroupBox`, `Grid`, `PagedLayer`, …), decorative components (`Text`, `Rectangle`, `Sprite`, `Line`, `Canvas`, `Model`, `ModelGroup`, `RadialProgressOverlay`), interactive components (`Button`, `Check`, `Slider`, `InputField`, `List`, `ComboField`, `RadioGroup`, `Carousel`) |
| **Audio** (`audio.*`) | `audio.Play`, `audio.Stop`, sound instances, buses, emitter shapes |
| IDs (`id.*`) | Built-in IDs, e.g. `id.Component.*`, `id.StyleSheet.*`, `id.Font.*` |

## Configs vs entities

- A **config** is static game data that's always available, whatever your location. Access it by
  name: `config.NPC.DOG_STRAY.name`, `.gridSize`, `config.Obj.LOGS`, `config.Inv.BANK`. To find
  names, use the console command `pan <Type>`. Display names and config names often differ, and
  several configs can share a display name (`DOG_STRAY`, `DOG_STRAY2`).
- **An unknown name reads as absent, without raising**: `config.Inv.NOPE`, `config.Obj.NOPE` and
  `var.VarPlayer.NOPE` read nil, but `id.Sprite.NOPE` and `id.Obj.NOPE` read the number -1, not
  nil, so test an `id.*` read for -1. Known names read as usual (`config.Inv.FISHINGSHOP`,
  `id.Sprite.XP_TOKEN_0`, `id.Obj.POP_LOG`). A plugin needs no `pcall` around such a read.
  (dev-bridge eval, 2026-10-31)
- An **entity** is a live instance the client is currently receiving from the server: only things
  near the player. Entities have position, facing, etc., and `.config` points back to the config.
  They come and go as you move.
- Get entities through **lists**, e.g. `NPCList.ByName("Stray dog")`. It always returns a table,
  possibly empty. If several configs share a display name, query by name to catch them all.
- Your own player has the richest API: `Player.GetLevelGameplay(SkillType.ATTACK)` (boosted or
  drained level), XP getters, etc. Other players (`PlayerList`) expose less. **Plugins may not
  export any information about other players.**

## Vars

- `var.VarPlayer.<NAME>.value` holds server-side persistent progress (quests, codex unlocks, POH
  furniture, collection log…).
- `var.VarClient.<NAME>.value` holds client-side state (some combat state, UI layout, cooldowns…).
- VarBits are packed sub-fields of a VarPlayer.
- Find names with `pan VarPlayer` / `pan VarClient`. The `VarTransmit` event fires whenever the
  server sends a var update (`ev.var`, `ev.oldValue`, `ev.newValue`). The value may not have
  actually changed.
- `pairs(id.VarPlayer)` works, but the integer ID isn't in the value slot (passing the values to
  `FromID` fails with "expected number, received string"). Scanning IDs -70000..20000 found
  ~62k VarPlayer vars (VarBits included) and ~7.8k VarClient vars.
- Reading `.value` on a var whose ValueType isn't in the documented list (seen: 49, 61, 71, 126)
  logs `Failed to convert a config value to a plugin value: invalid ValueType (n)` but doesn't
  raise an error.
- **VarTransmit values are integers** for BOOLEAN vars (0/1) and for config-typed ones
  (`COORDGRID`, `INV`, `OBJ`, `ACHIEVEMENT`, `COMPONENT`...), whatever `.value` gives for them. (first recording, 2026-10-25)
- **`VarTransmit` fires with `oldValue == newValue`** (`FARMING_CURRENT_PATCH` 161 -> 161,
  `DOUBLEXP_PERM1` 0 -> 0). (dev-bridge, 2026-10-26)
- **A VarTransmit names either the base var or the one VarBit that changed.** In the var-dump
  change log (2026-10-25, `dumps/var-dump/changes.jsonl`) claiming Bert's sand sent the base `HANDSAND_BUCKETS` (2801; 0 -> 1 -> 3,
  and its VarBit `HANDSAND_BUCKETS_CLAIMED_TODAY` then read 1), while chopping sent the VarBit
  `LEAGUE_TASK_PROGRESS_CHOP_ANY` (a VarBit of `LEAGUE_TASK_PROGRESS_BASE_3`) by name with its own field values (0 -> 1 -> 2 -> 3 -> 4), and
  `DNDTRACKER_MINS_TO_DAY_END` came the same way. The same base var can arrive under either:
  `TOPLEVEL_V2_PARENT_VARP_1` came under its own name and two of its VarBits' names in one
  session. So a plugin watching a VarBit maps `ev.var` to its base
  (`ev.var.isVarBit and ev.var.baseVar or ev.var`) and re-reads the VarBits it watches of that
  base (find them in `docs/vars/vars.csv` by `base_var`).
- **Chore claim flags move on the claim and come back at login** (var-dump change log and
  relog snapshot, 2026-10-25). Each went 0 -> 1 as the user claimed, and still read 1 in the
  snapshot taken after a relog, so the server sends them in the login burst:
  `HANDSAND_BUCKETS_CLAIMED_TODAY` (bit 1 of `HANDSAND_BUCKETS`, Bert's sand),
  `ATSEER_REWARD_FLAX_GIVEN_TODAY` (bit 30 of `ATSEER_TASK4`, Geoffrey's flax), `ATAR_ESS_USED`
  (bit 22 of `ATAR_TASKS_4`, Cromperty's essence) and `ATELF_DAILY_LOGS_CLAIMED` (bit 14 of
  `ATELF_MAIN4`, Coeden's logs). Whether a flag clears at the daily reset or only on the next
  claim is unconfirmed. Chore Tracker's `data/vars.lua` is built on these.
- **A daily challenge counts as claimed, not finished, in `CHALLENGE_TOTAL_COMPLETED`**
  (var-dump change logs, 2026-10-25). Finishing a challenge raises
  `INTERN_NOTES_DAILY_CHALLENGES_COMPLETE` (bits 0-2 of `INTERN_NOTES_TEMP_1`), which counts
  finished but unclaimed challenges. Claiming all three at once in the challenge window (ticks
  2221-2222):
  - the unclaimed count fell 3 -> 1 -> 0;
  - `CHALLENGE_TOTAL_COMPLETED` (bits 0-13 of `CHALLENGE_BI_1`) went 0 -> 2 -> 3;
  - `CHEEVO_DAILY_CHALLENGE_COUNTER` (bits 19-22 of `CHEEVO_MISC_DATA_PERM15`) went 0 -> 1 (the
    user reads it as the streak);
  - `CHEEVO_DAILY_CHALLENGE_LAST_RUNEDAY` (bits 16-31 of `CHEEVO_MISC_DATA_PERM17`) became
    today's RuneDay, 9006;
  - all three `CHALLENGE_CURRENT_n` slots cleared and were refilled at once with a new set
    (`CHALLENGE_SHUFFLE_DONE` 0 -> 2 -> 3).

  Whether `CHALLENGE_TOTAL_COMPLETED` resets daily or is a lifetime total is unknown. A
  challenge's reward can be claimed as soon as that one challenge is finished (the user,
  2026-10-25). Chore Tracker ticks the Daily Challenge on any rise of
  `CHALLENGE_TOTAL_COMPLETED`.
- **Dream of Iaia vars, read live 2026-10-31**, validated against the chores by the user:
  70 workers on `DINO_BASE_CAMP_WORKER_ASSIGNED_STONE`, 0 on the other five; `DINO_BASE_CAMP_RESOURCE_*`
  wood 14400, vines 20400, leaves 19600, pelts 12000, stone 93800, clay 14000;
  `QUEST_EGW_FINALE_REWARD_STATION_XP_*` Construction 150000, the other five 75000. Resource ->
  station (runescape.wiki Dream_of_Iaia): WOOD -> FLETCHING, VINES -> HUNTER, LEAVES -> HERBLORE,
  PELTS -> CRAFTING, STONE -> CONSTRUCTION, CLAY -> FISHING. Chore Tracker ticks the chores when
  every worked resource or station has fallen to 0. Confirmed in the beta client the same day:
  converting all the stone ticked Resources, and training the Construction station's XP to 0
  ticked XP.
- **`SHOP_MULTIPURPOSE` wasn't sent during a purchase at Arhein's shop** (2026-10-25, with
  `SHOP` = 47, `ARHEINSTORE`), so its `SHOP_SEAWEED_BOUGHT` / `SHOP_PINEAPPLES_BOUGHT` counters
  can't be seen to move on a purchase; the shop's inventory can.
- **BOOLEAN vars read mostly `true` (unconfirmed).** 133 of 148 were `true`, including
  implausible ones like `HOUSE_CURRENTLY_PEEKING`, so unset may come back as `true`. Check
  against a BOOLEAN you can toggle before trusting one.
- **Some vars are only brought up to date when you visit.** Arriving at Miscellania changed
  `MISC_APPROVAL` 41 -> 32 and `MISC_COFFERS` 1275000 -> 825000. Both had been sent at login
  but were out of date. The Player Owned Farm's paddock slot codes (`POF_ANIMAL_PADDOCK_*_SLOT_*`)
  arrived only when the user reached the farm. A rule on such a var is right only as of the last visit. (chore probe, 2026-10-30)
- **Some vars hold an epoch-minute time**, the clock var's unit: `MISC_LAST_COLLECTION` read
  29806927 (2026-09-03 06:07 UTC, the user's "8 weeks ago") and became the minute of the
  collect. `POF_LAST_TIME` is one too, though it isn't the last visit. (chore probe, 2026-10-30)
- **Some timers are sent once and not kept current.** `SNIPER_BLOODTREE_TIME_<n>` (minutes,
  capped at 360) arrived at login and stayed put for 70 minutes until the tree was felled. (chore probe, 2026-10-30)
- **Changing the graphics setting reloads the game** (`GameStateChanged` 30 -> 35 -> 30) and
  resends every var with `oldValue` 0: hundreds of `0 -> X` transmits. Chore-tracker compares
  its own last read, not `oldValue`, so the burst ticks nothing unless a var also *reads* 0
  partway through the reload. Unchecked; its 10 s settle covers only a load or a character
  switch. (chore probe, 2026-10-30)
- **Game interfaces can't be read.** The API has nothing for another interface's components.
  An open window shows only through the vars it sets: the farm's Check and pen windows fill in
  `POF_ANIMAL_CHECK_SLOT/_PADDOCK/_OBJECT/_TRAIT_1..3`, and the Invention machine window fills in
  `INVENT_MACHINE_ID`, `_AMOUNT_STORED` and `_BATCHES_STORED`, all for the selected
  item only. (chore probe, 2026-10-30)
- **Farming patch-stage VarBits look region-relative**, as in OSRS: `FARMING_HERB_VARBIT_3`
  and `FARMING_CURRENT_PATCH` change meaning as the player moves. `FARMING_SEEDS_PLANTED_HERB_PATCH_<n>`
  (on `DESERT_FARM_PERM_*`) are per patch: clearing a patch set it 7 -> 0, planting 0 -> 7. (chore probe, 2026-10-30)

## Coordinates

- `CoordGrid` is a tile coordinate made of five numbers: `level, mapSquareX, mapSquareZ,
  localTileX, localTileZ` (written `0,50,50,9,56`). A map square (the "chunk") is 64×64 tiles.
  `tostring(coordGrid)` gives that comma form, which `!tele` accepts.
- `CoordFine` is a sub-tile world position. Convert between the two with
  `ToCoordFine`/`ToCoordGrid`.
- Instances have their own coordinates and map back to source tiles
  (`World.GetRegionSourceForCoordGrid`, `!getcoord` shows both).
- `ScreenConvert` converts between world coordinates and screen positions, for overlays.
- **A `CoordGrid` is a snapshot, and `tostring` of one is its value**,
  `level,mapSquareX,mapSquareZ,localX,localZ` (`0,50,50,25,23`). One read before the player walked
  still held the old tile afterwards, and wasn't `==` a fresh one. CoordGrids also support `<`. Two
  reads of one tile are `==` but not `rawequal` (see "API objects"). (dev-bridge eval, 2026-10-26)

## Locs, shapes and walkability

These facts come from `plugins/walkable-flood`, a deleted loc-based flood-fill experiment that
never ran with results recorded (recover it with
`git show b139b3b^:plugins/walkable-flood/main.lua`). Every client-behaviour claim below is open;
*(stub)* marks stub readings. Run "Open checks" before relying on any of it.

- **No walkability getter.** The stubs have no collision-flag or walkability member, so terrain
  blocking (water, cliffs, some map edges: map tile flags, not locs) is invisible from locs alone.
  (stub) By its own choice the experiment also ignored other levels, NPCs and players, and
  approximated walkability from `LocType.blockWalk`, `LocEntity.shapeType`,
  `LocEntity.rotationType`, `width`/`length` and `coordGrid`. (walkable-flood, 2026-10-20, open)
- **`LocList.ByDistance(coordGrid, range, sameLevel)`** lists nearby locs. The plugin searched
  `ceil(32 * 1.5)` tiles for a 65×65-tile square, in case distance is a straight line (corners are
  1.41× the radius away) and to catch big locs whose anchor is just outside. Whether `range` is
  Chebyshev or Euclidean is **open**. (stub for the signature; the range choice is walkable-flood,
  2026-10-20, open)
- **`LocShapeType` values 0-24** (from the docs, `game/config/loctype`): 0 WALL_STRAIGHT,
  1 WALL_DIAGONALCORNER, 2 WALL_L, 3 WALL_SQUARECORNER, 4 WALLDECOR_STRAIGHT_NOOFFSET,
  5 WALLDECOR_STRAIGHT_OFFSET, 6 WALLDECOR_DIAGONAL_OFFSET, 7 WALLDECOR_DIAGONAL_NOOFFSET,
  8 WALLDECOR_DIAGONAL_BOTH, 9 WALL_DIAGONAL, 10 CENTREPIECE_STRAIGHT, 11 CENTREPIECE_DIAGONAL,
  12 ROOF_STRAIGHT, 13 ROOF_DIAGONAL_WITH_ROOFEDGE, 14 ROOF_DIAGONAL, 15 ROOF_L_CONCAVE,
  16 ROOF_L_CONVEX, 17 ROOF_FLAT, 18 ROOFEDGE_STRAIGHT, 19 ROOFEDGE_DIAGONALCORNER,
  20 ROOFEDGE_L, 21 ROOFEDGE_SQUARECORNER, 22 GROUNDDECOR, 23 WALL_L_ALT,
  24 WALLDECOR_DIAGONAL_BOTH_ALT. (stub)
- **Which shapes block (assumed, old-engine rules).** Shapes 9 (diagonal wall), 10-11
  (centrepieces: trees, tables, rocks) and 12-21 (roofs) block every tile of their
  `width × length` footprint (`width`/`length` are already rotated). Straight walls (0) block one
  side of their tile; L walls (2, 23) block two; the neighbouring tile gets the matching side so the
  wall blocks both ways. Wall decoration never blocks. Corner pillars (1, 3) only block diagonal
  steps and a diagonal step needs both straight routes clear, so a fill using straight steps
  reaches the same tiles. Only locs whose `config.blockWalk` is true were applied. (walkable-flood,
  2026-10-20, open)
- **Footprint anchor.** The plugin assumed `loc.coordGrid` is the **south-west** tile of a
  multi-tile footprint. It logged `anchor check:` lines (size, `coordGrid`, `position/512`) to test
  this, but no output was recorded. (walkable-flood, 2026-10-20, open)
- **Rotation to wall side** (old-engine convention, open in RS3). Straight walls by
  `rotationType`: 0 = W, 1 = N, 2 = E, 3 = S. L walls: 0 = W+N, 1 = N+E, 2 = E+S, 3 = S+W. Z points
  north. A wrong side on a fence means this table is off. (walkable-flood, 2026-10-20, open)
- **Ground decoration (shape 22).** Most grass, flowers and rugs report `config.blockWalk = true`
  although the player walks over them; in the old engine only decoration that explicitly blocks
  does, and the API cannot tell the two apart. The plugin treated all of it as non-blocking
  (`GROUNDDECOR_BLOCKS = false`). Whether the `blockWalk` reading is true in RS3 is **open**.
  (walkable-flood, 2026-10-20, open)
- **Doors.** Whether a closed door is a `WALL_STRAIGHT` with `blockWalk` (and flips when opened)
  was never checked. (walkable-flood, 2026-10-20, open)
- **`World.GetGroundHeight(level, x, z[, heightOffsetType])`** takes fine coordinates (512 = one
  tile) and returns `height, ok`, with height -1 when unavailable; the plugin used `ok == false`
  as "map not loaded here" and stopped the fill at the edge of the loaded area. That a failed call
  really means "not loaded" is **open**. Heights are per tile corner, so overlay quads followed
  the slope. (stub for the signature; walkable-flood, 2026-10-20, open)
- **Overlay drawing.** One `ShapeData` holds `positions` (`Vector3`), `rgba` (`0xRRGGBBAA`),
  `tris` and `lines` (0-based vertex indices); `ShapeList.CreateInstance(name)` plus
  `instance:SetShapeData(data)` attaches it (returns false on failure; destroy the instance then),
  and instances have `ignoreDepth`, `lineWidth` and `visible` fields. (stub) The experiment put the
  fill 16 fine units above the ground and wall lines 48 above, and split tiles into instances of
  1000 items; whether the lifts stop flicker into terrain and whether the split is needed is
  unconfirmed, as is whether it rendered as intended. (walkable-flood, 2026-10-20, open)
- **Slicing.** The experiment spread loc application, flood and drawing over `Logic` ticks at
  `WORK_PER_TICK` = 500 units each, because of the 1000 ms Lua-call limit (see "Runtime limits
  we've hit"). Whether 500 units per tick is cheap enough is unconfirmed; it logged elapsed ticks
  per run. (walkable-flood, 2026-10-20, open)
- **Moderation.** Automatically showing walkable areas is close to the guidelines' ban on
  "automatically showing where to stand or move" ([guidelines.md](guidelines.md)), so it was dev
  only. Any player-facing version needs a moderation-friendly framing first.

### Open checks (the experiment's validation table, never run)

| Where | Look for | If it's wrong |
|---|---|---|
| A fenced field (Lumbridge sheep/cow pens) | Wall lines along the fence, fill stops at it | Wrong side: the rotation-to-side table is off |
| A building with doors | Closed door is a wall; opened and recomputed, the fill flows in | Doors may not be `WALL_STRAIGHT` or not set `blockWalk` |
| A big object (furnace, large rock, 2×2+ table) | Blocked area is exactly its footprint | Offset by a tile: `coordGrid` isn't the south-west tile |
| Grass/flower patches | Fill covers them | If you really can't walk there, ground decoration blocks |
| A riverbank or lake | Fill spills onto water | Expected: terrain blocking isn't visible from locs |
| A tile the game won't walk to but the fill reaches | Inspect the tile (loc name, ID, shape, rotation, ground height) | Shows what kind of blocker is missing |

## Events

- `Event.<Name>.Subscribe("uniqueName", callback)` and `Event.<Name>.Unsubscribe("uniqueName")`.
  The name identifies the subscription so you can replace or remove it. **Call `Unsubscribe`
  directly, never pass it straight to `pcall` or `xpcall`**: every client abort seen from it
  used that form (see "Runtime limits we've hit"). Subscribing at load and unsubscribing in
  `PluginShutdown` is the plain pattern, and safe even when the plugin's own `prl` from `Logic`
  triggers the shutdown. A `Subscribe` inside a callback works too (it delivers), and so did a
  direct `Unsubscribe` of it from inside `Logic`.
- The callback gets a **payload** table, whose fields depend on the event.
- Useful events: `ServerLogic` (after each server packet, about once per 0.6 s tick, no
  payload), `Logic` (fixed 50 Hz client tick, `ev.logicTick`), `Draw` (every rendered frame,
  `ev.timeDeltaSecs`), `NPCEntityAdded/Removed` (`ev.npcEntity`), `PlayerEntityAdded/Removed`,
  `ObjStackEntityAdded/Removed/Changed`, `MiniMenuEntrySelected` (`ev.entry`, including
  left-clicks; `ev.entry.npcData` is nil unless the target is an NPC), `ChatMessage`,
  `VarTransmit`, `KeyDown/KeyUp/KeyTyped`, `WindowFocusChanged`, `OptionalDependencyChanged`,
  `OptionalPermissionChanged`.
- `*Added` events only fire for **new** arrivals. They won't report entities that were already
  nearby when the plugin enabled, so scan the list once at startup too.
- Check optional payload fields for `nil` before indexing into them. An unchecked nil index
  crashes the plugin's callback.
- **Tick rates.** `Logic` runs at 50 Hz (about 3000 ticks per clock minute). `ServerLogic` came
  30 Logic ticks apart two times in three, anywhere from 16 to 82, and twice two arrived in one
  tick. (first recording, 2026-10-25)
- **A wall clock without permissions:** `var.VarPlayer.CLOCK_TIME_DATE_MINUTES.value` is minutes
  since the Unix epoch (29881543 = 2026-10-25 01:43 UTC), and a VarTransmit fires as it ticks
  over. `ChatMessage.timestamp` is unix seconds. (first recording, 2026-10-25)
- **Subscribing a name twice keeps the first** (real `ServerLogic` subscriptions made from
  `Logic`, session 7bcb60d109, with the user's approval). `rA` and `rB` ran in the order made (`A B`).
  `Subscribe("rA", newFn)` again raised nothing and changed nothing: the old callback kept
  running in its place, and the new one never ran. That contradicts core/events.html#overview,
  which says the name is replaced. To replace a callback, `Unsubscribe` it first; the new one
  then runs last (`Unsubscribe("rA")` then `Subscribe("rA", A3)` gave `B A3`). `Unsubscribe` returns true when it removed the name and false when there was
  none. A subscriber that unsubscribes a later one of the same event during a dispatch (`rC`
  removing `rD`, so no `D3`) stops it being called in that same pass, and the client stayed up.
  Probed 2026-10-30: a subscriber added during a dispatch first runs on the next; an
  `Unsubscribe` and `Subscribe` of one name inside a dispatch of the same event loses the
  subscription (see "Dispatch edge cases" below). (First part: dev-bridge eval, 2026-10-26.)
- **`Event.<X>.Subscribe` from inside a `Logic` callback works** (`Event.VarTransmit.Subscribe`
  from an eval snippet: the probe was called 6 times over about 70 s and the client stayed up;
  an `Event.Logic.Subscribe` probe made the same way counted 544 ticks, emitting every 50). And
  it can be removed: a direct `Event.VarTransmit.Unsubscribe` of one, called from inside
  `Logic`, left the client up (session ff92400823). (dev-bridge, 2026-10-26)
- **A lazy `ServerLogic` probe subscribed from the bridge's own `Logic` tick works**
  (2026-10-26, commit a0df251): it went live (6 calls in 3 s, about one per 0.6 s server tick)
  and emitted. Removing it, by a direct `Unsubscribe` of the runtime subscription from inside
  `Logic` on the next tick, stopped it and the client stayed up. `eval --reset` with a lazy probe
  live kept the session and cleared the scratch environment (`x` and `sl2` read nil afterwards).
  `exec "prl dev-bridge"` with a lazy probe live reloaded cleanly onto a new session
  (cbb88037d4): the self-reload that aborted the client seven times with the `pcall` form (see "Runtime limits we've hit").
- **A `MiniMenuEntry` payload** serialises (`tostring`) as `sol.jag::MiniMenuEntry`; read its
  fields by name. (dev-bridge, 2026-10-26)
- **Dispatch edge cases** (dev-bridge eval, 2026-10-30, beta 951-1, session 38ac205778; real
  `ServerLogic` subscriptions). Within a dispatch of an event, a subscriber added is first called
  on the next dispatch, and an `Unsubscribe` of that same event is deferred to the end of the
  dispatch. The unsubscribed callback is skipped for the rest of the pass at once (as `rD` is in
  "Subscribing a name twice keeps the first" above), but its name stays registered until the
  dispatch ends, so a `Subscribe` of the same name meanwhile does nothing and the name is gone
  afterwards (the new callback never runs and a later `Unsubscribe` returns false). The same pair
  made from another event's dispatch keeps the subscription, placed last. Calls seen:
  `A1 B1 A2 N2 A3 N3 ...` (`N`, subscribed by `A` in pass 1, first ran in pass 2); `A`
  unsubscribing and resubscribing `d2B` in pass 2 meant the new `B'` never ran in passes 2-17 and
  the cleanup's `Unsubscribe('d2B')` returned false. The deferral is the likely mechanism, not
  confirmed.
- **A subscriber that reloads its own plugin mid-dispatch** (`ExecuteConsoleCommand("prl <self>")`;
  dev-bridge eval, 2026-10-30, beta 951-1, session 38ac205778): the old instance's
  `PluginShutdown` and the new instance's load both run synchronously inside that call, the
  subscriber's code after the call still runs, and the old instance's later subscribers of that
  dispatch are not called. `ServerLogic` subscriber `A` called `prl` on its own plugin; it saw
  `shutdown` true afterwards and the old instance's later `B` was not called.
- **A `ui.Layer` listener removed during a fire of its hook is not called later in that fire; one
  added during it first runs on the next fire** (dev-bridge eval, 2026-10-30, beta 951-1, session
  38ac205778). In one `ONCLICK` fire `L1` unsubscribed `L2` (later in order) and subscribed `L3`;
  fire 1 ran only `L1`, fire 2 ran `L1` then `L3` (`L1.1 L1.2 L3.2`).

## UI

- The UI is a **component tree**. Every plugin component needs a parent. The usual root is the
  plugin layer:
  ```lua
  local root = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
  local box = ui.GroupBox.new(root)
  ```
  Children move with their parent.
- **Layout** components (`GroupBox`, `Panel`, `Layer`, `Grid`…) can have children but offer little
  styling. **Decorative** components (`Rectangle`, `Text`, `Sprite`…) offer more styling but
  can't have children. **Interactive** components (`Button`, `Slider`…) take input.
- Gotchas that make things invisible:
  - Components that use style sheets draw nothing until you set `stylesheetID`
    (e.g. `id.StyleSheet.DEFAULT`, `id.StyleSheet.BUTTON_DEFAULT`). A style sheet only applies
    to a matching component type.
  - `ui.Text` needs a `font` (e.g. `id.Font.MUSEO_SANS_15PT_REGULAR`).
  - `ui.Rectangle` draws an outline unless `fill = true`. Colours are `Vector4` RGBA in 0–1.
- Sizing and positioning: `SetSize(w, h)` / `SetPos(x, y)` take pixels. The 4-argument forms
  `SetSize(px, py, relW, relH)` / `SetPos(px, py, relX, relY)` add a fraction of the parent's
  size (`SetPos(0,0,0.6,0.4)` = 60 % across, 40 % down).
- `SetPos` takes floats where the stub says `Int`, and rounds them to the nearest integer, halves
  away from zero (dev-bridge eval, 2026-10-29, on a `ui.Layer.new` of the plugin layer, 1916x2121).
  `l:SetPos(-150.0, -46.0, 0.5, 1/3)` raised nothing, and `l.x, l.y` then read the anchored position
  808, 661 as integers (0.5 * 1916 - 150; 2121 / 3 - 46), not the offset passed.
  `l:SetPos(-150.5, -46.25)` also raised nothing and read -151, -46. Pass integers anyway
  (`//`, not `/`).
- UI input uses **component hooks**, separate from `Event`:
  `button:Subscribe(ui.Hook.ONBUTTONPRESSED, fn)`, `button:Unsubscribe(ui.Hook.ONBUTTONPRESSED)`.
- **Pointer hooks on a plain `ui.Layer`** (`clickthrough = false`; the Row Probe, user-driven in
  the beta client, 2026-10-29). Ticks below are `Event.Logic` ticks, about 20 ms each.
  - A click: `ONCLICK` and the first `ONHOLD` on the same tick, `ONRELEASE` 1-3 ticks later. A
    press held still gets `ONHOLD` every tick (42 in 42 ticks). The callbacks get the press
    point in the layer's own coordinates.
  - A click on a `clickthrough = true` child of the row (an icon sprite, a label) reaches the
    row layer under it as the row's own `ONCLICK`, with the row's local coordinates (icon
    click at local (30, 19), label clicks at x 100-262).
  - **A click whose press and release land in one tick arrives backwards**: `ONRELEASE` and
    then `ONCLICK`, on the same tick, with no `ONHOLD`. Code that acts on "a press, then its
    release" misses these clicks; acting on `ONCLICK` (as PrettyUI does) catches every one.
  - `ONRELEASE` arrived at the pressed layer with coordinates outside it (y 37-45 on a 36-high
    row). The earlier note that `ONHOLD` keeps coming after the pointer leaves the pressed layer
    did not hold in the 2026-10-29 drag probes (next bullet), and this probe did not record
    whether the button was still down at those releases.
  - `Mouse.GetPosition()` tracks while a press is held, and equals the layer's global origin
    plus the hook's x, y (at interface scale 100, the client option's percentage).
  - **The native drag hooks never fired.** No `ONDRAG` or `ONDRAGCOMPLETE` on any probe row,
    including one with `dragDelayTicks = 0, deadZone = 0`, dragged 40 px. Build a drag from
    `ONCLICK`/`ONHOLD`/`ONRELEASE` and the mouse position, as PrettyUI's own drags do.
  - `component.dragConfig` is read-only ("sol: cannot write to a readonly property"); set its
    fields in place (`layer.dragConfig.deadZone = 10`), which reads back. A new layer's is
    `0, 0, 0`.
- **A hook listener that returns nothing stops the ones after it** (hook probe, beta client, dev
  bridge, user hovering, 2026-10-30). The stub says an omitted return counts as true; it
  doesn't. Four layers, each with `ONMOUSEOVER` listeners under the default id and a named id
  (`"probe"`), in subscription order:
  - default returning nothing, then named: only the default ran;
  - default returning `true`, then named: both ran;
  - named alone: it ran;
  - named returning `true`, then default returning nothing: both ran.

  So return `true` from a listener whenever another may follow it on the same hook. PrettyUI
  1.2.0's `Tooltip.attach` subscribes `ONMOUSEOVER`/`ONMOUSELEAVE` under `"prettyui_tooltip"`
  after any listener the plugin made first: chore-tracker's row hover listeners returned nothing,
  and no row tooltip showed until they returned `true`.
- **Pressing and dragging a plain `ui.Layer`** (drag probes v1-v3, user-driven in the beta
  client through the dev bridge, 2026-10-29).
  - `ONHOLD` fires once per Logic tick while the button is down. Its x, y are the pointer in
    the pressed layer's own coordinates, relative to where the layer is at that moment: move
    the layer and the next sample is relative to its new place. v1 moved a bar on each
    `ONHOLD` by the hook y less the grab y; the samples alternated between y 18 (the grab
    point, once the bar had caught up) and other values when the mouse moved, and the mouse
    position itself changed only every other `ONHOLD`. `Mouse.GetPosition().y` (floats, e.g.
    703.0) equalled the bar's global y plus the hook y.
  - **A press ends as soon as the pointer leaves the pressed layer's hit area**, which is the
    layer's own rect clipped by every ancestor's rect: `ONRELEASE` arrives with the button
    still held, and no more `ONHOLD`. v1: the 28-high bar got `ONRELEASE` at y 32 when one
    sample moved the pointer 14 px past it ("as soon as the mouse leaves the drag bar it stops
    dragging"). v2: a pressed layer inside a 320x400 panel, stretched far past the panel on
    its first `ONHOLD`, kept getting `ONHOLD` inside the panel but got `ONRELEASE` when the
    pointer crossed the panel's top edge (mouse y 490, panel top 500), button still held.
  - **What holds the press** (v3, user-confirmed): make the pressed layer a direct child of
    the plugin layer, docked over the visual at rest. On its first `ONHOLD` stretch it over the
    whole plugin layer (`SetPos(0, 0)`, `SetSize(p.width, p.height)`, `p` the plugin layer) and
    `MoveToFront()` it. It then gets `ONHOLD` until the real release, overshoots and re-entries
    included, and its hook y equalled the pointer's y in plugin-layer space and
    `Mouse.GetPosition().y` at interface scale 100 (`game.options.InterfaceScale.setting`
    read 100); other interface scales are unprobed.
    Dock it back on `ONRELEASE`. This is PrettyUI 1.2.0's scroll-thumb drag
    (`src/core/scroll.lua`, `thumbDrag`: "The first ONHOLD expands this layer across the
    overlay parent so later events continue outside the scrollbar").
  - **Holding and leaving the client** (chore-tracker grip drag, user-driven in the beta
    client, 2026-10-29). A drag held still for several seconds is kept: `ONHOLD` keeps coming.
    Dragging the pointer out of the client window with the button held ends the drag (the row
    dropped where it was shown). Whether leaving the client sends `ONRELEASE` or only stops
    `ONHOLD` was not determined; the plugin drops a drag after 10 Logic ticks without `ONHOLD`.
  - **Keeping plugin-layer press targets over a PrettyUI window** (chore-tracker grips, beta
    client, dev bridge + user, 2026-10-29).
    - After a collapse and expand the 15 shown targets were docked correctly (16x16 at the
      grips, `hidden` false) yet took no pointer. The expand had called `MoveToFront()` on each
      target while they were still hidden from the collapse, and unhid them after. Calling
      `MoveToFront()` on the now-shown targets from the bridge made them work again: **a
      `MoveToFront()` on a hidden component has no lasting effect on the stacking.**
    - Pressing or dragging the window's title bar buried the targets again: PrettyUI 1.2.0's
      title-bar `ONCLICK` does `self.root:MoveToFront()`. PrettyUI raises the window root only
      on creation, `Show()` and that title-bar `ONCLICK` (`src/window.lua`), but a resize's
      press calls `Show()` (`Resize.new`'s `onBegin`), so it raises the root too; tooltips raise
      only their own layers.
    - Raising every shown target every Logic tick broke the grips: the cursor flickered between
      PUSH and the hand about once a second and drags failed. Raising every 25 ticks, skipped
      while any target was hovered or clicked, worked without flicker but sometimes delayed the
      PUSH cursor on hover (a raise as the pointer arrived). So **`MoveToFront()` on a layer
      resets its hover state**.
    - Watching the title-bar layer's `isClicked` (PrettyUI's internal `win.titleDrag`) each
      Logic tick and raising the shown targets once when it went true → false worked for title
      drags (grips usable right after, no hover delay; user-confirmed), but **missed quick
      clicks**: the user found "clicking the title bar breaks dragging, moving the window with
      the titlebar is fine, closing and expanding is fine".
    - 2026-10-29, beta client, dev bridge + user: a quick click on the title bar buries the
      shown targets under the window (re-raising them from the bridge made them work again); a
      click on a row does not. Subscriptions under a named hook id (`"gripProbe"`) for
      `ONCLICK` and `ONRELEASE` on the title-drag layer, and `ONCLICK` on the window root,
      logged nothing across several quick title clicks, a click on an empty part of the window
      and row clicks, though an earlier named `ONCLICK` probe on the title layer fired twice
      during title drags. PrettyUI's own title handlers are subscribed under the default id.
      The plugin registers a never-shown sentinel layer with the window through PrettyUI's
      internal `win:_RegisterOverlay(component, isVisible, layout)`, whose `layout` only flags
      that the window synced its overlays, and raises the shown targets once afterwards. 1.2.0
      syncs (`_SyncOverlays`) on `Show()`, at the end of every title-bar press (`stopDrag`, on
      `ONRELEASE`), on every frame a resize or a scrollbar-thumb drag moves, on every scroll
      step (`SetScrollPosition`) and when the client window is resized; a title-bar drag syncs
      only as it ends. A one-tick click arrives release-first (above), so its sync comes before
      its raise, but both land before the next Logic tick. Unregister the sentinel
      (`_UnregisterOverlay`) before destroying it: `_SyncOverlays` skips an overlay only when
      its interface is gone, and a plugin-layer component shares the plugin layer's.
    - 2026-10-29, beta client, user: with the raise on the Logic tick after each sync, quick
      title clicks, a title drag, collapse and expand, a window resize and wheel scrolling were
      each followed by a working grip hover (PUSH) and drag, with no flicker noticed. The
      earlier trouble with resizing (handles hard to trigger, a resize stuck with its outline
      showing) was this burial: a resize's press calls `Show()`, which raises the root over the
      targets. Since a resize or a wheel spin syncs tick after tick, the raise now waits for the
      first Logic tick with no new sync, so a hovered target isn't raised (and its hover reset)
      on every tick of the burst; not yet re-checked in the client.
    - 2026-10-29, beta client, dev bridge + user: after a quick title-bar click all eight of
      PrettyUI 1.2.0's resize handles were hidden (the window's resize disabled) with their
      cursors intact; a press-drag-release on the title bar brought them back. Cause, per the
      1.2.0 source: the title layer's `ONCLICK` calls `resize:SetEnabled(false)` and its
      `stopDrag` (`ONRELEASE` / `ONDRAGCOMPLETE`) calls `SetEnabled(true)`, and a quick click
      arrives release-first, so the disable lands last. The plugin's workaround (re-enable on a
      Logic tick when `resize.enabled` is false and `titleDrag.isClicked` is not true) was
      confirmed in the client (beta client, dev bridge + user, 2026-10-29): after several quick
      title-bar clicks the resize cursors and resizing came back, a title-bar drag moved the
      window with no resize handles showing, and the grips still dragged. So `titleDrag.isClicked`
      reads true for a held title press from its first Logic tick and false soon after a quick
      click.
- **`type()` of a UI component** is `"userdata"` (beta client, dev bridge, 2026-10-29): a component from
  `ui.Interfaces:GetComponent(...)` and a `ui.Layer` made by a plugin or library (PrettyUI's title-drag
  layer), so a `type(x) == "table"` check rejects it. `type(layer.isClicked)` is `"boolean"`.
- **One plugin can find and drive another plugin's components** (probe-drive and the dev bridge,
  beta client, 2026-10-31). From the bridge, `IterateDynamicComponents` on the plugin layer listed
  probe-drive's layer (`type` 20) and slider (`type` 13) with their sizes and positions; no other
  plugin had UI up. A callback that returns `true` stops the iteration after the first
  component, so return nothing to visit them all. `SetValue(7, true)` from the bridge on
  probe-drive's slider returned true and fired probe-drive's own `ONSELECTIONCHANGED` listener,
  as probe-drive's own `SetValue(3, true)` had: the arguments were the slider, the value and 1.
  The setters with a `triggerEvents` flag (`List:SetEntrySelected`, `Slider:SetValue`,
  `ComboField:Select`, `RadioGroup:SetOptionSelected`, `Carousel:Select`) are only a guess to
  behave the same; no API call fires `ONCLICK`, `ONHOLD` or `ONSCROLLWHEEL`.
- **`ui.ComponentType` numbers skip 19** (dev bridge, 2026-10-31): `LINE` 0 … `RADIO_GROUP` 18
  in the stub's order, then `LAYER` 20, `PANEL` 21, `GRID` 22, `PAGED_LAYER` 23, `GROUP_BOX` 24.
  Compare `c.type` with the named members, never with a position in the stub's list.
- **`enabled` is false on layers that take clicks** (chore-tracker, 2026-10-31): its row layers,
  title-bar layer and window root read `enabled` false and `clickthrough` false, and the rows
  still got `ONCLICK` from an XTEST click (`rsdev.py click`). The resize-grip layers read
  `enabled` true. So `enabled` doesn't say whether a component takes a click; `clickthrough`
  and visibility do.
- **Cursor over a plain `ui.Layer`** (cursor probe, user-driven in the beta client, 2026-10-29).
  A layer with `clickthrough = false`, `cursorConfig.mouseOverCursor = id` and
  `opConfig:SetOpCursor(0, id)` shows that cursor over the layer, including over its
  `clickthrough` text child. The user compared `CURSOR_HAND` 204, `CURSOR_HYPERLINK_HAND` 175,
  `CURSOR_TICK` 157, `CURSOR_CROSS` 158, `CURSOR_BLANK` 41, `TOPLEVEL_V2_MOVE` 194, `CURSOR_MOVE` 0
  and `CURSOR_TELE_GRAB` 111, and chose 175 for clickable rows; `TOPLEVEL_V2_MOVE` (PrettyUI
  1.2.0's title-bar drag cursor) reads as a resize cursor. Whether `mouseOverCursor` alone,
  without `SetOpCursor`, is enough was not settled. A second round (same day, dev bridge) chose
  a drag grip's cursor, shown over the grip and for the whole drag: `CURSOR_PUSH` 196, over
  `CURSOR_MOVE` 0, `CURSOR_TELE_GRAB` 111, `TOPLEVEL_V2_SCALE_VERT` 190, `CURSOR_HAND` 204,
  `CURSOR_PULL` 197, `CURSOR_TAKE` 45 and `CURSOR_ACC_CREATE_HOVER` 187 /
  `CURSOR_ACC_CREATE_HOVER_SMALL` 189. The grip's sprite: `id.Sprite.HAMBURGER_MENU_ICON` 8122,
  over `ICON_HAMBURGERMENU_MAINMENU` 6900, `CURSOR_DIRECTIONAL_DRAG_UP_DOWN` 18409,
  `CURSOR_DIRECTIONAL_MOVE_VERT_HORIZ` 18411, `RS3_ICON_SORT_0`..`4`, `SCROLLBAR_DRAGGER_V2_0`
  789, `DEFAULT_SLIDER_HANDLE` 32435 and `AIF_ACCORDION_ARROWS_1` 7577 (all drew at 24 and 16
  px).
  A labelled tile grid (each a `clickthrough = false` layer with `mouseOverCursor` +
  `SetOpCursor(0)`) showed every id from 186 to 199 changing the cursor except
  `TOPLEVEL_V2_SCALE_VERT` 190, which shows nothing. Set on PrettyUI's resize handles, 190 and
  `TOPLEVEL_V2_SCALE_HORZ` 191 showed nothing, while `TOPLEVEL_V2_SCALE_DIAG_1` 192 (draws
  ↖↘), `TOPLEVEL_V2_SCALE_DIAG_2` 193 (↗↙) and `TOPLEVEL_V2_MOVE` 194 showed. PrettyUI 1.2.0
  sets no cursor on its resize handles. (Beta client, dev bridge + user, 2026-10-29.)
- **Enums are numbers in the client**, though the stubs list string values: `ui.DragRenderBehaviour`
  reads `TRANSPARENT_OVERLAY = 0` … `INVISIBLE = 3`, and `ui.DragRenderBehaviour.FromID(2)`
  gives back the name `"OPAQUE_OVERLAY"`. `pairs` over the enum table shows only `FromID`.
  Code that names the members (`ui.DragRenderBehaviour.OPAQUE`) works either way; comparing a
  read-back value against a string literal never matches.
- **A plugin whose `main.lua` raises after making UI leaves that UI behind.** The top level stops
  before `function PluginShutdown()` is defined, so nothing destroys it, and each `prl` added
  another window (Row Probe, 2026-10-29). Define `PluginShutdown` before building UI, or build
  under `pcall`. A plugin layer component another plugin left behind can be removed by id with
  `layer:Delete(categoryID, dynamicID)` from the dev bridge.
- Text content accepts `<br>` for line breaks.
- **Measuring text.** `ui.Text` can't clip or ellipsise (its only size option is `maxLines`), so a
  plugin that must keep a label out of something measures it:
  `config.Font.MUSEO_SANS_15PT_REGULAR:GetStringWidth(text, false)` (PrettyUI 1.2.0 does the same
  under `pcall`). Measured in the beta client, dev bridge, 2026-10-29: it returns integer pixel
  widths ("Pure Essence from Wizard Cromperty" 271, "Daily Challenge" 109, "Rune Shop Run
  (0/11)" 149, "W" 14, "i" 4, "..." 12); a Unicode "…" also measured 12 (the font may lack the
  glyph), so cut with three ASCII dots; with `ignoreTags` false `<col=ff0000>red</col>` measured
  25 (tags parsed, only "red" counted), with true 160 (tags counted as text), so pass false.
- Some components are restricted. The guidelines also forbid unhiding hidden interface
  components and moving or resizing click zones.

## Console commands from Lua

`ExecuteConsoleCommand("!tele 0,50,50,9,56")` runs any console or cheat command. Cheats only
work in the dev environment, so use this for dev tooling only. A shipped plugin can't rely on it.

- **Self-granting works.** `ExecuteConsoleCommand("ppr <plugin>")` then `"ppe <plugin> httpAccess"`
  from `main.lua`'s top level granted the permission: the bridge connected with no manual grant. (dev-bridge, 2026-10-26)
- **A plugin can reload itself.** `ExecuteConsoleCommand("prl <itself>")` from its own `Logic`
  callback (twice, capped via PersistentDB) reloaded cleanly: `PluginShutdown` ran in between, the
  plugin re-enabled with no errors or hitch, and PersistentDB persisted across it. Its
  `PluginShutdown` must call `Unsubscribe` directly: each self-reload whose shutdown passed it
  to `pcall` aborted the client (see "Runtime limits we've hit"). (dev-bridge, 2026-10-26)
- **Console output isn't a ChatMessage.** `ExecuteConsoleCommand("plist")`'s output did not arrive
  as a `ChatMessage` (chatAccess granted; the player's own public chat did), so `ChatMessage` is
  not a way to capture console output. The same holds for a plugin's own `log` and `print`: across
  three bridge sessions no console chat type (96, 98 or 99) arrived while `[BRIDGE]` log lines
  were printing. A plugin that wants its console output elsewhere has to forward it itself, which
  is what `lib/dev/tee.lua` does. (dev-bridge, 2026-10-26)
- **`prl <other plugin>` from `ExecuteConsoleCommand` runs the target's `main.lua` synchronously**
  inside that call (the caller's frames show in the target's load traceback). A load error is caught
  and printed by the client, and the caller's call returns normally. (dev-bridge, 2026-10-26)
- **A reload command run from a plugin's own event callback is synchronous** (2026-10-30, beta
  951-1): it unloads and loads inside `ExecuteConsoleCommand`; the dispatch rules that follow
  are under "Dispatch edge cases" in Events (probe `probe-reload`, deleted).
- **A daemon older than the eval kinds** ignored the request's `kind` and queued `rsdev.py eval`
  snippets as `exec` console commands, so the bridge ran the Lua as console input. `rsdev.py
  eval` now checks the daemon's `/cli/status` `kinds` first. (dev-bridge, 2026-10-26)

## Plugin environment and globals

- **No `os` or `io`.** Both globals are absent, so `os.time()`, `os.date()` and `os.clock()`
  aren't available. `_VERSION` is `Lua 5.4`. (first recording, 2026-10-25)
- **Modules and symlinks.** A `require`d module shares `main.lua`'s globals, `Event` included,
  and the client follows a directory symlink inside the plugin folder (the recorder's `dev/`). (first recording, 2026-10-25)
- **Plugin environment.** `type()` gives `function` for `load`, `require` and
  `ExecuteConsoleCommand`, `table` for `coroutine`, and nil for `debug`, `io`, `os` and
  `loadstring`. (dev-bridge, 2026-10-26)
- **`utf8` is nil in the client** (2026-10-26, beta client 951-1): `type(utf8)` is `nil`, while
  `string.pack`, `math.tointeger`, `table.move` and `string.format` are functions. The tee's
  `utf8.len` raised on every line, so the tee caps a line by bytes and leaves decoding to the
  daemon (`errors="replace"`, `scripts/rsdev.py`).
- **`load(chunk, "=eval", "t", env)` honours the mode and env arguments.** In an eval, `x = 1`
  landed in the scratch env (`rawget(_G, 'x')` was 1, `_G == _ENV` true), not the bridge's own
  (`rawget(getmetatable(_G).__index, 'x')` was nil). `getmetatable` is exposed to plugins.
  `eval "Player.GetEntity().displayName"` returned the name; `print('hi', nil, 3) return 7, nil`
  gave output `["hi nil 3"]`, values `[7, null]`, nvalues 2. (dev-bridge, 2026-10-26)
- **A plugin's globals and `_G` are different tables.** The bridge's env held 6 keys: `Plugin`,
  `require`, its own `PluginShutdown`, `__THIS_PLUGIN` (a `sol.jag::scripting::LuaPlugin*`),
  `__PACKAGES_LOADED` (the `require`d modules by name: `dev/json`, `eval`, `protocol`...) and
  `__PACKAGES_LOADING` (`"main"`). Its metatable's `__index` is a 291-key table with no
  metatable that holds the stdlib and the whole API, and that is what `_G` (and `base`) names:
  `_G._G == _G`, `_G ~= _ENV`. A key put in that table survived `prl dev-bridge` (same table,
  new env), so it outlives a plugin's reload and is very likely shared by every plugin
  (unproven). So `rawget(_G, "x")` never finds a plugin's own `x` (use `_ENV`), `_G.Plugin` and
  `_G.require` are nil, and a write to `_G` may reach every plugin: never write to it. (dev-bridge eval, 2026-10-26)
- **Stdlib in the client**: the base functions plus `collectgarbage` and `warn`; `string` (with
  `dump`, which works: `#string.dump(function() return 1 end)` was 74), `table`, `math`,
  `coroutine` and `load`. Absent: `os`, `io`, `debug`, `utf8`, `package`, `dofile`,
  `loadfile`, `loadstring`. `getmetatable("").__index` is the `string` table. (dev-bridge eval, 2026-10-26)
- **Globals beyond the stdlib**: the API namespaces and enums; a `<Name>Event` table per event
  payload type (`ChatMessageEvent`, `MainLogicEvent`...); `clamp`, `lerp`, `slerp`, `random`
  and `formatStr` (documented); `utils` (only `CalcTextWidth`), `game` (only `options`, the 43
  `ClientOptions`), `base` (the table itself) and `__internal` (sol proxy tables), all
  undocumented; and some 190 `sol.*` userdata, sol's own registry entries. `random(1, 10)`
  returns a float (4.27); `lerp(0, 10, 0.25)` is the float 2.5; `random()` with no arguments raises. `clamp(5, 0, 3)` is the float 3. (dev-bridge eval, 2026-10-26)
- **`formatStr` is fmtlib, fed doubles, and returns nil on a format error.** `{}` of `1` and of
  `1.0` both give `1`, `2^53 + 1` gives `9007199254740992` (an integer goes through a double),
  `math.huge` `inf`, NaN `nan`; `true`, `nil`, `{}` and `print` give `true`, `nil`, `table` and
  `function`. `{0} {1} {0}`, `{{}}`, `{:.2f}`, `{:5}`, `{:<5}`, `{:^5}` and `{:08.3f}` work as
  in fmtlib. `{:d}`, `{:x}` and `{:+d}` of a number, `{:q}`, and `"{} {}"` with one argument
  return nil without an error, so check the result; extra arguments are ignored. A non-string
  format raises `stack index 1, expected string, received number`. (dev-bridge eval, 2026-10-26)

### Usertype members

`getmetatable(<userdata>)` is a plain table naming every
member, properties included, as functions, plus sol's `__eq`, `__index` and so on. For
example, `InventoryProxy` has `GetCategoryTotal`, `GetSlot`, `GetSlots`, `GetTotal`, `config`,
`freeSlotCount`, `id`, `isValid`, `slotCount` and `usedSlotCount`. The global class tables
(`CoordGrid`, `__internal.*`) refuse `pairs` ("not recognized as a container"), and so does
`PersistentDBType` (its values, read by name: `BOOL` 0 to `STRUCTURED_DATA` 4). (dev-bridge eval, 2026-10-26)

## Plugin, permissions and PersistentDB

- **`Plugin.urls` values are opaque userdata, not strings** (eval in the bridge, beta client
  951-1). `type(Plugin.urls)` is `table` and `pairs` iterates it, but each value is a
  `sol.jag::scripting::LuaPluginMetadata::URL` userdata with a metatable: `'x' .. Plugin.urls.rsdev`
  raises `attempt to concatenate a ... URL value`, and `tostring` gives a pointer string
  (`...::URL: 0x649971a92608`), not the URL text. `HTTPRequest.new(url, path)` takes it. Never
  concatenate, format or compare one; only pass it to `HTTPRequest.new`.
- **`PluginPermissions` values are userdata, not strings.** `PluginPermissions.httpAccess` is a
  `sol.jag::scripting::PluginPermission` (`tostring` a pointer, the same object on every read,
  `pairs(PluginPermissions)` lists the three by name), and isn't `==` `"httpAccess"`.
  `Plugin.HasPermission("httpAccess")` raises `stack index 1, expected userdata, received
  string: value is not a valid userdata (bad argument into 'bool(const
  jag::scripting::PluginPermission&)')`; pass `PluginPermissions.httpAccess` (`type(PluginPermissions.httpAccess)` is userdata). The stubs give the
  enum string values, so LuaLS can't catch a string. The stub types
  `OptionalPermissionChanged.permissionName` as a String, and it is one, the key
  (`"chatAccess"`), so it can't be passed on either: look it up with
  `PluginPermissions[ev.permissionName]`, which is `rawequal` to `PluginPermissions.chatAccess`. While the user ran
  `ppd dev-bridge chatAccess` then `ppe dev-bridge chatAccess`, the bridge's probe saw two
  deliveries, both `enabled` true and none false; why is unknown.
  The dev recorder used to record a permission by `tostring`, which gave the pointer text; it
  now records the name. (dev-bridge eval, 2026-10-26)
- **`Plugin` holds more than the page lists**: `HasPermission`, `urls`, `resources` (an empty
  table for a plugin without resources), and the undocumented `Name` and `Version` (the
  manifest's `name` and `version`) and `RemoteID` (-7 for dev-bridge loaded from `dev_plugins`).
  The stubs lack the last three, so LuaLS flags them; don't build on them. `Plugin.urls.<name>`
  for a name the manifest lacks (`Plugin.urls.nope`) reads nil, without an error, as do `var.VarPlayer.FromID` of an
  unknown ID, `Event.<unknown name>` and `require` of a missing module. (dev-bridge eval, 2026-10-26)
- **A `PersistentDB:Set('gen', n)` made at load read back as absent** (2026-10-30, observation,
  cause unknown): across three successive loads of `probe-reload`, `PersistentDB:GetInt('gen')`
  returned nil each time, while a `PersistentDB:Set('fired', true)` made in a `ServerLogic`
  callback was read by `GetBool('fired')` in the next instance. Whether load-time writes don't
  persist, or `Set` of an integer or `GetInt` differs from the bool pair, is untested; don't
  rely on a load-time `Set` surviving a reload until it is.

## API objects

- **API objects are fresh userdata per call, and only some compare equal.** `Player.GetEntity()`
  and `Inventory.Find()` return a new userdata every call, and `tostring()` includes its address
  (`sol.jag::InventoryProxy: 0x591cbdbce258`); don't key a table by one. Two
  `Player.GetEntity()` results, two reads of `.coordGrid` and two
  `ui.Interfaces:GetComponent(<plugin layer>)` results are `==` but not `rawequal`. Two
  `Inventory.Find(config.Inv.INV)` results are not even `==` (`GetEntity() == GetEntity()` true, `Find(INV) == Find(INV)` false,
  `rawequal` false for both), although `InventoryProxy`'s
  metatable has an `__eq`. So never use one as a table key, and don't compare Invs; compare
  `inv.id` instead. (first recording, 2026-10-25, a new object per call; dev-bridge eval,
  2026-10-26, the `==` and `rawequal` results)

## HTTP

- **HTTP to 127.0.0.1 carries no `Origin` header**, so a local daemon can't use one to vet the caller. (dev-bridge, 2026-10-26)
- **HTTP failures, from requests to the rsdev daemon.** The client's HTTP is libcurl.
  - A 404 (GET `/probe-404`) and a 400 (POST `/tee` "not json") finish with `failed` true and `successful` false,
    `responseCode` set, `errorCode` 0, `errorInfo` "", `data` "" and `progress` nil. `header`
    still holds the raw status line and headers.
  - A 200 with a 422-byte body (GET `/cli/status`): `successful`, `progress` 1, `downloadedBytes` and
    `downloadTotalBytes` 422. Its progress callback was never called.
  - The completion callback ran 1-2 Logic ticks after `Get`/`Post`, never inside the call, and
    its argument is `==` the request. Until then the request reads `finished` false,
    `successful` false, `data` "" and `responseCode` 0.
  - **The client times out after 10 s.** A 100 s long-poll finished 500 Logic ticks after `Get`
    with `timedOut` and `failed` true, `errorCode` 28 (`CURLE_OPERATION_TIMEDOUT`), `errorInfo`
    `ErrorOperation timed out after 10001 milliseconds with 0 bytes received` and
    `responseCode` 0. A plugin can't wait longer on one request.
  - **`Cancel` never calls the completion callback.** Right after `Cancel` (one tick after
    `Get`) the request read `cancelled` true and `finished`, `failed` false. Read again 20 s
    later, `finished` and `failed` were true too.
  - **Cancelling an in-flight POST from `PluginShutdown` still delivers it** (2026-10-30,
    var-dump `prl` mid-upload, 3 times): the receiver got the request with a 0-byte body, and
    the plugin logged no failure line for it. So a receiver may see empty POSTs from a plugin
    that was reloaded mid-upload.
  - `Get` or `AddHeader` on a request that hasn't finished raises
    `This request is already being executed`. (dev-bridge eval, 2026-10-26)

## Chat

- **`chatType` values seen**: `GENERAL` (0) for game messages such as "Your pickpocket target
  becomes aware of your presence.", `PUBLIC` (2) for public chat, the only kind with a sender,
  and `SPAM` (109, the filterable game messages) for "You pick the target's pocket." and the
  money pouch lines. Game messages have an empty sender. (first recording, 2026-10-25)
- **Examines arrive as `GENERAL` (0)**, not `OBJ_EXAMINE`/`NPC_EXAMINE`/`LOC_EXAMINE`, with empty
  sender fields. (dev-bridge, 2026-10-26)
- **`chatType` 138 (`BROADCAST_WORLD`) is world News** ("News: <player> has accomplished ...")
  and names other players while its sender fields are empty. An empty sender doesn't mean the
  text is free of other players' names, which is why dev-bridge filters chat by type allowlist
  (plus own-name match for speech), not by sender. (dev-bridge, 2026-10-26)
- **The player's own public line**: `chatType` 2, `senderNameSimple` `UberMouse894`,
  `senderNameUnfiltered` `<img=11>UberMouse894`, `senderNameFiltered`
  `<img=11> <col=6d6d75>Ironman</col> UberMouse894`. (dev-bridge, 2026-10-26)

## Inventories

- **Slot layout.** `Inv:GetSlots()` is dense: every slot up to `slotCount`, with an empty one as
  obj -1 (configName `UNKNOWN`) and count 0, so `ipairs` walks them all. A bought-out shop line
  stays in the shop inventory with count 0 (`GENERALSHOP1` slot 7 was obj 590 x0;
  `GENERALSHOP1_FREEBIES` slot 4 too). Updates were seen for `INV` (93), `BANK` (95, 1920
  slots), `LOOT` (773), `DROPLOG` (787), `MONEY_POUCH` (623, coins in slot 1),
  `GENERALSHOP1` (3) and `GENERALSHOP1_FREEBIES` (553). (first recording, 2026-10-25)
- **`Inv:GetSlot` never returns nil for an index.** An empty backpack slot, slot 0 and slot 9999
  all gave an `InventorySlot` of obj -1, count 0, with no error. `inv.valid` (the stub's name for
  `isValid`) reads nil without an error: `Inv.isValid` is the field (true on the backpack; chore probe,
  2026-10-30). (dev-bridge eval, 2026-10-26)
- **Machine inventories are kept current anywhere.** `INVENT_MACHINE_GUILD_<1..6>_INPUT/_OUTPUT`
  (Invention Guild machines) sent `InventoryUpdated` as the machines worked while the user was
  at the farm, and `Inventory.Find` + `GetSlots` read the current contents there. (chore probe, 2026-10-30)
- **Player Owned Farm paddock inventories update once a minute on their own** (growth, births:
  `POF_PADDOCK_3`, `_6`, `_BREEDING`), so a paddock `InventoryUpdated` isn't the player's doing. (chore probe, 2026-10-30)
- **`InvSlot` has only `obj` and `count`** (its metatable: `count`, `obj`, `class_cast`,
  `class_check`, `new`), and `obj` is the static `ObjType` (name, `params`, cost...). An item's
  per-instance VarObj values, such as a farm animal's state, can't be read. (chore probe, 2026-10-30)

## Runtime limits we've hit

Found in the beta client (2026-10-20), not in the official docs:

- **A symlinked plugin folder inside `dev_plugins` is not loaded**, wherever it points, although
  `dev_plugins` itself may be a symlink to this repo's `plugins/` (ours is). Probe 2026-10-26:
  after `prf` + `plist`, a real folder `plugins/linkprobe-real` was listed and
  `plugins/linkprobe-link` (a symlink to a real folder) was not. So plugins from elsewhere must be
  copied into `plugins/`, as the flake shellHook does for the third-party dev plugins.
- **Each Lua call can run for at most 1000 ms.** The client then aborts it with
  `Maximum function execution time of 1000 ms exceeded`. Spread big jobs across `Logic` ticks
  (see `plugins/var-dump`).
- **Starting a POST from inside another request's completion callback crashed the client**
  (freeze, then SIGABRT) twice, once from a coroutine and once without one. After the first
  response, the next request either arrived with an empty body or never arrived. The cause isn't
  confirmed. Until it is: start requests only from event callbacks (e.g. `Logic`), keep each
  body string referenced until its request finishes, and avoid coroutines around API calls.
- **Never pass `Event.<X>.Unsubscribe` straight to `pcall` (or `xpcall`): call it directly.**
  All seven client aborts of 2026-10-26 (rs2client SIGABRT, systemd coredumps; listed
  below) called `pcall(Event[event].Unsubscribe, name)` or
  `pcall(real.Event.Logic.Unsubscribe, ...)`, the API function handed to `pcall` itself.
  `pcall` doesn't catch it: it is a native abort, not a Lua error. Direct calls survived: stage
  1's bridge (commit 684eedc) calls `Event.Logic.Unsubscribe(name)` and
  `Event[name].Unsubscribe(...)` in its `PluginShutdown`, and its own `prl dev-bridge` from
  `Logic` reloaded cleanly twice; and a runtime `Event.VarTransmit.Subscribe("h4probe", fn)`
  made inside `Logic`, then a direct `Event.VarTransmit.Unsubscribe("h4probe")` from inside
  `Logic`, left the client up (session ff92400823; abort 2 was the same situation with the
  `pcall` form). Also safe, from `Logic` on real `ServerLogic` subscriptions (session
  7bcb60d109): a Lua closure under `pcall`, `pcall(function() Event.X.Unsubscribe(k) end)`
  (dev-kit's form), and a tail call from a function `pcall` called (`local function drop(k)
  return Event.X.Unsubscribe(k) end; pcall(drop, k)`), although the tail call leaves `pcall`'s
  C frame as the caller's. So the earlier guess at a mechanism, that the client reads the
  calling plugin off the calling Lua frame, doesn't explain it; what aborts is the API function
  itself handed to `pcall`. The POST crashes above (from a completion callback, and from a coroutine) may share
  it, also unconfirmed. This supersedes three readings recorded earlier the same day:
  "`Unsubscribe` inside an event callback aborts", "a subscription created at runtime can
  never be removed" and "a self-`prl` from `Logic` is only safe with stage 1's six load-time
  subscriptions". Every crash behind them used the `pcall` form. The harness faults the `pcall`
  form (testing.md fidelity ledger). Whether other API functions share the fault is unknown, so
  dev-bridge passes none straight to `pcall` except `ExecuteConsoleCommand`
  (`pcall(ExecuteConsoleCommand, cmd)` has run many times, live, without trouble);
  `HTTPRequest:Cancel` runs from a Lua closure under `pcall` instead.

- **In the beta client, logging out disables plugins** (the user, 2026-10-25), so what a plugin
  sees across a logout and the next login can't be observed there.
- **Crash 8 (SIGSEGV, coredump 2600170, 2026-10-26 14:48)**: `prl chore-tracker`, sent from
  the dev-bridge, unloaded a chore-tracker with the log tee on. The fault was in a shallow
  main-loop stack with no Lua frames running, and no POST was in flight. Every reload that
  survived unloaded an instance whose subscriptions were all unsubscribed in `PluginShutdown`;
  the tee-on instance also held the tee's `devTeeFlush` Logic subscription, which nothing
  unsubscribed. Hypothesis, supported by one surviving reload and not proven: a subscription
  left registered at unload is dispatched into the dead Lua state. With `tee.shutdown()` in
  chore-tracker's `PluginShutdown` (`lib/dev/tee.lua` at 11b307e), `prl chore-tracker` from
  the bridge with the tee on left the client up (2026-10-26) and the tee started a new session.
  The rule we follow: unsubscribe every subscription in `PluginShutdown`, including ones a
  `lib/dev` module made (`tee.shutdown()`, `recorder.shutdown()`). The harness's `h:unload`
  faults on any subscription `PluginShutdown` leaves behind (`docs/testing.md`).
- **Crash 9 (SIGSEGV x3, 2026-10-30 21:43:56, 21:59:55 and 22:03:31)**: `ppe var-dump httpAccess`
  sent through the dev bridge (`rsdev.py exec`) while `recorder-demo` was running with `httpAccess`.
  It crashed only with all three so far: (1) that `ppe` sent through the bridge, (2) var-dump's
  `start()` running in response to the grant, (3) `recorder-demo` running with `httpAccess`. The
  core dumps show the same shallow main-thread stack each time, with no Lua frames:
  rs2client+0x3c76a4, +0xe3f8b, +0x1c110c, +0x16648f5, +0x1402ec8. The one-run controls were the
  same `ppe` typed in the console (no crash) and the bridge `ppe` without `recorder-demo` (no crash,
  21:59:13). Probe runs did not reproduce it for the bridge `ppe` dispatch alone (`probe-perm`,
  whose handler only printed), nor for subscribing `Logic`, `ServerLogic` and `VarTransmit` inside
  that dispatch with `recorder-demo` granted and posting (`probe-perm-sub`); both probes are
  deleted. Remaining suspects: the synchronous part of var-dump's `start()` (snapshot init,
  `beginDomain`'s `pcall(nameLister)` starting `pairs(id.VarPlayer)`). The cause is unconfirmed. The
  rule we follow: grant var-dump's `httpAccess` by typing `ppe` in the console, never through the
  bridge.
- **Closing the client segfaults** (2026-10-26, beta client 951-1): closing it gave a SIGSEGV
  three times out of three, at 15:09:17 (pid 2637620), 15:12:49 (pid 2649914) and 15:15:07 (pid
  2656263). `coredumpctl` shows the same stack each time, frame #4 jumping into a heap address.
  dev-bridge and chore-tracker had been turned off with `poff` before the third close. A SIGSEGV
  on 2026-10-20 has no core left to compare. So it needs no plugin running at close; most likely
  it is the client. Residue from plugins loaded earlier in the session can't be ruled out.
- **Seven client aborts (rs2client SIGABRT, systemd coredumps), 2026-10-26**, the conductor
  driving the beta client through the bridge. Every one passed `Event.<X>.Unsubscribe`
  straight to `pcall` (the rule is above, under "Runtime limits we've hit"):
  1. A probe's error: eval.lua's `forget` ran `pcall(Event[event].Unsubscribe, ...)` inside the
     probe's own `Logic` callback (a subscription made at runtime inside `Logic`).
  2. `eval --reset`: `stop` ran `pcall(Event[event].Unsubscribe, ...)` from `Logic`, for a
     `VarTransmit` subscription made at runtime inside `Logic`. The subscription had worked.
  3. `eval --reset` on commit 0866186, which ran `prl dev-bridge` from `Logic`: its
     `PluginShutdown` ran the `pcall`'d `Unsubscribe`s.
  4. A `Logic` subscription made at runtime (a snippet reaching the real `Event` through
     `getmetatable(_G).__index`), removed by `pcall(real.Event.Logic.Unsubscribe, ...)` in an
     `HTTPRequest:Get` completion callback.
  5. `exec "prl dev-bridge"` on commit 493f192 (39 load-time subscriptions, one probe live),
     12:47: `PluginShutdown` ran `pcall(Event[event].Unsubscribe, ...)`.
  6. The same on commit f423f49 (stage 1's six load-time subscriptions), after evals.
  7. The same on f423f49 with no eval at all.

  A SIGABRT at 13:20:04 (pid 2557183) on 2026-10-26 has the same signature (frames at
  rs2client+0xa0df2 and +0x3af451). It most likely came from closing the client while a bridge
  whose `PluginShutdown` used the `pcall` form was loaded.

  Survived: stage 1's bridge (684eedc), whose `PluginShutdown` unsubscribes directly,
  reloading itself with `prl dev-bridge` from `Logic` twice (new sessions in the daemon log);
  the direct `Unsubscribe` from inside `Logic` (under Events); a probe disarmed on error (made a no-op);
  on 0866186, refusing a `poff dev-bridge` (exit 1). Seen working on 493f192 and f423f49, with
  probes as entries in the bridge's own table: loading with 39 load-time subscriptions
  (493f192); a `Logic` probe run through the bridge's handler (554 ticks, emitting); a
  `ServerLogic` probe that raised removed with one `Log` line; fan-out to several probes; an
  `Event.Draw` probe refused with its reason; `Unsubscribe` on the proxy (a table edit)
  stopping a probe; `eval --reset` keeping the session and clearing the scratch env (`x`, `lc`
  nil afterwards) and the probes (their emits stopped), with no reload. The bridge now calls
  `Unsubscribe` directly.

## The client window on X11

- **The game window** has `WM_CLASS` `"rs2client", "RuneScape"` and `_NET_WM_NAME` "RuneScape". It
  belongs to a child `rs2client` process; the `rs3linux` launcher only has 10x10 leader windows. (rsdev shot, 2026-10-26)
- **`maim -u -i <window>` captures real GL pixels** under VMware (about 1.2 s, 3836x2121, a 4-6 MB
  PNG). `-g` together with `-i` is window-local. (rsdev shot, 2026-10-26)
- **A window on a hidden i3 workspace** reports `Map State: IsUnviewable` (`WM_STATE` Withdrawn),
  and maim then exits 0 having captured whatever is on screen in that rectangle: a silent wrong
  shot, so `shot` checks the map state first. (rsdev shot, 2026-10-26)
- **Windows above the client appear in the capture** (a floating scratchpad terminal did). (rsdev shot, 2026-10-26)
- **`_NET_DESKTOP_NAMES`** holds names like "1: web" and "3: dev"; `_NET_WM_DESKTOP` is the index. (rsdev shot, 2026-10-26)
- **Plugin-layer units are window pixels at interface scale 100.** The plugin layer read
  1916x2121 at global 0,0, the same size as the game window (`xwininfo`), and a layer placed at
  (600, 600) showed 600 px right and down from the window's top-left corner in a shot. A click at
  window-relative (750, 675) reached a 300x150 layer at (600, 600) as local (150, 75), with
  `Mouse.GetPosition()` 750, 675. Other interface scales are unprobed. (probe-drive, beta client,
  dev bridge, 2026-10-31)
- **OS input reaches the client through XTEST only** (xdotool 3.20211022, i3, probe-drive,
  2026-10-31). `xdotool mousemove --window <client> x y` moved the real pointer, i3's focus
  follows the mouse, so the client took focus, and the layer got `ONMOUSEOVER`. `xdotool click 1`
  (XTEST) gave one `ONRELEASE` then `ONCLICK`, the release-first order of a press and release in
  one tick (see "Pointer hooks on a plain `ui.Layer`"). `xdotool click --window <client> 1`
  (XSendEvent) gave nothing in 3 s. One run that sent the XSendEvent click, then
  `windowfocus --sync` and an XTEST click, logged two click pairs; that wasn't explained, so
  click with XTEST alone. Another window titled "RuneScape" (738x498) existed alongside the
  game window at the time.
- **XTEST keys reach the console.** With the client focused, `xdotool key alt+grave` opened the
  console, `xdotool type --delay 40 plist` and `key Return` ran `plist` (its listing showed), and
  another `alt+grave` closed it. A pointer hook still fired while the console was open. Check
  that the console really opened (a shot) before typing: typed text goes to the chat box when it
  is closed, and Return would send it. (probe-drive, 2026-10-31)
- **A plugin can't tell whether the console is open** (dev-bridge `KeyDown`/`KeyTyped` eval
  probes, XTEST keys, 2026-10-31). Shift gave `KeyDown` `gameKey` 81 (SHIFT) with `modifiers` 1
  with the console closed and open alike, and `z` typed into the open console gave `KeyDown` 64
  (Z) each time. Alt+\` gave one `KeyDown` 86 (ALT) with `modifiers` 2 (the bit `ModifierKey`
  calls CONTROL) and nothing for the \` itself, so no `GameKey.CONSOLE` (28). Backspace in the
  open console gave no `KeyDown`. `KeyTyped` never fired during the whole probe.

## Shops in the client

Found by a throwaway probe in the beta client (2026-10-25): a purchase at each of 17 shops,
logging `VarPlayer.SHOP` and the inventory events.

- **A shop is an inventory the server sends only while the shop is open.** In order:
  - **Opening:** `InventoryAdded` for the shop's inventory, then `VarPlayer.SHOP` (304, a
    number) goes from -1 to that inventory's id. Some shops also send a second "free" inventory
    alongside it: `RUNESHOP_FREEBIES` 557, `FISHINGSHOP_LUM_FREEBIES` 561,
    `OMGE_HERBLORE_FREE_SHOP` 636 and others.
  - **Closing:** `InventoryRemoved`, then `SHOP` goes back to -1.
- **A purchase** is one `InventoryUpdated` on the shop whose line drops (`FEATHER_PACK x20` to
  `x0`), next to the backpack (`INV` 93) gaining the items and the money pouch (`MONEY_POUCH`
  623, slot 2 `COINS`) dropping. A bought-out line stays at x0.
- **Stock is per character** (the user), so a drop in an open shop's line is the player's own
  purchase.
- **Each shop has its own inventory**, even shops selling the same thing:

  | Shop | Inventory | id |
  |---|---|---|
  | Gerrant, Port Sarim | `FISHINGSHOP` | 30 |
  | Lumbridge Fishing Supplies | `FISHINGSHOP_LUM` | 562 |
  | Harry, Catherby | `FISHINGSHOP2` | 43 |
  | Shantay Pass | `SHANTAYSHOP` | 78 |
  | Jatix, Taverley | `OMGE_HERBLORE_SHOP` | 635 |
  | Obli, Shilo Village | `SHILOJUNGLESTORE` | 138 |
  | Lady Meilyr, Prifddinas | `ELFCITY_MEILYR_SHOP` | 738 |
  | Jossik, Lighthouse | `LIGHTHOUSESHOP` | 214 |
  | Vanligga, Jatizso (yak hide) | `FRISD_YAK_CONTRABAND` | 508 |
  | Feathers of Ma'at, Sophanem | `MENAPHOS_SLAYER_SHOP` | 821 |
  | Turael, Burthorpe | `OMGE_SLAYERSHOP_SMKI` | 633 |
  | Sumona, Pollnivneach | `SMKI_SLAYERSHOP` | 538 |
  | Aubury, Varrock | `RUNESHOP` | 5 |
  | Betty, Port Sarim | `MAGICSHOP` | 25 |
  | Ali Morrisane, Al Kharid | `FEUD_MORRISANES` | 252 |
  | Carwen Essencebinder | `OMGE_RUNECRAFTING_SHOP` | 641 |

- **A detector built on these facts works (user-checked in the client, 2026-10-25, Chore
  Tracker C1 stage 1):** it snapshots a listed shop's slot counts on `InventoryAdded`
  (and with `Inventory.Find` at load) and counts any drop on `InventoryUpdated` as a
  purchase. It caught purchases at two shops, ignored a shop opened and closed without
  buying, and still caught one after a `prl` with the shop open.
- **Dell Monti is not a shop.** His apples and pineapples arrive as banknotes in the backpack
  (`CERT_COOKING_APPLE`, `CERT_PINEAPPLE`) with no shop open.

## PrettyUI in the client

[PrettyUI](https://prettyui.j3.gg) is a UI library plugin (mod.io 6398181). Found by three
throwaway probe plugins in the beta client (2026-10-25), with PrettyUI 1.2.0 installed:

- **The dependency.** `"requiredDependencies": { "prettyui": 6398181 }`, the object form with a
  mod.io ID as the value, resolves for a plugin in `dev_plugins` too: the plugin sees PrettyUI
  1.2.0 as the global `prettyui`.
- **The plugin layer** (`ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)`)
  was 3836x2121 at global 0,0.
- **Reading a window's geometry.** `window.root`'s `x`, `y`, `width` and `height` read back the
  window's position and size after the user drags or resizes it, so a plugin can persist them.
  A titled window drags by its title bar and stays clamped inside its parent (clamped at 1004,1013 and other spots, 2026-10-25).
- **The close X** sits at (width - 28, 7). A component made a child of `window.root` at
  `x = -28, y = 7, xAnchor = 1.0` lands in the X's slot (global 872,307 for a 300-wide window at
  600,300) and moves with the window in the same frame. Hide the X with
  `window.closeButton.hidden = true` to put your own button there.
- **The title bar takes clicks.** Its drag layer covers the whole title bar except the X's slot
  (width - 34 to width), so a button anywhere else on the title bar gets no clicks.
- **Moving a window or panel from code.** A bare `root:SetPos(x, y)` gets snapped back by
  PrettyUI's drag bounds (a Panel moved to 1593,571 stayed at 0,0). `root:SetPos(x, y)` followed
  by the owner's `SetSize(width, height)` (its current size will do) sticks, because SetSize
  makes PrettyUI remember the new spot.
- **Panels Alt-drag**, but only with the console closed: the console blocks the keyboard, so
  PrettyUI never sees Alt while it is open.
- **Panel drawing.** A Panel draws its frame even at `backgroundAlpha = 0`, and scrolls content
  that overflows it.
- **Panel layout.** A Panel's first child sat at +18,+16 inside it (throwaway probe, beta
  client, 2026-10-25).
- **A frameless collapsed button** (Chore Tracker, user-checked 2026-10-25): a 20x20 Panel
  (`backgroundAlpha = 0`, `scrollable = false`) with a 20 px SpriteButton made on
  `panel.root` at 0,0, not in its content, covers the frame and looks like the same button on a
  window's title bar. It still Alt-drags, and its screen spot is the Panel's own.
- **A Panel clips tooltips drawn on its root** (Chore Tracker's collapsed strip, user-checked
  2026-10-31). A hand-built row made on `panel.root` of a 40 px high Panel, with its tooltip
  attached through `prettyui.Tooltip.attach(row, panel.root, ...)`, showed the tooltip cut to
  the panel's bounds. Otherwise the strip worked as built: a hand-built `ui.Layer` row on
  `panel.root` that ticks on click, beside a SpriteButton on the same root at `xAnchor = 1.0`.
- **Rows that change colour.** A CheckboxButton's `colour` is fixed once made. Two copies of
  a row at the same `y` (an explicit `y` keeps the second out of the flow), one shown at a
  time with `root.hidden`, looked right in the client (user-checked 2026-10-25).
- **Tooltips can stick, and the fix works (confirmed in the client, 2026-10-25, Chore Tracker
  stage 2).** The user saw some tooltips stay up after they should have closed. With the fix
  below, no tooltip stayed up after a row's tick swapped it to its dimmed copy and back, and
  none after a collapse and expand. The cause is read from the 1.2.0 source: in
  `src/tooltip.lua` a tooltip shows on its target's ONMOUSEOVER and hides only on that
  target's ONMOUSELEAVE. Content tooltips (CheckboxButton choices included) are drawn on the
  window's parent, outside the window, so hiding a hovered row's root leaves its tooltip up.
  That a hidden component never gets the mouse-leave is still only read from source: the fix
  makes it unobservable. `Window:Close` hides the content's tooltips and `Destroy` destroys
  them. A SpriteButton made on `window.root` draws its tooltip inside the root, so Close hides
  it only with the window and `Show` brings it back. The fix is the documented
  `SetTooltip(value)` / `SetOptionTooltip(value, tooltip)` with a **table** value, which
  destroys the old tooltip and attaches a new, hidden one. A string on an existing tooltip only
  changes its text (`Tooltip.set`), so it stays up.
- **Building a big window in one call is fine.** Chore Tracker's list with all 67 chores picked
  (134 CheckboxButtons, two per row, each with a tooltip, plus headings) builds in one Lua call
  without hitting the 1000 ms limit (user-checked 2026-10-25). That is one machine, not a
  bound: a window with many times that would still need slicing across `Logic` ticks.
- **`AchievementPopup` draws over the game view from the plugin layer** (user-checked
  2026-10-29, Chore Tracker). `prettyui.AchievementPopup.show` with `parent` set to the plugin
  layer, `xAnchor = 0.5`, `yAnchor = 1/3` and offsets of minus half its size showed centred a
  third of the way down. Back-to-back popups queued through `onComplete` each showed in turn.
  Its sound (`soundID`, played through `audio.Play`) is unheard: the client ran in a VM with
  no audio. The sound ids `ARCH_INFO_POPUP` (48145) and `LEAGUE2_HARD_TASK_COMPLETE` (60041) exist
  in the live client (dev-bridge, 2026-10-29).
- **Hand-built rows in a window** (Row Probe, user-checked 2026-10-29). A `ui.Layer` made on
  the window's `content` (a field outside our typed subset) at an explicit `y`, with
  `window:SetContentHeight(h)` covering the rows, scrolls with the window.
  - `ui.Sprite:SetAssociatedObject(objId)` draws the item's icon scaled into the sprite's box:
    32 px fills a 36-high row, 24 px is smaller but clear. Coins' icon is a speck at any size
    (one coin's art). `alpha = 0.5` on the icon, muted text and
    `id.Sprite.RS3_BTN_CHECKBOX_SMALL_2` (the ticked box; `_0` is empty) read as "done".
    The chore rows use the full four-state set instead, see "Row box sprites" below.
  - The window clips both drawing and the mouse: a row scrolled past the bottom edge drew
    only the part inside, and hovering and clicking just below the window reached no row.
  - **`xyGlobal` leaves out an ancestor's scroll** (dev-bridge probe, beta client,
    2026-10-29, raw layers). A viewport layer at plugin-layer (1200, 300), 200x100, with
    `SetScrollSize(200, 400)`, a content child at (0, 0) 200x400 and a row on it at (10, 150):
    the row read `xyGlobal` (1210, 450) and the content (1200, 300) both before and right after
    `viewport:SetScrollPos(0, 120)`, and again on a later frame; the row's `y` stayed 150. PrettyUI
    1.2.0 scrolls a window that way (`src/core/scroll.lua`) and places its own overlays from
    the root y plus the target's y less `_scroll.scrollY` (`src/window.lua`). So a row's
    on-screen spot is `viewport.xyGlobal` plus the row's `x`, `y`, less the scroll position.
  - **A raw row swallows the mouse wheel.** Over a row that subscribes nothing for the wheel,
    the window didn't scroll. `row:Subscribe(ui.Hook.ONSCROLLWHEEL, window._onScrollWheel)`
    (internal, read from the 1.2.0 source; PrettyUI's own content components bind the same
    handler) made it scroll.
  - Tooltips: `prettyui.Tooltip` is exported, and `Tooltip.attach(target, parent, value)` is
    what PrettyUI's `ItemSlot` uses on content children. It works on a hand-built row
    (user-checked in the beta client, 2026-10-29): the tooltip shows on hover and goes on leave,
    and a shortened row's tooltip leads with the full name.
  - **Row box sprites** (rendered in the user's beta client through the dev bridge, `scripts/rsdev.py eval`, 2026-10-29):
    `RS3_BTN_CHECKBOX_0/1/2/3` are empty / empty-hovered (lighter border) / ticked /
    ticked-hovered and read well at 16 px. The SMALL set PrettyUI 1.2.0 uses has no
    ticked-hovered sprite (its selectedHovered is the plain ticked one), so the rows use the
    full 0-3 set so a ticked box also reacts to hover. `RS3_BTN_CHECKBOX_4` looks like an empty box (role not
    established).
  - **Stepper sprites** (Chore Tracker's Shop runs lines, plugin reloaded in the beta client and
    screenshotted, 2026-10-31): `id.Sprite.RS3_CONTEXTUAL_INPUT_MINUS` and `_PLUS` draw as a
    recognisable − and + at 20 px, each in a hand-built button (a `clickthrough = false` layer
    holding the sprite). A value `ui.Text` between them with
    `AlignTo(ui.AlignMode.CENTRE, ui.AlignMode.CENTRE)` drew centred horizontally, and clicks
    changed it in place, at either end of the range too. PrettyUI 1.2.0's `SpriteButton` has a
    PLUS sprite but no MINUS (`tests/harness/api/prettyui/internal.lua`), hence the hand-built
    pair. A name `ui.Text` sized to end before the minus button still drew over it when too long
    (it can't clip), so the name is cut to fit like a row's.
- **A window's scroll is settable but only internally readable** (read from the 1.2.0 source,
  not yet confirmed in the client): `Window:SetScrollPosition(position)` is public, but the
  position is read only from the internal `window._scroll.scrollY`.

The test harness fakes this subset (docs/testing.md, "Testing a PrettyUI plugin"). Its LuaLS
types are in `types/prettyui.lua`.
