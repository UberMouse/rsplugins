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
copied into `plugins/` as real directories by the dev shell's `shellHook`, so the client's
`dev_plugins` symlink picks them up. They are copies because the client skips a symlinked plugin
folder inside `dev_plugins` (probe 2026-10-26; see
[Runtime limits](api-concepts.md#runtime-limits-weve-hit)).
The copies are gitignored, `.luarc.json` skips them (`workspace.ignoreDir`), and
`scripts/check-lua.sh` skips any `plugins/*` folder holding a `.flake-source` marker, so selene,
stylua, LuaLS and the tests never reach them. Neither is ours: they are never submitted, and they
are not held to this repo's code rules.

| Folder | Source | What it is |
|---|---|---|
| `plugins/debug-plugin` | [FriendlyDevelopment/debug-plugin](https://github.com/FriendlyDevelopment/debug-plugin) (no licence) | Debugging UI with a ribbon icon and settings. Needs **PrettyUI** installed in the client. Self-grants permissions with `ppr debug-plugin`. |
| `plugins/dev-kit` | the `dev-kit/` subfolder of [wildrabbet/dev-kit](https://github.com/wildrabbet/dev-kit) (MIT) | Dev window. It runs cheat commands, so use it on dev worlds only. |

The folder names matter: they are the plugins' names for console commands. Each copy holds a
`.flake-source` file with the store path it was copied from. On entering the shell the hook:

- creates the copy if the folder is absent (or replaces an old symlink from the previous design);
- re-copies only when the marker's store path differs from the pinned input, so a bump updates it
  and ordinary entries are cheap. Edits inside a copy are overwritten on that refresh;
- never touches a real directory without the marker; it prints a warning instead.

Bump both with `nix flake update debug-plugin dev-kit`, then re-enter the shell. To force a refresh,
delete the folder and re-enter the shell. After `prf`, `plist` should list both; enable with
`pon debug-plugin` / `pon dev-kit`.

## Dev bridge

The dev bridge lets Claude (from Bash) drive the running client and watch it while you play:
queue console commands for the client, read the events a plugin forwards, and capture the
window (`shot`, below, which needs only the client, not the bridge). It is a dev tool,
never for submission. One host daemon, `scripts/rsdev.py`, serves it and also receives the dev
recorder's batches ([Recordings](testing.md#recordings)). The `dev-bridge` plugin in the client
polls the daemon over HTTP; [its README](../plugins/dev-bridge/README.md) has the console steps
to enable it (`prf`, `pon dev-bridge`).

```
scripts/rsdev.py start                       # detached; log dumps/rsdev/daemon.log, pid dumps/rsdev/daemon.pid
scripts/rsdev.py status                      # daemon up?, bridge connected?, session, seq, env facts, queue, events, dropped
scripts/rsdev.py exec <console command...> [--timeout 10]
scripts/rsdev.py events [--since N] [--follow] [--name X]
scripts/rsdev.py eval <lua code...> | --file F | --reset [--timeout 10]
scripts/rsdev.py logs [--since N] [--follow] [--plugin X] [--json]
scripts/rsdev.py shot [--region WxH+X+Y] [--max 1600] [--count N --every S] [--delay S] [--window 0x...]
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
is unknown). With `--shot`, 4 means the command returned 0 but the shot failed, and 130 means it
was interrupted during the shot (see `shot` below). Exit 3 also covers "never ran": if the HTTP
reply carrying the command is lost (the plugin's request timed out or failed after the daemon
answered), the plugin never receives it and the daemon never re-sends it, so non-idempotent
commands can't run twice; check the client.
Commands run in the order queued, and each is delivered at most once. **Every command
is logged with its id in `dumps/rsdev/daemon.log`**: that log is the audit trail. `eval` and
`reset` are logged the same way, an eval's Lua source cut to its first 200 characters.

**`events`** prints the forwarded events as JSON lines, each with an increasing `n`, numbered from 1
per daemon run (a restarted daemon starts again at 1). `--follow` survives a daemon restart: when
the connection drops it prints "daemon not reachable; retrying" on stderr once and retries every 0.5
s, doubling to 5 s, then prints "daemon reachable again" and, if it had already seen a run from the
old daemon and now sees a new one, "daemon restarted; numbering restarted" and continues from 0,
printing each new event once. Without `--follow`, a down daemon exits 2. `--since N` gives those
after `n`; `--name` keeps one event name; `--follow` keeps printing until interrupted. The last
10,000 are kept in memory, across bridge and tee events together, so a chatty plugin can push
older events out of memory (they remain in the files); every event is also appended to
`dumps/rsdev/events/<session>.jsonl`. A growth in a sync's `dropped` count appears as an event
`{"name": "dropped", "n_lost": ...}`.

**`eval`** queues a command of kind `eval` whose arg is Lua source (the words joined with spaces,
or the contents of `--file`; exactly one of the two, else a usage error), waits for the result
like `exec` and exits with the same codes (0 ok; 1 the plugin reported an error, printed on
stderr, e.g. a Lua error, after any `output` lines the snippet printed before it; 2 never
delivered or daemon down; 3 delivered, no result in time). On success it prints one JSON object to stdout, indented by 2: `{"values": [...], "nvalues": n,
"output": [...]}`, plus `"truncated": true` when the plugin cut something to fit its caps.
`eval --reset` (no code allowed) queues a `reset` command and prints `ok (<id>)`: the bridge
clears its eval probes and starts a fresh scratch env, without reloading (same session, no
console command; probes are entries in the bridge's own table, on any event but `Draw`,
`EntityDraw`, `SettingsLayerReady` and `ContentLayerReady`; an event outside the bridge's six
load-time ones is subscribed at the client while it has probes, and reset leaves its removal to
the next `Logic` tick). Before queueing, `eval` and `eval --reset` check
that the daemon's `GET /cli/status` lists the kind in `kinds`. A daemon started before the eval
kinds existed ignores `kind` and would queue the Lua as a console command, so then the CLI exits
2 without queueing and says to restart it (`scripts/rsdev.py stop && scripts/rsdev.py start`);
`exec` doesn't check. The daemon only
queues and relays these; running the Lua and enforcing the caps is the plugin's job (the
scratch env, probes, `emit` and the caps are in [its README](../plugins/dev-bridge/README.md#eval)). The Lua is
sent by the local daemon, so it has the same trust as `exec`.

**`logs`** prints the `Log` events as `n [plugin] level: text` lines (a multi-line text continues on
lines indented by four spaces), or the raw event JSON lines with `--json`. `--since`, `--follow`
and the restart handling are those of `events`; `--plugin X` keeps one plugin's lines. Lines a tee
lost show as `n [plugin] dropped: <n> lines lost` (see below). `Log` events come from the bridge's own sync (payload `{plugin, level: "print"|"log"|"error", text,
source?}`) and from `POST /tee` below. An `Emit` event (payload `{tag, value}`) is an ordinary
event too: read it with `events --name Emit`.

**`shot`** captures the client's X11 window (`maim -u -i <window>`) so Claude can see the game and
plugin UI while checking a change; it needs no daemon. It prints each file's path on stdout, in
`dumps/rsdev/shots/<YYYYmmdd-HHMMSS-mmm>[-NN].<ext>` (`-NN` only for a `--count` series, which
shares one stamp). The window is found through the window manager's client list by `WM_CLASS`
`"rs2client", "RuneScape"`, never by title; `--window 0x...` names one instead. By default the
shot is shrunk with ImageMagick to fit `--max 1600` px (never enlarged) and written as a JPEG;
`--max 0` keeps the full-size PNG. `--region WxH+X+Y` is relative to the window. `--count N`
(1-100) takes a series, starting a capture every `--every S` seconds (default 1; an overrunning
capture makes the next start at once), after `--delay S`. `exec ... --shot [--shot-delay 1.0]`
captures once the command has a result (ok or a plugin error; not if it was never delivered), and
takes `--region`/`--max`/`--window`, which are errors without `--shot`; exec's exit code stands,
and a failed shot makes it exit 4 only if the command itself returned 0.

`shot` exits 0 ok; 1 the capture or conversion failed (the tool's stderr is shown); 2 it could not
try: no window found or several (it lists them; pick with `--window`), the window is not visible, or a
tool is missing (enter the dev shell: `direnv`). A client on another workspace is refused, naming
that workspace, because maim would silently capture whatever is on screen there. Visibility is
checked before every capture, so a window that leaves the screen mid-series stops the series
(exit 2; paths already printed stay valid); `shot` never switches workspaces, focuses or raises
anything. If another window has focus it warns, since windows on top (floating ones) appear in the
capture. X11 only.

In-client check: with the client showing on screen, `scripts/rsdev.py shot` prints a path under
`dumps/rsdev/shots/` and the image is the game window. Switch to another workspace so the client is
hidden and run it again: it exits 2 with a message naming the client's workspace.

Privacy: a shot shows whatever is on screen, including other players' names and chat. Shots stay in
the gitignored `dumps/`, and Claude views them whenever useful (approved by the user); delete them
when done, nothing prunes them.

### Protocol (schema 1)

The plugin polls with `POST <urls.rsdev>/bridge/sync`. The body is JSON:

```json
{"schema": 1, "plugin": "dev-bridge", "session": "<id per enable>", "seq": 1, "dropped": 0,
 "hello": {"version": "Lua 5.4", "env": {"load": "function", "io": "nil"}},
 "events": [{"t": 1234, "name": "ChatMessage", "payload": {}}],
 "results": [{"id": "c1-ab12cd", "ok": false, "error": "text"}]}
```

- `plugin` and `session` match `[A-Za-z0-9][A-Za-z0-9._-]{0,63}`; `seq` counts syncs from 1;
  `dropped` is the cumulative number of events lost on the plugin side (`>= 0`); `t` is the logic
  tick; `payload` is any JSON; `error` is a string (when `ok` is false).
- `hello` is sent on every sync, so it survives a daemon restart. `env` maps global names to their
  `type()` (at least `load`, `loadstring`, `debug`, `os`, `io`, `require`,
  `ExecuteConsoleCommand`, `coroutine`).
- A bad body (not JSON, wrong types, a bad name) gets a `400` and nothing from it is applied.
- A result may also carry the fields of an `eval`: `values` (a list; each element plain JSON
  data), `nvalues` (an integer: how many values the snippet returned, trailing nils included),
  `output` (a list of strings printed during the snippet) and `truncated` (a boolean: the plugin's
  caps cut something). The daemon checks only these types (a wrong one is a `400`) and hands the
  fields back to the waiting CLI.

The reply is `200` with a `text/plain` body of zero or more lines, newline-terminated:
`<id>\t<kind>\t<arg>`. `arg` escapes `\` as `\\`, tab as `\t`, newline as `\n` and CR as `\r`, so
a line splits on tabs and the arg is un-escaped after. Ids match `[A-Za-z0-9_-]{1,32}`; the plugin
echoes the id in `results`. The kinds are `exec` (arg: a console command), `eval` (arg: Lua
source) and `reset` (empty arg). A
command in a reply counts as delivered; the daemon never sends it again. For the plugin, any
non-200 reply, or a body that fails to parse, is a failed sync.

A sync from a new `session` is logged, and any command delivered to the previous session without
a result is resolved as failed with "bridge restarted before reporting". `status` calls the bridge
connected if its last sync was under 2 s ago.

The CLI talks to the same port under `/cli/` (`GET /cli/status`, which includes
`"kinds": ["exec", "eval", "reset"]`, `POST /cli/exec`,
`GET /cli/events?since=&wait=&name=`); these are not for plugins. `POST /cli/exec` takes
`{"kind": "exec"|"eval"|"reset", "command": "...", "timeout": s}`; `kind` defaults to `exec`,
and `command` is empty for `reset` and non-empty otherwise.

### Log tee (`POST /tee`)

A plugin can forward its log lines to the daemon with `POST <urls.rsdev>/tee`:

```json
{"schema": 1, "plugin": "my-plugin", "session": "<id per enable>", "seq": 1, "dropped": 0,
 "lines": [{"t": 1234, "level": "print", "text": "hello"}]}
```

`plugin`, `session`, `seq` and `dropped` follow the rules of a sync above; `t` is an integer,
`level` is `print`, `log` or `error` (anything else is a 400; `dropped` is produced only by the
daemon), and `text` a string. The reply is `200` with an empty body,
or `400` with nothing applied. The body cap, `Content-Length` rules and `Host`/`Origin` refusals
are those of `/bridge/sync`. Each line becomes a `Log` event with payload `{plugin, level, text}`,
the line's `t` and the tee's `session`, numbered in the same stream `events` and `logs` read, and
appended to `dumps/rsdev/events/tee/<plugin>/<session>.jsonl` (a directory per plugin, so
different plugin and session pairs never share a file). A growth in `dropped` adds a marker, unlike
a sync's, as a `Log` event with payload `{plugin, level: "dropped", text: "<n> lines lost"}`, so
`logs` and `logs --plugin X` show which plugin lost lines.
