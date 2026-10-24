# rsplugins

RS3 client plugins written in Lua 5.4.8 against Jagex's Client Plugin API.

- Before writing or changing plugin code, read `docs/README.md` and the relevant docs. The API
  reference will live in `docs/api/` once the dump script exists. Until then, check signatures at
  https://developer.runescape.com/rs/.
- To find which game vars a plugin can read, look them up in `docs/vars/` (grep `vars.csv`). It
  lists what exists, not values. To see a logged-in account's actual state, dump it with
  `plugins/var-dump` + `scripts/var-dump-receiver.py`, then run `scripts/var-dump-analyze.py`;
  dumps and their analysis stay in the gitignored `dumps/`.
- Plugins must pass Jagex moderation (`docs/guidelines.md`). Never build features that automate
  actions, send inputs to the server, reveal hidden or future state, or export other players'
  info. If a feature is borderline, flag it.
- Work and commit directly on `main`; don't create branches or worktrees unless asked or truly
  needed. Only one session edits this repo, and the beta client's `dev_plugins` symlink points at
  this checkout's `plugins/`, so a worktree's plugins would be invisible to the client.
- Moderation rejects unreadable code. Keep Lua lean and clearly commented, and write a plain-English
  description per plugin.
- Every change must pass `scripts/check-lua.sh` (luac, manifest JSON, selene, stylua; run `stylua`
  first). When selene flags an API global as undefined, confirm it exists at the API reference
  before adding it to `rs.yml`: it is as likely an invented API as a gap in the std.
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

## Architecture: Functional Core, Imperative Shell

Pure business logic stays free of side effects; I/O, state, and external APIs live in shell
modules. The core never calls the shell — the shell orchestrates the core.

## Critical Reminders

- **Transformer Mandate**: generate options, the human decides. Don't make architectural choices
  autonomously. 
- Edit files with the Edit tool rather than ad-hoc python scripts, unless the edit is bulk and
  mechanical.
