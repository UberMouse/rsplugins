# Walkable Flood (dev tool, not for submission)

An experiment to see whether a plugin can work out where you can walk. The API has no collision
or walkability getter, so this plugin rebuilds the walls and blocked tiles around you from loc
(scenery) data, flood-fills outward from your tile, and draws the result on the ground:

- **green fill**: tiles the fill reached (walkable, as far as locs can tell)
- **red fill**: tiles blocked by a loc (trees, tables, rocks…)
- **red lines**: wall edges that block movement (fences, walls, closed doors)

## Use

1. In the client console: `prf`, then `pon walkable-flood`. It computes once on enable.
2. Hold **Ctrl+Shift** and press:
   - **F**: recompute around where you're standing now
   - **G**: inspect the tile under the mouse. Logs whether the fill reached it, what blocks it
     (loc name, ID, shape, rotation), the locs whose south-west tile it is (blocking or not), and
     its ground height
   - **H**: hide/show the overlay
3. Each run logs a summary: tiles reached, blocked tiles, wall edges, how long it took, and a count
   of nearby locs by shape (and how many have `blockWalk`).

Console lines from the plugin are tagged `[WALKFLOOD]` (grep regex: `\[WALKFLOOD\]`).

## How it works

1. **Locs → collision.** `LocList.ByDistance` lists the nearby locs. Those whose
   `config.blockWalk` is true are applied by `shapeType`, following the old RS engine's rules:
   - Centrepieces, diagonal walls and roofs block every tile of their `width × length` footprint,
     starting from `coordGrid` (assumed to be the south-west tile).
   - Straight walls block one side of their tile and L-walls block two, chosen by `rotationType`
     (straight: 0 = W, 1 = N, 2 = E, 3 = S). The neighbouring tile gets the matching side, so the
     wall blocks both ways.
   - Wall decoration never blocks. Corner pillars are ignored: they only block diagonal steps, and
     a diagonal step needs both straight routes around it clear, so straight steps reach the same
     tiles.
   - Ground decoration is treated as non-blocking (`GROUNDDECOR_BLOCKS = false`). Most of it
     reports `blockWalk = true` even though you walk over it, and the API can't separate the few
     pieces that really block.
2. **Flood fill.** A breadth-first fill of straight steps from your tile, within `RADIUS` (32)
   tiles. A step is allowed unless the target is blocked, a wall is in the way, or the map isn't
   loaded there (`World.GetGroundHeight` fails).
3. **Draw.** Tile quads and wall lines, following the ground's slope, grouped into a few
   `ShapeInstance`s.

Work is spread over `Logic` ticks (`WORK_PER_TICK`), because the client aborts any Lua call over
1000 ms.

## What it can't see

- **Terrain blocking.** Water, cliffs and some map edges are blocked by map tile flags, not locs,
  and the API doesn't expose those. Expect the green to run into rivers and lakes.
- **Bridges and level changes.** Only locs on your level are used.
- NPCs and players aren't treated as obstacles.

## Validating it

Things to try, and what each tells us:

| Where | Look for | If it's wrong |
|---|---|---|
| A fenced field (e.g. Lumbridge sheep/cow pens) | Red lines along the fence; green stops at it | Wrong side → the rotation→side table is off |
| A building with doors | Closed door = red line; open it and recompute → green flows in | Doors may not be `WALL_STRAIGHT` or may not set `blockWalk` |
| A big object (furnace, large rock, 2×2+ table) | Red covers exactly its footprint | Offset by a tile → `coordGrid` isn't the south-west tile; check the `anchor check:` lines |
| Grass/flower patches | Green over them | If you really can't walk there, try `GROUNDDECOR_BLOCKS = true` |
| A riverbank or lake | Green spills onto water | Expected: terrain blocking isn't visible |
| A tile the game won't let you walk to but shows green | Ctrl+Shift+G on it | Tells us what kind of blocker we're missing |

## Why it isn't for submission

It's a research tool, and showing walkable areas automatically is close to the guidelines' ban on
"automatically showing where to stand or move" (see `docs/guidelines.md`). If it turns into a
player feature, it needs a moderation-friendly framing first.
