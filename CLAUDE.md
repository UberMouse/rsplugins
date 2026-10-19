# rsplugins

RS3 client plugins written in Lua 5.4.8 against Jagex's Client Plugin API.

- Before writing or changing plugin code, read `docs/README.md` and the relevant docs. The API
  reference will live in `docs/api/` once the dump script exists. Until then, check signatures at
  https://developer.runescape.com/rs/.
- Plugins must pass Jagex moderation (`docs/guidelines.md`). Never build features that automate
  actions, send inputs to the server, reveal hidden or future state, or export other players'
  info. If a feature is borderline, flag it.
- Work and commit directly on `main`; don't create branches or worktrees unless asked or truly
  needed. Only one session edits this repo, and the beta client's `dev_plugins` symlink points at
  this checkout's `plugins/`, so a worktree's plugins would be invisible to the client.
- Moderation rejects unreadable code. Keep Lua lean and clearly commented, and write a plain-English
  description per plugin.
