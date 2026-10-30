# rsplugins

RuneScape 3 client plugins (Lua 5.4.8, using Jagex's official Client Plugin API).

- Dev tools (Lua 5.4, lua-language-server, stylua, selene, Python, ruff) come from `flake.nix`. With
  direnv, run `direnv allow` once and they load whenever you `cd` in. Otherwise use `nix develop`.
  Claude Code's Bash tool gets them from `SessionStart`, `CwdChanged` and `FileChanged`
  (`.envrc|flake.nix|flake.lock`) hooks in `~/.claude/settings.json`, each running
  `direnv export zsh > "$CLAUDE_ENV_FILE"`, so agents normally never need `direnv exec` (a shell
  started before `flake.nix` changed does: see the message `scripts/check.sh` prints).
- Once per clone, `git config blame.ignoreRevsFile .git-blame-ignore-revs` keeps `git blame` past
  the formatting-only commits.
- [docs/](docs/README.md): our notes on the plugin API, dev environment, guidelines and Mod.io
  submission. `docs/api/` is the API reference as LuaLS stubs. The dev shell links it, and
  `.luarc.json` points editors at it, so you get completion and type checks.
- `scripts/check.sh`: the gate for Lua, Python, JS and shell (its header lists the
  steps). The plugin tests need the var catalog in `docs/vars/`, which isn't committed: build it
  from a var dump first (see
  [plugins/var-dump/README.md](plugins/var-dump/README.md#building-the-var-catalog)).
- `plugins/<name>/`: one folder per plugin (`main.lua` + `plugin.json`). The folder name is the
  plugin's console name.
- `scripts/link-dev-plugins.sh` symlinks the beta client's `dev_plugins/` to `plugins/`. After
  that, the in-client loop is `prf`, `plist`, `pon <name>`, `prl <name>` (see
  [docs/dev-environment.md](docs/dev-environment.md)).

## Plugins

| Folder | What it does | Status |
|---|---|---|
| [`chore-tracker`](plugins/chore-tracker/README.md) | A checklist of the daily, weekly and monthly chores that clears itself at the game's reset | Shipped |
| [`dev-bridge`](plugins/dev-bridge/README.md) | Runs the console commands and Lua snippets the local rsdev daemon queues, and forwards events and logs to it | Dev only |
| [`recorder-demo`](plugins/recorder-demo/README.md) | A small plugin that exercises the dev recorder in the real client | Dev only |
| [`var-dump`](plugins/var-dump/README.md) | Dumps every var the client can read for your character, then logs each change, to a local receiver | Dev only |
| [`walkable-flood`](plugins/walkable-flood/README.md) | An experiment that draws which tiles around you look walkable | Dev only |
| `debug-plugin`, `dev-kit` | Community dev tools pinned in `flake.nix` and copied in by the dev shell (gitignored; not ours) | Dev only |

## Scripts

| Script | What | Docs |
|---|---|---|
| `scripts/check.sh` | The gate: lint, format, type-check and test everything. `scripts/check-lua.sh` is its old name | [its header](scripts/check.sh) |
| `scripts/test-lua.sh` | Runs the plugin tests (busted) | [docs/testing.md](docs/testing.md) |
| `scripts/check-submission.sh` | Fails while a plugin copy still carries a dev opt-in; `check-submission.selftest.sh` tests it | [docs/submission.md](docs/submission.md#preparing-the-zip-from-this-repo) |
| `scripts/link-dev-plugins.sh` | Symlinks the beta client's `dev_plugins/` to `plugins/` | [docs/dev-environment.md](docs/dev-environment.md) |
| `scripts/rsdev.py` | The dev daemon and CLI: recorder receiver, dev bridge (`exec`, `events`, `logs`), `shot` | [docs/dev-environment.md](docs/dev-environment.md#dev-bridge) |
| `scripts/client-surface.py` | Snapshots the client's API surface into a test fixture, through the bridge | [docs/testing.md](docs/testing.md#checking-the-mocks-against-the-live-client) |
| `scripts/recording-sanitise.py`, `recording-chat-allowlist.txt` | Turn a recorded session into a committed fixture | [docs/testing.md](docs/testing.md#turning-a-session-into-a-fixture) |
| `scripts/var-dump-receiver.py` | Local HTTP receiver for the `var-dump` plugin | [plugins/var-dump/README.md](plugins/var-dump/README.md) |
| `scripts/var-dump-analyze.py`, `var-dump-changes.py` | Turn a var dump and its change log into navigable files, and print the changes in order | [plugins/var-dump/README.md](plugins/var-dump/README.md) |
| `scripts/chores-from-dailyscape.py` | Generates Chore Tracker's chore list from dailyscape's data | [its docstring](scripts/chores-from-dailyscape.py) |
| `scripts/test_*.py` | Unit tests for the Python scripts above, run by `check.sh` | [`check.sh` header](scripts/check.sh) |

## License

MIT, see [LICENSE](LICENSE).
