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
| Linux (Bolt) | `~/.local/share/bolt-launcher/jagex/RuneScape-BETA` |
| Linux (Jagex Launcher via flatpak wine) | `~/.var/app/com.jagex.Launcher/data/wine/drive_c/users/<user>/AppData/Local/Jagex/RuneScape-BETA` |

Other installs: <https://runescape.wiki/w/Jagex_cache#Installation_paths>.

Inside the root:

- `plugins/`: plugins downloaded from the plugin browser (created by the client).
- `dev_plugins/`: **create this yourself.** Each subfolder is one plugin under development. The
  folder name is the plugin's name for console commands, so use no spaces.

To develop from this repo, symlink each plugin folder into `dev_plugins/`, or use
`plugins_setpath` (below) to point the client somewhere else.

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
| `plugins_list` | `plist` | List found plugins (`[ENABLED]` marks running ones) |
| `plugins_setenabled <name> [true/false]` | | Enable/disable (defaults to enable) |
| `plugins_enable <name>` | `pon <name>` | Enable |
| `plugins_disable <name>` | `poff <name>` | Disable |
| `plugins_reload <name>` | `prl <name>` | Disable + re-enable |
| `plugins_permissions_request <name>` | `ppr <name>` | Make a loaded plugin request its manifest permissions |
| `plugins_permissions_enable <name> <perm>` | `ppe` | Grant a permission (`httpAccess`, `chatAccess`, `trackingAccess`) |
| `plugins_permissions_disable <name> <perm>` | `ppd` | Revoke a permission |

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
