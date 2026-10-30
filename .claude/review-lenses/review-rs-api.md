# Review lens: RS plugin API usage & client runtime limits

How the change uses the Client Plugin API and lives inside the client. The ground truth is
`docs/api-concepts.md` and `docs/plugin-anatomy.md` (read the sections the diff touches) and the
official reference at https://developer.runescape.com/rs/. Whether an API member *exists* and its
exact signature is the API-grounding lens's job; this lens asks whether the change uses the API
the way the client needs.

## Part A — the client's runtime limits

- **1000 ms per Lua call.** The client aborts any call that runs longer ("Maximum function
  execution time of 1000 ms exceeded"). Flag work in one callback, or in `main.lua`'s top level,
  whose cost grows with the world or the data: a loop over `LocList`/`NPCList` results, a var or id
  scan, a flood fill, building many shapes, encoding a large table. It must be sliced across
  `Logic` ticks with a bounded amount of work per tick, as `plugins/var-dump` and
  `plugins/walkable-flood` do. Judge the realistic worst case (a busy area, a full bank), not the
  case on your screen.
- **Per-frame cost.** `Draw` fires every rendered frame. Allocation, list queries or shape
  rebuilding in `Draw` that could run once per change (or per `ServerLogic` tick) costs frame rate
  for every user.
- **HTTP.** Starting a request from inside another request's completion callback has crashed the
  client (SIGABRT). Requests must be started from an event callback such as `Logic`, the body
  string kept referenced until the request finishes, and no coroutines wrapped around API calls
  (`docs/api-concepts.md`, *Runtime limits we've hit*).

## Part B — events and lifecycle

- **Subscription names.** `Event.X.Subscribe(name, fn)`: a second subscription with the same name
  on the same event replaces the first. Two features sharing a name silently lose one; a name
  derived from data can collide.
- **Teardown.** Subscriptions, drawn shapes and UI components the plugin owns must stop or be
  removed when the feature turns off (a toggle, a revoked permission, `PluginShutdown`), or they
  keep running and drawing.
- **Lifecycle hooks must be globals.** `PluginShutdown` / `PluginDependencyUpdate` declared
  `local` never fire. `PluginShutdown` does not run on a client crash, so it must not be the only
  place data is saved.
- **`*Added` events only fire for new arrivals.** A feature driven by `NPCEntityAdded` (or any
  `*Added`) that does not also scan the list once at startup misses everything already nearby
  when the plugin enables.
- **Payload fields.** Optional payload fields must be nil-checked before indexing; an unchecked
  nil crashes the callback (overlaps the correctness lens: report it there if it is purely a nil
  trace, here if it is a misreading of the event's contract).
- **Choice of event.** `ServerLogic` (once per server packet, ~0.6 s), `Logic` (fixed 50 Hz),
  `Draw` (per frame, `ev.timeDeltaSecs`). Timing derived from counting ticks of the wrong event,
  or animation driven by `Logic` instead of `Draw`'s delta, is wrong under load.
- **`VarTransmit`** may fire without the value changing, and may name only one VarBit of a base
  var per update (unconfirmed; see `docs/api-concepts.md`). Code that assumes every changed VarBit
  gets its own event misses updates.
- **`pcall` on API functions.** Pass a Lua closure, not the API function, to `pcall`
  (`pcall(function() Event.X.Unsubscribe(k) end)`, not `pcall(Event.X.Unsubscribe, k)`). Proven for
  `Unsubscribe` only: handed bare to `pcall` it aborted the client (`docs/api-concepts.md`,
  "Runtime limits we've hit"). dev-kit's `pcall(Mouse.GetX)` is live counterevidence that other
  functions survive it, so a bare call is a style finding, not a crash claim.
- **Permissions and dependencies change at runtime.** A feature gated on an optional permission
  or optional dependency must handle `OptionalPermissionChanged` / `OptionalDependencyChanged`
  (start when granted, stop when revoked), not just check once at enable.

## Part C — UI

- Components that use style sheets draw nothing until `stylesheetID` is set; `ui.Text` needs a
  `font`; `ui.Rectangle` draws an outline unless `fill = true`; colours are `Vector4` RGBA in
  0–1 (not 0–255, not hex). Every component needs a parent, normally the plugin build layer.
- UI input goes through component hooks (`component:Subscribe(ui.Hook.ONBUTTONPRESSED, fn)`), not
  `Event`.
- Components or shapes created on every tick or frame instead of once and updated: a leak, and a
  growing per-frame cost.
- Positions and sizes: the 4-argument `SetPos`/`SetSize` forms take a fraction of the parent's
  size; mixing them up with pixels puts the component off-screen.

## Part D — manifest, permissions, storage, modules

- `requiredPermissions` is broken in the client (the plugin does not run). Permissions belong in
  `optionalPermissions`, with `Plugin.HasPermission(...)` checked at runtime before use.
- HTTP may only reach base URLs declared in the manifest's `urls`, read via `Plugin.urls.<name>`.
  A hard-coded URL is a defect even when it matches.
- **PersistentDB** is slower than Lua variables: keep working state in memory and persist on
  change or at sensible points, not every tick. It is shared by every character played on the
  device (not per character) unless the key includes the character or tracking id. Defaults for
  unset keys must survive a saved `false`.
- **`require`**: the path is relative to the plugin root, not the calling file, with no extension;
  results are cached, so state in a required table is shared by every requirer; circular requires
  error; a failed require returns nil.
- **Dependencies**: an imported table is shared by every importer and must never be modified; an
  optional dependency's global is nil when that plugin is absent or disabled.
- **Resources**: keyed by filename without extension; PNG at most 1024×1024, Ogg Vorbis audio.

## Part E — dev-only API in shipped code

- `ExecuteConsoleCommand` and `!` cheat commands only work in the dev environment. A plugin meant
  for submission must not depend on them. (A dev tool marked "not for submission" may.)
- Console logging volume: logging every tick or every entity floods the console and costs time;
  logs must carry the plugin's greppable tag (`CLAUDE.md`).
