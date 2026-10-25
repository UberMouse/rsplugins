# Review lens: API grounding

Cross-check every Client Plugin API use the diff adds or changes against the **real** API
reference. This is the one lens whose ground truth is outside the repo. `scripts/check-lua.sh`
runs LuaLS against the community stubs in `docs/api/`, so where a value's type is known it already
catches an undefined member or global, a wrong argument type and an unchecked `T?`. It is blind
wherever the type is `any` (a `pcall` result, an untyped table, a value passed through our own
code), to a stub that is wrong or stale, and to everything the types do not say: units, ranges,
when an event fires. So a misspelt member, a `.` where the reference has `:`, a wrong argument
order or a missing payload field can still reach the client. Read the reference; do not judge
from memory or from what an API "would" look like.

## Where the truth lives, most authoritative first

The fastest lookup is the stubs: `grep -rn 'function Player\.' docs/api/generated/`, or open
`docs/api/generated/<section>/<page>.lua`. They are generated from the official pages and carry
their signatures and doc text, but they are third-party. When a stub decides a verdict, or looks
odd, confirm it against 1 or 2 below. Where they disagree, the official reference wins.

1. **The API search index**: one entry per API member, with its signature and examples in `text`
   (HTML). The prompt gives a local copy's path (`API INDEX`) when the gather step fetched it.
   Query it with jq, e.g.
   `jq -r '.items[] | select(.location | test("persistentdb"; "i")) | "\(.location) :: \(.text)"' <path>`
   or by title: `select(.title == "ByDistance")`. Locations are `core/`, `game/` (with `config/`,
   `entity/`, `list/`), `math/`, `ui/` (with `decorative_components/`, `interactive_components/`,
   `layout_components/`) and `audio/` pages. If no local copy was given, fetch
   https://developer.runescape.com/rs/search.json yourself (curl to a temp file, then jq).
2. **The rendered page** at `https://developer.runescape.com/rs/<location>` when an index entry is
   too terse (WebFetch).
3. **`docs/`**: our notes, including `docs/api-concepts.md` *Runtime limits we've hit* (client
   behaviour the official docs do not state) and `docs/vars/vars.csv` (every var the API exposes:
   grep the name there for any `var.VarPlayer.X` / `var.VarClient.X` the diff reads).
4. **Existing plugins** that already use the same member and are known to work in the client
   (`plugins/var-dump`, `plugins/walkable-flood`): evidence, but weaker than the reference.

## Step 1 — extract

List every API use the diff adds or changes: each global, namespace member, method, field,
event name, payload field, enum value (`GameKey.F`, `PluginPermissions.httpAccess`,
`SkillType.ATTACK`), `id.*` constant, `config.*` name, and var name, with how the code calls it
(`.` or `:`), the arguments it passes, and what it assumes about the result (type, nil-ability,
1- or 0-based, units: pixels vs relative, fine units vs tiles, 0–1 vs 0–255 colours).

## Step 2 — locate and compare

For each, find its reference entry and compare. Hunt specifically for:

- **Does not exist**: the member, event, payload field, enum value or var is not in the reference
  (or `vars.csv`). Calling a nil member errors on the first call; indexing a missing field reads
  nil and the code silently does nothing.
- **Call form**: the reference writes methods as `T:M(...)` and static functions as `T.f(...)`.
  `PersistentDB.Get(key)` passes `key` as `self`; `NPCList:ByName(n)` passes the table as the
  name.
- **Arguments**: count, order, types and ranges (an `Int32` id where a name string was passed,
  a `Float` 0–1 where 0–255 was passed, a required argument left out).
- **Returns**: a `T?` return used without a nil check; a list assumed to be an array that is a
  map (or the reverse); a value assumed to be a number that is a userdata or config object.
- **Event contracts**: the event's payload field names and when it fires (`*Added` only for new
  arrivals; `MiniMenuEntrySelected` includes left-clicks).
- **Units and coordinates**: `CoordGrid` (level, map square, local tile) vs `CoordFine` (512 fine
  units per tile); screen pixels vs relative sizes in the 4-argument `SetPos`/`SetSize` forms.

## Step 3 — verdicts

Give each API use a verdict, CONFIRMED / CONTRADICTED / UNVERIFIED, citing the reference
location (and a quoted signature) for the first two. Raise a finding for every CONTRADICTED use,
and for every UNVERIFIED use the change *depends on* (one the feature cannot work without),
saying what you searched for. Severity: critical when the contradicted use errors or makes the
feature do nothing on a reachable path; warning when it bites an edge case or only some inputs;
info for an UNVERIFIED use whose failure would be harmless. Do not raise findings for CONFIRMED
uses. Note in the suggestion when the existing plugins already call the member the same way
successfully: that lowers the odds it is wrong, but does not confirm it.
