# Review lens: correctness & data flow

Runtime correctness via **data-flow tracing**. Trace what the changed Lua actually *does* in the
client, end to end, not whether it looks idiomatic. For every changed function or callback, find
its callers (the event that fires it, the function that calls it, the tick that resumes it) and
the consumers of what it returns, and check the contract still holds. An error inside an event
callback aborts that call; code after it does not run, so the state it was updating stays
half-written.

## Part A — nil and missing values

- **Indexing a value that can be nil.** Optional event payload fields (`ev.entry.npcData` is nil
  unless the target is an NPC); API getters that return nil (a `T?` return in the docs:
  `Player.GetTrackingID()` until a few seconds after login or without the permission, an entity
  lookup for something that has left the area); `PersistentDB:Get` on an unset key; `require` of a
  file that is missing or errored; an optional dependency's global when that plugin is absent;
  `config.*` lookups by a name that does not exist. Find where the value comes from and whether it
  can be nil on a reachable path before accepting or dismissing the finding.
- **Defaults that mask a missing input**: `x or 0` / `x or ""` where nil meant "unknown" and the
  code then acts on the default as if it were real.
- **`false` vs `nil`**: `PersistentDB:Get(k) or true` can never yield a saved `false`; an
  `a and b or c` "ternary" yields `c` whenever `b` is `false` or nil.
- **Truthiness**: `0` and `""` are truthy in Lua. A check written as if they were falsy
  (`if count then`) takes the wrong branch.

## Part B — Lua semantics

- **`#` on tables that are not sequences.** On a table with holes (an element set to nil, keys
  assigned out of order) `#` may return any border; on a hash-keyed table it is not a count.
  `ipairs` stops at the first nil. Check how the table is filled.
- **Off-by-one**: 1-based indexing; `for i = a, b` includes `b`; `string.sub` is inclusive at both
  ends; converting between 0-based API values (tile coords, ids, local tile indexes) and 1-based
  Lua arrays.
- **Integer vs float.** `/` always yields a float (`4/2 == 2.0`); `//` floors. `string.format("%d",
  x)` raises an error for a float with a fractional part; `math.type` tells the two apart. Float
  keys that should be integers miss table lookups when they are not integral. Integer overflow
  wraps silently.
- **String patterns**: `string.find/match/gsub/gmatch` treat `( ) . % + - * ? [ ^ $` as magic.
  An unescaped one in a pattern built from data (a player-visible name, a config name) matches the
  wrong thing or raises "malformed pattern". `string.find(s, x, 1, true)` is the plain-text form.
- **Multiple returns**: `gsub` returns the result *and* a count; any call in the last position of
  an argument list, table constructor or `return` passes every value through
  (`t[#t+1] = s:gsub(...)` is fine; `table.insert(t, s:gsub(...))` passes the string as the
  insert position and errors). `pcall` returns `ok` first; using its first result as the value is a bug.
- **Varargs with nils**: `#{...}` and `table.unpack` stop or misbehave at a nil; use
  `select("#", ...)` / `table.pack(...).n`.
- **Mutating a table during `pairs`**: assigning a *new* key while iterating is undefined
  behaviour (clearing an existing key is allowed).

## Part C — state across ticks, events and reloads

- **Work sliced across `Logic` ticks** (the 1000 ms limit forces it): the world changes between
  slices. Check the resumed step still holds: the player moved, an entity was removed, a new run
  was started while the previous one is mid-slice (two jobs writing the same state), or the plugin
  was disabled mid-job.
- **Stale entity references**: an `NPCEntity`/`LocEntity`/`PlayerEntity` kept after its `*Removed`
  event, or across a region change, then read later.
- **Re-entrancy and ordering**: a callback that triggers work that fires the same event; state
  updated in one callback that another reads assuming a fixed order (`Logic` at 50 Hz, `Draw` per
  frame, `ServerLogic` once per server tick: they do not interleave in a guaranteed way).
- **Enable/reload**: `main.lua` runs again on every enable and `prl`. Module-level state starts
  fresh, but anything the previous run created outside Lua (drawn shapes, UI components, pending
  HTTP requests, PersistentDB entries) may not. Check the change does not double up or leak on a
  second enable, and that what must survive a reload is persisted.
- **Unreachable premises**: a check written against state it cannot observe: a flag nothing sets,
  a subscription to an event that never fires for this case (`*Added` for entities already nearby
  when the plugin enabled), a var the server never transmits. Confirm the premise by finding the
  writer or the event source, not by reading the new code's comment about it.

## Part D — error handling

- An error path that is swallowed (`pcall` result ignored) and leaves the plugin in a state it
  cannot leave (a `busy` flag never cleared, a job never finished, a request slot never freed).
- An error raised on a path that should degrade instead: one bad entity or var aborting the whole
  scan, rather than being skipped and logged.
- **Self-inflicted regressions**: a refactor in this change that breaks a path which worked
  before: a guard removed, a fallback defeated, an order-of-operations change.

## Reporting

Name the exact path that triggers the bug (the event, the input, the state) and what the user
sees. Apply the severity scale in `review-conventions.md`.
