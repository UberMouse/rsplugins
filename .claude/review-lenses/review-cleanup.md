# Review lens: reuse, simplification & efficiency

Quality findings only; these are **not** correctness bugs. Suggest the concrete simpler or cheaper
form for each, and check that it behaves the same (nil, empty table, integer vs float) before
suggesting it.

## Part A — reuse

Code that reimplements something the plugin already has (a local helper, its `say()` logger, a
module in its folder), the Lua standard library (`table.concat`, `table.move`, `string.rep`,
`math.tointeger`, `utf8`), or the API itself (a list query such as `ByDistance`/`Filter` instead
of fetching `All()` and filtering by hand; `formatStr`; `CoordGrid` arithmetic helpers; `clamp`,
`lerp`). Prefer the existing one.

## Part B — simplification

Needlessly verbose or convoluted logic a clearer idiom collapses; redundant branches; dead code
(unused locals selene missed because they are table fields, unreachable branches, a constant
flag that is never flipped and only guards dead code); over-nested conditionals that an early
`return` flattens. Readable beats clever: moderators must follow it, so do not suggest a terser
form that is harder to read.

## Part C — efficiency & altitude

Avoidable repeated work: recomputing the same list query or config lookup inside a loop, O(n²)
neighbour checks where a keyed table gives O(1), string concatenation in a loop instead of
`table.concat`, re-creating tables or closures per entity per tick. Weigh it by where it runs:
the same waste in `Draw` or a per-tick handler matters; once at enable it rarely does.

Logic at the wrong layer: computed inside an event callback when it belongs in a pure helper the
callback calls, or the reverse.
