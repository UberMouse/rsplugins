# API concepts

A conceptual guide to the API. The full per-type reference will be generated into `docs/api/` by
the API dump script. Treat names here as orientation, and check signatures against the reference.

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
