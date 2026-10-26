# Dev Bridge (dev tool, never submitted)

**This plugin is never submitted to Jagex.** It runs, in your client, whatever console commands
and Lua snippets the daemon on your own machine (`scripts/rsdev.py`) hands it, cheat commands
included.
`ExecuteConsoleCommand` and cheats only work on the dev worlds, and no submitted plugin may run
commands sent from outside the client. Cheat commands are logged on Jagex's server
(tutorial/6cheats.html), so only queue what you would type yourself.

It lets Claude, from a terminal, drive the client and watch what happens while you play:

- `scripts/rsdev.py exec "prl chore-tracker"` queues a console command; the bridge runs it and
  reports whether `ExecuteConsoleCommand` raised (ok means it ran without a Lua error, not that
  the command did what you hoped).
- `scripts/rsdev.py eval "Player.GetEntity().displayName"` runs a Lua snippet in the client and
  prints what it returned and printed (see "Eval" below).
- `scripts/rsdev.py events --follow` prints the events the bridge forwards: `ChatMessage` (your
  own lines and system messages only), `VarTransmit`, `InventoryUpdated`,
  `MiniMenuEntrySelected` (its text fields, with a targeted player's name replaced by
  `<player>`) and `GameStateChanged`, each stamped with the Logic tick it arrived after. rsdev
  writes them to `dumps/rsdev/events/`. The stream also carries the bridge's own `Log` events
  and the `Emit` events of eval probes.
- `scripts/rsdev.py logs --follow` prints the `Log` events: every `[BRIDGE]` console line, and
  what eval probes print.
- `scripts/rsdev.py status` shows whether the bridge is connected, and what the client's Lua
  environment has (`type()` of `load`, `loadstring`, `debug`, `os`, `io`, `require`,
  `ExecuteConsoleCommand`, `coroutine`).

The daemon, the CLI and the protocol are in
[docs/dev-environment.md](../../docs/dev-environment.md#dev-bridge). `dev/` is a symlink to
`lib/dev/`, the dev recorder's modules, which the bridge reuses to serialise event payloads.

## Use

1. In a terminal at the repo root: `scripts/rsdev.py start`.
2. In the client console, on a dev world: `prf`, then `pon dev-bridge`. On enable the bridge runs
   `ppr dev-bridge`, `ppe dev-bridge httpAccess` and `ppe dev-bridge chatAccess` itself. If it
   still logs `waiting for httpAccess`, type those three yourself.
3. `scripts/rsdev.py status` should say `connected`.

What the console should show: `[BRIDGE] enabled, session <id>`, then
`[BRIDGE] connected to rsdev, session <id>`, and an `[BRIDGE] exec <id>: <command>` line per
command run. Grep regex for this plugin's lines: `\[BRIDGE\]`.

## How it behaves

- It syncs (one `POST /bridge/sync`) from the `Logic` event only, with at most one request in
  flight: 10 Logic ticks (0.2 s) after the last one finished, or 250 (5 s) after one failed.
  Each sync carries the events seen since the last one (at most 256 KB of them) and the results
  of the commands run. The reply carries new commands, which run one per Logic tick.
- With the daemon down it keeps running: it logs the first failure, retries every 5 s, and keeps
  up to 1 MB of events that have not been sent. Past that the oldest are dropped. Events taken
  into a sync that fails are dropped too, not retried; the next sync's `dropped` count tells the
  daemon how many.
- It refuses any command that would disable it or revoke one of its permissions (`poff`,
  `plugins_disable`, `plugins_setenabled` with any argument, `ppd`, `plugins_permissions_disable`
  naming `dev-bridge`): that would cut the only channel that could re-enable it. Run those from
  the client console. The guard is best-effort: it matches only the first two
  whitespace-separated words, so a quoted target, an extra leading word, an alias not listed
  above, or a bare `prl` or `poff` with no argument (whether the client treats that as "all
  plugins" is unknown) would pass: don't send one.
- `prl dev-bridge` (or `plugins_reload dev-bridge`) is allowed: probed in the client, the
  bridge reloads itself cleanly from its own `Logic` callback, provided its `PluginShutdown`
  calls `Unsubscribe` directly (see below). The reloaded bridge is a new session, so
  that command's result is never reported. The daemon resolves it as "bridge restarted before
  reporting" as soon as the new session syncs, so `rsdev.py exec "prl dev-bridge"` exits 1
  (`error: bridge restarted before reporting`), or 3 (outcome unknown) if the new session hasn't
  synced within `--timeout`. That is the expected result of a successful reload, not a failure.
- If a sync reply carrying commands is lost (the plugin's request fails after the daemon
  answered), those commands are never run and never re-sent, and `rsdev.py exec` reports
  "delivered but no result" (exit 3). That is safe for non-idempotent commands, but exit 3
  means "unknown": check the client.
- At load it subscribes the six events in `protocol.LOAD_EVENTS`: `Logic` (as
  `devBridgeLogic`), then the five above, each as `devBridge<Event>`, the same names and order
  as stage 1's bridge. Each handler forwards its event if it is one of the five above, does the
  bridge's own work on `Logic`, then runs the eval probes on that event. With none, that costs
  one table read per delivery. Other events are subscribed only while an eval probe needs them
  ("Eval" below).
- **Every `Event.<X>.Unsubscribe` is a direct call.** All seven client aborts seen on
  2026-10-26 passed it straight to `pcall` (`pcall(Event[event].Unsubscribe, name)`), including
  three `prl dev-bridge` reloads whose `PluginShutdown` did; stage 1's bridge, which calls it
  directly, reloaded cleanly (docs/api-concepts.md, "Runtime limits we've hit").
- Disabling or reloading it runs `PluginShutdown`: it cancels any sync in flight, then
  unsubscribes, directly, every probe event subscribed at the client and the six load-time
  events. An internal error (in a handler or a probe fan-out) stops the bridge by making every
  handler do nothing, clearing the probes and cancelling the sync in flight; it makes no client
  call, and unsubscribes nothing until `PluginShutdown`.
- Every `[BRIDGE]` console line is also sent to the daemon as a `Log` event
  (`{plugin: "dev-bridge", level: "log", text}`), so `rsdev.py logs` shows it.

## Eval

`rsdev.py eval <lua>` (or `--file F`) sends a snippet as a command of kind `eval`. It runs on a
Logic tick, one command per tick, like `exec`.

- The source is compiled as `return <source>` first, so an expression gives its values, and
  if that doesn't compile, as `<source>`. A compile or runtime error is `ok=false` with the Lua
  error message. The result carries `values` (each serialised the way forwarded event payloads
  are: tables copied, an API config as `{config, id, type}`, other objects as text), `nvalues`
  (how many were returned, trailing nils included; nils show as `null`) and `output`.
- Snippets run in a scratch environment kept for the bridge session, so a global one snippet
  sets, the next can read (`_G` is the scratch table too). Reads of anything else fall through
  to the bridge's globals, so the whole API is there. The scratch env is a convenience, not a
  sandbox.
- `print` and `log` in a snippet go into the result's `output`, and to the console. Called
  later, from a probe's callback, they become `Log` events with `source: "eval"`, and still
  reach the console.
- `emit(tag, value)` sends an `Emit` event `{tag, value}` (the tag as text, the value serialised
  like the result's values). Read them with `rsdev.py events --name Emit`.
- `Event.<Name>.Subscribe(name, callback)` in a snippet installs a **probe**: `callback` is
  called with the event's payload each time the bridge's own handler for that event runs.
  A probe is an entry in a table in `eval.lua`, not a client subscription of its own, so it
  can't touch the bridge's subscriptions whatever its name. Subscribing a name the event already has
  replaces it: the old callback is not called again and the new one goes last. A probe's
  returns are dropped (no probe-able event uses a subscriber's return), so it can't affect the
  client that way; it can still edit the payload (`ChatMessage.chatMessage`, say), and
  forwarding happens before the probes run.
- `Event.<Name>.Unsubscribe(name)` removes the probe; an unknown name does nothing. Both are
  table edits, safe anywhere, including from inside a probe.
- **Probe-able events** are those in `protocol.PROBE_EVENTS`: every event in the API stub
  but four. `Subscribe` and `Unsubscribe` refuse those four with a Lua error naming the event
  and why: `Draw` fires every rendered frame, so a handler there would cost frame time for the
  whole session; `EntityDraw` fires for every entity on every frame, and its subscribers'
  boolean return decides whether the entity is drawn; `SettingsLayerReady` and
  `ContentLayerReady` never fire for the bridge, which has no `hasSettingsIcon` or
  `hasRibbonIcon` in its manifest. An unknown name is refused as "no such event".
- **Lazy subscriptions.** A probe on one of the six load-time events runs from the bridge's
  existing handler, with no client call. The first probe on any other event makes one direct
  client call, `Event.<X>.Subscribe("devBridgeProbe<X>", handler)`, there and then in the
  snippet (a `Subscribe` from inside `Logic` works). When that event's last probe goes (its
  `Unsubscribe`, its first error, or a reset), the bridge doesn't unsubscribe at once: it
  queues the event, and its own `Logic` handler calls `Event.<X>.Unsubscribe("devBridgeProbe<X>")`
  directly on a later tick. A new probe on the event before then cancels the removal, so the
  subscription stays. Until then the subscription delivers to no probes, which costs a table
  read.
- **Changes during a fan-out** (mark and sweep): a probe removed while its event's probes are
  being called (by itself, another probe or an error) is not called again in that pass, and is
  dropped from the table when the pass ends. One added or replaced during the pass is first
  called on the next delivery of that event, including a nested delivery during the current
  pass.
- A probe whose callback raises is removed after its first error, which is reported once as a
  `Log` event (level `error`, source `eval`, naming the event, the probe's name and the error)
  and on the console. Other probes keep running.
- A session holds at most 32 live probes. A `Subscribe` of a new one past that raises a Lua
  error in the snippet (`ok=false`) naming the cap; `Unsubscribe` frees a slot at once, and
  `rsdev.py eval --reset` clears them all.
- **Never pass `Event.<X>.Unsubscribe` straight to `pcall`** (or `xpcall`), from a snippet or
  anywhere: that form aborted the client seven times. A snippet can reach the real `Event`
  through `getmetatable(_G).__index`; one that subscribes it must unsubscribe it itself, with
  a direct call, before a reset or reload: neither knows about it, and after a reset its
  callback keeps firing. Prefer probes.
- `ExecuteConsoleCommand` in a snippet refuses what `exec` refuses: a self-disable raises a Lua
  error, so the eval fails with that message. `prl dev-bridge` is allowed, and as with `exec`,
  the reload means that eval's result is never reported.
- `rsdev.py eval --reset` (kind `reset`) clears every probe and starts a fresh scratch env, then
  answers ok (no values). The bridge does not reload: same session, no console command. Probe
  events subscribed at the client are unsubscribed on the next `Logic` tick, as above. Disabling or reloading the bridge also clears the probes and the scratch env,
  which lives for one session and is never saved.
- Caps keep a sync under the daemon's 2 MB body limit. Values over 64 KB encoded are dropped
  (`nvalues` stays the true count), `output` keeps 200 lines of up to 2 KB each, and a result
  over 1 MB encoded loses its output. Each cut sets `truncated: true`, and `ok` is unchanged.
  An `Emit` whose value is over 64 KB encoded carries `truncated: true` and no value. A `Log`
  text, an `Emit` tag or an error over 2 KB is cut, ending in `<+N bytes>`.
- **A snippet that runs for over 1000 ms is killed by the client** (the per-call limit,
  docs/api-concepts.md). It runs inside the bridge's own Logic callback, so that takes the
  bridge down with it, and only `pon dev-bridge` from the console brings it back. A probe on
  `Logic` runs in the same handler call as the bridge's own Logic work and shares that 1000 ms
  budget, so a slow probe takes the bridge down the same way. Nothing guards against either:
  keep snippets and probes short, and spread long work across ticks.
- Eval compiles with `load(chunk, "=eval", "t", scratchEnv)`; the client honours the mode and
  env arguments (seen 2026-10-26: a snippet's `x = 1` stayed in the scratch env). Without
  `load`, every eval fails with "this client has no load()".

## Why it isn't for submission

It executes console and cheat commands and Lua sent from outside the client, which no submitted
plugin may do, and forwards chat to a program on your machine (only your own lines and system messages:
speech from other players is dropped, as is every chat type not on the allowlist in
`protocol.lua`). `GENERAL` and the other system types are forwarded with their text as-is, so
that text can still name other players. Residual risk: a `MiniMenuEntrySelected` that names a
player without `playerData`, a `PLAYER` entry type or a player action type (friends-list or
chat-name right-clicks, say; unprobed) is not redacted.

Those chat and menu filters cover only the events the bridge forwards itself, and default
forwarding is unchanged by eval. **They do not apply to eval:** a snippet can read anything the
API exposes, other players included, and a probe sees the full payload of every subscribed
event (other players' chat text, inventories, menu entries naming players) and could emit it.
What a snippet returns or emits reaches the daemon unfiltered. A probe on `KeyUp`, `KeyDown` or
`KeyTyped` sees every keystroke while it is installed; the bridge subscribes to those events
only while such a probe exists. Eval is the conductor's local dev tool, with
the same trust as `exec`: it runs only Lua that the daemon on this machine sends. The daemon
logs each snippet's first 200 characters to `dumps/rsdev/daemon.log` and hands the result to
the waiting `rsdev.py eval`, which prints it. Its `Emit` and `Log` events are written to
`dumps/rsdev/events/`. All of `dumps/` is gitignored, and the bridge is never submitted.

It exists only to test other plugins on the dev worlds.
