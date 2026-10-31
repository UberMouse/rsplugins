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
`scripts/check.sh` skips any `plugins/*` folder holding a `.flake-source` marker, so selene,
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
scripts/rsdev.py eval <lua code...> | --file F | --reset [--plugin NAME] [--timeout 10]
scripts/rsdev.py logs [--since N] [--follow] [--plugin X] [--json]
scripts/rsdev.py shot [--region WxH+X+Y] [--max 1600] [--count N --every S] [--delay S] [--window 0x...]
scripts/rsdev.py ui [--all]                  # the plugin layer's components: type, centre, size, flags, text
scripts/rsdev.py click X Y | --text T [--nth N] [--right] [--hold 0.08] [--shot]
scripts/rsdev.py move X Y | --text T [--nth N] [--stay 0.5] [--shot]
scripts/rsdev.py drag X Y X2 Y2 [--hold 0.1] [--steps 10] [--duration 0.5] [--shot]
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
with the manifest URL `"urls": { "rsdev": "http://127.0.0.1:8766" }` (the recorder uses the same
`rsdev` key).

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

### Input: `ui`, `click`, `move`, `drag`

These let Claude press plugin UI in the client itself, with the user's real pointer (XTEST
through `xdotool`; the client ignores XSendEvent clicks). The scope is the user's decision
([plans/client-driving.md](plans/client-driving.md)): **only UI a plugin made**, never the game
world or game interfaces, which could send an action to the server. There is no keyboard
command yet: plugins can't tell whether the console is open, so typed keys could reach ability
keybinds or the chat box.

**`ui`** runs `plugins/dev-bridge/probes/ui-tree.lua` through the bridge and prints every
component under the plugin layer, nested: `#index TYPE at cx,cy WxH [flags] 'text'`, where
`cx,cy` is the centre of the part left visible after clipping by its ancestors, in window
pixels, and the flags are `c` clickthrough, `e` enabled, `v` visible. Components that are hidden or
clipped out of view are left out unless `--all`. Use it to find what to click instead of
reading coordinates off a shot.

**`click`**, **`move`** and **`drag`** take window-pixel points (the `ui` coordinates), or for
`click` and `move`, `--text T`: the shown component whose text is T (ignoring case), or else
contains it; several matches need `--nth N`. Before touching the pointer, each command:

1. walks the plugin layer through the bridge. **The bridge must be connected**: nothing else can
   vouch that a point is plugin UI;
2. refuses an interface scale other than 100, the only one where plugin units are window pixels;
3. refuses a point outside the window, or one not on a shown, non-clickthrough plugin component
   other than the plugin layer itself (that component stops the click reaching the game; `enabled`
   doesn't count, since clickable rows read false). For `drag`, every point the pointer passes
   with the button held: the press, each step and the release;
4. checks that you've left mouse and keyboard alone for 3 s, and since before the walk began
   (`xprintidle`). If not, it waits up to `--idle-wait` (30 s, else refuses) and goes back to
   step 1: what you did may have moved or closed the UI the walk found.

Then it notes where the pointer and focus were and moves the pointer onto the point (i3's focus
follows it). If the pointer isn't where it was put, or the client lost focus, it stops: someone
else has the mouse. `click` holds the button `--hold` seconds, so the press and release fall in
different Logic ticks rather than arriving release-first. `move` stays `--stay` seconds (for
hover states and tooltips). `drag` presses, moves in `--steps` over `--duration`, checks the
end, and releases. With `--shot`, a shot (shot's `--region`/`--max`/`--window` apply) is taken
`--shot-delay` (0.5 s) later, while the pointer is still there. Whatever happens, including
Ctrl-C, a held button is released and the pointer and focus are put back.

Exit codes: 0 done; 1 stopped partway (the pointer moved, focus lost, an X tool failed); 2 never
started (refused, the bridge is down, you were active, no client window, a tool missing); 130
interrupted. Every outcome is appended to `dumps/rsdev/input.log`, the input audit trail (the
CLI does the input itself, so `daemon.log` doesn't see it).

In-client check (2026-10-31, chore-tracker): `ui` listed the window and rows with their text;
`move --text 'Dream of Iaia XP' --shot` showed the row's tooltip; two `click --text` on it
unticked then re-ticked it; `click 500 500` (the game world) was refused with exit 2 and the
pointer untouched; `drag` on a row's grip moved the row and a second drag moved it back.

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
`level` is `print`, `log` or `error` (anything else, `dropped` included, is a 400), and `text` a
string. The reply is `200` with an empty body, or `400` with nothing applied. The body cap,
`Content-Length` rules and `Host`/`Origin` refusals are those of `/bridge/sync`. A body may also
carry `"remote": true` and `"results": [...]` (results as in a sync); then the reply body is that
plugin's queued commands, in the sync reply's line format (see "Remote eval" below). Each line becomes a
`Log` event with payload `{plugin, level, text}`, the line's `t` and the tee's `session`, numbered
in the same stream `events` and `logs` read, and appended to
`dumps/rsdev/events/tee/<plugin>/<session>.jsonl` (a directory per plugin, so different plugin and
session pairs never share a file). A growth in the batch's `dropped` makes the daemon add a marker,
unlike a sync's, as a `Log` event with payload `{plugin, level: "dropped", text: "<n> lines lost"}`,
so `logs` and `logs --plugin X` show which plugin lost lines. A plugin never sends `dropped` as a
level.

**Opting a plugin in.** `lib/dev/tee.lua` is the plugin side: it sends a plugin's own `print` and
`log` output, and the errors its event callbacks raise, to this endpoint. It is a dev tool,
never for submission. A plugin opts in like the recorder does:

1. `ln -s ../../lib/dev plugins/<name>/dev` (commit the link).
2. First lines of `main.lua`:

   ```lua
   local tee = require("dev/tee") -- nil when dev/ isn't there
   if tee then tee.install(_ENV, "<name>") end
   ```

3. In `PluginShutdown`, after the plugin's own `Unsubscribe`s: `if tee then tee.shutdown() end`.
   It unsubscribes the tee's own `devTeeFlush` Logic subscription and cancels a request in
   flight. Skipping it leaves a subscription registered at unload, the suspected cause of a
   client segfault on `prl` (docs/api-concepts.md, crash 8).
4. In `plugin.json`: `"httpAccess"` in `optionalPermissions` and
   `"urls": { "rsdev": "http://127.0.0.1:8766" }` (the dev bridge's url name, so one entry
   serves both).

Before uploading, strip the opt-in from a copy of the plugin:
[Preparing the zip from this repo](submission.md#preparing-the-zip-from-this-repo).
`scripts/check-submission.sh` fails while any piece of it is left, and on any `urls` entry
pointing at 127.0.0.1 or localhost.

Then `scripts/rsdev.py exec "prl <name>"` and `scripts/rsdev.py logs --plugin <name>` shows what
the plugin printed, as `n [<name>] print|log|error: text`. An `error` line reads
`Event.<X> subscriber '<name>': <message>`; the error is then raised again unchanged, so the
client reports it as before. Errors outside event callbacks (a failing `main.lua`, say) are not
caught.

Behaviour: each `print`/`log` call is one line (arguments `tostring`'d and joined by a space, cut
to 2 KB). Lines are posted from `Logic` only, one request in flight, every 50 ticks while there
are lines. At most 500 lines or 256 KB are kept while the daemon can't be reached, the oldest
dropped and counted in `dropped`. A failed post (daemon down, non-200) keeps its lines and
retries after 5 s, doubling to 60 s; a 400 drops that batch (the daemon applied nothing). Each
failure streak logs one `[TEE]` console line. Without `urls.rsdev` or without httpAccess already
granted at load, the tee logs one `[TEE]` line and changes nothing (granting later needs a
`prl`: `ppr <name>`, `ppe <name> httpAccess`, `prl <name>`). With the dev recorder too, require
both modules first, then call `tee.install`, then `recorder.install` (spec in
`tests/tee/tee_spec.lua`).

**Moderation.** The tee sends only the plugin's own console output and errors, to 127.0.0.1. A
plugin for submission ships without `dev/`, the lines above (install and shutdown), httpAccess
(unless a feature of its own needs it) and `urls.rsdev`. Chore Tracker is the first plugin opted
in; its README lists what to strip.

### Remote eval (`eval --plugin`)

```
scripts/rsdev.py eval --plugin <name> <lua code...> | --file F | --reset [--timeout 10]
```

runs Lua **inside a plugin**, where the dev bridge's eval can't reach: its own globals, its
modules (`__PACKAGES_LOADED`), and the state `main.lua` keeps in locals once it exposes it. It
prints and exits like `eval`. `lib/dev/remote.lua` is the plugin side; it rides on the log tee,
so the plugin must be opted into the tee first, with httpAccess granted.

**How it travels.** While remote is installed the tee posts every 25 ticks (half a second) even
with no lines, with `"remote": true`; the daemon answers with the commands queued for that
plugin (`/cli/exec` with `"plugin": "<name>"`, kinds `eval` and `reset` only), and the next
post carries their results. The tee runs one command per Logic tick. A command is only ever
delivered to its own plugin's tee, and only that plugin's results resolve it. A new tee session
(a reload) fails what the old one was sent ("<name> reloaded before reporting"). `rsdev.py
status` lists each plugin's remote as `remote: <name> polling|not polling`, and `eval --plugin`
refuses at once (exit 2) when that plugin's remote isn't polling, naming the likely cause.

**In a snippet** (the scratch env lives for the plugin's session; `--reset` clears it):
- reads fall through to the plugin's globals; writes stay in the scratch env;
- `print`/`log` go to the result's output, and to the console and the tee as before;
- `exposed.<name>`: what the plugin registered with `remote.expose(name, value)`; a function is
  a getter, called with no arguments;
- `press(text, nth)` calls the `onClick` of the pressable whose text is `text` (ignoring case),
  or else contains it, and returns that text. A pressable is any table reachable from the
  exposed values with an `onClick` function and a `text` string or a `label` `ui.Text`. It runs
  the plugin's own handler, so it needs no pointer and works with the client on another
  workspace, but it skips the client's hit testing and event order: use `rsdev.py click` when
  those matter. Several matches raise an error naming them; pass `nth`.

Caps are the bridge eval's: each string value is cut at 4096 bytes (it then ends in
`<+N bytes>`), all of a result's values are dropped once they pass 64 KB encoded (the result
says `truncated`), and 200 output lines of 2 KB are kept. A snippet runs inside the
tee's Logic callback, so one past the client's 1000 ms limit can take the plugin down; `prl` it.

**Opting a plugin in**, after the tee:

```lua
local tee = require("dev/tee") -- nil when dev/ isn't there
local remote = require("dev/remote")
if tee then tee.install(_ENV, "<name>") end
if remote then remote.install(_ENV, tee) end
```

then `if remote then remote.expose("main", function() return { ... } end) end` once the state
it should show exists, and in `PluginShutdown`, before the tee's,
`if remote then remote.shutdown() end`. `check-submission.sh` flags each of these lines. The
plugin's UI helpers keep their click handler on the view table they return (`onClick`) for
`press` to find; that field ships, and is harmless.

In-client check (2026-10-31, chore-tracker): `eval --plugin chore-tracker` returned the mode, the
phase and each row's ticked state from `main.lua`'s locals in 0.74 s; two
`press("Dream of Iaia XP")` unticked and re-ticked that chore; `press("Shop Run")` was refused
naming both shop runs.
