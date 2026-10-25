# API concepts

A conceptual guide to the API. The full per-type reference is the LuaLS stubs in `docs/api/` (see
[README.md](README.md#the-api-reference-api)). Treat names here as orientation, and check
signatures against the stubs.

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

## Coordinates

- `CoordGrid` is a tile coordinate made of five numbers: `level, mapSquareX, mapSquareZ,
  localTileX, localTileZ` (written `0,50,50,9,56`). A map square (the "chunk") is 64×64 tiles.
  `tostring(coordGrid)` gives that comma form, which `!tele` accepts.
- `CoordFine` is a sub-tile world position. Convert between the two with
  `ToCoordFine`/`ToCoordGrid`.
- Instances have their own coordinates and map back to source tiles
  (`World.GetRegionSourceForCoordGrid`, `!getcoord` shows both).
- `ScreenConvert` converts between world coordinates and screen positions, for overlays.

## Events

- `Event.<Name>.Subscribe("uniqueName", callback)` and `Event.<Name>.Unsubscribe("uniqueName")`.
  The name identifies the subscription so you can replace or remove it.
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
- UI input uses **component hooks**, separate from `Event`:
  `button:Subscribe(ui.Hook.ONBUTTONPRESSED, fn)`, `button:Unsubscribe(ui.Hook.ONBUTTONPRESSED)`.
- Text content accepts `<br>` for line breaks.
- Some components are restricted. The guidelines also forbid unhiding hidden interface
  components and moving or resizing click zones.

## Console commands from Lua

`ExecuteConsoleCommand("!tele 0,50,50,9,56")` runs any console or cheat command. Cheats only
work in the dev environment, so use this for dev tooling only. A shipped plugin can't rely on it.

## Runtime limits we've hit

Found in the beta client (2026-10-20), not in the official docs:

- **Each Lua call can run for at most 1000 ms.** The client then aborts it with
  `Maximum function execution time of 1000 ms exceeded`. Spread big jobs across `Logic` ticks
  (see `plugins/var-dump`).
- **Starting a POST from inside another request's completion callback crashed the client**
  (freeze, then SIGABRT) twice, once from a coroutine and once without one. After the first
  response, the next request either arrived with an empty body or never arrived. The cause isn't
  confirmed. Until it is: start requests only from event callbacks (e.g. `Logic`), keep each
  body string referenced until its request finishes, and avoid coroutines around API calls.
- `pairs(id.VarPlayer)` works, but the integer ID isn't in the value slot (passing the values to
  `FromID` fails with "expected number, received string"). Scanning IDs -70000..20000 found
  ~62k VarPlayer vars (VarBits included) and ~7.8k VarClient vars.
- Reading `.value` on a var whose ValueType isn't in the documented list (seen: 49, 61, 71, 126)
  logs `Failed to convert a config value to a plugin value: invalid ValueType (n)` but doesn't
  raise an error.
- **A VarTransmit names either the base var or the one VarBit that changed.** In the var-dump
  change log (2026-10-25) claiming Bert's sand sent the base `HANDSAND_BUCKETS` (0 -> 1 -> 3,
  and its VarBit `HANDSAND_BUCKETS_CLAIMED_TODAY` then read 1), while chopping sent the VarBit
  `LEAGUE_TASK_PROGRESS_CHOP_ANY` by name with its own field values (0 -> 1 -> 2 -> 3 -> 4), and
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
  `ATELF_MAIN4`, Coeden's logs). `INTERN_NOTES_DAILY_CHALLENGES_COMPLETE` counted 0 -> 1 -> 2 as
  daily challenges finished, while `OMGE_CHALLENGE_CURRENT_ID_1..3` held 2, 2, 3 (a finished
  slot kept its id) and slots 4-5 held 0. Whether a flag clears at the daily reset or only on
  the next claim is unconfirmed. Chore Tracker's `data/vars.lua` is built on these.
- **`SHOP_MULTIPURPOSE` wasn't sent during a purchase at Arhein's shop** (2026-10-25, with
  `SHOP` = 47, `ARHEINSTORE`), so its `SHOP_SEAWEED_BOUGHT` / `SHOP_PINEAPPLES_BOUGHT` counters
  can't be seen to move on a purchase; the shop's inventory can.
- **In the beta client, logging out disables plugins** (the user, 2026-10-25), so what a plugin
  sees across a logout and the next login can't be observed there.
- **BOOLEAN vars read mostly `true` (unconfirmed).** 133 of 148 were `true`, including
  implausible ones like `HOUSE_CURRENTLY_PEEKING`, so unset may come back as `true`. Check
  against a BOOLEAN you can toggle before trusting one.

## Seen in the first recording (2026-10-25)

From `plugins/recorder-demo` in the beta client: its probe line, and the dev recorder's
recording `20261025-144642-8f7250b863` (bank, picking things up, pickpocketing, talking to NPCs,
buying out a shop line). See [testing.md](testing.md#recordings) for recordings.

- **No `os` or `io`.** Both globals are absent, so `os.time()`, `os.date()` and `os.clock()`
  aren't available. `_VERSION` is `Lua 5.4`.
- **A wall clock without permissions:** `var.VarPlayer.CLOCK_TIME_DATE_MINUTES.value` is minutes
  since the Unix epoch (29881543 = 2026-10-25 01:43 UTC), and a VarTransmit fires as it ticks
  over. `ChatMessage.timestamp` is unix seconds.
- **Tick rates.** `Logic` runs at 50 Hz (about 3000 ticks per clock minute). `ServerLogic` came
  30 Logic ticks apart two times in three, anywhere from 16 to 82, and twice two arrived in one
  tick.
- **`chatType` values seen**: `GENERAL` (0) for game messages such as "Your pickpocket target
  becomes aware of your presence.", `PUBLIC` (2) for public chat, the only kind with a sender,
  and `SPAM` (109, the filterable game messages) for "You pick the target's pocket." and the
  money pouch lines. Game messages have an empty sender.
- **A fresh object per call.** `Player.GetEntity()` and `Inventory.Find()` return a new
  userdata every call, and `tostring()` includes its address
  (`sol.jag::InventoryProxy: 0x591cbdbce258`). Don't key a table by one. Whether two of them
  compare equal with `==` is unconfirmed.
- **Inventories.** `Inv:GetSlots()` is dense: every slot up to `slotCount`, with an empty one as
  obj -1 (configName `UNKNOWN`) and count 0, so `ipairs` walks them all. A bought-out shop line
  stays in the shop inventory with count 0 (`GENERALSHOP1` slot 7 was obj 590 x0;
  `GENERALSHOP1_FREEBIES` slot 4 too). Updates were seen for `INV` (93), `BANK` (95, 1920
  slots), `LOOT` (773), `DROPLOG` (787), `MONEY_POUCH` (623, coins in slot 1),
  `GENERALSHOP1` (3) and `GENERALSHOP1_FREEBIES` (553).
- **VarTransmit values are integers** for BOOLEAN vars (0/1) and for config-typed ones
  (`COORDGRID`, `INV`, `OBJ`, `ACHIEVEMENT`, `COMPONENT`...), whatever `.value` gives for them.
- **Modules and symlinks.** A `require`d module shares `main.lua`'s globals, `Event` included,
  and the client follows a directory symlink inside the plugin folder (the recorder's `dev/`).

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
  A titled window drags by its title bar and stays clamped inside its parent.
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
- **A frameless collapsed button** (Chore Tracker, user-checked 2026-10-25): a 20x20 Panel
  (`backgroundAlpha = 0`, `scrollable = false`) with a 20 px SpriteButton made on
  `panel.root` at 0,0, not in its content, covers the frame and looks like the same button on a
  window's title bar. It still Alt-drags, and its screen spot is the Panel's own.
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
- **A window's scroll is settable but only internally readable** (read from the 1.2.0 source,
  not yet confirmed in the client): `Window:SetScrollPosition(position)` is public, but the
  position is read only from the internal `window._scroll.scrollY`.

The test harness fakes this subset (docs/testing.md, "Testing a PrettyUI plugin"). Its LuaLS
types are in `types/prettyui.lua`.
