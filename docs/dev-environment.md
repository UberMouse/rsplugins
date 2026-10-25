# Development environment

## Joining the plugin beta

Unmoderated plugins only load on the plugin beta world. To launch it:

| Launcher | Launch URI |
|---|---|
| Jagex Launcher | `jagex:launch=runescape,args=%5BconfigURI=rs-launch://www.runescape.com/jav_config_beta.ws%5D` (auto-logs in) |
| Bare RuneScape client | `rs-launch://www.runescape.com/jav_config_beta.ws` (then log in normally) |

The key part is the client config URI `rs-launch://www.runescape.com/jav_config_beta.ws`. On
Linux, point whatever launches the client (Bolt, or the Jagex Launcher under wine/flatpak) at that
config URI.

- On first login, click **Import save** in the lobby to copy your live character into the beta.
  You can re-import once per hour.
- Beta progress never goes back to live.
- **To go back to live:** fully close the game *and* the launcher (kill the processes if they
  linger), then launch normally.

## Plugin root folder

The beta client keeps its own data folder. Plugins go in there. You've found it when it holds
`*.jcache` files. While the client is loading, the cog icon on the loading window shows the cache
location.

| Platform | Beta root |
|---|---|
| Windows | `C:\ProgramData\Jagex\RuneScape-BETA` |
| macOS | `/Users/<user>/Jagex/RuneScape-BETA` |
| Linux (Bolt) | `~/.local/share/bolt-launcher/Jagex/RuneScape-BETA` (the official docs say lowercase `jagex/`; on our machine it's `Jagex/`) |
| Linux (Jagex Launcher via flatpak wine) | `~/.var/app/com.jagex.Launcher/data/wine/drive_c/users/<user>/AppData/Local/Jagex/RuneScape-BETA` |

Other installs: <https://runescape.wiki/w/Jagex_cache#Installation_paths>.

Inside the root:

- `plugins/`: plugins downloaded from the plugin browser (created by the client).
- `dev_plugins/`: **create this yourself.** Each subfolder is one plugin under development. The
  folder name is the plugin's name for console commands, so use no spaces.

**In this repo:** `dev_plugins/` is a symlink to the repo's `plugins/` directory, so every plugin
folder in `plugins/` is visible to the client. Set it up with `scripts/link-dev-plugins.sh`, run
from the main checkout. It defaults to Bolt's beta root, or takes another root as an argument.
(`plugins_setpath`, below, is an alternative.)

## The client console

- Toggle with **Alt + \`** (the key under Esc) on Windows/Linux, **Option + \`** on macOS. This
  works on non-UK layouts too: it's whatever key sits under Esc.
- While it's open, all keystrokes go to the console, not the game.
- Up/Down scroll through command history.
- `print(...)` and `log(...)` output from plugins appears here (`log` adds source location).
- Lua errors appear here too, e.g.
  `[ERROR] in ...: [string "..."]:1: unfinished string near <eof>`. The `:1` is the line number.

### Plugin management commands

There's no in-game plugin management UI yet, so you manage plugins from the console.

| Command | Short | Effect |
|---|---|---|
| `plugins_setpath <disk path>` | | Change where plugin folders are looked for |
| `plugins_refresh` | `prf` | Rescan for plugins. Needed after adding/removing a plugin or editing a manifest |
| `plugins_list` | `plist` | List found plugins (`[ENABLED]` marks running ones). Shows the **last scan**, so new plugins are missing and deleted ones linger until you `prf` |
| `plugins_setenabled <name> [true/false]` | | Enable/disable (defaults to enable) |
| `plugins_enable <name>` | `pon <name>` | Enable |
| `plugins_disable <name>` | `poff <name>` | Disable |
| `plugins_reload <name>` | `prl <name>` | Disable + re-enable |
| `plugins_permissions_request <name>` | `ppr <name>` | Make a loaded plugin request its manifest permissions |
| `plugins_permissions_enable <name> <perm>` | `ppe` | Grant a permission (`httpAccess`, `chatAccess`, `trackingAccess`) |
| `plugins_permissions_disable <name> <perm>` | `ppd` | Revoke a permission |

Always run `ppr <name>` before `ppe <name> <perm>`. `ppe` on a permission the plugin hasn't
requested is a silent no-op: no error, and no permission.

You can enable, disable and reload plugins without restarting the client.

### Other useful console commands

- `pan <ConfigType>` copies a full `id` / `configName` list for a config type to the clipboard,
  e.g. `pan NPC`, `pan Obj`, `pan VarPlayer`, `pan VarClient`. Use it to find the config name to
  use as `config.NPC.<NAME>` and similar. These lists are big (32k+ NPCs).
- Cheat commands (`!tele`, `!give`, `!setvar`, …) are listed in [cheats.md](cheats.md).
- **Ctrl + Shift + left-click** on the world, minimap or world map teleports you instantly
  (beta only).

## Dev loop

1. Edit Lua or manifest files.
2. Manifest changed, or plugin added/removed? Run `prf`.
3. `prl <name>` to reload. **Saved changes don't take effect until you reload.**
4. Watch the console for `print`/`log` output and errors.

Top-level code in `main.lua` runs once each time the plugin is enabled. Anything ongoing needs
event subscriptions (see [api-concepts.md](api-concepts.md#events)).

## Third-party dev plugins

Two community dev tools are pinned in `flake.nix` (as `flake = false` inputs, not vendored) and
linked into `plugins/` by the dev shell's `shellHook`, so the client's `dev_plugins` symlink picks
them up. The links are gitignored, and `.luarc.json` skips them (`workspace.ignoreDir`); `scripts/check-lua.sh`
(so selene, stylua and LuaLS) and the tests never reach them, because its `find` doesn't follow
symlinked folders. Neither is ours: they are never submitted, and they are not held to
this repo's code rules.

| Folder | Source | What it is |
|---|---|---|
| `plugins/debug-plugin` | [FriendlyDevelopment/debug-plugin](https://github.com/FriendlyDevelopment/debug-plugin) (no licence) | Debugging UI with a ribbon icon and settings. Needs **PrettyUI** installed in the client. Self-grants permissions with `ppr debug-plugin`. |
| `plugins/dev-kit` | the `dev-kit/` subfolder of [wildrabbet/dev-kit](https://github.com/wildrabbet/dev-kit) (MIT) | Dev window. It runs cheat commands, so use it on dev worlds only. |

The folder names matter: they are the plugins' names for console commands. The hook replaces only
an existing symlink or nothing, never a real directory. Bump both with
`nix flake update debug-plugin dev-kit`, then re-enter the shell. After `prf`, `plist` should list
both; enable with `pon debug-plugin` / `pon dev-kit`.

## Dev bridge

The dev bridge lets Claude (from Bash) drive the running client and watch it while you play:
queue console commands for the client, and read the events a plugin forwards. It is a dev tool,
never for submission. One host daemon, `scripts/rsdev.py`, serves it and also receives the dev
recorder's batches ([Recordings](testing.md#recordings)). The `dev-bridge` plugin in the client
polls the daemon over HTTP.

```
scripts/rsdev.py start                       # detached; log dumps/rsdev/daemon.log, pid dumps/rsdev/daemon.pid
scripts/rsdev.py status                      # daemon up?, bridge connected?, session, seq, env facts, queue, events, dropped
scripts/rsdev.py exec <console command...> [--timeout 10]
scripts/rsdev.py events [--since N] [--follow] [--name X]
scripts/rsdev.py stop                        # asks the daemon for its pid; signals only if it matches the pid file
```

`scripts/rsdev.py daemon` runs it in the foreground instead. `--port` (default 8766) and `--out`
(default `dumps/` in the repo, whatever the cwd) go on any subcommand. The daemon listens on
127.0.0.1 only, but that alone doesn't keep out web pages in your browser (they can POST to
loopback, and DNS rebinding can point a hostname at it). So every request is refused with a 403
(and one log line naming the route and the header) if its `Host` isn't `127.0.0.1:<port>` or
`localhost:<port>`, or if it carries an `Origin` header, which browsers add to cross-origin
requests; the CLI sends none. `/cli/*` also needs the header `X-Rsdev: 1`, which the CLI always
sends and which makes a browser preflight the request (the daemon never answers a preflight with
CORS headers). If the in-client bridge plugin's HTTP library sends an `Origin`, the log will show
`refused /bridge/sync: Origin ...`. A plugin names the daemon
with the manifest URL `"urls": { "rsdev": "http://127.0.0.1:8766" }` (the recorder's `recorder`
URL is the same address).

**`exec`** queues one console command, waits for the plugin's result and exits: 0 ok; 1 the plugin
reported an error (printed); 2 never delivered before the timeout (the command is withdrawn, so it
can never run later) or the daemon is down; 3 delivered but no result arrived in time (the outcome
is unknown). Commands run in the order queued, and each is delivered at most once. **Every command
is logged with its id in `dumps/rsdev/daemon.log`**: that log is the audit trail.

**`events`** prints the forwarded events as JSON lines, each with an increasing `n`, numbered from 1
per daemon run (a restarted daemon starts again at 1; `--follow` notices, says so on stderr and
continues from 0). `--since N` gives those after `n`; `--name` keeps one event name; `--follow`
keeps printing until interrupted. The last 10,000 are kept in memory; every event is also appended to
`dumps/rsdev/events/<session>.jsonl`. A growth in a sync's `dropped` count appears as an event
`{"name": "dropped", "n_lost": ...}`.

### Protocol (schema 1)

The plugin polls with `POST <urls.rsdev>/bridge/sync`. The body is JSON:

```json
{"schema": 1, "plugin": "dev-bridge", "session": "<id per enable>", "seq": 1, "dropped": 0,
 "hello": {"version": "Lua 5.4", "env": {"load": "function", "io": "nil"}},
 "events": [{"t": 1234, "name": "ChatMessage", "payload": {}}],
 "results": [{"id": "c1-ab12cd", "ok": false, "error": "text"}]}
```

- `plugin` and `session` match `[A-Za-z0-9][A-Za-z0-9._-]{0,63}`; `seq` counts syncs from 1; `dropped`
  is the cumulative number of events lost on the plugin side (`>= 0`); `t` is the logic tick;
  `payload` is any JSON; `error` is a string (when `ok` is false).
- `hello` is sent on every sync, so it survives a daemon restart. `env` maps global names to their
  `type()` (at least `load`, `loadstring`, `debug`, `os`, `io`, `require`,
  `ExecuteConsoleCommand`, `coroutine`).
- A bad body (not JSON, wrong types, a bad name) gets a `400` and nothing from it is applied.

The reply is `200` with a `text/plain` body of zero or more lines, newline-terminated:
`<id>\t<kind>\t<arg>`. `arg` escapes `\` as `\\`, tab as `\t`, newline as `\n` and CR as `\r`, so
a line splits on tabs and the arg is un-escaped after. Ids match `[A-Za-z0-9_-]{1,32}`; the plugin
echoes the id in `results`. Stage 1 has one kind, `exec`, whose arg is a console command. A
command in a reply counts as delivered; the daemon never sends it again. For the plugin, any
non-200 reply, or a body that fails to parse, is a failed sync.

A sync from a new `session` is logged, and any command delivered to the previous session without
a result is resolved as failed with "bridge restarted before reporting". `status` calls the bridge
connected if its last sync was under 2 s ago.

The CLI talks to the same port under `/cli/` (`GET /cli/status`, `POST /cli/exec`,
`GET /cli/events?since=&wait=&name=`); these are not for plugins.
