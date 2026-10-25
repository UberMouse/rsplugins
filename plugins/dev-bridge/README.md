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
- `prl dev-bridge` (or `plugins_reload dev-bridge`) is allowed: probed in the client, a plugin
  reloads itself cleanly from its own `Logic` callback. The reloaded bridge is a new session, so
  that command's result is never reported. The daemon resolves it as "bridge restarted before
  reporting" as soon as the new session syncs, so `rsdev.py exec "prl dev-bridge"` exits 1
  (`error: bridge restarted before reporting`), or 3 (outcome unknown) if the new session hasn't
  synced within `--timeout`. That is the expected result of a successful reload, not a failure.
- If a sync reply carrying commands is lost (the plugin's request fails after the daemon
  answered), those commands are never run and never re-sent, and `rsdev.py exec` reports
  "delivered but no result" (exit 3). That is safe for non-idempotent commands, but exit 3
  means "unknown": check the client.
- Disabling it (`poff dev-bridge`) unsubscribes everything, eval probes included, and cancels
  any sync in flight.
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
- `Event.<Name>.Subscribe(name, callback)` in a snippet installs a probe. It is registered under
  `devBridgeEval_<name>`, so it runs beside the bridge's own subscriptions and can't replace
  them, and `Event.<Name>.Unsubscribe(name)` takes the same name. A probe whose callback raises
  is unsubscribed after its first error, which is reported once as a `Log` event (level
  `error`, naming the event, the probe's name and the error) and on the console. Other probes
  keep running.
- `ExecuteConsoleCommand` in a snippet refuses what `exec` refuses: a self-disable raises a Lua
  error, so the eval fails with that message. `prl dev-bridge` is allowed, and as with `exec`,
  the reload means that eval's result is never reported.
- `rsdev.py eval --reset` (kind `reset`) unsubscribes every probe and starts a fresh scratch
  env. Disabling or reloading the bridge does the same: the scratch env lives for one session
  and is never saved.
- Caps keep a sync under the daemon's 2 MB body limit. Values over 64 KB encoded are dropped
  (`nvalues` stays the true count), `output` keeps 200 lines of up to 2 KB each, and a result
  over 1 MB encoded loses its output. Each cut sets `truncated: true`, and `ok` is unchanged.
  An `Emit` whose value is over 64 KB encoded carries `truncated: true` and no value. A `Log`
  text, an `Emit` tag or an error over 2 KB is cut, ending in `<+N bytes>`.
- **A snippet that runs for over 1000 ms is killed by the client** (the per-call limit,
  docs/api-concepts.md). It runs inside the bridge's own Logic callback, so that takes the
  bridge down with it, and only `pon dev-bridge` from the console brings it back. Nothing guards
  against this: keep snippets short, and spread long work across ticks with a probe.
- Unconfirmed in the client: eval compiles with `load(chunk, "=eval", "t", scratchEnv)`. The
  client has a global `load` (`hello.env` says `function`), but whether it honours the mode and
  env arguments isn't checked yet. If it ignored the env, a snippet's globals would land in the
  bridge's own. Without `load`, every eval fails with "this client has no load()".

## Why it isn't for submission

It executes console and cheat commands and Lua sent from outside the client, which no submitted
plugin may do, and forwards chat to a program on your machine (only your own lines and system messages:
speech from other players is dropped, as is every chat type not on the allowlist in
`protocol.lua`). `GENERAL` and the other system types are forwarded with their text as-is, so
that text can still name other players. Residual risk: a `MiniMenuEntrySelected` that names a
player without `playerData`, a `PLAYER` entry type or a player action type (friends-list or
chat-name right-clicks, say; unprobed) is not redacted.

Those chat and menu filters cover only the events the bridge forwards itself. **They do not
apply to eval:** a snippet can read anything the API exposes, other players included, and what
it returns or emits reaches the daemon unfiltered. Eval is the conductor's local dev tool, with
the same trust as `exec`: it runs only Lua that the daemon on this machine sends. The daemon
logs each snippet's first 200 characters to `dumps/rsdev/daemon.log` and hands the result to
the waiting `rsdev.py eval`, which prints it. Its `Emit` and `Log` events are written to
`dumps/rsdev/events/`. All of `dumps/` is gitignored, and the bridge is never submitted.

It exists only to test other plugins on the dev worlds.
