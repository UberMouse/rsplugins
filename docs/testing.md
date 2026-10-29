# Testing plugins

`tests/harness/` runs a plugin's `main.lua` under plain Lua 5.4 against a mock of the Client
Plugin API, in a world the test scripts. A plugin that passes its tests should work in the client,
barring behaviour nobody has found yet. The [fidelity ledger](#fidelity-ledger) lists what is
modelled and on what evidence, and what isn't. Anything outside it still needs a check in the beta
client (`prl <plugin>`).

- Run the suite with `scripts/test-lua.sh`: busted, every `tests/**/*_spec.lua`, from the repo root
  (`.busted` holds the config). Pass busted arguments through, e.g.
  `scripts/test-lua.sh tests/chore-tracker` or `--filter=reload`.
- `scripts/check-lua.sh` always runs the whole suite as its last step, so the gate fails on a
  failing test.
- Nothing under `tests/` ships in a plugin.

## Layout

| Path | What |
|---|---|
| `tests/harness/init.lua` | The entry module, `require("tests.harness")`: lifecycle, clock, world builder |
| `tests/harness/world.lua` | The world as plain data, changed only by world ops |
| `tests/harness/api/*.lua` | The mocks, one module per API area; `api/prettyui.lua` is the PrettyUI fake and the `h.ui` driver ([Testing a PrettyUI plugin](#testing-a-prettyui-plugin)) |
| `types/prettyui.lua` | LuaLS types for the PrettyUI subset the fake models, loaded by `.luarc.json` |
| `tests/harness/sandbox.lua`, `runtime.lua`, `strict.lua` | The plugin's environment, client limits, strict proxies |
| `tests/harness/stubs.lua`, `catalog.lua` | Reads `docs/api/` and `docs/vars/vars.csv` |
| `tests/harness/timeline.lua`, `replay.lua` | Replaying a recording: grouping its entries by tick (pure), and driving the world from them |
| `tests/harness/*_spec.lua` | The harness's own tests |
| `tests/<plugin>/*_spec.lua` | A plugin's tests |
| `lib/dev/`, `scripts/rsdev.py` | The dev recorder and the daemon that receives it ([Recordings](#recordings)) |
| `scripts/recording-sanitise.py`, `recording-chat-allowlist.txt`, `test_recording_sanitise.py`, `tests/fixtures/` | Recorded sessions made into committed fixtures, the game chat a fixture may keep, and the sanitiser's tests ([Turning a session into a fixture](#turning-a-session-into-a-fixture)) |
| `tests/recorder/` | The recorder's tests, with `plugins/recorder-demo` |
| `tests/fixtures/client-surface.json`, `tests/harness/client_surface_spec.lua`, `tests/harness/surface_report.lua`, `scripts/client-surface.py`, `plugins/dev-bridge/probes/client-surface.lua` | The live client's API surface, the spec that checks the mocks against it, and the stub-vs-client report ([below](#checking-the-mocks-against-the-live-client)) |

## Writing a plugin test

```lua
-- tests/my-plugin/startup_spec.lua
local harness = require("tests.harness")
local SkillType = harness.enums.SkillType

describe("my-plugin", function()
    it("greets the player once they log in", function()
        local h = harness.new("my-plugin", { grant = { "chatAccess" } })
        h.world:setVar("VarPlayer", "ABSYSTEM", 3) -- world state from before the plugin starts
        h.world:setSkill(SkillType.MINING, { level = 50, xp = 101333 })
        h:load() -- runs plugins/my-plugin/main.lua

        h.world:login("Zezima")
        h:advance(600) -- 30 Logic ticks, 1 ServerLogic
        assert.are.equal("Hello Zezima", h.chatLog[1].message)

        h:reload() -- `prl my-plugin`: PersistentDB, world and permissions carry over
        assert.are.equal(1, h.db.greetings.value)
    end)
end)
```

- Set up the world before `h:load()` for state the client would already have, and after it for
  changes the plugin should react to. Builder calls fire their events immediately (to no
  subscribers before load).
- Specs run outside the sandbox: API globals (`Player`, `SkillType`...) don't exist there. Use
  `harness.enums.*` for enum values and `h.env.<name>` for the plugin's globals.
- `h.env.someGlobal` and `h.env.someFunction()` reach into the plugin. Prefer asserting on what a
  player would see (`h.chatLog`, `h:output()`, `h.requests`, `h.db`).
- To check an error, use `assert.matches(pattern, harness.errorOf(function() ... end))`. luassert's
  `error_matches` strips everything up to the first `file:line:`, which is the part that names the
  event and the plugin line.

## Harness API

### Module

| Call | Does |
|---|---|
| `harness.new(plugin, opts?)` | A harness, not yet loaded. `plugin` is a folder name under `plugins/`, a path containing `/`, or a table of inline files `{ ["main.lua"] = "...", ["plugin.json"] = "..." }` |
| `harness.load(plugin, opts?)` | `new` then `h:load()` |
| `harness.enums` | `ChatType`, `PersistentDBType`, `PluginPermissions`, `SkillType`, `ValueType`. `PluginPermissions` values are opaque, as in the client; the world builder (`grant`, `revoke`, `opts.grant`) names permissions by string |
| `harness.errorOf(fn, ...)` | The error message `fn` raises; fails if it doesn't raise |

`opts`: `grant = { "httpAccess", ... }` (permissions granted from the start, without an event),
`budgetMs = 1000` (the per-call time budget), `stdlib = { os = true, io = true, load = true }`
(opt in to withheld globals; only these three can be opted in, and `load` is for dev-bridge's
eval specs), `echo = true` (also print the plugin's console output), `absent = { "load", ... }`
(globals that read nil instead of faulting, modelling a client without them; for a plugin that
reports what its environment has, like `plugins/dev-bridge`). A global can't be both opted in
and absent. `randomSeed = 1` seeds `random()`, and `textWidth = function(fontID, text) return
n end` gives `utils.CalcTextWidth` its font metrics (without it, the call faults).

### The harness `h`

| Member | Does |
|---|---|
| `h:load()` / `h:unload()` / `h:reload()` | Enable (fresh env, run `main.lua`), disable (call a global `PluginShutdown`, drop subscriptions and pending HTTP callbacks), or both |
| `h:advance(ms)` | Run the clock forward in 20 ms logic steps; a remainder carries over. Each step: deliver answered HTTP requests, deliver queued `Chat.AddMessage` messages, fire `Logic`, and every 30th step `ServerLogic` |
| `h:fire(event, fields?)` | Fire any stub event; `fields` must be fields of the stub's `<Event>EventPayload`. For events the world builder doesn't model (`KeyDown`, `SkillTransmit`...) |
| `h:respond(record, response)` | Answer an HTTP request: `{ status = 200, body = "", header = "" }` (a status of 400 or more arrives failed), `{ timedOut = true }` or `{ error = "info", errorCode = n }`; any other field faults. Delivered on the next step. A request left unanswered for 10 s (500 steps) times out by itself |
| `h:useRecording(source, opts?)` | Drive the world from a recording (a `.jsonl` path, repo-relative or absolute, or a list of entries); call before `h:load()`. A recording with `dropped` entries is refused unless `opts.allowDropped`. See [Replaying a recording](#replaying-a-recording) |
| `h:playRecording()` | Step the clock to the recording's last tick |
| `h:output()` | Everything the plugin printed or logged, one line per call |
| `h.env` | The current sandbox environment |
| `h.console` | `{ kind = "print"|"log", text }` per call |
| `h.chatLog` | `{ message, chatType, sender }` per chat-window message, after subscribers' edits |
| `h.requests` | Started HTTP requests in order: `{ method, url, body, headers, request }` |
| `h.consoleCommands` | Every `ExecuteConsoleCommand` argument, in order |
| `h.onConsoleCommand` | Set by a test: called with each console command; raise in it to model a command that errors |
| `h.db` | PersistentDB entries, `key -> { type, value }`; survives reload |
| `h.dbWrites` | How many values the plugin has stored (`Set` and the typed setters), across reloads |
| `h.tick` | Logic ticks so far (`ev.logicTick`) |
| `h.ui` | The PrettyUI driver: find, click, drag and resize the plugin's PrettyUI objects ([below](#the-prettyui-driver-hui)) |
| `h.replay` | While replaying: `timeline`, `reads` (path -> `{ v }`, the reads seen so far), `skipped` (`{ t, event, why }` per recorded delivery the harness couldn't make) and `dropped` (`{ t, n }` per gap in the recording) |

### The world `h.world`

| Call | Fires |
|---|---|
| `setVar(domain, nameOrId, value)` | `VarTransmit`, on every call, naming the var set. A VarBit is packed into its base var (see the [fidelity ledger](#fidelity-ledger)) |
| `login(displayName)` / `logout()` | nothing |
| `setPosition(x, z, level?)` | nothing. The player's world tile (`level` defaults to 0), read back as `Player.GetEntity().coordGrid`; it survives a logout |
| `setSkill(skill, { level, xp, gameplay?, capped?, xpCapped? })` | nothing. The optional fields default to `level` / `xp` |
| `defineObj(nameOrId, fields)` | nothing. Gives an `ObjType` the stub fields a test needs (`name`, `category`...) |
| `setInventory(inv, { [slot] = { obj, count? } }, size?)` | `InventoryAdded` the first time, then `InventoryUpdated` with the changed slots (no event if nothing changed). A slot left out, or given as `{ obj = -1, count = 0 }`, is empty |
| `removeInventory(inv)` | `InventoryRemoved`; the Inv objects for it become invalid |
| `grant(perm)` / `revoke(perm)` | `OptionalPermissionChanged`, if it changed and the manifest lists it as optional |
| `chat(message, { chatType?, sender? })` | `ChatMessage` (default `ChatType.GENERAL`), if chatAccess is granted |
| `apply(op)` | Whatever the op changes |

Each builder call is a world op, e.g. `{ op = "setVar", domain = "VarPlayer", name = "X",
value = 3 }`. `world.apply(state, op)` (in `world.lua`) validates it, changes `h.world.state` and
returns the changes; the harness turns those into events. Ops are plain data, so a recorded
timeline can drive the same world.

### The PrettyUI driver `h.ui`

For a plugin that lists PrettyUI as a dependency. A target is an object the plugin got from
the fake (a Window, Panel, SpriteButton, CheckboxButton, a Text from `AddText`) or a component
such as `win.closeButton`. Plugin callbacks it triggers run under the client's limits, like
event subscribers.

| Call | Does |
|---|---|
| `find(kind, filter?)` | The live objects of `kind` (`"Window"`, `"Panel"`, `"SpriteButton"`, `"Text"`, `"Title"`, `"CheckboxButton"`, `"Divider"`), in creation order. `filter`: `{ sprite = "MENU" }` (any case), `{ text = "substring" }`, matched against a Window's title, a Text's current content or a checkbox choice, and `{ visible = true }` (neither it nor an ancestor hidden), in any combination |
| `get(kind, filter?)` | The one object `find` returns; errors on none or several |
| `click(target, value?)` | A SpriteButton: `action(button, true)`. A Window's `closeButton`: `Close()`. A CheckboxButton: toggles the choice whose value is `value`, firing `onChange`. Returns true, or false and why when the click wouldn't reach it: hidden (itself or an ancestor), under a window's title-bar drag layer, Alt held over a Panel, a disabled choice |
| `dragTitle(win, dx, dy)` | Drag a titled Window's title bar, clamped inside its parent |
| `resize(win, dw, dh)` | Drag a resizable Window's bottom-right corner; clamped to its min/max and the parent's edge |
| `holdAlt(held)` / `altDrag(panel, dx, dy)` | Hold Alt (with the console closed), then Alt-drag a Panel, clamped inside its parent. `altDrag` returns false and leaves the panel alone unless Alt is held |
| `hover(target, value?)` / `leave()` | Move the pointer onto a target (a CheckboxButton's choice by `value`), which shows its tooltip after the previous target's mouse-leave; or off it. Hovering a hidden target returns false. A target hidden since it was hovered gets no mouse-leave, so its tooltip stays |
| `tooltips()` | The text of every tooltip on screen |
| `choices(checkbox)` | A CheckboxButton's choices as `{ text, value, selected, disabled, tooltip }` in order, and its `colour` option as a second result |
| `layout(target)` | `{ x, y, width, height, hidden, globalX, globalY, visible }` of a component or an object's root. Specs can also read `x`, `y`, `width`, `height`, `hidden` and `xyGlobal` off the components directly |

## Strictness

The harness fails loudly rather than guessing:

- **`unmocked API: <name>`**: the plugin read a global, member or payload field the harness doesn't
  mock. Either the API is out of scope (see below) or the name is wrong. The fault is positioned
  at the plugin line, and if the plugin swallows it with `pcall` the call still fails afterwards.
  That includes a feature probe such as `pcall(function() return SomeApi.x end)`: unmocked use
  must be visible, and a probe means the mock needs extending.
- **`unmocked state: ...`**: the API exists but the test never set the value (a var's `.value`, a
  skill, an `ObjType` field, a payload field `h:fire` didn't pass). Set it in the test. This
  includes the `oldValue` of the first `setVar` of a var: set it before `h:load()` so the plugin
  sees a change from a known value.
- **`unrecorded: <path>`**: replaying, the plugin read something neither the world nor the
  recording has a value for, or checked a permission or PersistentDB key that neither the
  recording nor the test decided ([Replaying a recording](#replaying-a-recording)).
- **Unknown names**: vars must exist in `docs/vars/vars.csv`, and invs and objs in
  `docs/api/consts/{Inv,Obj}.lua`, so a misspelt `var.VarPlayer.X` or `config.Obj.X` fails the
  test.
- **Wrong call form**: `PersistentDB.Get(k)` (should be `:`) and `Player:IsAvailable()` (should
  be `.`) fault.
- **Own globals**: a plugin reading one of its own globals before assigning it also faults
  (`x = x or {}`). Use a local, or `rawget(_ENV, "x")`.
- **`_G` is not the plugin's env.** In the client it is one table of stdlib and API shared by
  every plugin; a plugin's own globals, `Plugin` and `require` aren't in it. So `_G.<own
  global>`, `_G.Plugin` and `_G.require` fault, and any write to `_G` faults, since in the client
  it would reach every plugin. `rawget(_G, name)` is nil for every name in the harness (the
  client finds the stdlib and API names there); use `_ENV` for the plugin's own globals.
- **With the dev recorder installed**, it reads every field of each recorded event's payload, so
  `h:fire` must pass them all and a var needs a value before `h:load()` (its first VarTransmit
  would otherwise have no `oldValue`). See [Recordings](#recordings).

`tests/harness/api_names_spec.lua` checks every mocked global and member against the stubs, with
its call form, and fails on any the stubs lack. It doesn't take the harness's word for it. The one
exception is listed with the official page that proves the stub wrong. A member a class inherits
counts (`ui.Layer:SetPos` is `ui.Component`'s). The PrettyUI fake's classes are not API, so they
are left out (`strict.class(..., { undeclared = true })`); `types/prettyui.lua` is their reference.

### Checking the mocks against the live client

The stubs can be wrong, so `tests/harness/client_surface_spec.lua` also checks the mocks against
`tests/fixtures/client-surface.json`, a snapshot of the beta client's API surface: every global
with its `type()`, the keys of each namespace, every enum's values, the members of the API types
a read-only snapshot reaches (`PlayerEntity`, `CoordGrid`, `Inv`, `InvSlot`, `InvType`, `ObjType`,
`VarType`, `PersistentDB`, `HTTPRequest`, `Vector2`, `ui.Interfaces`...), and the payload members
of the events that fired while it was taken. It holds names, types and enum numbers, nothing
about the player. The spec fails when:

- the harness serves a global or member the client lacks, wherever the snapshot covers the
  owner (a type no instance reached, like `ui.Text`, or a class table whose statics sol hides,
  like `HTTPRequest.new`, isn't checked);
- an enum value the harness serves differs from the client's (`PluginPermissions`, whose values
  are userdata in the client, is checked by name);
- a payload field the harness builds from the stubs is missing from a payload the snapshot has.

To refresh it (after a client update, or to cover more), with the bridge connected:
`scripts/client-surface.py [--wait 20]`. It runs `plugins/dev-bridge/probes/client-surface.lua`
through `rsdev.py eval`, waits for event payloads (play a little meanwhile: open a menu, move),
writes the fixture and ends with `eval --reset`. Review the diff before committing it.

`lua tests/harness/surface_report.lua` (dev shell, repo root) prints where the stubs and the
client disagree: per type and namespace, members only the client has (undocumented ones such as
`World.GetPing`) and members only the stubs have (renamed or invented ones, such as `Inv.valid`).
Check a finding against the official page before building on it.

## Lint and type-check config for tests/

`scripts/check-lua.sh` lints `tests/` with its own config, because spec and harness code run in
plain Lua and busted, not in the plugin sandbox:

- `tests/selene.toml` + `tests/tests.yml`: the root std plus the luassert assertions specs call.
  Add an `assert.*` member to `tests.yml` when a spec needs a new one.
- `tests/.luarc.json`: LuaLS against LuaLS's bundled busted and luassert definitions, *without*
  the API stubs. An API global used in a spec is a bug, since it is nil there. The root
  `.luarc.json` ignores `tests/`.

## Testing a PrettyUI plugin

When `plugin.json` lists PrettyUI by its numeric mod.io ID in the object form
(`"requiredDependencies": { "prettyui": 6398181 }`, or under `optionalDependencies`),
`h:load()` exposes the fake under that key's global. Naming PrettyUI any other way
(`["prettyui"]`, `["6398181"]`, `{ "prettyui": "6398181" }`) fails the load, since only that
form is proven in the client; so does any other dependency, naming it. The fake models the
part of PrettyUI 1.2.0 the Chore Tracker uses: `Window.new`, with `root`, `closeButton`, `SetSize`, `SetScrollPosition` (and the internal `_scroll.scrollY` it sets), `Show`, `Close`, `Destroy`, `AddText`, `AddTitle`,
`AddCheckboxButton` (with `SetOptionTooltip`), `AddDivider` and `AddSpriteButton`; `Panel.new`, with `root`, `width`,
`height`, `SetSize`, `AddSpriteButton` and `Destroy`; `SpriteButton.new`, with `SetTooltip`; `AchievementPopup.show` and `new`, with `root` and `Destroy` (the driver's `h.ui:popups()` lists them); and the tooltips of all of these. Any other member, method or option
faults as unmocked: extend `api/prettyui.lua` and `types/prettyui.lua` together, with a ledger
row, when a plugin needs more. LuaLS (`types/prettyui.lua`) doesn't flag an unknown option key
such as `titel`; the fake faults on it at test time.

```lua
local h = harness.load({ ["main.lua"] = main, ["plugin.json"] = manifest })
local win = h.ui:get("Window", { text = "Chores" })
h.ui:dragTitle(win, 100, 50)
h.ui:click(h.ui:get("SpriteButton", { sprite = "MENU" }))
assert.is_true(win.root.hidden)
```

`tests/harness/prettyui_spec.lua` has worked examples, including the probe's collapse-to-a-button
round trip.

## Recordings

The harness models the client from docs and guesses. The dev recorder (`lib/dev/`) checks those
guesses against the real thing. A plugin opts in; the recorder then notes what the plugin did with
the API in the beta client, and streams it to `scripts/rsdev.py` on this machine. A
recording shows what went wrong in the client, and is the input for replaying a session in the
harness. `plugins/recorder-demo` is the worked example.

### Opting a plugin in

1. Link the recorder in as the plugin's `dev/` folder, and commit the link:
   `ln -s ../../lib/dev plugins/<name>/dev`. It is a relative directory symlink, like the
   client's `dev_plugins` link itself, so the helper modules come with it. The beta client
   follows it (recorder-demo's probe said `recorder=true`, 2026-10-25). If a client ever
   refuses it, copy instead (`rm plugins/<name>/dev && cp -r lib/dev plugins/<name>/dev`), don't
   commit the copy, and re-copy after changing `lib/dev/`.
2. Make these the first lines of `main.lua`, before any other `require`:

   ```lua
   local recorder = require("dev/recorder") -- nil when dev/ isn't there
   if recorder then recorder.install(_ENV, "<name>") end
   ```

3. In `plugin.json`, add `"httpAccess"` to `optionalPermissions` and
   `"urls": { "recorder": "http://127.0.0.1:8766" }`.

`install()` swaps the API globals in the environment it is given for stand-ins that forward
every use to the real API. Without `urls.recorder` it logs one `[RECORDER]` line and changes
nothing. Without httpAccess it logs one line, records into its buffer and sends nothing, then
starts sending once the permission is granted (no reload needed). If the recorder itself fails,
it logs once and stops recording, and the plugin carries on.

**Modules.** `install()` swaps the globals of the environment passed to it. Every module shares
`main.lua`'s environment, in the harness and in the client (recorder-demo's probe said
`moduleSharesEnv=true moduleSeesSameEvent=true`, 2026-10-25), so the recorder sees the API use
of the plugin's other modules too.

**Moderation.** The recorder and recorder-demo are dev tools, never for submission. A plugin
for submission ships without `dev/`, without the two lines above, and without `urls.recorder`.
It keeps httpAccess only if a feature of its own needs it. Recordings hold the plugin's request
headers (an `Authorization` header included) and bodies, chat lines and display names, so keep
them local.

### Opting a plugin into the log tee

The log tee (`lib/dev/tee.lua`) is a separate dev module from the recorder: it ships a plugin's
`print`/`log` output and callback errors to `rsdev.py logs`, not recordings. Opt a plugin in
the same way (a `dev/` link, two lines at the top of `main.lua`, a `tee.shutdown()` call in
`PluginShutdown`, `httpAccess` and a url), but
with `require("dev/tee")`, `tee.install(_ENV, "<name>")` and `urls.rsdev`; docs/dev-environment.md
("Log tee") has the steps and behaviour. In the harness, a plugin with the link installs the
tee too: without `httpAccess` granted it is a no-op (one `[TEE]` console line), so existing specs
are unaffected; grant `httpAccess` and the plugin's console lines arrive as `POST .../tee`
requests in `h.requests` (`tests/tee/support.lua` decodes them; `tests/chore-tracker/tee_spec.lua`
is an example). The specs for the tee itself are in `tests/tee/`.

### Recording a session

1. From the repo root, run `scripts/rsdev.py start` (`--port`, `--out`; it listens on
   127.0.0.1:8766 and writes to `dumps/recordings/`, which is gitignored).
2. In the client: `prf`, `pon <name>`, `ppr <name>`, then `ppe <name> httpAccess`. Always
   `ppr` before `ppe`: `ppe` on a permission the plugin hasn't requested does nothing, and
   says nothing either.
3. Each enable is one session, written to `dumps/recordings/<name>/<time>-<session>.jsonl`. The
   daemon logs one line per batch (`dumps/rsdev/daemon.log`).

Console lines from the recorder carry `[RECORDER]` (grep: `\[RECORDER\]`).

### What is recorded

| Kind | When |
|---|---|
| `event` | A delivery to one of the plugin's subscriptions, once per delivery (whatever the number of subscribers), before the plugin's callbacks run, so before any edits. `Logic`, `Draw` and `EntityDraw` are not recorded: they fire every tick or frame, and `t` carries the time instead |
| `read` | A value read through `var`, `config`, `Player` or `Inventory`, or from an object reached from them, and every call on them. Reaching an object (`var.VarPlayer.QP`) isn't a read; reading `.value` from it is. Payload fields aren't reads (the payload is in the event), but a payload's configs are stand-ins, so `ev.var.value` is |
| `db` | Every `PersistentDB` method call |
| `perm` | `Plugin.HasPermission` |
| `http` | The plugin's own `HTTPRequest`s: `start` when `Get`/`Post` is called, `done` when its completion callback runs (no callback, no `done`). The recorder's own batches are not recorded |

A read, or a permission check, is recorded only when its value differs from the last one
recorded under the same path, so a value polled every tick costs one entry per change. Nothing
else is recorded: other globals (`Chat`, `World`, entity lists, `ui`...) and `print`/`log` pass
through untouched.

While recording, API objects are Lua tables (stand-ins), so `type()` gives `"table"` where the
client gives `"userdata"`. Two stand-ins compare equal when their objects do, and one object
always gets the same stand-in. `Event.<Name>` is a plain table of `Subscribe` and `Unsubscribe`,
so any other member is nil where the harness would fault.

**Limits.** Batches are POSTed only from the recorder's own `Logic` subscription, at most one a
second and one at a time, never from an HTTP callback. Each body stays referenced until its
request finishes. A batch holds up to 256 KB of entries. The buffer keeps up to 8 MB. Past that
the oldest entries are dropped, and so is a batch the receiver doesn't take, after which the next
POST waits 5 s. A failed batch isn't re-sent, so the buffer bounds memory but doesn't carry data
across a receiver outage: start the receiver before granting httpAccess. Drops (buffer overflow
and failed batches) are counted, and the first one logs one console line. One value is capped
at 10,000 nodes and each string at 4096 bytes, so recording a full bank stays well inside a
call's 1000 ms. Entries not yet sent when the plugin is disabled are lost (normally under a
second's worth), because nothing is sent from `PluginShutdown`.

### Format (schema 1)

A batch is `POST <urls.recorder>/record` with
`{"schema": 1, "plugin", "session", "seq", "dropped", "entries": [...]}`. `seq` counts batches
from 1 each enable, and `dropped` is the running total of entries lost. The receiver writes a
`{"k": "session", "schema", "plugin", "session", "started"}` line when a session starts, then
each entry on its own line in recording order. Before a batch whose `dropped` total has grown, it
writes `{"t", "k": "dropped", "n"}` to mark the gap. A new file starts for a new session name, or
when `seq` doesn't go up (a re-enable that drew the same name).

Every entry has `t`, the number of Logic ticks (50 a second) since `install()`, so 0 for anything
recorded while `main.lua` runs, and `k`, its kind:

| `k` | Fields |
|---|---|
| `read` | `path`, `v` |
| `event` | `name`; `payload`, each field the stub's `<Name>EventPayload` lists (none for `ServerLogic`); `op`, the world op it stands for, when the harness models one |
| `db` | `op` (the method, e.g. `GetInt`), `key`, `value` (the second argument, e.g. what `Set` stored), `v` (the result) |
| `perm` | `permission` (its name, e.g. `httpAccess`), `v` |
| `http` | `id`, `phase`. For `start`: `method`, `url`, `headers`, `body`. For `done`: `successful`, `failed`, `timedOut`, `cancelled`, `responseCode`, `errorCode`, `errorInfo`, `header`, `data` |

A missing field means nil (`v` of a `PersistentDB:Get` of an unset key, say).

**Paths** start at a global and add `.field`, `.Static(args)`, `:Method(args)` or `[slot]`:
`var.VarPlayer.QP.value`, `Player.GetEntity().displayName`,
`Inventory.Find(config.Inv.INV):GetSlots()`, `Inventory.Find(config.Inv.INV):GetSlots()[1].count`.
A config is always named `var.<typeName>.<configName>` or `config.<typeName>.<configName>`,
however it was reached (`var.VarPlayer.FromID(463)`, `ev.var`), so one key serves every read of
it. Other objects keep the path they were first reached by. Arguments are written as a
stand-in's path, a quoted string, or a number, boolean or `nil`.

**Values.** Plain data is copied. A config is `{"config": configName, "id", "type": typeName}`,
an `InvSlot` is `{"obj": <config>, "count"}`, and any other API object is its `tostring()`
text without the memory address (`sol.jag::InventoryProxy`, not
`sol.jag::InventoryProxy: 0x591cbdbce258`): `Inventory.Find()` and `Player.GetEntity()` hand out
a fresh object per call, so with the address every call would be recorded. A table met again
inside itself becomes `"<cycle>"`, a string over the cap ends `<+N bytes>`, and the first value
past the cap becomes `"<truncated>"`, with the rest left out. A table keyed 1..n is a JSON array and any other a JSON object with
string keys, so a table with holes comes back as `{"1": ..., "5": ...}`. (`GetSlots()` is dense
in the client, so inventories come back as arrays, with empty slots as obj -1.)

**World ops** in `event.op` use the shapes `world.apply` takes:

| Event | `op` |
|---|---|
| `VarTransmit` | `{"op": "setVar", "domain", "name", "id", "value"}` (`value` is the new value) |
| `InventoryAdded`, `InventoryUpdated` | `{"op": "setInventory", "inv": id, "size", "slots": {slot: {"obj": id, "count"}}}`. The whole inventory, which the recorder reads itself when the event arrives, since the payload only lists changed slots |
| `InventoryRemoved` | `{"op": "removeInventory", "inv": id}` |
| `OptionalPermissionChanged` | `{"op": "setPermission", "permission", "enabled"}` |
| `ChatMessage` | `{"op": "chat", "message", "chatType", "sender"}` (`sender` is `senderNameUnfiltered`) |

### Replaying a recording

A recording replays as a world timeline: the plugin runs in the harness again, and the world
does what the recording says it did. Scripted and replayed changes share one world, so a test
can start from a recording and script more on top, during or after it.

```lua
local h = harness.new("recorder-demo", { grant = { "chatAccess" }, stdlib = { os = true, io = true } })
h:useRecording("tests/fixtures/recorder-demo-shop.jsonl")
h:load()            -- main.lua sees the reads recorded at t = 0
h:playRecording()   -- step to the last recorded tick
h.world:setVar("VarPlayer", "QP", 12) -- then script as usual
```

- **Events fire at their recorded tick** (`t` = `h.tick`), after that tick's `Logic` (events
  at `t = 0` straight after `main.lua`). Each event's `op` is applied to the world first,
  without the events the world would derive from it, and then the recorded event is fired: an
  `InventoryUpdated` stays one even for an inventory new to the world. Payload API objects
  are rebuilt from the world (`ev.var`, `ev.inv`); an event with any other object in its
  payload faults. If the recording has any `ServerLogic`, then while it lasts `ServerLogic`
  comes only from it; one without (the plugin never subscribed) leaves the harness clock
  firing it every 30 ticks.
- **Reads.** A mock serves what the world holds, and otherwise the latest read recorded under
  the same path at or before the current tick. A read the recording never made faults with
  `unrecorded: <path>`. Reads made by an event's callbacks are in place before that event
  fires, and reads made by `Logic` callbacks before `Logic` fires (within one tick, a later
  read of a path wins). Reads the world models also go into the world: a var's `.value`
  (when the world can hold the value) and the login (below).
- **Permissions and PersistentDB** don't fall back to the scripted world's defaults (not
  granted, unset), since the client's answer may have differed. `Plugin.HasPermission` of a
  permission that no `perm` entry, `opts.grant`, `h.world:grant`/`revoke` or recorded
  `OptionalPermissionChanged` has decided faults `unrecorded: Plugin.HasPermission(<perm>)`. A
  `Get*` or `CheckExists*` of a key the store doesn't hold faults
  `unrecorded: PersistentDB:<Method>("<key>")` unless the recording has a `db` entry for it
  or the plugin deleted it or called `Clear` during the replay. A key
  the plugin stores, or the test puts in `h.db`, is answered from the store.
- **An inventory the recording knows but the world doesn't yet** (no Added/Updated event so
  far): `Inventory.Find` returns a new `Inv` each call (as the client does) whose every member
  is the recorded read under its path (`Inventory.Find(config.Inv.INV).usedSlotCount`), or nil
  if Find was recorded returning nil. Once the world has the inventory, Find returns
  world-backed `Inv`s.
- **Starting state.** The login is inferred from `Player.IsAvailable()` and
  `Player.GetEntity().displayName` reads. PersistentDB is seeded from each key's first
  `db` entry, when that is a `Get`/`GetInt`/... that found a value (a key the plugin wrote
  first is left unset). Permissions start as their first `perm` entries say, over
  `opts.grant`; later changes come from `OptionalPermissionChanged` events. A recording made
  of a plugin that never calls `Plugin.HasPermission` has no `perm` entries, so grant what it
  needs in `opts.grant`: replaying a `ChatMessage` without chatAccess faults.
- **Normalised on load**: JSON string slot keys (`{"1": ...}`) become integers, and a
  `ChatMessage` of `ChatType.PLUGIN` (the plugin's own `Chat.AddMessage` coming back) is
  dropped, since the harness delivers those itself.
- **Not applied to the world**: a `setVar` whose var isn't in `docs/vars/vars.csv`, or whose
  value its type can't hold in the harness (config-typed vars, BOOLEAN vars, which
  VarTransmit reports as 0/1, and the two VarBits the catalog gives no bits,
  `PSR_XPBLOCKSKILLS_0_LISTENER` and `_1_LISTENER`). The event still fires with the recorded
  values, except for a var the catalog lacks: then the delivery is skipped and listed in
  `h.replay.skipped`.
- **Gaps.** After a `dropped` line, reads and the world may not match what the plugin saw,
  so `h:useRecording` refuses a recording with one, giving the count, unless the test passes
  `{ allowDropped = true }`; then `h.replay.dropped` lists the gaps (`{ t, n }`).
- `http` entries aren't replayed: answer the plugin's requests with `h:respond`. The header's
  `schema` must be 1.

### Turning a session into a fixture

A fixture is a recorded session, sanitised and trimmed, committed under `tests/fixtures/` for a
spec to replay. `tests/fixtures/recorder-demo-shop.jsonl` (replayed by
`tests/recorder/fixture_spec.lua`) was made this way.

1. Record the session (above), and find the ticks worth keeping, e.g.
   `jq -c 'select(.k == "event") | [.t, .name, .payload.inv.config]' <session>.jsonl`.
2. Sanitise it:
   `scripts/recording-sanitise.py dumps/recordings/<plugin>/<session>.jsonl
   tests/fixtures/<name>.jsonl --from <t> --to <t>`. The script:
   - replaces the player's display name, as the recording's own
     `Player.GetEntity().displayName` reads give it, with a placeholder (`--placeholder`,
     default `Fixture Player`) in every string: read values, chat sender fields, and inside
     any other text. It matches case-insensitively as a substring, with a space, underscore,
     hyphen or no-break space in the name matching any of them, and prints how many it
     replaced, never the name. It refuses a recording without that read, and a name under 4
     characters (which would match inside other words) without `--short-name-ok`. It looks
     for the name in its output, as text and in every string the text decodes to, before
     writing and again in the file read back; if it is there, it exits non-zero and leaves
     none of its output on disk. It refuses an output path that is the session file.
   - redacts every chat message with a non-empty sender (one a player sent): its text and
     sender fields become `<redacted>`.
   - keeps game chat (no sender) only if the whole text matches a line of
     `scripts/recording-chat-allowlist.txt`, a list of regexes each anchored as a whole (`^`
     first, `$` last, any `|` inside a group, which the script checks). Any other game text
     becomes `<redacted:N chars>`, N its length in characters, keeping its `chatType`, so a
     game message naming another player ("Bob has logged in.") never reaches a fixture.
     A pattern must not be able to match a player's name, so the script refuses free-form
     slots (`.`, `\w`, any class but `[0-9,]`, hex anywhere but the `<col=[0-9A-Fa-f]{6}>`
     tag, inline flags; the full rule heads the allowlist), leaving fixed text, numbers,
     colour tags and lists of known names.
     To keep a new message, add a pattern for it and re-run.
   - strips memory addresses from object text, as the recorder now does, and drops the reads
     that then repeat.
   - keeps only the entries with `--from <= t <= --to`, rebased so `--from` is `t = 0`. What
     the plugin knew before the window comes in at `t = 0`: the latest read of each path, the
     latest check of each permission, and one `Get` per PersistentDB key of the value it held
     (a key stored before the window seeds the replay's store). Events before the window are
     dropped, so the world starts empty and the replay serves what the plugin had read; an
     inventory, say, is a [read-backed Inv](#replaying-a-recording) until its first update in
     the window. The header gains `"window": [from, to]`.
   - refuses a `dropped` line at or before `--to` unless `--allow-dropped`: in the window it is
     a gap, and before it the state carried in at `t = 0` may be wrong. Allowed, the window's
     are kept and the earlier ones become one at `t = 0`, so the spec must pass `allowDropped`
     too. A `dropped` line without a tick is always refused, here and by the harness.
3. Check the result before committing: count the display name's matches in it (0 means
   none), e.g. ``grep -ci "$(jq -r 'select(.path == "Player.GetEntity().displayName") | .v' <session>.jsonl | head -1)" <fixture>``,
   and read what chat is left (`jq -c 'select(.name == "ChatMessage") | .payload.chatMessage'`).
   The script only knows the player's own name and the chat it redacts: a plugin that copies
   chat text into a read or the store, or reads other players' names, needs a look by hand.
4. Keep it small: a window of a minute or so is tens of KB. A bank update is about 40 KB on
   its own (1920 slots), so leave bank changes out of the window unless the test needs one.
5. Replay it in a spec with `h:useRecording("tests/fixtures/<name>.jsonl")`.

`scripts/check-lua.sh` also runs the sanitiser's tests, `scripts/test_recording_sanitise.py`.

## Fidelity ledger

### Modelled, with its source

| Behaviour | Source |
|---|---|
| `require`: path from the plugin root, no extension; runs once per load and caches the result; nil for a missing file; circular requires are an error | [plugin-anatomy.md](plugin-anatomy.md#modules-require) |
| A `require`d module runs in `main.lua`'s environment (same globals, same `Event`); a directory symlink inside the plugin folder is followed | recorder-demo's probe line in the beta client, 2026-10-25 |
| A plugin's env holds its own globals, `Plugin` and `require`, and falls through to one table of stdlib and API, which is `_G` (`_G._G == _G`, `_G ~= _ENV`); that table outlives the plugin's reload. The harness's `_G` reads like it (not the plugin's own globals) and faults on writes | dev-bridge eval, 2026-10-26: the bridge's env had 6 keys (`Plugin`, `require`, `PluginShutdown`, `__THIS_PLUGIN`, `__PACKAGES_LOADED`, `__PACKAGES_LOADING`) and a metatable whose `__index` was a 291-key table equal to `_G`; a key set in it survived `prl dev-bridge`. Whether other plugins share it is unproven |
| A global `PluginShutdown` runs on disable/reload (a `local` one doesn't); reload = fresh env, PersistentDB kept | [plugin-anatomy.md](plugin-anatomy.md#lifecycle-hooks-global-functions), [dev-environment.md](dev-environment.md#plugin-management-commands) |
| A manifest with `requiredPermissions` doesn't run, so the harness refuses it | [plugin-anatomy.md](plugin-anatomy.md#manifest-pluginjson) |
| Subscribers run in subscription order; a payload edited by one subscriber is what the next sees (fields the stub doesn't mark "(Read-only)", such as `ChatMessage.chatMessage`, are writable) | [core/events.html#overview](https://developer.runescape.com/rs/core/events.html#overview), #event-payloads; live, two `ServerLogic` subscriptions ran in the order made |
| `Subscribe` with a name the event already has does nothing: the first callback stays, in its place (the page says the name is replaced). After `Unsubscribe`, subscribing the name again puts it last. `Unsubscribe` returns true if it removed the name, false if there was none. A subscriber unsubscribed by an earlier one during a dispatch isn't called later in that dispatch | dev-bridge eval, 2026-10-26, real `ServerLogic` subscriptions made from `Logic`: `rA`, `rB` ran `A B`; subscribing `rA` again with a new callback left `A B` (no error); `Unsubscribe("rA")` then `Subscribe("rA", A3)` gave `B A3`; `rC` unsubscribing `rD` in pass 3 left no `D3`; `Unsubscribe` gave true, then false for a removed name |
| `Logic` at a fixed 50 Hz with `logicTick`; `ServerLogic` about every 600 ms with no payload | core/events.html#logic, #serverlogic; recording `20261025-144642-8f7250b863`: about 3000 Logic ticks per `CLOCK_TIME_DATE_MINUTES` minute, and `ServerLogic` 30 ticks apart two times in three (16 to 82 seen). The harness's is exactly every 30 |
| `VarTransmit` fires on every update, changed or not, after the value is set, with `var`, `oldValue`, `newValue` | core/events.html#vartransmit |
| VarBit packing: a VarBit's `.value` is its catalog `bits` of its base var's value, unsigned, the base a 32-bit int that may be negative. Setting the base fires one `VarTransmit` naming the base (base old/new); setting a VarBit writes its bits into the base, keeping the others, and fires one naming the VarBit (field old/new). A value that doesn't fit the bits faults, as does any non-LONG int var's value outside signed 32 bits. A VarBit set while its base is unset starts the base at 0 (so its first `oldValue` is 0); reading one whose base is unset faults as unmocked. Replay packs the same way and delivers each event under the var the recording named. The catalog has no VarClient VarBits | var-dump change log, 2026-10-25 (`dumps/var-dump/changes.jsonl`): claiming Bert's sand sent `HANDSAND_BUCKETS` (2801) 0 -> 1 -> 3 and `HANDSAND_BUCKETS_CLAIMED_TODAY` (bit 1) then read 1; chopping sent `LEAGUE_TASK_PROGRESS_CHOP_ANY` (a VarBit of `LEAGUE_TASK_PROGRESS_BASE_3`) by its own name, 0 -> 1 -> 2 -> 3 -> 4; `TOPLEVEL_V2_PARENT_VARP_1` arrived under its own name and two of its VarBits' names. Bits from `docs/vars/vars.csv` |
| `var.<Domain>.NAME` and `FromID(id)` give one VarType per var (`ev.var == var.VarPlayer.X`); VarBits report `isVarBit`, `baseVar`, `varBitMask`; `baseVar`/`varBitMask` are nil otherwise; properties are read-only | game/config/vartype.html, `docs/vars/vars.csv` |
| `Player.IsAvailable` says whether player data can be read | game/player.html#isavailable |
| `PlayerEntity.coordGrid` is the player's tile as a `CoordGrid` with `level`, `x`, `z` (world tiles), `mapSquareX`/`Z` (`x // 64`) and `localX`/`Z` (`x % 64`) | game/entity/playerentity.html#properties, game/coordgrid.html#properties; a map square is 64 tiles ([api-concepts.md](api-concepts.md#coordinates)) |
| `Inventory.Find` returns an `Inv`; slots are 1-indexed; `GetSlot`/`GetSlots` return copies; an Inv goes invalid (`isValid`) when its inventory is removed, and re-adding it makes a new Inv | game/inventory.html |
| A fresh object per call: `Player.GetEntity()` and `Inventory.Find()` give a new userdata every call. Two entities of one login are `==` (not `rawequal`, so not one table key); two Invs from `Find` are not `==` | recording `20261025-144642-8f7250b863` (a new object per call); dev-bridge eval, 2026-10-26 (`GetEntity() == GetEntity()` true, `Find(INV) == Find(INV)` false, `rawequal` false for both) |
| `Inv:GetSlot` of an empty slot, or of an index past either end (0, 9999), is an obj -1 x0 slot, never nil or an error | dev-bridge eval, 2026-10-26 (backpack slot 28 empty, and 0 and 9999) |
| `Inv:GetSlots()` is dense, one slot per index up to `slotCount`, with each empty slot as obj -1 (configName `UNKNOWN`) and count 0. A real obj with count 0 is not empty: a bought-out shop line stays in its shop inventory that way (GENERALSHOP1 slot 7, obj 590 x0) | `tests/fixtures/recorder-demo-shop.jsonl`, trimmed from recording `20261025-144642-8f7250b863` (recorder-demo in the beta client, 2026-10-25) |
| `InventoryAdded`/`Updated` (`slotsUpdated`)/`Removed` carry the `InvType` | core/events.html#inventoryadded and below |
| PersistentDB: Get nil when unset; typed getters nil on a type mismatch; Set returns a Bool; unsupported table fields are dropped; `IterateEntries` stops on `true` and returns the count; persists across reload | core/persistentdb.html |
| `PersistentDBType` values 0–4 (the stub has strings) | core/persistentdb.html#persistentdbtype |
| `PluginPermissions` values are opaque (`sol.jag::scripting::PluginPermission`, a pointer `tostring`, the same object on every read, not `==` the name), and `Plugin.HasPermission` takes only them: a name string faults with the client's `expected userdata, received string` error. So turn `OptionalPermissionChanged`'s `permissionName`, the key as a string (`chatAccess`), into one with `PluginPermissions[ev.permissionName]` | dev-bridge eval, 2026-10-26: `type(PluginPermissions.httpAccess)` userdata, `Plugin.HasPermission("httpAccess")` raised; a probe on `OptionalPermissionChanged` while the user ran `ppd`/`ppe dev-bridge chatAccess` saw `permissionName` the string `chatAccess`, and `PluginPermissions[it]` `rawequal` to `PluginPermissions.chatAccess` |
| `Plugin.HasPermission`, `Plugin.urls.<name>` from the manifest; a name the manifest lacks reads nil, without an error (and `HTTPRequest.new` faults on that nil) | core/plugin.html; dev-bridge eval, 2026-10-26 (`Plugin.urls.nope`) |
| `OptionalPermissionChanged` (`permissionName`, `enabled`) fires for optional permissions | core/events.html#optionalpermissionchanged |
| HTTP needs httpAccess, and a base URL from the manifest's `urls`; `Get`/`Post`/`AddHeader` on an active request raise (`This request is already being executed`); the completion callback receives the request (`==` it) | core/http.html; dev-bridge eval against the rsdev daemon, 2026-10-26 (beta 951-1) |
| A reply of 400 or more finishes `failed` (not `successful`), with `responseCode` set, `errorCode` 0, `errorInfo` and `data` empty and `progress` nil. A 200 is `successful` with `progress` 1 and `downloadedBytes` = `downloadTotalBytes` = the body's length. The callback runs on a later Logic tick, never inside `Get`/`Post`; until then a request reads `finished`, `successful` false, `data` "" and `responseCode` 0 | dev-bridge eval, 2026-10-26: GET `/probe-404` (404), POST `/tee` "not json" (400), GET `/cli/status` (200, 422 bytes), each finished 1-2 Logic ticks after the call |
| The client gives up after 10 s: `timedOut` and `failed`, `errorCode` 28 (libcurl's `CURLE_OPERATION_TIMEDOUT`), `errorInfo` `ErrorOperation timed out after 10001 milliseconds with 0 bytes received`, `responseCode` 0. The harness times out a request unanswered for 500 steps the same way | dev-bridge eval, 2026-10-26: a 100 s long-poll to the daemon finished 500 Logic ticks after `Get` |
| `Cancel` never calls the completion callback. Straight after it the request reads `cancelled`, not `finished` or `failed`; later it reads `finished` and `failed` (the harness: on the next step) | dev-bridge eval, 2026-10-26: cancelled one tick after `Get`; no callback after 20 s; `finished` and `failed` true when next read |
| Starting an HTTP request inside a completion callback fails the test (it crashed the client) | [api-concepts.md](api-concepts.md#runtime-limits-weve-hit) |
| `Event.<X>.Unsubscribe` faults (fails the test, even under the plugin's own `pcall`) when a C function is its immediate caller, i.e. it was passed straight to `pcall` or `xpcall`: "Event.X.Unsubscribe passed straight to pcall: the client aborts (SIGABRT)". The harness checks the caller's frame (`debug.getinfo`'s `what`, and `istailcall` to let a tail call through). A direct call is fine anywhere: at load, inside any callback (of a subscription made inside a callback too) and in `PluginShutdown`; so are a closure under `pcall`, `pcall(function() Event.X.Unsubscribe(k) end)` (dev-kit's form), and a tail call from a function `pcall` called (`local function drop(k) return Event.X.Unsubscribe(k) end; pcall(drop, k)`), both seen live | seven live aborts 2026-10-26 with dev-bridge (systemd coredumps), every one `pcall(Event[event].Unsubscribe, ...)` or `pcall(real.Event.Logic.Unsubscribe, ...)`: inside a probe's own `Logic` callback, from `Logic`, from an `HTTPRequest:Get` completion callback, and four times in a `PluginShutdown` run by the bridge's own `prl` from `Logic`. Direct calls survived: stage 1's `PluginShutdown` on the same self-`prl`, twice, and a runtime-made `VarTransmit` subscription unsubscribed directly from inside `Logic`. The closure and tail-call forms survived from `Logic` on real `ServerLogic` subscriptions (dev-bridge eval, 2026-10-26, session 7bcb60d109). This replaces the earlier rule, withdrawn, that faulted an Unsubscribe of a subscription made inside a callback, and any Unsubscribe during a dispatch or HTTP completion. [api-concepts.md](api-concepts.md#runtime-limits-weve-hit) |
| `clamp`, `lerp` (of Floats) and `random(min, max)` return floats; `random` with fewer than two numbers raises | math/index.html; dev-bridge eval, 2026-10-26 (`clamp(5, 0, 3)` 3.0, `lerp(0, 10, 0.25)` 2.5, `random(1, 10)` 4.27, `random()` raised) |
| A call running past 1000 ms is aborted with `Maximum function execution time of 1000 ms exceeded` | [api-concepts.md](api-concepts.md#runtime-limits-weve-hit) |
| `Chat` needs chatAccess; `AddMessage` is queued until the next logic update and comes back as `ChatMessage` with `ChatType.PLUGIN`; `ChatMessage` only reaches plugins with chatAccess | game/chat.html, core/events.html#chatmessage |
| `ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)` is a 3836x2121 layer at global 0,0 | PrettyUI probe in the beta client, 2026-10-25; the ID from `docs/api/consts/Component.lua` |
| Components: `SetPos(x, y, relX?, relY?)` / `SetSize(w, h, relW?, relH?)` add a fraction of the parent's size, kept live, so a child anchored to its parent's right edge follows it as it moves and resizes; `MoveToFront`; `Destroy` takes the children with it | ui/component.html; probe 2026-10-25: a MENU button at `x = -28, xAnchor = 1.0` on a window at 600,300, 300 wide, sat at global 872,307 |
| A manifest dependency on mod.io ID 6398181 (object form) resolves, for a dev_plugins plugin, to PrettyUI 1.2.0 as the global named by the key | probe 2026-10-25 |
| Window: defaults (80,80, 480x340, min 220x140); `closeButton` at (width-28, 7), 20x20, and clicking it is `Close()`; `Close` calls `onClose(window)`, then hides the root; `Show` unhides it; `SetSize` clamps to min/max | PrettyUI 1.2.0 source (`src/window.lua`); the X's position matches the probe |
| A titled Window drags by its title bar, clamped inside its parent; a child of `window.root` moves with it in the same step; root x/y/width/height read back after a drag or resize | probe 2026-10-25 (clamped at 1004,1013 and other spots; root read back) |
| The title-bar drag layer covers the title bar except the X's slot (width-34..width), so a button of the window elsewhere on the title bar gets no clicks | probe 2026-10-25; 1.2.0 source (`titleDrag`, width - CLOSE_SIZE - 14) |
| A bare `root:SetPos` on a Window or Panel root is reverted to the remembered position at the next harness step, unless the owner's `SetSize` follows. `Panel:SetSize`, `Window:SetSize`, a title drag, a resize and an Alt-drag all remember the current position. The fake does this for a Panel and for a titled or resizable Window (the ones 1.2.0 gives drag bounds), before `Logic` | probe 2026-10-25: a Panel `root:SetPos(1593,571)` stayed at 0,0, and SetPos then SetSize stuck. PrettyUI's DragBounds does the reverting; **the client's exact trigger is unknown** (1.2.0 refreshes it from the Panel's Logic poll and on the parent's ONRESIZE), so the snap may come later or, for a Window, not at all |
| `Panel:SetSize` clamps to at least 9x9 and keeps the panel inside its parent | 1.2.0 source (`src/panel.lua`, DragBounds:Clamp) |
| A Panel's first child sits at +18,+16 inside it; content rows flow down from (14, 12) inside the frame (4 px for a Panel; 8 px, and 32 under a title, for a Window) | probe 2026-10-25 for the Panel; the Window's offsets from 1.2.0 (`src/core/layout.lua`) |
| Alt-drag moves a standalone Panel, clamped inside its parent, only while Alt is held, and while it is held the panel's drag layer takes clicks on it | probe 2026-10-25 (alt read true only with the console closed); 1.2.0 source for the click |
| SpriteButton: unknown sprite names raise `Unknown SpriteButton sprite: <name>` (a plain error a plugin can catch); names are case-insensitive; `action(button, enabled)`, with enabled true for a non-toggle button; default size 24 | 1.2.0 source (`src/sprite_button.lua`, `src/core/sprites.lua`) |
| CheckboxButton: `GetSelectedValues` in choice order, `IsSelected`, `SetSelected(value, selected, notify?)` false for an unknown value; `onChange(group, values, value, selected)` only on a change; rows 22 px; a disabled choice ignores clicks | 1.2.0 source (`src/selection_button.lua`), https://prettyui.j3.gg |
| CheckboxButton options `colour` (the choices' text colour, fixed once made) and `y` (placed at that content y, outside the flow: later rows don't move), and a per-choice `tooltip` | 1.2.0 source (`src/selection_button.lua`; `y` makes the placement absolute in `src/core/layout.lua`) |
| `Window:AddSpriteButton(sprite, action, options)`: the next content row, 24 px by default, or at `options.y` outside the flow | 1.2.0 source (`src/core/content_methods.lua`, the `AddSpriteButton` entry, installed on Window) |
| `Window:SetScrollPosition(position)` floors the position and clamps it to 0..(content height - viewport height), where the content height is the lowest row's bottom plus 14 px (flow rows and `y`-placed ones alike) and the viewport is the window less its title bar (32, or 8 untitled) and 8 px bottom border; `SetSize` and a resize re-clamp it. A Window's `_scroll.scrollY` reads the position (internal: 1.2.0 has no getter), and `_scroll` is nil after `Destroy()` | 1.2.0 source (`src/core/scroll.lua` `SetScrollPosition`, `_Layout` and `Scroll.install`; `src/core/layout.lua` `growContent`; `src/window.lua` `Destroy`) |
| Panel option `scrollable` (false: no scrolling, no scrollbar) is accepted; the fake doesn't scroll either way | 1.2.0 source (`src/core/scroll.lua`, `src/panel.lua`) |
| AchievementPopup (`show(options)` / `new(parent, options)`): defaults 300x92, title "ACHIEVEMENT COMPLETE", centred (`xAnchor` 0.5, `x` -width/2) at `y` 20; `show` takes `options.parent` and returns nil without one (the real one then uses the game area, which the harness lacks, so the fake faults on a missing parent); the popup subscribes its own `Event.Logic` callback named `prettyui_achievement_popup_<n>` and, on the 201st Logic tick (15 in, 160 held, 25 out; 200 ticks is 4 s at 50/s), destroys itself (unsubscribing) and then calls `onComplete(popup)`; `Destroy()` unsubscribes and never calls `onComplete`. The fake records each popup (`h.ui:popups()`: title, text, size, the sound options, `played`, `root`, `destroyed`, `completed`) and accepts exactly the options 1.2.0 reads (an unknown key faults), but models only the parent, title, text, size, position, sound and `onComplete`: the colour, `shadowed`, `item` and quantity options are accepted and ignored | 1.2.0 source (`src/achievement_popup.lua`); the sound ids `ARCH_INFO_POPUP` and `LEAGUE2_HARD_TASK_COMPLETE` exist in the live client (dev-bridge, 2026-10-29) |
| `id.Sound.<NAME>` resolves to the id in `docs/api/consts/Sound.lua` (`ARCH_INFO_POPUP` 48145, `LEAGUE2_HARD_TASK_COMPLETE` 60041); an unknown name faults | the consts file; the two ids confirmed in the live client, dev-bridge 2026-10-29 |
| Tooltips: shown on the target's mouse-over, hidden only on its mouse-leave. A Window's or Panel's content tooltips (choices included) are drawn on the host's parent: `Close` hides them, `Destroy` destroys them. A `SpriteButton.new` button's tooltip is drawn inside the parent it was given. `SetTooltip` / `SetOptionTooltip` with a string retext an existing tooltip (a shown one stays shown); a table or nil destroys it and attaches a new, hidden one | 1.2.0 source (`src/tooltip.lua`, `src/window.lua`, `src/selection_button.lua`); https://prettyui.j3.gg lists both methods |

### Harness choices: unknown client behaviour, or stricter than the client on purpose

| Behaviour | Harness does |
|---|---|
| A subscriber error | Fails the test, naming the event and subscriber (the client logs it to the console) |
| `var.<Domain>.FromID` for an ID that isn't in the catalog | nil (the catalog holds every ID `FromID` returned a var for in `plugins/var-dump`; the client may raise instead) |
| `Plugin.urls` values | Opaque proxies: `..` raises, `tostring` is a pointer-style string, and `HTTPRequest.new` takes only proxies. Live, 2026-10-26 (beta 951-1): a userdata, `..` raises `attempt to concatenate a ...LuaPluginMetadata::URL value`, `tostring` is `sol.jag::scripting::LuaPluginMetadata::URL: 0x...`, `HTTPRequest.new` accepts it. Gap: the proxy is a table, so `type()` says `table` |
| `utf8` | Absent from a plugin's environment. Live, 2026-10-26 (beta client 951-1): `type(utf8)` is `nil` (`string.pack`, `math.tointeger`, `table.move` and `string.format` are functions). The tee's `utf8.len` raised in every `teelog.encode` while 520+ specs passed on a harness that provided it; `lib/dev/teelog.lua` now checks UTF-8 by hand |
| `pairs(Plugin.urls)` | Lists the manifest's urls (name -> proxy). Live, 2026-10-26: `type(Plugin.urls)` is `table` and `pairs` iterates it. `recording.manifestUrl` (used by the recorder, tee and bridge) scans with `pairs` inside a `pcall`, then falls back to a `pcall`'d `urls[name]` |
| Granting a permission the manifest doesn't request | The builder errors |
| A `require`d file that errors | Fails the test (the client returns nil) |
| Order within a logic step | HTTP deliveries, then queued chat, then `Logic`, then `ServerLogic` |
| `ExecuteConsoleCommand` | Records the command (`h.consoleCommands`) and runs nothing: what a command does in the client (`ppe` granting a permission, `pon` enabling a plugin...) isn't modelled, so the test changes the world itself. No error unless the test raises one from `h.onConsoleCommand`. The signature is from core/index.html#executeconsolecommand |
| `load` in the sandbox | Withheld (faults) unless a test opts in (`stdlib = { load = true }`), though the client has `load` (type `function`; `loadstring`, `debug`, `os` and `io` are nil there; dev-bridge, 2026-10-26): only dev-bridge's eval should use it. Opted in, it takes string chunks in text mode only (a function chunk or another mode faults; Lua's default is `"bt"`), and a chunk given no env argument runs in the plugin's sandbox env, never the host's `_G`; an env argument, even nil, is used as in Lua 5.4. The client's `load` honours both the mode and env arguments (dev-bridge's eval, `load(chunk, "=eval", "t", scratchEnv)`, 2026-10-26) |
| `opts.absent` | Listed globals read nil, as in a client without them; the client has `load` but not `loadstring`, `debug`, `os` or `io` (dev-bridge, 2026-10-26). Naming a global the sandbox provides is an error |
| HTTP | A response arrives on the step after the test answers it, and never on the step that started the request. A 3xx counts as `successful` (unconfirmed). Progress callbacks are never called (live, none fired for a 422-byte reply; a large download is unprobed). Without httpAccess, `new`/`Get`/`Post` fault. Whether the 10 s timeout is total time or time without data is unconfirmed: the harness counts from the call |
| Player getters while logged out | Fault (`IsAvailable` is the documented guard). `GetEntity` returns the same object until the next login |
| `PlayerEntity.coordGrid` | A new CoordGrid on each read, holding the tile at that moment: live, one kept from before the player walked still read the old tile and wasn't `==` a fresh one; two of one tile are `==`, and `tostring` gives `level,mapSquareX,mapSquareZ,localX,localZ` (dev-bridge eval, 2026-10-26). The client's CoordGrid also has `<` (`__lt`, meaning unknown), which the harness lacks. Only `h.world:setPosition` sets it: reading it before then faults, replaying too, since recordings carry no position |
| `Inventory.Find` for an inventory that isn't loaded | nil |
| Reading an invalid Inv (anything but `isValid`) | Faults (the page says to check `isValid` first) |
| A count-0 slot (bought-out shop line) | Counts as used in `usedSlotCount` / `freeSlotCount` (unconfirmed) |
| `Chat.AddMessage` without chatAccess | Faults |
| `ChatMessage.timestamp` | A fixed epoch (2026-01-01) plus elapsed logic time. The client's is unix seconds (recording `20261025-144642-8f7250b863`); a replay delivers the recorded one |
| PersistentDB | `IterateEntries` goes in key order. `Delete` returns true. Typed setters return nil on a type mismatch |
| Replaying: a permission check or PersistentDB key nothing accounts for | Faults `unrecorded: ...` instead of answering the scripted default (not granted, unset). `IterateEntries` visits only the keys the store holds (seeded, stored during the replay, or put in `h.db`), since the recorder logs only its count |
| Replaying a recording with `dropped` entries | Refused unless the test passes `{ allowDropped = true }` |
| Replaying, `ServerLogic` | Only the recorded ones while the recording lasts, if it has any; the harness clock's otherwise |
| Stdlib | Provides what the client's shared table held when dev-bridge listed it (2026-10-26): the base functions, `string` (with `dump`), `table`, `math`, `coroutine`, `warn` (a no-op: Lua starts with warnings off, and where the client sends them is unknown) and `collectgarbage` (`"collect"`, `"count"`, `"step"` and `"isrunning"` only; any other option faults, since it would change busted's VM). Withholds `os` and `io` (opt-in; both absent in the client), `load` (opt-in, see its row), and `debug`, `loadfile`, `dofile`, `package` and `utf8`, all absent in the client |
| `random(min, max)` | A seeded generator per harness (`opts.randomSeed`, default 1), uniform in `[min, max)`; whether the client's can return `max` is unknown |
| `formatStr` | The subset a live probe covered (dev-bridge eval, 2026-10-26; the cases are in `tests/harness/helpers_spec.lua`): `{}`, `{N}`, `{{`/`}}`, and specs of fill, `<>^`, `0`, width, `.N` and `f`. Numbers go through a double (`1` prints `1`, 2^53+1 prints `9007199254740992`); a spec fmtlib refuses (`d`/`x` on a number, `q`) or too few arguments returns nil. A number that would print in exponent form, any other spec, a spec on a boolean and an API object fault as unmocked |
| `utils.CalcTextWidth` | The test's `opts.textWidth`; it faults without one. Undocumented (only `docs/api/types.lua` declares it) |
| `print` / `log` | Join `tostring` of each argument with spaces. The client prints table contents, and `log` adds a plugin prefix (core/index.html#log) |
| The time budget | Wall time (luasystem's monotonic clock), checked every 10,000 VM instructions and when the call returns. Coroutines the plugin creates are checked too, against the call that resumes them |
| `ui.Interfaces:GetComponent` | Only the plugin layer; any other ID, or the 2- and 4-argument forms, faults. The same root object comes back on every call of one load (live, a fresh userdata each call, `==` the last: dev-bridge eval, 2026-10-26). Moving, resizing or destroying it faults |
| Component positions | Rounded to whole pixels. `SetPos`'s self-percentage arguments fault |
| A destroyed component, or a PrettyUI object after `Destroy()` | Any member faults (the client's behaviour is undocumented; 1.2.0 ignores some calls on a destroyed object). A destroyed Window's or Panel's `root` reads nil, as in 1.2.0 |
| Dependency fakes | Always present and enabled, so an optional one is never nil and `PluginDependencyUpdate` never fires |
| How a manifest names PrettyUI | Only the probed form resolves: the object form with the numeric mod.io ID (`{ "<global>": 6398181 }`). The array form (`["prettyui"]`, `["6398181"]`) and string values (`{ "prettyui": "6398181" }`, `{ "prettyui": "prettyui" }`) fail the load, saying the form is unconfirmed. Stricter on purpose: plugin-anatomy.md has those name a folder, and the installed folder is `6398181`, so the client may give no global. Relax it once an in-client probe confirms another form |
| `h.ui:click` on a destroyed component or PrettyUI object | Faults (`used after Destroy()`) rather than reporting it unclickable, so a plugin that leaves a destroyed button's handle reachable is caught |
| `h.ui:holdAlt` across `h:reload()` | Unloading releases Alt |
| An AchievementPopup's sound and look | No sound is played (`audio` isn't modelled; the real popup passes the id to `audio.Play` inside a `pcall`), and none of its sprites, fade or flash are drawn: the fake keeps the root layer, the title and the text. `h.ui:popupsFail(true)` makes `show` return nil, standing in for a client with no parent to put it in |
| PrettyUI text | Doesn't wrap: the fake can't measure fonts, so a body row is 24 px, or 18 px per `<br>`-separated line plus 6 |
| PrettyUI clicks | `h.ui:click` hits a component's centre. Only a target's own window's title-bar drag layer can cover it; other windows' z-order isn't modelled |
| A Window's title-bar drag layer position | Tracks the root's live position. In 1.2.0 it is a sibling of the root (`src/window.lua`, `titleDrag`), moved only at the end of a title drag, by the DragBounds callback and by `SetSize`, so between a bare `root:SetPos` and its snap-back the real layer can sit over the old spot and block clicks there instead (not modelled) |
| PrettyUI scrolling and hover states | Not modelled beyond a Window's scroll position: scrolled content doesn't move (clicks and positions read as unscrolled), the mouse wheel and scrollbar don't scroll, and hover sprites don't change. Hover is only what `h.ui:hover` says |
| A hovered target hidden or destroyed | Gets no mouse-leave, so its tooltip stays shown until replaced, its window closes or is destroyed. Assumed from the stuck tooltips the user saw (2026-10-25); whether the client sends a leave to a hidden component is unconfirmed. Showing a component under a still pointer fires no mouse-over |

### Not modelled

- **APIs** (they fault as unmocked): `ui.*` beyond the plugin root layer (the components a
  plugin would make itself, hooks, style sheets...), PrettyUI beyond the subset in
  [Testing a PrettyUI plugin](#testing-a-prettyui-plugin), `World`, entity lists
  (`NPCList`, `PlayerList`, `LocList`, `ObjStackList`), `Camera`, `audio`, `Keyboard`, `Mouse`,
  `MiniMenu`, `GrandExchange`, `ClientOptions`, `ScreenConvert`, `Shapes`, the `CoordGrid`
  global (its constructors and methods; a PlayerEntity's `coordGrid` is modelled), math
  types (bar `xyGlobal`'s `x`/`y`), `id.*` beyond
  `id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP` and the names in `id.Sound`, `config.*` beyond `Inv` and `Obj`,
  `slerp` and the Vector/Matrix forms of `lerp`,
  `Plugin.resources`, `Player.GetTrackingID` / `GetRunEnergy` / `GetWeight` / `GetCombatLevel`,
  `PlayerEntity` beyond `displayName` and `coordGrid`, `InvType.stockCount`.
- **Vars**: BOOLEAN vars reading `true` (unconfirmed,
  [api-concepts.md](api-concepts.md#runtime-limits-weve-hit)). Which name the client gives an
  update, base or VarBit: the builder names the var the test set. A replayed VarBit value
  (event or read) whose base the world doesn't know yet starts the base at 0, so the base's
  other VarBits read 0 rather than unrecorded until the recording gives them. The error logged for
  unsupported ValueTypes. Config-typed values (OBJ, NPC, COORDGRID...): `setVar` refuses them.
- **VarTransmit values of BOOLEAN and config-typed vars.** The client's `oldValue`/`newValue`
  are plain integers for these (BOOLEAN 0/1, COORDGRID, INV, OBJ, ACHIEVEMENT, COMPONENT...;
  recording `20261025-144642-8f7250b863`). The builder's `setVar` takes a boolean for a
  BOOLEAN var and refuses config types, so a scripted VarTransmit can't show this; a replayed
  one carries the recorded integers.
- **Events the builder doesn't fire**: `SkillTransmit`, `RunEnergyTransmit`, `GameStateChanged`
  on login/logout, entity and loc events, keys, `Draw`. Use `h:fire`. Logging out doesn't clear
  inventories or vars.
- **Dependencies**: `PluginDependencyUpdate`, `OptionalDependencyChanged`, and the globals of any
  dependency but PrettyUI. The UI hooks aren't recorded by the dev recorder either.
- **HTTP request bodies being garbage-collected** before the request finishes (a suspicion in
  api-concepts.md), and coroutines crashing the client.
- **An HTTP request started from a coroutine resumed after a completion callback.** Only a
  request started while the callback itself runs fails the test. A coroutine created in the
  callback and resumed later from `Logic` starts its request unflagged: whether the client
  treats that as inside the callback is undocumented.
- **String methods on string values**: `("").rep` and `getmetatable("").__index` resolve
  through the host's `string` table, not the sandbox copy (busted shares that metatable, so the
  harness leaves it alone).

### Where the official page and the stubs disagree

| Stub | Official page | Harness |
|---|---|---|
| `Inventory.Find` returns `Inv[]` | returns `Inv` (game/inventory.html#findinvtype) | an `Inv` |
| `Inv.valid` | `isValid` (game/inventory.html#properties) | `isValid`; `valid` faults as unmocked |
| `PersistentDBType` values are strings | 0–4 | 0–4 |

Plugin code that follows the page here trips LuaLS. Suppress that one line with
`---@diagnostic disable-next-line` and cite the page (see `CLAUDE.md`).
