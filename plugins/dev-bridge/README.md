# Dev Bridge (dev tool, never submitted)

**This plugin is never submitted to Jagex.** It runs, in your client, whatever console commands
the daemon on your own machine (`scripts/rsdev.py`) hands it, cheat commands included.
`ExecuteConsoleCommand` and cheats only work on the dev worlds, and no submitted plugin may run
commands sent from outside the client. Cheat commands are logged on Jagex's server
(tutorial/6cheats.html), so only queue what you would type yourself.

It lets Claude, from a terminal, drive the client and watch what happens while you play:

- `scripts/rsdev.py exec "prl chore-tracker"` queues a console command; the bridge runs it and
  reports whether `ExecuteConsoleCommand` raised (ok means it ran without a Lua error, not that
  the command did what you hoped).
- `scripts/rsdev.py events --follow` prints the events the bridge forwards: `ChatMessage` (every
  chat type), `VarTransmit`, `InventoryUpdated`, `MiniMenuEntrySelected` and `GameStateChanged`,
  each stamped with the Logic tick it arrived after.
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
  up to 1 MB of events. Past that the oldest are dropped, and events in a sync the daemon never
  received are lost too; the sync's `dropped` count tells the daemon how many.
- It refuses any command that would disable or reload it, or revoke one of its permissions
  (`prl`, `poff`, `plugins_reload`, `plugins_disable`, `plugins_setenabled`, `ppd`,
  `plugins_permissions_disable` naming `dev-bridge`), because what the client does when a plugin
  disables itself from inside its own callback hasn't been tried. Run those from the console.
- Disabling it (`poff dev-bridge`) unsubscribes everything and cancels any sync in flight.

## Why it isn't for submission

It executes console and cheat commands sent from outside the client, which no submitted plugin
may do, and forwards chat (including other players' names and messages) to a program on your
machine. It exists only to test other plugins on the dev worlds.
