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
| `tests/harness/*_spec.lua` | The harness's own tests |
| `tests/<plugin>/*_spec.lua` | A plugin's tests |
| `lib/dev/`, `scripts/dev-receiver.py` | The dev recorder and its receiver ([Recordings](#recordings)) |
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
| `h:output()` | Everything the plugin printed or logged, one line per call |
| `h.env` | The current sandbox environment |
| `h.console` | `{ kind = "print"|"log", text }` per call |
| `h.chatLog` | `{ message, chatType, sender }` per chat-window message, after subscribers' edits |
| `h.requests` | Started HTTP requests in order: `{ method, url, body, headers, request }` |
| `h.db` | PersistentDB entries, `key -> { type, value }`; survives reload |
| `h.tick` | Logic ticks so far (`ev.logicTick`) |

### The world `h.world`

| Call | Fires |
|---|---|
| `setVar(domain, nameOrId, value)` | `VarTransmit`, on every call |
| `login(displayName)` / `logout()` | nothing |
| `setSkill(skill, { level, xp, gameplay?, capped?, xpCapped? })` | nothing. The optional fields default to `level` / `xp` |
| `defineObj(nameOrId, fields)` | nothing. Gives an `ObjType` the stub fields a test needs (`name`, `category`...) |
| `setInventory(inv, { [slot] = { obj, count? } }, size?)` | `InventoryAdded` the first time, then `InventoryUpdated` with the changed slots (no event if nothing changed) |
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
   client's `dev_plugins` link itself, so the helper modules come with it. If the client refuses
   it, copy instead (`rm plugins/<name>/dev && cp -r lib/dev plugins/<name>/dev`), don't commit
   the copy, and re-copy after changing `lib/dev/`.
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

**Modules.** `install()` swaps the globals of the environment passed to it. In the harness every
module shares `main.lua`'s environment. Whether the client's modules do is undocumented:
recorder-demo's probe line reports it as `moduleSharesEnv`. If that is `false`, only
`main.lua`'s own API use gets recorded.

**Moderation.** The recorder and recorder-demo are dev tools, never for submission. A plugin
for submission ships without `dev/`, without the two lines above, and without `urls.recorder`.
It keeps httpAccess only if a feature of its own needs it. Recordings hold the plugin's request
headers (an `Authorization` header included) and bodies, chat lines and display names, so keep
them local.

### Recording a session

1. From the repo root, run `scripts/dev-receiver.py` (`--port`, `--out`; it listens on
   127.0.0.1:8766 and writes to `dumps/recordings/`, which is gitignored).
2. In the client: `prf`, `pon <name>`, then `ppe <name> httpAccess` (run `ppr <name>` first if
   it says the plugin hasn't asked for it).
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
text. A table met again inside itself becomes `"<cycle>"`, a string over the cap ends
`<+N bytes>`, and values past the cap become `"<truncated>"`. A table keyed 1..n is a JSON array
and any other a JSON object with string keys, so an inventory with empty slots comes back as
`{"1": ..., "5": ...}`.

**World ops** in `event.op` use the shapes `world.apply` takes:

| Event | `op` |
|---|---|
| `VarTransmit` | `{"op": "setVar", "domain", "name", "id", "value"}` (`value` is the new value) |
| `InventoryAdded`, `InventoryUpdated` | `{"op": "setInventory", "inv": id, "size", "slots": {slot: {"obj": id, "count"}}}`. The whole inventory, which the recorder reads itself when the event arrives, since the payload only lists changed slots |
| `InventoryRemoved` | `{"op": "removeInventory", "inv": id}` |
| `OptionalPermissionChanged` | `{"op": "setPermission", "permission", "enabled"}` |
| `ChatMessage` | `{"op": "chat", "message", "chatType", "sender"}` (`sender` is `senderNameUnfiltered`) |

### Replaying (notes for the harness)

- Apply each event's `op` at its `t`, then deliver the event. Serve a read from the latest
  `read` with its path at or before the current `t`: deduplication drops only repeats, so that
  is exact.
- Login isn't an event. Infer it from `Player.IsAvailable()` and `Player.GetEntity().displayName`
  reads. Seed `h.db` from each key's first `db` `Get`. Take the starting permissions from the
  first `perm` entries.
- A `chat` op whose `chatType` is `ChatType.PLUGIN` is the plugin's own `Chat.AddMessage`
  coming back. The harness produces those itself, so don't replay them as server chat.
- A `setVar` whose `value` is a config (`{"config": ...}`) can't be applied: the harness doesn't
  model config-typed vars.
- After a `dropped` line, reads and the world may not match the plugin's view.

## Fidelity ledger

### Modelled, with its source

| Behaviour | Source |
|---|---|
| `require`: path from the plugin root, no extension; runs once per load and caches the result; nil for a missing file; circular requires are an error | [plugin-anatomy.md](plugin-anatomy.md#modules-require) |
| A global `PluginShutdown` runs on disable/reload (a `local` one doesn't); reload = fresh env, PersistentDB kept | [plugin-anatomy.md](plugin-anatomy.md#lifecycle-hooks-global-functions), [dev-environment.md](dev-environment.md#plugin-management-commands) |
| A manifest with `requiredPermissions` doesn't run, so the harness refuses it | [plugin-anatomy.md](plugin-anatomy.md#manifest-pluginjson) |
| Subscribers run in subscription order; reusing a name replaces it for that event only; a payload edited by one subscriber is what the next sees (fields the stub doesn't mark "(Read-only)", such as `ChatMessage.chatMessage`, are writable) | [core/events.html#overview](https://developer.runescape.com/rs/core/events.html#overview), #event-payloads |
| `Logic` at a fixed 50 Hz with `logicTick`; `ServerLogic` about every 600 ms with no payload | core/events.html#logic, #serverlogic |
| `VarTransmit` fires on every update, changed or not, after the value is set, with `var`, `oldValue`, `newValue` | core/events.html#vartransmit |
| `var.<Domain>.NAME` and `FromID(id)` give one VarType per var (`ev.var == var.VarPlayer.X`); VarBits report `isVarBit`, `baseVar`, `varBitMask`; `baseVar`/`varBitMask` are nil otherwise; properties are read-only | game/config/vartype.html, `docs/vars/vars.csv` |
| `Player.IsAvailable` says whether player data can be read | game/player.html#isavailable |
| `Inventory.Find` returns an `Inv`; slots are 1-indexed; `GetSlot`/`GetSlots` return copies; an Inv goes invalid (`isValid`) when its inventory is removed, and re-adding it makes a new Inv | game/inventory.html |
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
| `Inventory.Find` for an inventory that isn't loaded | nil |
| Reading an invalid Inv (anything but `isValid`) | Faults (the page says to check `isValid` first) |
| Empty slots | `GetSlot` gives nil; `GetSlots` has holes there (so `ipairs` stops at the first) |
| `Chat.AddMessage` without chatAccess | Faults |
| `ChatMessage.timestamp` | A fixed epoch (2026-01-01) plus elapsed logic time |
| PersistentDB | `IterateEntries` goes in key order. `Delete` returns true. Typed setters return nil on a type mismatch |
| Stdlib | Provides the base functions, `string` (without `dump`), `table`, `math`, `utf8`, `coroutine` (an earlier var-dump ran one in the client). Withholds `os` and `io` (opt-in), and `debug`, `load*`, `dofile`, `package`, `collectgarbage` |
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
