# rsplugins

RuneScape 3 client plugins (Lua 5.4.8, using Jagex's official Client Plugin API).

- Dev tools (Lua 5.4, lua-language-server, stylua, selene, Python) come from `flake.nix`. With
  direnv, run `direnv allow` once and they load whenever you `cd` in. Otherwise use `nix develop`.
- [docs/](docs/README.md): our notes on the plugin API, dev environment, guidelines and Mod.io
  submission. `docs/api/` is the API reference as LuaLS stubs. The dev shell links it, and
  `.luarc.json` points editors at it, so you get completion and type checks.
- `scripts/check-lua.sh`: the lint gate (luac, manifests, selene, stylua, LuaLS type check).
- `plugins/<name>/`: one folder per plugin (`main.lua` + `plugin.json`). The folder name is the
  plugin's console name.
- `scripts/link-dev-plugins.sh`: symlinks the beta client's `dev_plugins/` to `plugins/`. After
  that, the in-client loop is `prf`, `plist`, `pon <name>`, `prl <name>` (see
  [docs/dev-environment.md](docs/dev-environment.md)).
- `scripts/var-dump-receiver.py`: local HTTP receiver for the `var-dump` dev plugin (see
  [plugins/var-dump/README.md](plugins/var-dump/README.md)).
- `lib/dev/` + `scripts/dev-receiver.py`: a dev recorder a plugin opts into, which streams what
  it does with the API in the client to a local receiver (see
  [docs/testing.md](docs/testing.md#recordings); `plugins/recorder-demo` is the example).
