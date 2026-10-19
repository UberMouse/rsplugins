# Plugin anatomy

## Folder layout

```
my-plugin/
├── main.lua        # entry point, run when the plugin is enabled
├── plugin.json     # manifest
├── resources/      # optional runtime assets (exposed as Plugin.resources)
└── anything_else/  # extra Lua modules/folders are fine
```

Only `main.lua`, `plugin.json` and `resources/` are fixed paths. For distribution, zip the
plugin so `main.lua` and `plugin.json` sit at the **top level of the zip**, not inside a
subfolder (see [submission.md](submission.md)).

## Manifest (`plugin.json`)

You can test without a manifest, but submission needs one. The smallest valid manifest:

```json
{ "name": "My Plugin", "version": "0.0.1", "contactEmailAddress": "me@example.com" }
```

| Field | Type | Notes |
|---|---|---|
| `name` | string | User-facing name |
| `version` | string | User-facing version. Mod.io versions allow only digits and `.` |
| `contactEmailAddress` | string | **Legally required.** Shown publicly, so use a dedicated address, not your Mod.io/RS login |
| `requiredDependencies` | `[name]` or `{ luaVar: pluginName }` | Plugins that must be present (see below) |
| `optionalDependencies` | same | Used if present/enabled |
| `requiredPermissions` | `[perm]` | Plugin won't work without these. **Currently broken in the client** (as of 2026-10-20 the plugin doesn't run). Use `optionalPermissions` and check at runtime |
| `optionalPermissions` | `[perm]` | Unlock extra features. **Prefer optional** and check at runtime |
| `urls` | `{ name: url }` | Base HTTP/HTTPS URLs the plugin may call. Exposed as `Plugin.urls.<name>` |

Plugins installed from a remote repository can carry extra `remote*` fields; ignore them.

## Permissions

The current `PluginPermissions` values:

| Permission | Grants |
|---|---|
| `httpAccess` | HTTP functionality (`HTTPRequest`), limited to the manifest's `urls` |
| `chatAccess` | Chat functionality (e.g. `Chat.AddMessage`) |
| `trackingAccess` | `Player.GetTrackingID()`, a unique 64-bit ID for the player. Returns nil until a few seconds after login, or without the permission |

- Check at runtime with `Plugin.HasPermission(PluginPermissions.httpAccess)`.
- The `OptionalPermissionChanged` event fires when the user toggles an optional permission.
- During dev, grant permissions with `ppe <plugin> <perm>`.
- Moderators review **every** plugin that requests a permission more closely. Each permission
  must be justified in the Mod.io description, and the listing needs the matching tag.
- The submission example also mentions "Screenshot" and "File I/O" permissions. Those aren't in
  the enum yet, so they're probably planned.

## Modules: `require`

- `require("path/to/file")` loads a Lua file. The path is **relative to the plugin root (not the
  calling file)**, with no extension. So `a/b/file1.lua` loads its sibling with
  `require("a/b/file2")`.
- It returns whatever the file returns, or `nil` if the file is missing or fails to run.
- Results are cached: each file runs once, and later `require`s get the same table. Any state in
  that table is shared. If you need separate state, export a constructor.
- Circular requires are an error.

## Depending on other plugins

- List plugins by **folder name** in `requiredDependencies` / `optionalDependencies`.
  Dependencies load first.
- Each dependency's returned value is **cloned** and exposed as a **global named after the
  plugin**. Names that aren't valid Lua identifiers get `_` replacements/prefixes
  (`2!GraphLib` → `_2_GraphLib`). Alias with the object form instead:
  `"requiredDependencies": { "Graph": "2!GraphLib" }`.
- An optional dependency's global is `nil` when that plugin is absent or disabled. Check before
  using it.
- Exports are shared by every importer. **Never modify** an imported table. Library plugins
  should hand out per-caller state objects.
- On Mod.io, every *required* dependency must also be declared as a Mod.io dependency. *Optional*
  ones must not be. You can only depend on approved plugins that allow dependents.

## Lifecycle hooks (global functions)

These are called automatically when defined as **globals**. They don't fire if declared `local`.

| Function | When |
|---|---|
| `PluginShutdown()` | When the plugin is disabled/reloaded and when the client closes (including a task-manager kill). **Not** on a client crash |
| `PluginDependencyUpdate(ev)` | When an optional dependency is enabled/disabled. `ev.pluginIdentifier` (its Lua global name), `ev.enabled`. Same as the `OptionalDependencyChanged` event |

If losing data matters, don't save only in `PluginShutdown`. Also write to `PersistentDB`
periodically or whenever the value changes.

## Persistent storage

- `PersistentDB` is a per-plugin key/value store kept on disk. Other plugins can't read or write
  it.
- `PersistentDB:Get(key)` (nil if unset, so write `PersistentDB:Get("k") or default`) and
  `PersistentDB:Set(key, value)`. There are also `CheckExists`, `CheckExistsTyped`,
  `IterateEntries`, `Delete`, `Clear`.
- It's slower than plain Lua variables. Keep working state in memory and persist at sensible
  points.

## Resources

- Files under `resources/` show up as `Plugin.resources`, keyed by filename **without extension**.
  Folders become nested tables: `resources/images/menu/background.png` →
  `Plugin.resources.images.menu.background`.
- Supported formats: **PNG** sprites (max **1024×1024**) and **Ogg Vorbis** audio.
- Resources load when first used, or explicitly with `:Load()`/`:Unload()` (useful for large
  files, or to preload audio and avoid playback lag). Once loaded, a resource stays in memory
  until the plugin unloads and nothing references it.
- Shipping custom images or sounds puts the plugin under closer moderation review.
