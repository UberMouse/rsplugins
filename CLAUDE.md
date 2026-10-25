# rsplugins

RS3 client plugins written in Lua 5.4.8 against Jagex's Client Plugin API.

- Before writing or changing plugin code, read `docs/README.md` and the relevant docs. The API
  reference is `docs/api/`: LuaLS stubs (signatures, types, doc text) that the dev shell symlinks
  from a pinned community repo. Grep it, e.g. `grep -rn 'function Player\.' docs/api/generated/`.
  The stubs are generated from https://developer.runescape.com/rs/; check there when details
  matter or a stub looks wrong.
- To find which game vars a plugin can read, look them up in `docs/vars/` (grep `vars.csv`). It
  lists what exists, not values. It's gitignored and built from a var dump
  (`plugins/var-dump/README.md`); the plugin tests fail without it. To see a logged-in account's
  actual state, dump it with `plugins/var-dump` + `scripts/var-dump-receiver.py`, then run
  `scripts/var-dump-analyze.py`; dumps and their analysis stay in the gitignored `dumps/`.
- Plugins must pass Jagex moderation (`docs/guidelines.md`). Never build features that automate
  actions, send inputs to the server, reveal hidden or future state, or export other players'
  info. If a feature is borderline, flag it.
- You can't launch or play the beta client, but the user can: treat them as the tool for it.
  Whenever an answer depends on how the client behaves and the docs, stubs and recordings don't
  settle it (does an API or dependency resolve, what a var holds, how a UI component behaves, does
  a change work in game), don't guess or build on the assumption. Write a probe (a throwaway
  plugin, tagged logging, or a session for the dev recorder in `lib/dev/`) and get it run. Record
  what it showed in `docs/api-concepts.md`. A probe that sits in `plugins/` must keep
  `scripts/check-lua.sh` green, and is deleted once it has answered.
- When the client is open, drive it yourself through the dev bridge
  ([docs/dev-environment.md](docs/dev-environment.md#dev-bridge)). Run `scripts/rsdev.py status`
  first. If the bridge is connected, run the console commands yourself (`rsdev.py exec "prf"`,
  `exec "prl <plugin>"`), read what plugins forward with `events`, and look at the game and plugin
  UI with `shot` (then Read the printed path). Ask the user only for what needs their hands:
  starting the client, enabling the bridge (`pon dev-bridge`), and acting in game. If it isn't
  connected, ask them for those steps, or fall back to giving them the exact console commands and
  what to send back (console lines matching a tag regex, or a recording's path). Only the main
  session uses rsdev, never a subagent. Two agents must not send console commands to the user's
  client at once, and every action should show in the conversation they are watching.
- Work and commit directly on `main`; don't create branches or worktrees unless asked or truly
  needed. Only one session edits this repo, and the beta client's `dev_plugins` symlink points at
  this checkout's `plugins/`, so a worktree's plugins would be invisible to the client.
- Moderation rejects unreadable code. Keep Lua lean and clearly commented, and write a plain-English
  description per plugin.
- Every change must pass `scripts/check-lua.sh` (luac, manifest JSON, selene, stylua, LuaLS
  against `docs/api/`, the busted plugin tests in `tests/` via `scripts/test-lua.sh`, which run
  plugins against the mock API harness described in `docs/testing.md`, and the Python tests of the
  recording sanitiser, `scripts/test_recording_sanitise.py`; run `stylua` first). When LuaLS flags an API name, member or argument, it is
  most likely an invented API: fix the code. Only if the official page proves the stub wrong,
  suppress that one line with `---@diagnostic disable-next-line: <code>` and a comment citing the
  page.
- Review criteria for plugin code live in `.claude/review-lenses/`. `/sdd-loop` runs a small change
  through implement → parallel spec/quality review → fix, then the `branch-code-review` workflow.

## Communication Style

**Be a peer engineer, not a cheerleader:**

- Skip validation theater ("you're absolutely right", "excellent point")
- Be direct and technical - if something's wrong, say it
- Use dry, technical humor when appropriate
- Talk like you're pairing with a staff engineer, not pitching to a VP
- Challenge bad ideas respectfully - disagreement is valuable
- No emoji unless the user uses them first
- Precision over politeness - technical accuracy is respect

## Code Conventions

- Comments explain the WHY, not the WHAT; never leave trivial comments
- Annotate function return types, unless the type is complex enough that it needs inferring. In Lua
  that is a LuaLS `---@return <type>` line on every new or changed function that returns a value
- Module state that starts nil is declared `local snap = nil ---@type table?`, and every function
  that reads it starts with `assert(snap, "<why it must be set>")`. That narrows it for LuaLS's
  nil check and names the broken invariant if it ever fires

## Architecture: Functional Core, Imperative Shell

Pure business logic stays free of side effects; I/O, state, and external APIs live in shell
modules. The core never calls the shell — the shell orchestrates the core.

## Critical Reminders

- **Transformer Mandate**: generate options, the human decides. Don't make architectural choices
  autonomously. 
- Edit files with the Edit tool rather than ad-hoc python scripts, unless the edit is bulk and
  mechanical.
