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
| `tests/harness/api/*.lua` | The mocks, one module per API area |
| `tests/harness/sandbox.lua`, `runtime.lua`, `strict.lua` | The plugin's environment, client limits, strict proxies |
| `tests/harness/stubs.lua`, `catalog.lua` | Reads `docs/api/` and `docs/vars/vars.csv` |
| `tests/harness/timeline.lua`, `replay.lua` | Replaying a recording: grouping its entries by tick (pure), and driving the world from them |
| `tests/harness/*_spec.lua` | The harness's own tests |
| `tests/<plugin>/*_spec.lua` | A plugin's tests |
| `lib/dev/`, `scripts/dev-receiver.py` | The dev recorder and its receiver ([Recordings](#recordings)) |
| `scripts/recording-sanitise.py`, `tests/fixtures/` | Recorded sessions made into committed fixtures ([Turning a session into a fixture](#turning-a-session-into-a-fixture)) |
| `tests/recorder/` | The recorder's tests, with `plugins/recorder-demo` |

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
| `harness.enums` | `ChatType`, `PersistentDBType`, `PluginPermissions`, `SkillType`, `ValueType` |
| `harness.errorOf(fn, ...)` | The error message `fn` raises; fails if it doesn't raise |

`opts`: `grant = { "httpAccess", ... }` (permissions granted from the start, without an event),
`budgetMs = 1000` (the per-call time budget), `stdlib = { os = true, io = true }` (opt in to
withheld libraries), `echo = true` (also print the plugin's console output).

### The harness `h`

| Member | Does |
|---|---|
| `h:load()` / `h:unload()` / `h:reload()` | Enable (fresh env, run `main.lua`), disable (call a global `PluginShutdown`, drop subscriptions and pending HTTP callbacks), or both |
| `h:advance(ms)` | Run the clock forward in 20 ms logic steps; a remainder carries over. Each step: deliver answered HTTP requests, deliver queued `Chat.AddMessage` messages, fire `Logic`, and every 30th step `ServerLogic` |
| `h:fire(event, fields?)` | Fire any stub event; `fields` must be fields of the stub's `<Event>EventPayload`. For events the world builder doesn't model (`KeyDown`, `SkillTransmit`...) |
| `h:respond(record, response)` | Answer an HTTP request: `{ status = 200, body = "", header = "" }`, `{ timedOut = true }` or `{ error = "info", errorCode = n }`. Delivered on the next step |
| `h:useRecording(source, opts?)` | Drive the world from a recording (a `.jsonl` path, repo-relative or absolute, or a list of entries); call before `h:load()`. A recording with `dropped` entries is refused unless `opts.allowDropped`. See [Replaying a recording](#replaying-a-recording) |
| `h:playRecording()` | Step the clock to the recording's last tick |
| `h:output()` | Everything the plugin printed or logged, one line per call |
| `h.env` | The current sandbox environment |
| `h.console` | `{ kind = "print"|"log", text }` per call |
| `h.chatLog` | `{ message, chatType, sender }` per chat-window message, after subscribers' edits |
| `h.requests` | Started HTTP requests in order: `{ method, url, body, headers, request }` |
| `h.db` | PersistentDB entries, `key -> { type, value }`; survives reload |
| `h.tick` | Logic ticks so far (`ev.logicTick`) |
| `h.replay` | While replaying: `timeline`, `reads` (path -> `{ v }`, the reads seen so far), `skipped` (`{ t, event, why }` per recorded delivery the harness couldn't make) and `dropped` (`{ t, n }` per gap in the recording) |

### The world `h.world`

| Call | Fires |
|---|---|
| `setVar(domain, nameOrId, value)` | `VarTransmit`, on every call |
| `login(displayName)` / `logout()` | nothing |
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
  (`x = x or {}`). Use a local, or `rawget(_G, "x")`.
- **With the dev recorder installed**, it reads every field of each recorded event's payload, so
  `h:fire` must pass them all and a var needs a value before `h:load()` (its first VarTransmit
  would otherwise have no `oldValue`). See [Recordings](#recordings).

`tests/harness/api_names_spec.lua` checks every mocked global and member against the stubs, with
its call form, and fails on any the stubs lack. It doesn't take the harness's word for it. The one
exception is listed with the official page that proves the stub wrong.

## Lint and type-check config for tests/

`scripts/check-lua.sh` lints `tests/` with its own config, because spec and harness code run in
plain Lua and busted, not in the plugin sandbox:

- `tests/selene.toml` + `tests/tests.yml`: the root std plus the luassert assertions specs call.
  Add an `assert.*` member to `tests.yml` when a spec needs a new one.
- `tests/.luarc.json`: LuaLS against LuaLS's bundled busted and luassert definitions, *without*
  the API stubs. An API global used in a spec is a bug, since it is nil there. The root
  `.luarc.json` ignores `tests/`.

## Recordings

The harness models the client from docs and guesses. The dev recorder (`lib/dev/`) checks those
guesses against the real thing. A plugin opts in; the recorder then notes what the plugin did with
the API in the beta client, and streams it to `scripts/dev-receiver.py` on this machine. A
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

### Recording a session

1. From the repo root, run `scripts/dev-receiver.py` (`--port`, `--out`; it listens on
   127.0.0.1:8766 and writes to `dumps/recordings/`, which is gitignored).
2. In the client: `prf`, `pon <name>`, `ppr <name>`, then `ppe <name> httpAccess`. Always
   `ppr` before `ppe`: `ppe` on a permission the plugin hasn't requested does nothing, and
   says nothing either.
3. Each enable is one session, written to `dumps/recordings/<name>/<time>-<session>.jsonl`. The
   receiver prints one line per batch.

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
| `perm` | `permission`, `v` |
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
inside itself becomes `"<cycle>"`, a string over the cap ends `<+N bytes>`, and values past the
cap become `"<truncated>"`. A table keyed 1..n is a JSON array and any other a JSON object with
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
  (so it was seen unset) or the plugin deleted it or called `Clear` during the replay. A key
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
  value its type can't hold in the harness (config-typed vars, and BOOLEAN vars, which
  VarTransmit reports as 0/1). The event still fires with the recorded values, except for a
  var the catalog lacks: then the delivery is skipped and listed in `h.replay.skipped`.
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
     any other text. It matches case-insensitively, with a space, underscore, hyphen or
     no-break space in the name matching any of them. It refuses a recording without that read,
     and checks its output for the name before writing.
   - redacts every chat message with a non-empty sender (one a player sent): its text and
     sender fields become `<redacted>`.
   - strips memory addresses from object text, as the recorder now does, and drops the reads
     that then repeat.
   - keeps only the entries with `--from <= t <= --to`, rebased so `--from` is `t = 0`. What
     the plugin knew before the window comes in at `t = 0`: the latest read of each path, the
     latest check of each permission, and one `Get` per PersistentDB key of the value it held
     (a key stored before the window seeds the replay's store). Events before the window are
     dropped, so the world starts empty and the replay serves what the plugin had read; an
     inventory, say, is a [read-backed Inv](#replaying-a-recording) until its first update in
     the window. The header gains `"window": [from, to]`.
3. Check the result before committing: count the display name's matches in it (0 means
   none), e.g. ``grep -ci "$(jq -r 'select(.path == "Player.GetEntity().displayName") | .v' <session>.jsonl | head -1)" <fixture>``,
   and read what chat is left (`jq -c 'select(.name == "ChatMessage") | .payload.chatMessage'`).
   The script only knows the player's own name and chat senders: a game message that names
   another player, or a plugin that copies chat text into a read or the store, needs a look by
   hand.
4. Keep it small: a window of a minute or so is tens of KB. A bank update is about 40 KB on
   its own (1920 slots), so leave bank changes out of the window unless the test needs one.
5. Replay it in a spec with `h:useRecording("tests/fixtures/<name>.jsonl")`.

## Fidelity ledger

### Modelled, with its source

| Behaviour | Source |
|---|---|
| `require`: path from the plugin root, no extension; runs once per load and caches the result; nil for a missing file; circular requires are an error | [plugin-anatomy.md](plugin-anatomy.md#modules-require) |
| A `require`d module runs in `main.lua`'s environment (same globals, same `Event`); a directory symlink inside the plugin folder is followed | recorder-demo's probe line in the beta client, 2026-10-25 |
| A global `PluginShutdown` runs on disable/reload (a `local` one doesn't); reload = fresh env, PersistentDB kept | [plugin-anatomy.md](plugin-anatomy.md#lifecycle-hooks-global-functions), [dev-environment.md](dev-environment.md#plugin-management-commands) |
| A manifest with `requiredPermissions` doesn't run, so the harness refuses it | [plugin-anatomy.md](plugin-anatomy.md#manifest-pluginjson) |
| Subscribers run in subscription order; reusing a name replaces it for that event only; a payload edited by one subscriber is what the next sees (fields the stub doesn't mark "(Read-only)", such as `ChatMessage.chatMessage`, are writable) | [core/events.html#overview](https://developer.runescape.com/rs/core/events.html#overview), #event-payloads |
| `Logic` at a fixed 50 Hz with `logicTick`; `ServerLogic` about every 600 ms with no payload | core/events.html#logic, #serverlogic; recording `20261025-144642-8f7250b863`: about 3000 Logic ticks per `CLOCK_TIME_DATE_MINUTES` minute, and `ServerLogic` 30 ticks apart two times in three (16 to 82 seen). The harness's is exactly every 30 |
| `VarTransmit` fires on every update, changed or not, after the value is set, with `var`, `oldValue`, `newValue` | core/events.html#vartransmit |
| `var.<Domain>.NAME` and `FromID(id)` give one VarType per var (`ev.var == var.VarPlayer.X`); VarBits report `isVarBit`, `baseVar`, `varBitMask`; `baseVar`/`varBitMask` are nil otherwise; properties are read-only | game/config/vartype.html, `docs/vars/vars.csv` |
| `Player.IsAvailable` says whether player data can be read | game/player.html#isavailable |
| `Inventory.Find` returns an `Inv`; slots are 1-indexed; `GetSlot`/`GetSlots` return copies; an Inv goes invalid (`isValid`) when its inventory is removed, and re-adding it makes a new Inv | game/inventory.html |
| `Inv:GetSlots()` is dense, one slot per index up to `slotCount`, with each empty slot as obj -1 (configName `UNKNOWN`) and count 0. A real obj with count 0 is not empty: a bought-out shop line stays in its shop inventory that way (GENERALSHOP1 slot 7, obj 590 x0) | recording `20261025-144642-8f7250b863` (recorder-demo in the beta client, 2026-10-25) |
| `InventoryAdded`/`Updated` (`slotsUpdated`)/`Removed` carry the `InvType` | core/events.html#inventoryadded and below |
| PersistentDB: Get nil when unset; typed getters nil on a type mismatch; Set returns a Bool; unsupported table fields are dropped; `IterateEntries` stops on `true` and returns the count; persists across reload | core/persistentdb.html |
| `PersistentDBType` values 0–4 (the stub has strings) | core/persistentdb.html#persistentdbtype |
| `Plugin.HasPermission`, `Plugin.urls.<name>` from the manifest | core/plugin.html |
| `OptionalPermissionChanged` (`permissionName`, `enabled`) fires for optional permissions | core/events.html#optionalpermissionchanged |
| HTTP needs httpAccess, and a base URL from the manifest's `urls`; `Get`/`Post`/`AddHeader` on an active request raise; the completion callback receives the request | core/http.html |
| Starting an HTTP request inside a completion callback fails the test (it crashed the client) | [api-concepts.md](api-concepts.md#runtime-limits-weve-hit) |
| A call running past 1000 ms is aborted with `Maximum function execution time of 1000 ms exceeded` | [api-concepts.md](api-concepts.md#runtime-limits-weve-hit) |
| `Chat` needs chatAccess; `AddMessage` is queued until the next logic update and comes back as `ChatMessage` with `ChatType.PLUGIN`; `ChatMessage` only reaches plugins with chatAccess | game/chat.html, core/events.html#chatmessage |

### Harness choices: unknown client behaviour, or stricter than the client on purpose

| Behaviour | Harness does |
|---|---|
| A subscriber error | Fails the test, naming the event and subscriber (the client logs it to the console) |
| `var.<Domain>.FromID` for an ID that isn't in the catalog | nil (the catalog holds every ID `FromID` returned a var for in `plugins/var-dump`; the client may raise instead) |
| `Plugin.urls.<name>` missing from the manifest | Faults. Unlike other faults, a `pcall` around the lookup catches it for good, so a plugin can probe for an optional url |
| `pairs(Plugin.urls)` | Lists the manifest's urls. The page calls `urls` a table; whether the client's can be iterated is unconfirmed. The dev recorder looks for `urls.recorder` this way first, then by a `pcall`'d lookup |
| Granting a permission the manifest doesn't request | The builder errors |
| A `require`d file that errors | Fails the test (the client returns nil) |
| Replacing a subscription by name | Keeps its original position in the order |
| Unsubscribing during a dispatch | The removed subscriber isn't called later in that dispatch |
| Order within a logic step | HTTP deliveries, then queued chat, then `Logic`, then `ServerLogic` |
| HTTP | A response arrives on the step after the test answers it, and never on the step that started the request. `successful` is true for any status code. Progress callbacks are never called. `Cancel` means no callback. Without httpAccess, `new`/`Get`/`Post` fault. Timeouts happen only when the test responds with one |
| Player getters while logged out | Fault (`IsAvailable` is the documented guard). `GetEntity` returns the same object until the next login |
| A fresh object per call | `Player.GetEntity()` and `Inventory.Find()` give a new userdata on every call in the client (recording `20261025-144642-8f7250b863`); the harness hands out one object per login / per inventory. Whether the client's compare equal with `==` is unconfirmed |
| `Inventory.Find` for an inventory that isn't loaded | nil |
| Reading an invalid Inv (anything but `isValid`) | Faults (the page says to check `isValid` first) |
| `Inv:GetSlot` on an empty slot | nil. Unconfirmed: the client may give an obj -1 slot, as `GetSlots` does |
| A count-0 slot (bought-out shop line) | Counts as used in `usedSlotCount` / `freeSlotCount` (unconfirmed) |
| `Chat.AddMessage` without chatAccess | Faults |
| `ChatMessage.timestamp` | A fixed epoch (2026-01-01) plus elapsed logic time. The client's is unix seconds (recording `20261025-144642-8f7250b863`); a replay delivers the recorded one |
| PersistentDB | `IterateEntries` goes in key order. `Delete` returns true. Typed setters return nil on a type mismatch |
| Replaying: a permission check or PersistentDB key nothing accounts for | Faults `unrecorded: ...` instead of answering the scripted default (not granted, unset). `IterateEntries` visits only the keys the store holds (seeded, stored during the replay, or put in `h.db`), since the recorder logs only its count |
| Replaying a recording with `dropped` entries | Refused unless the test passes `{ allowDropped = true }` |
| Replaying, `ServerLogic` | Only the recorded ones while the recording lasts, if it has any; the harness clock's otherwise |
| Stdlib | Provides the base functions, `string` (without `dump`), `table`, `math`, `utf8`, `coroutine` (an earlier var-dump ran one in the client). Withholds `os` and `io` (opt-in; both are absent in the client, per recorder-demo's probe line, 2026-10-25), and `debug`, `load*`, `dofile`, `package`, `collectgarbage` |
| `print` / `log` | Join `tostring` of each argument with spaces. The client prints table contents, and `log` adds a plugin prefix (core/index.html#log) |
| The time budget | Wall time (luasystem's monotonic clock), checked every 10,000 VM instructions and when the call returns. Coroutines the plugin creates are checked too, against the call that resumes them |

### Not modelled

- **APIs** (they fault as unmocked): `ui.*` and PrettyUI, `World`, entity lists
  (`NPCList`, `PlayerList`, `LocList`, `ObjStackList`), `Camera`, `audio`, `Keyboard`, `Mouse`,
  `MiniMenu`, `GrandExchange`, `ClientOptions`, `ScreenConvert`, `Shapes`, `CoordGrid`, math
  types, `formatStr`, `ExecuteConsoleCommand`, `id.*`, `config.*` beyond `Inv` and `Obj`,
  `Plugin.resources`, `Player.GetTrackingID` / `GetRunEnergy` / `GetWeight` / `GetCombatLevel`,
  `PlayerEntity` beyond `displayName`, `InvType.stockCount`.
- **Vars**: VarBit packing (setting a base var doesn't change its VarBits, nor the reverse).
  VarTransmit naming one VarBit per base-var update, and BOOLEAN vars reading `true` (both
  unconfirmed, [api-concepts.md](api-concepts.md#runtime-limits-weve-hit)). The error logged for
  unsupported ValueTypes. Config-typed values (OBJ, NPC, COORDGRID...): `setVar` refuses them.
- **VarTransmit values of BOOLEAN and config-typed vars.** The client's `oldValue`/`newValue`
  are plain integers for these (BOOLEAN 0/1, COORDGRID, INV, OBJ, ACHIEVEMENT, COMPONENT...;
  recording `20261025-144642-8f7250b863`). The builder's `setVar` takes a boolean for a
  BOOLEAN var and refuses config types, so a scripted VarTransmit can't show this; a replayed
  one carries the recorded integers.
- **Events the builder doesn't fire**: `SkillTransmit`, `RunEnergyTransmit`, `GameStateChanged`
  on login/logout, entity and loc events, keys, `Draw`. Use `h:fire`. Logging out doesn't clear
  inventories or vars.
- **Dependencies**: `PluginDependencyUpdate`, `OptionalDependencyChanged`, dependency globals.
- **HTTP request bodies being garbage-collected** before the request finishes (a suspicion in
  api-concepts.md), and coroutines crashing the client.
- **An HTTP request started from a coroutine resumed after a completion callback.** Only a
  request started while the callback itself runs fails the test. A coroutine created in the
  callback and resumed later from `Logic` starts its request unflagged: whether the client
  treats that as inside the callback is undocumented.
- **String methods on string values**: `("").rep` and `getmetatable("").__index` resolve
  through the host's `string` table, not the sandbox copy (busted shares that metatable, so the
  harness leaves it alone). The known difference is `dump`, which is reachable that way.

### Where the official page and the stubs disagree

| Stub | Official page | Harness |
|---|---|---|
| `Inventory.Find` returns `Inv[]` | returns `Inv` (game/inventory.html#findinvtype) | an `Inv` |
| `Inv.valid` | `isValid` (game/inventory.html#properties) | `isValid`; `valid` faults as unmocked |
| `PersistentDBType` values are strings | 0–4 | 0–4 |

Plugin code that follows the page here trips LuaLS. Suppress that one line with
`---@diagnostic disable-next-line` and cite the page (see `CLAUDE.md`).
