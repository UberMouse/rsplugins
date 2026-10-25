-- Walkable Flood: a dev-only experiment. It rebuilds the walls and blocked
-- tiles around the player from loc (scenery) data, flood-fills outward from
-- the player's tile, and draws the result on the ground:
--
--   * green fill  - tiles the fill reached (walkable, as far as locs can tell)
--   * red fill    - tiles blocked by a loc
--   * red lines   - wall edges that block movement
--
-- The API has no collision-flag getter, so this is an approximation built
-- from LocType.blockWalk, LocEntity.shapeType and LocEntity.rotationType. It
-- can't see terrain blocking (water, cliffs), which comes from map tile
-- flags rather than locs. The point is to measure how close loc data alone
-- gets. See README.md.
--
-- Keys (hold Ctrl+Shift):
--   F  recompute around the player
--   G  inspect the tile under the mouse (logs what blocks it)
--   H  hide/show the overlay
--
-- NOT for submission: see README.md.

-- Every console line from this plugin carries this tag, so it's easy to grep.
local function say(...)
    log("[WALKFLOOD]", ...)
end

-- How far the fill may spread from the player, in tiles. The fill works on a
-- square of (2 * RADIUS + 1) tiles a side, centred on the player.
local RADIUS = 32
local SIZE = RADIUS * 2 + 1

-- The client kills any Lua call that runs longer than 1000 ms, so the work is
-- done a slice at a time: each Logic tick (50 a second) does at most this
-- many units (one loc, one flood tile, or one drawn tile/edge each).
local WORK_PER_TICK = 500

-- Drawn tiles per ShapeInstance. Splitting keeps each ShapeData a modest size.
local ITEMS_PER_SHAPE = 1000

-- Heights above the ground, in fine units (512 = one tile), so the overlay
-- doesn't flicker into the terrain.
local FILL_HEIGHT = 16
local WALL_HEIGHT = 48

-- Colours are 0xRRGGBBAA.
local WALKABLE_COLOUR = 0x00FF0050
local BLOCKED_COLOUR = 0xFF000060
local WALL_COLOUR = 0xFF3030FF

-- Ground decoration (grass, flowers, rugs) usually reports blockWalk = true
-- even though you can walk over it. In the old engine only decoration that
-- explicitly blocks does, and the API can't tell the two apart. Flip this to
-- test the other assumption.
local GROUNDDECOR_BLOCKS = false

-- How many multi-tile locs to log per run, to check which tile coordGrid
-- refers to (we assume the south-west one).
local ANCHOR_SAMPLES = 5

-- Hotkeys: a GameKey held with Ctrl+Shift. Modifier bits are from the
-- ModifierKey table in the docs (SHIFT = 1, CONTROL = 2).
local CTRL_SHIFT = 1 | 2
local KEY_RECOMPUTE = GameKey.F
local KEY_INSPECT = GameKey.G
local KEY_TOGGLE = GameKey.H

---------------------------------------------------------------------------
-- Loc shapes and walls
---------------------------------------------------------------------------

-- LocShapeType values, from the docs (game/config/loctype).
-- stylua: ignore
local SHAPE_NAMES = {
    [0] = "WALL_STRAIGHT", [1] = "WALL_DIAGONALCORNER", [2] = "WALL_L",
    [3] = "WALL_SQUARECORNER", [4] = "WALLDECOR_STRAIGHT_NOOFFSET",
    [5] = "WALLDECOR_STRAIGHT_OFFSET", [6] = "WALLDECOR_DIAGONAL_OFFSET",
    [7] = "WALLDECOR_DIAGONAL_NOOFFSET", [8] = "WALLDECOR_DIAGONAL_BOTH",
    [9] = "WALL_DIAGONAL", [10] = "CENTREPIECE_STRAIGHT", [11] = "CENTREPIECE_DIAGONAL",
    [12] = "ROOF_STRAIGHT", [13] = "ROOF_DIAGONAL_WITH_ROOFEDGE", [14] = "ROOF_DIAGONAL",
    [15] = "ROOF_L_CONCAVE", [16] = "ROOF_L_CONVEX", [17] = "ROOF_FLAT",
    [18] = "ROOFEDGE_STRAIGHT", [19] = "ROOFEDGE_DIAGONALCORNER", [20] = "ROOFEDGE_L",
    [21] = "ROOFEDGE_SQUARECORNER", [22] = "GROUNDDECOR", [23] = "WALL_L_ALT",
    [24] = "WALLDECOR_DIAGONAL_BOTH_ALT",
}
local WALL_STRAIGHT, WALL_L, WALL_L_ALT, GROUNDDECOR = 0, 2, 23, 22

-- Shapes that block every tile they cover, as in the old engine: diagonal
-- walls, centrepieces (trees, tables, rocks) and roofs.
local FULL_TILE_SHAPES = { [9] = true, [10] = true, [11] = true }
for shape = 12, 21 do
    FULL_TILE_SHAPES[shape] = true
end
if GROUNDDECOR_BLOCKS then FULL_TILE_SHAPES[GROUNDDECOR] = true end

-- The other shapes don't affect where you can get to. Wall decoration never
-- blocks. Corner pillars (WALL_DIAGONALCORNER, WALL_SQUARECORNER) only block
-- diagonal steps, and a diagonal step is only allowed when both straight
-- routes around it are clear, so a fill using straight steps reaches the
-- same tiles.

-- Tile sides as bits. A tile's wall bits say which sides you can't cross.
local N, E, S, W = 1, 2, 4, 8
local SIDES = { N, E, S, W }
local SIDE_NAMES = { [N] = "N", [E] = "E", [S] = "S", [W] = "W" }
local OPPOSITE = { [N] = S, [E] = W, [S] = N, [W] = E }
-- Tile offset (x, z) for each side. Z points north.
local STEP = { [N] = { 0, 1 }, [E] = { 1, 0 }, [S] = { 0, -1 }, [W] = { -1, 0 } }

-- Which sides of its tile a wall covers, by RotationType (0-3). This is the
-- old-engine convention; checking it holds in RS3 is part of the experiment.
local STRAIGHT_SIDES = { [0] = W, [1] = N, [2] = E, [3] = S }
local L_SIDES = { [0] = W | N, [1] = N | E, [2] = E | S, [3] = S | W }

local function sidesText(bits)
    local names = {}
    for _, side in ipairs(SIDES) do
        if bits & side ~= 0 then names[#names + 1] = SIDE_NAMES[side] end
    end
    return #names > 0 and table.concat(names, " ") or "none"
end

---------------------------------------------------------------------------
-- The area being computed
---------------------------------------------------------------------------

-- Everything about the current run, or nil before the first one. Tiles are
-- addressed by local x/z (0 to SIZE-1, the player at RADIUS,RADIUS), packed
-- into one integer key. Functions that read it assert it first, which also
-- tells the type checker it is set from there on.
local area = nil ---@type table?

local function inBounds(lx, lz)
    return lx >= 0 and lx < SIZE and lz >= 0 and lz < SIZE
end

local function tileKey(lx, lz)
    return lz * SIZE + lx
end

-- World tile -> local tile.
local function toLocal(x, z)
    assert(area, "no run started")
    return x - area.originX + RADIUS, z - area.originZ + RADIUS
end

-- Remember why a tile is blocked, for the inspect key.
local function note(lx, lz, text)
    assert(area, "no run started")
    local k = tileKey(lx, lz)
    area.notes[k] = area.notes[k] or {}
    table.insert(area.notes[k], text)
end

-- Ground height at a tile corner (local corner coords 0..SIZE), cached.
-- Returns nil where the map isn't loaded.
local function cornerHeight(cx, cz)
    assert(area, "no run started")
    local k = cz * (SIZE + 1) + cx
    local h = area.heights[k]
    if h == nil then
        local fineX = (area.originX - RADIUS + cx) * 512
        local fineZ = (area.originZ - RADIUS + cz) * 512
        local height, ok = World.GetGroundHeight(area.level, fineX, fineZ)
        h = ok and height or false
        area.heights[k] = h
    end
    return h or nil
end

-- Whether the map is loaded at a tile, so the fill stops at the edge of the
-- loaded area rather than running into empty space.
local function tileLoaded(lx, lz)
    return cornerHeight(lx, lz) ~= nil
end

---------------------------------------------------------------------------
-- Stage 1: turn locs into blocked tiles and walls
---------------------------------------------------------------------------

local function blockTile(lx, lz, label)
    assert(area, "no run started")
    if not inBounds(lx, lz) then return end
    local k = tileKey(lx, lz)
    if not area.blocked[k] then
        area.blocked[k] = true
        table.insert(area.blockedList, k)
    end
    note(lx, lz, "blocked by " .. label)
end

-- Mark one side of a tile as a wall, and the matching side of the tile next
-- to it, so the wall stops movement in both directions.
local function addWallSide(lx, lz, side, label)
    assert(area, "no run started")
    local nx, nz = lx + STEP[side][1], lz + STEP[side][2]
    if inBounds(lx, lz) then
        local k = tileKey(lx, lz)
        area.walls[k] = (area.walls[k] or 0) | side
        note(lx, lz, SIDE_NAMES[side] .. " wall from " .. label)
        table.insert(area.edges, { lx, lz, side })
    end
    if inBounds(nx, nz) then
        local nk = tileKey(nx, nz)
        area.walls[nk] = (area.walls[nk] or 0) | OPPOSITE[side]
        note(nx, nz, SIDE_NAMES[OPPOSITE[side]] .. " wall from neighbour's " .. label)
    end
end

-- Log where a multi-tile loc says it is, to check our south-west assumption.
local function sampleAnchor(loc, label)
    assert(area, "no run started")
    if area.anchorSamples >= ANCHOR_SAMPLES then return end
    area.anchorSamples = area.anchorSamples + 1
    local c, pos = loc.coordGrid, loc.position
    say(
        formatStr(
            "anchor check: {} size {}x{} coordGrid {},{} position/512 {},{}",
            label,
            loc.width,
            loc.length,
            c.x,
            c.z,
            string.format("%.2f", pos.x / 512),
            string.format("%.2f", pos.z / 512)
        )
    )
end

-- Count each loc's shape, and apply it to the grid if it blocks walking.
local function applyLoc(loc)
    assert(area, "no run started")
    if not loc.isValid then return end
    local cfg = loc.config
    if cfg == nil then return end
    local shape, rotation = loc.shapeType, loc.rotationType
    local counts = area.shapeCounts[shape] or { all = 0, blocking = 0 }
    area.shapeCounts[shape] = counts
    counts.all = counts.all + 1
    if not cfg.blockWalk then return end
    counts.blocking = counts.blocking + 1

    local label = formatStr(
        "{} [{}] {} rot {}",
        cfg.configName,
        cfg.id,
        SHAPE_NAMES[shape] or shape,
        rotation
    )
    local c = loc.coordGrid
    local lx, lz = toLocal(c.x, c.z)

    if FULL_TILE_SHAPES[shape] then
        -- width/length are already rotated. Assumes coordGrid is the
        -- south-west tile of the footprint.
        if loc.width > 1 or loc.length > 1 then sampleAnchor(loc, label) end
        for dx = 0, loc.width - 1 do
            for dz = 0, loc.length - 1 do
                blockTile(lx + dx, lz + dz, label)
            end
        end
    elseif shape == WALL_STRAIGHT or shape == WALL_L or shape == WALL_L_ALT then
        local sides = (shape == WALL_STRAIGHT and STRAIGHT_SIDES or L_SIDES)[rotation] or 0
        for _, side in ipairs(SIDES) do
            if sides & side ~= 0 then addWallSide(lx, lz, side, label) end
        end
    end
end

-- One unit of work: apply the next loc. Moves on to flooding when done.
local function locStep()
    assert(area, "no run started")
    local loc = area.locs[area.nextLoc]
    area.nextLoc = area.nextLoc + 1
    if loc then
        applyLoc(loc)
    else
        area.locs = nil
        area.stage = "flood"
    end
    return 1
end

---------------------------------------------------------------------------
-- Stage 2: flood fill from the player
---------------------------------------------------------------------------

-- Whether you can step from tile k to its neighbour nk across `side`.
local function canStep(k, nk, side, nx, nz)
    assert(area, "no run started")
    return not area.blocked[nk]
        and (area.walls[k] or 0) & side == 0
        and (area.walls[nk] or 0) & OPPOSITE[side] == 0
        and tileLoaded(nx, nz)
end

-- One unit of work: take the next reached tile off the queue and reach its
-- neighbours. The queue doubles as the list of reached tiles, in order.
local function floodStep()
    assert(area, "no run started")
    local k = area.queue[area.head]
    if k == nil then
        area.stage = "draw"
        return 1
    end
    area.head = area.head + 1
    local lx, lz = k % SIZE, k // SIZE
    for _, side in ipairs(SIDES) do
        local nx, nz = lx + STEP[side][1], lz + STEP[side][2]
        if not inBounds(nx, nz) then
            area.hitEdge = true
        else
            local nk = tileKey(nx, nz)
            if not area.reached[nk] and canStep(k, nk, side, nx, nz) then
                area.reached[nk] = true
                table.insert(area.queue, nk)
            end
        end
    end
    return 1
end

---------------------------------------------------------------------------
-- Stage 3: draw the result
---------------------------------------------------------------------------

-- ShapeInstances this plugin has made, so they can be hidden or replaced.
local instances = {}
local shown = true

local function clearShapes()
    for _, instance in ipairs(instances) do
        if instance.isValid then instance:Destroy() end
    end
    instances = {}
end

-- World position of a tile corner, `lift` fine units above the ground.
local function cornerPos(cx, cz, lift)
    assert(area, "no run started")
    local h = cornerHeight(cx, cz) or 0
    return Vector3.new(
        (area.originX - RADIUS + cx) * 512,
        h + lift,
        (area.originZ - RADIUS + cz) * 512
    )
end

-- Shape data being filled, flushed to a ShapeInstance every ITEMS_PER_SHAPE items.
local function newBuilder()
    return { positions = {}, rgba = {}, tris = {}, lines = {}, items = 0 }
end

-- Append a vertex; returns its 0-based index, as tris/lines expect.
local function addVertex(b, pos, colour)
    table.insert(b.positions, pos)
    table.insert(b.rgba, colour)
    return #b.positions - 1
end

local function addTileFill(b, lx, lz, colour)
    local i = addVertex(b, cornerPos(lx, lz, FILL_HEIGHT), colour)
    addVertex(b, cornerPos(lx + 1, lz, FILL_HEIGHT), colour)
    addVertex(b, cornerPos(lx + 1, lz + 1, FILL_HEIGHT), colour)
    addVertex(b, cornerPos(lx, lz + 1, FILL_HEIGHT), colour)
    for _, offset in ipairs({ 0, 1, 2, 0, 2, 3 }) do
        table.insert(b.tris, i + offset)
    end
end

-- Corner offsets at each end of a tile side.
local SIDE_CORNERS = {
    [N] = { 0, 1, 1, 1 },
    [E] = { 1, 0, 1, 1 },
    [S] = { 0, 0, 1, 0 },
    [W] = { 0, 0, 0, 1 },
}

local function addWallLine(b, lx, lz, side)
    local c = SIDE_CORNERS[side]
    local i = addVertex(b, cornerPos(lx + c[1], lz + c[2], WALL_HEIGHT), WALL_COLOUR)
    addVertex(b, cornerPos(lx + c[3], lz + c[4], WALL_HEIGHT), WALL_COLOUR)
    table.insert(b.lines, i)
    table.insert(b.lines, i + 1)
end

-- Turn the builder into a ShapeInstance and start a new one.
local function flushBuilder()
    assert(area, "no run started")
    local b = area.builder
    area.builder = newBuilder()
    if b.items == 0 then return end
    local data = ShapeData.new()
    data.positions = b.positions
    data.rgba = b.rgba
    data.tris = b.tris
    data.lines = b.lines
    local instance = ShapeList.CreateInstance("walkflood" .. (#instances + 1))
    if instance == nil or not instance:SetShapeData(data) then
        say("could not create shape instance", #instances + 1)
        if instance then instance:Destroy() end
        return
    end
    instance.ignoreDepth = false
    instance.lineWidth = 4
    instance.visible = shown
    table.insert(instances, instance)
end

-- Report what the run found. Ticks are 50 a second.
local function reportDone()
    assert(area, "no run started")
    say(
        formatStr(
            "done in {} s: {} tiles reached, {} blocked tiles, {} wall edges, {} shapes",
            string.format("%.1f", area.ticks / 50),
            #area.queue,
            #area.blockedList,
            #area.edges,
            #instances
        )
    )
    if area.hitEdge then
        say(
            formatStr(
                "the fill reached the {}-tile radius limit, so the area is open "
                    .. "(or something blocking wasn't detected)",
                RADIUS
            )
        )
    end
    for shape = 0, 24 do
        local counts = area.shapeCounts[shape]
        if counts then
            say(
                formatStr(
                    "  shape {} {}: {} locs, {} with blockWalk",
                    shape,
                    SHAPE_NAMES[shape],
                    counts.all,
                    counts.blocking
                )
            )
        end
    end
end

-- One unit of work: draw the next item, in order: reached tiles, blocked
-- tiles, wall edges.
local function drawStep()
    assert(area, "no run started")
    local n = area.nextDraw
    area.nextDraw = n + 1
    local reachedCount, blockedCount = #area.queue, #area.blockedList
    local b = area.builder
    if n <= reachedCount then
        local k = area.queue[n]
        addTileFill(b, k % SIZE, k // SIZE, WALKABLE_COLOUR)
    elseif n <= reachedCount + blockedCount then
        local k = area.blockedList[n - reachedCount]
        addTileFill(b, k % SIZE, k // SIZE, BLOCKED_COLOUR)
    elseif n <= reachedCount + blockedCount + #area.edges then
        local edge = area.edges[n - reachedCount - blockedCount]
        addWallLine(b, edge[1], edge[2], edge[3])
    else
        flushBuilder()
        area.stage = "done"
        reportDone()
        return 1
    end
    b.items = b.items + 1
    if b.items >= ITEMS_PER_SHAPE then flushBuilder() end
    return 1
end

---------------------------------------------------------------------------
-- Running a computation
---------------------------------------------------------------------------

local STAGES = { locs = locStep, flood = floodStep, draw = drawStep }

-- Start a fresh run around the player's current tile.
local function recompute()
    local ok, player = pcall(Player.GetEntity)
    if not ok or player == nil then
        say("no player entity; log in, then press Ctrl+Shift+F")
        return
    end
    local c = player.coordGrid
    clearShapes()
    area = {
        stage = "locs",
        ticks = 0,
        originX = c.x,
        originZ = c.z,
        level = c.level,
        blocked = {},
        blockedList = {},
        walls = {},
        edges = {},
        notes = {},
        heights = {},
        shapeCounts = {},
        anchorSamples = 0,
        reached = {},
        queue = {},
        head = 1,
        hitEdge = false,
        builder = newBuilder(),
        nextDraw = 1,
    }
    -- Search a little past the square's corners (which are RADIUS * 1.41
    -- away), in case the distance is measured as a straight line, and to
    -- catch big locs whose south-west tile is just outside.
    local searchRange = math.ceil(RADIUS * 1.5)
    area.locs = LocList.ByDistance(c, searchRange, true)
    area.nextLoc = 1
    local start = tileKey(RADIUS, RADIUS)
    area.reached[start] = true
    area.queue[1] = start
    say(
        formatStr(
            "computing around {}: {} locs within {} tiles",
            tostring(c),
            #area.locs,
            searchRange
        )
    )
end

-- Each Logic tick, do up to WORK_PER_TICK units of the current run. Errors
-- abandon the run instead of repeating every tick.
local function onLogic()
    if area == nil or area.stage == "done" then return end
    area.ticks = area.ticks + 1
    local ok, err = pcall(function()
        local work = 0
        while area.stage ~= "done" and work < WORK_PER_TICK do
            work = work + STAGES[area.stage]()
        end
    end)
    if not ok then
        say("run failed in stage", area.stage, ":", err)
        area.stage = "done"
    end
end

---------------------------------------------------------------------------
-- Inspecting a tile
---------------------------------------------------------------------------

-- Log everything we know about the tile under the mouse: whether the fill
-- reached it, what blocks it, and the raw locs whose south-west tile it is.
local function inspect()
    local mouse = Mouse.GetPosition()
    local c = mouse and ScreenConvert.ScreenToCoordGrid(mouse)
    if c == nil then
        say("inspect: no tile under the mouse")
        return
    end
    say("inspect", tostring(c))
    if area and area.stage == "done" and c.level == area.level then
        local lx, lz = toLocal(c.x, c.z)
        if inBounds(lx, lz) then
            local k = tileKey(lx, lz)
            say(
                formatStr(
                    "  {}, blocked: {}, wall sides: {}",
                    area.reached[k] and "reached" or "not reached",
                    area.blocked[k] and "yes" or "no",
                    sidesText(area.walls[k] or 0)
                )
            )
            for _, text in ipairs(area.notes[k] or {}) do
                say("    " .. text)
            end
        else
            say("  outside the last run's area")
        end
    end
    for _, loc in ipairs(LocList.ByDistance(c, 0, true)) do
        if loc.isValid and loc.config then
            say(
                formatStr(
                    "  loc {} [{}] '{}' {} rot {} size {}x{} blockWalk {} hidden {}",
                    loc.config.configName,
                    loc.config.id,
                    loc.displayName,
                    SHAPE_NAMES[loc.shapeType] or loc.shapeType,
                    loc.rotationType,
                    loc.width,
                    loc.length,
                    tostring(loc.config.blockWalk),
                    tostring(loc.isHidden)
                )
            )
        end
    end
    local fine = c:ToCoordFine(true).position
    local height, ok = World.GetGroundHeight(c.level, math.floor(fine.x), math.floor(fine.z))
    say(formatStr("  ground height {} (loaded: {})", height, tostring(ok)))
end

---------------------------------------------------------------------------
-- Start up
---------------------------------------------------------------------------

local function toggleShown()
    shown = not shown
    for _, instance in ipairs(instances) do
        if instance.isValid then instance.visible = shown end
    end
    say(shown and "overlay shown" or "overlay hidden")
end

Event.KeyDown.Subscribe("walkFloodKeys", function(ev)
    if ev.isRepeat or ev.modifiers & CTRL_SHIFT ~= CTRL_SHIFT then return end
    if ev.gameKey == KEY_RECOMPUTE then
        recompute()
    elseif ev.gameKey == KEY_INSPECT then
        inspect()
    elseif ev.gameKey == KEY_TOGGLE then
        toggleShown()
    end
end)

Event.Logic.Subscribe("walkFloodRun", onLogic)

say("Ctrl+Shift+F recompute, Ctrl+Shift+G inspect tile under mouse, Ctrl+Shift+H hide/show")
recompute()
