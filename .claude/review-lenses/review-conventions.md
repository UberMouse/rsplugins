# Review conventions (shared by every lens)

These apply to every `review-*.md` lens in this directory. They define how to weigh a finding,
and when not to report one at all.

## Trace to the runtime consequence

For every finding, state the concrete consequence in the client: the callback that errors and
stops doing its job, the overlay that never draws or never clears, the setting that is lost, the
client freeze or crash. Say whether it bites on a path the change can reach. Never report the form
of a line in isolation; trace it to the behaviour it causes.

There is no typechecker and no test suite here. `scripts/check-lua.sh` runs `luac -p`, selene (with
`rs.yml` declaring the API's top-level globals) and stylua, and nothing else. So a nil index, a
wrong `.`/`:` call, a misspelt API member or a wrong argument order is found **only** by review or
by a user in the client. Do not dismiss those as "a typechecker would catch it": none runs.

Some lenses review artefacts whose consequence falls on a person rather than the client: a
comment that misleads the next reader, a feature a Jagex moderator rejects. For those, that
person's consequence *is* the runtime consequence ("moderation fails the plugin: it reveals the
NPC's target", "the next reader trusts the stale comment and reintroduces the freeze"). A criterion
a lens names explicitly is never "style preference" under **Do not report** below.

## Severity

- **critical**: errors, freezes or crashes the client, loses or corrupts saved data, or gets the
  plugin rejected by moderation, on a reachable path.
- **warning**: degrades behaviour, or bites only an edge case (first enable, a reload, an empty
  list, logged out, an instance).
- **info**: latent, pre-existing, or with no plausible consequence.

A structural smell with a real consequence is a bug (warning or critical), not a nitpick.
Escalate its severity accordingly.

## Pattern consistency

When you flag a pattern (a missing nil check, an unbounded loop in a callback, a `.` that should
be `:`), check every other changed file for the same pattern and report each occurrence as its
own finding. A pattern fixed in one plugin but left in a sibling is a common miss.

## Do not report

- What `scripts/check-lua.sh` already rejects: Lua syntax errors, invalid `plugin.json` JSON,
  formatting (stylua), and what selene flags (undefined top-level globals, unused variables,
  accidental globals, shadowing). Assume the gate ran and passed.
- Pure formatting or style preference.
- Code the change did not touch, unless the change introduces a new consequence on it.
- Anything explicitly justified in a comment or sanctioned by `CLAUDE.md`, unless the lens says
  that kind of justification does not excuse it.

## Repository context these lenses assume

- RS3 client plugins in **Lua 5.4.8** against Jagex's Client Plugin API. One folder per plugin
  under `plugins/<name>/`: `main.lua` (run on every enable), `plugin.json` (manifest), optional
  extra modules and `resources/`. `scripts/` holds Python and shell dev helpers.
- The API is documented in `docs/` (our notes) and at https://developer.runescape.com/rs/ (the
  source of truth). `docs/api-concepts.md` *Runtime limits we've hit* records client behaviour
  the official docs do not.
- Every plugin must pass Jagex moderation (`docs/guidelines.md`), and moderators read all the
  code: unreadable code fails moderation outright. Some plugins are dev-only tools marked "not for
  submission" in their README; moderation findings still apply to them, at lower severity, unless
  the plugin is plainly a local dev tool (see `review-moderation.md`).
- Architecture is functional core / imperative shell: pure logic (geometry, parsing, state
  transitions) stays free of API calls and side effects; event callbacks, UI, HTTP and
  PersistentDB live in the shell. The core never calls the shell.
- House conventions (`CLAUDE.md`): comments explain the WHY; debug logging carries a greppable tag
  (each plugin's `say()` prefixes a `[TAG]`); keep Lua lean and readable.
